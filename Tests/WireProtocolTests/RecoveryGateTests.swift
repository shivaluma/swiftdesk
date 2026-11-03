import Testing
@testable import WireProtocol

@Suite("RecoveryGate")
struct RecoveryGateTests {
    let ms: UInt64 = 1_000_000

    @Test func initiallyAwaitingKeyframe() {
        let g = GateBox()
        #expect(g.awaitingKeyframe)
        #expect(!g.admit(flags: []))
        #expect(!g.admit(flags: .recovery))
        #expect(g.admit(flags: .keyframe))
        #expect(!g.awaitingKeyframe)
        #expect(g.admit(flags: []))
    }

    @Test func lossGatesUntilKeyframe() {
        let g = GateBox()
        _ = g.admit(flags: .keyframe)
        #expect(g.onLoss(nowNanos: 1_000 * ms))
        #expect(g.awaitingKeyframe)
        #expect(!g.admit(flags: []))
        #expect(g.admit(flags: [.keyframe, .recovery]))
        #expect(g.admit(flags: []))
    }

    @Test func rateLimiting() {
        let g = GateBox(minRequestIntervalNanos: 200 * ms, rerequestAfterNanos: 500 * ms)
        let t: UInt64 = 10_000 * ms
        #expect(g.onLoss(nowNanos: t))
        #expect(g.lastRequestAtNanos == t)
        #expect(!g.onLoss(nowNanos: t + 1 * ms))
        #expect(!g.onDecodeError(nowNanos: t + 199 * ms))
        #expect(g.onLoss(nowNanos: t + 200 * ms))
        #expect(g.lastRequestAtNanos == t + 200 * ms)
    }

    @Test func rerequestWhileStillAwaiting() {
        let g = GateBox(minRequestIntervalNanos: 200 * ms, rerequestAfterNanos: 500 * ms)
        let t: UInt64 = 1_000 * ms
        #expect(g.onLoss(nowNanos: t))
        #expect(!g.tick(nowNanos: t + 100 * ms))
        #expect(!g.tick(nowNanos: t + 499 * ms))
        #expect(g.tick(nowNanos: t + 500 * ms))
        #expect(!g.tick(nowNanos: t + 999 * ms))
        #expect(g.tick(nowNanos: t + 1000 * ms))
        _ = g.admit(flags: .keyframe)
        #expect(!g.tick(nowNanos: t + 5000 * ms))
    }

    @Test func keyframeClearsAndLaterLossIsDeferredByRateLimit() {
        let g = GateBox(minRequestIntervalNanos: 200 * ms, rerequestAfterNanos: 500 * ms)
        let t: UInt64 = 1_000 * ms
        #expect(g.onLoss(nowNanos: t))
        #expect(g.admit(flags: .keyframe))
        // New loss 50 ms after the previous request: rate-limited now, but tick sends it once allowed.
        #expect(!g.onLoss(nowNanos: t + 50 * ms))
        #expect(g.awaitingKeyframe)
        #expect(!g.tick(nowNanos: t + 150 * ms))
        #expect(g.tick(nowNanos: t + 200 * ms))
        #expect(!g.tick(nowNanos: t + 300 * ms))
        #expect(g.tick(nowNanos: t + 700 * ms))
    }

    @Test func initialGracePeriodBeforeFirstRequest() {
        let g = GateBox(minRequestIntervalNanos: 200 * ms, rerequestAfterNanos: 500 * ms)
        let t: UInt64 = 3_000 * ms
        #expect(!g.tick(nowNanos: t))            // starts the grace period
        #expect(!g.tick(nowNanos: t + 499 * ms))
        #expect(g.tick(nowNanos: t + 500 * ms))  // first keyframe never came
        #expect(!g.tick(nowNanos: t + 600 * ms))
        #expect(g.tick(nowNanos: t + 1000 * ms))
    }

    @Test func lossBeforeFirstKeyframeRequestsImmediately() {
        let g = GateBox()
        #expect(g.onLoss(nowNanos: 5 * ms))
        #expect(!g.admit(flags: []))
        #expect(g.admit(flags: .keyframe))
    }

    @Test func tickIsQuietWhenNotAwaiting() {
        let g = GateBox()
        _ = g.admit(flags: .keyframe)
        for i in 0..<10 { #expect(!g.tick(nowNanos: UInt64(i) * 1_000 * ms)) }
    }

    @Test func clockGoingBackwardsDoesNotTrap() {
        let g = GateBox()
        #expect(g.onLoss(nowNanos: 1_000 * ms))
        #expect(!g.onLoss(nowNanos: 10 * ms))
        #expect(!g.tick(nowNanos: 0))
    }
}

/// Reference wrapper so mutating gate calls can be used directly inside `#expect`.
private final class GateBox {
    var gate: RecoveryGate
    init(minRequestIntervalNanos: UInt64 = 200_000_000, rerequestAfterNanos: UInt64 = 500_000_000) {
        gate = RecoveryGate(minRequestIntervalNanos: minRequestIntervalNanos, rerequestAfterNanos: rerequestAfterNanos)
    }
    var awaitingKeyframe: Bool { gate.awaitingKeyframe }
    var lastRequestAtNanos: UInt64? { gate.lastRequestAtNanos }
    func onLoss(nowNanos: UInt64) -> Bool { gate.onLoss(nowNanos: nowNanos) }
    func onDecodeError(nowNanos: UInt64) -> Bool { gate.onDecodeError(nowNanos: nowNanos) }
    func admit(flags: VideoFlags) -> Bool { gate.admit(flags: flags) }
    func tick(nowNanos: UInt64) -> Bool { gate.tick(nowNanos: nowNanos) }
}
