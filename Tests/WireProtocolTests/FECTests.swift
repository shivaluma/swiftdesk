import Foundation
import Testing
@testable import WireProtocol

/// Packetizes with FEC and parses every datagram back, data fragments first, then parity (send order).
/// Defaults to keyframes, so a test's first frame is not reported as a loss (a session may not start on a P-frame).
private func fecPackets(sessionId: UInt32 = 42, frameId: UInt32, size: Int, k: Int, flags: VideoFlags = .keyframe,
                        captureNanos: UInt64 = 1_000, maxDatagramSize: Int = 132) -> (data: [Datagram], parity: [Datagram]) {
    let p = VideoPacketizer(sessionId: sessionId, maxDatagramSize: maxDatagramSize)
    let datagrams = try! p.packetize(frameId: frameId, frame: frameBytes(id: frameId, count: size), flags: flags,
                                     captureTimestampNanos: captureNanos, hostPipelineMicros: 500, fecGroupSize: k)
    let parsed = datagrams.map { try! Datagram.parse($0) }
    let data = parsed.filter { if case .video = $0 { true } else { false } }
    let parity = parsed.filter { if case .parity = $0 { true } else { false } }
    return (data, parity)
}

private func feed(_ r: FrameReassembler, _ datagrams: [Datagram], now: UInt64 = 1_000) -> [ReassemblyEvent] {
    datagrams.flatMap { r.ingest($0, nowNanos: now) }
}

private func makeReassembler(_ configure: (inout FrameReassembler.Config) -> Void = { _ in }) -> FrameReassembler {
    var c = FrameReassembler.Config(sessionId: 42)
    configure(&c)
    return FrameReassembler(config: c)
}

private func parityHeader(_ d: Datagram) -> (ParityPacketHeader, Data) {
    guard case .parity(let h, let p) = d else { fatalError("not parity") }
    return (h, p)
}

/// Re-encodes a parity datagram after mutating its header and/or payload.
private func reencode(_ d: Datagram, header mutate: (inout ParityPacketHeader) -> Void = { _ in },
                      payload: ((Data) -> Data)? = nil) -> Datagram {
    var (h, p) = parityHeader(d)
    mutate(&h)
    if let payload { p = payload(p) }
    return .parity(h, payload: p)
}

@Suite("FEC layout, parity datagrams, packetizer")
struct FECWireTests {
    @Test func layoutArithmetic() {
        #expect(FECLayout.groupCount(packetCount: 0, groupSize: 4) == 0)
        #expect(FECLayout.groupCount(packetCount: 7, groupSize: 0) == 0)
        #expect(FECLayout.groupCount(packetCount: 1, groupSize: 4) == 1)
        #expect(FECLayout.groupCount(packetCount: 8, groupSize: 4) == 2)
        #expect(FECLayout.groupCount(packetCount: 9, groupSize: 4) == 3)
        // 9 fragments, G = 3: groups {0,3,6}, {1,4,7}, {2,5,8}.
        #expect((0..<3).map { FECLayout.memberCount(group: $0, packetCount: 9, groupCount: 3) } == [3, 3, 3])
        // 7 fragments, K = 3 → G = 3: groups {0,3,6}, {1,4}, {2,5}; every group ≤ K.
        #expect((0..<3).map { FECLayout.memberCount(group: $0, packetCount: 7, groupCount: 3) } == [3, 2, 2])
        for count in 1...300 {
            for k in 1...12 {
                let g = FECLayout.groupCount(packetCount: count, groupSize: k)
                let sizes = (0..<g).map { FECLayout.memberCount(group: $0, packetCount: count, groupCount: g) }
                #expect(sizes.reduce(0, +) == count)
                #expect(sizes.allSatisfy { $0 >= 1 && $0 <= k })
            }
        }
        // 3 fragments, K = 2 → G = 2: {0, 2} and {1}; group 1 is a single *non-last* fragment.
        #expect(!FECLayout.isLastOnlyGroup(group: 1, packetCount: 3, groupCount: 2))
        #expect(!FECLayout.isLastOnlyGroup(group: 0, packetCount: 3, groupCount: 2))
        // 1 fragment: the only group is the last fragment alone.
        #expect(FECLayout.isLastOnlyGroup(group: 0, packetCount: 1, groupCount: 1))
        // K = 1: every group is one fragment; only the last one is "last only".
        #expect(FECLayout.isLastOnlyGroup(group: 4, packetCount: 5, groupCount: 5))
        #expect(!FECLayout.isLastOnlyGroup(group: 3, packetCount: 5, groupCount: 5))
    }

    @Test func parityHeaderByteOffsetsAndRoundTrip() throws {
        let h = ParityPacketHeader(flags: [.keyframe, .recovery], groupSize: 6, sessionId: 0x1122_3344,
                                   frameId: 0x5566_7788, parityIndex: 2, packetCount: 0x0F03, payloadLength: 5,
                                   captureTimestampNanos: 0xA1A2_A3A4_A5A6_A7A8, hostPipelineMicros: 0xB1B2_B3B4,
                                   lengthXor: 0xC1C2)
        var w = ByteWriter()
        h.encode(into: &w)
        let b = Array(w.data)
        #expect(b.count == ParityPacketHeader.size && b.count == 32)
        #expect(b[0] == 0x46 && b[1] == 1 && b[2] == 0x03 && b[3] == 6)
        #expect(Array(b[4..<8]) == [0x11, 0x22, 0x33, 0x44])
        #expect(Array(b[8..<12]) == [0x55, 0x66, 0x77, 0x88])
        #expect(Array(b[12..<14]) == [0x00, 0x02])
        #expect(Array(b[14..<16]) == [0x0F, 0x03])
        #expect(Array(b[16..<18]) == [0x00, 0x05])
        #expect(Array(b[18..<26]) == [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8])
        #expect(Array(b[26..<30]) == [0xB1, 0xB2, 0xB3, 0xB4])
        #expect(Array(b[30..<32]) == [0xC1, 0xC2])
        w.bytes(Data([1, 2, 3, 4, 5]))
        guard case .parity(let parsed, let payload) = try Datagram.parse(w.data) else { Issue.record(); return }
        #expect(parsed == h)
        #expect(Array(payload) == [1, 2, 3, 4, 5])
    }

    @Test func parityParseRejections() {
        let valid = ParityPacketHeader(flags: [], groupSize: 4, sessionId: 1, frameId: 1, parityIndex: 1,
                                       packetCount: 8, payloadLength: 3, captureTimestampNanos: 0,
                                       hostPipelineMicros: 0, lengthXor: 0)
        func datagram(_ h: ParityPacketHeader, payload: Int) -> Data {
            var w = ByteWriter()
            h.encode(into: &w)
            w.bytes(Data(repeating: 7, count: payload))
            return w.data
        }
        #expect((try? Datagram.parse(datagram(valid, payload: 3))) != nil)
        #expect(throws: WireError.truncated) { try Datagram.parse(datagram(valid, payload: 3).prefix(31)) }
        #expect(throws: WireError.malformed("payloadLength mismatch")) { try Datagram.parse(datagram(valid, payload: 4)) }
        var h = valid
        h.groupSize = 0
        #expect(throws: WireError.malformed("parity groupSize 0")) { try Datagram.parse(datagram(h, payload: 3)) }
        h = valid
        h.parityIndex = 2   // 8 fragments / K 4 → G = 2
        #expect(throws: WireError.malformed("parityIndex >= groupCount")) { try Datagram.parse(datagram(h, payload: 3)) }
        h = valid
        h.packetCount = 0
        #expect(throws: WireError.malformed("packetCount out of range")) { try Datagram.parse(datagram(h, payload: 3)) }
        h = valid
        h.payloadLength = 0
        #expect(throws: WireError.malformed("empty parity")) { try Datagram.parse(datagram(h, payload: 0)) }
        var badVersion = datagram(valid, payload: 3)
        badVersion[1] = 2
        #expect(throws: WireError.unsupportedVersion(2)) { try Datagram.parse(badVersion) }
    }

    @Test func packetizerWithoutFECIsUnchanged() throws {
        let p = VideoPacketizer(sessionId: 42, maxDatagramSize: 132)
        let frame = frameBytes(id: 3, count: 950)
        let plain = try p.packetize(frameId: 3, frame: frame, flags: [], captureTimestampNanos: 1, hostPipelineMicros: 2)
        let zero = try p.packetize(frameId: 3, frame: frame, flags: [], captureTimestampNanos: 1, hostPipelineMicros: 2,
                                   fecGroupSize: 0)
        #expect(plain == zero)
        #expect(plain.count == 10)
        #expect(plain.allSatisfy { $0[0] == WireConstants.videoMagic && $0[3] == 0 })
        #expect(p.parityCount(forFrameBytes: 950, fecGroupSize: 0) == 0)
    }

    @Test(arguments: [1, 2, 3, 4, 6, 10, 255, 1000])
    func packetizerAppendsXorParity(k: Int) throws {
        let p = VideoPacketizer(sessionId: 42, maxDatagramSize: 132)   // 100-byte fragments
        let size = 950                                                   // 10 fragments, last one 50 bytes
        let frame = frameBytes(id: 9, count: size)
        let datagrams = try p.packetize(frameId: 9, frame: frame, flags: .keyframe, captureTimestampNanos: 77,
                                        hostPipelineMicros: 5, fecGroupSize: k)
        let effectiveK = min(k, 255)
        let groups = FECLayout.groupCount(packetCount: 10, groupSize: effectiveK)
        #expect(datagrams.count == 10 + groups)
        #expect(p.parityCount(forFrameBytes: size, fecGroupSize: k) == groups)
        // Data fragments come first and carry K.
        for d in datagrams.prefix(10) {
            guard case .video(let h, _) = try Datagram.parse(d) else { Issue.record(); return }
            #expect(Int(h.fecGroupSize) == effectiveK)
        }
        for (g, d) in datagrams.dropFirst(10).enumerated() {
            guard case .parity(let h, let payload) = try Datagram.parse(d) else { Issue.record(); return }
            #expect(Int(h.parityIndex) == g && Int(h.groupSize) == effectiveK && h.packetCount == 10)
            #expect(h.flags == .keyframe && h.frameId == 9 && h.captureTimestampNanos == 77 && h.hostPipelineMicros == 5)
            // Expected parity: XOR of members zero-padded to the longest member.
            let members = stride(from: g, to: 10, by: groups).map { i in frame[(i * 100)..<min(size, i * 100 + 100)] }
            let length = members.map(\.count).max()!
            var expected = [UInt8](repeating: 0, count: length)
            var lengths: UInt16 = 0
            for m in members {
                lengths ^= UInt16(m.count)
                for (j, byte) in m.enumerated() { expected[j] ^= byte }
            }
            #expect(Array(payload) == expected)
            #expect(h.lengthXor == lengths)
        }
    }

    @Test func singleFragmentFrameParityIsACopy() throws {
        let p = VideoPacketizer(sessionId: 42, maxDatagramSize: 132)
        let frame = frameBytes(id: 1, count: 37)
        let datagrams = try p.packetize(frameId: 1, frame: frame, flags: [], captureTimestampNanos: 0,
                                        hostPipelineMicros: 0, fecGroupSize: 8)
        #expect(datagrams.count == 2)
        guard case .parity(let h, let payload) = try Datagram.parse(datagrams[1]) else { Issue.record(); return }
        #expect(payload == frame && h.lengthXor == 37 && h.payloadLength == 37 && h.groupCount == 1)
    }

    @Test func packetizerHandlesSlicedInput() throws {
        let p = VideoPacketizer(sessionId: 42, maxDatagramSize: 132)
        let backing = Data(repeating: 0xEE, count: 13) + frameBytes(id: 4, count: 420)
        let slice = backing[13...]
        let a = try p.packetize(frameId: 4, frame: slice, flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0,
                                fecGroupSize: 3)
        let b = try p.packetize(frameId: 4, frame: frameBytes(id: 4, count: 420), flags: [], captureTimestampNanos: 0,
                                hostPipelineMicros: 0, fecGroupSize: 3)
        #expect(a == b)
    }
}

@Suite("FrameReassembler FEC recovery")
struct FECReassemblyTests {
    /// Every single-fragment loss position, for several frame shapes and group sizes, and with the parity arriving
    /// both after the data (normal order) and before it.
    @Test(arguments: [(950, 1), (950, 3), (950, 4), (950, 10), (1000, 4), (100, 2), (305, 2), (2000, 6)])
    func recoversEveryPosition(size: Int, k: Int) {
        let probe = fecPackets(frameId: 1, size: size, k: k)
        for parityFirst in [false, true] {
            for lost in probe.data.indices {
                let r = makeReassembler()
                var data = probe.data
                data.remove(at: lost)
                let order = parityFirst ? probe.parity + data : data + probe.parity
                let events = feed(r, order)
                let frames = events.completedFrames
                #expect(frames.count == 1, "size \(size) k \(k) lost \(lost) parityFirst \(parityFirst)")
                #expect(frames.first?.data == frameBytes(id: 1, count: size))
                #expect(events.lostCount == 0)
                // Parity first: a group whose last member is merely still in flight is rebuilt early too.
                if parityFirst {
                    #expect(r.stats.fragmentsRecovered >= 1)
                } else {
                    #expect(r.stats.fragmentsRecovered == 1)
                }
                #expect(r.stats.pendingBytes == 0 && r.stats.pendingFrames == 0)
                #expect(r.stats.parityMalformed == 0)
            }
        }
    }

    @Test func recoversTheShortLastFragmentWithItsTrueLength() {
        // 950 bytes / 100-byte fragments: the last fragment is 50 bytes. K = 10 → one group of all ten.
        let probe = fecPackets(frameId: 1, size: 950, k: 10)
        let r = makeReassembler()
        let events = feed(r, Array(probe.data.dropLast()) + probe.parity)
        #expect(events.completedFrames.first?.data.count == 950)
        #expect(events.completedFrames.first?.data == frameBytes(id: 1, count: 950))
    }

    @Test func singleFragmentFrameIsRecoveredFromParityAlone() {
        let probe = fecPackets(frameId: 1, size: 37, k: 4, flags: .keyframe)
        let r = makeReassembler()
        let events = feed(r, probe.parity)
        #expect(events.completedFrames.first?.data == frameBytes(id: 1, count: 37))
        #expect(events.completedFrames.first?.flags == .keyframe)
        #expect(r.stats.fragmentsRecovered == 1)
    }

    @Test func oneLossInEachGroupIsRecovered() {
        let probe = fecPackets(frameId: 1, size: 1200, k: 4)   // 12 fragments, G = 3: {0,3,6,9} {1,4,7,10} {2,5,8,11}
        #expect(probe.parity.count == 3)
        let r = makeReassembler()
        let kept = probe.data.enumerated().filter { ![0, 4, 11].contains($0.offset) }.map(\.element)
        let events = feed(r, kept + probe.parity)
        #expect(events.completedFrames.first?.data == frameBytes(id: 1, count: 1200))
        #expect(r.stats.fragmentsRecovered == 3)
    }

    @Test func twoLossesInOneGroupLoseTheFrame() {
        let probe = fecPackets(frameId: 1, size: 1200, k: 4)
        let r = makeReassembler()
        // 0 and 3 are both in group 0: unrecoverable.
        let kept = probe.data.enumerated().filter { ![0, 3].contains($0.offset) }.map(\.element)
        var events = feed(r, kept + probe.parity)
        #expect(events.isEmpty)
        #expect(r.stats.pendingFrames == 1)
        // The parity of the intact groups was dropped right away; only group 0's parity is still held.
        #expect(r.stats.pendingBytes == 10 * 100 + 100)
        // The next frame completes: frame 1 is reported lost once, and its buffers (incl. parity) are freed.
        events = feed(r, fecPackets(frameId: 2, size: 300, k: 4, flags: []).data)
        #expect(events.lostCount == 1)
        #expect(events.completedFrames.map(\.frameId) == [2])
        #expect(r.stats.pendingBytes == 0 && r.stats.pendingFrames == 0)
        #expect(r.stats.fragmentsRecovered == 0)
    }

    @Test func unrecoverableFrameExpiresAndFreesParity() {
        let probe = fecPackets(frameId: 1, size: 800, k: 8)   // 8 fragments, one group
        let r = makeReassembler { $0.deadlineNanos = 50; $0.keyframeDeadlineNanos = 50 }
        _ = feed(r, Array(probe.data.dropFirst(2)) + probe.parity, now: 100)
        #expect(r.stats.pendingBytes == 600 + 100)
        let events = r.expire(nowNanos: 200)
        #expect(events.lostCount == 1)
        #expect(r.stats.pendingBytes == 0 && r.stats.pendingFrames == 0)
        // Late data and parity of the expired frame are stale; parity is counted separately from data.
        _ = feed(r, [probe.data[0]] + probe.parity, now: 300)
        #expect(r.stats.packetsStale == 1 && r.stats.parityStale == 1)
    }

    @Test func parityAfterCompletionIsStaleNotAnError() {
        let probe = fecPackets(frameId: 1, size: 950, k: 4)
        let r = makeReassembler()
        let events = feed(r, probe.data + probe.parity)
        #expect(events.completedFrames.count == 1)
        let s = r.stats
        #expect(s.parityReceived == UInt64(probe.parity.count))
        #expect(s.parityStale == UInt64(probe.parity.count))
        #expect(s.packetsStale == 0 && s.packetsMalformed == 0 && s.fragmentsRecovered == 0)
    }

    @Test func parityForAnIntactGroupIsNotBuffered() {
        let probe = fecPackets(frameId: 1, size: 1200, k: 4)
        let r = makeReassembler()
        // Group 1 ({1,4,7,10}) complete, frame still missing fragment 0.
        _ = feed(r, Array(probe.data.dropFirst()))
        let before = r.stats.pendingBytes
        _ = feed(r, [probe.parity[1], probe.parity[2]])
        #expect(r.stats.pendingBytes == before)
        #expect(r.stats.parityUnused == 2)
        // Group 0's parity repairs fragment 0.
        let events = feed(r, [probe.parity[0]])
        #expect(events.completedFrames.first?.data == frameBytes(id: 1, count: 1200))
    }

    @Test func duplicateParityIsIgnored() {
        let probe = fecPackets(frameId: 1, size: 1200, k: 4)
        let r = makeReassembler()
        _ = feed(r, [probe.parity[0], probe.parity[0]])
        #expect(r.stats.parityUnused == 1)
        #expect(r.stats.pendingBytes == 100)
    }

    @Test func lateDataAfterRecoveryIsAStaleOrDuplicatePacket() {
        let probe = fecPackets(frameId: 1, size: 950, k: 4)
        let r = makeReassembler()
        var events = feed(r, Array(probe.data.dropFirst()) + probe.parity)
        #expect(events.completedFrames.count == 1)
        events = feed(r, [probe.data[0]])
        #expect(events.isEmpty)
        #expect(r.stats.packetsStale == 1)
    }

    @Test func recoveredFrameStillReportsTheGapBeforeIt() {
        let r = makeReassembler()
        _ = feed(r, fecPackets(frameId: 1, size: 500, k: 4, flags: .keyframe).data)
        let probe = fecPackets(frameId: 3, size: 500, k: 4)
        let events = feed(r, Array(probe.data.dropLast()) + probe.parity)
        #expect(events.count == 2)
        #expect(events.first == .framesLost(count: 1))
        #expect(events.completedFrames.map(\.frameId) == [3])
    }

    // MARK: Hostile / inconsistent parity

    @Test func parityWithMismatchedGroupSizeDropsTheFrame() {
        let probe = fecPackets(frameId: 1, size: 950, k: 4)
        let r = makeReassembler()
        _ = feed(r, Array(probe.data.prefix(3)))
        let hostile = reencode(fecPackets(frameId: 1, size: 950, k: 5).parity[0])
        let events = feed(r, [hostile])
        #expect(events.lostCount == 1)
        #expect(r.stats.packetsMalformed == 1)
        #expect(r.stats.pendingFrames == 0 && r.stats.pendingBytes == 0)
    }

    @Test func parityWithMismatchedFlagsOrTimestampDropsTheFrame() {
        for mutate in [{ (h: inout ParityPacketHeader) in h.flags = [.keyframe, .recovery] },
                       { (h: inout ParityPacketHeader) in h.captureTimestampNanos &+= 1 }] {
            let probe = fecPackets(frameId: 1, size: 950, k: 4)
            let r = makeReassembler()
            _ = feed(r, Array(probe.data.prefix(2)))
            let events = feed(r, [reencode(probe.parity[0], header: mutate)])
            #expect(events.lostCount == 1)
            #expect(r.stats.pendingFrames == 0)
        }
    }

    @Test func parityWithWrongLengthDropsTheFrame() {
        let probe = fecPackets(frameId: 1, size: 950, k: 4)
        let r = makeReassembler()
        _ = feed(r, Array(probe.data.prefix(2)))   // fragment size 100 known
        let short = reencode(probe.parity[0], header: { $0.payloadLength = 60 }, payload: { $0.prefix(60) })
        let events = feed(r, [short])
        #expect(events.lostCount == 1)
        #expect(r.stats.parityMalformed == 1)
    }

    @Test func parityTooShortForALaterFragmentIsRejectedAtRecovery() {
        // Parity arrives first (fragment size unknown) with a bogus shorter length; when recovery runs, a member
        // longer than the parity proves it inconsistent and nothing corrupt is delivered.
        let probe = fecPackets(frameId: 1, size: 1200, k: 4)
        let r = makeReassembler()
        let short = reencode(probe.parity[0], header: { $0.payloadLength = 60 }, payload: { $0.prefix(60) })
        _ = feed(r, [short])
        let kept = probe.data.enumerated().filter { $0.offset != 3 }.map(\.element)
        let events = feed(r, kept)
        #expect(events.completedFrames.isEmpty || events.completedFrames.first?.data == frameBytes(id: 1, count: 1200))
        #expect(r.stats.fragmentsRecovered == 0)
    }

    @Test func corruptLengthXorIsRejectedAndTheRealFragmentStillCompletes() {
        let probe = fecPackets(frameId: 1, size: 950, k: 10)   // one group, last fragment 50 bytes
        let r = makeReassembler()
        let bogus = reencode(probe.parity[0], header: { $0.lengthXor ^= 0x0FFF })
        var events = feed(r, Array(probe.data.dropLast()) + [bogus])
        #expect(events.completedFrames.isEmpty)
        #expect(r.stats.parityMalformed == 1 && r.stats.fragmentsRecovered == 0)
        events = feed(r, [probe.data.last!])
        #expect(events.completedFrames.first?.data == frameBytes(id: 1, count: 950))
    }

    @Test func corruptPaddingIsRejected() {
        // Recovering the 50-byte last fragment from a 100-byte parity: bytes 50..<100 must XOR to zero.
        let probe = fecPackets(frameId: 1, size: 950, k: 10)
        let r = makeReassembler()
        let bogus = reencode(probe.parity[0], payload: { p in
            var d = Data(p)
            d[d.startIndex + 99] ^= 0x01
            return d
        })
        let events = feed(r, Array(probe.data.dropLast()) + [bogus])
        #expect(events.completedFrames.isEmpty)
        #expect(r.stats.parityMalformed == 1)
    }

    @Test func parityForAnotherSessionIsIgnored() {
        let r = makeReassembler()
        let other = fecPackets(sessionId: 7, frameId: 1, size: 37, k: 1)
        #expect(feed(r, other.parity).isEmpty)
        #expect(r.stats.packetsWrongSession == 1 && r.stats.pendingFrames == 0)
    }

    @Test func parityOnlyFloodIsBoundedByTheByteBudget() {
        let r = makeReassembler {
            $0.maxPendingBytes = 1_000
            $0.maxPendingFrames = 4
        }
        var lost = 0
        for id in 1...200 {
            let probe = fecPackets(frameId: UInt32(id), size: 3_000, k: 2)   // 30 fragments, 15 parity
            lost += feed(r, probe.parity).lostCount
            #expect(r.stats.pendingBytes <= 1_000 && r.stats.pendingFrames <= 4)
        }
        #expect(lost > 0)
        #expect(r.stats.framesCompleted == 0)
    }

    @Test func mutatedParityDatagramsNeverTrap() {
        var rng = SeededRNG(seed: 0xFEC)
        let r = makeReassembler()
        let base = (1...20).flatMap { id -> [Data] in
            (try? VideoPacketizer(sessionId: 42, maxDatagramSize: 200)
                .packetize(frameId: UInt32(id), frame: frameBytes(id: UInt32(id), count: 50 + id * 60),
                           flags: id % 5 == 1 ? .keyframe : [], captureTimestampNanos: 0, hostPipelineMicros: 0,
                           fecGroupSize: 1 + id % 4)) ?? []
        }
        var now: UInt64 = 0
        for _ in 0..<30_000 {
            var d = base[Int.random(in: 0..<base.count, using: &rng)]
            for _ in 0..<Int.random(in: 0...3, using: &rng) where !d.isEmpty {
                d[Int.random(in: 0..<d.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            }
            if rng.chance(0.1) { d = d.prefix(Int.random(in: 0...d.count, using: &rng)) }
            now += UInt64.random(in: 0...2_000_000, using: &rng)
            if let parsed = try? Datagram.parse(d) {
                for event in r.ingest(parsed, nowNanos: now) {
                    if case .frameComplete(let f) = event {
                        // Whatever survives must be a frame the Host sent, or a mutated header's size; never a
                        // crash. Exact-content checks are done by the non-hostile tests.
                        #expect(!f.data.isEmpty)
                    }
                }
                let s = r.stats
                #expect(s.pendingBytes >= 0 && s.pendingBytes <= 8 * 1024 * 1024 && s.pendingFrames <= 8)
            }
            if rng.chance(0.05) { _ = r.expire(nowNanos: now) }
        }
    }

    // MARK: Simulation

    /// Uniform random datagram loss over a 720p-like stream: FEC must turn most single losses into delivered
    /// frames, and every delivered frame must be byte-exact.
    @Test(arguments: [(0.01, 6), (0.03, 4), (0.03, 3)])
    func simulatedLossWithAndWithoutFEC(loss: Double, k: Int) throws {
        func run(k: Int) throws -> (completed: Int, lost: UInt64, recovered: UInt64) {
            var rng = SeededRNG(seed: 0x5EED)
            let r = makeReassembler()
            let p = VideoPacketizer(sessionId: 42, maxDatagramSize: 1150)
            var completed = 0
            var now: UInt64 = 0
            for id in 1...3_000 {
                now += 16_666_667
                let size = id % 300 == 1 ? 54_000 : Int.random(in: 4_000...8_000, using: &rng)
                let datagrams = try p.packetize(frameId: UInt32(id), frame: frameBytes(id: UInt32(id), count: size),
                                                flags: id % 300 == 1 ? .keyframe : [], captureTimestampNanos: now,
                                                hostPipelineMicros: 0, fecGroupSize: k)
                for d in datagrams where id == 1 || !rng.chance(loss) {
                    for event in r.ingest(try Datagram.parse(d), nowNanos: now) {
                        if case .frameComplete(let f) = event {
                            #expect(f.data == frameBytes(id: f.frameId, count: f.data.count))
                            completed += 1
                        }
                    }
                }
                _ = r.expire(nowNanos: now)
            }
            return (completed, r.stats.framesLost, r.stats.fragmentsRecovered)
        }
        let plain = try run(k: 0)
        let fec = try run(k: k)
        #expect(plain.recovered == 0)
        #expect(fec.recovered > 0)
        // Residual frame loss with FEC must be well under a third of the unprotected loss.
        #expect(fec.lost * 3 < plain.lost, "loss \(loss) k \(k): plain lost \(plain.lost), fec lost \(fec.lost)")
        #expect(Double(fec.completed) >= 0.97 * 3_000)
    }

    // MARK: Loss estimate

    @Test func lossEstimateCountsRecoveredFragmentsAndLostFrames() {
        var a = FrameReassembler.Stats()
        a.packetsReceived = 100
        var b = a
        b.packetsReceived = 160   // 60 data
        b.parityReceived = 10
        b.framesCompleted = 10
        b.fragmentsRecovered = 2
        b.framesLost = 1
        let e = b.lossEstimate(since: a)
        #expect(e.received == 70)
        // 72 datagrams per 10 completed frames → 7.2 per frame; 1 lost frame ≈ 7 + 2 recovered.
        #expect(e.lost == 9)
        #expect(FrameReassembler.Stats().lossEstimate(since: FrameReassembler.Stats()) == (0, 0))
    }
}

@Suite("FECPolicy")
struct FECPolicyTests {
    @Test func defaultsAndInitialGroupSize() {
        let p = FECPolicy()
        #expect(p.groupSize == 6)
        #expect(FECPolicy(configuration: .off).groupSize == 0)
        #expect(FECPolicy(configuration: .fixed(5)).groupSize == 5)
        #expect(FECPolicy(configuration: .fixed(9999)).groupSize == 255)
    }

    @Test func ladderMapsLossToGroupSize() {
        let ladder = FECPolicy.Configuration.defaultLadder
        #expect(FECPolicy.target(for: 0, ladder: ladder) == 10)
        #expect(FECPolicy.target(for: 0.5, ladder: ladder) == 6)
        #expect(FECPolicy.target(for: 1, ladder: ladder) == 4)
        #expect(FECPolicy.target(for: 2, ladder: ladder) == 3)
        #expect(FECPolicy.target(for: 3, ladder: ladder) == 3)
        #expect(FECPolicy.target(for: 50, ladder: ladder) == 3)
        #expect(FECPolicy.target(for: 1, ladder: []) == 0)
    }

    @Test func protectionRisesImmediatelyAndRelaxesSlowly() {
        var p = FECPolicy()
        #expect(p.update(lossPercent: 3) == 3)        // burst: immediate
        #expect(p.update(lossPercent: 0) == 3)        // smoothed 1.5 → would relax to 4, needs 3 reports
        #expect(p.update(lossPercent: 0) == 3)
        #expect(p.update(lossPercent: 0) == 6)        // smoothed 0.375 → 6 after the third quiet report
        #expect(p.update(lossPercent: 0) == 6)
        #expect(p.update(lossPercent: 0) == 6)
        #expect(p.update(lossPercent: 0) == 10)
        #expect(p.update(lossPercent: 1) == 4)        // any rise is immediate again
    }

    @Test func fixedOffAndInvalidReportsAreIgnored() {
        var fixed = FECPolicy(configuration: .fixed(4))
        #expect(fixed.update(lossPercent: 10) == 4)
        var off = FECPolicy(configuration: .off)
        #expect(off.update(lossPercent: 10) == 0)
        var p = FECPolicy()
        #expect(p.update(lossPercent: nil) == 6)
        #expect(p.update(lossPercent: .nan) == 6)
        #expect(p.smoothedLossPercent == nil)
        #expect(p.update(lossPercent: -5) == 6)       // clamped to 0: less protection, so not applied at once
        #expect(p.smoothedLossPercent == 0)
    }
}
