import Testing
@testable import TransportCore

@Suite("ConnectionRateLimiter")
struct ConnectionRateLimiterTests {
    let second: UInt64 = 1_000_000_000

    @Test func allowsUpToPerAddressCapacityThenRefuses() {
        let limiter = LimiterBox(perAddressPerMinute: 3, globalPerMinute: 100)
        let t: UInt64 = 1_000 * second
        #expect(limiter.allow(address: "10.0.0.1", nowNanos: t))
        #expect(limiter.allow(address: "10.0.0.1", nowNanos: t))
        #expect(limiter.allow(address: "10.0.0.1", nowNanos: t))
        #expect(!limiter.allow(address: "10.0.0.1", nowNanos: t))
        // Another address has its own bucket.
        #expect(limiter.allow(address: "10.0.0.2", nowNanos: t))
    }

    @Test func refillsAtConfiguredRate() {
        let limiter = LimiterBox(perAddressPerMinute: 6, globalPerMinute: 100)   // one token per 10 s
        let t: UInt64 = 5_000 * second
        for _ in 0..<6 { #expect(limiter.allow(address: "a", nowNanos: t)) }
        #expect(!limiter.allow(address: "a", nowNanos: t))
        #expect(!limiter.allow(address: "a", nowNanos: t + 9 * second))
        #expect(limiter.allow(address: "a", nowNanos: t + 10 * second))
        #expect(!limiter.allow(address: "a", nowNanos: t + 10 * second))
        // A full minute later the bucket is full again, but never above capacity.
        let later = t + 10 * second + 600 * second
        for _ in 0..<6 { #expect(limiter.allow(address: "a", nowNanos: later)) }
        #expect(!limiter.allow(address: "a", nowNanos: later))
    }

    @Test func globalLimitAppliesAcrossAddresses() {
        let limiter = LimiterBox(perAddressPerMinute: 10, globalPerMinute: 4)
        let t: UInt64 = 77 * second
        #expect(limiter.allow(address: "a", nowNanos: t))
        #expect(limiter.allow(address: "b", nowNanos: t))
        #expect(limiter.allow(address: "c", nowNanos: t))
        #expect(limiter.allow(address: "d", nowNanos: t))
        #expect(!limiter.allow(address: "e", nowNanos: t))
        #expect(!limiter.allow(address: "a", nowNanos: t))
    }

    @Test func refusedAttemptsDoNotConsumeGlobalBudget() {
        let limiter = LimiterBox(perAddressPerMinute: 1, globalPerMinute: 3)
        let t: UInt64 = 10 * second
        #expect(limiter.allow(address: "flood", nowNanos: t))
        for _ in 0..<100 { #expect(!limiter.allow(address: "flood", nowNanos: t)) }
        // The flooder only used one global token; two remain for others.
        #expect(limiter.allow(address: "x", nowNanos: t))
        #expect(limiter.allow(address: "y", nowNanos: t))
        #expect(!limiter.allow(address: "z", nowNanos: t))
    }

    @Test func nonAdvancingTimeDoesNotRefill() {
        let limiter = LimiterBox(perAddressPerMinute: 1, globalPerMinute: 10)
        #expect(limiter.allow(address: "a", nowNanos: 100 * second))
        #expect(!limiter.allow(address: "a", nowNanos: 50 * second))   // clock went backwards: no refill
        #expect(!limiter.allow(address: "a", nowNanos: 100 * second))
    }

    @Test func zeroOrNegativeConfigurationStillAllowsOne() {
        let limiter = LimiterBox(perAddressPerMinute: 0, globalPerMinute: -5)
        #expect(limiter.allow(address: "a", nowNanos: second))
        #expect(!limiter.allow(address: "a", nowNanos: second))
    }

    @Test func trackedAddressesStayBounded() {
        let limiter = LimiterBox(perAddressPerMinute: 2, globalPerMinute: 1_000_000)
        var t: UInt64 = second
        for i in 0..<(ConnectionRateLimiter.maxTrackedAddresses * 3) {
            _ = limiter.allow(address: "198.51.\(i / 256).\(i % 256)", nowNanos: t)
            t += 1_000   // effectively simultaneous: nothing refills, so pruning must evict the stalest
        }
        #expect(limiter.trackedAddressCount <= ConnectionRateLimiter.maxTrackedAddresses)
    }
}

/// `#expect` cannot call mutating members on a captured value, so tests drive the limiter through a box.
final class LimiterBox {
    var limiter: ConnectionRateLimiter
    init(perAddressPerMinute: Int, globalPerMinute: Int) {
        limiter = ConnectionRateLimiter(perAddressPerMinute: perAddressPerMinute, globalPerMinute: globalPerMinute)
    }
    func allow(address: String, nowNanos: UInt64) -> Bool { limiter.allow(address: address, nowNanos: nowNanos) }
    var trackedAddressCount: Int { limiter.trackedAddressCount }
}
