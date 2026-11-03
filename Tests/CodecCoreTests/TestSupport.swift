import CoreMedia
import CoreVideo
import Foundation
import Synchronization
@testable import CodecCore

/// Deterministic synthetic video: a diagonal luma gradient scrolling 3 steps/frame plus a bright box
/// moving 8 px/frame, so every frame differs (P-frames carry real motion) yet compresses predictably.
enum SyntheticVideo {
    static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        precondition(status == kCVReturnSuccess && buffer != nil, "CVPixelBufferCreate failed: \(status)")
        return buffer!
    }

    private static let gradient: [UInt8] = (0..<(4096 + 1024)).map { UInt8(truncatingIfNeeded: 16 + ($0 / 2) % 220) }

    static func fill(_ buffer: CVPixelBuffer, frame i: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let box = 160
        let boxX = (i * 8) % (width - box)
        let boxY = (i * 4) % (height - box)
        gradient.withUnsafeBytes { g in
            for y in 0..<height {
                let row = yBase + y * yStride
                let shift = 2 * ((y / 3 + i * 3) % 440)
                row.copyMemory(from: g.baseAddress! + shift, byteCount: width)
                if y >= boxY && y < boxY + box { memset(row + boxX, 235, box) }
            }
        }
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            memset(uvBase + y * uvStride, Int32(112 + (y / 45)), width)
        }
    }

    static func makeFrame(width: Int, height: Int, frame: Int) -> CVPixelBuffer {
        let buffer = makePixelBuffer(width: width, height: height)
        fill(buffer, frame: frame)
        return buffer
    }

    /// Luma PSNR between two 420v buffers of equal size (dB).
    static func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let width = CVPixelBufferGetWidth(a)
        let height = CVPixelBufferGetHeight(a)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0)
        let sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var sse: Double = 0
        for y in 0..<height {
            var rowSSE = 0
            for x in 0..<width {
                let d = Int(pa[y * sa + x]) - Int(pb[y * sb + x])
                rowSSE += d * d
            }
            sse += Double(rowSSE)
        }
        let mse = sse / Double(width * height)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}

/// Collects encoder output and lets the test wait for each frame.
///
/// The encoder enforces one frame in flight and drops anything submitted meanwhile, so a test that wants
/// every frame encoded must wait for the previous output *and* for the slot to be released (the slot is
/// freed only after `onEncodedFrame` returns, which is just after this collector signals).
final class EncodedCollector: Sendable {
    private let frames = Mutex<[EncodedVideoFrame]>([])
    private let semaphore = DispatchSemaphore(value: 0)

    func attach(to encoder: H264Encoder) {
        encoder.onEncodedFrame = { [self] frame in
            frames.withLock { $0.append(frame) }
            semaphore.signal()
        }
    }

    /// Waits for the next frame and for the encoder's in-flight slot to be released.
    func waitForFrame(_ encoder: H264Encoder, timeout: TimeInterval = 3) -> Bool {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while encoder.isEncodeInFlight {
            if Date() > deadline { return false }
            usleep(50)
        }
        return true
    }

    var all: [EncodedVideoFrame] { frames.withLock { $0 } }
}

final class DecodedCollector: Sendable {
    private let frames = Mutex<[DecodedFrame]>([])
    private let errors = Mutex<[OSStatus]>([])

    func attach(to decoder: H264Decoder) {
        decoder.onDecodedFrame = { [self] frame in frames.withLock { $0.append(frame) } }
        decoder.onError = { [self] status in errors.withLock { $0.append(status) } }
    }

    var all: [DecodedFrame] { frames.withLock { $0 } }
    var allErrors: [OSStatus] { errors.withLock { $0 } }
}

enum H264Inspect {
    /// NAL types of an AVCC access unit, in order.
    static func nalTypes(_ data: Data) -> [UInt8] {
        ((try? AVCC.nalUnits(in: data)) ?? []).map(AVCC.nalType)
    }

    /// (profile_idc, constraint flags byte, level_idc) from an SPS NAL (including its header byte).
    static func profile(ofSPS sps: Data) -> (profile: UInt8, constraints: UInt8, level: UInt8)? {
        guard sps.count >= 4 else { return nil }
        let b = [UInt8](sps.prefix(4))
        return (b[1], b[2], b[3])
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((p * Double(s.count)).rounded(.up)) - 1))]
    }
}
