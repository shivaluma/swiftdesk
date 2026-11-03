import Foundation
import Synchronization
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Thread-safe record of what a raw Viewer connection saw.
private final class RawViewerProbe: Sendable {
    private struct State {
        var ready = false
        var accept: Accept?
    }
    private let state = Mutex(State())

    var isReady: Bool { state.withLock { $0.ready } }
    var accept: Accept? { state.withLock { $0.accept } }

    func stateChanged(_ s: PeerConnectionState) {
        if s == .ready { state.withLock { $0.ready = true } }
    }

    func message(_ m: ControlMessage) {
        if case .accept(let a) = m { state.withLock { $0.accept = a } }
    }
}

extension EndToEndTests {
    /// PRD §4 Host step 6 / §9: when connectivity is lost (no DISCONNECT ever arrives), the Host must stop capture,
    /// reject later events and release held input. A raw TransportCore client stands in for the Viewer so the
    /// connection can vanish while a modifier key is held, exactly as a crashed or unplugged Viewer would.
    @Test func connectionLossWithoutDisconnectStopsCaptureAndReleasesInput() async throws {
        let h = try Harness()
        let port = try await h.startHost()

        let probe = RawViewerProbe()
        let viewer = PeerConnection.connect(host: "127.0.0.1", port: port, identity: h.ids.viewer,
                                            pinnedHostFingerprint: h.ids.host.fingerprint)
        viewer.onStateChange = { probe.stateChanged($0) }
        viewer.onControlMessage = { probe.message($0) }
        viewer.start()
        #expect(await eventually { probe.isReady }, "raw viewer never became ready")

        viewer.sendControl(.hello(Hello(deviceName: "Raw Viewer", appVersion: "test")))
        viewer.sendControl(.auth(Auth(viewerFingerprint: h.ids.viewer.fingerprint,
                                      hostFingerprint: h.ids.host.fingerprint,
                                      nonce: Data(repeating: 7, count: Auth.nonceSize))))
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        h.host.approve()
        #expect(await eventually { probe.accept != nil }, "no ACCEPT")
        #expect(h.host.isSharing)

        let sink = try #require(h.sinks.last)
        let source = try #require(h.sources.last)
        #expect(await eventually { source.isRunning })

        // Hold Shift on the Host, then lose the connection without DISCONNECT.
        viewer.sendControl(.keyDown(KeyEvent(seq: 1, keyCode: 56, modifiers: 0x20000)))
        #expect(await eventually { sink.messages.count == 1 }, "host received \(sink.messages)")
        viewer.close(reason: nil)

        #expect(await eventually(timeout: 15) { if case .listening = h.host.state { true } else { false } },
                "host: \(h.host.state)")
        #expect(h.host.lastEndReason == "Connection to the Viewer was lost")
        #expect(!h.host.isSharing && h.host.activePeer == nil)
        // Deauthorizing the injector is what releases held keys/buttons (HostInputInjector.setAuthorized(false)).
        #expect(sink.authorizations == [true, false])
        await h.host.waitForTeardown()
        #expect(!source.isRunning, "capture must stop when the connection is lost")
        await h.close()
    }
}
