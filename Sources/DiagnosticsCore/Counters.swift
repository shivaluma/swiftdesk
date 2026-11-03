import Synchronization

/// Thread-safe sliding-window event counter (e.g. frames/sec, bytes/sec).
/// Cheap enough to call from per-frame callbacks: one uncontended lock + ring append.
public final class RateCounter: Sendable {
    private struct State {
        var events: [(t: UInt64, amount: UInt64)] = []
        var head = 0
        var total: UInt64 = 0
    }
    private let window: UInt64
    private let state = Mutex(State())

    /// - Parameter windowNanos: averaging window, default 1 s.
    public init(windowNanos: UInt64 = 1_000_000_000) {
        self.window = windowNanos
    }

    public func record(_ amount: UInt64 = 1, now: UInt64 = MonotonicClock.nowNanos()) {
        state.withLock { s in
            s.events.append((now, amount))
            s.total &+= amount
            Self.trim(&s, now: now, window: window)
        }
    }

    /// Amount per second over the window.
    public func ratePerSecond(now: UInt64 = MonotonicClock.nowNanos()) -> Double {
        state.withLock { s in
            Self.trim(&s, now: now, window: window)
            var sum: UInt64 = 0
            for i in s.head..<s.events.count { sum &+= s.events[i].amount }
            return Double(sum) * 1_000_000_000 / Double(window)
        }
    }

    /// Lifetime total.
    public var total: UInt64 { state.withLock { $0.total } }

    public func reset() { state.withLock { $0 = State() } }

    private static func trim(_ s: inout State, now: UInt64, window: UInt64) {
        let cutoff = now > window ? now - window : 0
        while s.head < s.events.count && s.events[s.head].t < cutoff { s.head += 1 }
        if s.head > 256 && s.head * 2 > s.events.count {
            s.events.removeFirst(s.head)
            s.head = 0
        }
    }
}

/// Thread-safe bounded sample window with mean / percentiles. Used for per-stage latencies.
public final class RollingStats: Sendable {
    public struct Summary: Sendable, Equatable {
        public var count: Int
        public var mean: Double
        public var p50: Double
        public var p95: Double
        public var max: Double
        public static let empty = Summary(count: 0, mean: 0, p50: 0, p95: 0, max: 0)
    }

    private struct State {
        var samples: [Double] = []
        var next = 0
    }
    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 240) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func add(_ value: Double) {
        guard value.isFinite else { return }
        state.withLock { s in
            if s.samples.count < capacity {
                s.samples.append(value)
            } else {
                s.samples[s.next] = value
            }
            s.next = (s.next + 1) % capacity
        }
    }

    public func summary() -> Summary {
        let values = state.withLock { $0.samples }
        return Self.summarize(values)
    }

    public func reset() { state.withLock { $0 = State() } }

    /// Nearest-rank percentiles on a copy; exposed for tests and offline reports.
    public static func summarize(_ values: [Double]) -> Summary {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double {
            let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return Summary(count: sorted.count, mean: mean, p50: pct(0.5), p95: pct(0.95), max: sorted.last!)
    }
}

/// Smoothed RTT estimator (RFC 6298 style EWMA) fed by PING/PONG.
public final class RTTEstimator: Sendable {
    public struct Value: Sendable, Equatable {
        public var latestMillis: Double
        public var smoothedMillis: Double
        public var minMillis: Double
        public var varianceMillis: Double
        public static let none = Value(latestMillis: 0, smoothedMillis: 0, minMillis: 0, varianceMillis: 0)
    }
    private let state = Mutex<Value?>(nil)

    public init() {}

    public func add(sampleMillis rtt: Double) {
        guard rtt.isFinite, rtt >= 0 else { return }
        state.withLock { v in
            guard var cur = v else {
                v = Value(latestMillis: rtt, smoothedMillis: rtt, minMillis: rtt, varianceMillis: rtt / 2)
                return
            }
            cur.varianceMillis = 0.75 * cur.varianceMillis + 0.25 * abs(cur.smoothedMillis - rtt)
            cur.smoothedMillis = 0.875 * cur.smoothedMillis + 0.125 * rtt
            cur.latestMillis = rtt
            cur.minMillis = min(cur.minMillis, rtt)
            v = cur
        }
    }

    public var value: Value { state.withLock { $0 ?? .none } }
    public func reset() { state.withLock { $0 = nil } }
}
