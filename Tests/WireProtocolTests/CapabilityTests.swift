import Foundation
import Testing
@testable import WireProtocol

/// `PeerCapabilities` in both directions (AUTH nonce, ACCEPT token) and the silent back-off of `RecoveryGate`.
@Suite("Peer capabilities")
struct CapabilityTests {
    @Test func bitAllocation() {
        #expect(PeerCapabilities.passwordAuth.rawValue == 1)
        #expect(PeerCapabilities.sessionResume.rawValue == 2)
        // AUTH's capability type is the shared one, so both directions use one bit table.
        let viewer: Auth.Capabilities = [.passwordAuth, .sessionResume]
        #expect(viewer.rawValue == 3)
    }

    @Test func acceptTokenCarriesHostCapabilities() throws {
        let random = Data((0..<16).map { UInt8(0xC0 + $0) })
        let token = Accept.sessionToken(capabilities: .sessionResume, random: random)
        #expect(token.count == Accept.sessionTokenSize)
        #expect(Array(token.prefix(5)) == [0x53, 0x44, 0x43, 0x31, 0x02])
        #expect(token.suffix(11) == random.prefix(11))

        let accept = Accept(sessionId: 7, sessionToken: token, hostName: "studio")
        #expect(accept.capabilities == .sessionResume)
        // Unchanged ACCEPT layout: an old Viewer decodes it like any other token.
        let payload = ControlMessage.accept(accept).encodePayload()
        #expect(payload.count == 4 + 16 + 2 + 6)
        guard case .accept(let decoded) = try ControlMessage.decode(type: 3, payload: payload) else {
            Issue.record("not an accept"); return
        }
        #expect(decoded.capabilities.contains(.sessionResume))
        #expect(!decoded.capabilities.contains(.passwordAuth))
    }

    @Test func legacyTokenAnnouncesNothing() {
        let legacy = Accept(sessionId: 1, sessionToken: Data(repeating: 0xA5, count: 16), hostName: "old")
        #expect(legacy.capabilities == [])
        #expect(PeerCapabilities.announced(in: Data(count: 15)) == [])
        #expect(PeerCapabilities.announced(in: PeerCapabilities.marker + Data([0x02])) == [])   // wrong size
        let sliced = (Data([0xFF]) + PeerCapabilities.carrier(.sessionResume, random: Data())).dropFirst()
        #expect(PeerCapabilities.announced(in: sliced) == .sessionResume)
    }

    @Test func featureNeedsBothSides() {
        let newViewer: PeerCapabilities = [.passwordAuth, .sessionResume]
        let oldHost = Accept(sessionId: 1, sessionToken: Data(count: 16), hostName: "h").capabilities
        #expect(!newViewer.intersection(oldHost).contains(.sessionResume))
        let oldViewer = Auth(viewerFingerprint: Data(count: 32), hostFingerprint: Data(count: 32),
                             nonce: Data(repeating: 9, count: 16)).capabilities
        #expect(!oldViewer.intersection(.sessionResume).contains(.sessionResume))
        #expect(newViewer.intersection(.sessionResume) == .sessionResume)
    }

    @Test func viewerNonceWithBothBitsSurvivesTheWire() throws {
        let auth = Auth(viewerFingerprint: Data(count: 32), hostFingerprint: Data(count: 32),
                        nonce: Auth.nonce(capabilities: [.passwordAuth, .sessionResume], random: Data(count: 11)))
        guard case .auth(let decoded) = try ControlMessage.decode(type: 2, payload: ControlMessage.auth(auth).encodePayload()) else {
            Issue.record("not an auth"); return
        }
        #expect(decoded.capabilities == [.passwordAuth, .sessionResume])
    }
}

@Suite("RecoveryGate after a blackout")
struct RecoveryGateBlackoutTests {
    let ms: UInt64 = 1_000_000

    /// Ticks every 15 ms like `ViewerMediaPipeline` from `start` to `end`, counting requests.
    private func run(_ gate: inout RecoveryGate, from start: UInt64, to end: UInt64) -> [UInt64] {
        var sent: [UInt64] = []
        var t = start
        while t < end {
            if gate.tick(nowNanos: t) { sent.append(t) }
            t += 15 * ms
        }
        return sent
    }

    @Test func silentLinkBacksOffAndRecoveryAsksOnce() {
        var gate = RecoveryGate(maxSilentRerequestIntervalNanos: 4_000 * ms)
        _ = gate.admit(flags: .keyframe)
        // Blackout starts: pending frames expire → one loss request.
        do { let r = gate.onLoss(nowNanos: 1_000 * ms); #expect(r) }
        let during = run(&gate, from: 1_000 * ms, to: 11_000 * ms)
        // 1 s, 2 s, 4 s, 4 s … after the first request, instead of every 500 ms (≈20 requests).
        #expect(during.count <= 4, "\(during.map { $0 / ms })")
        #expect(during.first.map { $0 - 1_000 * ms } ?? 0 >= 1_000 * ms)

        // Traffic again: exactly one request right away, then the gap report is rate-limited away.
        gate.noteTraffic()
        let resume = run(&gate, from: 11_000 * ms, to: 11_060 * ms)
        #expect(resume.count == 1)
        do { let r = gate.onLoss(nowNanos: 11_070 * ms); #expect(!r) }
        // The keyframe arrives: nothing more is asked.
        do { let r = gate.admit(flags: .keyframe); #expect(r) }
        #expect(run(&gate, from: 11_100 * ms, to: 13_000 * ms).isEmpty)
    }

    @Test func trafficKeepsTheNormalInterval() {
        var gate = RecoveryGate(maxSilentRerequestIntervalNanos: 4_000 * ms)
        _ = gate.admit(flags: .keyframe)
        do { let r = gate.onLoss(nowNanos: 0); #expect(r) }
        var sent: [UInt64] = []
        var t: UInt64 = 0
        while t < 2_000 * ms {
            gate.noteTraffic()   // P-frames keep arriving; only the keyframe is missing
            if gate.tick(nowNanos: t) { sent.append(t) }
            t += 15 * ms
        }
        #expect(sent.count == 3, "\(sent.map { $0 / ms })")   // ~500, ~1000, ~1500 ms
    }

    @Test func intervalDoublesToTheCap() {
        var gate = RecoveryGate(maxSilentRerequestIntervalNanos: 4_000 * ms)
        _ = gate.admit(flags: .keyframe)
        do { let r = gate.onLoss(nowNanos: 0); #expect(r) }
        #expect(gate.currentRerequestIntervalNanos == 1_000 * ms)
        do { let r = gate.tick(nowNanos: 1_000 * ms); #expect(r) }
        #expect(gate.currentRerequestIntervalNanos == 2_000 * ms)
        do { let r = gate.tick(nowNanos: 2_900 * ms); #expect(!r) }
        do { let r = gate.tick(nowNanos: 3_000 * ms); #expect(r) }
        #expect(gate.currentRerequestIntervalNanos == 4_000 * ms)
        do { let r = gate.tick(nowNanos: 7_000 * ms); #expect(r) }
        #expect(gate.currentRerequestIntervalNanos == 4_000 * ms)
        gate.noteTraffic()
        #expect(gate.currentRerequestIntervalNanos == 500 * ms)
    }

    @Test func withoutBackoffTheIntervalIsFixed() {
        var gate = RecoveryGate()
        _ = gate.admit(flags: .keyframe)
        do { let r = gate.onLoss(nowNanos: 0); #expect(r) }
        #expect(gate.currentRerequestIntervalNanos == 500 * ms)
        #expect(run(&gate, from: 0, to: 5_000 * ms).count >= 9)
    }
}
