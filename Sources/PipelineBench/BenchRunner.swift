import CaptureCore
import CoreMedia
import DiagnosticsCore
import Foundation
import Synchronization
import WireProtocol

/// Drives one bench run end to end and turns the collected metrics into a `BenchResult`.
enum BenchRunner {
    enum RunError: Error, CustomStringConvertible {
        case noDisplay
        case captureFailed(String)

        var description: String {
            switch self {
            case .noDisplay: "no capturable display found"
            case .captureFailed(let message): "capture failed: \(message)"
            }
        }
    }

    static func expectedFrames(_ options: BenchOptions) -> Int {
        Int(options.seconds * Double(options.fps)) + 128
    }

    static func pipelineConfig(_ options: BenchOptions, width: Int, height: Int) -> LoopbackPipeline.Config {
        LoopbackPipeline.Config(width: width, height: height, fps: options.fps, bitrateKbps: options.bitrateKbps,
                                lossPercent: options.lossPercent, seed: options.seed,
                                maxDatagramSize: options.maxDatagramSize, expectedFrames: expectedFrames(options),
                                duplicateKeyframes: options.duplicateKeyframes, fec: fecConfiguration(options.fec))
    }

    static func fecConfiguration(_ fec: BenchFEC) -> FECPolicy.Configuration {
        switch fec {
        case .off: .off
        case .adaptive: FECPolicy.Configuration()
        case .fixed(let k): .fixed(k)
        }
    }

    // MARK: Synthetic

    /// Synchronous: blocks the calling thread for `options.seconds`. Nothing in the pipeline needs the main thread.
    static func runSynthetic(_ options: BenchOptions) throws -> BenchResult {
        let source = try SyntheticFrameSource(width: options.width, height: options.height, fps: options.fps,
                                              poolSize: 4, expectedFrames: expectedFrames(options))
        let pipeline = try LoopbackPipeline(config: pipelineConfig(options, width: options.width, height: options.height))

        let cpuStart = ProcessCPU.seconds()
        let start = MonotonicClock.nowNanos()
        source.start { buffer, pts, captureNanos, sequence in
            pipeline.submit(buffer, presentationTime: pts, captureNanos: captureNanos, sequence: sequence)
        }
        Thread.sleep(forTimeInterval: options.seconds)
        source.stop()
        let end = MonotonicClock.nowNanos()
        pipeline.finish()
        let cpu = ProcessCPU.seconds() - cpuStart

        return makeResult(options: options, pipeline: pipeline,
                          sourceDescription: "generated IOSurface 420v frames (pool of \(source.poolSize), CPU-filled)",
                          durationNanos: end - start, cpuSeconds: cpu,
                          generated: source.framesGenerated.load, sourceSkipped: source.poolExhausted.load,
                          fill: source.fillMillis.summary(), notes: [
                              "synthetic content: scrolling gradient + bouncing box + per-frame noise strip; "
                                  + "real desktop content compresses differently",
                          ])
    }

    // MARK: Capture

    /// Requires Screen Recording permission (checked by the caller without prompting).
    @MainActor
    static func runCapture(_ options: BenchOptions) async throws -> BenchResult {
        let displays: [DisplayInfo]
        do {
            displays = try await ScreenCapturer.availableDisplays()
        } catch {
            throw RunError.captureFailed(String(describing: error))
        }
        let mainID = CGMainDisplayID()
        guard let display = displays.first(where: { $0.id == mainID }) ?? displays.first else { throw RunError.noDisplay }

        let capturer = ScreenCapturer(display: display,
                                      config: CaptureConfig(maxWidth: options.width, maxHeight: options.height,
                                                            fps: options.fps))
        // The pipeline is created once the real output size is known; frames that arrive earlier are not counted.
        let active = Mutex<LoopbackPipeline?>(nil)
        let generated = Counter()
        capturer.onFrame = { frame in
            guard let pipeline = active.withLock({ $0 }) else { return }
            generated.add()
            pipeline.submit(frame.pixelBuffer, presentationTime: frame.presentationTime,
                            captureNanos: frame.captureNanos, sequence: frame.sequence)
        }
        let stoppedBySystem = Mutex<String?>(nil)
        capturer.onStopped = { error in
            stoppedBySystem.withLock { $0 = error.map { String(describing: $0) } ?? "stopped by system" }
        }

        do {
            try await capturer.start()
        } catch {
            throw RunError.captureFailed(String(describing: error))
        }
        let size = capturer.outputSize
        let pipeline: LoopbackPipeline
        do {
            pipeline = try LoopbackPipeline(config: pipelineConfig(options, width: size.width, height: size.height))
        } catch {
            await capturer.stop()
            throw error
        }
        capturer.diagnostics.reset()
        let cpuStart = ProcessCPU.seconds()
        let start = MonotonicClock.nowNanos()
        active.withLock { $0 = pipeline }

        try? await Task.sleep(for: .milliseconds(Int(options.seconds * 1000)))

        active.withLock { $0 = nil }
        let end = MonotonicClock.nowNanos()
        let captureSnapshot = capturer.diagnostics.snapshot()
        await capturer.stop()
        pipeline.finish()
        let cpu = ProcessCPU.seconds() - cpuStart

        var notes = [
            "ScreenCaptureKit only delivers complete frames when screen content changes; a static desktop yields "
                + "few frames (idle frames this run: \(captureSnapshot.framesIdle))",
        ]
        if captureSnapshot.displayToCallbackMillis.count > 0 {
            let s = captureSnapshot.displayToCallbackMillis
            notes.append(String(format: "compositor display -> capture callback: p50 %.3f p95 %.3f max %.3f ms (window)",
                                s.p50, s.p95, s.max))
        }
        if let reason = stoppedBySystem.withLock({ $0 }) { notes.append("capture stopped early: \(reason)") }
        let settings = capturer.appliedSettings.map { "\($0.width)x\($0.height)@\($0.fps)" } ?? "\(size.width)x\(size.height)"
        return makeResult(options: options, pipeline: pipeline,
                          sourceDescription: "ScreenCaptureKit main display '\(display.name)' "
                              + "(\(display.pixelWidth)x\(display.pixelHeight) px) scaled to \(settings)",
                          durationNanos: end - start, cpuSeconds: cpu,
                          generated: generated.load, sourceSkipped: 0, fill: nil, notes: notes)
    }

    // MARK: Result assembly

    static func makeResult(options: BenchOptions, pipeline: LoopbackPipeline, sourceDescription: String,
                           durationNanos: UInt64, cpuSeconds: Double, generated: UInt64, sourceSkipped: UInt64,
                           fill: RollingStats.Summary?, notes: [String]) -> BenchResult {
        let m = pipeline.metrics
        let encoder = pipeline.encoder
        let decoder = pipeline.decoder
        func stage(_ key: String, _ label: String, _ series: SampleSeries) -> BenchResult.Stage {
            BenchResult.Stage(key: key, label: label, summary: series.summary(), p99: series.percentile(0.99))
        }
        let stages = [
            stage("src_encdone", "source -> encodeDone", m.sourceToEncodeDone),
            stage("vt_encode", "  of which VT submit -> encodeDone", m.encodeSubmitToDone),
            stage("encdone_pkt", "encodeDone -> packetized", m.encodeDoneToPacketized),
            stage("pkt_reasm", "packetized -> reassembled (no net)", m.packetizedToReassembled),
            stage("reasm_decdone", "reassembled -> decodeDone", m.reassembledToDecodeDone),
            stage("src_decdone", "source -> decodeDone (end-to-end)", m.sourceToDecodeDone),
        ]
        return BenchResult(
            options: options, machine: .current(), sourceDescription: sourceDescription,
            width: pipeline.config.width, height: pipeline.config.height,
            durationSeconds: Double(durationNanos) / 1e9, cpuSeconds: cpuSeconds,
            framesGenerated: generated, framesSourceSkipped: sourceSkipped,
            framesSizeMismatch: m.framesSizeMismatch.load, framesSubmitted: m.framesSubmitted.load,
            framesDroppedBackpressure: encoder.droppedForBackpressure, framesEncoderDropped: encoder.encoderDroppedFrames,
            framesWaitingSubmitted: encoder.waitingFramesSubmitted, refreshes: encoder.refreshesSubmitted,
            framesEncoded: m.framesEncoded.load, keyframes: m.keyframesEncoded.load,
            recoveryKeyframes: m.recoveryKeyframes.load, encodedBytes: m.encodedBytes.load,
            datagramsSent: m.datagramsSent.load, datagramBytes: m.datagramBytes.load,
            datagramsDropped: m.datagramsDropped.load, framesReassembled: m.framesReassembled.load,
            framesDecoded: m.framesDecoded.load, decodeFailures: m.decodeFailures.load,
            framesLost: m.framesLost.load, lossEvents: m.lossEvents.load,
            keyframeRequests: m.keyframeRequests.load, keyframeRequestsFromTick: m.keyframeRerequests.load,
            framesGated: m.framesGated.load, endedAwaitingKeyframe: pipeline.endedAwaitingKeyframe,
            recovery: m.recoveryTime.summary(), stages: stages, fill: fill,
            hardwareEncoder: encoder.isHardwareAccelerated, requiredHardware: encoder.requiredHardwareEncoder,
            lowLatency: encoder.lowLatencyRateControl, profileLevel: encoder.profileLevel,
            appliedProperties: encoder.appliedProperties, hardwareDecoder: decoder.isHardwareAccelerated,
            decoderRealTime: decoder.realTimeApplied, decoderSessions: decoder.sessionsCreated,
            stalledEncodeResets: encoder.stalledEncodeResets,
            fec: BenchResult.FECSummary(parityDatagrams: m.parityDatagrams.load,
                                        framesWithParity: m.framesWithParity.load,
                                        groupSizeSum: m.fecGroupSizeSum.load,
                                        finalGroupSize: pipeline.finalFECGroupSize,
                                        reassembly: pipeline.reassemblyStats),
            notes: notes)
    }
}
