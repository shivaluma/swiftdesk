import DiagnosticsCore
import Foundation
import Synchronization

/// SplitMix64: tiny, fast, statistically solid for simulation, and — unlike `SystemRandomNumberGenerator` —
/// seedable, so a lossy run drops exactly the same datagrams every time and regressions are comparable.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) with 53 bits of precision.
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

/// Independent (Bernoulli) datagram loss with a fixed seed.
///
/// Uniform random loss is the simplest model that exercises the reassembly → gate → keyframe-request path; real
/// Wi-Fi loss is bursty, which this deliberately does not model (a burst usually costs one frame, so uniform loss is
/// the harsher case for frame loss at a given packet loss rate).
struct LossSimulator: Sendable {
    let probability: Double
    private var rng: SplitMix64

    init(lossPercent: Double, seed: UInt64) {
        probability = min(max(lossPercent / 100, 0), 1)
        rng = SplitMix64(seed: seed)
    }

    /// True if this datagram should be dropped. Never consumes randomness when loss is disabled, so a 0 % run has no
    /// simulator cost at all.
    mutating func shouldDrop() -> Bool {
        guard probability > 0 else { return false }
        return rng.nextUnitDouble() < probability
    }
}

/// Unbounded-per-run latency sample store (milliseconds).
///
/// `RollingStats` keeps only a sliding window, which is right for a live UI but wrong for a bench report that must
/// summarize the whole run. Capacity is reserved up front from the expected frame count, so appends on the hot path do
/// not reallocate; one uncontended `Mutex` makes the final read from the main thread safe.
final class SampleSeries: Sendable {
    private let samples: Mutex<[Double]>

    init(expected: Int) {
        var storage: [Double] = []
        storage.reserveCapacity(max(expected, 16))
        samples = Mutex(storage)
    }

    @inline(__always)
    func add(nanos: UInt64) {
        let ms = Double(nanos) / 1_000_000
        samples.withLock { $0.append(ms) }
    }

    /// Adds `end - start` (clamped at 0 if clocks are ever out of order, which would indicate a stamping bug).
    @inline(__always)
    func add(from start: UInt64, to end: UInt64) {
        add(nanos: end >= start ? end - start : 0)
    }

    func addMillis(_ ms: Double) {
        guard ms.isFinite else { return }
        samples.withLock { $0.append(ms) }
    }

    var count: Int { samples.withLock { $0.count } }

    /// Nearest-rank percentiles, identical to `RollingStats.summarize` so bench and in-app numbers mean the same thing.
    func summary() -> RollingStats.Summary {
        RollingStats.summarize(samples.withLock { $0 })
    }

    /// Nearest-rank percentile `p` in 0...1 (same rank rule as `RollingStats`); 0 when empty. p99 separates a
    /// one-off warm-up spike (session creation lands in `max`) from a recurring tail.
    func percentile(_ p: Double) -> Double {
        Self.percentile(samples.withLock { $0 }, p)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// Small atomic counter wrapper so counters read naturally at call sites.
final class Counter: Sendable {
    private let value = Atomic<UInt64>(0)
    init() {}
    @inline(__always) func add(_ n: UInt64 = 1) { value.add(n, ordering: .relaxed) }
    var load: UInt64 { value.load(ordering: .relaxed) }
}
