import CoreGraphics

/// Pure geometry shared by the renderer (aspect-fit viewport) and input capture (pointer normalization).
///
/// Both sides must use the exact same rectangle, otherwise a click lands a few pixels away from where the
/// user sees the remote content — so the math lives in one place and is unit-tested.
public enum VideoGeometry {
    /// Largest rectangle with the aspect ratio of `content`, centered in `bounds` (letterbox / pillarbox).
    ///
    /// Returns `.zero` when either size is empty or not finite: there is nothing meaningful to show, and
    /// callers treat an empty video rect as "no video" (pointer events map to nil).
    public static func aspectFitRect(content: CGSize, in bounds: CGRect) -> CGRect {
        let cw = content.width, ch = content.height
        let bw = bounds.width, bh = bounds.height
        guard cw > 0, ch > 0, bw > 0, bh > 0,
              cw.isFinite, ch.isFinite, bw.isFinite, bh.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite else { return .zero }

        // Compare aspect ratios by cross-multiplication so an exact fit returns `bounds` without rounding noise.
        let width: CGFloat
        let height: CGFloat
        if bw * ch > bh * cw {
            // Bounds are wider than the content: full height, bars left and right (pillarbox).
            height = bh
            width = bh * cw / ch
        } else if bw * ch < bh * cw {
            // Bounds are taller than the content: full width, bars top and bottom (letterbox).
            width = bw
            height = bw * ch / cw
        } else {
            width = bw
            height = bh
        }
        return CGRect(x: bounds.minX + (bw - width) / 2,
                      y: bounds.minY + (bh - height) / 2,
                      width: width,
                      height: height)
    }

    /// View point (AppKit coords, origin bottom-left unless `viewIsFlipped`) → normalized video point with
    /// (0,0) at the top-left and (1,1) at the bottom-right of the video. Returns nil outside `videoRect`
    /// (edges inclusive, so the four corners map exactly to 0/1) or when `videoRect` is empty.
    public static func normalizedPoint(viewPoint: CGPoint, videoRect: CGRect, viewIsFlipped: Bool) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0,
              viewPoint.x.isFinite, viewPoint.y.isFinite else { return nil }
        guard viewPoint.x >= videoRect.minX, viewPoint.x <= videoRect.maxX,
              viewPoint.y >= videoRect.minY, viewPoint.y <= videoRect.maxY else { return nil }
        let x = (viewPoint.x - videoRect.minX) / videoRect.width
        let fromTop = viewIsFlipped ? viewPoint.y - videoRect.minY : videoRect.maxY - viewPoint.y
        let y = fromTop / videoRect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Like `normalizedPoint`, but a point outside `videoRect` is first clamped onto its nearest edge, so it maps to
    /// the edge of the remote display instead of nil. Used for moves, drags and button-ups while input is captured:
    /// AppKit samples rarely land exactly on the video's edge, and without clamping the Host cursor would stop short
    /// of the screen edge (no Dock reveal, hidden menu bar, hot corners or drag-autoscroll). Nil only for an empty
    /// `videoRect` or a non-finite point.
    public static func clampedNormalizedPoint(viewPoint: CGPoint, videoRect: CGRect, viewIsFlipped: Bool) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0,
              viewPoint.x.isFinite, viewPoint.y.isFinite else { return nil }
        let clamped = CGPoint(x: min(max(viewPoint.x, videoRect.minX), videoRect.maxX),
                              y: min(max(viewPoint.y, videoRect.minY), videoRect.maxY))
        return normalizedPoint(viewPoint: clamped, videoRect: videoRect, viewIsFlipped: viewIsFlipped)
    }

    /// Largest whole-pixel mismatch between the aspect-fit size and a whole multiple of the frame size (1×, 2×, …)
    /// that is still drawn at exactly that multiple. Rounding of window and view sizes routinely leaves the fit a pixel
    /// or two away; drawing exactly 1:1 or 2:1 (with that pixel of black bar) is far sharper than resampling by 1.001.
    static let oneToOneSnapPixels: CGFloat = 2

    /// Aspect-fit rectangle in whole drawable pixels (origin top-left, as Metal viewports expect).
    ///
    /// Snapping to integer pixels keeps the video edges crisp and avoids a half-covered column of bars. When a whole
    /// multiple of the frame (1×, 2×, …) fits in the drawable and the fit is within `oneToOneSnapPixels` of it, the
    /// viewport is *exactly* that multiple, so every frame pixel covers exactly n×n drawable pixels and the picture
    /// is shown pixel for pixel (or pixel-doubled, e.g. a 1× Host's 1600×900 in a 1600×900 pt view on Retina).
    static func pixelViewport(content: CGSize, drawableWidth: Int, drawableHeight: Int) -> CGRect {
        let fit = aspectFitRect(content: content,
                                in: CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight))
        guard fit.width > 0, fit.height > 0 else { return .zero }
        var w = max(1, fit.width.rounded())
        var h = max(1, fit.height.rounded())
        let cw = content.width.rounded(), ch = content.height.rounded()
        if cw >= 1, ch >= 1 {
            let n = max(1, (w / cw).rounded())
            let nw = cw * n, nh = ch * n
            if nw <= CGFloat(drawableWidth), nh <= CGFloat(drawableHeight),
               abs(w - nw) <= oneToOneSnapPixels, abs(h - nh) <= oneToOneSnapPixels {
                w = nw
                h = nh
            }
        }
        let x = ((CGFloat(drawableWidth) - w) / 2).rounded(.down)
        let y = ((CGFloat(drawableHeight) - h) / 2).rounded(.down)
        return CGRect(x: max(0, x), y: max(0, y), width: w, height: h)
    }

    /// Whole-number magnification (1, 2, …) at which `viewport` shows `content`, or nil when it is scaled by any other
    /// factor. At a whole multiple the renderer samples without filtering: every drawable pixel centre falls inside
    /// exactly one frame pixel, so nearest sampling is exact (1:1) or clean pixel doubling (2:1), never soft.
    static func wholeMagnification(content: CGSize, viewport: CGRect) -> Int? {
        let cw = content.width.rounded(), ch = content.height.rounded()
        guard cw >= 1, ch >= 1, viewport.width >= cw, viewport.height >= ch else { return nil }
        let n = (viewport.width / cw).rounded()
        guard n >= 1, n <= 16, viewport.width == cw * n, viewport.height == ch * n else { return nil }
        return Int(n)
    }

    /// True when `viewport` shows `content` at exactly one frame pixel per drawable pixel.
    static func isOneToOne(content: CGSize, viewport: CGRect) -> Bool {
        wholeMagnification(content: content, viewport: viewport) == 1
    }

    /// Drawable size in pixels for a view of `bounds` points at `scale` (what `MetalVideoView` gives its layer).
    static func drawableSize(bounds: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        let maxSide: CGFloat = 16384   // Metal 2D texture limit on all supported GPUs
        let s = scale > 0 && scale.isFinite ? scale : 1
        guard bounds.width.isFinite, bounds.height.isFinite else { return (0, 0) }
        let width = min(maxSide, max(0, (bounds.width * s).rounded()))
        let height = min(maxSide, max(0, (bounds.height * s).rounded()))
        return (Int(width), Int(height))
    }

    /// The renderer's viewport (`pixelViewport` in a `drawableSize` drawable) converted back to view points, so the
    /// rectangle input is normalized against is exactly the one the video is drawn into — including the 1:1 snap.
    public static func videoRect(content: CGSize, bounds: CGRect, scale: CGFloat, viewIsFlipped: Bool) -> CGRect {
        let s = scale > 0 && scale.isFinite ? scale : 1
        let drawable = drawableSize(bounds: bounds, scale: s)
        let viewport = pixelViewport(content: content, drawableWidth: drawable.width, drawableHeight: drawable.height)
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let x = bounds.minX + viewport.minX / s
        let topInset = viewport.minY / s
        let height = viewport.height / s
        let y = viewIsFlipped ? bounds.minY + topInset : bounds.minY + CGFloat(drawable.height) / s - topInset - height
        return CGRect(x: x, y: y, width: viewport.width / s, height: height)
    }

    // MARK: Viewer window sizing

    /// How a window is sized to its stream.
    public enum WindowSizing: Sendable, Equatable {
        /// One stream pixel per screen pixel (View › Actual Size, ⌘0), or as large as fits when that does not fit.
        case actualSize
        /// Session start and automatic re-sizing: the largest *whole* magnification that fits (1×, 2×, … — drawn
        /// without filtering), unless that leaves the picture much smaller than the screen (a 1× Host's 1600×900 on a
        /// Retina laptop is 800×450 pt at 1:1, its UI at half its physical size); then as large as fits.
        case automatic
    }

    /// Below this fraction of the available width *and* height, `.automatic` prefers filling the screen over a whole
    /// magnification.
    static let automaticSmallFraction: CGFloat = 0.6

    /// Window frame that shows a `streamPixels` stream at one stream pixel per screen pixel, or — when that does not
    /// fit on the screen — as large as fits, aspect preserved. `sizing: .automatic` picks a whole magnification or
    /// fills the screen instead (see `WindowSizing`).
    ///
    /// - Parameters:
    ///   - windowFrame: the window's current frame (screen points).
    ///   - videoArea: the size (points) of the view the video is drawn in; everything else in the window (title bar,
    ///     toolbar) is kept as is.
    ///   - streamPixels: encoded stream size in pixels.
    ///   - backingScale: the screen's backing scale factor (2 on Retina): 1:1 needs `streamPixels / backingScale` points.
    ///   - visibleFrame: the screen's visible frame (without menu bar and Dock).
    ///   - minimumFrameSize: smallest frame the window allows (its minimum content size plus title bar); the video
    ///     area grows to meet it (the renderer still draws 1:1 when only one axis grew, with bars on the other).
    /// - Returns: the new frame, top-left corner kept where it was when possible and moved onto the visible frame
    ///   otherwise; nil for degenerate inputs.
    public static func actualSizeWindowFrame(windowFrame: CGRect, videoArea: CGSize, streamPixels: CGSize,
                                             backingScale: CGFloat, visibleFrame: CGRect,
                                             minimumFrameSize: CGSize = .zero,
                                             sizing: WindowSizing = .actualSize) -> CGRect? {
        let scale = backingScale > 0 && backingScale.isFinite ? backingScale : 1
        guard streamPixels.width > 0, streamPixels.height > 0, visibleFrame.width > 0, visibleFrame.height > 0,
              windowFrame.width.isFinite, windowFrame.height.isFinite,
              videoArea.width.isFinite, videoArea.height.isFinite else { return nil }
        let chromeW = max(0, windowFrame.width - videoArea.width)
        let chromeH = max(0, windowFrame.height - videoArea.height)
        var videoW = streamPixels.width / scale
        var videoH = streamPixels.height / scale
        let availableW = visibleFrame.width - chromeW
        let availableH = visibleFrame.height - chromeH
        guard availableW > 0, availableH > 0 else { return nil }
        let largest = min(availableW / videoW, availableH / videoH)   // magnification that fills the screen
        var factor: CGFloat = 1
        if largest < 1 {
            factor = largest                                            // 1:1 does not fit: as large as fits
        } else if sizing == .automatic {
            let whole = largest.rounded(.down)
            let tiny = videoW * whole < availableW * automaticSmallFraction
                && videoH * whole < availableH * automaticSmallFraction
            factor = tiny ? largest : whole
        }
        if factor != factor.rounded() {
            // Whole device pixels, so the scaled picture still starts and ends on pixel boundaries.
            videoW = ((videoW * factor * scale).rounded(.down)) / scale
            videoH = ((videoH * factor * scale).rounded(.down)) / scale
        } else {
            videoW *= factor
            videoH *= factor
        }
        var width = videoW + chromeW
        var height = videoH + chromeH
        width = min(max(width, minimumFrameSize.width), visibleFrame.width)
        height = min(max(height, minimumFrameSize.height), visibleFrame.height)
        // Keep the top-left corner (AppKit screen coordinates grow upwards), then pull the frame onto the screen.
        var x = windowFrame.minX
        var y = windowFrame.maxY - height
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
