import CaptureCore
import CoreGraphics
import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization

/// A `VideoSource` that generates moving 420v frames, standing in for ScreenCaptureKit.
///
/// Used by tests (no Screen Recording permission needed), by the Loopback screen's "synthetic" mode and for
/// benchmarking. It mirrors what SCK hands the encoder so the rest of the pipeline takes the production path:
/// - IOSurface-backed, Metal-compatible `420v` buffers from a `CVPixelBufferPool` capped at `poolSize` (the cap is
///   `kCVPixelBufferPoolAllocationThresholdKey`, so a stalled consumer makes ticks skip — like a starved SCK pool —
///   instead of growing memory);
/// - a strict `DispatchSourceTimer` on a dedicated serial `.userInteractive` queue (non-strict timers get coalesced and
///   deliver bursts, measured by the RenderCore agent at ≈12 of 60 fps);
/// - content that changes every frame (scrolling bands + a moving box), so the encoder produces real P-frames.
///
/// Synchronization: generation state is confined to `queue`; callbacks and the timer handle sit behind `Mutex`es
/// (closures as struct fields, never a bare `Mutex<Closure?>` — see CaptureCore's note on thunk growth).
public final class SyntheticVideoSource: VideoSource, @unchecked Sendable {
    public enum SourceError: Error, Equatable, Sendable {
        case poolCreationFailed(Int32)
    }

    private struct Callbacks {
        var onFrame: (@Sendable (CapturedFrame) -> Void)?
        var onStopped: (@Sendable ((any Error)?) -> Void)?
    }

    private struct Shared {
        var config: CaptureConfig
        var size: (width: Int, height: Int)
        var timer: (any DispatchSourceTimer)?
        var sourceSize: (width: Int, height: Int)
        var displayFrame: CGRect
    }

    /// The captured area in global points; changes only through `simulateDisplayChange`.
    public var displayFrame: CGRect { shared.withLock { $0.displayFrame } }
    /// The full-resolution size the capture config is fitted into (like a display's pixel size).
    public var sourceSize: (width: Int, height: Int) { shared.withLock { $0.sourceSize } }
    public let poolSize: Int

    private let queue = DispatchQueue(label: "com.swiftdesk.session.synthetic", qos: .userInteractive)
    private let callbacks = Mutex(Callbacks())
    private let shared: Mutex<Shared>
    /// `{AllocationThreshold: poolSize}`, built once (not per tick).
    private let auxAttributes: CFDictionary
    private let generated = Atomic<UInt64>(0)
    private let skipped = Atomic<UInt64>(0)

    // Confined to `queue`.
    private var pool: CVPixelBufferPool?
    private var poolSizeKey: (width: Int, height: Int) = (0, 0)
    private var sequence: UInt64 = 0
    private var startNanos: UInt64 = 0

    /// - Parameters:
    ///   - sourceWidth/sourceHeight: the "display" resolution; `config` bounds are fitted into it like SCK does.
    ///   - displayFrame: global point rect reported to the input mapper.
    public init(sourceWidth: Int = 1920, sourceHeight: Int = 1080, config: CaptureConfig = CaptureConfig(),
                displayFrame: CGRect? = nil, poolSize: Int = 4) {
        let sourceSize = (max(2, sourceWidth), max(2, sourceHeight))
        self.poolSize = max(2, poolSize)
        self.auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: max(2, poolSize)] as CFDictionary
        let sanitized = config.sanitized
        let size = CaptureGeometry.fit(sourceWidth: sourceSize.0, sourceHeight: sourceSize.1,
                                       maxWidth: sanitized.maxWidth, maxHeight: sanitized.maxHeight)
        self.shared = Mutex(Shared(config: sanitized, size: size, timer: nil, sourceSize: sourceSize,
                                   displayFrame: displayFrame
                                       ?? CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)))
    }

    deinit {
        shared.withLock { $0.timer?.cancel() }
    }

    public var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { callbacks.withLock { $0.onFrame } }
        set { callbacks.withLock { $0.onFrame = newValue } }
    }

    /// Never fired by this source on its own (it cannot be revoked); `simulateSystemStop` exercises the path.
    public var onStopped: (@Sendable ((any Error)?) -> Void)? {
        get { callbacks.withLock { $0.onStopped } }
        set { callbacks.withLock { $0.onStopped = newValue } }
    }

    public var outputSize: (width: Int, height: Int) { shared.withLock { $0.size } }

    public func predictedOutputSize(for config: CaptureConfig) -> (width: Int, height: Int) {
        let sanitized = config.sanitized
        let source = sourceSize
        return CaptureGeometry.fit(sourceWidth: source.width, sourceHeight: source.height,
                                   maxWidth: sanitized.maxWidth, maxHeight: sanitized.maxHeight)
    }
    public var config: CaptureConfig { shared.withLock { $0.config } }
    public var isRunning: Bool { shared.withLock { $0.timer != nil } }
    /// Frames delivered to `onFrame`.
    public var framesGenerated: UInt64 { generated.load(ordering: .relaxed) }
    /// Ticks skipped because every pool buffer was still held downstream.
    public var framesSkipped: UInt64 { skipped.load(ordering: .relaxed) }

    public func start() async throws {
        try queue.sync { try preparePool() }
        shared.withLock { s in
            guard s.timer == nil else { return }
            s.timer = makeTimer(fps: s.config.fps)
        }
    }

    public func update(config newConfig: CaptureConfig) async throws {
        let sanitized = newConfig.sanitized
        let size = predictedOutputSize(for: sanitized)
        let restart = shared.withLock { s -> Bool in
            let fpsChanged = s.config.fps != sanitized.fps
            s.config = sanitized
            s.size = size
            guard fpsChanged, let timer = s.timer else { return false }
            timer.cancel()
            s.timer = nil
            return true
        }
        try queue.sync { try preparePool() }
        if restart {
            shared.withLock { s in
                if s.timer == nil { s.timer = makeTimer(fps: s.config.fps) }
            }
        }
    }

    /// Cancels the timer and waits for an in-progress tick, so `onFrame` is not called after this returns.
    public func stop() async {
        let timer = shared.withLock { s -> (any DispatchSourceTimer)? in
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        queue.sync {}
    }

    /// Test hook: the "display" changes resolution or arrangement mid-session. Like ScreenCaptureKit, the output keeps
    /// its configured size until the next `update(config:)`, which fits the config into the new source size.
    public func simulateDisplayChange(sourceWidth: Int, sourceHeight: Int, displayFrame: CGRect) {
        shared.withLock { s in
            s.sourceSize = (max(2, sourceWidth), max(2, sourceHeight))
            s.displayFrame = displayFrame
        }
    }

    /// Test hook: behaves like ScreenCaptureKit stopping the stream on its own (e.g. permission revoked).
    public func simulateSystemStop(error: (any Error)? = nil) {
        let timer = shared.withLock { s -> (any DispatchSourceTimer)? in
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        queue.async { [self] in callbacks.withLock { $0.onStopped }?(error) }
    }

    // MARK: Queue-confined

    private func makeTimer(fps: Int) -> any DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1_000_000_000 / max(fps, 1)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        return timer
    }

    private func preparePool() throws {
        let size = shared.withLock { $0.size }
        if pool != nil, poolSizeKey == size { return }
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVBufferPropagatedAttachmentsKey as String: [
                kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            ] as [String: Any],
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: poolSize]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                                             pixelAttributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw SourceError.poolCreationFailed(status) }
        pool = created
        poolSizeKey = size
    }

    private func tick() {
        guard let pool else { return }
        let size = poolSizeKey
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            skipped.add(1, ordering: .relaxed)
            return
        }
        sequence &+= 1
        Self.fill(buffer, width: size.width, height: size.height, frameIndex: sequence)
        let now = MonotonicClock.nowNanos()
        if startNanos == 0 { startNanos = now }
        // Presentation time on the host clock in microseconds keeps timestamps monotonic across fps changes.
        let pts = CMTime(value: CMTimeValue((now - startNanos) / 1_000), timescale: 1_000_000)
        let frame = CapturedFrame(pixelBuffer: buffer, presentationTime: pts, captureNanos: now, sequence: sequence)
        generated.add(1, ordering: .relaxed)
        // Same milestone ScreenCapturer emits at the start of its callback, so traces look alike for both sources.
        PipelineSignpost.capture(frame: sequence)
        callbacks.withLock { $0.onFrame }?(frame)
    }

    /// Scrolling horizontal luma bands, flat chroma and a bright box moving diagonally. Cheap (row memsets) but
    /// different every frame, so every frame is encoded as real motion.
    static func fill(_ buffer: CVPixelBuffer, width: Int, height: Int, frameIndex: UInt64) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let f = Int(truncatingIfNeeded: frameIndex)

        for y in 0..<height {
            let band = ((y + f * 3) / 24) & 7
            memset(yBase + y * yStride, Int32(40 + band * 22), width)
        }
        for y in 0..<(height / 2) {
            memset(uvBase + y * uvStride, 128, width)
        }
        let box = max(16, (min(width, height) / 6) & ~1)
        let bx = triangle(f * 7, span: width - box) & ~1
        let by = triangle(f * 5, span: height - box) & ~1
        for y in by..<(by + box) {
            memset(yBase + y * yStride + bx, 235, box)
        }
        for y in (by / 2)..<((by + box) / 2) {
            let row = (uvBase + y * uvStride + bx).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < box {
                row[x] = 90
                row[x + 1] = 240
                x += 2
            }
        }
    }

    static func triangle(_ t: Int, span: Int) -> Int {
        guard span > 0 else { return 0 }
        let period = span * 2
        let p = ((t % period) + period) % period
        return p <= span ? p : period - p
    }
}
