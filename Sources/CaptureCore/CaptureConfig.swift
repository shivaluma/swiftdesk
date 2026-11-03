import CoreGraphics

/// Capture parameters for one display stream.
///
/// Defaults: bounds of 1920×1080 at 60 FPS — the Host's "Sharp" top rung, so a display up to that size is captured
/// at its native pixel size and never upscaled (`CaptureGeometry.fit`); the PRD's 1280×720 starting point is the
/// "Balanced" quality and the next rung down. Host cursor hidden (the Viewer draws its own cursor locally so pointer
/// feedback never waits for video), and a ScreenCaptureKit surface queue of 4.
/// The queue depth is deliberately not 1: Apple documents 3 as the minimum, and a shallower pool makes the
/// window server stall instead of dropping, which *adds* latency. 4 rather than 3 because the encoder keeps its
/// newest frame retained (to resubmit it on a static screen, see `H264Encoder`), which pins one surface. Staleness is
/// avoided downstream by the one-in-flight / latest-frame encoder rule, not by starving the capture pool.
public struct CaptureConfig: Sendable, Equatable {
    /// Smallest surface pool we ever request. Apple's `queueDepth` documentation gives 3 as the minimum.
    public static let minimumQueueDepth = 3
    /// The SDK header says the queue "should not exceed 8 frames".
    public static let maximumQueueDepth = 8
    /// Upper bound for `fps`; the PRD designs for 60 Hz with 120 as an optional experiment.
    public static let maximumFPS = 120

    public var maxWidth = 1920
    public var maxHeight = 1080
    public var fps = 60
    public var showsCursor = false
    public var queueDepth = 4

    public init(maxWidth: Int = 1920, maxHeight: Int = 1080, fps: Int = 60, showsCursor: Bool = false, queueDepth: Int = 4) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.fps = fps
        self.showsCursor = showsCursor
        self.queueDepth = queueDepth
    }

    /// The values actually handed to ScreenCaptureKit: fps in `1...maximumFPS`, queue depth in
    /// `minimumQueueDepth...maximumQueueDepth`, output bounds at least 2×2. Applying this instead of trusting the
    /// caller means a bad config can never produce `queueDepth = 1` or a zero frame interval (which SCK
    /// interprets as "native refresh rate", silently doubling encode load on 120 Hz panels).
    public var sanitized: CaptureConfig {
        CaptureConfig(
            maxWidth: max(2, maxWidth),
            maxHeight: max(2, maxHeight),
            fps: min(max(1, fps), Self.maximumFPS),
            showsCursor: showsCursor,
            queueDepth: min(max(Self.minimumQueueDepth, queueDepth), Self.maximumQueueDepth)
        )
    }
}

/// Output-size math for the capture stream.
///
/// Sizing happens in ScreenCaptureKit's GPU scaler, so the encoder receives exactly the resolution it will
/// encode and no CPU resampling ever runs on the hot path.
public enum CaptureGeometry {
    /// Largest aspect-preserving size that fits in `maxWidth × maxHeight` without upscaling the source.
    ///
    /// Both dimensions are even because 4:2:0 chroma subsampling (420v) and H.264 macroblock cropping require it;
    /// odd sizes make VideoToolbox pad or reject the buffer. Rounding is to the nearest even value (for the best
    /// aspect match) and then clamped so the result never exceeds the bounds or the source. Degenerate inputs:
    /// a non-positive source yields `(0, 0)`; any positive result is at least 2×2.
    public static func fit(sourceWidth: Int, sourceHeight: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
        let boundW = max(2, maxWidth)
        let boundH = max(2, maxHeight)
        let scale = min(1.0, Double(boundW) / Double(sourceWidth), Double(boundH) / Double(sourceHeight))
        let width = clampEven(Double(sourceWidth) * scale, limit: min(boundW, sourceWidth))
        let height = clampEven(Double(sourceHeight) * scale, limit: min(boundH, sourceHeight))
        return (width, height)
    }

    /// Convenience overload for `CGSize` sources (e.g. a display's point size).
    public static func fit(source: CGSize, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard source.width.isFinite, source.height.isFinite else { return (0, 0) }
        return fit(sourceWidth: Int(source.width.rounded()), sourceHeight: Int(source.height.rounded()),
                   maxWidth: maxWidth, maxHeight: maxHeight)
    }

    @inline(__always)
    private static func clampEven(_ value: Double, limit: Int) -> Int {
        let nearestEven = Int((value / 2).rounded()) * 2
        let evenLimit = limit & ~1
        return max(2, min(nearestEven, evenLimit))
    }
}
