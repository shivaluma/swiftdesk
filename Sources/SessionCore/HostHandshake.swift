import Foundation
import WireProtocol

/// Host-side handshake rules for one incoming connection, as a pure state machine.
///
/// Order (PRD §4/§7): mutual TLS already happened in TransportCore; then the Viewer sends HELLO (protocol version,
/// device name) and AUTH — the fingerprints *it* observed in TLS. AUTH is channel binding: the Host checks that the
/// Viewer saw the Host's own certificate (no interception in between) and that the Viewer claims the same identity
/// TLS authenticated. Only then is the operator asked; nothing grants control before an explicit approval.
///
/// Opt-in password access: when the session passes `PasswordGate.available`, a Viewer that announced
/// `Auth.Capabilities.passwordAuth` gets a PASSWORD_CHALLENGE instead of the prompt (`.awaitingPassword`). A valid
/// proof accepts at once (`.passwordAccepted`); "no password" falls back to the prompt (`.requestApproval`); the 3 s
/// timeout, or a challenge that went stale (password access switched off or the password changed meanwhile), falls
/// back to the prompt *and tells the Viewer* (`.fallbackToPrompt`), so it never takes a later operator approval for
/// a password login; a wrong proof is DENY(authFailed). A Viewer locked out after repeated wrong passwords is not
/// challenged and goes straight to the prompt. Everything before (version, channel binding, Screen Recording) is
/// unchanged and checked first.
///
/// Reconnect without a prompt (0.1.4): when the session passes `resume: true` at AUTH time (its `ReconnectGrace` allows
/// this identity), a Viewer that announced `PeerCapabilities.sessionResume` is accepted at once (`.resumeAccepted`),
/// before any password challenge or prompt. Version, channel binding and Screen Recording are still checked first.
///
/// The reducer never performs I/O: it returns an `Effect` the session executes (send DENY, show the prompt, …),
/// which keeps every rejection path unit-testable without sockets or TCC permissions.
public struct HostHandshake: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case awaitingHello
        case awaitingAuth(Hello)
        /// PASSWORD_CHALLENGE sent; waiting for PASSWORD_RESPONSE (no prompt is shown).
        case awaitingPassword(Hello, PasswordChallenge)
        case awaitingApproval(Hello)
        case accepted(Hello)
        /// Denied, closed or abandoned; no further effects.
        case finished
    }

    public enum Effect: Sendable, Equatable {
        /// Identity verified: show the operator an approval prompt.
        case requestApproval(Hello)
        /// Operator approved: send ACCEPT and start the session.
        case accept(Hello)
        /// Send DENY with this reason, then close.
        case deny(DenyReason, String)
        /// Protocol violation: close without DENY.
        case close(DisconnectReason)
        /// Identity verified and password access available: send this PASSWORD_CHALLENGE and start the password timer.
        case sendChallenge(PasswordChallenge)
        /// Valid password proof: send ACCEPT and start the session, marked "via password".
        case passwordAccepted(Hello)
        /// The password check ended without using the Viewer's password (timeout, or the challenge went stale): send
        /// PASSWORD_RESPONSE(none) Host → Viewer so a proof still in flight is not mistaken for a login, then show the
        /// operator prompt exactly like `.requestApproval`.
        case fallbackToPrompt(Hello)
        /// The Viewer is resuming a session the operator allowed (or that used the access password) after its
        /// connection dropped, within the Host's grace window: send ACCEPT and start the session without a prompt.
        case resumeAccepted(Hello)
    }

    /// What the Host's password-access policy allows for this connection, computed by the session at AUTH time.
    public enum PasswordGate: Sendable, Equatable {
        /// No password access (off, not set, or disabled by the global failure cap): prompt as usual.
        case disabled
        /// This Viewer fingerprint or IP address is locked out after repeated wrong passwords: no challenge, the
        /// operator is asked as usual (the prompt has its own deny cooldown and connection rate limits).
        case lockedOut
        /// Challenge a capable Viewer with this (fresh nonce).
        case available(PasswordChallenge)
    }

    public let hostFingerprint: Data
    /// Fingerprint TransportCore observed for the Viewer's client certificate.
    public let peerFingerprint: Data?
    public let protocolVersion: UInt16
    public private(set) var phase: Phase = .awaitingHello

    public init(hostFingerprint: Data, peerFingerprint: Data?, protocolVersion: UInt16 = WireConstants.protocolVersion) {
        self.hostFingerprint = hostFingerprint
        self.peerFingerprint = peerFingerprint
        self.protocolVersion = protocolVersion
    }

    /// The HELLO received so far, if any.
    public var hello: Hello? {
        switch phase {
        case .awaitingAuth(let h), .awaitingPassword(let h, _), .awaitingApproval(let h), .accepted(let h): h
        case .awaitingHello, .finished: nil
        }
    }

    public var isAwaitingApproval: Bool {
        if case .awaitingApproval = phase { true } else { false }
    }

    public var isAwaitingPassword: Bool {
        if case .awaitingPassword = phase { true } else { false }
    }

    /// Feeds a handshake message (HELLO, AUTH or PASSWORD_RESPONSE). Other message types are the router's business
    /// and return nil.
    /// - Parameters:
    ///   - screenRecordingGranted: checked at AUTH time, so the Viewer learns immediately that the Host cannot share
    ///     its screen instead of waiting for an approval that would lead nowhere.
    ///   - password: the password-access gate, used at AUTH time only.
    ///   - verifyProof: checks a PASSWORD_RESPONSE proof against the challenge it answers (constant time, in the
    ///     session's `HostAccessPassword`). Called at most once per connection.
    ///   - resume: the Host's reconnect grace allows this identity back without a prompt (used at AUTH time only;
    ///     effective only if the Viewer announced `sessionResume`).
    public mutating func receive(_ message: ControlMessage, screenRecordingGranted: Bool,
                                 password: PasswordGate = .disabled, resume: Bool = false,
                                 verifyProof: (Data, PasswordChallenge) -> HostAccessPassword.ProofResult = { _, _ in .invalid })
        -> Effect? {
        switch (phase, message) {
        case (.awaitingHello, .hello(let hello)):
            guard hello.protocolVersion == protocolVersion else {
                phase = .finished
                return .deny(.versionMismatch,
                             "Host speaks protocol \(protocolVersion), Viewer speaks \(hello.protocolVersion)")
            }
            phase = .awaitingAuth(hello)
            return nil

        case (.awaitingAuth(let hello), .auth(let auth)):
            guard let peerFingerprint, peerFingerprint.count == Auth.fingerprintSize,
                  auth.viewerFingerprint == peerFingerprint,
                  auth.hostFingerprint == hostFingerprint,
                  auth.nonce.count == Auth.nonceSize else {
                phase = .finished
                return .deny(.identityMismatch, "Device identities do not match the secure connection")
            }
            guard screenRecordingGranted else {
                phase = .finished
                return .deny(.permissionsMissing, "Screen Recording permission is not granted on the Host")
            }
            if resume, auth.capabilities.contains(.sessionResume) {
                phase = .accepted(hello)
                return .resumeAccepted(hello)
            }
            switch password {
            case .available(let challenge) where auth.capabilities.contains(.passwordAuth):
                phase = .awaitingPassword(hello, challenge)
                return .sendChallenge(challenge)
            case .available, .disabled, .lockedOut:
                // Locked out: password attempts are refused, asking the operator is not.
                phase = .awaitingApproval(hello)
                return .requestApproval(hello)
            }

        case (.awaitingPassword(let hello, let challenge), .passwordResponse(let response)):
            // Single use: whatever the answer, this challenge is spent.
            switch response.kind {
            case .none:
                phase = .awaitingApproval(hello)
                return .requestApproval(hello)
            case .proof:
                switch verifyProof(response.proof, challenge) {
                case .valid:
                    phase = .accepted(hello)
                    return .passwordAccepted(hello)
                case .invalid:
                    phase = .finished
                    return .deny(.authFailed, "Incorrect password")
                case .stale:
                    // Switched off or changed on the Host meanwhile: not a guess, so no failure and no DENY.
                    phase = .awaitingApproval(hello)
                    return .fallbackToPrompt(hello)
                }
            }

        case (.awaitingApproval, .passwordResponse):
            // Arrived after the password timer fell back to the prompt: the operator decides now.
            return nil

        case (.awaitingHello, .auth), (.awaitingAuth, .hello),
             (.awaitingPassword, .hello), (.awaitingPassword, .auth),
             (.awaitingApproval, .hello), (.awaitingApproval, .auth),
             (.accepted, .hello), (.accepted, .auth),
             (.awaitingHello, .passwordResponse), (.awaitingAuth, .passwordResponse), (.accepted, .passwordResponse):
            phase = .finished
            return .close(.protocolError)

        default:
            return nil
        }
    }

    /// HELLO + AUTH did not arrive in time.
    public mutating func handshakeTimedOut() -> Effect? {
        switch phase {
        case .awaitingHello, .awaitingAuth:
            phase = .finished
            return .deny(.timeout, "Handshake timed out")
        default:
            return nil
        }
    }

    /// No PASSWORD_RESPONSE within the password timeout (a slow or silent Viewer): fall back to the prompt and tell
    /// the Viewer, whose late proof will be ignored.
    public mutating func passwordTimedOut() -> Effect? {
        guard case .awaitingPassword(let hello, _) = phase else { return nil }
        phase = .awaitingApproval(hello)
        return .fallbackToPrompt(hello)
    }

    /// The operator did not answer in time.
    public mutating func approvalTimedOut() -> Effect? {
        guard case .awaitingApproval = phase else { return nil }
        phase = .finished
        return .deny(.timeout, "The Host did not respond to the request")
    }

    /// Operator decision. Ignored unless a prompt is pending (e.g. a stale button press after a timeout).
    public mutating func decide(approved: Bool) -> Effect? {
        guard case .awaitingApproval(let hello) = phase else { return nil }
        if approved {
            phase = .accepted(hello)
            return .accept(hello)
        }
        phase = .finished
        return .deny(.userDenied, "The Host declined the request")
    }

    /// Connection went away or the session was torn down; later events produce nothing.
    public mutating func finish() {
        phase = .finished
    }
}
