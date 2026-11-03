import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization

/// Generates moving 420v frames at a fixed rate, standing in for ScreenCaptureKit.
///
/// Why it looks like this:
/// - **IOSurface-backed `CVPixelBufferPool`, capped at `poolSize`.** Matches what SCK hands the encoder (a small
///   pool of IOSurfaces), so VideoToolbox takes the same zero-copy input path. The cap is enforced with
///   `kCVPixelBufferPoolAllocationThresholdKey`: when every buffer is still held downstream the tick is skipped and
///   counted, exactly like a stalled capture pool, instead of growing memory.
/// - **Dedicated serial queue + strict `DispatchSourceTimer`.** No main-thread or Swift-concurrency involvement, so
///   UI or executor scheduling cannot perturb frame pacing.
/// - **Moving content.** A diagonally scrolling sawtooth gradient, a bouncing box and a per-frame noise patch, so
///   every frame differs from the last and the encoder does real motion search and residual coding (a static image
///   would collapse to near-zero-byte P-frames and flatter the numbers).
/// - **CPU fill is a harness cost, not a pipeline cost.** Filling ~1.4 MB per 720p frame costs well under a
///   millisecond (measured and reported as `fill`); the source timestamp is taken *after* the fill, i.e. when the
///   frame "becomes available", which is where SCK's capture callback would stamp it.
///
/// Synchronization: everything mutable is confined to `queue`; counters are atomics; `start`/`stop` are called
/// from the driver thread and only touch the timer (thread-safe) and the `Mutex`-guarded handle.
final class SyntheticFrameSource: @unchecked Sendable {
    typealias FrameHandler = @Sendable (_ buffer: CVPixelBuffer, _ pts: CMTime, _ captureNanos: UInt64, _ sequence: UInt64) -> Void

    let width: Int
    let height: Int
    let fps: Int
    let poolSize: Int

    let framesGenerated = Counter()
    /// Ticks skipped because every pool buffer was still held downstream (encoder, decoder reference, etc.).
    let poolExhausted = Counter()
    let fillMillis: SampleSeries

    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary
    private let queue = DispatchQueue(label: "com.swiftdesk.bench.source", qos: .userInteractive)
    private let timer = Mutex<(any DispatchSourceTimer)?>(nil)

    // Confined to `queue`.
    private var sequence: UInt64 = 0
    private var noiseState: UInt64 = 0x2545_F491_4F6C_DD1D
    private let lumaPattern: [UInt8]
    private let chromaPattern: [UInt8]

    enum SourceError: Error, CustomStringConvertible {
        case poolCreationFailed(CVReturn)
        var description: String {
            switch self {
            case .poolCreationFailed(let status): "CVPixelBufferPoolCreate failed (\(status))"
            }
        }
    }

    init(width: Int, height: Int, fps: Int, poolSize: Int = 4, expectedFrames: Int) throws {
        precondition(width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0, "420v needs even dimensions")
        self.width = width
        self.height = height
        self.fps = fps
        self.poolSize = poolSize
        self.fillMillis = SampleSeries(expected: expectedFrames)

        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            // Default attachments for every pool buffer: tag BT.709 once instead of per frame.
            kCVBufferPropagatedAttachmentsKey as String: [
                kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
            ] as [String: Any],
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: poolSize]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                                             pixelAttributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw SourceError.poolCreationFailed(status) }
        pool = created
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: poolSize] as CFDictionary

        // One period (256 px) of sawtooth beyond the frame width, so every row is a single memcpy at an offset.
        lumaPattern = (0..<(width + 256)).map { UInt8(16 + ($0 & 0xFF) * 219 / 255) }
        // Interleaved Cb/Cr, 128-sample period per component; extra 256 bytes keeps offsets in range and even.
        chromaPattern = (0..<(width + 256)).map { i in
            let phase = (i >> 1) & 0x7F
            return UInt8(i & 1 == 0 ? 64 + phase : 192 - phase)
        }
    }

    deinit { stop() }

    /// Starts the timer. `handler` runs on the source queue and must not block (hand the buffer to the encoder).
    func start(handler: @escaping FrameHandler) {
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1_000_000_000 / max(fps, 1)
        source.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .microseconds(250))
        source.setEventHandler { [weak self] in self?.tick(handler) }
        timer.withLock { $0 = source }
        source.resume()
    }

    /// Cancels the timer and waits for an in-progress tick to finish, so no frame is emitted after `stop` returns.
    func stop() {
        guard let source = timer.withLock({ t -> (any DispatchSourceTimer)? in defer { t = nil }; return t }) else { return }
        source.cancel()
        queue.sync {}
    }

    /// Creates one buffer and fills it with the content for `frameIndex`. Exposed for `--self-test`.
    func makeFrame(frameIndex: UInt64) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        fill(buffer, frameIndex: frameIndex)
        return buffer
    }

    private func tick(_ handler: FrameHandler) {
        sequence &+= 1
        framesGenerated.add()
        let fillStart = MonotonicClock.nowNanos()
        guard let buffer = makeFrame(frameIndex: sequence) else {
            poolExhausted.add()
            return
        }
        let captureNanos = MonotonicClock.nowNanos()
        fillMillis.add(from: fillStart, to: captureNanos)
        let pts = CMTime(value: CMTimeValue(sequence), timescale: CMTimeScale(fps))
        handler(buffer, pts, captureNanos, sequence)
    }

    // MARK: Content

    private func fill(_ buffer: CVPixelBuffer, frameIndex: UInt64) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaRows = height / 2
        let f = Int(truncatingIfNeeded: frameIndex)

        // Scrolling diagonal sawtooth: 4 px/frame horizontally, shifted by row for a diagonal edge.
        lumaPattern.withUnsafeBufferPointer { pattern in
            for y in 0..<height {
                let offset = (f &* 4 &+ y / 2) & 0xFF
                (yBase + y * yStride).copyMemory(from: pattern.baseAddress! + offset, byteCount: width)
            }
        }
        chromaPattern.withUnsafeBufferPointer { pattern in
            for y in 0..<chromaRows {
                let offset = ((f &* 2 &+ y) & 0x7F) * 2   // even: keeps Cb/Cr phase
                (uvBase + y * uvStride).copyMemory(from: pattern.baseAddress! + offset, byteCount: width)
            }
        }

        // Bouncing box (triangle wave on both axes), even-aligned for 4:2:0.
        let box = max(16, (height / 6) & ~1)
        let bx = Self.triangle(f &* 6, span: width - box) & ~1
        let by = Self.triangle(f &* 4, span: height - box) & ~1
        for y in by..<(by + box) {
            memset(yBase + y * yStride + bx, 235, box)
        }
        for y in (by / 2)..<((by + box) / 2) {
            let row = (uvBase + y * uvStride + bx).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < box {
                row[x] = 90      // Cb
                row[x + 1] = 240 // Cr
                x += 2
            }
        }

        // Per-frame noise patch (bottom-left quarter-width strip): incompressible detail, like changing text.
        let noiseWidth = (width / 4) & ~7
        let noiseHeight = height / 8
        let noiseTop = height - noiseHeight - height / 16
        for y in noiseTop..<(noiseTop + noiseHeight) {
            let row = UnsafeMutableRawPointer(yBase + y * yStride + width / 16)
            var x = 0
            while x < noiseWidth {
                noiseState ^= noiseState << 13
                noiseState ^= noiseState >> 7
                noiseState ^= noiseState << 17
                // Keep samples inside video range (48...175).
                let v = (noiseState & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x3030_3030_3030_3030
                row.storeBytes(of: v, toByteOffset: x, as: UInt64.self)
                x += 8
            }
        }
    }

    /// Triangle wave in `0...span`.
    static func triangle(_ t: Int, span: Int) -> Int {
        guard span > 0 else { return 0 }
        let period = span * 2
        let p = ((t % period) + period) % period
        return p <= span ? p : period - p
    }
}
