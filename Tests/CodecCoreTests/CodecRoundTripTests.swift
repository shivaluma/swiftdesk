import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Testing
@testable import CodecCore

/// Hardware codec tests. Serialized so encoder sessions do not compete for the media engine and skew
/// the latency numbers printed by the end-to-end test.
@Suite("H.264 encode/decode", .serialized)
struct CodecRoundTripTests {
    static let width = 1280
    static let height = 720

    /// Encodes `count` synthetic frames, waiting for each output (one-pending-frame rule: a frame submitted
    /// while another is in flight would be dropped). Optionally paces submissions at real-time 60 fps.
    private func encodeSequence(_ encoder: H264Encoder, collector: EncodedCollector, width: Int, height: Int,
                                count: Int, startIndex: Int = 0, paced: Bool = false,
                                keyframeAt: Set<Int> = []) throws {
        let start = MonotonicClock.nowNanos()
        let pool = (0..<2).map { _ in SyntheticVideo.makePixelBuffer(width: width, height: height) }
        for i in startIndex..<(startIndex + count) {
            let buffer = pool[i % 2]
            SyntheticVideo.fill(buffer, frame: i)
            if paced {
                let target = start + UInt64(i - startIndex) * 16_666_667
                let now = MonotonicClock.nowNanos()
                if target > now { usleep(UInt32((target - now) / 1000)) }
            }
            if keyframeAt.contains(i) { encoder.requestKeyframe() }
            let accepted = encoder.encode(buffer, presentationTime: CMTime(value: CMTimeValue(i), timescale: 60),
                                          captureNanos: MonotonicClock.nowNanos(), sequence: UInt64(i))
            try #require(accepted, "frame \(i) unexpectedly dropped")
            try #require(collector.waitForFrame(encoder), "timed out waiting for frame \(i)")
        }
    }

    @Test func endToEnd720pRoundTripAndMeasurements() throws {
        let config = EncoderConfig(width: Self.width, height: Self.height, fps: 60, bitrateKbps: 3000)
        let encoder = try H264Encoder(config: config)
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)

        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height,
                           count: 120, paced: true, keyframeAt: [60])
        let frames = collector.all
        try #require(frames.count == 120)
        #expect(encoder.droppedForBackpressure == 0)
        #expect(encoder.encoderDroppedFrames == 0)
        #expect(encoder.framesEncoded == 120)
        #expect(frames.map(\.sequence) == (0..<120).map(UInt64.init), "output order must equal input order")
        if encoder.requiredHardwareEncoder { #expect(encoder.isHardwareAccelerated == true) }
        for key in ["RealTime", "AllowFrameReordering", "AverageBitRate", "ExpectedFrameRate", "ProfileLevel"] {
            #expect(encoder.appliedProperties[key] == true, "\(key) not applied")
        }

        // First frame: IDR with in-band SPS + PPS.
        let first = frames[0]
        #expect(first.isKeyframe)
        let firstTypes = H264Inspect.nalTypes(first.data)
        #expect(Array(firstTypes.prefix(2)) == [7, 8])
        #expect(firstTypes.contains(5))
        #expect(AVCC.containsIDR(first.data))

        // requestKeyframe() → the next submitted frame (60) is an IDR with parameter sets.
        let forced = frames[60]
        #expect(forced.isKeyframe)
        let forcedTypes = H264Inspect.nalTypes(forced.data)
        #expect(Array(forcedTypes.prefix(2)) == [7, 8])
        #expect(forcedTypes.contains(5))

        // Everything else is a P-frame without parameter sets.
        for frame in frames where frame.sequence != 0 && frame.sequence != 60 {
            #expect(!frame.isKeyframe, "frame \(frame.sequence) unexpectedly a keyframe")
            let types = H264Inspect.nalTypes(frame.data)
            #expect(!types.contains(7) && !types.contains(8) && !types.contains(5))
            #expect(types.contains(1))
        }

        // Decode everything in order.
        let decoder = H264Decoder()
        let decoded = DecodedCollector()
        decoded.attach(to: decoder)
        var decodeMillis: [Double] = []
        for (index, frame) in frames.enumerated() {
            let received = MonotonicClock.nowNanos()
            let ok = decoder.decode(frame.data, frameId: UInt32(index + 1), captureNanos: frame.captureNanos, receivedNanos: received)
            decodeMillis.append(MonotonicClock.elapsedMillis(since: received))
            #expect(ok, "frame \(index) failed to decode")
        }
        let outputs = decoded.all
        #expect(decoded.allErrors.isEmpty)
        try #require(outputs.count == 120)
        #expect(outputs.map(\.frameId) == (1...120).map(UInt32.init))
        for out in outputs {
            #expect(CVPixelBufferGetPixelFormatType(out.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            #expect(CVPixelBufferGetWidth(out.pixelBuffer) == Self.width)
            #expect(CVPixelBufferGetHeight(out.pixelBuffer) == Self.height)
            #expect(CVPixelBufferGetIOSurface(out.pixelBuffer) != nil)
            #expect(out.decodeDoneNanos >= out.receivedNanos)
        }
        // Content check: decoded pictures resemble the source.
        var psnrs: [Double] = []
        for index in [0, 1, 30, 60, 119] {
            let source = SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: index)
            psnrs.append(SyntheticVideo.lumaPSNR(source, outputs[index].pixelBuffer))
        }
        #expect(psnrs.allSatisfy { $0 > 28 }, "luma PSNR too low: \(psnrs)")

        // Measurements for the report.
        let codecMillis = frames.map { Double($0.encodeDoneNanos - $0.encodeSubmitNanos) / 1_000_000 }
        let captureToDone = frames.map { Double($0.encodeDoneNanos - $0.captureNanos) / 1_000_000 }
        let pSizes = frames.filter { !$0.isKeyframe }.map { Double($0.data.count) }
        let totalBits = Double(frames.reduce(0) { $0 + $1.data.count } * 8)
        print("""
        [CodecCore measurements] 1280x720 @60 (paced), 3000 kbps, 120 frames
          encoder: hardware=\(String(describing: encoder.isHardwareAccelerated)) lowLatencyRateControl=\(encoder.lowLatencyRateControl) requireHW=\(encoder.requiredHardwareEncoder) profile=\(encoder.profileLevel ?? "nil")
          SPS profile_idc/constraints/level: \(H264Inspect.profile(ofSPS: try AVCC.nalUnits(in: first.data)[0]).map { "\($0.profile)/0x\(String($0.constraints, radix: 16))/\($0.level)" } ?? "?")
          appliedProperties: \(encoder.appliedProperties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
          encode (submit→output) ms: median=\(fmt(H264Inspect.median(codecMillis))) p95=\(fmt(H264Inspect.percentile(codecMillis, 0.95))) max=\(fmt(codecMillis.max() ?? 0))
          encode (encode() call→output, incl. queue hop) ms: median=\(fmt(H264Inspect.median(captureToDone)))
          decode (synchronous decode() call) ms: median=\(fmt(H264Inspect.median(decodeMillis))) p95=\(fmt(H264Inspect.percentile(decodeMillis, 0.95))) max=\(fmt(decodeMillis.max() ?? 0))
          decoder: hardware=\(String(describing: decoder.isHardwareAccelerated)) realTime=\(String(describing: decoder.realTimeApplied))
          sizes bytes: keyframe0=\(frames[0].data.count) keyframe60=\(frames[60].data.count) P median=\(Int(H264Inspect.median(pSizes))) P p95=\(Int(H264Inspect.percentile(pSizes, 0.95))) P max=\(Int(pSizes.max() ?? 0))
          effective bitrate over 2 s: \(Int(totalBits / 2 / 1000)) kbps
          luma PSNR dB (frames 0,1,30,60,119): \(psnrs.map(fmt))
        """)
    }

    @Test func nonKeyframeBeforeAnyKeyframeIsRejected() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height, count: 3)
        let frames = collector.all
        try #require(frames.count == 3 && frames[0].isKeyframe && !frames[1].isKeyframe)

        let decoder = H264Decoder()
        let decoded = DecodedCollector()
        decoded.attach(to: decoder)
        #expect(decoder.decode(frames[1].data, frameId: 2, captureNanos: 0, receivedNanos: 0) == false)
        #expect(decoded.all.isEmpty)
        #expect(decoder.sessionsCreated == 0)

        // Keyframe recovers; subsequent P-frame decodes.
        #expect(decoder.decode(frames[0].data, frameId: 1, captureNanos: 0, receivedNanos: 0))
        #expect(decoder.decode(frames[1].data, frameId: 2, captureNanos: 0, receivedNanos: 0))

        // After reset the decoder again needs a keyframe.
        decoder.reset()
        #expect(decoder.decode(frames[2].data, frameId: 3, captureNanos: 0, receivedNanos: 0) == false)
        #expect(decoder.decode(frames[0].data, frameId: 4, captureNanos: 0, receivedNanos: 0))
        #expect(decoded.all.map(\.frameId) == [1, 2, 4])
        #expect(decoded.allErrors.isEmpty)
    }

    @Test func decoderRejectsMalformedInputWithoutCrashing() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height, count: 2)
        let key = collector.all[0].data

        let decoder = H264Decoder()
        #expect(decoder.decode(Data(), frameId: 1, captureNanos: 0, receivedNanos: 0) == false)
        #expect(decoder.decode(key.prefix(key.count - 1), frameId: 2, captureNanos: 0, receivedNanos: 0) == false)
        #expect(decoder.decode(Data([0, 0, 0, 0, 0x65]), frameId: 3, captureNanos: 0, receivedNanos: 0) == false)
        // SPS without PPS is not a usable configuration.
        let nals = try AVCC.nalUnits(in: key)
        #expect(decoder.decode(AVCC.lengthPrefixed([nals[0]]), frameId: 4, captureNanos: 0, receivedNanos: 0) == false)
        // Parameter sets alone are accepted (configuration only, no picture).
        #expect(decoder.decode(AVCC.lengthPrefixed(Array(nals.prefix(2))), frameId: 5, captureNanos: 0, receivedNanos: 0))
        // Valid keyframe still decodes afterwards.
        #expect(decoder.decode(key, frameId: 6, captureNanos: 0, receivedNanos: 0))
        #expect(decoder.framesRejected == 4)
    }

    /// A frame arriving while one is in flight is not lost when nothing newer follows: it waits in the single
    /// latest-frame slot and is submitted after the quiet period (it may be the last change on a screen that then
    /// went static; review finding latency-2). In a live stream the next capture would replace it instead.
    @Test func frameArrivingWhileBusyIsEncodedNextInsteadOfLost() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        let a = SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: 0)
        let b = SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: 1)
        #expect(encoder.encode(a, presentationTime: CMTime(value: 0, timescale: 60), captureNanos: 1, sequence: 0))
        // The first frame holds the slot until its output callback returns, so this one is not submitted now.
        #expect(encoder.encode(b, presentationTime: CMTime(value: 1, timescale: 60), captureNanos: 2, sequence: 1) == false)
        #expect(encoder.droppedForBackpressure == 1)
        #expect(collector.waitForFrame(encoder))
        #expect(collector.waitForFrame(encoder))
        #expect(collector.all.map(\.sequence) == [0, 1])
        #expect(!encoder.hasWaitingFrame)
        #expect(encoder.waitingFramesSubmitted == 1)
        #expect(encoder.refreshesSubmitted == 0)
    }

    /// Only the newest waiting frame is kept: a newer capture replaces an older waiting one.
    @Test func newerWaitingFrameReplacesOlderOne() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        let frames = (0..<3).map { SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: $0) }
        #expect(encoder.encode(frames[0], presentationTime: CMTime(value: 0, timescale: 60), captureNanos: 1, sequence: 0))
        #expect(encoder.encode(frames[1], presentationTime: CMTime(value: 1, timescale: 60), captureNanos: 2, sequence: 1) == false)
        #expect(encoder.encode(frames[2], presentationTime: CMTime(value: 2, timescale: 60), captureNanos: 3, sequence: 2) == false)
        #expect(collector.waitForFrame(encoder))
        #expect(collector.waitForFrame(encoder))
        usleep(150_000)
        #expect(collector.all.map(\.sequence) == [0, 2])
        #expect(encoder.droppedForBackpressure == 2)
    }

    /// Loss recovery on a static screen: no new capture arrives after REQUEST_KEYFRAME, so the encoder resubmits its
    /// newest frame as the IDR instead of waiting for the screen to change (review finding latency-1).
    @Test func keyframeRequestOnAStaticScreenResubmitsTheNewestFrame() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height, fps: 60))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height, count: 3)
        let requested = MonotonicClock.nowNanos()
        encoder.requestKeyframe()
        #expect(collector.waitForFrame(encoder, timeout: 1), "no keyframe without a new capture")
        let frames = collector.all
        try #require(frames.count == 4)
        let refreshed = frames[3]
        #expect(refreshed.isKeyframe)
        #expect(AVCC.containsIDR(refreshed.data))
        #expect(refreshed.sequence == 2, "the newest captured content is what gets re-encoded")
        #expect(encoder.refreshesSubmitted == 1)
        let millis = Double(refreshed.encodeDoneNanos - requested) / 1_000_000
        #expect(millis < 200, "refresh took \(millis) ms")
        // Delivered: nothing further is resubmitted while the screen stays static.
        usleep(150_000)
        #expect(collector.all.count == 4)
        #expect(encoder.refreshesSubmitted == 1)
    }

    /// A frame that takes the slot while `reconfigure` rebuilds the session is dropped on the encode queue instead of
    /// being encoded back to back behind the rebuild; the newest frame is what reaches the new session (review
    /// finding concurrency-1).
    @Test func frameAdmittedDuringReconfigureIsDroppedNotQueued() throws {
        let config = EncoderConfig(width: Self.width, height: Self.height, fps: 60)
        let encoder = try H264Encoder(config: config)
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        let hold = DispatchSemaphore(value: 0)
        encoder.enqueueOnEncodeQueueForTesting { hold.wait() }
        let reconfigured = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? encoder.reconfigure(config)   // same size and fps: the rebuild a fps-only ladder step does
            reconfigured.signal()
        }
        usleep(100_000)   // the rebuild is now queued behind `hold`
        let a = SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: 0)
        let b = SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: 1)
        // The slot is free, so `a` is admitted, but its submit lands behind the rebuild.
        #expect(encoder.encode(a, presentationTime: CMTime(value: 0, timescale: 60), captureNanos: 1, sequence: 1))
        #expect(encoder.encode(b, presentationTime: CMTime(value: 1, timescale: 60), captureNanos: 2, sequence: 2) == false)
        hold.signal()
        #expect(reconfigured.wait(timeout: .now() + 3) == .success)
        #expect(collector.waitForFrame(encoder, timeout: 1))
        usleep(150_000)
        let frames = collector.all
        #expect(frames.map(\.sequence) == [2], "only the newest frame reaches the new session")
        #expect(frames.first?.isKeyframe == true)
        #expect(!encoder.isEncodeInFlight)
    }

    @Test func nonIncreasingTimestampsDoNotWedgeEncoder() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        let buffer = SyntheticVideo.makeFrame(width: Self.width, height: Self.height, frame: 0)
        for (seq, pts) in [(0, 10), (1, 10), (2, 5), (3, 11)] {
            #expect(encoder.encode(buffer, presentationTime: CMTime(value: CMTimeValue(pts), timescale: 60), captureNanos: 0, sequence: UInt64(seq)))
            #expect(collector.waitForFrame(encoder))
        }
        #expect(collector.all.map(\.sequence) == [0, 1, 2, 3])
        #expect(encoder.encoderDroppedFrames == 0)
    }

    @Test func invalidateStopsEncodingAndIsIdempotent() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: 640, height: 360))
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        let buffer = SyntheticVideo.makeFrame(width: 640, height: 360, frame: 0)
        #expect(encoder.encode(buffer, presentationTime: .zero, captureNanos: 0, sequence: 0))
        encoder.invalidate()   // flushes: the in-flight frame is still delivered
        #expect(collector.all.count == 1)
        encoder.invalidate()
        #expect(encoder.encode(buffer, presentationTime: CMTime(value: 1, timescale: 60), captureNanos: 0, sequence: 1) == false)
        #expect(encoder.droppedForBackpressure == 0)
        #expect(throws: CodecError.invalidated) { try encoder.reconfigure(EncoderConfig(width: 640, height: 360)) }
    }

    @Test func invalidConfigurationsThrow() {
        #expect(throws: CodecError.self) { try H264Encoder(config: EncoderConfig(width: 0, height: 720)) }
        #expect(throws: CodecError.self) { try H264Encoder(config: EncoderConfig(width: 1281, height: 720)) }
        #expect(throws: CodecError.self) { try H264Encoder(config: EncoderConfig(width: 1280, height: 720, fps: 0)) }
        #expect(throws: CodecError.self) { try H264Encoder(config: EncoderConfig(width: 1280, height: 720, bitrateKbps: 0)) }
    }

    @Test func setBitrateAppliesLive() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height, bitrateKbps: 3000))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height, count: 5)
        encoder.setBitrate(kbps: 1000)
        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height, count: 5, startIndex: 5)
        #expect(encoder.currentConfig.bitrateKbps == 1000)
        #expect(encoder.appliedProperties["AverageBitRate"] == true)
        #expect(collector.all.count == 10)
        #expect(collector.all.dropFirst().allSatisfy { !$0.isKeyframe }, "bitrate change must not force an IDR")
    }

    @Test func reconfigureChangesResolutionAndDecoderFollows() throws {
        let encoder = try H264Encoder(config: EncoderConfig(width: Self.width, height: Self.height))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        try encodeSequence(encoder, collector: collector, width: Self.width, height: Self.height, count: 3)
        try encoder.reconfigure(EncoderConfig(width: 960, height: 540, fps: 30, bitrateKbps: 2000))
        #expect(encoder.currentConfig.width == 960)
        try encodeSequence(encoder, collector: collector, width: 960, height: 540, count: 3, startIndex: 3)
        let frames = collector.all
        try #require(frames.count == 6)
        #expect(frames[3].isKeyframe, "first frame after reconfigure must be a keyframe")

        let decoder = H264Decoder()
        let decoded = DecodedCollector()
        decoded.attach(to: decoder)
        for (i, frame) in frames.enumerated() {
            #expect(decoder.decode(frame.data, frameId: UInt32(i + 1), captureNanos: 0, receivedNanos: 0))
        }
        let sizes = decoded.all.map { (CVPixelBufferGetWidth($0.pixelBuffer), CVPixelBufferGetHeight($0.pixelBuffer)) }
        try #require(sizes.count == 6)
        #expect(sizes[0...2].allSatisfy { $0 == (1280, 720) })
        #expect(sizes[3...5].allSatisfy { $0 == (960, 540) })
        #expect(decoded.allErrors.isEmpty)
        print("[CodecCore] decoder sessions created across 720p→540p change: \(decoder.sessionsCreated)")
    }
}

private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
