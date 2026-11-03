import CoreGraphics

/// Normalized video coordinates → Host global event coordinates.
///
/// The Viewer sends positions normalized to the video frame, which already removes its window size, letterboxing
/// and Retina scale. The Host maps them onto the captured display's frame in *points* (the `CGDisplayBounds`
/// convention CGEvent uses: origin at the top-left of the main display, y down, secondary displays may have negative
/// origins). Capture pixel size never enters this mapping, so a 2x display needs no special case.
public enum HostCoordinateMapper {
    /// normalized (0,0 top-left) → global CG display coordinates in points, clamped to the display
    /// (`[minX, maxX - 1] × [minY, maxY - 1]`) so a click at the very edge cannot land on a neighbouring display.
    /// Non-finite input is treated as 0 (NaN, -inf) or 1 (+inf).
    public static func globalPoint(normalizedX: Float, normalizedY: Float, displayFrame: CGRect) -> CGPoint {
        let frame = displayFrame.standardized
        let nx = CGFloat(InputStateTracker.clampUnit(normalizedX))
        let ny = CGFloat(InputStateTracker.clampUnit(normalizedY))
        let x = frame.minX + nx * frame.width
        let y = frame.minY + ny * frame.height
        let maxX = max(frame.minX, frame.maxX - 1)
        let maxY = max(frame.minY, frame.maxY - 1)
        return CGPoint(x: min(max(x, frame.minX), maxX), y: min(max(y, frame.minY), maxY))
    }
}
