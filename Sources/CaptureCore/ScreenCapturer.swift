@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import Dispatch
import Foundation
import Synchronization
import DiagnosticsCore

/// Errors raised by `ScreenCapturer` itself (ScreenCaptureKit errors are passed through unchanged).
public enum CaptureError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The display is not in `SCShareableContent` (unplugged, or not capturable).
    case displayNotFound(CGDirectDisplayID)
    /// The system stopped the stream while `start()` was still waiting for it to begin.
    case stoppedDuringStart

    public var description: String {
        switch self {
        case .displayNotFound(let id): "Display \(id) is not available for capture."
        case .stoppedDuringStart: "The capture stream was stopped by the system while starting."
        }
    }

    /// True if `error` means the user has not granted Screen Recording (ScreenCaptureKit `userDeclined`).
    public static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }
}

/// Streams one display through ScreenCaptureKit and hands each new, complete frame to `onFrame`.
///
/// Threading: sample buffers arrive on a private serial `.userInteractive` queue (never the main thread, so UI work
/// cannot delay capture). `onFrame` is called synchronously on that queue — no `Task`, actor hop or extra queue per
/// frame — and must return quickly (hand the buffer to the non-blocking encoder and return); a slow consumer holds
/// one of only three pool surfaces and stalls capture.
///
/// Synchronization: lifecycle calls (`start`, `update`, `stop`) are serialized by an async gate so they never
/// interleave across `await`s. Narrow shared state (stream, config, output size, callbacks) lives in `Mutex`es.
/// The system-stop delegate path only touches that state, never the gate, so it cannot deadlock with `stop()`.
public final class ScreenCapturer: @unchecked Sendable {
    /// SCStream is not annotated Sendable; its methods are documented to be callable from any thread, and every
    /// lifecycle call on it is serialized by `lifecycle`.
    private struct StreamBox: @unchecked Sendable {
        let stream: SCStream
    }

    private struct State {
        var config: CaptureConfig
        var outputSize: (width: Int, height: Int)
        var appliedSettings: CaptureStreamSettings?
        var stream: StreamBox?
    }

    public let display: DisplayInfo
    /// Counters for the diagnostics panel; read with `diagnostics.snapshot()`.
    public let diagnostics: CaptureDiagnostics

    private let state: Mutex<State>
    private let stoppedHandler = Mutex<StopCallbackBox?>(nil)
    private let lifecycle = AsyncSerialGate()
    private let deliverer: FrameDeliverer
    private let output: StreamOutput
    /// `.workItem` autorelease frequency drains each callback's autorelease pool immediately, so sample buffers (and
    /// their IOSurfaces) return to ScreenCaptureKit's small pool as soon as the consumer lets go.
    private let sampleQueue = DispatchQueue(label: "com.swiftdesk.capture.samples", qos: .userInteractive,
                                            autoreleaseFrequency: .workItem)

    // MARK: Display enumeration

    /// Displays ScreenCaptureKit can capture, enriched with CoreGraphics geometry and `NSScreen` names.
    /// Requires Screen Recording permission (ScreenCaptureKit throws `userDeclined` otherwise). Use
    /// `DisplayInfo.activeDisplays()` to list displays without touching permissions.
    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let shareable: [(id: CGDirectDisplayID, frame: CGRect, width: Int, height: Int)] =
            content.displays.map { ($0.displayID, $0.frame, $0.width, $0.height) }
        let names = await MainActor.run { DisplayInfo.screenNames() }
        let main = CGMainDisplayID()
        return shareable
            .map { entry in
                DisplayInfo.make(id: entry.id, name: names[entry.id])
                    // No CG mode (e.g. mid-reconfiguration): fall back to SCK's point geometry.
                    ?? DisplayInfo(id: entry.id, name: names[entry.id] ?? DisplayInfo.fallbackName(for: entry.id),
                                   frame: entry.frame, pixelWidth: entry.width, pixelHeight: entry.height)
            }
            .sorted { lhs, rhs in lhs.id == main && rhs.id != main }
    }

    // MARK: Lifecycle

    public init(display: DisplayInfo, config: CaptureConfig) {
        self.display = display
        let diagnostics = CaptureDiagnostics()
        self.diagnostics = diagnostics
        let deliverer = FrameDeliverer(diagnostics: diagnostics)
        self.deliverer = deliverer
        self.output = StreamOutput(deliverer: deliverer)
        let predicted = CaptureStreamSettings(config: config, pixelWidth: display.pixelWidth,
                                              pixelHeight: display.pixelHeight, pointSize: display.frame.size)
        self.state = Mutex(State(config: config, outputSize: (predicted.width, predicted.height),
                                 appliedSettings: nil, stream: nil))
        output.owner = self
    }

    deinit {
        // Best effort if the owner forgot stop(): never leave a stream (and the system recording indicator) running.
        if let box = state.withLock({ $0.stream }) {
            box.stream.stopCapture(completionHandler: nil)
        }
    }

    /// Called synchronously on the capture queue for every `.complete` frame. Must not block.
    public var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { deliverer.frameHandler }
        set { deliverer.frameHandler = newValue }
    }

    /// Called when the system stops the stream (permission revoked, display disconnected, user stopped it from the
    /// menu bar). Not called for `stop()`. After it fires the capturer is idle and `start()` may be called again.
    public var onStopped: (@Sendable ((any Error)?) -> Void)? {
        get { stoppedHandler.withLock { $0 }?.call }
        set {
            let box = newValue.map(StopCallbackBox.init)
            stoppedHandler.withLock { $0 = box }
        }
    }

    /// Size of the frames the stream produces (or will produce once started).
    /// Frames already in flight when `update(config:)` returns may still have the previous size; consumers that
    /// care (the encoder) should check `CapturedFrame.width/height`.
    public private(set) var outputSize: (width: Int, height: Int) {
        get { state.withLock { $0.outputSize } }
        set { state.withLock { $0.outputSize = newValue } }
    }

    /// The configuration as last passed to `init` or `update(config:)` (before sanitizing).
    public var config: CaptureConfig { state.withLock { $0.config } }

    /// The ScreenCaptureKit values currently applied, or nil while stopped.
    public var appliedSettings: CaptureStreamSettings? { state.withLock { $0.appliedSettings } }

    public var isRunning: Bool { state.withLock { $0.stream != nil } }

    /// Starts capturing. No-op if already running. Throws ScreenCaptureKit errors (e.g. `userDeclined` without
    /// Screen Recording permission — see `CaptureError.isPermissionDenied`) or `CaptureError`.
    public func start() async throws {
        await lifecycle.acquire()
        defer { lifecycle.release() }
        if isRunning { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CaptureError.displayNotFound(display.id)
        }
        let settings = currentSettings(for: config)
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: settings.makeConfiguration(), delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        let box = StreamBox(stream: stream)
        // Publish before starting so a system stop during startup is attributed to this stream.
        state.withLock { s in
            s.stream = box
            s.appliedSettings = settings
            s.outputSize = (settings.width, settings.height)
        }
        deliverer.isDelivering = true
        do {
            try await stream.startCapture()
        } catch {
            deliverer.isDelivering = false
            state.withLock { s in
                if s.stream?.stream === stream { s.stream = nil; s.appliedSettings = nil }
            }
            try? stream.removeStreamOutput(output, type: .screen)
            throw error
        }
        guard state.withLock({ $0.stream?.stream === stream }) else {
            try? stream.removeStreamOutput(output, type: .screen)
            throw CaptureError.stoppedDuringStart
        }
        Log.media.info("capture started display=\(self.display.id, privacy: .public) size=\(settings.width, privacy: .public)x\(settings.height, privacy: .public) fps=\(settings.fps, privacy: .public) nominal=\(settings.usesNominalResolution, privacy: .public)")
    }

    /// Applies a new configuration. While running this uses `SCStream.updateConfiguration` (no restart, no gap
    /// beyond one frame); while stopped it is stored for the next `start()`. On failure nothing changes.
    public func update(config newConfig: CaptureConfig) async throws {
        await lifecycle.acquire()
        defer { lifecycle.release() }
        let settings = currentSettings(for: newConfig)
        if let box = state.withLock({ $0.stream }) {
            try await box.stream.updateConfiguration(settings.makeConfiguration())
        }
        state.withLock { s in
            s.config = newConfig
            s.outputSize = (settings.width, settings.height)
            if s.stream != nil { s.appliedSettings = settings }
        }
        Log.media.info("capture reconfigured size=\(settings.width, privacy: .public)x\(settings.height, privacy: .public) fps=\(settings.fps, privacy: .public)")
    }

    /// Stops capturing. Idempotent and safe if `start()` failed or the system already stopped the stream.
    /// When it returns, `onFrame` will not be called again until the next `start()`.
    public func stop() async {
        await lifecycle.acquire()
        defer { lifecycle.release() }
        let box = state.withLock { s -> StreamBox? in
            let box = s.stream
            s.stream = nil
            s.appliedSettings = nil
            return box
        }
        deliverer.isDelivering = false
        if let box {
            do {
                try await box.stream.stopCapture()
            } catch {
                // Already stopped by the system between our check and the call; nothing left to do.
                Log.media.debug("capture stopCapture error code=\((error as NSError).code, privacy: .public)")
            }
            try? box.stream.removeStreamOutput(output, type: .screen)
            Log.media.info("capture stopped display=\(self.display.id, privacy: .public)")
        }
        await drainSampleQueue()
    }

    /// Output size `update(config:)` would apply for `config`, from the display's *current* mode (no side effects).
    public func predictedOutputSize(for config: CaptureConfig) -> (width: Int, height: Int) {
        let settings = currentSettings(for: config)
        return (settings.width, settings.height)
    }

    // MARK: Internals

    /// Recomputes settings from the display's *current* mode, since resolution may change during a session.
    private func currentSettings(for config: CaptureConfig) -> CaptureStreamSettings {
        let pixels = DisplayInfo.currentPixelSize(of: display.id) ?? (display.pixelWidth, display.pixelHeight)
        let bounds = CGDisplayBounds(display.id)
        let points = bounds.isEmpty ? display.frame.size : bounds.size
        return CaptureStreamSettings(config: config, pixelWidth: pixels.width, pixelHeight: pixels.height, pointSize: points)
    }

    /// Waits (without blocking a thread) until any sample callback already on the queue has finished.
    private func drainSampleQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async { continuation.resume() }
        }
    }

    fileprivate func streamDidStop(_ stream: SCStream, error: any Error) {
        let wasCurrent = state.withLock { s -> Bool in
            guard s.stream?.stream === stream else { return false }
            s.stream = nil
            s.appliedSettings = nil
            return true
        }
        guard wasCurrent else { return }
        deliverer.isDelivering = false
        try? stream.removeStreamOutput(output, type: .screen)
        let nsError = error as NSError
        Log.media.error("capture stopped by system domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        stoppedHandler.withLock { $0 }?.call(error)
    }
}

/// ScreenCaptureKit's output + delegate target. A separate NSObject so `ScreenCapturer` does not have to be one.
/// `owner` is weak to avoid capturer → stream → output → capturer retain cycles; it is written once in
/// `ScreenCapturer.init` before any stream exists and only read afterwards.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let deliverer: FrameDeliverer
    weak var owner: ScreenCapturer?

    init(deliverer: FrameDeliverer) {
        self.deliverer = deliverer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        deliverer.handle(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        owner?.streamDidStop(stream, error: error)
    }
}

/// FIFO async mutex for lifecycle operations. Unlike an actor, it stays held across `await`s, so `start()`,
/// `update(config:)` and `stop()` run strictly one after another. Never used per frame.
final class AsyncSerialGate: Sendable {
    private struct State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    init() {}

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { s -> Bool in
                if s.locked {
                    s.waiters.append(continuation)
                    return false
                }
                s.locked = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.waiters.isEmpty {
                s.locked = false
                return nil
            }
            return s.waiters.removeFirst()   // ownership passes directly to the next waiter
        }
        next?.resume()
    }
}
