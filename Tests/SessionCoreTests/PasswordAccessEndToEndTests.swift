import Foundation
import Synchronization
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// What a raw (hand-driven) Viewer connection received.
private final class RawPasswordProbe: Sendable {
    private struct State {
        var ready = false
        var messages: [ControlMessage] = []
    }
    private let state = Mutex(State())

    var isReady: Bool { state.withLock { $0.ready } }
    var messages: [ControlMessage] { state.withLock { $0.messages } }
    var challenge: PasswordChallenge? {
        for case .passwordChallenge(let c) in messages { return c }
        return nil
    }
    /// The Host sent PASSWORD_RESPONSE(none): it fell back to its prompt without using the password.
    var gotFallback: Bool {
        messages.contains { if case .passwordResponse(let r) = $0 { r.kind == .none } else { false } }
    }
    var gotDeny: Bool {
        messages.contains { if case .deny = $0 { true } else { false } }
    }

    func stateChanged(_ s: PeerConnectionState) {
        if s == .ready { state.withLock { $0.ready = true } }
    }

    func message(_ m: ControlMessage) {
        state.withLock { $0.messages.append(m) }
    }
}

/// Opt-in password access over real QUIC on 127.0.0.1 (requested by the product owner; PRD §3 non-goal lifted).
extension EndToEndTests {
    private static let password = "open sesame 42"
    /// Production rounds: the Viewer refuses anything below `AccessPassword.defaultIterations` (security-3).
    private static let testRounds: UInt32 = AccessPassword.defaultIterations

    private func passwordHarness(enabled: Bool = true,
                                 configure: (inout HostSession.Configuration) -> Void = { _ in }) throws
        -> (EndToEndTests.Harness, HostAccessPassword) {
        let access = HostAccessPassword(store: InMemorySecretStore(), iterations: Self.testRounds)
        if enabled { try access.set(password: Self.password) }
        let h = try Harness(accessPassword: access, hostConfiguration: configure)
        return (h, access)
    }

    private func reason(_ v: ViewerSession) -> String? {
        if case .disconnected(let reason) = v.state { reason } else { nil }
    }

    /// Correct password: streaming with no approve() call, the Host marks the session "via password"; with
    /// "Remember" the password is saved for the pinned Host and the next connection needs no typing.
    @Test func correctPasswordStreamsWithoutApproval() async throws {
        let (h, _) = try passwordHarness()
        let port = try await h.startHost()
        #expect(h.host.passwordAccessEnabled)
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let saved = SavedHostPasswords(store: InMemorySecretStore())
        let viewer = h.makeViewer(savedPasswords: saved)
        viewer.attach(frameSink: h.frames)

        viewer.connect(host: "127.0.0.1", port: port, password: Self.password, rememberPassword: true)
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.pendingRequest == nil)
        let peer = try #require(h.host.activePeer)
        #expect(peer.viaPassword)
        #expect(peer.name == "Test Viewer")
        if case .streaming(let info) = viewer.state { #expect(info.viaPassword) }
        #expect(await eventually(timeout: 15) { h.frames.count >= 5 }, "decoded \(h.frames.count) frames")
        #expect(h.sinks.last?.authorizations == [true])
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == Self.password)
        #expect(viewer.savedPasswordFingerprints.contains(TrustedHostStore.hex(h.ids.host.fingerprint)))

        // Stop Sharing works exactly as for an approved session.
        h.host.stopSharing()
        #expect(await eventually { self.reason(viewer) != nil }, "viewer: \(viewer.state)")

        // Saved password: connect without typing.
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == true)
        #expect(h.host.passwordFailureCount == 0)

        // Forgetting the saved password brings back the prompt.
        viewer.disconnect()
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        let trusted = try #require(viewer.trustedHosts.first)
        viewer.forgetSavedPassword(for: trusted)
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == nil)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        await h.close()
    }

    /// 0.1.4: a password session that drops comes back without a prompt within the grace window and stays marked
    /// "via password"; once password access is switched off, the grace is gone and the reconnect is prompted (the
    /// typed password from the original connection is kept in memory for the reconnect, never saved).
    @Test func droppedPasswordSessionResumesAndRespectsTheSwitch() async throws {
        let (h, _) = try passwordHarness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let saved = SavedHostPasswords(store: InMemorySecretStore())
        let viewer = h.makeViewer(savedPasswords: saved)
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == true)

        viewer.simulateConnectionLoss()
        #expect(await eventually(timeout: 20) { viewer.isStreaming && h.host.activePeer?.resumed == true },
                "viewer: \(viewer.state), host: \(h.host.state)")
        #expect(h.host.activePeer?.viaPassword == true, "still a session nobody approved")
        #expect(h.host.pendingRequest == nil)
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == nil, "never saved without Remember")

        // Switch password access off while the Viewer is away: its grace goes with it.
        viewer.autoReconnect = false
        viewer.simulateConnectionLoss()
        #expect(await eventually { h.host.reconnectGrace?.viaPassword == true }, "host: \(h.host.state)")
        try h.host.setPasswordAccessEnabled(false)
        #expect(h.host.reconnectGrace == nil)
        viewer.autoReconnect = true
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        await h.close()
    }

    /// 0.2.0: the operator's "Require Approval" on a dropped password session means the Viewer's next connection asks
    /// the operator, even though the Viewer still holds the password (its automatic reconnect replays it). One-shot:
    /// the connection after that uses the password again.
    @Test func requireApprovalOnAPasswordGracePromptsTheNextPasswordLogin() async throws {
        let (h, _) = try passwordHarness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")

        viewer.autoReconnect = false
        viewer.simulateConnectionLoss()
        #expect(await eventually { h.host.reconnectGrace?.viaPassword == true }, "host: \(h.host.state)")
        h.host.revokeReconnectGrace()
        #expect(h.host.reconnectGrace == nil)

        viewer.autoReconnect = true
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(!viewer.isStreaming)
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == false, "the operator allowed it")
        #expect(h.host.passwordFailureCount == 0)

        viewer.disconnect()
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == true)
        await h.close()
    }

    /// "Remember" is honoured only for a pinned Host: an unpinned (trust-once) Host never gets a saved password.
    @Test func passwordIsNotSavedForAnUnpinnedHost() async throws {
        let (h, _) = try passwordHarness()
        let port = try await h.startHost()
        let saved = SavedHostPasswords(store: InMemorySecretStore())
        let viewer = h.makeViewer(savedPasswords: saved)
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password, rememberPassword: true)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } })
        #expect(h.host.activePeer == nil, "no password is used before the Host is verified")
        viewer.trustHost(remember: false)
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == true)
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == nil)
        await h.close()
    }

    /// Wrong password: DENY(authFailed) → "Incorrect password", no prompt; a saved password that failed is deleted.
    @Test func wrongPasswordIsAuthFailed() async throws {
        let (h, _) = try passwordHarness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let saved = SavedHostPasswords(store: InMemorySecretStore())
        try saved.save("stale password", forFingerprint: h.ids.host.fingerprint)
        let viewer = h.makeViewer(savedPasswords: saved)

        viewer.connect(host: "127.0.0.1", port: port, password: "not the password")
        #expect(await eventually { self.reason(viewer) != nil }, "viewer: \(viewer.state)")
        #expect(reason(viewer) == ViewerHandshake.incorrectPasswordMessage)
        #expect(h.host.pendingRequest == nil && h.host.activePeer == nil)
        #expect(h.host.passwordFailureCount == 1)
        #expect(h.host.lastPasswordFailure?.contains("127.0.0.1") == true)
        #expect(h.sinks.count == 0, "nothing was ever authorized")
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == "stale password",
                "a typed password failing leaves the saved one alone")

        // Now the saved (stale) password is used and fails: it is deleted.
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { self.reason(viewer) != nil }, "viewer: \(viewer.state)")
        #expect(reason(viewer) == ViewerHandshake.incorrectPasswordMessage)
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == nil)
        #expect(h.host.passwordFailureCount == 2)
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        await h.close()
    }

    /// No password on the Viewer: it answers "none" and the Host shows the normal prompt at once.
    @Test func noPasswordFallsBackToThePrompt() async throws {
        let (h, _) = try passwordHarness { $0.passwordTimeout = .seconds(30) }
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        // Well under the (30 s) password timeout: the explicit "none" triggered the prompt.
        #expect(await eventually(timeout: 5) { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(viewer.state == .awaitingApproval)
        #expect(!viewer.isUsingPassword)
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == false)
        await h.close()
    }

    /// Password access off (the default): behaviour is exactly as before — prompt, no challenge.
    @Test func disabledPasswordAccessPromptsAsBefore() async throws {
        let (h, access) = try passwordHarness()
        try h.host.setPasswordAccessEnabled(false)
        #expect(!access.isEnabled && !h.host.passwordAccessEnabled && h.host.passwordAccessConfigured)
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(!viewer.isUsingPassword, "no challenge was sent")
        await h.close()
    }

    /// A Viewer that announces password support but never answers (a stalled or misbehaving client): after the
    /// password timeout the Host falls back to the prompt. A Viewer without the capability marker (SwiftDesk ≤
    /// 0.1.1) is never challenged — it would drop the connection on the unknown message type — and is prompted at once.
    @Test func silentAndLegacyViewersGetThePrompt() async throws {
        let (h, _) = try passwordHarness { $0.passwordTimeout = .seconds(1) }
        let port = try await h.startHost()

        func rawViewer(capable: Bool) async throws -> (PeerConnection, RawPasswordProbe) {
            let probe = RawPasswordProbe()
            let connection = PeerConnection.connect(host: "127.0.0.1", port: port, identity: h.ids.viewer,
                                                    pinnedHostFingerprint: h.ids.host.fingerprint)
            connection.onStateChange = { probe.stateChanged($0) }
            connection.onControlMessage = { probe.message($0) }
            connection.start()
            #expect(await eventually { probe.isReady }, "raw viewer never became ready")
            let random = Data(repeating: 7, count: Auth.nonceSize)
            connection.sendControl(.hello(Hello(deviceName: "Raw Viewer", appVersion: "test")))
            connection.sendControl(.auth(Auth(viewerFingerprint: h.ids.viewer.fingerprint,
                                              hostFingerprint: h.ids.host.fingerprint,
                                              nonce: capable ? Auth.nonce(capabilities: .passwordAuth, random: random) : random)))
            return (connection, probe)
        }

        // Capable but silent.
        let start = ContinuousClock.now
        let (silent, silentProbe) = try await rawViewer(capable: true)
        #expect(await eventually { silentProbe.challenge != nil }, "no challenge: \(silentProbe.messages)")
        let challenge = try #require(silentProbe.challenge)
        #expect(challenge.iterations == Self.testRounds && challenge.nonce.count == 32)
        #expect(h.host.pendingRequest == nil, "no prompt while the password is checked")
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(ContinuousClock.now - start >= .milliseconds(900), "fell back before the password timeout")
        #expect(await eventually { silentProbe.gotFallback }, "the Viewer is told: \(silentProbe.messages)")
        h.host.deny()
        silent.close(reason: nil)
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })

        // Legacy: prompted immediately, never challenged.
        let legacyIdentity = try h.ids.extra("Legacy")
        let probe = RawPasswordProbe()
        let legacy = PeerConnection.connect(host: "127.0.0.1", port: port, identity: legacyIdentity,
                                            pinnedHostFingerprint: h.ids.host.fingerprint)
        legacy.onStateChange = { probe.stateChanged($0) }
        legacy.onControlMessage = { probe.message($0) }
        legacy.start()
        #expect(await eventually { probe.isReady })
        legacy.sendControl(.hello(Hello(deviceName: "Old Viewer", appVersion: "0.1.1")))
        legacy.sendControl(.auth(Auth(viewerFingerprint: legacyIdentity.fingerprint, hostFingerprint: h.ids.host.fingerprint,
                                      nonce: Data(repeating: 3, count: Auth.nonceSize))))
        #expect(await eventually(timeout: 0.9) { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(h.host.pendingRequest?.peerName == "Old Viewer")
        #expect(probe.challenge == nil)
        h.host.approve()
        #expect(await eventually { probe.messages.contains { if case .accept = $0 { true } else { false } } })
        #expect(h.host.activePeer?.viaPassword == false)
        legacy.close(reason: .userInitiated)
        await h.close()
    }

    /// 5 wrong passwords lock the Viewer out of password attempts: even the right password is not checked, but the
    /// Viewer can still ask the operator, who sees the prompt (review finding ux-3).
    @Test func fiveFailuresLockTheViewerOut() async throws {
        let (h, _) = try passwordHarness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        for attempt in 1...5 {
            viewer.connect(host: "127.0.0.1", port: port, password: "guess number \(attempt)")
            #expect(await eventually { self.reason(viewer) != nil }, "attempt \(attempt): \(viewer.state)")
            #expect(reason(viewer) == ViewerHandshake.incorrectPasswordMessage, "attempt \(attempt)")
            #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        }
        #expect(h.host.passwordFailureCount == 5)

        viewer.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(viewer.state == .awaitingApproval)
        #expect(!viewer.isUsingPassword, "a locked-out Viewer is not challenged")
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        #expect(h.host.activePeer?.viaPassword == false)
        viewer.disconnect()
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })

        // The lockout is per identity and per address: here both match, so a new identity is not challenged
        // either, and it too reaches the prompt.
        let other = h.makeViewer(identity: try h.ids.extra("Other"))
        other.connect(host: "127.0.0.1", port: port, password: Self.password)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(!other.isUsingPassword)
        h.host.deny()
        #expect(await eventually { self.reason(other) != nil }, "other: \(other.state)")
        #expect(h.host.passwordFailureCount == 5, "nothing more was counted")
        await h.close()
    }

    /// A proof that arrives after the Host's password timer fell back to the prompt is not a password login: the
    /// Viewer is told, shows "waiting for approval", saves nothing and the session is not "via password" on either
    /// side when the operator then clicks Allow (review finding protocol-1).
    @Test func lateProofAfterTheFallbackIsNotAPasswordLogin() async throws {
        // PBKDF2 at production rounds takes far longer than this timeout, so the proof is always late.
        let (h, _) = try passwordHarness { $0.passwordTimeout = .milliseconds(20) }
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let saved = SavedHostPasswords(store: InMemorySecretStore())
        let viewer = h.makeViewer(savedPasswords: saved)
        viewer.connect(host: "127.0.0.1", port: port, password: Self.password, rememberPassword: true)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        // Leave time for a derivation already under way to finish (it must have been cancelled or ignored).
        try await Task.sleep(for: .milliseconds(600))
        #expect(viewer.state == .awaitingApproval)
        #expect(!viewer.isUsingPassword, "the UI must say 'waiting for approval', not 'signing in with password'")
        #expect(h.host.pendingRequest != nil, "the late proof changed nothing on the Host")
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        if case .streaming(let info) = viewer.state { #expect(!info.viaPassword) }
        #expect(h.host.activePeer?.viaPassword == false)
        #expect(saved.password(forFingerprint: h.ids.host.fingerprint) == nil, "an unverified password is never saved")
        #expect(viewer.savedPasswordFingerprints.isEmpty)
        #expect(h.host.passwordFailureCount == 0)
        await h.close()
    }

    /// Password access switched off while the Viewer answers: the correct proof falls back to the prompt; nothing is
    /// counted as a wrong password and no DENY(authFailed) is sent (review finding protocol-2).
    @Test func switchingPasswordAccessOffMidChallengePrompts() async throws {
        let (h, _) = try passwordHarness { $0.passwordTimeout = .seconds(30) }
        let port = try await h.startHost()
        let probe = RawPasswordProbe()
        let connection = PeerConnection.connect(host: "127.0.0.1", port: port, identity: h.ids.viewer,
                                                pinnedHostFingerprint: h.ids.host.fingerprint)
        connection.onStateChange = { probe.stateChanged($0) }
        connection.onControlMessage = { probe.message($0) }
        connection.start()
        #expect(await eventually { probe.isReady }, "raw viewer never became ready")
        connection.sendControl(.hello(Hello(deviceName: "Raw Viewer", appVersion: "test")))
        connection.sendControl(.auth(Auth(viewerFingerprint: h.ids.viewer.fingerprint,
                                          hostFingerprint: h.ids.host.fingerprint,
                                          nonce: Auth.nonce(capabilities: .passwordAuth,
                                                            random: Data(repeating: 7, count: Auth.nonceSize)))))
        #expect(await eventually { probe.challenge != nil }, "no challenge: \(probe.messages)")
        let challenge = try #require(probe.challenge)

        try h.host.setPasswordAccessEnabled(false)
        let proof = try #require(try AccessPassword.answer(challenge, password: Self.password,
                                                           hostFingerprint: h.ids.host.fingerprint,
                                                           viewerFingerprint: h.ids.viewer.fingerprint))
        connection.sendControl(.passwordResponse(.proof(proof)))

        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        #expect(await eventually { probe.gotFallback }, "the Viewer is told: \(probe.messages)")
        #expect(!probe.gotDeny)
        #expect(h.host.passwordFailureCount == 0 && h.host.lastPasswordFailure == nil)
        #expect(h.host.activePeer == nil)
        h.host.deny()
        connection.close(reason: nil)
        await h.close()
    }
}
