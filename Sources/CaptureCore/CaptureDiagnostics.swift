import Synchronization
import DiagnosticsCore

/// Per-capturer counters for the Troubleshooter persona: shows whether a low FPS is the desktop being idle
/// (ScreenCaptureKit only produces frames on change), the display blanking, or a consumer blocking the callback.
///
/// Every recording method is lock-free (relaxed atomics) except the two `RollingStats`/`RateCounter` updates, which
/// take one uncontended `Mutex` each — cheap enough for the capture callback. Read with `snapshot()` off the hot path.
public final class CaptureDiagnostics: Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// `.complete` frames handed to `onFrame`.
        public var framesDelivered: UInt64 = 0
        /// No new frame because nothing on the display changed (expected on a static desktop).
        public var framesIdle: UInt64 = 0
        public var framesBlank: UInt64 = 0
        public var framesSuspended: UInt64 = 0
        public var framesStarted: UInt64 = 0
        public var framesStopped: UInt64 = 0
        /// Sample buffers without a readable `SCStreamFrameInfo.status` attachment (dropped).
        public var framesWithoutStatus: UInt64 = 0
        /// `.complete` sample buffers without an image buffer (dropped).
        public var framesWithoutImage: UInt64 = 0
        /// Complete frames that arrived while the capturer was stopping (dropped).
        public var framesAfterStop: UInt64 = 0
        /// Delivered frames per second over the last second.
        public var deliveredFPS: Double = 0
        /// Window-server display time → capture callback, milliseconds.
        public var displayToCallbackMillis: RollingStats.Summary = .empty
        /// Time spent inside `onFrame`, milliseconds. Should stay well under 1 ms; anything larger means a consumer
        /// is blocking the capture queue and the surface pool will back up.
        public var onFrameMillis: RollingStats.Summary = .empty

        public init() {}
    }

    private let delivered = Atomic<UInt64>(0)
    private let idle = Atomic<UInt64>(0)
    private let blank = Atomic<UInt64>(0)
    private let suspended = Atomic<UInt64>(0)
    private let started = Atomic<UInt64>(0)
    private let stopped = Atomic<UInt64>(0)
    private let withoutStatus = Atomic<UInt64>(0)
    private let withoutImage = Atomic<UInt64>(0)
    private let afterStop = Atomic<UInt64>(0)
    private let rate = RateCounter()
    private let displayToCallback = RollingStats()
    private let onFrameDuration = RollingStats()

    public init() {}

    func recordStatus(_ status: CaptureFrameStatus) {
        switch status {
        case .complete: break   // counted on delivery
        case .idle: idle.wrappingAdd(1, ordering: .relaxed)
        case .blank: blank.wrappingAdd(1, ordering: .relaxed)
        case .suspended: suspended.wrappingAdd(1, ordering: .relaxed)
        case .started: started.wrappingAdd(1, ordering: .relaxed)
        case .stopped: stopped.wrappingAdd(1, ordering: .relaxed)
        case .missing, .unknown: withoutStatus.wrappingAdd(1, ordering: .relaxed)
        }
    }

    func recordMissingImage() { withoutImage.wrappingAdd(1, ordering: .relaxed) }
    func recordAfterStop() { afterStop.wrappingAdd(1, ordering: .relaxed) }

    func recordDelivered(captureNanos: UInt64, displayNanos: UInt64, callbackDoneNanos: UInt64) {
        delivered.wrappingAdd(1, ordering: .relaxed)
        rate.record(1, now: captureNanos)
        if displayNanos != 0, displayNanos <= captureNanos {
            displayToCallback.add(MonotonicClock.millis(captureNanos - displayNanos))
        }
        if callbackDoneNanos >= captureNanos {
            onFrameDuration.add(MonotonicClock.millis(callbackDoneNanos - captureNanos))
        }
    }

    public func snapshot(now: UInt64 = MonotonicClock.nowNanos()) -> Snapshot {
        var s = Snapshot()
        s.framesDelivered = delivered.load(ordering: .relaxed)
        s.framesIdle = idle.load(ordering: .relaxed)
        s.framesBlank = blank.load(ordering: .relaxed)
        s.framesSuspended = suspended.load(ordering: .relaxed)
        s.framesStarted = started.load(ordering: .relaxed)
        s.framesStopped = stopped.load(ordering: .relaxed)
        s.framesWithoutStatus = withoutStatus.load(ordering: .relaxed)
        s.framesWithoutImage = withoutImage.load(ordering: .relaxed)
        s.framesAfterStop = afterStop.load(ordering: .relaxed)
        s.deliveredFPS = rate.ratePerSecond(now: now)
        s.displayToCallbackMillis = displayToCallback.summary()
        s.onFrameMillis = onFrameDuration.summary()
        return s
    }

    public func reset() {
        // Atomics are non-copyable, so they cannot be iterated as a collection.
        delivered.store(0, ordering: .relaxed)
        idle.store(0, ordering: .relaxed)
        blank.store(0, ordering: .relaxed)
        suspended.store(0, ordering: .relaxed)
        started.store(0, ordering: .relaxed)
        stopped.store(0, ordering: .relaxed)
        withoutStatus.store(0, ordering: .relaxed)
        withoutImage.store(0, ordering: .relaxed)
        afterStop.store(0, ordering: .relaxed)
        rate.reset()
        displayToCallback.reset()
        onFrameDuration.reset()
    }
}
