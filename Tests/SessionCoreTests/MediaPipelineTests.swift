import CaptureCore
import CoreGraphics
import CoreVideo
import Foundation
import Synchronization
import Testing
import WireProtocol
import DiagnosticsCore
@testable import SessionCore

/// Real VideoToolbox encode/decode through the Host and Viewer pipelines, joined by an in-memory transport.
@Suite("Media pipelines", .serialized, .timeLimit(.minutes(2)))
struct MediaPipelineTests {
    @Test func syntheticSourceDeliversSizedFramesAndStopsCleanly() async throws {
        let source = SyntheticVideoSource(sourceWidth: 1920, sourceHeight: 1080,
                                          config: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60))
        #expect(source.outputSize == (1280, 720))
        let count = Atomic<Int>(0)
        let wrong = Atomic<Int>(0)
        let expected = Mutex((1280, 720))
        source.onFrame = { frame in
            let (w, h) = expected.withLock { $0 }
            if CVPixelBufferGetWidth(frame.pixelBuffer) != w || CVPixelBufferGetHeight(frame.pixelBuffer) != h
                || CVPixelBufferGetPixelFormatType(frame.pixelBuffer) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || CVPixelBufferGetIOSurface(frame.pixelBuffer) == nil {
                wrong.add(1, ordering: .relaxed)
            }
            count.add(1, ordering: .relaxed)
        }
        try await source.start()
        #expect(source.isRunning)
        try await Task.sleep(nanoseconds: 500_000_000)
        await source.stop()
        let afterStop = count.load(ordering: .relaxed)
        #expect(afterStop >= 15, "strict 60 fps timer should deliver ~30 frames in 0.5 s, got \(afterStop)")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(count.load(ordering: .relaxed) == afterStop, "no frame after stop()")
        #expect(wrong.load(ordering: .relaxed) == 0)

        expected.withLock { $0 = (960, 540) }
        try await source.update(config: CaptureConfig(maxWidth: 960, maxHeight: 540, fps: 30))
        #expect(source.outputSize == (960, 540))
        try await source.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await source.stop()
        #expect(wrong.load(ordering: .relaxed) == 0)
        #expect(count.load(ordering: .relaxed) > afterStop)
    }

    @Test func simulatedSystemStopFiresOnStopped() async throws {
        let source = SyntheticVideoSource(config: CaptureConfig(maxWidth: 640, maxHeight: 360, fps: 30))
        let stopped = Atomic<Bool>(false)
        source.onStopped = { _ in stopped.store(true, ordering: .relaxed) }
        try await source.start()
        source.simulateSystemStop()
        #expect(await eventuallyDetached { stopped.load(ordering: .relaxed) })
        #expect(!source.isRunning)
    }

    /// Wires host → viewer datagrams and viewer → host control through fake transports, with optional loss.
    private final class Rig: @unchecked Sendable {
        let hostTransport = FakeTransport()
        let viewerTransport = FakeTransport()
        let sink = RecordingFrameSink()
        let slot = FrameSinkSlot()
        let source: SyntheticVideoSource
        let host: HostMediaPipeline
        let viewer: ViewerMediaPipeline
        let hostMetrics = Mutex<MetricsSnapshot?>(nil)
        let viewerMetrics = Mutex<MetricsSnapshot?>(nil)
        let dropped = Atomic<Int>(0)
        private let lossState: Mutex<(percent: Double, rng: UInt64)>

        init(lossPercent: Double = 0, adaptation: Bool = false, fec: FECPolicy.Configuration = FECPolicy.Configuration()) throws {
            lossState = Mutex((lossPercent, 0x9E37_79B9_7F4A_7C15))
            slot.sink = sink
            source = SyntheticVideoSource(sourceWidth: 1280, sourceHeight: 720,
                                          config: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60),
                                          displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 810))
            var config = HostMediaPipeline.Configuration(sessionId: 77, displayPointSize: CGSize(width: 1440, height: 810))
            config.adaptationEnabled = adaptation
            config.fec = fec
            host = try HostMediaPipeline(configuration: config, source: source, transport: hostTransport)
            viewer = ViewerMediaPipeline(sessionId: 77, transport: viewerTransport, sinkSlot: slot)

            hostTransport.onDatagrams = { [self] batch in
                for datagram in batch where !self.shouldDrop() { viewer.ingest(datagram) }
            }
            hostTransport.onControl = { [self] message in
                switch message {
                case .ping(let p): host.pong(p)                   // the "viewer" echoes host pings
                case .config(let c): viewer.configure(c)
                default: break
                }
            }
            viewerTransport.onControl = { [self] message in
                switch message {
                case .requestKeyframe: host.keyframeRequested()
                case .ping(let p): viewer.pong(p)                 // the "host" echoes viewer pings
                case .stats(let s): host.viewerStats(s)
                default: break
                }
            }
            host.onMetrics = { [self] m in hostMetrics.withLock { $0 = m } }
            viewer.onMetrics = { [self] m in viewerMetrics.withLock { $0 = m } }
        }

        func shouldDrop() -> Bool {
            lossState.withLock { s in
                guard s.percent > 0 else { return false }
                s.rng ^= s.rng << 13
                s.rng ^= s.rng >> 7
                s.rng ^= s.rng << 17
                let drop = Double(s.rng % 10_000) / 100 < s.percent
                if drop { dropped.add(1, ordering: .relaxed) }
                return drop
            }
        }

        func start() async throws {
            viewer.start()
            try await host.start()
        }

        func stop() async {
            await host.stop()
            viewer.stop()
        }
    }

    /// The send-queue bound is time-based: ~80 ms of video at the target bitrate, plus the part of the last keyframe
    /// batch the link cannot have drained yet at that rate (review finding latency-3).
    @Test func sendQueueBoundIsTimeBasedWithKeyframeAllowance() {
        // 3000 kbps = 375 000 B/s → 80 ms = 30 000 B.
        #expect(HostMediaPipeline.allowedBacklogAhead(bitrateKbps: 3000, budgetMillis: 80, keyframeBatchBytes: 0,
                                                      sinceKeyframeNanos: 0) == 30_000)
        // 1000 kbps floor: the same 80 ms is 10 000 B (a fixed 256 KiB cap was ~2.1 s here).
        #expect(HostMediaPipeline.allowedBacklogAhead(bitrateKbps: 1000, budgetMillis: 80, keyframeBatchBytes: 0,
                                                      sinceKeyframeNanos: 0) == 10_000)
        // Right after a 108 KB duplicated keyframe, P-frames may queue behind all of it...
        #expect(HostMediaPipeline.allowedBacklogAhead(bitrateKbps: 3000, budgetMillis: 80, keyframeBatchBytes: 108_000,
                                                      sinceKeyframeNanos: 0) == 138_000)
        // ...and the allowance drains at the bitrate: 100 ms later 37 500 B of it are gone.
        #expect(HostMediaPipeline.allowedBacklogAhead(bitrateKbps: 3000, budgetMillis: 80, keyframeBatchBytes: 108_000,
                                                      sinceKeyframeNanos: 100_000_000) == 100_500)
        // Fully drained after 288 ms.
        #expect(HostMediaPipeline.allowedBacklogAhead(bitrateKbps: 3000, budgetMillis: 80, keyframeBatchBytes: 108_000,
                                                      sinceKeyframeNanos: 1_000_000_000) == 30_000)
    }

    @Test func hostPassesTheSendQueueBoundWithEveryBatch() async throws {
        let rig = try Rig()
        try await rig.start()
        #expect(await eventuallyDetached(timeout: 10) { rig.sink.count >= 30 })
        // The first keyframe went out over a second ago, so only the 80 ms budget at 3000 kbps remains.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let bound = try #require(rig.hostTransport.lastMaxQueuedAhead)
        #expect(bound >= 30_000 && bound < 31_000, "bound \(bound)")
        await rig.stop()
    }

    @Test func hostToViewerDecodesInOrderAtFullRate() async throws {
        let rig = try Rig()
        try await rig.start()
        #expect(await eventuallyDetached(timeout: 10) { rig.sink.count >= 60 }, "decoded \(rig.sink.count)")
        // Let the 500 ms metrics timers fire at least twice.
        #expect(await eventuallyDetached(timeout: 5) {
            (rig.hostMetrics.withLock { $0 }?.fps ?? 0) > 10 && (rig.viewerMetrics.withLock { $0 }?.receivedFPS ?? 0) > 10
        })
        // The viewer reports STATS (1 Hz) to the host; wait for the first one rather than racing the 1 s window.
        #expect(await eventuallyDetached(timeout: 5) {
            rig.viewerTransport.controlMessages.contains { if case .stats = $0 { true } else { false } }
        })
        await rig.stop()

        #expect(rig.sink.nonIncreasing == 0)
        #expect(rig.sink.lastSize == (1280, 720))
        let configs = rig.hostTransport.controlMessages.compactMap { m -> StreamConfig? in
            if case .config(let c) = m { c } else { nil }
        }
        let config = try #require(configs.first)
        #expect(config.width == 1280 && config.height == 720 && config.fps == 60 && config.bitrateKbps == 3000)
        #expect(config.displayPointWidth == 1440)

        let host = try #require(rig.hostMetrics.withLock { $0 })
        #expect(host.width == 1280 && host.height == 720)
        #expect(host.captureToEncodeDone.count > 0)
        #expect(host.hostPipeline.count > 0)
        #expect(host.bitrateKbps > 0)
        #expect(host.rtt.smoothedMillis > 0)
        let viewer = try #require(rig.viewerMetrics.withLock { $0 })
        #expect(viewer.networkToDecodeDone.count > 0)
        #expect(viewer.hostPipeline.count > 0)
        #expect(viewer.width == 1280)
        #expect(viewer.rtt.smoothedMillis > 0)
        #expect(viewer.framesLost == 0)

        // No loss: the STATS loss estimate is exactly zero (parity arriving after its frame is not loss).
        let reports = rig.viewerTransport.controlMessages.compactMap { m -> ViewerStats? in
            if case .stats(let s) = m { s } else { nil }
        }
        #expect(reports.allSatisfy { $0.packetsLost == 0 && $0.framesLost == 0 })
        print("[bench] pipeline no-loss: decoded=\(rig.sink.count) captureToEncode p50=\(host.captureToEncodeDone.p50)ms "
              + "hostPipeline p50=\(host.hostPipeline.p50)ms networkToDecode p50=\(viewer.networkToDecodeDone.p50)ms "
              + "hw=\(String(describing: host.hardwareEncoder)) ll=\(String(describing: host.lowLatencyRateControl))")
    }

    /// Keyframe-only recovery (FEC off): the fallback path must still keep video moving.
    @Test func videoStaysLiveUnderThreePercentLoss() async throws {
        let rig = try Rig(lossPercent: 3, fec: .off)
        try await rig.start()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let midway = rig.sink.count
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let end = rig.sink.count
        let viewer = rig.viewerMetrics.withLock { $0 }
        await rig.stop()

        #expect(rig.dropped.load(ordering: .relaxed) > 0)
        #expect(midway >= 30, "decoded only \(midway) frames in 3 s under 3 % loss")
        #expect(end - midway >= 20, "video must keep moving under loss (\(end - midway) frames in the last 2 s)")
        #expect(rig.sink.nonIncreasing == 0)
        let requests = rig.viewerTransport.controlMessages.filter { if case .requestKeyframe = $0 { true } else { false } }
        #expect(!requests.isEmpty, "loss must trigger keyframe requests")
        print("[bench] pipeline 3% loss: decoded=\(end) in 5 s, keyframeRequests=\(requests.count), "
              + "framesLost=\(viewer?.framesLost ?? 0), loss%=\(viewer?.packetLossPercent ?? 0)")
    }

    /// FEC on (production default): single losses are rebuilt from parity, so far fewer frames are lost and the
    /// decoded rate stays close to the source rate. Thresholds are loose (debug build, shared machine); the release
    /// bench in docs/bench measures the real numbers.
    @Test func fecKeepsVideoNearFullRateUnderThreePercentLoss() async throws {
        let rig = try Rig(lossPercent: 3, fec: .fixed(3))
        try await rig.start()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let start = rig.sink.count
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let end = rig.sink.count
        let health = rig.viewer.healthCounters()
        await rig.stop()

        #expect(rig.dropped.load(ordering: .relaxed) > 0)
        #expect(health.reassembly.fragmentsRecovered > 0, "parity must rebuild lost fragments")
        #expect(health.reassembly.parityReceived > 0)
        #expect(health.reassembly.parityMalformed == 0)
        #expect(end - start >= 90, "decoded only \(end - start) frames in 3 s under 3 % loss with FEC")
        #expect(rig.sink.nonIncreasing == 0)
        print("[bench] pipeline 3% loss + FEC k3: decoded=\(end - start) in 3 s, recovered=\(health.reassembly.fragmentsRecovered), "
              + "framesLost=\(health.reassembly.framesLost)")
    }

    @Test func fecGroupSizeFollowsViewerStats() throws {
        let source = SyntheticVideoSource(config: CaptureConfig(maxWidth: 640, maxHeight: 360, fps: 30))
        let config = HostMediaPipeline.Configuration(sessionId: 9, displayPointSize: CGSize(width: 640, height: 360))
        let host = try HostMediaPipeline(configuration: config, source: source, transport: FakeTransport())
        #expect(host.fecGroupSize == FECPolicy.Configuration().initialGroupSize)
        func stats(received: UInt32, lost: UInt32) -> ViewerStats {
            ViewerStats(windowMillis: 1000, packetsReceived: received, packetsLost: lost, framesCompleted: 60,
                        framesLost: 0, framesPresented: 60, decodeMicrosAvg: 0, decodeToPresentMicrosAvg: 0)
        }
        host.viewerStats(stats(received: 970, lost: 30))      // 3 %
        #expect(host.fecGroupSize == 3)
        host.viewerStats(stats(received: 0, lost: 0))         // empty window: no information, no change
        #expect(host.fecGroupSize == 3)
        for _ in 0..<12 { host.viewerStats(stats(received: 1000, lost: 0)) }
        #expect(host.fecGroupSize == 10, "clean reports relax protection to the lowest rung")

        var off = config
        off.fec = .off
        let plain = try HostMediaPipeline(configuration: off, source: source, transport: FakeTransport())
        plain.viewerStats(stats(received: 970, lost: 30))
        #expect(plain.fecGroupSize == 0)
    }

    @Test func hostSendsParityAfterDataAndNoneWhenFECIsOff() async throws {
        for fec in [FECPolicy.Configuration.fixed(4), .off] {
            let rig = try Rig(fec: fec)
            let batches = Mutex<[[Data]]>([])
            let original = rig.hostTransport.onDatagrams
            rig.hostTransport.onDatagrams = { batch in
                batches.withLock { $0.append(batch) }
                original?(batch)
            }
            try await rig.start()
            #expect(await eventuallyDetached { rig.sink.count >= 20 })
            await rig.stop()
            let all = batches.withLock { $0 }
            #expect(!all.isEmpty)
            for batch in all {
                let magics = batch.map { $0[0] }
                let firstParity = magics.firstIndex(of: WireConstants.parityMagic)
                if fec.enabled {
                    // Every frame carries parity, and within one frame's batch all parity follows all its data
                    // (keyframes are duplicated as data+parity, data+parity).
                    #expect(firstParity != nil)
                    if let firstParity { #expect(magics[..<firstParity].allSatisfy { $0 == WireConstants.videoMagic }) }
                    if let h = try? Datagram.parse(batch[0]), case .video(let header, _) = h {
                        #expect(header.fecGroupSize == 4)
                    }
                } else {
                    #expect(firstParity == nil)
                }
            }
            #expect(rig.sink.nonIncreasing == 0)
        }
    }

    @Test func sendBackpressureSkipsToNextKeyframe() async throws {
        let rig = try Rig()
        try await rig.start()
        #expect(await eventuallyDetached { rig.sink.count >= 20 })
        rig.hostTransport.acceptsDatagrams = false
        try await Task.sleep(nanoseconds: 300_000_000)
        let duringBlock = rig.sink.count
        rig.hostTransport.acceptsDatagrams = true
        #expect(await eventuallyDetached { rig.sink.count >= duringBlock + 30 }, "viewer must recover after backpressure")
        let metrics = rig.hostMetrics.withLock { $0 }
        await rig.stop()
        #expect((metrics?.framesDroppedBackpressure ?? 0) > 0)
        #expect(rig.sink.nonIncreasing == 0)
    }

    /// The Host switches its display from 1600×900 to 1920×1080 mid-session: capture, encoder, the ladder's bitrate
    /// range and CONFIG's display size (which the Viewer sizes its window by) follow at once, not at some later
    /// ladder step; a display notification that changed nothing relevant sends nothing.
    @Test func displayChangeRefitsCaptureLadderAndConfig() async throws {
        let source = SyntheticVideoSource(sourceWidth: 1600, sourceHeight: 900,
                                          config: CaptureConfig(maxWidth: 1920, maxHeight: 1080, fps: 60),
                                          displayFrame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let transport = FakeTransport()
        var config = HostMediaPipeline.Configuration(sessionId: 6, displayPointSize: CGSize(width: 1600, height: 900))
        config.adaptationEnabled = false
        let host = try HostMediaPipeline(configuration: config, source: source, transport: transport)
        try await host.start()
        #expect(host.adaptationState.currentCeilingKbps == 8250)
        let configs: @Sendable () -> [StreamConfig] = { transport.controlMessages.compactMap { if case .config(let c) = $0 { c } else { nil } } }
        let first = configs().last
        #expect(first?.width == 1600 && first?.height == 900 && first?.displayPointWidth == 1600)

        // Nothing changed (e.g. another display was plugged in): no reconfiguration, no CONFIG.
        let before = configs().count
        host.displayChanged()
        _ = host.adaptationState   // drains the control queue
        #expect(configs().count == before)

        source.simulateDisplayChange(sourceWidth: 1920, sourceHeight: 1080,
                                     displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(source.outputSize == (1600, 900), "like SCK, capture keeps its size until updated")
        host.displayChanged()
        let followed = await eventuallyDetached(timeout: 10) {
            configs().contains { $0.width == 1920 && $0.height == 1080 && $0.displayPointWidth == 1920
                && $0.displayPointHeight == 1080 }
        }
        #expect(followed, "expected CONFIG 1920×1080 with the new display size")
        #expect(source.outputSize == (1920, 1080))
        #expect(await eventuallyDetached { host.encoder.currentConfig.width == 1920 })
        #expect(host.adaptationState.currentCeilingKbps == 12000)
        #expect(host.adaptationState.rungIndex == 0)
        await host.stop()
    }

    @Test func ladderStepReconfiguresSourceEncoderAndConfig() async throws {
        // Force congestion: every datagram batch refused → send-backpressure signal → bitrate floor → step down.
        var adaptation = AdaptationController.Configuration()
        adaptation.stepDownAfterNanos = 0
        adaptation.decreaseCooldownNanos = 0
        let source = SyntheticVideoSource(sourceWidth: 1280, sourceHeight: 720,
                                          config: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60))
        let transport = FakeTransport()
        transport.acceptsDatagrams = false
        var config = HostMediaPipeline.Configuration(sessionId: 5, displayPointSize: CGSize(width: 1280, height: 720))
        config.adaptation = adaptation
        let host = try HostMediaPipeline(configuration: config, source: source, transport: transport)
        try await host.start()
        let stepped = await eventuallyDetached(timeout: 15) {
            transport.controlMessages.contains { if case .config(let c) = $0 { c.width == 960 } else { false } }
        }
        #expect(stepped, "expected a CONFIG for 960×540 after sustained congestion")
        #expect(source.outputSize == (960, 540))
        #expect(await eventuallyDetached { host.encoder.currentConfig.width == 960 })
        await host.stop()
        #expect(!source.isRunning)
    }
}
