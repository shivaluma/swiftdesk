/// Token-bucket connection limiter: one bucket per remote IP plus one global bucket.
///
/// Why: every accepted connection costs a TLS handshake and may surface a consent prompt to the host operator,
/// so an unauthenticated peer must not be able to spam either (PRD §5 "rate limit connection attempts").
/// Applied before the handshake starts. Pure value type; time is injected for deterministic tests.
public struct ConnectionRateLimiter: Sendable {
    private struct Bucket: Sendable {
        var tokens: Double
        var updatedAt: UInt64
    }

    private let perAddressCapacity: Double
    private let globalCapacity: Double
    private let perAddressRatePerNano: Double
    private let globalRatePerNano: Double
    private var global: Bucket?
    private var buckets: [String: Bucket] = [:]

    /// Upper bound on tracked addresses; full (idle) buckets are pruned first, then the stalest.
    static let maxTrackedAddresses = 1024

    public init(perAddressPerMinute: Int = 6, globalPerMinute: Int = 30) {
        perAddressCapacity = Double(max(1, perAddressPerMinute))
        globalCapacity = Double(max(1, globalPerMinute))
        perAddressRatePerNano = perAddressCapacity / 60e9
        globalRatePerNano = globalCapacity / 60e9
    }

    /// Number of addresses currently tracked (for tests/diagnostics).
    public var trackedAddressCount: Int { buckets.count }

    /// Consumes one token from both buckets if both have one; otherwise refuses without consuming anything,
    /// so a flooding address cannot drain the global budget for everyone else beyond its own allowance.
    public mutating func allow(address: String, nowNanos: UInt64) -> Bool {
        var g = global ?? Bucket(tokens: globalCapacity, updatedAt: nowNanos)
        refill(&g, now: nowNanos, capacity: globalCapacity, rate: globalRatePerNano)
        var b = buckets[address] ?? Bucket(tokens: perAddressCapacity, updatedAt: nowNanos)
        refill(&b, now: nowNanos, capacity: perAddressCapacity, rate: perAddressRatePerNano)

        let allowed = g.tokens >= 1 && b.tokens >= 1
        if allowed {
            g.tokens -= 1
            b.tokens -= 1
        }
        global = g
        buckets[address] = b
        if buckets.count > Self.maxTrackedAddresses { prune(now: nowNanos) }
        return allowed
    }

    private func refill(_ bucket: inout Bucket, now: UInt64, capacity: Double, rate: Double) {
        guard now > bucket.updatedAt else { return }   // monotonic clock; ignore non-advancing time
        bucket.tokens = min(capacity, bucket.tokens + Double(now - bucket.updatedAt) * rate)
        bucket.updatedAt = now
    }

    private mutating func prune(now: UInt64) {
        let capacity = perAddressCapacity
        let rate = perAddressRatePerNano
        buckets = buckets.filter { _, b in
            let elapsed = now > b.updatedAt ? Double(now - b.updatedAt) : 0
            return b.tokens + elapsed * rate < capacity   // keep only buckets that still restrict something
        }
        if buckets.count > Self.maxTrackedAddresses {
            let stalest = buckets.sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(buckets.count - Self.maxTrackedAddresses)
            for (key, _) in stalest { buckets.removeValue(forKey: key) }
        }
    }
}
