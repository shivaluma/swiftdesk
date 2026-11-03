import CoreGraphics
import Testing
@testable import RenderCore

@Suite("VideoGeometry")
struct VideoGeometryTests {
    private func approx(_ a: CGRect, _ b: CGRect, tol: CGFloat = 1e-9) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    @Test func exactFitReturnsBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 1280, height: 720)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: 1920, height: 1080), in: bounds) == bounds)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: 1280, height: 720), in: bounds) == bounds)
    }

    @Test func letterboxWhenBoundsTaller() {
        // 16:9 content in a square: full width, bars top and bottom.
        let r = VideoGeometry.aspectFitRect(content: CGSize(width: 1600, height: 900),
                                            in: CGRect(x: 0, y: 0, width: 800, height: 800))
        #expect(approx(r, CGRect(x: 0, y: 175, width: 800, height: 450)))
    }

    @Test func pillarboxWhenBoundsWider() {
        // 4:3 content in 16:9 bounds: full height, bars left and right.
        let r = VideoGeometry.aspectFitRect(content: CGSize(width: 1024, height: 768),
                                            in: CGRect(x: 0, y: 0, width: 1600, height: 900))
        #expect(approx(r, CGRect(x: 200, y: 0, width: 1200, height: 900)))
    }

    @Test func respectsBoundsOrigin() {
        let r = VideoGeometry.aspectFitRect(content: CGSize(width: 100, height: 100),
                                            in: CGRect(x: 50, y: -30, width: 300, height: 100))
        #expect(approx(r, CGRect(x: 150, y: -30, width: 100, height: 100)))
    }

    @Test func zeroOrInvalidSizesReturnZero() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(VideoGeometry.aspectFitRect(content: .zero, in: bounds) == .zero)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: 0, height: 10), in: bounds) == .zero)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: 10, height: 10), in: .zero) == .zero)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: 10, height: 10),
                                            in: CGRect(x: 0, y: 0, width: 100, height: 0)) == .zero)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: -10, height: 10), in: bounds) == .zero)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: CGFloat.nan, height: 10), in: bounds) == .zero)
        #expect(VideoGeometry.aspectFitRect(content: CGSize(width: 10, height: 10), in: .null) == .zero)
    }

    @Test func resultAlwaysInsideBoundsAndPreservesAspect() {
        let contents = [CGSize(width: 1280, height: 720), CGSize(width: 960, height: 540),
                        CGSize(width: 1, height: 1000), CGSize(width: 3000, height: 7)]
        let boundsList = [CGRect(x: 0, y: 0, width: 333, height: 777), CGRect(x: 5, y: 5, width: 1440, height: 900),
                          CGRect(x: -100, y: 0, width: 10, height: 10)]
        for c in contents {
            for b in boundsList {
                let r = VideoGeometry.aspectFitRect(content: c, in: b)
                #expect(r.minX >= b.minX - 1e-9 && r.maxX <= b.maxX + 1e-9)
                #expect(r.minY >= b.minY - 1e-9 && r.maxY <= b.maxY + 1e-9)
                #expect(abs(r.width / r.height - c.width / c.height) < 1e-6 * (c.width / c.height))
                // One dimension must touch the bounds.
                #expect(abs(r.width - b.width) < 1e-9 || abs(r.height - b.height) < 1e-9)
            }
        }
    }

    @Test func cornersMapToZeroAndOneUnflipped() throws {
        let video = CGRect(x: 100, y: 50, width: 400, height: 200)
        // Unflipped: origin bottom-left, so the top-left of the video is (minX, maxY).
        let tl = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 100, y: 250), videoRect: video, viewIsFlipped: false))
        let br = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 500, y: 50), videoRect: video, viewIsFlipped: false))
        let bl = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 100, y: 50), videoRect: video, viewIsFlipped: false))
        let tr = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 500, y: 250), videoRect: video, viewIsFlipped: false))
        #expect(tl == CGPoint(x: 0, y: 0))
        #expect(br == CGPoint(x: 1, y: 1))
        #expect(bl == CGPoint(x: 0, y: 1))
        #expect(tr == CGPoint(x: 1, y: 0))
    }

    @Test func cornersMapToZeroAndOneFlipped() throws {
        let video = CGRect(x: 100, y: 50, width: 400, height: 200)
        // Flipped: origin top-left, so the top-left of the video is (minX, minY).
        let tl = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 100, y: 50), videoRect: video, viewIsFlipped: true))
        let br = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 500, y: 250), videoRect: video, viewIsFlipped: true))
        #expect(tl == CGPoint(x: 0, y: 0))
        #expect(br == CGPoint(x: 1, y: 1))
    }

    @Test func interiorPoints() throws {
        let video = CGRect(x: 0, y: 0, width: 200, height: 100)
        let p = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 50, y: 75), videoRect: video, viewIsFlipped: false))
        #expect(abs(p.x - 0.25) < 1e-12)
        #expect(abs(p.y - 0.25) < 1e-12)   // 75 from the bottom = 25 from the top
        let q = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 50, y: 75), videoRect: video, viewIsFlipped: true))
        #expect(abs(q.y - 0.75) < 1e-12)
        let center = try #require(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 100, y: 50), videoRect: video, viewIsFlipped: false))
        #expect(center == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func pointsOutsideReturnNil() {
        let video = CGRect(x: 100, y: 50, width: 400, height: 200)
        let outside = [CGPoint(x: 99.999, y: 100), CGPoint(x: 500.001, y: 100),
                       CGPoint(x: 200, y: 49.999), CGPoint(x: 200, y: 250.001),
                       CGPoint(x: -1, y: -1), CGPoint(x: CGFloat.nan, y: 100), CGPoint(x: CGFloat.infinity, y: 100)]
        for p in outside {
            #expect(VideoGeometry.normalizedPoint(viewPoint: p, videoRect: video, viewIsFlipped: false) == nil)
            #expect(VideoGeometry.normalizedPoint(viewPoint: p, videoRect: video, viewIsFlipped: true) == nil)
        }
    }

    @Test func clampedPointsMapOutsidePointsOntoTheEdge() throws {
        let video = CGRect(x: 100, y: 50, width: 400, height: 200)
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 50, y: 150), CGPoint(x: 0, y: 0.5)),      // left bar
            (CGPoint(x: 900, y: 150), CGPoint(x: 1, y: 0.5)),     // right
            (CGPoint(x: 300, y: 0), CGPoint(x: 0.5, y: 1)),       // below (unflipped: bottom of the video)
            (CGPoint(x: 300, y: 999), CGPoint(x: 0.5, y: 0)),     // above
            (CGPoint(x: -5, y: -5), CGPoint(x: 0, y: 1)),         // corner
            (CGPoint(x: 300, y: 150), CGPoint(x: 0.5, y: 0.5)),   // inside: same as normalizedPoint
        ]
        for (point, expected) in cases {
            let p = try #require(VideoGeometry.clampedNormalizedPoint(viewPoint: point, videoRect: video, viewIsFlipped: false))
            #expect(p == expected, "\(point)")
        }
        let flipped = try #require(VideoGeometry.clampedNormalizedPoint(viewPoint: CGPoint(x: 300, y: 0), videoRect: video,
                                                                         viewIsFlipped: true))
        #expect(flipped == CGPoint(x: 0.5, y: 0))
        #expect(VideoGeometry.clampedNormalizedPoint(viewPoint: CGPoint(x: CGFloat.nan, y: 0), videoRect: video,
                                                     viewIsFlipped: false) == nil)
        #expect(VideoGeometry.clampedNormalizedPoint(viewPoint: .zero, videoRect: .zero, viewIsFlipped: false) == nil)
    }

    @Test func emptyVideoRectReturnsNil() {
        #expect(VideoGeometry.normalizedPoint(viewPoint: .zero, videoRect: .zero, viewIsFlipped: false) == nil)
        #expect(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 5, y: 5),
                                              videoRect: CGRect(x: 0, y: 0, width: 10, height: 0),
                                              viewIsFlipped: true) == nil)
    }

    @Test func letterboxBarsAreOutsideVideo() {
        // Square view with 16:9 video: clicks in the bars must not map.
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
        let video = VideoGeometry.aspectFitRect(content: CGSize(width: 1280, height: 720), in: bounds)
        #expect(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 400, y: 10), videoRect: video, viewIsFlipped: false) == nil)
        #expect(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 400, y: 790), videoRect: video, viewIsFlipped: false) == nil)
        #expect(VideoGeometry.normalizedPoint(viewPoint: CGPoint(x: 400, y: 400), videoRect: video, viewIsFlipped: false) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func pixelViewportIsIntegralAndCentered() {
        let v = VideoGeometry.pixelViewport(content: CGSize(width: 1280, height: 720), drawableWidth: 1001, drawableHeight: 1000)
        #expect(v.width == 1001)
        let expectedHeight: CGFloat = (CGFloat(1001) * 720 / 1280).rounded()
        #expect(v.height == expectedHeight)
        #expect(v.minX == 0)
        #expect(v.minY == ((1000 - v.height) / 2).rounded(.down))
        #expect(v.minX == v.minX.rounded() && v.minY == v.minY.rounded())
        #expect(VideoGeometry.pixelViewport(content: .zero, drawableWidth: 100, drawableHeight: 100) == .zero)
        #expect(VideoGeometry.pixelViewport(content: CGSize(width: 10, height: 10), drawableWidth: 0, drawableHeight: 100) == .zero)
        let exact = VideoGeometry.pixelViewport(content: CGSize(width: 1280, height: 720), drawableWidth: 2560, drawableHeight: 1440)
        #expect(exact == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    // MARK: 1:1 display

    @Test func viewportWithinTwoPixelsOfTheFrameSnapsToOneToOne() {
        let content = CGSize(width: 1600, height: 900)
        // A 1601×901 drawable would scale by 1.0006 — drawn exactly 1:1 instead.
        let near = VideoGeometry.pixelViewport(content: content, drawableWidth: 1601, drawableHeight: 901)
        #expect(near.width == 1600 && near.height == 900)
        #expect(VideoGeometry.isOneToOne(content: content, viewport: near))
        // Exact: the whole drawable.
        let exact = VideoGeometry.pixelViewport(content: content, drawableWidth: 1600, drawableHeight: 900)
        #expect(exact == CGRect(x: 0, y: 0, width: 1600, height: 900))
        // Pillarboxed by a wider window but the same height: still 1:1.
        let wide = VideoGeometry.pixelViewport(content: content, drawableWidth: 1800, drawableHeight: 900)
        #expect(wide == CGRect(x: 100, y: 0, width: 1600, height: 900))
        // Clearly larger: scaled (and so filtered).
        let big = VideoGeometry.pixelViewport(content: content, drawableWidth: 2200, drawableHeight: 1238)
        #expect(!VideoGeometry.isOneToOne(content: content, viewport: big))
        // Smaller than the frame is never "snapped" past the drawable.
        let small = VideoGeometry.pixelViewport(content: content, drawableWidth: 1599, drawableHeight: 899)
        #expect(small.width <= 1599 && small.height <= 899)
    }

    /// An exact (or within-two-pixels) whole multiple of the frame is drawn at exactly that multiple and sampled
    /// without filtering — a 1× Host's 1600×900 in a 1600×900 pt view on Retina is clean pixel doubling, not a soft
    /// linear upscale. Any other factor is filtered.
    @Test func wholeMultiplesAreDrawnExactly() {
        let content = CGSize(width: 1600, height: 900)
        let doubled = VideoGeometry.pixelViewport(content: content, drawableWidth: 3200, drawableHeight: 1800)
        #expect(doubled == CGRect(x: 0, y: 0, width: 3200, height: 1800))
        #expect(VideoGeometry.wholeMagnification(content: content, viewport: doubled) == 2)
        #expect(!VideoGeometry.isOneToOne(content: content, viewport: doubled))
        let nearDouble = VideoGeometry.pixelViewport(content: content, drawableWidth: 3202, drawableHeight: 1801)
        #expect(nearDouble.size == CGSize(width: 3200, height: 1800))
        #expect(VideoGeometry.wholeMagnification(content: content, viewport: nearDouble) == 2)
        // Pillarboxed 2×.
        let wide = VideoGeometry.pixelViewport(content: content, drawableWidth: 3600, drawableHeight: 1800)
        #expect(wide == CGRect(x: 200, y: 0, width: 3200, height: 1800))
        // 1.9×: scaled, filtered.
        let between = VideoGeometry.pixelViewport(content: content, drawableWidth: 3040, drawableHeight: 1710)
        #expect(VideoGeometry.wholeMagnification(content: content, viewport: between) == nil)
        // Minified: never whole.
        let small = VideoGeometry.pixelViewport(content: content, drawableWidth: 800, drawableHeight: 450)
        #expect(VideoGeometry.wholeMagnification(content: content, viewport: small) == nil)
        #expect(VideoGeometry.wholeMagnification(content: content,
                                                 viewport: CGRect(x: 0, y: 0, width: 1600, height: 900)) == 1)
    }

    @Test func videoRectMatchesTheRendererViewportInPoints() {
        // Retina: an 800×450 pt view is a 1600×900 px drawable → the whole view, 1:1.
        let retina = VideoGeometry.videoRect(content: CGSize(width: 1600, height: 900),
                                             bounds: CGRect(x: 0, y: 0, width: 800, height: 450), scale: 2,
                                             viewIsFlipped: false)
        #expect(retina == CGRect(x: 0, y: 0, width: 800, height: 450))
        // Letterbox in an unflipped view: the bar split rounds down at the top, so y is measured from the bottom.
        let box = VideoGeometry.videoRect(content: CGSize(width: 1280, height: 720),
                                          bounds: CGRect(x: 0, y: 0, width: 400, height: 400), scale: 1,
                                          viewIsFlipped: false)
        #expect(box == CGRect(x: 0, y: 88, width: 400, height: 225))
        let flipped = VideoGeometry.videoRect(content: CGSize(width: 1280, height: 720),
                                              bounds: CGRect(x: 0, y: 0, width: 400, height: 400), scale: 1,
                                              viewIsFlipped: true)
        #expect(flipped == CGRect(x: 0, y: 87, width: 400, height: 225))
        #expect(VideoGeometry.videoRect(content: .zero, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 2,
                                        viewIsFlipped: false) == .zero)
    }

    @Test func drawableSizeIsTheViewInDevicePixels() {
        #expect(VideoGeometry.drawableSize(bounds: CGRect(x: 0, y: 0, width: 800, height: 450), scale: 2) == (1600, 900))
        #expect(VideoGeometry.drawableSize(bounds: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 0) == (100, 50))
        #expect(VideoGeometry.drawableSize(bounds: CGRect(x: 0, y: 0, width: 20000, height: 10), scale: 1).width == 16384)
    }

    // MARK: Viewer window sizing

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)   // 14" MacBook Pro visible frame (pt)

    @Test func actualSizeOnRetinaShowsTheStreamPixelForPixel() throws {
        // Window 1100×760 with 76 pt of chrome above the video (title bar + toolbar): video 1100×684.
        let window = CGRect(x: 100, y: 100, width: 1100, height: 760)
        let frame = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: CGSize(width: 1100, height: 684),
            streamPixels: CGSize(width: 1600, height: 900), backingScale: 2, visibleFrame: screen))
        #expect(frame.size == CGSize(width: 800, height: 450 + 76))
        #expect(frame.maxY == window.maxY)   // top-left corner kept
        #expect(frame.minX == window.minX)
    }

    @Test func actualSizeOnOneXFitsWhenTooLarge() throws {
        // 1× screen of 1440×875 visible: 1600×900 pt does not fit → largest aspect-preserving size that does.
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let window = CGRect(x: 50, y: 100, width: 1100, height: 760)
        let frame = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: CGSize(width: 1100, height: 684),
            streamPixels: CGSize(width: 1600, height: 900), backingScale: 1, visibleFrame: visible))
        #expect(frame.width <= visible.width && frame.height <= visible.height)
        let video = CGSize(width: frame.width, height: frame.height - 76)
        #expect(abs(video.width / video.height - 16.0 / 9.0) < 0.01)
        #expect(visible.contains(frame))
        // Fits on a 1080p screen at 1×: exactly 1600×900 of video.
        let big = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: CGSize(width: 1100, height: 684),
            streamPixels: CGSize(width: 1600, height: 900), backingScale: 1,
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)))
        #expect(big.size == CGSize(width: 1600, height: 976))
    }

    /// The reported setup at session start: a 1× Host at 1600×900 on a Retina laptop. Strict 1:1 would be an
    /// 800×450 pt picture (remote UI at half its physical size); automatic sizing fills the screen instead.
    @Test func automaticSizingDoesNotShrinkA1xHostOnRetina() throws {
        let window = CGRect(x: 100, y: 100, width: 1100, height: 760)
        let frame = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: CGSize(width: 1100, height: 684),
            streamPixels: CGSize(width: 1600, height: 900), backingScale: 2, visibleFrame: screen, sizing: .automatic))
        let video = CGSize(width: frame.width, height: frame.height - 76)
        #expect(video.width > 1400, "video \(video)")
        #expect(abs(video.width / video.height - 16.0 / 9.0) < 0.01)
        #expect(screen.contains(frame))
        #expect((video.width * 2).rounded() == video.width * 2)   // whole device pixels
    }

    @Test func automaticSizingPrefersAWholeMagnification() throws {
        let window = CGRect(x: 0, y: 0, width: 1100, height: 760)
        let videoArea = CGSize(width: 1100, height: 684)
        // 27" 5K Retina (2560×1415 pt visible): 2× (1600×900 pt, pixel doubling) fits, 3× does not.
        let fiveK = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let doubled = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: videoArea, streamPixels: CGSize(width: 1600, height: 900),
            backingScale: 2, visibleFrame: fiveK, sizing: .automatic))
        #expect(doubled.size == CGSize(width: 1600, height: 900 + 76))
        // A 1× 1080p screen: 1:1 fits and is most of the screen.
        let oneX = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: videoArea, streamPixels: CGSize(width: 1600, height: 900),
            backingScale: 1, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), sizing: .automatic))
        #expect(oneX.size == CGSize(width: 1600, height: 976))
        // Too large even at 1:1: as large as fits, like Actual Size.
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let fit = VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: videoArea, streamPixels: CGSize(width: 1600, height: 900),
            backingScale: 1, visibleFrame: visible, sizing: .automatic)
        let actual = VideoGeometry.actualSizeWindowFrame(
            windowFrame: window, videoArea: videoArea, streamPixels: CGSize(width: 1600, height: 900),
            backingScale: 1, visibleFrame: visible)
        #expect(fit == actual)
    }

    @Test func actualSizeRespectsTheMinimumAndStaysOnScreen() throws {
        // A 640×360 stream on Retina wants 320×180 pt of video; the window minimum wins on both axes.
        let frame = try #require(VideoGeometry.actualSizeWindowFrame(
            windowFrame: CGRect(x: 1400, y: 800, width: 1100, height: 760), videoArea: CGSize(width: 1100, height: 684),
            streamPixels: CGSize(width: 640, height: 360), backingScale: 2, visibleFrame: screen,
            minimumFrameSize: CGSize(width: 480, height: 328)))
        #expect(frame.size == CGSize(width: 480, height: 328))
        #expect(screen.contains(frame))
        #expect(VideoGeometry.actualSizeWindowFrame(windowFrame: .zero, videoArea: .zero, streamPixels: .zero,
                                                    backingScale: 2, visibleFrame: screen) == nil)
    }
}
