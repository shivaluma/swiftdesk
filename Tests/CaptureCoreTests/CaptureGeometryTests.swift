import CoreGraphics
import Testing
@testable import CaptureCore

@Suite("CaptureGeometry.fit")
struct CaptureGeometryTests {
    private func fit(_ w: Int, _ h: Int, max mw: Int = 1280, _ mh: Int = 720) -> (width: Int, height: Int) {
        CaptureGeometry.fit(sourceWidth: w, sourceHeight: h, maxWidth: mw, maxHeight: mh)
    }

    @Test("16:9 sources scale exactly to 1280x720", arguments: [(1920, 1080), (2560, 1440), (3840, 2160), (5120, 2880), (1280, 720)])
    func sixteenByNine(source: (Int, Int)) {
        let size = fit(source.0, source.1)
        #expect(size.width == 1280)
        #expect(size.height == 720)
    }

    @Test("16:10 MacBook Pro 3456x2234 is height-limited and keeps aspect")
    func sixteenByTenMacBookPro() {
        let size = fit(3456, 2234)
        #expect(size.height == 720)
        #expect(size.width == 1114)   // 3456 * 720/2234 = 1113.8 -> nearest even
        let sourceAspect = 3456.0 / 2234.0
        let outputAspect = Double(size.width) / Double(size.height)
        #expect(abs(outputAspect - sourceAspect) / sourceAspect < 0.003)
    }

    @Test("16:10 2880x1800 -> 1152x720")
    func sixteenByTen() {
        let size = fit(2880, 1800)
        #expect(size.width == 1152)
        #expect(size.height == 720)
    }

    @Test("4:3 -> 960x720")
    func fourByThree() {
        let size = fit(2048, 1536)
        #expect(size.width == 960)
        #expect(size.height == 720)
    }

    @Test("Ultrawide 21:9 is width-limited")
    func ultrawide() {
        let size = fit(3440, 1440)
        #expect(size.width == 1280)
        #expect(size.height == 536)   // 1440 * 1280/3440 = 535.8 -> 536
    }

    @Test("Portrait displays are height-limited")
    func portrait() {
        let size = fit(1440, 2560)
        #expect(size.height == 720)
        #expect(size.width == 406)    // 1440 * 720/2560 = 405 -> nearest even (ties away from zero) 406
        #expect(size.width <= 1280)
    }

    @Test("Sources smaller than the bounds are never upscaled", arguments: [(1024, 576), (800, 600), (640, 480), (320, 200)])
    func tinySourcesNotUpscaled(source: (Int, Int)) {
        let size = fit(source.0, source.1)
        #expect(size.width == source.0)
        #expect(size.height == source.1)
    }

    @Test("Odd small sources round down to even, never above the source")
    func oddSmallSources() {
        let size = fit(1023, 575)
        #expect(size.width == 1022)
        #expect(size.height == 574)
    }

    @Test("Odd bounds produce even results within the bounds")
    func oddBounds() {
        let size = fit(1920, 1080, max: 1279, 719)
        #expect(size.width <= 1279 && size.height <= 719)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }

    @Test("1600x900 is never resampled by the 1920x1080 Sharp bound, and is 0.8x in the old 1280x720 bound")
    func nativeSharpRung() {
        let native = fit(1600, 900, max: 1920, 1080)
        #expect(native.width == 1600 && native.height == 900)
        let old = fit(1600, 900, max: 1280, 720)
        #expect(old.width == 1280 && old.height == 720)
        // 1920x1200 (16:10) fills the bound's height.
        let wide = fit(1920, 1200, max: 1920, 1080)
        #expect(wide.width == 1728 && wide.height == 1080)
    }

    @Test("Smaller ladder rung 960x540")
    func ladderRung() {
        let size = fit(3456, 2234, max: 960, 540)
        #expect(size.height == 540)
        #expect(size.width == 836)    // 3456 * 540/2234 = 835.4 -> 836
    }

    @Test("Degenerate inputs")
    func degenerate() {
        #expect(fit(0, 1080) == (0, 0))
        #expect(fit(1920, -1) == (0, 0))
        let tinyBounds = fit(1920, 1080, max: 0, 0)
        #expect(tinyBounds.width == 2 && tinyBounds.height == 2)
        let oneByOne = fit(1, 1)
        #expect(oneByOne.width == 2 && oneByOne.height == 2)   // documented minimum
    }

    @Test("CGSize overload rounds points")
    func cgSizeOverload() {
        let size = CaptureGeometry.fit(source: CGSize(width: 1728, height: 1117), maxWidth: 1280, maxHeight: 720)
        #expect(size.height == 720)
        #expect(size.width == 1114)
    }

    @Test("Exhaustive invariants over many sources and bounds")
    func invariants() {
        let bounds = [(1280, 720), (960, 540), (1279, 719), (640, 360), (1920, 1080)]
        var checked = 0
        for w in stride(from: 2, through: 6016, by: 97) {
            for h in stride(from: 2, through: 3384, by: 89) {
                for (mw, mh) in bounds {
                    let size = fit(w, h, max: mw, mh)
                    #expect(size.width % 2 == 0 && size.height % 2 == 0, "odd output for \(w)x\(h) in \(mw)x\(mh)")
                    #expect(size.width <= mw && size.height <= mh, "exceeds max for \(w)x\(h) in \(mw)x\(mh)")
                    #expect(size.width <= max(2, w) && size.height <= max(2, h), "upscaled \(w)x\(h)")
                    #expect(size.width >= 2 && size.height >= 2)
                    // At least one dimension is (within even rounding) at its limit: the fit is maximal.
                    let limitW = min(mw, w) & ~1, limitH = min(mh, h) & ~1
                    #expect(size.width >= limitW - 2 || size.height >= limitH - 2, "not maximal for \(w)x\(h) in \(mw)x\(mh)")
                    // Aspect error stays within what one even-pixel rounding step can cause.
                    if size.width >= 64 && size.height >= 64 {
                        let srcAspect = Double(w) / Double(h)
                        let outAspect = Double(size.width) / Double(size.height)
                        let tolerance = 2.0 / Double(size.width) + 2.0 / Double(size.height)
                        #expect(abs(outAspect / srcAspect - 1) <= tolerance, "aspect drift for \(w)x\(h) -> \(size)")
                    }
                    checked += 1
                }
            }
        }
        #expect(checked > 10_000)
    }
}

@Suite("CaptureConfig")
struct CaptureConfigTests {
    @Test("Defaults are the Sharp top rung: bounds of 1920x1080 at 60 fps")
    func defaults() {
        let config = CaptureConfig()
        #expect(config.maxWidth == 1920)
        #expect(config.maxHeight == 1080)
        #expect(config.fps == 60)
        #expect(config.showsCursor == false)
        #expect(config.queueDepth == 4)   // 3 + the surface the encoder retains for static-screen refresh
        #expect(config.sanitized == config)
    }

    @Test("Sanitizing never yields queueDepth 1, a zero frame rate or empty bounds")
    func sanitized() {
        let bad = CaptureConfig(maxWidth: 0, maxHeight: -5, fps: 0, showsCursor: true, queueDepth: 1).sanitized
        #expect(bad.queueDepth == 3)
        #expect(bad.fps == 1)
        #expect(bad.maxWidth == 2 && bad.maxHeight == 2)
        #expect(bad.showsCursor)
        let high = CaptureConfig(fps: 500, queueDepth: 20).sanitized
        #expect(high.fps == CaptureConfig.maximumFPS)
        #expect(high.queueDepth == CaptureConfig.maximumQueueDepth)
    }
}
