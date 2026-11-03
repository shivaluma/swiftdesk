import CaptureCore
import CoreGraphics
import CoreVideo
import Foundation
import InputCore
import RenderCore
import TransportCore
import WireProtocol

// Dependency-injection seams. Each protocol is the narrowest surface the session logic needs from a lower module,
// so the state machines and pipelines run in tests without Screen Recording / Accessibility permission, a window or
// a real network — while production uses the real classes through the conformances declared here.

/// A stream of captured frames: ScreenCaptureKit in production, `SyntheticVideoSource` in tests and benchmarks.
///
/// Contract (same as `ScreenCapturer`): `onFrame` runs on the source's own serial queue, must not block, and is not
/// called after `stop()` returns; `onStopped` fires only when the *system* ends the stream (permission revoked,
/// display gone), never for `stop()`.
public protocol VideoSource: AnyObject, Sendable {
    var onFrame: (@Sendable (CapturedFrame) -> Void)? { get set }
    var onStopped: (@Sendable ((any Error)?) -> Void)? { get set }
    /// Pixel size of the frames currently produced (after `start()`).
    var outputSize: (width: Int, height: Int) { get }
    /// The captured area in global display coordinates (points) — what normalized input maps onto.
    var displayFrame: CGRect { get }
    /// Pixel size `update(config:)` would produce for `config` on the display as it is *now* (its mode may have
    /// changed since the last update; capture keeps its configured size until then).
    func predictedOutputSize(for config: CaptureConfig) -> (width: Int, height: Int)
    func start() async throws
    func update(config: CaptureConfig) async throws
    func stop() async
}

extension ScreenCapturer: VideoSource {
    /// Re-read from CoreGraphics on every access: the arrangement, main display or scaled resolution may have changed
    /// since `display` was listed, and input must map onto the display's *current* bounds (capture already looks the
    /// display up by id). Falls back to the listed frame while the display is mid-reconfiguration (empty bounds).
    public var displayFrame: CGRect {
        let live = CGDisplayBounds(display.id)
        return live.isEmpty ? display.frame : live
    }
}

/// Where the Host applies the Viewer's input: `HostInputInjector` in production, a recorder in tests.
///
/// Contract (same as `HostInputInjector`): every method is non-blocking and callable from the transport queue;
/// `setAuthorized(false)` releases every held key and button before rejecting further input.
public protocol InputSink: AnyObject, Sendable {
    func handle(_ message: ControlMessage)
    func handlePointer(_ state: PointerState)
    func setAuthorized(_ authorized: Bool)
    func updateDisplayFrame(_ frame: CGRect)
    func releaseAll()
    /// True while authorized and the process can actually post events (Accessibility granted).
    var canInject: Bool { get }
}

extension HostInputInjector: InputSink {}

/// The send side of an established session (`PeerConnection`), abstracted so media pipelines can be tested without
/// sockets. All members are thread-safe and non-blocking.
public protocol SessionTransport: AnyObject, Sendable {
    func sendControl(_ message: ControlMessage)
    /// Unreliable; false means the batch was dropped (backpressure or not ready).
    @discardableResult func sendDatagrams(_ datagrams: [Data]) -> Bool
    /// As `sendDatagrams(_:)`, but also refused when more than `maxQueuedAheadBytes` are already queued ahead of the
    /// batch (nothing queued always admits). The Host uses it to bound send queueing in time, not bytes.
    @discardableResult func sendDatagrams(_ datagrams: [Data], maxQueuedAheadBytes: Int) -> Bool
    var pendingDatagramBytes: Int { get }
    var maxDatagramSize: Int { get }
}

extension SessionTransport {
    /// Transports without a send queue of their own have nothing queued ahead of a batch.
    @discardableResult
    public func sendDatagrams(_ datagrams: [Data], maxQueuedAheadBytes: Int) -> Bool {
        sendDatagrams(datagrams)
    }
}

extension PeerConnection: SessionTransport {}

/// Destination for decoded frames. `MetalVideoView` / `RemoteDisplayView` in the app; a recorder in tests.
///
/// `enqueue` is called on the decode queue for every decoded frame, so conformers must make it thread-safe and
/// non-blocking (newest-frame-wins), as `MetalVideoView.enqueue` is. Not `Sendable`: AppKit views are not, and the
/// session only ever reaches the sink through `FrameSinkSlot`, which documents its synchronization.
public protocol VideoFrameSink: AnyObject {
    func enqueue(_ frame: any RenderableFrame)
}

extension MetalVideoView: VideoFrameSink {}

/// TCC permission checks, injectable because tests cannot (and must not) grant Screen Recording or Accessibility.
public struct PermissionChecker: Sendable {
    public var screenRecordingGranted: @Sendable () -> Bool
    public var accessibilityGranted: @Sendable () -> Bool

    public init(screenRecordingGranted: @escaping @Sendable () -> Bool,
                accessibilityGranted: @escaping @Sendable () -> Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }

    /// The real checks. Neither call prompts: prompting is an explicit user action in the UI.
    public static let system = PermissionChecker(
        screenRecordingGranted: { ScreenCapturePermission.isGranted() },
        accessibilityGranted: { AccessibilityPermission.isTrusted(prompt: false) }
    )
}

/// A decoded frame handed to RenderCore. A wrapper rather than a retroactive conformance of `DecodedFrame`, so
/// RenderCore and CodecCore stay independent of each other.
struct SessionRenderFrame: RenderableFrame, @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let frameId: UInt32
    let decodeDoneNanos: UInt64
}

/// Weak, lock-protected reference to the current frame sink, readable from the decode queue.
///
/// Weak so a closed window's view is released even if the session outlives it; the per-frame cost is one
/// uncontended lock and a weak load.
///
/// 0.1.8: with `keepsLatestFrame` on (the Viewer saves address-book thumbnails), `deliver` also remembers the newest
/// frame — in the same lock, so the per-frame cost is unchanged — and `takeLatestFrame()` hands it over once at session
/// end. This retains one decoded buffer, the one the renderer holds anyway.
final class FrameSinkSlot: @unchecked Sendable {
    private struct Box {
        weak var sink: (any VideoFrameSink)?
        var keepsLatest = false
        var latest: (any RenderableFrame)?
    }
    private let lock = NSLock()
    private var box = Box()

    var sink: (any VideoFrameSink)? {
        get { lock.withLock { box.sink } }
        set { lock.withLock { box.sink = newValue } }
    }

    /// Remember the newest delivered frame. Turning it off drops the one held.
    var keepsLatestFrame: Bool {
        get { lock.withLock { box.keepsLatest } }
        set {
            let dropped: (any RenderableFrame)? = lock.withLock {
                box.keepsLatest = newValue
                guard !newValue else { return nil }
                defer { box.latest = nil }
                return box.latest
            }
            _ = dropped   // released outside the lock
        }
    }

    /// Hands `frame` to the current sink (decode queue). Equivalent to `sink?.enqueue(frame)` plus the bookkeeping.
    func deliver(_ frame: any RenderableFrame) {
        let (sink, replaced): ((any VideoFrameSink)?, (any RenderableFrame)?) = lock.withLock {
            guard box.keepsLatest else { return (box.sink, nil) }
            defer { box.latest = frame }
            return (box.sink, box.latest)
        }
        sink?.enqueue(frame)
        _ = replaced   // the previous frame goes back to the decoder's pool outside the lock
    }

    /// The newest delivered frame since the last take/drop, cleared by this call.
    func takeLatestFrame() -> (any RenderableFrame)? {
        lock.withLock {
            defer { box.latest = nil }
            return box.latest
        }
    }

    func dropLatestFrame() {
        _ = takeLatestFrame()
    }
}

/// Hops a closure to the main actor. For low-rate events (state changes, ≤ 2 Hz metrics) only — never per frame.
@inline(__always)
func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
}

extension ControlMessage {
    /// Sequence number of an input message, nil for everything else. Used only for the `input` signpost, which
    /// carries this number and never the key code, button or position (PRD goal 8).
    var inputSequence: UInt32? {
        switch self {
        case .keyDown(let e), .keyUp(let e): e.seq
        case .mouseDown(let e), .mouseUp(let e): e.seq
        case .mouseMove(let p): p.seq
        case .scroll(let e): e.seq
        default: nil
        }
    }
}
