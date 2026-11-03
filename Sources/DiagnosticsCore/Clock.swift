import Darwin

/// Monotonic time source shared by every pipeline stage.
///
/// Uses `CLOCK_UPTIME_RAW` (same base as `mach_absolute_time`, `CMClockGetHostTimeClock`
/// and CoreVideo host time) so timestamps from capture, codec and Metal callbacks are comparable
/// on one machine. Values are NOT comparable across machines.
public enum MonotonicClock {
    @inline(__always)
    public static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Converts `mach_absolute_time` ticks (e.g. `CVTimeStamp.hostTime`, `CMClockGetHostTimeClock`
    /// timestamps converted with `CMClockConvertHostTimeToSystemUnits`) to nanoseconds.
    public static func nanos(fromMachTicks ticks: UInt64) -> UInt64 {
        let info = timebase
        return ticks &* UInt64(info.numer) / UInt64(info.denom)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    @inline(__always)
    public static func millis(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000 }

    @inline(__always)
    public static func elapsedMillis(since start: UInt64, now: UInt64 = MonotonicClock.nowNanos()) -> Double {
        now >= start ? Double(now - start) / 1_000_000 : 0
    }
}
