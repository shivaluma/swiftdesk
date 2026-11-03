import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization
import VideoToolbox

/// Hardware H.264 decoder for AVCC access units produced by `H264Encoder`.
///
/// Design:
/// - **Synchronous decode on the caller's queue** (`decodeFlags = []`). VideoToolbox is then compelled to
///   emit the picture before `VTDecompressionSessionDecodeFrame` returns, so output order equals input
///   order and there is no second queue adding latency or reordering. `onDecodedFrame` is invoked on the
///   caller's thread before `decode` returns.
/// - **In-band configuration.** SPS/PPS carried on keyframes create the `CMVideoFormatDescription`; when
///   they change the session is kept if it can accept the new format, otherwise recreated.
/// - **Fail closed.** Frames before the first parameter sets, malformed AVCC, or decoder failures return
///   false; decoder failures also call `onError` so the session can request a keyframe.
///
/// Synchronization: all decoder state is guarded by one `Mutex` (uncontended in normal single-queue use);
/// callbacks run after the lock is released, so they may call back into the decoder (e.g. `reset()`).
public final class H264Decoder: @unchecked Sendable {
    public var onDecodedFrame: (@Sendable (DecodedFrame) -> Void)? {
        get { callbacks.withLock { $0.frame } }
        set { callbacks.withLock { $0.frame = newValue } }
    }

    /// Called with the VideoToolbox status when a frame fails to decode; the caller should request a keyframe.
    public var onError: (@Sendable (OSStatus) -> Void)? {
        get { callbacks.withLock { $0.error } }
        set { callbacks.withLock { $0.error = newValue } }
    }

    private struct Callbacks {
        var frame: (@Sendable (DecodedFrame) -> Void)?
        var error: (@Sendable (OSStatus) -> Void)?
    }

    private enum Outcome {
        case decoded(DecodedFrame)
        case accepted          // parameter sets only, or frame dropped by the decoder without error
        case rejected          // malformed / no parameter sets
        case failed(OSStatus)
    }

    private let callbacks = Mutex(Callbacks())
    private let lock = Mutex(())
    private let output = DecoderOutputContext()
    private let diagnostics = Mutex(DecoderDiagnostics())

    // Guarded by `lock`.
    private var session: VTDecompressionSession?
    private var sessionRefCon: Unmanaged<DecoderOutputContext>?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSPS: [Data] = []
    private var currentPPS: [Data] = []
    // Reused scratch arrays so steady-state parsing does not allocate.
    private var spsRanges: [Range<Int>] = []
    private var ppsRanges: [Range<Int>] = []
    private var sliceRanges: [Range<Int>] = []

    public init() {
        spsRanges.reserveCapacity(2)
        ppsRanges.reserveCapacity(2)
        sliceRanges.reserveCapacity(8)
    }

    deinit {
        teardownSession()
    }

    /// Parses AVCC; (re)creates format description/session when SPS/PPS change. Returns false if it could
    /// not decode (no parameter sets yet, malformed input, or decoder failure).
    @discardableResult
    public func decode(_ data: Data, frameId: UInt32, captureNanos: UInt64, receivedNanos: UInt64) -> Bool {
        let outcome = lock.withLock { _ in
            decodeLocked(data, frameId: frameId, captureNanos: captureNanos, receivedNanos: receivedNanos)
        }
        switch outcome {
        case .decoded(let frame):
            PipelineSignpost.decoded(frame: UInt64(frameId))
            diagnostics.withLock { $0.framesDecoded &+= 1 }
            callbacks.withLock { $0.frame }?(frame)
            return true
        case .accepted:
            return true
        case .rejected:
            diagnostics.withLock { $0.framesRejected &+= 1 }
            return false
        case .failed(let status):
            diagnostics.withLock { $0.decodeErrors &+= 1 }
            callbacks.withLock { $0.error }?(status)
            return false
        }
    }

    /// Drops the session and parameter sets; the next decodable frame must be a keyframe.
    public func reset() {
        lock.withLock { _ in
            teardownSession()
            formatDescription = nil
            currentSPS = []
            currentPPS = []
        }
    }

    // MARK: Diagnostics (extra public API)

    /// Whether the current session reports a hardware decoder; nil before a session exists or if unknown.
    public var isHardwareAccelerated: Bool? { diagnostics.withLock { $0.hardware } }
    /// Whether `kVTDecompressionPropertyKey_RealTime` was accepted by the current session.
    public var realTimeApplied: Bool? { diagnostics.withLock { $0.realTime } }
    public var framesDecoded: UInt64 { diagnostics.withLock { $0.framesDecoded } }
    public var framesRejected: UInt64 { diagnostics.withLock { $0.framesRejected } }
    public var decodeErrors: UInt64 { diagnostics.withLock { $0.decodeErrors } }
    /// Number of VTDecompressionSessions created (increments on parameter-set changes that need a new session).
    public var sessionsCreated: UInt64 { diagnostics.withLock { $0.sessionsCreated } }

    // MARK: Locked implementation

    private func decodeLocked(_ data: Data, frameId: UInt32, captureNanos: UInt64, receivedNanos: UInt64) -> Outcome {
        data.withUnsafeBytes { raw -> Outcome in
            spsRanges.removeAll(keepingCapacity: true)
            ppsRanges.removeAll(keepingCapacity: true)
            sliceRanges.removeAll(keepingCapacity: true)
            do {
                try AVCC.forEachNAL(in: raw) { range in
                    switch raw[range.lowerBound] & 0x1F {
                    case AVCC.NALType.sps: spsRanges.append(range)
                    case AVCC.NALType.pps: ppsRanges.append(range)
                    default: sliceRanges.append(range)
                    }
                }
            } catch {
                return .rejected
            }

            if !spsRanges.isEmpty || !ppsRanges.isEmpty {
                guard !spsRanges.isEmpty, !ppsRanges.isEmpty else { return .rejected }
                if let status = updateParameterSets(raw) {
                    return status == noErr ? .rejected : .failed(status)
                }
            }
            guard let format = formatDescription else { return .rejected }
            guard !sliceRanges.isEmpty else { return .accepted }

            if session == nil, let status = createSession(format) {
                return .failed(status)
            }
            guard let session else { return .rejected }

            guard let sample = makeSampleBuffer(raw, format: format) else { return .rejected }
            output.begin(frameId: frameId, captureNanos: captureNanos, receivedNanos: receivedNanos)
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                           frameRefcon: nil, infoFlagsOut: &infoFlags)
            if infoFlags.contains(.asynchronous) {
                // Not expected without the async flag, but never let ordering depend on it.
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
            let result = output.take()
            if status != noErr {
                if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
                    teardownSession()  // recreated from the retained format description on the next frame
                }
                return .failed(status)
            }
            if let frame = result.frame { return .decoded(frame) }
            if result.status != noErr { return .failed(result.status) }
            return .accepted
        }
    }

    /// Returns nil on success, `noErr` for malformed parameter sets (reject), or a VT error status.
    private func updateParameterSets(_ raw: UnsafeRawBufferPointer) -> OSStatus? {
        if Self.matches(raw, spsRanges, currentSPS), Self.matches(raw, ppsRanges, currentPPS), formatDescription != nil {
            return nil
        }
        let ranges = spsRanges + ppsRanges
        var pointers = ranges.map { raw.baseAddress!.advanced(by: $0.lowerBound).assumingMemoryBound(to: UInt8.self) }
        var sizes = ranges.map(\.count)
        var newFormat: CMFormatDescription?
        let status = pointers.withUnsafeMutableBufferPointer { ptrs in
            sizes.withUnsafeMutableBufferPointer { szs in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ranges.count,
                    parameterSetPointers: UnsafePointer(ptrs.baseAddress!), parameterSetSizes: UnsafePointer(szs.baseAddress!),
                    nalUnitHeaderLength: Int32(AVCC.lengthHeaderSize), formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else {
            // Corrupt SPS/PPS: forget the old ones too so following P-frames are not decoded against
            // a configuration the encoder no longer uses.
            formatDescription = nil
            currentSPS = []
            currentPPS = []
            teardownSession()
            return noErr
        }
        currentSPS = spsRanges.map { Data(raw[$0]) }
        currentPPS = ppsRanges.map { Data(raw[$0]) }
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            teardownSession()
        }
        formatDescription = newFormat
        return nil
    }

    private static func matches(_ raw: UnsafeRawBufferPointer, _ ranges: [Range<Int>], _ stored: [Data]) -> Bool {
        guard ranges.count == stored.count else { return false }
        for (range, data) in zip(ranges, stored) {
            guard range.count == data.count else { return false }
            let equal = data.withUnsafeBytes { memcmp($0.baseAddress!, raw.baseAddress! + range.lowerBound, range.count) == 0 }
            guard equal else { return false }
        }
        return true
    }

    /// Copies the slice NAL units (with their 4-byte prefixes) into one CoreMedia-owned block.
    ///
    /// One memcpy is deliberate: referencing the caller's `Data` with `kCFAllocatorNull` would be zero-copy
    /// but relies on VideoToolbox never retaining the sample past the call. Adjacent NAL units are copied
    /// as a single run, so a typical frame costs exactly one memcpy of a few KB.
    private func makeSampleBuffer(_ raw: UnsafeRawBufferPointer, format: CMFormatDescription) -> CMSampleBuffer? {
        var total = 0
        for range in sliceRanges { total += AVCC.lengthHeaderSize + range.count }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block
        else { return nil }
        var destination: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &destination) == kCMBlockBufferNoErr, let destination
        else { return nil }

        var written = 0
        var runStart = sliceRanges[0].lowerBound - AVCC.lengthHeaderSize
        var runEnd = sliceRanges[0].upperBound
        func flush() {
            let count = runEnd - runStart
            UnsafeMutableRawPointer(destination + written).copyMemory(from: raw.baseAddress! + runStart, byteCount: count)
            written += count
        }
        for range in sliceRanges.dropFirst() {
            let start = range.lowerBound - AVCC.lengthHeaderSize
            if start == runEnd {
                runEnd = range.upperBound
            } else {
                flush()
                runStart = start
                runEnd = range.upperBound
            }
        }
        flush()

        var sample: CMSampleBuffer?
        var sampleSize = total
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// Returns nil on success, else the failing status.
    private func createSession(_ format: CMFormatDescription) -> OSStatus? {
        let decoderSpecification = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ] as CFDictionary
        let destinationAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ] as CFDictionary

        let refCon = Unmanaged.passRetained(output)
        var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: h264DecoderOutputCallback,
                                                         decompressionOutputRefCon: refCon.toOpaque())
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: decoderSpecification,
            imageBufferAttributes: destinationAttributes, outputCallback: &record, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            refCon.release()
            Log.media.error("VTDecompressionSessionCreate failed: \(status)")
            return status == noErr ? kVTParameterErr : status
        }
        let realTime = VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) == noErr
        var hardwareOut: Unmanaged<CFTypeRef>?
        let hwStatus = withUnsafeMutablePointer(to: &hardwareOut) {
            VTSessionCopyProperty(newSession, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: nil, valueOut: $0)
        }
        var hardware: Bool?
        if hwStatus == noErr, let value = hardwareOut?.takeRetainedValue(), CFGetTypeID(value) == CFBooleanGetTypeID() {
            hardware = CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        session = newSession
        sessionRefCon = refCon
        diagnostics.withLock {
            $0.hardware = hardware
            $0.realTime = realTime
            $0.sessionsCreated &+= 1
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        Log.media.info("H264Decoder session \(dims.width)x\(dims.height) hw=\(String(describing: hardware), privacy: .public) realTime=\(realTime)")
        return nil
    }

    private func teardownSession() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        sessionRefCon?.release()
        sessionRefCon = nil
    }
}

struct DecoderDiagnostics {
    var hardware: Bool?
    var realTime: Bool?
    var framesDecoded: UInt64 = 0
    var framesRejected: UInt64 = 0
    var decodeErrors: UInt64 = 0
    var sessionsCreated: UInt64 = 0
}

/// Receives the VideoToolbox output callback. With synchronous decoding the callback runs on the decoding
/// thread inside `VTDecompressionSessionDecodeFrame`; the `Mutex` keeps it correct even if VideoToolbox
/// ever calls back on another thread before `WaitForAsynchronousFrames` returns.
final class DecoderOutputContext: Sendable {
    struct Pending {
        var frameId: UInt32 = 0
        var captureNanos: UInt64 = 0
        var receivedNanos: UInt64 = 0
    }
    struct Result {
        var frame: DecodedFrame?
        var status: OSStatus = noErr
    }
    private struct State {
        var pending = Pending()
        var result = Result()
    }
    private let state = Mutex(State())

    func begin(frameId: UInt32, captureNanos: UInt64, receivedNanos: UInt64) {
        state.withLock {
            $0.pending = Pending(frameId: frameId, captureNanos: captureNanos, receivedNanos: receivedNanos)
            $0.result = Result()
        }
    }

    func take() -> Result {
        state.withLock { s in
            let r = s.result
            s.result = Result()
            return r
        }
    }

    func deliver(status: OSStatus, imageBuffer: CVImageBuffer?) {
        let done = MonotonicClock.nowNanos()
        let box = imageBuffer.map(PixelBufferBox.init)
        state.withLock { s in
            if status != noErr {
                s.result.status = status
                return
            }
            guard let box else { return }  // dropped frame
            s.result.frame = DecodedFrame(pixelBuffer: box.buffer, frameId: s.pending.frameId,
                                          captureNanos: s.pending.captureNanos, receivedNanos: s.pending.receivedNanos,
                                          decodeDoneNanos: done)
        }
    }
}

private func h264DecoderOutputCallback(_ outputRefCon: UnsafeMutableRawPointer?, _ sourceFrameRefCon: UnsafeMutableRawPointer?,
                                       _ status: OSStatus, _ flags: VTDecodeInfoFlags, _ imageBuffer: CVImageBuffer?,
                                       _ presentationTimeStamp: CMTime, _ presentationDuration: CMTime) {
    guard let outputRefCon else { return }
    let context = Unmanaged<DecoderOutputContext>.fromOpaque(outputRefCon).takeUnretainedValue()
    context.deliver(status: status, imageBuffer: flags.contains(.frameDropped) ? nil : imageBuffer)
}
