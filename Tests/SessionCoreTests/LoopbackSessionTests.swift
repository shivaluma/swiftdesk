import AppKit
import CaptureCore
import CoreGraphics
import Foundation
import RenderCore
import Testing
@testable import SessionCore

@MainActor
@Suite("Loopback session", .serialized, .timeLimit(.minutes(2)))
struct LoopbackSessionTests {
    @Test func syntheticLoopbackDecodesAndReportsStageLatencies() async throws {
        let session = LoopbackSession()
        let sink = RecordingFrameSink()
        session.attach(frameSink: sink)
        await session.start(options: .init(source: .synthetic(width: 1920, height: 1080),
                                           capture: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60)))
        #expect(session.state == .running)
        #expect(await eventually(timeout: 10) { sink.count >= 30 }, "decoded \(sink.count)")
        #expect(await eventually(timeout: 5) { session.metrics.decodedFPS > 10 })
        let m = session.metrics
        #expect(m.width == 1280 && m.height == 720)
        #expect(m.captureToEncodeDone.count > 0)
        #expect(m.encodeDoneToDecodeDone.count > 0)
        #expect(m.framesEncoded > 0 && m.framesDecoded > 0)
        #expect(m.hardwareEncoder == true)
        #expect(m.framesLost == 0)
        #expect(sink.nonIncreasing == 0)
        print("[bench] loopback: capturedFPS=\(m.capturedFPS) encodedFPS=\(m.encodedFPS) decodedFPS=\(m.decodedFPS) "
              + "captureToEncode p50=\(m.captureToEncodeDone.p50)ms p95=\(m.captureToEncodeDone.p95)ms "
              + "encodeToDecode p50=\(m.encodeDoneToDecodeDone.p50)ms p95=\(m.encodeDoneToDecodeDone.p95)ms "
              + "drops=\(m.encoderBackpressureDrops) hwDec=\(String(describing: m.hardwareDecoder))")
        await session.stop()
        #expect(session.state == .idle)
        let after = sink.count
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sink.count == after, "no frames after stop()")
    }

    @Test func packetizedLoopbackSurvivesLoss() async throws {
        let session = LoopbackSession()
        let sink = RecordingFrameSink()
        session.attach(frameSink: sink)
        await session.start(options: .init(source: .synthetic(width: 1280, height: 720),
                                           capture: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60),
                                           packetize: true, simulatedLossPercent: 2, forwardErrorCorrection: false))
        #expect(session.state == .running)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        // Metrics are published periodically; under a loaded full test run the snapshot can trail the pipeline, so
        // wait for it instead of reading it once (this made the test flaky in full runs only).
        _ = await eventually { session.metrics.simulatedPacketsDropped > 0 && session.metrics.keyframeRequests > 0 }
        let m = session.metrics
        await session.stop()
        #expect(m.simulatedPacketsDropped > 0)
        #expect(sink.count >= 30, "decoded \(sink.count) frames in 3 s under 2 % loss")
        #expect(m.keyframeRequests > 0)
        #expect(m.fecGroupSize == 0 && m.fecFragmentsRecovered == 0)
        #expect(sink.nonIncreasing == 0)
    }

    @Test func packetizedLoopbackRebuildsLostFragmentsWithFEC() async throws {
        let session = LoopbackSession()
        let sink = RecordingFrameSink()
        session.attach(frameSink: sink)
        await session.start(options: .init(source: .synthetic(width: 1280, height: 720),
                                           capture: CaptureConfig(maxWidth: 1280, maxHeight: 720, fps: 60),
                                           packetize: true, simulatedLossPercent: 2))
        #expect(session.state == .running)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let m = session.metrics
        await session.stop()
        #expect(m.simulatedPacketsDropped > 0)
        #expect(m.fecFragmentsRecovered > 0, "parity must rebuild lost fragments")
        #expect(m.fecGroupSize > 0 && m.fecGroupSize <= 8, "K adapts to the measured loss (got \(m.fecGroupSize))")
        #expect(sink.count >= 90, "decoded \(sink.count) frames in 3 s under 2 % loss with FEC")
        #expect(sink.nonIncreasing == 0)
    }

    @Test func startFailureIsReported() async {
        struct Boom: Error {}
        let session = LoopbackSession(makeSource: { _, _ in throw Boom() })
        await session.start(options: .init(source: .synthetic(width: 640, height: 360)))
        guard case .failed(let message) = session.state else {
            Issue.record("expected failure, got \(session.state)")
            return
        }
        #expect(message.contains("Could not start loopback"))
        // A failed session can be started again.
        await session.start(options: .init(source: .synthetic(width: 640, height: 360)))
        #expect(session.state != .running)
    }

    @Test func metalViewCanBeAttachedWithoutAWindow() async throws {
        // No window (tests must not create one): the renderer is suspended, so frames are replaced, not presented.
        let view = MetalVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let session = LoopbackSession()
        session.attach(renderView: view)
        await session.start(options: .init(source: .synthetic(width: 640, height: 360),
                                           capture: CaptureConfig(maxWidth: 640, maxHeight: 360, fps: 30)))
        #expect(await eventually(timeout: 10) { view.contentSize == CGSize(width: 640, height: 360) })
        #expect(await eventually(timeout: 10) { view.framesReplacedBeforeDisplay > 5 })
        await session.stop()
        session.attach(renderView: nil)
    }
}

@MainActor
@Suite struct ViewerViewWiringTests {
    @Test func remoteDisplayViewIsWiredAndCaptureFlagMirrors() throws {
        let ids = try TestIdentities()
        defer { ids.cleanUp() }
        let defaults = TestDefaults()
        defer { defaults.cleanUp() }
        let viewer = ViewerSession(identity: ids.viewer, trustStore: TrustedHostStore(defaults: defaults.defaults))
        let view = RemoteDisplayView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        viewer.attach(renderView: view)
        #expect(view.onMouse != nil && view.onKey != nil && view.onScroll != nil && view.onFocusChange != nil)
        viewer.isCapturingInput = true
        #expect(view.isCapturingInput)
        viewer.isCapturingInput = false
        #expect(!view.isCapturingInput)
        // Not streaming: input is ignored and the release shortcut logic is not consulted.
        #expect(viewer.handleKey(try Events.key(.keyDown, 0)))
        viewer.attach(renderView: nil)
        #expect(view.onMouse == nil && view.onKey == nil)
        #expect(ViewerSession.releaseShortcutDescription == "⌃⌥⎋")
    }

    @Test func connectRejectsEmptyHost() throws {
        let ids = try TestIdentities()
        defer { ids.cleanUp() }
        let defaults = TestDefaults()
        defer { defaults.cleanUp() }
        let viewer = ViewerSession(identity: ids.viewer, trustStore: TrustedHostStore(defaults: defaults.defaults))
        viewer.connect(host: "   ")
        #expect(viewer.state == .disconnected(reason: "Enter a host name or IP address"))
        viewer.disconnect()
        #expect(viewer.state == .disconnected(reason: "Enter a host name or IP address"))
    }

    @Test func unreachableHostEndsWithAReadableError() async throws {
        let ids = try TestIdentities()
        defer { ids.cleanUp() }
        let defaults = TestDefaults()
        defer { defaults.cleanUp() }
        var config = ViewerSession.Configuration()
        config.establishmentTimeout = 2
        let viewer = ViewerSession(identity: ids.viewer, trustStore: TrustedHostStore(defaults: defaults.defaults),
                                   configuration: config)
        // Nothing listens on this port.
        viewer.connect(host: "127.0.0.1", port: 9)
        #expect(await eventually(timeout: 10) { if case .disconnected = viewer.state { true } else { false } })
        if case .disconnected(let reason) = viewer.state {
            #expect(reason.hasPrefix("Could not connect"), "\(reason)")
        }
    }
}

@MainActor
@Suite struct HostSessionEnvironmentTests {
    @Test func environmentIsPopulated() throws {
        let ids = try TestIdentities()
        defer { ids.cleanUp() }
        let host = HostSession(dependencies: .init(identity: ids.host, permissions: .fixed(screen: false, accessibility: true),
                                                   makeVideoSource: { _, c in SyntheticVideoSource(config: c) },
                                                   makeInputSink: { _ in RecordingInputSink() }))
        #expect(host.state == .idle)
        #expect(host.fingerprintDisplay == ids.host.fingerprintDisplay)
        #expect(host.fingerprintDisplayFull.count > host.fingerprintDisplay.count)
        #expect(!host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
        host.refreshDisplays()
        #expect(!host.displays.isEmpty)
        #expect(host.selectedDisplay?.id == host.displays.first?.id)
        #expect(!host.isSharing && host.pendingRequest == nil && host.activePeer == nil)
        // Operator actions are no-ops without a pending request / session.
        host.approve()
        host.deny()
        host.stopSharing()
        #expect(host.state == .idle)
    }
}
