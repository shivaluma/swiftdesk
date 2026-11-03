import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Testing
@testable import CaptureCore

/// Building an `SCStreamConfiguration` needs no permission, so the exact values handed to ScreenCaptureKit are tested.
@Suite("CaptureStreamSettings")
struct CaptureStreamSettingsTests {
    @Test("Retina 16:10 display: 1114x720, nominal sampling, 420v BT.709, no cursor, no audio")
    func retinaConfiguration() {
        let settings = CaptureStreamSettings(config: CaptureConfig(maxWidth: 1280, maxHeight: 720), pixelWidth: 3456,
                                             pixelHeight: 2234,
                                             pointSize: CGSize(width: 1728, height: 1117))
        #expect(settings.width == 1114 && settings.height == 720)
        #expect(settings.usesNominalResolution)
        #expect(settings.minimumFrameInterval == CMTime(value: 1, timescale: 60))

        let c = settings.makeConfiguration()
        #expect(c.width == 1114)
        #expect(c.height == 720)
        #expect(c.minimumFrameInterval == CMTime(value: 1, timescale: 60))
        #expect(c.queueDepth == 4)
        #expect(c.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect((c.colorMatrix as String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
        #expect((c.colorMatrix as String) == "ITU_R_709_2")
        #expect((c.colorSpaceName as String) == (CGColorSpace.sRGB as String))
        #expect(c.showsCursor == false)
        #expect(c.showMouseClicks == false)
        #expect(c.capturesAudio == false)
        #expect(c.captureMicrophone == false)
        #expect(c.captureResolution == .nominal)
        #expect(c.preservesAspectRatio == false)
        #expect(c.captureDynamicRange == .SDR)
    }

    @Test("Small point raster falls back to backing resolution to avoid upscaling")
    func smallPointRasterUsesBest() {
        // 1024x640 points at 2x: output 1152x720 is larger than the point raster.
        let settings = CaptureStreamSettings(config: CaptureConfig(maxWidth: 1280, maxHeight: 720), pixelWidth: 2048,
                                             pixelHeight: 1280,
                                             pointSize: CGSize(width: 1024, height: 640))
        #expect(settings.width == 1152 && settings.height == 720)
        #expect(settings.usesNominalResolution == false)
        #expect(settings.makeConfiguration().captureResolution == .best)
    }

    /// The reported case: a 1600×900 (virtual) display without HiDPI was streamed at 1280×720 and looked soft.
    /// With the default (Sharp top-rung) bounds it is captured pixel for pixel.
    @Test("Non-HiDPI 1600x900 display is captured at exactly 1600x900 with the default bounds")
    func nativeNonRetinaCapture() {
        let settings = CaptureStreamSettings(config: CaptureConfig(), pixelWidth: 1600, pixelHeight: 900,
                                             pointSize: CGSize(width: 1600, height: 900))
        #expect(settings.width == 1600 && settings.height == 900)
        #expect(settings.usesNominalResolution)   // points == pixels: nominal and best are the same raster
        let c = settings.makeConfiguration()
        #expect(c.width == 1600 && c.height == 900)
    }

    /// Bounds are compared with the display's *pixel* size: a HiDPI display is captured at up to 1920×1080 backing
    /// pixels (aspect preserved), not at its smaller point size.
    @Test("HiDPI display is bounded in pixels, sampled from the backing raster when points are too small")
    func hidpiCaptureUsesPixels() {
        // 1440x900 pt at 2x = 2880x1800 px → 1728x1080; 1440 pt < 1728 px, so nominal would upscale → .best.
        let settings = CaptureStreamSettings(config: CaptureConfig(), pixelWidth: 2880, pixelHeight: 1800,
                                             pointSize: CGSize(width: 1440, height: 900))
        #expect(settings.width == 1728 && settings.height == 1080)
        #expect(settings.usesNominalResolution == false)
        #expect(settings.makeConfiguration().captureResolution == .best)
        // 1920x1200 pt at 2x (3840x2400 px): the point raster is already ≥ the 1728x1080 output → nominal.
        let large = CaptureStreamSettings(config: CaptureConfig(), pixelWidth: 3840, pixelHeight: 2400,
                                          pointSize: CGSize(width: 1920, height: 1200))
        #expect(large.width == 1728 && large.height == 1080)
        #expect(large.usesNominalResolution)
    }

    @Test("Config values propagate and are sanitized")
    func propagation() {
        let config = CaptureConfig(maxWidth: 960, maxHeight: 540, fps: 30, showsCursor: true, queueDepth: 1)
        let settings = CaptureStreamSettings(config: config, pixelWidth: 1920, pixelHeight: 1080,
                                             pointSize: CGSize(width: 1920, height: 1080))
        let c = settings.makeConfiguration()
        #expect(c.width == 960 && c.height == 540)
        #expect(c.minimumFrameInterval == CMTime(value: 1, timescale: 30))
        #expect(c.queueDepth == 3)
        #expect(c.showsCursor == true)
    }
}
