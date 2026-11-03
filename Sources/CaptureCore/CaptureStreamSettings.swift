@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo

/// The concrete `SCStreamConfiguration` values SwiftDesk applies, derived purely from a `CaptureConfig` and the
/// display's geometry so the choices are unit-testable without Screen Recording permission.
///
/// Latency rationale for each value lives in `makeConfiguration()`. This SDK exposes no explicit latency knob on
/// `SCStreamConfiguration`; latency is controlled through output size, frame interval, pixel format (no conversion
/// before the encoder), queue depth and how fast the callback returns.
public struct CaptureStreamSettings: Sendable, Equatable {
    /// Output surface size in pixels (even, aspect-preserving, ≤ the configured bounds).
    public var width: Int
    public var height: Int
    public var fps: Int
    public var queueDepth: Int
    public var showsCursor: Bool
    /// True when ScreenCaptureKit samples the display at point resolution instead of Retina backing resolution.
    public var usesNominalResolution: Bool

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: the display mode's backing size (`CGDisplayModeGetPixelWidth/Height`).
    ///   - pointSize: the display size in points (`CGDisplayBounds`).
    public init(config: CaptureConfig, pixelWidth: Int, pixelHeight: Int, pointSize: CGSize) {
        let config = config.sanitized
        let size = CaptureGeometry.fit(sourceWidth: pixelWidth, sourceHeight: pixelHeight,
                                       maxWidth: config.maxWidth, maxHeight: config.maxHeight)
        width = size.width
        height = size.height
        fps = config.fps
        queueDepth = config.queueDepth
        showsCursor = config.showsCursor
        // Nominal (1 sample per point) halves the source raster on Retina displays, so the window server reads and
        // scales a quarter of the pixels. Only safe when the point raster is still at least as large as the output;
        // otherwise nominal capture would be upscaled and blurry, so fall back to backing resolution.
        usesNominalResolution = pointSize.width >= CGFloat(width) && pointSize.height >= CGFloat(height)
    }

    public var minimumFrameInterval: CMTime { CMTime(value: 1, timescale: CMTimeScale(fps)) }

    /// Builds a fresh configuration; used both for `SCStream(filter:configuration:delegate:)` and
    /// `updateConfiguration(_:)`.
    func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Scale in the window server's GPU pass so the encoder gets exactly the size it encodes; no CPU resampling.
        configuration.width = width
        configuration.height = height
        // Caps delivery at the target rate. Never kCMTimeZero: that means "native refresh" (120 Hz on ProMotion),
        // which would double encode load and queue frames the network cannot carry.
        configuration.minimumFrameInterval = minimumFrameInterval
        // Apple documents 3 as the minimum. A deeper pool lets frames go stale; a shallower one stalls the
        // compositor. The app keeps at most one frame pending in the encoder instead.
        configuration.queueDepth = queueDepth
        // 420v is what the H.264 hardware encoder consumes natively: no per-frame colour conversion pass.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // BT.709 matrix to match the encoder's VUI and the Viewer's YUV→RGB shader. The CoreVideo constant has the
        // same value as kCGDisplayStreamYCbCrMatrix_ITU_R_709_2 (documented in CGDisplayStream.h) without
        // depending on the obsolete CGDisplayStream API.
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        // sRGB shares BT.709 primaries; without it SCK emits the display's space (often Display P3) and colours shift
        // after 709 decode. Desktop UI is authored in sRGB, so this is also the cheapest conversion.
        configuration.colorSpaceName = CGColorSpace.sRGB
        // Our geometry is already aspect-preserving within one even-pixel rounding step. Letting SCK stretch by
        // that sub-pixel amount avoids 1-px black bars that would offset normalized input coordinates.
        configuration.preservesAspectRatio = false
        configuration.captureResolution = usesNominalResolution ? .nominal : .best
        // The Viewer paints its own cursor immediately (PRD §6); the host cursor in video would lag and double up.
        configuration.showsCursor = showsCursor
        configuration.showMouseClicks = false
        // SDR explicitly: HDR capture changes formats and adds tone-mapping work.
        configuration.captureDynamicRange = .SDR
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.streamName = "SwiftDesk"
        return configuration
    }
}
