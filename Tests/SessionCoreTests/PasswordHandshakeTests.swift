import Foundation
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Every password-access path through the pure handshake reducers.
@Suite("Host handshake: password access")
struct HostPasswordHandshakeTests {
    private let hostFP = Data(repeating: 0xAA, count: 32)
    private let viewerFP = Data(repeating: 0xBB, count: 32)
    private let hello = Hello(deviceName: "Viewer Mac", appVersion: "0.1.2")
    private let challenge = PasswordChallenge(salt: Data(repeating: 1, count: 16), iterations: 1_000_000,
                                              nonce: Data(repeating: 2, count: 32))
    private let goodProof = Data(repeating: 0x60, count: 32)
    private let staleProof = Data(repeating: 0x5E, count: 32)

    private func auth(capable: Bool) -> ControlMessage {
        let nonce = capable ? Auth.nonce(capabilities: .passwordAuth, random: Data(repeating: 9, count: 16))
                            : Data(repeating: 9, count: 16)
        return .auth(Auth(viewerFingerprint: viewerFP, hostFingerprint: hostFP, nonce: nonce))
    }

    private func verifier(_ proof: Data, _ c: PasswordChallenge) -> HostAccessPassword.ProofResult {
        guard c == challenge else { return .stale }
        if proof == staleProof { return .stale }
        return proof == goodProof ? .valid : .invalid
    }

    /// HELLO + AUTH with the given gate.
    private func authed(capable: Bool = true, gate: HostHandshake.PasswordGate, screen: Bool = true)
        -> (HostHandshake, HostHandshake.Effect?) {
        var h = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = h.receive(.hello(hello), screenRecordingGranted: screen, password: gate)
        let effect = h.receive(auth(capable: capable), screenRecordingGranted: screen, password: gate)
        return (h, effect)
    }

    @Test func capableViewerIsChallengedWithoutAPrompt() {
        let (h, effect) = authed(gate: .available(challenge))
        #expect(effect == .sendChallenge(challenge))
        #expect(h.phase == .awaitingPassword(hello, challenge))
        #expect(h.isAwaitingPassword && !h.isAwaitingApproval)
        #expect(h.hello == hello)
    }

    @Test func validProofAcceptsImmediately() {
        var (h, _) = authed(gate: .available(challenge))
        let effect = h.receive(.passwordResponse(.proof(goodProof)), screenRecordingGranted: true,
                               verifyProof: verifier)
        #expect(effect == .passwordAccepted(hello))
        #expect(h.phase == .accepted(hello))
        // A late operator decision or timeout changes nothing.
        #expect(h.decide(approved: false) == nil)
        #expect(h.passwordTimedOut() == nil)
        #expect(h.approvalTimedOut() == nil)
    }

    @Test func wrongProofIsAuthFailed() {
        var (h, _) = authed(gate: .available(challenge))
        let effect = h.receive(.passwordResponse(.proof(Data(repeating: 0x61, count: 32))), screenRecordingGranted: true,
                               verifyProof: verifier)
        #expect(effect == .deny(.authFailed, "Incorrect password"))
        #expect(h.phase == .finished)
    }

    @Test func noPasswordFallsBackToThePrompt() {
        var (h, _) = authed(gate: .available(challenge))
        var verifierCalled = false
        let effect = h.receive(.passwordResponse(.none), screenRecordingGranted: true) { _, _ in
            verifierCalled = true
            return .valid
        }
        #expect(effect == .requestApproval(hello))
        #expect(!verifierCalled, "a 'none' answer is never verified")
        #expect(h.isAwaitingApproval)
        #expect(h.decide(approved: true) == .accept(hello))
    }

    @Test func silentViewerTimesOutToThePrompt() {
        var (h, _) = authed(gate: .available(challenge))
        // The Viewer is told (PASSWORD_RESPONSE none), so a late proof is never taken for a login (protocol-1).
        #expect(h.passwordTimedOut() == .fallbackToPrompt(hello))
        #expect(h.isAwaitingApproval)
        #expect(h.passwordTimedOut() == nil, "only once")
        // A late answer after the fallback is ignored: the operator decides, the spent challenge is not checked.
        var verifierCalled = false
        #expect(h.receive(.passwordResponse(.proof(goodProof)), screenRecordingGranted: true) { _, _ in
            verifierCalled = true
            return .valid
        } == nil)
        #expect(!verifierCalled)
        #expect(h.isAwaitingApproval)
    }

    /// Password access switched off or changed while the Viewer answered: prompt, not "Incorrect password"
    /// (review finding protocol-2).
    @Test func staleChallengeFallsBackToThePrompt() {
        var (h, _) = authed(gate: .available(challenge))
        let effect = h.receive(.passwordResponse(.proof(staleProof)), screenRecordingGranted: true, verifyProof: verifier)
        #expect(effect == .fallbackToPrompt(hello))
        #expect(h.isAwaitingApproval)
        #expect(h.passwordTimedOut() == nil, "the password timer has nothing left to do")
        #expect(h.decide(approved: true) == .accept(hello))
    }

    @Test func challengeIsSingleUse() {
        var (h, _) = authed(gate: .available(challenge))
        _ = h.receive(.passwordResponse(.proof(Data(repeating: 0x61, count: 32))), screenRecordingGranted: true,
                      verifyProof: verifier)
        #expect(h.phase == .finished)
        #expect(h.receive(.passwordResponse(.proof(goodProof)), screenRecordingGranted: true, verifyProof: verifier) == nil)
    }

    @Test func legacyViewerIsPromptedStraightAway() {
        let (h, effect) = authed(capable: false, gate: .available(challenge))
        #expect(effect == .requestApproval(hello))
        #expect(h.isAwaitingApproval)
    }

    @Test func disabledGateKeepsTodaysBehaviour() {
        let (h, effect) = authed(gate: .disabled)
        #expect(effect == .requestApproval(hello))
        #expect(h.isAwaitingApproval)
    }

    /// Locked out of password attempts, but still allowed to ask the operator (review finding ux-3).
    @Test(arguments: [true, false])
    func lockedOutIsPromptedWithoutAChallenge(_ capable: Bool) {
        var (h, effect) = authed(capable: capable, gate: .lockedOut)
        #expect(effect == .requestApproval(hello))
        #expect(h.isAwaitingApproval)
        #expect(h.decide(approved: true) == .accept(hello))
    }

    @Test func identityAndPermissionChecksStillComeFirst() {
        var h = HostHandshake(hostFingerprint: hostFP, peerFingerprint: Data(repeating: 0xCC, count: 32))
        _ = h.receive(.hello(hello), screenRecordingGranted: true, password: .available(challenge))
        guard case .deny(.identityMismatch, _)? = h.receive(auth(capable: true), screenRecordingGranted: true,
                                                            password: .available(challenge)) else {
            Issue.record("expected identityMismatch")
            return
        }
        let (_, noScreen) = authed(gate: .available(challenge), screen: false)
        guard case .deny(.permissionsMissing, _)? = noScreen else {
            Issue.record("expected permissionsMissing")
            return
        }
    }

    @Test func passwordResponseOutOfPlaceIsAProtocolError() {
        var early = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        #expect(early.receive(.passwordResponse(.none), screenRecordingGranted: true) == .close(.protocolError))
        var afterHello = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = afterHello.receive(.hello(hello), screenRecordingGranted: true)
        #expect(afterHello.receive(.passwordResponse(.none), screenRecordingGranted: true) == .close(.protocolError))
        var accepted = authed(gate: .disabled).0
        _ = accepted.decide(approved: true)
        #expect(accepted.receive(.passwordResponse(.none), screenRecordingGranted: true) == .close(.protocolError))
        // HELLO/AUTH again while the password is checked.
        var repeated = authed(gate: .available(challenge)).0
        #expect(repeated.receive(.hello(hello), screenRecordingGranted: true) == .close(.protocolError))
        var repeatedAuth = authed(gate: .available(challenge)).0
        #expect(repeatedAuth.receive(auth(capable: true), screenRecordingGranted: true) == .close(.protocolError))
    }

    @Test func operatorCannotDecideWhileThePasswordIsChecked() {
        var (h, _) = authed(gate: .available(challenge))
        #expect(h.decide(approved: true) == nil)
        #expect(h.approvalTimedOut() == nil)
        #expect(h.handshakeTimedOut() == nil)
        #expect(h.isAwaitingPassword)
    }
}

@Suite("Viewer handshake: password access")
struct ViewerPasswordHandshakeTests {
    private let hostFP = Data(repeating: 0xAA, count: 32)
    private let challenge = PasswordChallenge(salt: Data(repeating: 1, count: 16), iterations: 1_000_000,
                                              nonce: Data(repeating: 2, count: 32))

    private func awaiting(pinned: Bool = true) -> ViewerHandshake {
        var v = ViewerHandshake(pinnedFingerprint: pinned ? hostFP : nil)
        _ = v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: false)
        if !pinned { _ = v.userTrusted() }
        return v
    }

    @Test(arguments: [true, false])
    func challengeAfterVerificationIsAnswered(_ pinned: Bool) {
        var v = awaiting(pinned: pinned)
        #expect(v.receive(.passwordChallenge(challenge)) == .answerChallenge(challenge, hostFingerprint: hostFP))
        #expect(v.challengeAnswered)
        // Then the Host accepts as usual.
        let accept = Accept(sessionId: 3, sessionToken: Data(count: 16), hostName: "Host")
        #expect(v.receive(.accept(accept)) == .startStreaming(accept))
    }

    @Test func challengeBeforeVerificationEndsWithoutAProof() {
        var v = ViewerHandshake(pinnedFingerprint: nil)
        _ = v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: false)
        guard case .end(_, .protocolError)? = v.receive(.passwordChallenge(challenge)) else {
            Issue.record("a challenge before the user trusted the Host must end the attempt")
            return
        }
        var connecting = ViewerHandshake(pinnedFingerprint: hostFP)
        guard case .end(_, .protocolError)? = connecting.receive(.passwordChallenge(challenge)) else {
            Issue.record("a challenge before transport ready must end the attempt")
            return
        }
    }

    @Test func secondChallengeIsAProtocolError() {
        var v = awaiting()
        _ = v.receive(.passwordChallenge(challenge))
        guard case .end(_, .protocolError)? = v.receive(.passwordChallenge(challenge)) else {
            Issue.record("expected protocol error")
            return
        }
    }

    @Test func challengeWhileStreamingIsAProtocolError() {
        var v = awaiting()
        _ = v.receive(.accept(Accept(sessionId: 3, sessionToken: Data(count: 16), hostName: "Host")))
        guard case .end(_, .protocolError)? = v.receive(.passwordChallenge(challenge)) else {
            Issue.record("expected protocol error")
            return
        }
    }

    /// PASSWORD_RESPONSE(none) Host → Viewer after a challenge: the Host prompts instead (review finding protocol-1).
    @Test func hostFallbackAfterTheChallengeIsReported() {
        var v = awaiting()
        _ = v.receive(.passwordChallenge(challenge))
        #expect(v.receive(.passwordResponse(.none)) == .passwordFallback)
        #expect(v.phase == .awaitingApproval(hostFingerprint: hostFP), "still waiting for the operator")
        let accept = Accept(sessionId: 3, sessionToken: Data(count: 16), hostName: "Host")
        #expect(v.receive(.accept(accept)) == .startStreaming(accept))
    }

    @Test func hostFallbackWithoutAChallengeIsIgnored() {
        var v = awaiting()
        #expect(v.receive(.passwordResponse(.none)) == nil)
        _ = v.receive(.passwordChallenge(challenge))
        #expect(v.receive(.passwordResponse(.proof(Data(repeating: 1, count: 32)))) == nil, "only 'none' means fallback")
        #expect(v.phase == .awaitingApproval(hostFingerprint: hostFP))
    }

    @Test(arguments: [UInt32(0), 99_999, 100_000, 999_999, 5_000_001, .max])
    func outOfRangeRoundsAreDeclined(_ rounds: UInt32) {
        var v = awaiting()
        let hostile = PasswordChallenge(salt: challenge.salt, iterations: rounds, nonce: challenge.nonce)
        #expect(v.receive(.passwordChallenge(hostile)) == .declineChallenge)
        // Still waiting for the operator.
        #expect(v.phase == .awaitingApproval(hostFingerprint: hostFP))
    }

    @Test func authFailedReadsIncorrectPassword() {
        var v = awaiting()
        _ = v.receive(.passwordChallenge(challenge))
        #expect(v.receive(.deny(Deny(reason: .authFailed, message: "Incorrect password")))
                == .end(message: "Incorrect password", closeReason: nil))
        #expect(ViewerHandshake.message(for: Deny(reason: .authFailed)) == ViewerHandshake.incorrectPasswordMessage)
    }
}
