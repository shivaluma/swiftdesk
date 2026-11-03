import CoreVideo

/// A decoded video frame that RenderCore can put on screen.
///
/// RenderCore depends only on this protocol (not on CodecCore) so the renderer can be fed by the hardware
/// decoder, the loopback pipeline or synthetic test frames alike. Conformers are expected to wrap an
/// IOSurface-backed, Metal-compatible `420v` (or `420f`) pixel buffer: the renderer maps its planes as
/// textures with `CVMetalTextureCache`, so no pixel is ever copied through the CPU.
public protocol RenderableFrame: Sendable {
    var pixelBuffer: CVPixelBuffer { get }
    var frameId: UInt32 { get }
    /// `MonotonicClock.nowNanos()` when decoding finished; the origin of the decode→present measurement.
    var decodeDoneNanos: UInt64 { get }
}

/// Reported once per frame that actually reached the glass (per `MTLDrawable.presentedTime`).
///
/// Frames that were replaced before display, or whose drawable was dropped by the compositor, never produce
/// one of these — so a count of `PresentedFrameInfo` is the true on-screen frame rate.
public struct PresentedFrameInfo: Sendable, Equatable {
    public var frameId: UInt32
    /// Decoder output → photons leaving the compositor, in nanoseconds on the `MonotonicClock` base.
    public var decodeToPresentNanos: UInt64

    public init(frameId: UInt32, decodeToPresentNanos: UInt64) {
        self.frameId = frameId
        self.decodeToPresentNanos = decodeToPresentNanos
    }
}

/// Renderer counters, readable from any thread. Used for the diagnostics panel (PRD "Troubleshooter").
public struct RenderStats: Sendable, Equatable {
    /// Frames encoded into a drawable and committed to the GPU.
    public var framesRendered: UInt64 = 0
    /// Frames whose drawable was confirmed on screen (`presentedTime > 0`).
    public var framesPresented: UInt64 = 0
    /// Frames that were waiting for display when a newer frame arrived (latest-frame-wins drops).
    public var framesReplacedBeforeDisplay: UInt64 = 0
    /// Frames whose drawable was committed but never shown (`presentedTime == 0`).
    public var framesNotPresented: UInt64 = 0
    /// Frames discarded because their pixel format is not 4:2:0 bi-planar or texture mapping failed.
    public var framesUnsupported: UInt64 = 0
    /// `nextDrawable()` returned nil (1 s timeout, layer off screen or out of memory).
    public var drawableUnavailable: UInt64 = 0
    /// Command buffers that completed with an error.
    public var gpuErrors: UInt64 = 0

    public init() {}
}
