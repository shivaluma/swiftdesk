import CaptureCore
import DiagnosticsCore
import Foundation
import Testing
import TransportCore
@testable import SessionCore

/// Opt-in steady-state measurements (`SWIFTDESK_BENCH=1 swift test --filter BenchmarkTests`). Skipped by default so
/// the regular suite stays fast; the numbers are printed, not asserted, apart from basic liveness.
@MainActor
@Suite("Benchmarks", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["SWIFTDESK_BENCH"] != nil))
struct BenchmarkTests {
    private func fmt(_ s: RollingStats.Summary) -> String {
        String(format: "p50 %.2f / p95 %.2f / max %.2f ms (n=%d)", s.p50, s.p95, s.max, s.count)
    }

    @Test func quicLoopbackSessionSteadyState() async throws {
        let ids = try TestIdentities()
        let defaults = TestDefaults()
        defer { ids.cleanUp(); defaults.cleanUp() }
        var config = HostSession.Configuration()
        config.port = 0
        config.advertiseBonjour = false
        config.clipboardSharing = false
        config.cursorShapes = false
        let host = HostSession(configuration: config, dependencies: .init(
            identity: ids.host, permissions: .fixed(screen: true, accessibility: true),
            makeVideoSource: { _, c in
                SyntheticVideoSource(sourceWidth: 1280, sourceHeight: 720, config: c)
            },
            makeInputSink: { _ in RecordingInputSink() }))
        host.startListening()
        #expect(await eventually { if case .listening = host.state { true } else { false } })
        guard case .listening(let port) = host.state else { return }
        let store = TrustedHostStore(defaults: defaults.defaults)
        store.add(host: "127.0.0.1", port: port, fingerprint: ids.host.fingerprint, name: "h")
        var viewerConfig = ViewerSession.Configuration()
        viewerConfig.clipboardSharing = false
        viewerConfig.cursorShapes = false
        let viewer = ViewerSession(identity: ids.viewer, trustStore: store, configuration: viewerConfig)
        let frames = RecordingFrameSink()
        viewer.attach(frameSink: frames)
        let connectStart = Date()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { host.pendingRequest != nil })
        let approvedAt = Date()
        host.approve()
        #expect(await eventually(timeout: 10) { frames.count > 0 })
        let firstFrame = Date().timeIntervalSince(approvedAt)
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let v = viewer.metrics
        let h = host.metrics
        print("""
        [bench] QUIC loopback session, synthetic 1280x720@60, 10 s steady state
          connect→request \(String(format: "%.0f", approvedAt.timeIntervalSince(connectStart) * 1000)) ms, approve→first decoded frame \(String(format: "%.0f", firstFrame * 1000)) ms
          host: sent fps \(String(format: "%.1f", h.fps)), bitrate \(String(format: "%.0f", h.bitrateKbps)) kbps (target \(h.targetBitrateKbps)), hw=\(String(describing: h.hardwareEncoder)) ll=\(String(describing: h.lowLatencyRateControl))
          host capture→encoded: \(fmt(h.captureToEncodeDone))
          host capture→datagrams enqueued: \(fmt(h.hostPipeline))
          viewer received fps \(String(format: "%.1f", v.receivedFPS)), decoded fps \(String(format: "%.1f", v.fps)), rtt srtt \(String(format: "%.2f", v.rtt.smoothedMillis)) ms min \(String(format: "%.2f", v.rtt.minMillis)) ms
          viewer first packet→decoded: \(fmt(v.networkToDecodeDone))
          viewer framesLost \(v.framesLost), keyframeRequests \(v.keyframeRequests), loss \(String(format: "%.2f", v.packetLossPercent)) %, frames decoded total \(frames.count)
        """)
        #expect(v.receivedFPS > 30)
        viewer.disconnect()
        host.stopListening()
        await host.waitForTeardown()
    }

    @Test func syntheticLoopbackSteadyState() async throws {
        let session = LoopbackSession()
        let sink = RecordingFrameSink()
        session.attach(frameSink: sink)
        await session.start(options: .init(source: .synthetic(width: 1280, height: 720),
                                           capture: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60)))
        try await Task.sleep(nanoseconds: 10_000_000_000)
        let m = session.metrics
        print("""
        [bench] Loopback (no network), synthetic 1280x720@60, 10 s
          captured \(String(format: "%.1f", m.capturedFPS)) fps, encoded \(String(format: "%.1f", m.encodedFPS)), decoded \(String(format: "%.1f", m.decodedFPS)); encoder one-in-flight drops \(m.encoderBackpressureDrops) of \(m.framesCaptured)
          capture→encoded: \(fmt(m.captureToEncodeDone))
          encoded→decoded: \(fmt(m.encodeDoneToDecodeDone))
          bitrate \(String(format: "%.0f", m.bitrateKbps)) kbps, hwEnc=\(String(describing: m.hardwareEncoder)) hwDec=\(String(describing: m.hardwareDecoder))
        """)
        await session.stop()
        #expect(sink.count > 100)
    }
}
