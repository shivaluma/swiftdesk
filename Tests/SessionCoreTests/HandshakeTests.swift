import Foundation
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

@Suite struct HostHandshakeTests {
    private let hostFP = Data(repeating: 0xAA, count: 32)
    private let viewerFP = Data(repeating: 0xBB, count: 32)
    private let nonce = Data(repeating: 0x01, count: 16)
    private let hello = Hello(deviceName: "Viewer Mac", appVersion: "1.0")

    private func make(peer: Data? = nil) -> HostHandshake {
        HostHandshake(hostFingerprint: hostFP, peerFingerprint: peer ?? viewerFP)
    }

    private var goodAuth: ControlMessage {
        .auth(Auth(viewerFingerprint: viewerFP, hostFingerprint: hostFP, nonce: nonce))
    }

    @Test func happyPathRequestsApprovalThenAccepts() {
        var h = make()
        #expect(h.receive(.hello(hello), screenRecordingGranted: true) == nil)
        #expect(h.phase == .awaitingAuth(hello))
        #expect(h.receive(goodAuth, screenRecordingGranted: true) == .requestApproval(hello))
        #expect(h.isAwaitingApproval)
        #expect(h.hello == hello)
        #expect(h.decide(approved: true) == .accept(hello))
        #expect(h.phase == .accepted(hello))
        // A late second decision does nothing.
        #expect(h.decide(approved: false) == nil)
    }

    @Test func versionMismatchIsDenied() {
        var h = make()
        let old = Hello(protocolVersion: 99, deviceName: "x", appVersion: "y")
        guard case .deny(.versionMismatch, _)? = h.receive(.hello(old), screenRecordingGranted: true) else {
            Issue.record("expected versionMismatch")
            return
        }
        #expect(h.phase == .finished)
    }

    @Test(arguments: [
        ("viewer fingerprint differs from TLS", Data(repeating: 0xCC, count: 32), Data(repeating: 0xAA, count: 32)),
        ("viewer saw another host certificate", Data(repeating: 0xBB, count: 32), Data(repeating: 0xDD, count: 32)),
    ])
    func channelBindingMismatchIsDenied(_ label: String, _ claimedViewer: Data, _ observedHost: Data) {
        var h = make()
        _ = h.receive(.hello(hello), screenRecordingGranted: true)
        let auth = ControlMessage.auth(Auth(viewerFingerprint: claimedViewer, hostFingerprint: observedHost, nonce: nonce))
        guard case .deny(.identityMismatch, _)? = h.receive(auth, screenRecordingGranted: true) else {
            Issue.record("expected identityMismatch: \(label)")
            return
        }
    }

    @Test func unknownTLSPeerFingerprintIsDenied() {
        var h = HostHandshake(hostFingerprint: hostFP, peerFingerprint: nil)
        _ = h.receive(.hello(hello), screenRecordingGranted: true)
        guard case .deny(.identityMismatch, _)? = h.receive(goodAuth, screenRecordingGranted: true) else {
            Issue.record("expected identityMismatch")
            return
        }
    }

    @Test func missingScreenRecordingIsDeniedAfterIdentityCheck() {
        var h = make()
        _ = h.receive(.hello(hello), screenRecordingGranted: false)
        guard case .deny(.permissionsMissing, _)? = h.receive(goodAuth, screenRecordingGranted: false) else {
            Issue.record("expected permissionsMissing")
            return
        }
    }

    @Test func outOfOrderMessagesAreProtocolErrors() {
        var a = make()
        #expect(a.receive(goodAuth, screenRecordingGranted: true) == .close(.protocolError))
        var b = make()
        _ = b.receive(.hello(hello), screenRecordingGranted: true)
        #expect(b.receive(.hello(hello), screenRecordingGranted: true) == .close(.protocolError))
        var c = make()
        _ = c.receive(.hello(hello), screenRecordingGranted: true)
        _ = c.receive(goodAuth, screenRecordingGranted: true)
        #expect(c.receive(goodAuth, screenRecordingGranted: true) == .close(.protocolError))
    }

    @Test func nonHandshakeMessagesAreIgnored() {
        var h = make()
        #expect(h.receive(.ping(Ping(id: 1, sentAtNanos: 1)), screenRecordingGranted: true) == nil)
        #expect(h.receive(.keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: 0)), screenRecordingGranted: true) == nil)
        #expect(h.phase == .awaitingHello)
    }

    @Test func handshakeTimeoutOnlyBeforeApproval() {
        var a = make()
        guard case .deny(.timeout, _)? = a.handshakeTimedOut() else { Issue.record("expected timeout"); return }
        var b = make()
        _ = b.receive(.hello(hello), screenRecordingGranted: true)
        guard case .deny(.timeout, _)? = b.handshakeTimedOut() else { Issue.record("expected timeout"); return }
        var c = make()
        _ = c.receive(.hello(hello), screenRecordingGranted: true)
        _ = c.receive(goodAuth, screenRecordingGranted: true)
        #expect(c.handshakeTimedOut() == nil)
    }

    @Test func approvalTimeoutAndDeny() {
        var a = make()
        #expect(a.approvalTimedOut() == nil)
        _ = a.receive(.hello(hello), screenRecordingGranted: true)
        _ = a.receive(goodAuth, screenRecordingGranted: true)
        guard case .deny(.timeout, _)? = a.approvalTimedOut() else { Issue.record("expected timeout"); return }
        #expect(a.decide(approved: true) == nil)

        var b = make()
        _ = b.receive(.hello(hello), screenRecordingGranted: true)
        _ = b.receive(goodAuth, screenRecordingGranted: true)
        guard case .deny(.userDenied, _)? = b.decide(approved: false) else { Issue.record("expected userDenied"); return }
        #expect(b.phase == .finished)
    }

    @Test func finishSilencesEverything() {
        var h = make()
        h.finish()
        #expect(h.receive(.hello(hello), screenRecordingGranted: true) == nil)
        #expect(h.handshakeTimedOut() == nil)
        #expect(h.decide(approved: true) == nil)
    }
}

@Suite struct ViewerHandshakeTests {
    private let hostFP = Data(repeating: 0xAA, count: 32)
    private let accept = Accept(sessionId: 42, sessionToken: Data(repeating: 9, count: 16), hostName: "Host Mac")

    @Test func pinnedHostSkipsVerification() {
        var v = ViewerHandshake(pinnedFingerprint: hostFP)
        #expect(v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true) == .sendHandshake(hostFingerprint: hostFP))
        #expect(v.receive(.accept(accept)) == .startStreaming(accept))
        #expect(v.phase == .streaming(accept))
    }

    @Test func pinMismatchAtReadyIsIdentityChanged() {
        var v = ViewerHandshake(pinnedFingerprint: hostFP)
        let effect = v.transportReady(peerFingerprint: Data(repeating: 0xEE, count: 32), isKnownFingerprint: false)
        #expect(effect == .end(message: ViewerHandshake.identityChangedMessage, closeReason: .protocolError))
        #expect(v.isEnded)
    }

    @Test func transportPinFailureIsIdentityChangedNotARepin() {
        var v = ViewerHandshake(pinnedFingerprint: hostFP)
        let effect = v.transportEnded(.failed(PeerConnection.pinMismatchMessage))
        #expect(effect == .end(message: ViewerHandshake.identityChangedMessage, closeReason: nil))
    }

    @Test func unpinnedHostRequiresUserTrustBeforeAnythingIsSent() {
        var v = ViewerHandshake(pinnedFingerprint: nil)
        #expect(v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: false) == .verify(fingerprint: hostFP, firstTime: true))
        #expect(v.receive(.accept(accept)) == .end(message: "The Host sent an unexpected message", closeReason: .protocolError))

        var w = ViewerHandshake(pinnedFingerprint: nil)
        #expect(w.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true) == .verify(fingerprint: hostFP, firstTime: false))
        #expect(w.userTrusted() == .sendHandshake(hostFingerprint: hostFP))
        #expect(w.phase == .awaitingApproval(hostFingerprint: hostFP))
        #expect(w.userTrusted() == nil)
    }

    @Test func rejectingTheHostEnds() {
        var v = ViewerHandshake(pinnedFingerprint: nil)
        _ = v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: false)
        #expect(v.userRejected() == .end(message: "You did not trust the Host's identity", closeReason: .userInitiated))
        #expect(v.userRejected() == nil)
    }

    @Test func invalidPeerFingerprintEnds() {
        var v = ViewerHandshake(pinnedFingerprint: nil)
        guard case .end(_, .protocolError)? = v.transportReady(peerFingerprint: nil, isKnownFingerprint: false) else {
            Issue.record("expected end")
            return
        }
    }

    @Test(arguments: DenyReason.allCases)
    func denyEndsWithReadableReason(_ reason: DenyReason) {
        var v = ViewerHandshake(pinnedFingerprint: hostFP)
        _ = v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true)
        guard case .end(let message, nil)? = v.receive(.deny(Deny(reason: reason))) else {
            Issue.record("expected end")
            return
        }
        #expect(!message.isEmpty)
        #expect(message == ViewerHandshake.message(for: Deny(reason: reason)))
    }

    @Test func denyMessageIncludesHostDetail() {
        #expect(ViewerHandshake.message(for: Deny(reason: .busy, message: "x")) == "The Host is busy with another session (x)")
    }

    @Test func configAndDisconnectWhileStreaming() {
        var v = ViewerHandshake(pinnedFingerprint: hostFP)
        _ = v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true)
        _ = v.receive(.accept(accept))
        let config = StreamConfig(width: 1280, height: 720, fps: 60, bitrateKbps: 3000, displayPointWidth: 1440,
                                  displayPointHeight: 900)
        #expect(v.receive(.config(config)) == .configure(config))
        #expect(v.receive(.accept(accept)) == .end(message: "The Host sent an unexpected message", closeReason: .protocolError))

        var w = ViewerHandshake(pinnedFingerprint: hostFP)
        _ = w.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true)
        _ = w.receive(.accept(accept))
        #expect(w.receive(.disconnect(.permissionRevoked)) == .end(message: "The Host revoked screen sharing permission", closeReason: nil))
        #expect(w.receive(.disconnect(.hostStopped)) == nil)
        #expect(w.transportEnded(.closed) == nil)
    }

    @Test func transportEndingMessages() {
        var connecting = ViewerHandshake(pinnedFingerprint: nil)
        #expect(connecting.transportEnded(.failed("Connection timed out")) == .end(message: "Could not connect: Connection timed out", closeReason: nil))
        var streaming = ViewerHandshake(pinnedFingerprint: hostFP)
        _ = streaming.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true)
        #expect(streaming.transportEnded(.failed("x")) == .end(message: "Connection lost: x", closeReason: nil))
        var closed = ViewerHandshake(pinnedFingerprint: nil)
        #expect(closed.transportEnded(.closed) == .end(message: "Connection closed", closeReason: nil))
        #expect(closed.transportEnded(.ready) == nil)
    }

    @Test func approvalTimeoutAndUserDisconnect() {
        var v = ViewerHandshake(pinnedFingerprint: hostFP)
        #expect(v.approvalTimedOut() == nil)
        _ = v.transportReady(peerFingerprint: hostFP, isKnownFingerprint: true)
        #expect(v.approvalTimedOut() == .end(message: "The Host did not answer the request", closeReason: .timeout))
        var w = ViewerHandshake(pinnedFingerprint: nil)
        #expect(w.userDisconnected() == .end(message: "Disconnected", closeReason: .userInitiated))
        #expect(w.userDisconnected() == nil)
    }

    @Test(arguments: DisconnectReason.allCases)
    func everyDisconnectReasonHasAMessage(_ reason: DisconnectReason) {
        #expect(!ViewerHandshake.message(for: reason).isEmpty)
    }
}

@Suite struct SessionSupportTests {
    @Test func hostPartParsing() {
        #expect(SessionSupport.hostPart(of: "192.168.1.2:47800") == "192.168.1.2")
        #expect(SessionSupport.hostPart(of: "[fe80::1]:47800") == "fe80::1")
        #expect(SessionSupport.hostPart(of: "mac.local:1") == "mac.local")
        #expect(SessionSupport.hostPart(of: "fe80::1") == "fe80::1")
    }

    @Test func pathLabels() {
        #expect(SessionSupport.pathLabel(forHost: "127.0.0.1") == "Loopback")
        #expect(SessionSupport.pathLabel(forHost: "100.101.102.103") == "Tailscale")
        #expect(SessionSupport.pathLabel(forHost: "mac.tail1234.ts.net") == "Tailscale")
        #expect(SessionSupport.pathLabel(forHost: "192.168.1.20") == "LAN")
        #expect(SessionSupport.shouldProbeTailscale(host: "100.64.0.1"))
        #expect(!SessionSupport.shouldProbeTailscale(host: "192.168.0.1"))
    }

    @Test func environmentStrings() {
        #expect(!SessionSupport.computerName().isEmpty)
        #expect(!SessionSupport.appVersion().isEmpty)
    }
}

/// Peer-supplied names shown in consent UI (review finding security-2).
@Suite struct DisplayNameSanitizingTests {
    @Test func plainNamesAreUnchanged() {
        #expect(SessionSupport.displayName("Isabella’s MacBook Pro") == "Isabella’s MacBook Pro")
        #expect(SessionSupport.displayName("Mac 🍎") == "Mac 🍎")
    }

    @Test func lineBreaksAndControlCharactersBecomeSingleSpaces() {
        #expect(SessionSupport.displayName("Evil\nLine\r\n\tTwo\u{0}") == "Evil Line Two")
        #expect(SessionSupport.displayName("a\u{2028}b\u{2029}c\u{85}d") == "a b c d")
        #expect(SessionSupport.displayName("  padded   name  ") == "padded name")
    }

    @Test func bidiOverridesIsolatesAndZeroWidthCharactersAreRemoved() {
        for scalar in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200B, 0x200E, 0xFEFF] {
            let raw = "abc" + String(UnicodeScalar(UInt32(scalar))!) + "def"
            #expect(SessionSupport.displayName(raw) == "abc def", "U+\(String(scalar, radix: 16))")
        }
    }

    @Test func longNamesAreCappedWithAnEllipsis() {
        let name = SessionSupport.displayName(String(repeating: "x", count: 300))
        #expect(name.count == SessionSupport.maxDisplayNameLength)
        #expect(name.hasSuffix("…"))
    }

    @Test func emptyOrInvisibleNamesFallBack() {
        #expect(SessionSupport.displayName("") == "Unknown Mac")
        #expect(SessionSupport.displayName("\u{202E}\n\u{200B}") == "Unknown Mac")
        #expect(SessionSupport.displayName(" ", fallback: "unknown") == "unknown")
    }
}
