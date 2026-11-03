import Foundation
import Testing
@testable import WireProtocol

@Suite("FrameReassembler")
struct FrameReassemblerTests {
    static let session: UInt32 = 42

    private func makeReassembler(_ configure: (inout FrameReassembler.Config) -> Void = { _ in }) -> FrameReassembler {
        var c = FrameReassembler.Config(sessionId: Self.session)
        configure(&c)
        return FrameReassembler(config: c)
    }

    private func feed(_ r: FrameReassembler, _ packets: [(header: VideoPacketHeader, payload: Data)], now: UInt64 = 1_000)
        -> [ReassemblyEvent] {
        packets.flatMap { r.ingest(header: $0.header, payload: $0.payload, nowNanos: now) }
    }

    @Test func inOrderSingleFrame() {
        let r = makeReassembler()
        let packets = fragments(frameId: 1, size: 5000, flags: .keyframe, captureNanos: 777)
        #expect(packets.count == 5)
        var events: [ReassemblyEvent] = []
        for (i, p) in packets.enumerated() {
            events = r.ingest(header: p.header, payload: p.payload, nowNanos: 100 + UInt64(i))
            if i < packets.count - 1 {
                #expect(events.isEmpty)
                #expect(r.stats.pendingFrames == 1)
            }
        }
        #expect(events.count == 1)
        guard case .frameComplete(let f) = events.first else { Issue.record(); return }
        #expect(f.frameId == 1)
        #expect(f.flags == .keyframe)
        #expect(f.data == frameBytes(id: 1, count: 5000))
        #expect(f.data.startIndex == 0)
        #expect(f.captureTimestampNanos == 777)
        #expect(f.hostPipelineMicros == 500)
        #expect(f.firstPacketAtNanos == 100)
        #expect(f.completedAtNanos == 104)
        #expect(r.lastDeliveredFrameId == 1)
        let s = r.stats
        #expect(s.packetsReceived == 5 && s.framesCompleted == 1 && s.framesLost == 0)
        #expect(s.pendingFrames == 0 && s.pendingBytes == 0)
    }

    @Test func pendingBytesTracksPayload() {
        let r = makeReassembler()
        let packets = fragments(frameId: 1, size: 3000, flags: .keyframe)
        _ = r.ingest(header: packets[0].header, payload: packets[0].payload, nowNanos: 0)
        #expect(r.stats.pendingBytes == 1118)
        _ = r.ingest(header: packets[2].header, payload: packets[2].payload, nowNanos: 0)
        #expect(r.stats.pendingBytes == 1118 + 764)
    }

    @Test(arguments: [UInt64(1), 7, 99])
    func shuffledPackets(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let r = makeReassembler()
        let packets = fragments(frameId: 1, size: 20_000, flags: .keyframe).shuffled(using: &rng)
        let events = feed(r, packets)
        #expect(events.completedFrames.map(\.data) == [frameBytes(id: 1, count: 20_000)])
        #expect(events.lostCount == 0)
    }

    @Test func interleavedFramesCompleteInOrder() {
        let r = makeReassembler()
        let f1 = fragments(frameId: 1, size: 3300, flags: .keyframe)
        let f2 = fragments(frameId: 2, size: 3300)
        let f3 = fragments(frameId: 3, size: 3300)
        var order: [(header: VideoPacketHeader, payload: Data)] = []
        for i in 0..<3 { order += [f1[i], f2[i], f3[i]] }   // round-robin, so 1, 2, 3 complete in order
        let events = feed(r, order)
        #expect(events.completedFrames.map(\.frameId) == [1, 2, 3])
        #expect(events.lostCount == 0)
        #expect(events.completedFrames[1].data == frameBytes(id: 2, count: 3300))
    }

    @Test func newerFrameCompletingFirstDiscardsOlder() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let f2 = fragments(frameId: 2, size: 3000)
        let f3 = fragments(frameId: 3, size: 1000)
        _ = feed(r, Array(f2.prefix(2)))
        #expect(r.stats.pendingFrames == 1)
        let events = feed(r, f3)
        #expect(events.count == 2)
        #expect(events[0] == .framesLost(count: 1))           // loss reported before the completion
        #expect(events.completedFrames.map(\.frameId) == [3])
        #expect(r.stats.pendingFrames == 0 && r.stats.pendingBytes == 0)
        // The rest of frame 2 is now stale.
        #expect(feed(r, [f2[2]]).isEmpty)
        #expect(r.stats.packetsStale == 1)
    }

    @Test func gapReportsFramesLostThenComplete() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let events = feed(r, fragments(frameId: 5, size: 100))
        #expect(events.count == 2)
        #expect(events[0] == .framesLost(count: 3))
        #expect(events.completedFrames.first?.frameId == 5)
        #expect(r.stats.framesLost == 3)
        #expect(r.stats.framesCompleted == 2)
    }

    @Test func duplicates() {
        let r = makeReassembler()
        let packets = fragments(frameId: 1, size: 3000, flags: .keyframe)
        _ = feed(r, [packets[0], packets[0], packets[1]])
        #expect(r.stats.packetsDuplicate == 1)
        #expect(r.stats.pendingBytes == 2 * 1118)
        let events = feed(r, [packets[2], packets[1]])
        #expect(events.completedFrames.count == 1)
        // A duplicate after completion is stale.
        #expect(r.stats.packetsStale == 1)
        #expect(r.stats.packetsDuplicate == 1)
    }

    @Test func wrongSession() {
        let r = makeReassembler()
        let events = feed(r, fragments(sessionId: 7, frameId: 1, size: 100, flags: .keyframe))
        #expect(events.isEmpty)
        #expect(r.stats.packetsWrongSession == 1)
        #expect(r.stats.pendingFrames == 0)
    }

    @Test func mismatchedPacketCountDropsWholeFrame() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let good = fragments(frameId: 2, size: 3000)
        _ = feed(r, [good[0]])
        var bad = good[1]
        bad.header.packetCount = 4
        let events = r.ingest(header: bad.header, payload: bad.payload, nowNanos: 0)
        #expect(events == [.framesLost(count: 1)])
        #expect(r.stats.packetsMalformed == 1)
        #expect(r.stats.pendingFrames == 0 && r.stats.pendingBytes == 0)
        // Remaining packets for that frame are stale; the next frame is delivered without a further loss report.
        #expect(feed(r, [good[2]]).isEmpty)
        #expect(r.stats.packetsStale == 1)
        let next = feed(r, fragments(frameId: 3, size: 100))
        #expect(next.completedFrames.map(\.frameId) == [3])
        #expect(next.lostCount == 0)
    }

    @Test func mismatchedFlagsOrTimestampDropsFrame() {
        for mutate in [{ (h: inout VideoPacketHeader) in h.flags = .keyframe },
                       { (h: inout VideoPacketHeader) in h.captureTimestampNanos &+= 1 }] {
            let r = makeReassembler()
            _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
            let good = fragments(frameId: 2, size: 3000)
            _ = feed(r, [good[0]])
            var bad = good[1]
            mutate(&bad.header)
            #expect(r.ingest(header: bad.header, payload: bad.payload, nowNanos: 0) == [.framesLost(count: 1)])
            #expect(r.stats.packetsMalformed == 1)
        }
    }

    @Test func inconsistentFragmentSizesAreMalformed() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let base = fragments(frameId: 2, size: 3000)
        _ = feed(r, [base[0]])                              // establishes fragment size 1118
        var odd = base[1]
        odd.payload = Data(count: 1000)
        odd.header.payloadLength = 1000
        #expect(r.ingest(header: odd.header, payload: odd.payload, nowNanos: 0) == [.framesLost(count: 1)])

        // Last fragment larger than a middle fragment.
        let r2 = makeReassembler()
        _ = feed(r2, fragments(frameId: 1, size: 100, flags: .keyframe))
        let f = fragments(frameId: 2, size: 3000)
        _ = feed(r2, [f[0]])
        var bigLast = f[2]
        bigLast.payload = Data(count: 1200)
        bigLast.header.payloadLength = 1200
        #expect(r2.ingest(header: bigLast.header, payload: bigLast.payload, nowNanos: 0) == [.framesLost(count: 1)])
        #expect(r2.stats.packetsMalformed == 1)
    }

    @Test func structurallyInvalidHeaderIsMalformed() {
        let r = makeReassembler()
        var p = fragments(frameId: 1, size: 100, flags: .keyframe)[0]
        p.header.packetIndex = 1                            // == packetCount
        #expect(r.ingest(header: p.header, payload: p.payload, nowNanos: 0).isEmpty)
        p.header.packetIndex = 0
        p.header.packetCount = 0
        #expect(r.ingest(header: p.header, payload: p.payload, nowNanos: 0).isEmpty)
        p.header.packetCount = 1
        #expect(r.ingest(header: p.header, payload: p.payload.prefix(5), nowNanos: 0).isEmpty)   // length mismatch
        #expect(r.stats.packetsMalformed == 3)
        #expect(r.stats.pendingFrames == 0)
    }

    @Test func staleAndFrameIdZero() {
        let r = makeReassembler()
        let zero = fragments(frameId: 0, size: 100, flags: .keyframe)
        #expect(feed(r, zero).isEmpty)
        #expect(r.stats.packetsStale == 1)
        _ = feed(r, fragments(frameId: 10, size: 100, flags: .keyframe))
        #expect(feed(r, fragments(frameId: 10, size: 100, flags: .keyframe)).isEmpty)
        #expect(feed(r, fragments(frameId: 3, size: 100)).isEmpty)
        #expect(r.stats.packetsStale == 3)
        #expect(r.lastDeliveredFrameId == 10)
    }

    @Test func expiry() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let f2 = fragments(frameId: 2, size: 3000)
        let t0: UInt64 = 5_000_000
        _ = r.ingest(header: f2[0].header, payload: f2[0].payload, nowNanos: t0)
        let deadline = FrameReassembler.Config(sessionId: 0).deadlineNanos
        #expect(r.expire(nowNanos: t0 + deadline).isEmpty)   // not past the deadline yet
        #expect(r.expire(nowNanos: t0 + deadline + 1) == [.framesLost(count: 1)])
        #expect(r.stats.pendingFrames == 0)
        #expect(r.expire(nowNanos: t0 + 10 * deadline).isEmpty)
        // Late packet of the expired frame is stale; the next frame reports no additional loss.
        #expect(feed(r, [f2[1]]).isEmpty)
        #expect(r.stats.packetsStale == 1)
        let next = feed(r, fragments(frameId: 3, size: 100))
        #expect(next.lostCount == 0)
        #expect(next.completedFrames.count == 1)
        #expect(r.stats.framesLost == 1)
    }

    /// A large native-size keyframe whose last fragment (or its duplicate) arrives after 120 ms must still complete:
    /// expiring it would discard the frame recovery waits for and cost another, equally large keyframe.
    @Test func keyframeGetsTheLongerDeadline() {
        let r = makeReassembler()
        let key = fragments(frameId: 1, size: 20_000, flags: .keyframe)
        let t0: UInt64 = 5_000_000
        _ = r.ingest(header: key[0].header, payload: key[0].payload, nowNanos: t0)
        let config = FrameReassembler.Config(sessionId: 0)
        #expect(config.keyframeDeadlineNanos > config.deadlineNanos)
        #expect(r.expire(nowNanos: t0 + config.deadlineNanos + 1).isEmpty, "keyframe must outlive the P-frame deadline")
        let rest = key.dropFirst().flatMap { r.ingest(header: $0.header, payload: $0.payload, nowNanos: t0 + 300_000_000) }
        #expect(rest.completedFrames.map(\.frameId) == [1])
        #expect(r.stats.framesLost == 0)
        // Past the keyframe deadline it is abandoned like any other frame.
        let next = fragments(frameId: 2, size: 20_000, flags: .keyframe)
        _ = r.ingest(header: next[0].header, payload: next[0].payload, nowNanos: t0)
        #expect(r.expire(nowNanos: t0 + config.keyframeDeadlineNanos + 1) == [.framesLost(count: 1)])
        // A P-frame still expires at the short deadline.
        let p = fragments(frameId: 3, size: 3000)
        _ = r.ingest(header: p[0].header, payload: p[0].payload, nowNanos: t0)
        #expect(r.expire(nowNanos: t0 + config.deadlineNanos + 1) == [.framesLost(count: 1)])
    }

    @Test func expiryCoversGapUpToNewestExpired() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        _ = feed(r, [fragments(frameId: 3, size: 3000)[0]], now: 0)
        _ = feed(r, [fragments(frameId: 5, size: 3000)[0]], now: 50_000_000)
        // Only frame 3 is past the deadline; ids 2 and 3 are lost; 5 remains pending.
        #expect(r.expire(nowNanos: 130_000_000) == [.framesLost(count: 2)])
        #expect(r.stats.pendingFrames == 1)
        #expect(r.expire(nowNanos: 200_000_000) == [.framesLost(count: 2)])   // ids 4, 5
        #expect(r.stats.framesLost == 4)
    }

    @Test func evictionUnderMaxPendingFrames() {
        let r = makeReassembler { $0.maxPendingFrames = 2 }
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let f2 = fragments(frameId: 2, size: 3000)
        let f3 = fragments(frameId: 3, size: 3000)
        let f4 = fragments(frameId: 4, size: 3000)
        _ = feed(r, [f2[0], f3[0]])
        #expect(r.stats.pendingFrames == 2)
        let events = feed(r, [f4[0]])
        #expect(events == [.framesLost(count: 1)])          // frame 2 evicted
        #expect(r.stats.pendingFrames == 2)
        // Frame 3 and 4 can still complete in order.
        let done = feed(r, Array(f3.dropFirst()) + Array(f4.dropFirst()))
        #expect(done.completedFrames.map(\.frameId) == [3, 4])
        #expect(done.lostCount == 0)
        #expect(feed(r, [f2[1]]).isEmpty)                   // stale
    }

    @Test func olderNewcomerWhenFullIsTheOneDropped() {
        let r = makeReassembler { $0.maxPendingFrames = 2 }
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        _ = feed(r, [fragments(frameId: 3, size: 3000)[0], fragments(frameId: 4, size: 3000)[0]])
        let events = feed(r, [fragments(frameId: 2, size: 3000)[0]])
        #expect(events == [.framesLost(count: 1)])
        #expect(r.stats.pendingFrames == 2)
        let done = feed(r, Array(fragments(frameId: 3, size: 3000).dropFirst()))
        #expect(done.completedFrames.map(\.frameId) == [3])
        #expect(done.lostCount == 0)
    }

    @Test func evictionUnderMaxPendingBytes() {
        let r = makeReassembler { $0.maxPendingBytes = 3000 }
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let f2 = fragments(frameId: 2, size: 5000)
        let f3 = fragments(frameId: 3, size: 5000)
        _ = feed(r, [f2[0], f2[1]])
        #expect(r.stats.pendingBytes == 2236)
        let events = feed(r, [f3[0]])
        #expect(events == [.framesLost(count: 1)])
        #expect(r.stats.pendingBytes == 1118)
        #expect(r.stats.pendingFrames == 1)
    }

    @Test func frameLargerThanByteBudgetIsDropped() {
        let r = makeReassembler { $0.maxPendingBytes = 2000 }
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let big = fragments(frameId: 2, size: 5000)
        let events = feed(r, big)
        #expect(events.lostCount == 1)
        #expect(events.completedFrames.isEmpty)
        #expect(r.stats.pendingBytes <= 2000)
        #expect(r.stats.packetsStale == UInt64(big.count - 2))
    }

    @Test func maxFrameBytesEnforced() {
        let r = makeReassembler { $0.maxFrameBytes = 2000 }
        _ = feed(r, fragments(frameId: 1, size: 100, flags: .keyframe))
        let events = feed(r, fragments(frameId: 2, size: 3000))
        #expect(events.completedFrames.isEmpty)
        #expect(events.lostCount == 1)
        #expect(r.stats.packetsMalformed >= 1)
        #expect(r.stats.pendingBytes == 0)
        // A frame within the limit still works.
        #expect(feed(r, fragments(frameId: 3, size: 1500)).completedFrames.count == 1)
    }

    @Test func firstFrameKeyframeAtAnyId() {
        let r = makeReassembler()
        let events = feed(r, fragments(frameId: 1000, size: 2000, flags: .keyframe))
        #expect(events.count == 1)
        #expect(events.lostCount == 0)
        #expect(feed(r, fragments(frameId: 1001, size: 100)).lostCount == 0)
        #expect(r.stats.framesLost == 0)
    }

    @Test func firstFrameNonKeyframeReportsLoss() {
        let r = makeReassembler()
        let events = feed(r, fragments(frameId: 5, size: 100))
        #expect(events.count == 2)
        #expect(events[0] == .framesLost(count: 1))
        #expect(events.completedFrames.map(\.frameId) == [5])
    }

    @Test func firstFrameKeyframeDiscardsOlderPartialWithoutLoss() {
        let r = makeReassembler()
        _ = feed(r, [fragments(frameId: 1, size: 3000)[0]])
        let events = feed(r, fragments(frameId: 2, size: 100, flags: .keyframe))
        #expect(events.lostCount == 0)
        #expect(events.completedFrames.map(\.frameId) == [2])
        #expect(r.stats.pendingFrames == 0)
    }

    @Test func resetReturnsToFirstFrameBehaviour() {
        let r = makeReassembler()
        _ = feed(r, fragments(frameId: 10, size: 100, flags: .keyframe))
        _ = feed(r, [fragments(frameId: 11, size: 3000)[0]])
        r.reset()
        #expect(r.stats.pendingFrames == 0 && r.stats.pendingBytes == 0)
        #expect(r.lastDeliveredFrameId == 0)
        #expect(r.stats.framesCompleted == 1)                // lifetime counters kept
        let events = feed(r, fragments(frameId: 3, size: 100, flags: .keyframe))
        #expect(events.completedFrames.map(\.frameId) == [3])
        #expect(events.lostCount == 0)
    }

    @Test func payloadSlicesFromLargerBuffers() {
        // Payloads with non-zero startIndex (as produced by Datagram.parse) must assemble correctly.
        let r = makeReassembler()
        let packets = fragments(frameId: 1, size: 2500, flags: .keyframe)
        #expect(packets.allSatisfy { $0.payload.startIndex == 32 })
        let events = feed(r, packets.reversed())
        #expect(events.completedFrames.first?.data == frameBytes(id: 1, count: 2500))
    }

    @Test func slotReuseAcrossManyFrames() {
        let r = makeReassembler { $0.maxPendingFrames = 2 }
        var delivered: [UInt32] = []
        for id in UInt32(1)...500 {
            let events = feed(r, fragments(frameId: id, size: 100 + Int(id) * 7, flags: id == 1 ? .keyframe : []))
            delivered += events.completedFrames.map(\.frameId)
            #expect(events.lostCount == 0)
        }
        #expect(delivered == Array(1...500))
        #expect(r.stats.pendingFrames == 0)
    }

    // MARK: Loss + reorder simulation

    @Test(arguments: [(0.01, UInt64(11)), (0.03, UInt64(33)), (0.03, UInt64(1234))])
    func lossAndReorderSimulation(lossRate: Double, seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let frameCount = 2000
        let frameInterval: UInt64 = 16_666_667
        var config = FrameReassembler.Config(sessionId: Self.session)
        config.maxPendingBytes = 512 * 1024
        let r = FrameReassembler(config: config)
        let packetizer = VideoPacketizer(sessionId: Self.session)

        struct InFlight { var arrival: UInt64; var datagram: Data }
        var inFlight: [InFlight] = []
        var sizes: [UInt32: Int] = [:]
        for i in 1...frameCount {
            let id = UInt32(i)
            let isKey = i == 1 || i % 120 == 0
            let size = isKey ? Int.random(in: 30_000...60_000, using: &rng) : Int.random(in: 300...9_000, using: &rng)
            sizes[id] = size
            let datagrams = try packetizer.packetize(frameId: id, frame: frameBytes(id: id, count: size),
                                                     flags: isKey ? .keyframe : [], captureTimestampNanos: UInt64(i),
                                                     hostPipelineMicros: 0)
            let sendAt = UInt64(i) * frameInterval
            for (k, d) in datagrams.enumerated() {
                // Frame 1 is delivered losslessly so exact id accounting can be asserted from the start.
                if i > 1 && rng.chance(lossRate) { continue }
                var arrival = sendAt + UInt64(k) * 20_000 + 5_000_000 + UInt64.random(in: 0...8_000_000, using: &rng)
                if i > 1 && rng.chance(0.01) { arrival += UInt64.random(in: 10_000_000...60_000_000, using: &rng) } // late burst
                if rng.chance(0.002) { inFlight.append(InFlight(arrival: arrival + 1_000, datagram: d)) }    // duplicate
                inFlight.append(InFlight(arrival: arrival, datagram: d))
            }
        }
        inFlight.sort { $0.arrival < $1.arrival }

        var delivered: [UInt32] = []
        var lastExpire: UInt64 = 0
        var maxPendingBytesSeen = 0
        func handle(_ events: [ReassemblyEvent]) {
            for e in events {
                if case .frameComplete(let f) = e {
                    if let last = delivered.last { #expect(f.frameId > last) }
                    #expect(f.data == frameBytes(id: f.frameId, count: sizes[f.frameId]!))
                    delivered.append(f.frameId)
                }
            }
        }
        for packet in inFlight {
            if packet.arrival >= lastExpire + 10_000_000 {
                handle(r.expire(nowNanos: packet.arrival))
                lastExpire = packet.arrival
            }
            guard case .video(let h, let payload) = try Datagram.parse(packet.datagram) else { Issue.record(); continue }
            handle(r.ingest(header: h, payload: payload, nowNanos: packet.arrival))
            let s = r.stats
            maxPendingBytesSeen = max(maxPendingBytesSeen, s.pendingBytes)
            #expect(s.pendingBytes <= config.maxPendingBytes)
            #expect(s.pendingFrames <= config.maxPendingFrames)
        }
        handle(r.expire(nowNanos: .max))

        let s = r.stats
        #expect(s.pendingFrames == 0 && s.pendingBytes == 0)
        #expect(delivered.first == 1)
        #expect(Int(s.framesCompleted) == delivered.count)
        // Every frame id up to the last one handled is accounted exactly once: delivered or reported lost.
        // (Frame 1 is a lossless keyframe and the last frame always has packets in flight, so the total is exact.)
        #expect(s.framesCompleted + s.framesLost == UInt64(frameCount))
        #expect(s.packetsReceived == UInt64(inFlight.count))
        let minCompletion = lossRate <= 0.01 ? 0.85 : 0.65
        #expect(Double(delivered.count) >= minCompletion * Double(frameCount),
                "completed \(delivered.count)/\(frameCount), lost \(s.framesLost), maxPending \(maxPendingBytesSeen)")
    }
}
