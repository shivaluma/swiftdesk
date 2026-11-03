import Foundation
import Testing
import WireProtocol
@testable import SessionCore

/// PRD §9 "malformed datagrams, stale packets" and Milestone B "no runaway memory": the Viewer's receive path is fed
/// a flood of garbage, truncated, wrong-session, inconsistent and replayed datagrams. It must not crash, must not
/// hand anything to the renderer, and every buffer involved must stay within its fixed bound.
@Suite struct HostileDatagramTests {
    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: next()) }) }
    }

    private static func videoDatagram(session: UInt32, frame: UInt32, index: UInt16, count: UInt16,
                                      payload: Data, flags: VideoFlags = []) -> Data {
        var w = ByteWriter(capacity: VideoPacketHeader.size + payload.count)
        VideoPacketHeader(flags: flags, sessionId: session, frameId: frame, packetIndex: index, packetCount: count,
                          payloadLength: UInt16(payload.count), captureTimestampNanos: 1, hostPipelineMicros: 0)
            .encode(into: &w)
        w.bytes(payload)
        return w.data
    }

    private static func parityDatagram(session: UInt32, frame: UInt32, groupSize: UInt8, parityIndex: UInt16,
                                       count: UInt16, payload: Data, lengthXor: UInt16 = 0) -> Data {
        var w = ByteWriter(capacity: ParityPacketHeader.size + payload.count)
        ParityPacketHeader(flags: [], groupSize: groupSize, sessionId: session, frameId: frame, parityIndex: parityIndex,
                           packetCount: count, payloadLength: UInt16(payload.count), captureTimestampNanos: 1,
                           hostPipelineMicros: 0, lengthXor: lengthXor)
            .encode(into: &w)
        w.bytes(payload)
        return w.data
    }

    /// FEC parity datagrams from a hostile or buggy peer: parity-only frames, parity that disagrees with the data,
    /// bogus lengths and paddings, invalid indices. Bounded, nothing decoded, the pipeline stays alive.
    @Test func floodOfHostileParityDatagramsIsBoundedAndHarmless() throws {
        let transport = FakeTransport()
        let sink = RecordingFrameSink()
        let slot = FrameSinkSlot()
        slot.sink = sink
        let session: UInt32 = 0xFEC0
        let pipeline = ViewerMediaPipeline(sessionId: session, transport: transport, sinkSlot: slot)
        pipeline.start()
        defer { pipeline.stop() }

        var rng = SplitMix(state: 7)
        for round in 0..<20 {
            var batch: [Data] = []
            for i in 0..<1_000 {
                let frame = UInt32(round * 1_000 + i + 1)
                switch i % 5 {
                case 0:
                    // Parity-only frames with the largest legal shape: buffered under the byte budget, never complete.
                    batch.append(Self.parityDatagram(session: session, frame: frame, groupSize: 1,
                                                     parityIndex: UInt16(rng.next() % 4096),
                                                     count: UInt16(WireConstants.maxPacketsPerFrame),
                                                     payload: rng.bytes(1_118)))
                case 1:
                    // Single-fragment frames rebuilt from garbage parity: complete, but the gate/decoder rejects them.
                    batch.append(Self.parityDatagram(session: session, frame: frame, groupSize: 4, parityIndex: 0,
                                                     count: 1, payload: rng.bytes(200), lengthXor: 200))
                case 2:
                    // Data says K = 0, parity says K = 3 → metadata mismatch, frame dropped.
                    batch.append(Self.videoDatagram(session: session, frame: frame, index: 0, count: 4,
                                                    payload: rng.bytes(100)))
                    batch.append(Self.parityDatagram(session: session, frame: frame, groupSize: 3, parityIndex: 0,
                                                     count: 4, payload: rng.bytes(100)))
                case 3:
                    // Invalid parity index / zero K / wrong session / truncated: rejected before the reassembler.
                    batch.append(Self.parityDatagram(session: session, frame: frame, groupSize: 2, parityIndex: 9,
                                                     count: 4, payload: rng.bytes(10)))
                    batch.append(Self.parityDatagram(session: session, frame: frame, groupSize: 0, parityIndex: 0,
                                                     count: 4, payload: rng.bytes(10)))
                    batch.append(Self.parityDatagram(session: session &+ 1, frame: frame, groupSize: 1, parityIndex: 0,
                                                     count: 1, payload: rng.bytes(10)))
                    batch.append(Data([WireConstants.parityMagic, 1]) + rng.bytes(12))
                default:
                    // Bogus lengthXor on a recoverable group: rejected at recovery, nothing delivered.
                    batch.append(Self.parityDatagram(session: session, frame: frame, groupSize: 2, parityIndex: 0,
                                                     count: 2, payload: rng.bytes(100), lengthXor: 0xFFFF))
                }
            }
            for d in batch { pipeline.ingest(d) }
            for d in batch { pipeline.ingest(d) }   // replay: duplicates and stale parity
        }

        let health = pipeline.healthCounters()
        let r = health.reassembly
        let caps = FrameReassembler.Config(sessionId: session)
        #expect(health.malformedDatagrams > 0)
        #expect(r.parityReceived > 0)
        #expect(r.packetsMalformed > 0 && r.packetsWrongSession > 0)
        #expect(r.parityStale > 0 || r.parityUnused > 0)
        #expect(r.pendingFrames <= caps.maxPendingFrames && r.pendingBytes <= caps.maxPendingBytes)
        #expect(health.inboxQueued <= ViewerMediaPipeline.maxInboxDatagrams)
        #expect(sink.count == 0)
        #expect(pipeline.framesDecoded == 0)
    }

    @Test func floodOfHostileDatagramsIsBoundedAndHarmless() throws {
        let transport = FakeTransport()
        let sink = RecordingFrameSink()
        let slot = FrameSinkSlot()
        slot.sink = sink
        let session: UInt32 = 0xC0FFEE
        let pipeline = ViewerMediaPipeline(sessionId: session, transport: transport, sinkSlot: slot)
        pipeline.start()
        defer { pipeline.stop() }

        var rng = SplitMix(state: 42)
        var sent = 0
        for round in 0..<20 {
            var batch: [Data] = []
            for i in 0..<1_000 {
                switch i % 6 {
                case 0: batch.append(rng.bytes(Int(rng.next() % 1_400)))                       // random bytes
                case 1: batch.append(Data([WireConstants.videoMagic, 1]) + rng.bytes(10))      // truncated header
                case 2: batch.append(Self.videoDatagram(session: session &+ 1, frame: UInt32(i), index: 0, count: 1,
                                                        payload: rng.bytes(100)))              // wrong session
                case 3:
                    // Partial frames that never complete: many distinct ids, max packet counts, big payloads.
                    let frame = UInt32(round * 1_000 + i)
                    batch.append(Self.videoDatagram(session: session, frame: frame, index: 0,
                                                    count: UInt16(WireConstants.maxPacketsPerFrame),
                                                    payload: rng.bytes(1_118)))
                case 4:
                    // Same frame id with conflicting packet counts → malformed, whole frame dropped.
                    let frame = UInt32(round * 1_000 + i - 1)
                    batch.append(Self.videoDatagram(session: session, frame: frame, index: 1, count: 2,
                                                    payload: rng.bytes(50)))
                default:
                    // Complete one-packet "frames" with garbage payloads: delivered by the reassembler, but the
                    // recovery gate (no keyframe yet) or the decoder must reject them.
                    batch.append(Self.videoDatagram(session: session, frame: UInt32(round * 1_000 + i), index: 0,
                                                    count: 1, payload: rng.bytes(200)))
                }
            }
            for d in batch { pipeline.ingest(d) }
            // Replay the whole batch: duplicates and stale ids.
            for d in batch { pipeline.ingest(d) }
            sent += batch.count * 2
        }

        let health = pipeline.healthCounters()
        let r = health.reassembly
        #expect(health.malformedDatagrams > 0, "random/truncated datagrams must be rejected by Datagram.parse")
        #expect(r.packetsWrongSession > 0)
        #expect(r.packetsMalformed > 0 || r.packetsDuplicate > 0)
        #expect(r.packetsStale > 0, "replayed ids at or below the last delivered must be stale")
        // Bounded memory: the reassembler never holds more than its frame/byte caps, the inbox never more than its cap.
        let caps = FrameReassembler.Config(sessionId: session)
        #expect(r.pendingFrames <= caps.maxPendingFrames)
        #expect(r.pendingBytes <= caps.maxPendingBytes)
        #expect(health.inboxQueued <= ViewerMediaPipeline.maxInboxDatagrams)
        #expect(UInt64(sent) >= health.malformedDatagrams + r.packetsReceived)
        // Nothing reached the renderer: no keyframe ever arrived, and garbage is not decodable.
        #expect(sink.count == 0)
        #expect(pipeline.framesDecoded == 0)
        // The pipeline is still alive and asking for the keyframe it needs.
        let requests = transport.controlMessages.filter { if case .requestKeyframe = $0 { true } else { false } }
        #expect(!requests.isEmpty || health.framesGated > 0)
    }
}
