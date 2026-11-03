import CoreGraphics
import CoreVideo
import Metal

/// Errors raised while building GPU resources. Messages never contain frame content.
enum RenderSetupError: Error, Equatable {
    case noDevice
    case libraryCompilation(String)
    case missingFunction(String)
    case pipelineCreation(String)
    case textureCacheCreation(CVReturn)
    case commandQueueCreation
}

/// BT.709 / BT.601-agnostic affine YCbCr → RGB transform, laid out to match the MSL `YCbCrParams` struct
/// (four `float4`, 64 bytes) so it can be passed with `setFragmentBytes` without a per-frame buffer allocation.
struct YCbCrParams: Equatable {
    /// Subtracted from (Y, Cb, Cr) before the matrix (w unused).
    var offset: SIMD4<Float>
    /// Rows of the 3×3 matrix applied to the offset-corrected (Y, Cb, Cr) (w unused).
    var rowR: SIMD4<Float>
    var rowG: SIMD4<Float>
    var rowB: SIMD4<Float>

    /// BT.709 limited ("video") range: Y ∈ [16, 235], Cb/Cr ∈ [16, 240] — what ScreenCaptureKit and the
    /// VideoToolbox decoder produce for `420v`.
    static let bt709VideoRange: YCbCrParams = {
        let yScale: Float = 255.0 / 219.0
        let cScale: Float = 255.0 / 224.0
        return make(kr: 0.2126, kb: 0.0722, yScale: yScale, cScale: cScale, yOffset: 16.0 / 255.0)
    }()

    /// BT.709 full range (`420f`), accepted so a decoder configured for full range still renders correctly.
    static let bt709FullRange: YCbCrParams =
        make(kr: 0.2126, kb: 0.0722, yScale: 1, cScale: 1, yOffset: 0)

    private static func make(kr: Float, kb: Float, yScale: Float, cScale: Float, yOffset: Float) -> YCbCrParams {
        let kg = 1 - kr - kb
        let crToR = 2 * (1 - kr) * cScale
        let cbToB = 2 * (1 - kb) * cScale
        let cbToG = -2 * kb * (1 - kb) / kg * cScale
        let crToG = -2 * kr * (1 - kr) / kg * cScale
        return YCbCrParams(offset: SIMD4(yOffset, 128.0 / 255.0, 128.0 / 255.0, 0),
                           rowR: SIMD4(yScale, 0, crToR, 0),
                           rowG: SIMD4(yScale, cbToG, crToG, 0),
                           rowB: SIMD4(yScale, cbToB, 0, 0))
    }

    /// Conversion for a pixel format, or nil when the format is not 8-bit 4:2:0 bi-planar.
    static func forPixelFormat(_ format: OSType) -> YCbCrParams? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return .bt709VideoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return .bt709FullRange
        default: return nil
        }
    }
}

/// The two plane textures of one 4:2:0 bi-planar pixel buffer.
///
/// Holds the `CVMetalTexture` objects, not just the `MTLTexture`s: Core Video only guarantees the IOSurface
/// mapping while the `CVMetalTexture` is alive, so these must be retained until the command buffer that
/// samples them has completed. `@unchecked Sendable` because it is created on the render queue and only
/// handed, immutably, to that command buffer's completion handler.
struct PlaneTextures: @unchecked Sendable {
    let lumaRef: CVMetalTexture
    let chromaRef: CVMetalTexture
    let luma: MTLTexture
    let chroma: MTLTexture
    let params: YCbCrParams
    let contentSize: CGSize
}

/// Zero-copy mapping of decoder output (IOSurface-backed `CVPixelBuffer`) into Metal textures.
///
/// Not thread-safe by itself; RenderCore uses it only from the render queue (tests use it from one thread).
final class PlaneTextureCache {
    let cache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        var out: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &out)
        guard status == kCVReturnSuccess, let out else { throw RenderSetupError.textureCacheCreation(status) }
        cache = out
    }

    /// Maps plane 0 as `r8Unorm` (Y) and plane 1 as `rg8Unorm` (CbCr). Returns nil for unsupported formats.
    func textures(for pixelBuffer: CVPixelBuffer) -> PlaneTextures? {
        guard let params = YCbCrParams.forPixelFormat(CVPixelBufferGetPixelFormatType(pixelBuffer)),
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let luma = makeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = makeTexture(pixelBuffer, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return PlaneTextures(lumaRef: luma, chromaRef: chroma, luma: lumaTexture, chroma: chromaTexture,
                             params: params, contentSize: size)
    }

    /// Lets Core Video release IOSurface mappings that are no longer referenced (housekeeping, not per frame).
    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        guard width > 0, height > 0 else { return nil }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
                                                               format, width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }
}

/// Compiled YCbCr → RGB render pipeline (immutable after init, so safe to share across threads).
///
/// The shader is compiled at runtime from `shaderSource` with `makeLibrary(source:options:)`: SwiftPM does not
/// build `.metal` files, and runtime compilation works whether or not the `metal` CLI toolchain is installed.
/// The cost (tens of milliseconds) is paid once, off the main thread, on the render queue.
final class YCbCrPipeline: @unchecked Sendable {
    static let vertexFunctionName = "swiftdesk_video_vertex"
    static let fragmentFunctionName = "swiftdesk_video_fragment"

    /// Full-screen quad generated from `vertex_id` (no vertex buffer). Aspect-fit is done with the viewport, so
    /// the quad always covers the viewport and the letterbox bars are just the render pass clear colour.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VideoVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct YCbCrParams {
        float4 offset;
        float4 rowR;
        float4 rowG;
        float4 rowB;
    };

    // Triangle strip: 0 = bottom-left, 1 = bottom-right, 2 = top-left, 3 = top-right.
    vertex VideoVertexOut swiftdesk_video_vertex(uint vid [[vertex_id]]) {
        float2 ndc = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        VideoVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        // Texture origin is the top-left of the image; NDC +y is up.
        out.uv = float2((ndc.x + 1.0) * 0.5, (1.0 - ndc.y) * 0.5);
        return out;
    }

    fragment float4 swiftdesk_video_fragment(VideoVertexOut in [[stage_in]],
                                             texture2d<float, access::sample> lumaTexture [[texture(0)]],
                                             texture2d<float, access::sample> chromaTexture [[texture(1)]],
                                             constant YCbCrParams &p [[buffer(0)]],
                                             sampler lumaSampler [[sampler(0)]]) {
        // Chroma is half resolution (4:2:0), so it is always interpolated; luma uses the sampler the host picks:
        // nearest when the viewport is exactly the frame size or a whole multiple of it, linear otherwise.
        constexpr sampler chromaSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float y = lumaTexture.sample(lumaSampler, in.uv).r;
        float2 cbcr = chromaTexture.sample(chromaSampler, in.uv).rg;
        float3 ycc = float3(y, cbcr.x, cbcr.y) - p.offset.xyz;
        float3 rgb = float3(dot(p.rowR.xyz, ycc), dot(p.rowG.xyz, ycc), dot(p.rowB.xyz, ycc));
        return float4(saturate(rgb), 1.0);
    }
    """

    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState
    let colorPixelFormat: MTLPixelFormat
    /// Luma sampler for a viewport that is exactly the frame size or a whole multiple of it: every pixel takes
    /// exactly one texel (1:1, or clean pixel doubling at 2:1).
    let nearestSampler: MTLSamplerState
    /// Luma sampler whenever the picture is scaled by any other factor.
    let linearSampler: MTLSamplerState

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: MTLCompileOptions())
        } catch {
            throw RenderSetupError.libraryCompilation(String(describing: error))
        }
        guard let vertex = library.makeFunction(name: Self.vertexFunctionName) else {
            throw RenderSetupError.missingFunction(Self.vertexFunctionName)
        }
        guard let fragment = library.makeFunction(name: Self.fragmentFunctionName) else {
            throw RenderSetupError.missingFunction(Self.fragmentFunctionName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SwiftDesk YCbCr→RGB"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RenderSetupError.pipelineCreation(String(describing: error))
        }
        guard let nearest = Self.makeSampler(device: device, filter: .nearest),
              let linear = Self.makeSampler(device: device, filter: .linear) else {
            throw RenderSetupError.pipelineCreation("sampler state")
        }
        nearestSampler = nearest
        linearSampler = linear
    }

    private static func makeSampler(device: MTLDevice, filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
        let d = MTLSamplerDescriptor()
        d.minFilter = filter
        d.magFilter = filter
        d.mipFilter = .notMipmapped
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        d.normalizedCoordinates = true
        d.label = filter == .nearest ? "SwiftDesk luma whole-pixel" : "SwiftDesk luma scaled"
        return device.makeSamplerState(descriptor: d)
    }

    /// Encodes one render pass into `target`: clear to opaque black, then (if `planes` is non-nil) draw the
    /// video aspect-fit into the centre — pixel for pixel (nearest luma sampling) when the viewport is exactly the
    /// frame size or a whole multiple of it (clean pixel doubling), bilinear otherwise. Shared verbatim by the on-screen renderer and the offscreen tests.
    /// - Returns: false if a render command encoder could not be created.
    @discardableResult
    func encode(into commandBuffer: MTLCommandBuffer, target: MTLTexture, planes: PlaneTextures?) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let planes {
            let viewport = VideoGeometry.pixelViewport(content: planes.contentSize,
                                                       drawableWidth: target.width,
                                                       drawableHeight: target.height)
            if viewport.width > 0, viewport.height > 0 {
                encoder.setViewport(MTLViewport(originX: Double(viewport.minX), originY: Double(viewport.minY),
                                                width: Double(viewport.width), height: Double(viewport.height),
                                                znear: 0, zfar: 1))
                encoder.setRenderPipelineState(pipelineState)
                encoder.setFragmentTexture(planes.luma, index: 0)
                encoder.setFragmentTexture(planes.chroma, index: 1)
                var params = planes.params
                encoder.setFragmentBytes(&params, length: MemoryLayout<YCbCrParams>.size, index: 0)
                let whole = VideoGeometry.wholeMagnification(content: planes.contentSize, viewport: viewport) != nil
                encoder.setFragmentSamplerState(whole ? nearestSampler : linearSampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        return true
    }
}
