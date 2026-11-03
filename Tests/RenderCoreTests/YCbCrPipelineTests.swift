import CoreVideo
import Foundation
import Metal
import Testing
@testable import RenderCore

/// Offscreen GPU tests: same shader source, pipeline, texture cache and encode path as the on-screen renderer.
/// Skipped gracefully on machines without a Metal device (e.g. some VMs/CI).
@Suite("YCbCr Metal pipeline")
struct YCbCrPipelineTests {
    static let device = MTLCreateSystemDefaultDevice()
    static var hasMetal: Bool { device != nil }

    struct RGB8: CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
    }

    // MARK: Helpers

    /// BT.709 limited-range encoding of linear-light-agnostic R'G'B' in [0, 1] (the inverse of the shader).
    static func ycbcr709Video(r: Double, g: Double, b: Double) -> (UInt8, UInt8, UInt8) {
        let kr = 0.2126, kb = 0.0722, kg = 1 - kr - kb
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2 * (1 - kb))
        let cr = (r - y) / (2 * (1 - kr))
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        return (q(16 + 219 * y), q(128 + 224 * cb), q(128 + 224 * cr))
    }

    /// IOSurface-backed, Metal-compatible bi-planar buffer. `fill(x, y)` returns (Y, Cb, Cr) for a luma pixel;
    /// chroma uses the value at the top-left luma pixel of each 2×2 block.
    static func makePixelBuffer(width: Int, height: Int,
                                format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                fill: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &out)
        let buffer = try #require(out, "CVPixelBufferCreate failed: \(status)")
        #expect(CVPixelBufferGetIOSurface(buffer) != nil)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let yBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            for col in 0..<width { yBase[row * yStride + col] = fill(col, row).0 }
        }
        let cBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for col in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                let v = fill(col * 2, row * 2)
                cBase[row * cStride + col * 2] = v.1
                cBase[row * cStride + col * 2 + 1] = v.2
            }
        }
        return buffer
    }

    /// Renders `buffer` into a `width`×`height` bgra8Unorm texture and returns the pixels as BGRA bytes.
    static func render(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        let device = try #require(Self.device)
        let pipeline = try YCbCrPipeline(device: device, colorPixelFormat: .bgra8Unorm)
        let cache = try PlaneTextureCache(device: device)
        let planes = try #require(cache.textures(for: buffer))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let bytesPerRow = width * 4
        let readback = try #require(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))

        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        #expect(pipeline.encode(into: commandBuffer, target: target, planes: planes))
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "GPU error: \(String(describing: commandBuffer.error))")
        withExtendedLifetime(planes) {}
        let ptr = readback.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: bytesPerRow * height))
    }

    static func pixel(_ bgra: [UInt8], width: Int, x: Int, y: Int) -> RGB8 {
        let i = (y * width + x) * 4
        return RGB8(r: Int(bgra[i + 2]), g: Int(bgra[i + 1]), b: Int(bgra[i]))
    }

    static func close(_ p: RGB8, _ r: Int, _ g: Int, _ b: Int, tol: Int = 4) -> Bool {
        abs(p.r - r) <= tol && abs(p.g - g) <= tol && abs(p.b - b) <= tol
    }

    // MARK: CPU-side math

    @Test func paramsInvertTheEncoding() {
        let p = YCbCrParams.bt709VideoRange
        func apply(_ y: UInt8, _ cb: UInt8, _ cr: UInt8) -> SIMD3<Float> {
            let v = SIMD4<Float>(Float(y) / 255, Float(cb) / 255, Float(cr) / 255, 0) - p.offset
            func dot(_ row: SIMD4<Float>) -> Float { (row * v).sum() }
            return SIMD3(dot(p.rowR), dot(p.rowG), dot(p.rowB))
        }
        let white = apply(235, 128, 128)
        let black = apply(16, 128, 128)
        #expect(abs(white.x - 1) < 1e-5 && abs(white.y - 1) < 1e-5 && abs(white.z - 1) < 1e-5)
        #expect(abs(black.x) < 1e-5 && abs(black.y) < 1e-5 && abs(black.z) < 1e-5)
        let red = apply(63, 102, 240)
        #expect(abs(red.x - 1) < 0.02 && abs(red.y) < 0.02 && abs(red.z) < 0.02)
        #expect(MemoryLayout<YCbCrParams>.size == 64)
    }

    @Test func pixelFormatSelection() {
        #expect(YCbCrParams.forPixelFormat(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) == .bt709VideoRange)
        #expect(YCbCrParams.forPixelFormat(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) == .bt709FullRange)
        #expect(YCbCrParams.forPixelFormat(kCVPixelFormatType_32BGRA) == nil)
    }

    // MARK: GPU

    @Test(.enabled(if: hasMetal)) func shaderSourceCompilesAndPipelineBuilds() throws {
        let device = try #require(Self.device)
        let library = try device.makeLibrary(source: YCbCrPipeline.shaderSource, options: MTLCompileOptions())
        #expect(library.makeFunction(name: YCbCrPipeline.vertexFunctionName) != nil)
        #expect(library.makeFunction(name: YCbCrPipeline.fragmentFunctionName) != nil)
        let pipeline = try YCbCrPipeline(device: device)
        #expect(pipeline.colorPixelFormat == .bgra8Unorm)
    }

    @Test(.enabled(if: hasMetal)) func textureCacheMapsBothPlanesZeroCopy() throws {
        let device = try #require(Self.device)
        let cache = try PlaneTextureCache(device: device)
        let buffer = try Self.makePixelBuffer(width: 64, height: 32) { _, _ in (16, 128, 128) }
        let planes = try #require(cache.textures(for: buffer))
        #expect(planes.luma.pixelFormat == .r8Unorm)
        #expect(planes.chroma.pixelFormat == .rg8Unorm)
        #expect(planes.luma.width == 64 && planes.luma.height == 32)
        #expect(planes.chroma.width == 32 && planes.chroma.height == 16)
        #expect(planes.contentSize == CGSize(width: 64, height: 32))
        // Zero-copy: the textures alias the pixel buffer's IOSurface.
        #expect(planes.luma.iosurface === CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
        cache.flush()
    }

    @Test(.enabled(if: hasMetal)) func unsupportedFormatIsRejected() throws {
        let device = try #require(Self.device)
        let cache = try PlaneTextureCache(device: device)
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        let bgra = try #require(out)
        #expect(cache.textures(for: bgra) == nil)
    }

    @Test(.enabled(if: hasMetal), arguments: [
        (1.0, 1.0, 1.0), (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0),
        (0.5, 0.5, 0.5), (0.25, 0.5, 0.75), (0.9, 0.6, 0.1),
    ])
    func videoRangeColourConversion(r: Double, g: Double, b: Double) throws {
        let (y, cb, cr) = Self.ycbcr709Video(r: r, g: g, b: b)
        let buffer = try Self.makePixelBuffer(width: 32, height: 32) { _, _ in (y, cb, cr) }
        let pixels = try Self.render(buffer, width: 32, height: 32)
        let p = Self.pixel(pixels, width: 32, x: 16, y: 16)
        let expected = (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        #expect(Self.close(p, expected.0, expected.1, expected.2), "Y=\(y) Cb=\(cb) Cr=\(cr) → \(p), expected \(expected)")
    }

    @Test(.enabled(if: hasMetal)) func videoRangeWhiteAndBlackHitTheRails() throws {
        let white = try Self.render(try Self.makePixelBuffer(width: 16, height: 16) { _, _ in (235, 128, 128) },
                                    width: 16, height: 16)
        #expect(Self.close(Self.pixel(white, width: 16, x: 8, y: 8), 255, 255, 255, tol: 1))
        let black = try Self.render(try Self.makePixelBuffer(width: 16, height: 16) { _, _ in (16, 128, 128) },
                                    width: 16, height: 16)
        #expect(Self.close(Self.pixel(black, width: 16, x: 8, y: 8), 0, 0, 0, tol: 1))
        // Footroom/headroom values are clamped, never wrap.
        let superWhite = try Self.render(try Self.makePixelBuffer(width: 16, height: 16) { _, _ in (255, 128, 128) },
                                         width: 16, height: 16)
        #expect(Self.close(Self.pixel(superWhite, width: 16, x: 8, y: 8), 255, 255, 255, tol: 0))
    }

    @Test(.enabled(if: hasMetal)) func fullRangeFormatUsesFullRangeMatrix() throws {
        let buffer = try Self.makePixelBuffer(width: 16, height: 16,
                                              format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { _, _ in (255, 128, 128) }
        let pixels = try Self.render(buffer, width: 16, height: 16)
        #expect(Self.close(Self.pixel(pixels, width: 16, x: 8, y: 8), 255, 255, 255, tol: 1))
        let mid = try Self.render(try Self.makePixelBuffer(width: 16, height: 16,
                                                           format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { _, _ in (128, 128, 128) },
                                  width: 16, height: 16)
        #expect(Self.close(Self.pixel(mid, width: 16, x: 8, y: 8), 128, 128, 128, tol: 2))
    }

    @Test(.enabled(if: hasMetal)) func imageIsNotFlippedOrMirrored() throws {
        // Top half white, bottom half black; left/right halves differ in chroma (red vs blue tint).
        let red = Self.ycbcr709Video(r: 1, g: 0, b: 0)
        let blue = Self.ycbcr709Video(r: 0, g: 0, b: 1)
        let buffer = try Self.makePixelBuffer(width: 64, height: 64) { x, y in
            y < 32 ? (x < 32 ? red : blue) : (16, 128, 128)
        }
        let pixels = try Self.render(buffer, width: 64, height: 64)
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 8, y: 8), 255, 0, 0, tol: 6))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 56, y: 8), 0, 0, 255, tol: 6))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 56), 0, 0, 0, tol: 2))
    }

    @Test(.enabled(if: hasMetal)) func letterboxBarsAreClearedToBlack() throws {
        // 2:1 white content in a square target: rows above/below the 64×32 viewport stay black.
        let buffer = try Self.makePixelBuffer(width: 128, height: 64) { _, _ in (235, 128, 128) }
        let pixels = try Self.render(buffer, width: 64, height: 64)
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 2), 0, 0, 0, tol: 0))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 15), 0, 0, 0, tol: 0))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 16), 255, 255, 255, tol: 1))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 47), 255, 255, 255, tol: 1))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 48), 0, 0, 0, tol: 0))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 61), 0, 0, 0, tol: 0))
    }

    @Test(.enabled(if: hasMetal)) func pillarboxBarsAreClearedToBlack() throws {
        let buffer = try Self.makePixelBuffer(width: 32, height: 64) { _, _ in (235, 128, 128) }
        let pixels = try Self.render(buffer, width: 64, height: 64)
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 4, y: 32), 0, 0, 0, tol: 0))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 32, y: 32), 255, 255, 255, tol: 1))
        #expect(Self.close(Self.pixel(pixels, width: 64, x: 60, y: 32), 0, 0, 0, tol: 0))
    }

    /// A target within a pixel or two of the frame size draws the frame pixel for pixel (nearest luma sampling, with
    /// a one-pixel bar), so 1-pixel text strokes stay exactly black and white instead of being resampled to grey.
    @Test(.enabled(if: hasMetal)) func nearOneToOneTargetIsDrawnPixelForPixel() throws {
        let buffer = try Self.makePixelBuffer(width: 32, height: 16) { x, _ in x % 2 == 0 ? (235, 128, 128) : (16, 128, 128) }
        let pixels = try Self.render(buffer, width: 34, height: 18)
        for x in 0..<32 {
            let p = Self.pixel(pixels, width: 34, x: 1 + x, y: 8)
            let expected = x % 2 == 0 ? 255 : 0
            #expect(Self.close(p, expected, expected, expected, tol: 1), "column \(x): \(p)")
        }
        #expect(Self.close(Self.pixel(pixels, width: 34, x: 0, y: 8), 0, 0, 0, tol: 0))   // the bar
    }

    /// An exact 2× target (a 1× Host's stream in a same-point-size view on Retina) is clean pixel doubling: every
    /// frame pixel covers exactly 2×2 target pixels, so alternating 1-pixel columns stay pure black and white.
    @Test(.enabled(if: hasMetal)) func exactDoubleTargetIsPixelDoubled() throws {
        let buffer = try Self.makePixelBuffer(width: 32, height: 16) { x, _ in x % 2 == 0 ? (235, 128, 128) : (16, 128, 128) }
        let pixels = try Self.render(buffer, width: 64, height: 32)
        for x in 0..<64 {
            let p = Self.pixel(pixels, width: 64, x: x, y: 16)
            let expected = (x / 2) % 2 == 0 ? 255 : 0
            #expect(Self.close(p, expected, expected, expected, tol: 1), "column \(x): \(p)")
        }
    }

    @Test(.enabled(if: hasMetal)) func clearOnlyPassIsBlack() throws {
        let device = try #require(Self.device)
        let pipeline = try YCbCrPipeline(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let readback = try #require(device.makeBuffer(length: 8 * 8 * 4, options: .storageModeShared))
        let commandBuffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        #expect(pipeline.encode(into: commandBuffer, target: target, planes: nil))
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 8, height: 8, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: 32, destinationBytesPerImage: 256)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bytes = UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: UInt8.self), count: 256)
        for i in stride(from: 0, to: 256, by: 4) {
            #expect(bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 255)
        }
    }
}
