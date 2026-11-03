import Foundation
import Testing
@testable import WireProtocol

/// Hostile-input robustness: random and mutated bytes must only ever produce `WireError`s, never a trap.
@Suite("Fuzz")
struct FuzzTests {
    @Test func randomBytesIntoDatagramParse() {
        var rng = SeededRNG(seed: 0xF00D)
        var parsed = 0
        for _ in 0..<20_000 {
            var d = rng.bytes(Int.random(in: 0...80, using: &rng))
            // Bias toward valid magic/version so deeper paths are exercised.
            if !d.isEmpty && rng.chance(0.7) { d[0] = rng.chance(0.5) ? 0x56 : 0x50 }
            if d.count > 1 && rng.chance(0.7) { d[1] = 1 }
            do {
                _ = try Datagram.parse(d)
                parsed += 1
            } catch is WireError {
            } catch {
                Issue.record("non-WireError \(error)")
            }
        }
        #expect(parsed >= 0)
    }

    @Test func mutatedValidDatagramsIntoParseAndReassembler() {
        var rng = SeededRNG(seed: 0xBEEF)
        let r = FrameReassembler(config: FrameReassembler.Config(sessionId: 42))
        let base = (1...20).flatMap { id in
            (try? VideoPacketizer(sessionId: 42, maxDatagramSize: 200)
                .packetize(frameId: UInt32(id), frame: frameBytes(id: UInt32(id), count: 50 + id * 40),
                           flags: id % 5 == 1 ? .keyframe : [], captureTimestampNanos: 0, hostPipelineMicros: 0)) ?? []
        } + [Datagram.encodePointer(PointerState(seq: 1, x: 0.5, y: 0.5, buttonsMask: 1))]
        var now: UInt64 = 0
        for _ in 0..<30_000 {
            var d = base[Int.random(in: 0..<base.count, using: &rng)]
            let flips = Int.random(in: 0...3, using: &rng)
            for _ in 0..<flips where !d.isEmpty {
                d[Int.random(in: 0..<d.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            }
            if rng.chance(0.1) { d = d.prefix(Int.random(in: 0...d.count, using: &rng)) }
            if rng.chance(0.05) { d.append(rng.bytes(Int.random(in: 1...10, using: &rng))) }
            now += UInt64.random(in: 0...2_000_000, using: &rng)
            if case .video(let h, let payload)? = try? Datagram.parse(d) {
                _ = r.ingest(header: h, payload: payload, nowNanos: now)
                let s = r.stats
                #expect(s.pendingBytes <= 8 * 1024 * 1024 && s.pendingFrames <= 8 && s.pendingBytes >= 0)
            }
            if rng.chance(0.05) { _ = r.expire(nowNanos: now) }
        }
    }

    @Test func randomPayloadsIntoControlDecode() {
        var rng = SeededRNG(seed: 0xC0DE)
        for _ in 0..<30_000 {
            let type = UInt8.random(in: 0...20, using: &rng)
            let payload = rng.bytes(Int.random(in: 0...120, using: &rng))
            do { _ = try ControlMessage.decode(type: type, payload: payload) }
            catch is WireError {}
            catch { Issue.record("non-WireError \(error)") }
        }
    }

    @Test func mutatedValidPayloadsIntoControlDecode() {
        var rng = SeededRNG(seed: 0xD00D)
        for _ in 0..<30_000 {
            let m = sampleMessages[Int.random(in: 0..<sampleMessages.count, using: &rng)]
            var payload = m.encodePayload()
            for _ in 0..<Int.random(in: 1...4, using: &rng) where !payload.isEmpty {
                payload[Int.random(in: 0..<payload.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            do {
                let decoded = try ControlMessage.decode(type: m.type.rawValue, payload: payload)
                // Anything that decodes must re-encode to the same bytes (canonical encoding).
                #expect(decoded.encodePayload() == payload)
            } catch is WireError {
            } catch { Issue.record("non-WireError \(error)") }
        }
    }

    @Test func randomStreamsIntoControlStreamDecoder() {
        var rng = SeededRNG(seed: 0xABCD)
        for _ in 0..<2_000 {
            var d = ControlStreamDecoder(maxMessageSize: rng.chance(0.5) ? WireConstants.maxControlMessageSize : 64)
            var stream = Data()
            // Mix valid frames with garbage so the decoder sees both.
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                if rng.chance(0.7) {
                    stream.append(ControlFraming.frame(sampleMessages[Int.random(in: 0..<sampleMessages.count, using: &rng)]))
                } else {
                    stream.append(rng.bytes(Int.random(in: 0...40, using: &rng)))
                }
            }
            if !stream.isEmpty && rng.chance(0.3) {
                stream[Int.random(in: 0..<stream.count, using: &rng)] ^= 0xFF
            }
            var pos = 0
            var dead = false
            while pos < stream.count {
                let n = min(Int.random(in: 1...50, using: &rng), stream.count - pos)
                do {
                    _ = try d.append(stream[pos..<(pos + n)])
                    #expect(!dead)
                } catch is WireError {
                    dead = true
                    #expect(d.isFailed)
                } catch { Issue.record("non-WireError \(error)") }
                #expect(d.bufferedByteCount <= 4 + WireConstants.maxControlMessageSize)
                pos += n
            }
        }
    }
}
