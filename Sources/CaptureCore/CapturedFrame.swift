import CoreMedia
import CoreVideo

/// One complete screen frame handed from ScreenCaptureKit to the encoder.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is not annotated: the buffer is an immutable, IOSurface-backed
/// image owned by ScreenCaptureKit's pool and is only read after capture. Holding the value retains the surface,
/// and the pool only has `queueDepth` (4) of them — a consumer that keeps frames around starves capture, so hand it
/// to the encoder (one pending frame) and drop it.
public struct CapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// ScreenCaptureKit presentation timestamp (host-time based); pass straight to the encoder.
    public let presentationTime: CMTime
    /// `MonotonicClock.nowNanos()` taken as the first action of the capture callback: the start of the host pipeline.
    public let captureNanos: UInt64
    /// Monotonic per-capturer frame counter (starts at 1, continues across restarts of the same capturer).
    public let sequence: UInt64
    /// When the window server displayed this frame (`SCStreamFrameInfo.displayTime`, converted to
    /// `MonotonicClock` nanoseconds), or 0 if not attached. `captureNanos - displayNanos` is compositor→callback delay.
    public let displayNanos: UInt64

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureNanos: UInt64, sequence: UInt64, displayNanos: UInt64 = 0) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.captureNanos = captureNanos
        self.sequence = sequence
        self.displayNanos = displayNanos
    }

    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}
