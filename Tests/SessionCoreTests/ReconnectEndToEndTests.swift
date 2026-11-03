import Foundation
import Synchronization
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Dropout resilience over real QUIC on 127.0.0.1: release-on-silence on the Host, automatic reconnect on the Viewer,
/// and the Host's reconnect grace (no second prompt within the window, a prompt once it was revoked or switched off).
extension EndToEndTests {
    /// Verify (unpinned, session-only trust) → approve → streaming. Returns the viewer.
    private func approvedSession(_ h: Harness, port: UInt16) async throws -> ViewerSession {
        let viewer = h.makeViewer()
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "\(viewer.state)")
        // Not remembered: the reconnect must still pin the certificate this session verified.
        viewer.trustHost(remember: false)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        return viewer
    }

    @Test func droppedSessionReconnectsWithoutASecondPrompt() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await approvedSession(h, port: port)
        let started = try #require(h.host.activePeer?.startedAt)
        let firstSession = h.host.activePeer?.sessionId
        #expect(viewer.hostSupportsResume, "the Host announces sessionResume in ACCEPT")

        viewer.simulateConnectionLoss()
        #expect(viewer.isReconnecting, "\(viewer.state)")
        #expect(viewer.isPresentingStream, "the stream window stays up while reconnecting")
        guard case .reconnecting(let status) = viewer.state else { await h.close(); return }
        #expect(status.stream.hostName == "Test Host")
        #expect(status.hostSupportsResume)

        // No prompt on the Host: the same identity comes back within the grace window and is resumed.
        var prompted = false
        let resumed = await eventually(timeout: 20) {
            if h.host.pendingRequest != nil { prompted = true }
            return viewer.isStreaming && h.host.activePeer?.resumed == true
        }
        #expect(resumed, "viewer: \(viewer.state), host: \(h.host.state)")
        #expect(!prompted, "a reconnect within the grace window must not prompt")
        #expect(viewer.lastReconnectedAt != nil)
        #expect(h.host.activePeer?.sessionId != firstSession, "a new session id per connection")
        #expect(h.host.activePeer?.startedAt == started, "the resumed session keeps its start time")
        #expect(h.host.reconnectedNotice?.peerName == "Test Viewer")
        #expect(h.host.reconnectGrace == nil, "the grace is used up")
        // Video flows again on the new connection.
        let before = h.frames.count
        #expect(await eventually(timeout: 15) { h.frames.count > before + 10 })
        await h.close()
    }

    @Test func revokedGracePromptsAgain() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await approvedSession(h, port: port)

        // Keep the Viewer from reconnecting until the Host has seen the drop, then revoke the grace there.
        viewer.autoReconnect = false
        viewer.simulateConnectionLoss()
        #expect(await eventually { if case .disconnected = viewer.state { true } else { false } }, "\(viewer.state)")
        #expect(await eventually { h.host.reconnectGrace != nil }, "host: \(h.host.state)")
        #expect(h.host.reconnectGrace?.peerName == "Test Viewer")
        h.host.revokeReconnectGrace()
        #expect(h.host.reconnectGrace == nil)

        // A new connection from the same Viewer is an ordinary request.
        viewer.autoReconnect = true
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } })
        viewer.trustHost(remember: false)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        h.host.approve()
        #expect(await eventually { viewer.isStreaming })
        #expect(h.host.activePeer?.resumed == false)
        await h.close()
    }

    @Test func hostSettingOffMeansAPromptAndNoAnnouncement() async throws {
        let h = try Harness()
        h.host.allowsReconnectWithoutPrompt = false
        let port = try await h.startHost()
        let viewer = try await approvedSession(h, port: port)
        #expect(!viewer.hostSupportsResume)

        viewer.simulateConnectionLoss()
        #expect(viewer.isReconnecting)
        // The reconnect reaches the Host, which asks its operator again; the Viewer shows it is waiting.
        #expect(await eventually(timeout: 20) { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(await eventually {
            if case .reconnecting(let s) = viewer.state, s.phase == .awaitingApproval { true } else { false }
        }, "\(viewer.state)")
        #expect(h.host.reconnectGrace == nil)
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "\(viewer.state)")
        #expect(h.host.activePeer?.resumed == false)
        await h.close()
    }

    @Test func stopSharingIsNotReconnected() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await approvedSession(h, port: port)
        h.host.stopSharing()
        #expect(await eventually { if case .disconnected = viewer.state { true } else { false } }, "\(viewer.state)")
        #expect(h.host.reconnectGrace == nil)
        try await Task.sleep(for: .seconds(1))
        #expect(!viewer.isReconnecting)
        #expect(h.host.pendingConnectionCount == 0 && h.host.pendingRequest == nil)
        await h.close()
    }

    @Test func cancelStopsReconnecting() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await approvedSession(h, port: port)
        viewer.simulateConnectionLoss()
        #expect(viewer.isReconnecting)
        viewer.disconnect()   // the overlay's Cancel
        #expect(viewer.state == .disconnected(reason: "Disconnected"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(!viewer.isReconnecting, "no attempt after Cancel: \(viewer.state)")
        #expect(h.host.pendingRequest == nil && !h.host.isSharing)
        await h.close()
    }

    /// The Host releases held keys after 1 s without anything from the Viewer, keeps the session, and notices when
    /// the Viewer is heard again. A raw TransportCore client stands in for the Viewer so it can stay silent.
    @Test func silentViewerGetsHeldInputReleasedButKeepsTheSession() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let raw = PeerConnection.connect(host: "127.0.0.1", port: port, identity: h.ids.viewer,
                                         pinnedHostFingerprint: h.ids.host.fingerprint)
        let ready = ReadyFlag()
        raw.onStateChange = { if $0 == .ready { ready.set() } }
        raw.onControlMessage = { if case .ping(let p) = $0 { raw.sendControl(.pong(p)) } }
        raw.start()
        #expect(await eventually { ready.isSet })
        raw.sendControl(.hello(Hello(deviceName: "Raw Viewer", appVersion: "test")))
        raw.sendControl(.auth(Auth(viewerFingerprint: h.ids.viewer.fingerprint, hostFingerprint: h.ids.host.fingerprint,
                                   nonce: Data(repeating: 7, count: Auth.nonceSize))))
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.approve()
        #expect(await eventually { h.host.isSharing })
        let sink = try #require(h.sinks.last)

        // Hold Shift, then say nothing (PONGs are answers, so stop those too by dropping the handler).
        raw.onControlMessage = nil
        raw.sendControl(.keyDown(KeyEvent(seq: 1, keyCode: 56, modifiers: 0x20000)))
        #expect(await eventually { sink.messages.count == 1 })
        let releasesBefore = sink.releaseAllCount
        #expect(await eventually(timeout: 5) { h.host.isPeerSilent }, "silence not detected")
        #expect(sink.releaseAllCount == releasesBefore + 1, "held input released once")
        #expect(h.host.isSharing, "silence alone must not end the session")
        #expect(sink.authorizations == [true], "the session stays authorized")

        // Heard again: the flag clears, input flows as before.
        raw.sendControl(.ping(Ping(id: 1, sentAtNanos: 1)))
        #expect(await eventually { !h.host.isPeerSilent })
        raw.sendControl(.keyUp(KeyEvent(seq: 2, keyCode: 56, modifiers: 0)))
        #expect(await eventually { sink.messages.count == 2 })
        raw.close(reason: .userInitiated)
        #expect(await eventually { !h.host.isSharing })
        #expect(h.host.reconnectGrace == nil, "a Viewer that disconnected on purpose gets no grace")
        await h.close()
    }

}

private final class ReadyFlag: Sendable {
    private let flag = Mutex(false)
    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}
