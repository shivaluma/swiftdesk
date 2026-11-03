import Darwin
import Foundation
import Testing
@testable import DiagnosticsCore

@Suite struct MonotonicClockTests {
    @Test func isMonotonicAndUsesUptimeRawBase() {
        let a = MonotonicClock.nowNanos()
        let b = MonotonicClock.nowNanos()
        #expect(b >= a)
        // Same base as CLOCK_UPTIME_RAW / mach_absolute_time: the two readings must be within a few ms.
        let mach = MonotonicClock.nanos(fromMachTicks: mach_absolute_time())
        let now = MonotonicClock.nowNanos()
        let diff = now > mach ? now - mach : mach - now
        #expect(diff < 5_000_000)
    }

    @Test func millisHelpers() {
        #expect(MonotonicClock.millis(1_500_000) == 1.5)
        #expect(MonotonicClock.elapsedMillis(since: 2_000_000, now: 5_000_000) == 3)
        // A start in the future (clock domains mixed up) never yields a negative or wrapped value.
        #expect(MonotonicClock.elapsedMillis(since: 5_000_000, now: 2_000_000) == 0)
    }
}

@Suite struct RateCounterTests {
    @Test func ratePerSecondOverWindow() {
        let counter = RateCounter(windowNanos: 1_000_000_000)
        let base: UInt64 = 10_000_000_000
        for i in 0..<60 {
            counter.record(1, now: base + UInt64(i) * 16_666_667)
        }
        let rate = counter.ratePerSecond(now: base + 999_000_000)
        #expect(rate == 60)
        #expect(counter.total == 60)
    }

    @Test func oldEventsLeaveTheWindow() {
        let counter = RateCounter(windowNanos: 1_000_000_000)
        let base: UInt64 = 10_000_000_000
        counter.record(1_000, now: base)
        counter.record(500, now: base + 900_000_000)
        #expect(counter.ratePerSecond(now: base + 950_000_000) == 1_500)
        #expect(counter.ratePerSecond(now: base + 1_500_000_000) == 500)
        #expect(counter.ratePerSecond(now: base + 3_000_000_000) == 0)
        #expect(counter.total == 1_500)
    }

    @Test func longRunsStayBoundedAndCorrect() {
        // 10 minutes at 60 fps exercises the compaction path many times.
        let counter = RateCounter(windowNanos: 1_000_000_000)
        let step: UInt64 = 16_666_667
        var now: UInt64 = 1_000_000_000
        for _ in 0..<36_000 {
            now += step
            counter.record(1, now: now)
        }
        let rate = counter.ratePerSecond(now: now)
        #expect(rate >= 59 && rate <= 61)
        #expect(counter.total == 36_000)
        counter.reset()
        #expect(counter.total == 0)
        #expect(counter.ratePerSecond(now: now) == 0)
    }

    @Test func concurrentRecordingIsSafe() async {
        let counter = RateCounter(windowNanos: 60_000_000_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<1_000 { counter.record() } }
            }
        }
        #expect(counter.total == 8_000)
    }
}

@Suite struct RollingStatsTests {
    @Test func nearestRankPercentiles() {
        let s = RollingStats.summarize((1...100).map(Double.init))
        #expect(s.count == 100)
        #expect(s.mean == 50.5)
        #expect(s.p50 == 50)
        #expect(s.p95 == 95)
        #expect(s.max == 100)
    }

    @Test func emptyAndSingle() {
        #expect(RollingStats.summarize([]) == .empty)
        let one = RollingStats.summarize([7])
        #expect(one.p50 == 7 && one.p95 == 7 && one.max == 7 && one.count == 1)
    }

    @Test func ringKeepsOnlyNewestSamples() {
        let stats = RollingStats(capacity: 4)
        for v in [100.0, 100, 100, 100, 1, 2, 3, 4] { stats.add(v) }
        let s = stats.summary()
        #expect(s.count == 4)
        #expect(s.max == 4)
        #expect(s.mean == 2.5)
    }

    @Test func nonFiniteSamplesAreIgnored() {
        let stats = RollingStats()
        stats.add(.nan)
        stats.add(.infinity)
        stats.add(3)
        #expect(stats.summary().count == 1)
        stats.reset()
        #expect(stats.summary() == .empty)
    }
}

@Suite struct RTTEstimatorTests {
    @Test func firstSampleSeedsEstimator() {
        let rtt = RTTEstimator()
        #expect(rtt.value == .none)
        rtt.add(sampleMillis: 10)
        #expect(rtt.value.smoothedMillis == 10)
        #expect(rtt.value.minMillis == 10)
        #expect(rtt.value.varianceMillis == 5)
    }

    @Test func ewmaFollowsRFC6298Weights() {
        let rtt = RTTEstimator()
        rtt.add(sampleMillis: 10)
        rtt.add(sampleMillis: 18)
        let v = rtt.value
        #expect(v.latestMillis == 18)
        #expect(v.smoothedMillis == 0.875 * 10 + 0.125 * 18)
        #expect(v.varianceMillis == 0.75 * 5 + 0.25 * 8)
        #expect(v.minMillis == 10)
    }

    @Test func rejectsInvalidSamples() {
        let rtt = RTTEstimator()
        rtt.add(sampleMillis: -1)
        rtt.add(sampleMillis: .nan)
        #expect(rtt.value == .none)
        rtt.add(sampleMillis: 2)
        rtt.reset()
        #expect(rtt.value == .none)
    }
}

@Suite struct MetricsSnapshotTests {
    @Test func defaultsAreEmpty() {
        let m = MetricsSnapshot()
        #expect(m.fps == 0 && m.bitrateKbps == 0 && m.packetLossPercent == 0)
        #expect(m.captureToEncodeDone == .empty && m.decodeToPresent == .empty)
        #expect(m.hardwareEncoder == nil && m.pathDescription.isEmpty)
    }

    @Test func signpostsAndLoggersAreUsable() {
        // Smoke test: emitting must not crash and loggers share one subsystem.
        PipelineSignpost.capture(frame: 1)
        PipelineSignpost.encoded(frame: 1, bytes: 10, keyframe: true)
        PipelineSignpost.input(seq: 1)
        #expect(PipelineSignpost.subsystem == "com.swiftdesk.app")
    }
}
