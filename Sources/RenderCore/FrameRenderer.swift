import CoreGraphics
import CoreVideo
import DiagnosticsCore
import Dispatch
import Metal
import QuartzCore
import Synchronization

/// GPU objects bound to one `MTLDevice`. Rebuilt as a unit if the device stops working.
private struct GPUResources {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: YCbCrPipeline
    let textureCache: PlaneTextureCache
}

/// Latest-frame-wins Metal presenter behind `MetalVideoView`.
///
/// ## Why a render queue triggered by `enqueue` (and not a display link)
/// A display link renders on the *next* vsync callback, so a frame that is decoded just after a callback waits
/// almost a full refresh interval before rendering even starts. Here, `enqueue` schedules (at most one) render
/// pass on a dedicated serial queue immediately; the pass blocks in `CAMetalLayer.nextDrawable()` only when both
/// drawables are in use, and it takes the frame from the slot *after* the drawable is acquired — so whatever is
/// newest at that instant is what gets drawn, and everything older is counted as replaced. With
/// `displaySyncEnabled` the compositor still latches on vsync, so there is no tearing; we just never add a
/// display-link phase delay on top. `CAMetalLayer` explicitly supports drawing off the main thread.
///
/// ## Synchronization
/// - `shared` (a `Mutex`) is the only state touched from arbitrary threads: the decode queue (`enqueue`), the main
///   thread (renderability, `clear`, callback), and Metal's presented-handler thread (callback read). The lock is
///   held only for a few field assignments; nothing blocks while holding it.
/// - Counters are `Atomic`s.
/// - Everything else (`gpu`, `lastFrame`, flush bookkeeping) is confined to `queue`.
/// - The layer: the main thread owns geometry (`contentsScale`, `drawableSize`, frame); the render queue only calls
///   `nextDrawable()` and, on device rebuild, sets `device`.
final class FrameRenderer: @unchecked Sendable {
    /// Two drawables: one on glass, one being rendered. A third would let a finished frame sit in the swap queue
    /// for an extra refresh (≈8–16 ms of added latency) whenever we render faster than the display; with two, a
    /// producer that outruns vsync blocks in `nextDrawable()` and the newest frame is picked when it unblocks.
    static let maximumDrawableCount = 2
    /// Housekeeping interval for `CVMetalTextureCacheFlush`, in rendered frames (~2 s at 60 fps).
    static let textureCacheFlushInterval = 120
    /// Consecutive command-buffer failures after which GPU resources are rebuilt (device loss / GPU reset).
    static let gpuErrorRebuildThreshold = 3

    private struct Shared {
        var pending: (any RenderableFrame)?
        var renderScheduled = false
        var redrawRequested = false
        var clearRequested = false
        /// Attached to a visible window with a non-empty drawable. When false, frames stay pending (and are
        /// replaced by newer ones) instead of blocking the render queue on a drawable that would never show.
        var canRender = false
        var contentSize: CGSize = .zero
        var onPresented: (@Sendable (PresentedFrameInfo) -> Void)?
    }

    private struct Work {
        var frame: (any RenderableFrame)?
        var isNewFrame: Bool
    }

    let queue = DispatchQueue(label: "com.swiftdesk.render", qos: .userInteractive)
    private let layer: CAMetalLayer
    private let shared = Mutex(Shared())

    private let replaced = Atomic<UInt64>(0)
    private let rendered = Atomic<UInt64>(0)
    private let presented = Atomic<UInt64>(0)
    private let notPresented = Atomic<UInt64>(0)
    private let unsupported = Atomic<UInt64>(0)
    private let drawableUnavailable = Atomic<UInt64>(0)
    private let gpuErrors = Atomic<UInt64>(0)
    private let consecutiveGPUErrors = Atomic<Int>(0)
    private let needsRebuild = Atomic<Bool>(false)

    // MARK: render-queue confined
    private var gpu: GPUResources?
    private var initialDevice: MTLDevice?
    private var lastSetupAttemptNanos: UInt64 = 0
    private var loggedSetupFailure = false
    private var lastFrame: (any RenderableFrame)?
    private var framesSinceFlush = 0

    init(layer: CAMetalLayer, device: MTLDevice?) {
        self.layer = layer
        self.initialDevice = device
        // Compile the shader and create the texture cache off the main thread, before the first frame arrives.
        queue.async { [self] in _ = ensureGPU() }
    }

    // MARK: any thread

    /// Newest-frame-wins slot. Never blocks on rendering; O(1) and allocation-free apart from the async hop that
    /// schedules a render pass when none is already scheduled.
    func enqueue(_ frame: any RenderableFrame) {
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                          height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let schedule = shared.withLock { s -> Bool in
            if s.pending != nil { replaced.add(1, ordering: .relaxed) }
            s.pending = frame
            s.contentSize = size
            return Self.claimRender(&s)
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Main thread: the view's window/visibility/size changed. `redraw` re-renders the last frame at the new size.
    func setRenderable(_ canRender: Bool, redraw: Bool) {
        let schedule = shared.withLock { s -> Bool in
            let became = canRender && !s.canRender
            s.canRender = canRender
            if redraw || became { s.redrawRequested = true }
            return Self.claimRender(&s)
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Drops any pending and last frame and presents black.
    func clear() {
        let schedule = shared.withLock { s -> Bool in
            s.pending = nil
            s.contentSize = .zero
            s.redrawRequested = false
            s.clearRequested = true
            return Self.claimRender(&s)
        }
        if schedule { queue.async { [self] in drain() } }
    }

    func setOnPresented(_ callback: (@Sendable (PresentedFrameInfo) -> Void)?) {
        shared.withLock { $0.onPresented = callback }
    }

    var contentSize: CGSize { shared.withLock { $0.contentSize } }
    var framesReplacedBeforeDisplay: UInt64 { replaced.load(ordering: .relaxed) }
    var hasPendingFrame: Bool { shared.withLock { $0.pending != nil } }

    var stats: RenderStats {
        var s = RenderStats()
        s.framesRendered = rendered.load(ordering: .relaxed)
        s.framesPresented = presented.load(ordering: .relaxed)
        s.framesReplacedBeforeDisplay = replaced.load(ordering: .relaxed)
        s.framesNotPresented = notPresented.load(ordering: .relaxed)
        s.framesUnsupported = unsupported.load(ordering: .relaxed)
        s.drawableUnavailable = drawableUnavailable.load(ordering: .relaxed)
        s.gpuErrors = gpuErrors.load(ordering: .relaxed)
        return s
    }

    /// Returns true if the caller must dispatch `drain()`; guarantees at most one scheduled pass.
    private static func claimRender(_ s: inout Shared) -> Bool {
        guard s.canRender, !s.renderScheduled,
              s.pending != nil || s.redrawRequested || s.clearRequested else { return false }
        s.renderScheduled = true
        return true
    }

    // MARK: render queue

    private func drain() {
        dispatchPrecondition(condition: .onQueue(queue))
        while true {
            let proceed = shared.withLock { s -> Bool in
                guard s.canRender, s.pending != nil || s.redrawRequested || s.clearRequested else {
                    s.renderScheduled = false
                    return false
                }
                return true
            }
            guard proceed else { return }
            renderOnce()
        }
    }

    /// Takes the newest work item. Always consumes the request flags so `drain()` terminates.
    private func takeWork() -> Work? {
        let (frame, clear, redraw) = shared.withLock { s -> ((any RenderableFrame)?, Bool, Bool) in
            let taken = (s.pending, s.clearRequested, s.redrawRequested)
            s.pending = nil
            s.clearRequested = false
            s.redrawRequested = false
            return taken
        }
        if let frame { return Work(frame: frame, isNewFrame: true) }
        if clear {
            lastFrame = nil
            gpu?.textureCache.flush()
            return Work(frame: nil, isNewFrame: false)
        }
        if redraw { return Work(frame: lastFrame, isNewFrame: false) }
        return nil
    }

    private func renderOnce() {
        guard let gpu = ensureGPU() else {
            // No usable GPU: keep the newest frame so it can be shown once resources come back.
            if let work = takeWork(), let frame = work.frame { lastFrame = frame }
            return
        }
        // May block until the compositor releases a drawable; frames arriving meanwhile coalesce in the slot.
        guard let drawable = layer.nextDrawable() else {
            drawableUnavailable.add(1, ordering: .relaxed)
            if let work = takeWork(), let frame = work.frame { lastFrame = frame }
            return
        }
        guard let work = takeWork() else { return }   // nothing to draw: the drawable just returns to the pool

        var planes: PlaneTextures?
        if let frame = work.frame {
            planes = gpu.textureCache.textures(for: frame.pixelBuffer)
            if planes == nil {
                if work.isNewFrame { unsupported.add(1, ordering: .relaxed) }
                lastFrame = nil
                return
            }
        }

        guard let commandBuffer = gpu.commandQueue.makeCommandBuffer() else {
            needsRebuild.store(true, ordering: .relaxed)
            if let frame = work.frame { lastFrame = frame }
            return
        }
        commandBuffer.label = "SwiftDesk video"
        guard gpu.pipeline.encode(into: commandBuffer, target: drawable.texture, planes: planes) else {
            if let frame = work.frame { lastFrame = frame }
            return
        }

        if work.isNewFrame, let frame = work.frame {
            let frameId = frame.frameId
            let decodeDone = frame.decodeDoneNanos
            drawable.addPresentedHandler { [weak self] presentedDrawable in
                self?.didPresent(frameId: frameId, decodeDoneNanos: decodeDone,
                                 presentedTime: presentedDrawable.presentedTime)
            }
        }
        commandBuffer.present(drawable)

        let retainedPlanes = planes
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // Keep the CVMetalTextures (and thus the IOSurface mappings) alive until the GPU is done sampling.
            withExtendedLifetime(retainedPlanes) {}
            self?.didComplete(failed: buffer.status == .error)
        }
        commandBuffer.commit()

        if work.isNewFrame {
            rendered.add(1, ordering: .relaxed)
            framesSinceFlush += 1
            if framesSinceFlush >= Self.textureCacheFlushInterval {
                framesSinceFlush = 0
                gpu.textureCache.flush()
            }
        }
        lastFrame = work.frame
    }

    /// Creates (or rebuilds after device trouble) the GPU objects. Retries at most once per second.
    private func ensureGPU() -> GPUResources? {
        dispatchPrecondition(condition: .onQueue(queue))
        if needsRebuild.exchange(false, ordering: .relaxed) {
            if gpu != nil { Log.media.error("Render: rebuilding GPU resources after repeated command buffer failures") }
            gpu = nil
            lastSetupAttemptNanos = 0
        }
        if let gpu { return gpu }

        let now = MonotonicClock.nowNanos()
        if lastSetupAttemptNanos != 0, now &- lastSetupAttemptNanos < 1_000_000_000 { return nil }
        lastSetupAttemptNanos = now

        let device = initialDevice ?? MTLCreateSystemDefaultDevice()
        initialDevice = nil
        guard let device else {
            logSetupFailureOnce("no Metal device")
            return nil
        }
        do {
            guard let commandQueue = device.makeCommandQueue() else { throw RenderSetupError.commandQueueCreation }
            commandQueue.label = "SwiftDesk render"
            let resources = GPUResources(device: device,
                                         commandQueue: commandQueue,
                                         pipeline: try YCbCrPipeline(device: device, colorPixelFormat: layer.pixelFormat),
                                         textureCache: try PlaneTextureCache(device: device))
            if layer.device !== device {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.device = device
                CATransaction.commit()
            }
            gpu = resources
            loggedSetupFailure = false
            Log.media.info("Render: GPU resources ready (\(device.name, privacy: .public))")
            return resources
        } catch {
            logSetupFailureOnce(String(describing: error))
            return nil
        }
    }

    private func logSetupFailureOnce(_ reason: String) {
        guard !loggedSetupFailure else { return }
        loggedSetupFailure = true
        Log.media.error("Render: GPU setup failed: \(reason, privacy: .public)")
    }

    // MARK: Metal callback threads

    private func didPresent(frameId: UInt32, decodeDoneNanos: UInt64, presentedTime: CFTimeInterval) {
        // presentedTime is 0 when the drawable was never shown (dropped by the compositor).
        guard presentedTime > 0 else {
            notPresented.add(1, ordering: .relaxed)
            return
        }
        // presentedTime is in CACurrentMediaTime seconds, i.e. mach_absolute_time — the same base as
        // CLOCK_UPTIME_RAW used by MonotonicClock (verified on this machine), so a plain unit conversion suffices.
        let presentedNanos = UInt64((presentedTime * 1_000_000_000).rounded())
        let latency = presentedNanos > decodeDoneNanos ? presentedNanos - decodeDoneNanos : 0
        presented.add(1, ordering: .relaxed)
        PipelineSignpost.presented(frame: UInt64(frameId))
        let callback = shared.withLock { $0.onPresented }
        callback?(PresentedFrameInfo(frameId: frameId, decodeToPresentNanos: latency))
    }

    private func didComplete(failed: Bool) {
        guard failed else {
            consecutiveGPUErrors.store(0, ordering: .relaxed)
            return
        }
        gpuErrors.add(1, ordering: .relaxed)
        let streak = consecutiveGPUErrors.add(1, ordering: .relaxed).newValue
        if streak >= Self.gpuErrorRebuildThreshold {
            consecutiveGPUErrors.store(0, ordering: .relaxed)
            needsRebuild.store(true, ordering: .relaxed)
        }
    }
}
