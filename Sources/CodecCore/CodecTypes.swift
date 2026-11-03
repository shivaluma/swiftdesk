import CoreVideo
import Foundation

/// Encoder session parameters. Changing `width`, `height` or `fps` requires `H264Encoder.reconfigure`
/// (a new VideoToolbox session); `bitrateKbps` can be changed live with `setBitrate(kbps:)`.
public struct EncoderConfig: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int = 60
    public var bitrateKbps: Int = 3000
    /// Upper bound on the keyframe interval. Low-latency rate control may ignore this (infinite GOP);
    /// on-demand keyframes (`requestKeyframe`) are the actual loss-recovery mechanism.
    public var keyframeIntervalSeconds: Double = 4

    public init(width: Int, height: Int, fps: Int = 60, bitrateKbps: Int = 3000, keyframeIntervalSeconds: Double = 4) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
    }
}

/// One encoded access unit, ready for packetization.
///
/// `data` is AVCC (4-byte big-endian length-prefixed NAL units). Keyframes start with SPS and PPS so
/// the viewer can (re)initialise its decoder from any IDR without out-of-band configuration.
public struct EncodedVideoFrame: Sendable {
    public var data: Data
    public var isKeyframe: Bool
    /// Host capture timestamp (`MonotonicClock`) carried through from `encode`.
    public var captureNanos: UInt64
    /// Host time at which VideoToolbox delivered the compressed frame.
    public var encodeDoneNanos: UInt64
    /// Caller-supplied capture sequence number.
    public var sequence: UInt64
    /// Host time at which the frame was handed to VideoToolbox (after the encode-queue hop).
    /// `encodeDoneNanos - encodeSubmitNanos` is the pure codec latency.
    public var encodeSubmitNanos: UInt64

    public init(data: Data, isKeyframe: Bool, captureNanos: UInt64, encodeDoneNanos: UInt64, sequence: UInt64,
                encodeSubmitNanos: UInt64 = 0) {
        self.data = data
        self.isKeyframe = isKeyframe
        self.captureNanos = captureNanos
        self.encodeDoneNanos = encodeDoneNanos
        self.sequence = sequence
        self.encodeSubmitNanos = encodeSubmitNanos
    }
}

/// A decoded picture handed to the renderer.
///
/// `@unchecked Sendable`: the pixel buffer is produced by VideoToolbox and never mutated afterwards;
/// consumers only read it (Metal texture cache), so sharing it across queues is safe.
public struct DecodedFrame: @unchecked Sendable {
    /// 420v (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), IOSurface-backed, Metal compatible.
    public let pixelBuffer: CVPixelBuffer
    public let frameId: UInt32
    /// Host clock; not comparable with viewer timestamps.
    public let captureNanos: UInt64
    /// Viewer clock: when the complete access unit was handed to the decoder's caller.
    public let receivedNanos: UInt64
    /// Viewer clock: when VideoToolbox emitted the decoded picture.
    public let decodeDoneNanos: UInt64

    public init(pixelBuffer: CVPixelBuffer, frameId: UInt32, captureNanos: UInt64, receivedNanos: UInt64, decodeDoneNanos: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.frameId = frameId
        self.captureNanos = captureNanos
        self.receivedNanos = receivedNanos
        self.decodeDoneNanos = decodeDoneNanos
    }
}

/// Errors from creating or reconfiguring codec sessions.
public enum CodecError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    /// `VTCompressionSessionCreate` failed for every encoder specification tried (last status).
    case sessionCreationFailed(OSStatus)
    case prepareFailed(OSStatus)
    case invalidated
}
