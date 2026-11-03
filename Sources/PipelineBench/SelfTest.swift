import CodecCore
import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization
import WireProtocol

/// Built-in checks run with `PipelineBench --self-test`.
///
/// Package.swift has no test target for this executable (and this module may not edit it), so the bench verifies
/// its own pure logic and its wiring of the real codec/wire modules here. Each check prints PASS/FAIL; the exit code
/// is the number of failures (capped at 125), so CI can gate on it.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passes = 0

    private static func check(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
            print("PASS \(what)")
        } else {
            failures += 1
            let d = detail()
            print("FAIL \(what)" + (d.isEmpty ? "" : " — \(d)"))
        }
    }

    static func run() -> Int32 {
        print("== PipelineBench self-test ==")
        optionParsing()
        randomAndLoss()
        sampleSeries()
        triangleWave()
        syntheticFrames()
        reportFormatting()
        codecRoundTrip()
        pipelineLossless()
        pipelineLossy()
        pipelineLossyWithFEC()
        print("self-test: \(passes) passed, \(failures) failed")
        return Int32(min(failures, 125))
    }

    // MARK: Options

    private static func optionParsing() {
        let defaults = try? BenchOptions.parse([])
        check(defaults == BenchOptions(), "options: defaults")
        check(defaults.map { $0.seconds == 10 && $0.mode == .synthetic && $0.bitrateKbps == 3000 && $0.lossPercent == 0
                && $0.width == 1280 && $0.height == 720 && $0.fps == 60 && $0.maxDatagramSize == 1150 } ?? false,
              "options: default values match the spec")
        check(defaults.map { !$0.duplicateKeyframes } ?? false, "options: keyframe duplication off by default")
        check(defaults.map { $0.fec == .off } ?? false, "options: FEC off by default")
        check((try? BenchOptions.parse(["--fec"]))?.fec == .adaptive, "options: --fec is adaptive")
        check((try? BenchOptions.parse(["--fec-k", "4"]))?.fec == .fixed(4)
                && (try? BenchOptions.parse(["--fec-k=10"]))?.fec == .fixed(10), "options: --fec-k fixes K")
        check(BenchFEC.off.label == "off" && BenchFEC.adaptive.label == "auto" && BenchFEC.fixed(6).label == "k6",
              "options: FEC RESULT labels")

        let full = try? BenchOptions.parse(["--seconds", "2.5", "--mode", "capture", "--bitrate", "5000", "--loss=3",
                                            "--width", "960", "--height=540", "--fps", "30", "--seed", "42", "--mtu", "1200",
                                            "--dup-keyframes"])
        check(full.map { $0.seconds == 2.5 && $0.mode == .capture && $0.bitrateKbps == 5000 && $0.lossPercent == 3
                && $0.width == 960 && $0.height == 540 && $0.fps == 30 && $0.seed == 42 && $0.maxDatagramSize == 1200
                && $0.duplicateKeyframes } ?? false,
              "options: every flag, both spellings")

        func rejects(_ args: [String], _ expected: BenchOptions.ParseError, _ name: String) {
            do {
                _ = try BenchOptions.parse(args)
                check(false, "options: rejects \(name)", "parsed successfully")
            } catch {
                check(error == expected, "options: rejects \(name)", "got \(error)")
            }
        }
        rejects(["--width", "1279"], .invalidValue("--width", "1279"), "odd width")
        rejects(["--height", "0"], .invalidValue("--height", "0"), "zero height")
        rejects(["--loss", "101"], .invalidValue("--loss", "101"), "loss > 100")
        rejects(["--loss", "nan"], .invalidValue("--loss", "nan"), "NaN loss")
        rejects(["--mode", "turbo"], .invalidValue("--mode", "turbo"), "unknown mode")
        rejects(["--fps"], .missingValue("--fps"), "missing value")
        rejects(["--frobnicate"], .unknownArgument("--frobnicate"), "unknown flag")
        rejects(["--fec-k", "0"], .invalidValue("--fec-k", "0"), "FEC K 0")
        rejects(["--fec-k", "256"], .invalidValue("--fec-k", "256"), "FEC K > 255")
        check((try? BenchOptions.parse(["--self-test"]))?.selfTest == true, "options: --self-test")
    }

    // MARK: RNG / loss

    private static func randomAndLoss() {
        var a = SplitMix64(seed: 0)
        // Reference value of SplitMix64 for seed 0 (Vigna's reference implementation).
        check(a.next() == 0xE220_A839_7B1D_CDAF, "splitmix64: reference output for seed 0")
        var b = SplitMix64(seed: 1234), c = SplitMix64(seed: 1234)
        check((0..<1000).allSatisfy { _ in b.next() == c.next() }, "splitmix64: same seed, same stream")
        var u = SplitMix64(seed: 99)
        check((0..<10_000).allSatisfy { _ in let v = u.nextUnitDouble(); return v >= 0 && v < 1 }, "splitmix64: unit doubles in [0,1)")

        var none = LossSimulator(lossPercent: 0, seed: 1)
        check((0..<10_000).allSatisfy { _ in !none.shouldDrop() }, "loss: 0% never drops")
        var all = LossSimulator(lossPercent: 100, seed: 1)
        check((0..<10_000).allSatisfy { _ in all.shouldDrop() }, "loss: 100% always drops")
        for pct in [1.0, 3.0] {
            var sim = LossSimulator(lossPercent: pct, seed: 7)
            let n = 200_000
            var dropped = 0
            for _ in 0..<n where sim.shouldDrop() { dropped += 1 }
            let measured = Double(dropped) * 100 / Double(n)
            check(abs(measured - pct) < pct * 0.1, "loss: \(pct)% rate within 10%", "measured \(measured)%")
        }
        var s1 = LossSimulator(lossPercent: 3, seed: 5), s2 = LossSimulator(lossPercent: 3, seed: 5)
        check((0..<5000).allSatisfy { _ in s1.shouldDrop() == s2.shouldDrop() }, "loss: reproducible with the same seed")
    }

    // MARK: Samples

    private static func sampleSeries() {
        let series = SampleSeries(expected: 8)
        for v in [5.0, 1.0, 3.0, 2.0, 4.0] { series.addMillis(v) }
        series.addMillis(.nan)
        let s = series.summary()
        check(series.count == 5 && s == RollingStats.summarize([1, 2, 3, 4, 5]), "samples: non-finite ignored, matches RollingStats")
        check(s.p50 == 3 && s.p95 == 5 && s.max == 5, "samples: nearest-rank p50/p95/max")
        let clamp = SampleSeries(expected: 2)
        clamp.add(from: 2_000_000, to: 1_000_000)
        clamp.add(from: 1_000_000, to: 3_500_000)
        let c = clamp.summary()
        check(c.count == 2 && c.p50 == 0 && c.max == 2.5, "samples: ns→ms conversion, reversed interval clamps to 0")
        check(SampleSeries(expected: 1).summary() == .empty && SampleSeries(expected: 1).percentile(0.99) == 0,
              "samples: empty summary")
        let hundred = SampleSeries(expected: 100)
        for v in 1...100 { hundred.addMillis(Double(v)) }
        check(hundred.percentile(0.99) == 99 && hundred.percentile(0.5) == hundred.summary().p50 && hundred.percentile(1) == 100,
              "samples: p99 nearest-rank, consistent with RollingStats")
    }

    private static func triangleWave() {
        check(SyntheticFrameSource.triangle(0, span: 10) == 0 && SyntheticFrameSource.triangle(10, span: 10) == 10
                && SyntheticFrameSource.triangle(15, span: 10) == 5 && SyntheticFrameSource.triangle(20, span: 10) == 0
                && SyntheticFrameSource.triangle(5, span: 0) == 0,
              "triangle wave bounces within 0...span")
        check((0..<10_000).allSatisfy { (0...37).contains(SyntheticFrameSource.triangle($0 * 7, span: 37)) },
              "triangle wave never leaves range")
    }

    // MARK: Synthetic frames

    private static func syntheticFrames() {
        guard let source = try? SyntheticFrameSource(width: 1280, height: 720, fps: 60, poolSize: 3, expectedFrames: 8) else {
            check(false, "synthetic: pool creation")
            return
        }
        guard let f1 = source.makeFrame(frameIndex: 1), let f2 = source.makeFrame(frameIndex: 2) else {
            check(false, "synthetic: frame creation")
            return
        }
        check(CVPixelBufferGetPixelFormatType(f1) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                && CVPixelBufferGetWidth(f1) == 1280 && CVPixelBufferGetHeight(f1) == 720,
              "synthetic: 420v 1280x720")
        check(CVPixelBufferGetIOSurface(f1) != nil, "synthetic: IOSurface-backed")
        let matrix = CVBufferCopyAttachment(f1, kCVImageBufferYCbCrMatrixKey, nil) as? String
        check(matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String), "synthetic: BT.709 matrix attachment", "\(matrix ?? "nil")")

        let (min1, max1, sum1) = lumaStats(f1)
        let (_, _, sum2) = lumaStats(f2)
        check(min1 >= 16 && max1 <= 235, "synthetic: luma within video range", "min \(min1) max \(max1)")
        check(max1 - min1 > 150, "synthetic: content has contrast")
        check(sum1 != sum2 || !planesEqual(f1, f2), "synthetic: consecutive frames differ")

        // Pool cap: f1, f2 and a third are held; a fourth must be refused rather than allocated.
        let f3 = source.makeFrame(frameIndex: 3)
        let f4 = source.makeFrame(frameIndex: 4)
        check(f3 != nil && f4 == nil, "synthetic: pool allocation threshold enforced (newest-frame-wins upstream)")
        withExtendedLifetime((f1, f2, f3)) {}
        timerPacing()
    }

    /// Fresh source (the one above has its pool deliberately exhausted). Buffers are released immediately, like the
    /// encoder does, so every tick should produce a frame.
    private static func timerPacing() {
        guard let source = try? SyntheticFrameSource(width: 640, height: 360, fps: 60, poolSize: 4, expectedFrames: 64) else {
            check(false, "synthetic: timer source creation")
            return
        }
        let ticks = Atomic<Int>(0)
        source.start { _, _, _, _ in ticks.add(1, ordering: .relaxed) }
        Thread.sleep(forTimeInterval: 0.5)
        source.stop()
        let n = ticks.load(ordering: .relaxed)
        check((25...35).contains(n), "synthetic: 60 Hz timer delivers ~30 frames in 0.5 s", "\(n)")
        check(source.poolExhausted.load == 0 && source.framesGenerated.load == UInt64(n),
              "synthetic: no pool exhaustion when buffers are released promptly")
        let after = ticks.load(ordering: .relaxed)
        Thread.sleep(forTimeInterval: 0.05)
        check(ticks.load(ordering: .relaxed) == after, "synthetic: no frames after stop()")
    }

    private static func lumaStats(_ buffer: CVPixelBuffer) -> (min: Int, max: Int, sum: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var lo = 255, hi = 0, sum = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let v = Int(base[y * stride + x])
                lo = min(lo, v); hi = max(hi, v); sum += v
            }
        }
        return (lo, hi, sum)
    }

    private static func planesEqual(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        lumaMeanAbsDiff(a, b) == 0
    }

    /// Mean absolute luma difference over the whole frame (both buffers must have the same size).
    private static func lumaMeanAbsDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var total = 0
        for y in 0..<h {
            for x in 0..<w { total += abs(Int(pa[y * sa + x]) - Int(pb[y * sb + x])) }
        }
        return Double(total) / Double(w * h)
    }

    // MARK: Report

    private static func reportFormatting() {
        let summary = RollingStats.summarize([1, 2, 3])
        let result = BenchResult(
            options: BenchOptions(), machine: MachineInfo(model: "Mac Test", chip: "chip", osVersion: "1.2.3", osBuild: "X", cpuCount: 1),
            sourceDescription: "test", width: 1280, height: 720, durationSeconds: 2, cpuSeconds: 1,
            framesGenerated: 120, framesSourceSkipped: 0, framesSizeMismatch: 0, framesSubmitted: 118,
            framesDroppedBackpressure: 2, framesEncoderDropped: 0, framesEncoded: 118, keyframes: 1, recoveryKeyframes: 0,
            encodedBytes: 750_000, datagramsSent: 700, datagramBytes: 772_400, datagramsDropped: 0, framesReassembled: 118,
            framesDecoded: 118, decodeFailures: 0, framesLost: 0, lossEvents: 0, keyframeRequests: 0,
            keyframeRequestsFromTick: 0, framesGated: 0, endedAwaitingKeyframe: false, recovery: .empty,
            stages: [.init(key: "src_decdone", label: "source -> decodeDone", summary: summary, p99: 3)], fill: summary,
            hardwareEncoder: true, requiredHardware: true, lowLatency: true, profileLevel: nil,
            appliedProperties: ["RealTime": true, "MaxFrameDelayCount": false], hardwareDecoder: nil, decoderRealTime: true,
            decoderSessions: 1,
            stalledEncodeResets: 0, fec: .init(), notes: [])
        check(abs(result.encodeFPS - 59) < 1e-9 && abs(result.videoKbps - 3000) < 1e-9, "report: derived fps / kbps")
        let line = result.resultLine()
        let fields = line.split(separator: " ")
        check(fields.first == "RESULT", "report: RESULT prefix")
        let pairs = fields.dropFirst().map { $0.split(separator: "=", maxSplits: 1) }
        check(pairs.allSatisfy { $0.count == 2 && !$0[1].isEmpty }, "report: every field is key=value with no spaces")
        let keys = pairs.map { String($0[0]) }
        check(Set(keys).count == keys.count, "report: keys unique")
        check(keys.contains("src_decdone_p95_ms") && line.contains("model=Mac_Test") && line.contains("hw_encoder=true"),
              "report: stage keys, sanitized model, flags")
        check(line.contains(" fec=off ") && keys.contains("parity_datagrams") && keys.contains("fragments_recovered")
                && keys.contains("decode_fps"), "report: FEC keys present")
        let text = result.render()
        check(text.hasSuffix(line) && text.contains("MaxFrameDelayCount=NO"), "report: RESULT is the last line; rejected props flagged")
        check(MachineInfo.sysctlString("hw.model").map { !$0.isEmpty } ?? false, "machine: sysctl hw.model readable")
    }

    // MARK: Codec wiring

    /// One keyframe through the real encoder and decoder: proves the AVCC hand-off works and the decoded picture
    /// actually resembles the source (not just "a buffer came out").
    private static func codecRoundTrip() {
        guard let source = try? SyntheticFrameSource(width: 1280, height: 720, fps: 60, poolSize: 2, expectedFrames: 2),
              let input = source.makeFrame(frameIndex: 10),
              let encoder = try? H264Encoder(config: EncoderConfig(width: 1280, height: 720, fps: 60, bitrateKbps: 6000))
        else {
            check(false, "codec: setup")
            return
        }
        let encoded = Mutex<EncodedVideoFrame?>(nil)
        let done = DispatchSemaphore(value: 0)
        encoder.onEncodedFrame = { frame in
            encoded.withLock { $0 = frame }
            done.signal()
        }
        check(encoder.encode(input, presentationTime: CMTime(value: 1, timescale: 60), captureNanos: MonotonicClock.nowNanos(), sequence: 1),
              "codec: encoder accepts a 420v IOSurface buffer")
        let gotFrame = done.wait(timeout: .now() + 2) == .success
        encoder.invalidate()
        guard gotFrame, let frame = encoded.withLock({ $0 }) else {
            check(false, "codec: encoded frame delivered within 2 s")
            return
        }
        check(frame.isKeyframe && AVCC.containsIDR(frame.data), "codec: first frame is an IDR with in-band parameter sets")

        let packetizer = VideoPacketizer(sessionId: 1, maxDatagramSize: 1150)
        let reassembler = FrameReassembler(config: FrameReassembler.Config(sessionId: 1))
        guard let datagrams = try? packetizer.packetize(frameId: 1, frame: frame.data, flags: .keyframe,
                                                         captureTimestampNanos: frame.captureNanos, hostPipelineMicros: 0)
        else {
            check(false, "codec: packetize")
            return
        }
        check(datagrams.allSatisfy { $0.count <= 1150 }, "wire: datagrams within 1150 B", "\(datagrams.map(\.count).max() ?? 0)")
        var completed: EncodedFrame?
        for d in datagrams.reversed() {   // reversed order: reassembly must not depend on arrival order
            guard case .video(let h, let p)? = try? Datagram.parse(d) else { continue }
            for case .frameComplete(let f) in reassembler.ingest(header: h, payload: p, nowNanos: MonotonicClock.nowNanos()) {
                completed = f
            }
        }
        check(completed?.data == frame.data, "wire: reassembled access unit is byte-identical")

        // Same keyframe with FEC (K = 6), data fragments 0..<G dropped (one per interleaved group): parity must
        // rebuild them all.
        let fecReassembler = FrameReassembler(config: FrameReassembler.Config(sessionId: 1))
        var fecCompleted: EncodedFrame?
        if let fecDatagrams = try? packetizer.packetize(frameId: 1, frame: frame.data, flags: .keyframe,
                                                         captureTimestampNanos: frame.captureNanos, hostPipelineMicros: 0,
                                                         fecGroupSize: 6) {
            let groups = fecDatagrams.count - datagrams.count
            for (i, d) in fecDatagrams.enumerated() where i >= groups {
                guard let parsed = try? Datagram.parse(d) else { continue }
                for case .frameComplete(let f) in fecReassembler.ingest(parsed, nowNanos: MonotonicClock.nowNanos()) {
                    fecCompleted = f
                }
            }
        }
        check(fecCompleted?.data == frame.data && fecReassembler.stats.fragmentsRecovered > 0,
              "wire: FEC rebuilds dropped keyframe fragments byte-identically",
              "recovered \(fecReassembler.stats.fragmentsRecovered)")

        let decoder = H264Decoder()
        let decoded = Mutex<DecodedFrame?>(nil)
        decoder.onDecodedFrame = { f in decoded.withLock { $0 = f } }
        let ok = decoder.decode(completed?.data ?? frame.data, frameId: 1, captureNanos: frame.captureNanos,
                                receivedNanos: MonotonicClock.nowNanos())
        guard ok, let output = decoded.withLock({ $0 }) else {
            check(false, "codec: decoder produced a picture synchronously")
            return
        }
        check(CVPixelBufferGetWidth(output.pixelBuffer) == 1280 && CVPixelBufferGetHeight(output.pixelBuffer) == 720,
              "codec: decoded size matches")
        let mad = lumaMeanAbsDiff(input, output.pixelBuffer)
        check(mad < 12, "codec: decoded luma resembles the source", String(format: "mean abs diff %.2f", mad))
        print(String(format: "info: keyframe %d B, %d datagrams, luma mean abs diff %.2f", frame.data.count, datagrams.count, mad))
    }

    // MARK: Pipeline

    private static func shortRun(seconds: Double, loss: Double) -> BenchResult? {
        var options = BenchOptions()
        options.seconds = seconds
        options.lossPercent = loss
        do { return try BenchRunner.runSynthetic(options) } catch {
            check(false, "pipeline: run (loss \(loss)%)", "\(error)")
            return nil
        }
    }

    private static func pipelineLossless() {
        guard let r = shortRun(seconds: 2, loss: 0) else { return }
        print("info: " + r.resultLine())
        check(r.framesEncoded > 90, "pipeline 0%: encodes ~60 fps", "\(r.framesEncoded) in \(r.durationSeconds) s")
        check(r.framesDecoded == r.framesEncoded, "pipeline 0%: every encoded frame decoded", "\(r.framesDecoded)/\(r.framesEncoded)")
        check(r.framesLost == 0 && r.framesGated == 0 && r.keyframeRequests == 0 && r.datagramsDropped == 0,
              "pipeline 0%: no loss, gating or keyframe requests")
        check(r.keyframes >= 1, "pipeline 0%: starts with a keyframe")
        let e2e = r.stages.first { $0.key == "src_decdone" }?.summary
        check((e2e?.count ?? 0) == Int(r.framesDecoded) && (e2e?.p50 ?? 0) > 0, "pipeline 0%: end-to-end latency sampled per frame")
        check(r.framesSubmitted + r.framesDroppedBackpressure + r.framesSourceSkipped == r.framesGenerated,
              "pipeline 0%: frame accounting adds up",
              "gen \(r.framesGenerated) sub \(r.framesSubmitted) bp \(r.framesDroppedBackpressure) skip \(r.framesSourceSkipped)")
    }

    private static func pipelineLossy() {
        guard let r = shortRun(seconds: 4, loss: 1) else { return }
        print("info: " + r.resultLine())
        check(r.datagramsDropped > 0 && r.framesLost > 0, "pipeline 1%: loss is detected as frame loss")
        check(r.keyframeRequests > 0 && r.recoveryKeyframes > 0, "pipeline 1%: loss triggers keyframe requests and recovery IDRs")
        check(r.recovery.count > 0, "pipeline 1%: decoding recovers after loss")
        check(r.framesDecoded + r.framesGated + r.framesLost + r.decodeFailures + 3 >= r.framesEncoded,
              "pipeline 1%: every encoded frame is decoded, gated or lost",
              "dec \(r.framesDecoded) gated \(r.framesGated) lost \(r.framesLost) enc \(r.framesEncoded)")
        // Submissions = frames `encode` accepted + frames that waited in the latest-frame slot + static-screen refreshes.
        check(r.framesSubmitted + r.framesWaitingSubmitted + r.refreshes == r.framesEncoded + r.framesEncoderDropped,
              "pipeline 1%: every submitted frame is encoded or reported dropped by VideoToolbox",
              "sub \(r.framesSubmitted) waiting \(r.framesWaitingSubmitted) refresh \(r.refreshes) enc \(r.framesEncoded) vtDropped \(r.framesEncoderDropped)")
        check(r.keyframes >= r.recoveryKeyframes + 1, "pipeline 1%: recovery IDRs are a subset of keyframes")
    }

    private static func pipelineLossyWithFEC() {
        var options = BenchOptions()
        options.seconds = 4
        options.lossPercent = 1
        options.fec = .adaptive
        let r: BenchResult
        do { r = try BenchRunner.runSynthetic(options) } catch {
            check(false, "pipeline FEC: run", "\(error)")
            return
        }
        print("info: " + r.resultLine())
        check(r.fec.parityDatagrams > 0 && r.fec.framesWithParity > 0, "pipeline 1% FEC: parity datagrams sent")
        check(r.fec.reassembly.fragmentsRecovered > 0, "pipeline 1% FEC: lost fragments rebuilt from parity")
        check(r.framesDecoded + r.framesGated + r.framesLost + r.decodeFailures + 3 >= r.framesEncoded,
              "pipeline 1% FEC: every encoded frame is decoded, gated or lost")
    }
}
