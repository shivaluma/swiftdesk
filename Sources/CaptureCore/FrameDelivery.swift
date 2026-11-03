@preconcurrency import ScreenCaptureKit
import CoreFoundation
import CoreMedia
import Synchronization
import DiagnosticsCore

/// Frame status as read from a sample buffer's `SCStreamFrameInfo.status` attachment.
///
/// Mirrors `SCFrameStatus` plus the two failure cases, so the hot path never needs Swift dictionary bridging.
enum CaptureFrameStatus: Equatable {
    case complete, idle, blank, suspended, started, stopped
    /// No attachments array / no status key.
    case missing
    /// A status value this SDK does not know.
    case unknown(Int)

    init(rawStatus: Int) {
        switch SCFrameStatus(rawValue: rawStatus) {
        case .complete?: self = .complete
        case .idle?: self = .idle
        case .blank?: self = .blank
        case .suspended?: self = .suspended
        case .started?: self = .started
        case .stopped?: self = .stopped
        default: self = .unknown(rawStatus)
        }
    }
}

/// Allocation-free reader for ScreenCaptureKit's per-frame attachments.
///
/// The idiomatic `CMSampleBufferGetSampleAttachmentsArray(...) as? [[SCStreamFrameInfo: Any]]` bridges a CFArray of
/// CFDictionaries into Swift containers on every frame (several heap allocations at 60 Hz). Here the CF objects are
/// read in place with pre-built CFString keys.
enum FrameAttachments {
    // CFString constants are immutable; `nonisolated(unsafe)` only silences the missing Sendable annotation.
    nonisolated(unsafe) static let statusKey: CFString = SCStreamFrameInfo.status.rawValue as CFString
    nonisolated(unsafe) static let displayTimeKey: CFString = SCStreamFrameInfo.displayTime.rawValue as CFString

    struct Values {
        var status: CaptureFrameStatus
        /// `mach_absolute_time` ticks, 0 if absent.
        var displayMachTime: UInt64
    }

    static func read(_ sampleBuffer: CMSampleBuffer) -> Values {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(array) > 0,
              let first = CFArrayGetValueAtIndex(array, 0) else {
            return Values(status: .missing, displayMachTime: 0)
        }
        let dictionary = unsafeBitCast(first, to: CFDictionary.self)
        guard CFGetTypeID(dictionary) == CFDictionaryGetTypeID() else {
            return Values(status: .missing, displayMachTime: 0)
        }
        let status = int64(in: dictionary, key: statusKey).map { CaptureFrameStatus(rawStatus: Int($0)) } ?? .missing
        let displayTime = int64(in: dictionary, key: displayTimeKey).map { UInt64(bitPattern: $0) } ?? 0
        return Values(status: status, displayMachTime: displayTime)
    }

    @inline(__always)
    private static func int64(in dictionary: CFDictionary, key: CFString) -> Int64? {
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        let object = unsafeBitCast(raw, to: CFTypeRef.self)
        guard CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
        var value: Int64 = 0
        guard CFNumberGetValue(unsafeDowncast(object, to: CFNumber.self), .sInt64Type, &value) else { return nil }
        return value
    }
}

/// The per-frame half of `ScreenCapturer`, separated from `SCStream` so it can be unit-tested with synthetic
/// sample buffers (an `SCStream` cannot be created without Screen Recording permission).
///
/// Synchronization: `handle(_:)` runs only on the capturer's serial sample queue, but the sequence counter is an
/// atomic anyway so tests and diagnostics may read it from any thread. `onFrame` lives in a `Mutex` (one
/// uncontended lock per frame) so it can be swapped while the stream runs; `isDelivering` is an atomic flag flipped
/// by start/stop so frames already queued inside ScreenCaptureKit are dropped once `stop()` begins.
final class FrameDeliverer: @unchecked Sendable {
    let diagnostics: CaptureDiagnostics
    private let onFrame = Mutex<FrameCallbackBox?>(nil)
    private let delivering = Atomic<Bool>(false)
    private let sequence = Atomic<UInt64>(0)

    init(diagnostics: CaptureDiagnostics) {
        self.diagnostics = diagnostics
    }

    var frameHandler: (@Sendable (CapturedFrame) -> Void)? {
        get { onFrame.withLock { $0 }?.call }
        set {
            let box = newValue.map(FrameCallbackBox.init)
            onFrame.withLock { $0 = box }
        }
    }

    var isDelivering: Bool {
        get { delivering.load(ordering: .acquiring) }
        set { delivering.store(newValue, ordering: .releasing) }
    }

    var lastSequence: UInt64 { sequence.load(ordering: .relaxed) }

    /// Filters to `.complete` frames, stamps them and calls `onFrame` synchronously. Never blocks.
    /// Returns the delivered frame's sequence number, or nil if the sample was dropped.
    @discardableResult
    func handle(_ sampleBuffer: CMSampleBuffer) -> UInt64? {
        // First action: the host pipeline clock starts when ScreenCaptureKit hands us the surface.
        let captureNanos = MonotonicClock.nowNanos()
        let info = FrameAttachments.read(sampleBuffer)
        diagnostics.recordStatus(info.status)
        guard info.status == .complete else { return nil }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            diagnostics.recordMissingImage()
            return nil
        }
        guard isDelivering else {
            diagnostics.recordAfterStop()
            return nil
        }
        let seq = sequence.wrappingAdd(1, ordering: .relaxed).newValue
        let displayNanos = info.displayMachTime != 0 ? MonotonicClock.nanos(fromMachTicks: info.displayMachTime) : 0
        let frame = CapturedFrame(pixelBuffer: pixelBuffer,
                                  presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                  captureNanos: captureNanos,
                                  sequence: seq,
                                  displayNanos: displayNanos)
        PipelineSignpost.capture(frame: seq)
        if let box = onFrame.withLock({ $0 }) {
            box.call(frame)
        }
        diagnostics.recordDelivered(captureNanos: captureNanos, displayNanos: displayNanos,
                                    callbackDoneNanos: MonotonicClock.nowNanos())
        return seq
    }
}

/// Immutable holder for a `@Sendable` callback stored inside a `Mutex`.
///
/// Storing an optional closure *directly* as a `Mutex` value is unsafe on the hot path: every `withLock { $0 }` read
/// re-wraps the stored closure in another reabstraction thunk and writes it back, so the thunk chain grows by one per
/// frame (a heap allocation each time) and invoking it after ~10⁵–10⁶ reads overflows the stack. Verified with Swift
/// 6.4.2 at -Onone and -O (1M reads then one call → EXC_BAD_ACCESS). A reference to a non-generic final class has no
/// reabstraction, so the box is read without allocating and the closure is never re-wrapped.
final class FrameCallbackBox: Sendable {
    let call: @Sendable (CapturedFrame) -> Void

    init(_ call: @escaping @Sendable (CapturedFrame) -> Void) {
        self.call = call
    }
}

/// See `FrameCallbackBox`.
final class StopCallbackBox: Sendable {
    let call: @Sendable ((any Error)?) -> Void

    init(_ call: @escaping @Sendable ((any Error)?) -> Void) {
        self.call = call
    }
}
