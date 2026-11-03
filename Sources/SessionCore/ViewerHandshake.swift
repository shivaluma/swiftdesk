import Foundation
import TransportCore
import WireProtocol

/// Viewer-side handshake rules, as a pure state machine.
///
/// Trust model: if the dialed address has a pinned fingerprint, TLS itself rejects any other certificate, and a
/// mismatch ends the attempt with an explicit "identity changed" error — it is never silently re-pinned. Without a
/// pin, the TLS handshake succeeds but nothing is sent (not even HELLO, which carries the device name) until the user
/// has compared the Host's fingerprint and chosen to trust it.
///
/// Like `HostHandshake`, this returns effects instead of doing I/O so every branch is unit-testable.
public struct ViewerHandshake: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case connecting
        case verifyingHost(fingerprint: Data, firstTime: Bool)
        case awaitingApproval(hostFingerprint: Data)
        case streaming(Accept)
        case ended(String)
    }

    public enum Effect: Sendable, Equatable {
        /// Ask the user to verify this fingerprint.
        case verify(fingerprint: Data, firstTime: Bool)
        /// Send HELLO + AUTH binding this observed Host fingerprint.
        case sendHandshake(hostFingerprint: Data)
        /// ACCEPT received: start the media pipeline.
        case startStreaming(Accept)
        /// CONFIG received while streaming.
        case configure(StreamConfig)
        /// Session over. `closeReason` non-nil: close the transport, sending DISCONNECT with that reason.
        case end(message: String, closeReason: DisconnectReason?)
        /// PASSWORD_CHALLENGE from the verified Host: answer with a proof if a password is available, else `.none`.
        case answerChallenge(PasswordChallenge, hostFingerprint: Data)
        /// A challenge this Viewer refuses to work on (rounds outside `AccessPassword.acceptedIterations`):
        /// answer `.none`, so the Host falls back to its prompt.
        case declineChallenge
        /// The Host fell back to its operator prompt without using this Viewer's password (its password timer ran
        /// out, or password access changed meanwhile): stop any proof, show "waiting for approval", and do not treat
        /// a later ACCEPT as a password login.
        case passwordFallback
    }

    public static let identityChangedMessage =
        "Host identity changed: this address presented a different certificate than the one you trusted. " +
        "If the Host regenerated its identity, remove it from Trusted Hosts and verify the new fingerprint."

    public static let incorrectPasswordMessage = "Incorrect password"

    public let pinnedFingerprint: Data?
    public private(set) var phase: Phase = .connecting
    /// A PASSWORD_CHALLENGE was already answered on this connection (the Host sends at most one).
    public private(set) var challengeAnswered = false

    public init(pinnedFingerprint: Data?) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    public var isEnded: Bool {
        if case .ended = phase { true } else { false }
    }

    /// Transport reported `.ready`. `isKnownFingerprint`: the fingerprint is pinned for some other address.
    public mutating func transportReady(peerFingerprint: Data?, isKnownFingerprint: Bool) -> Effect? {
        guard case .connecting = phase else { return nil }
        guard let fp = peerFingerprint, fp.count == Auth.fingerprintSize else {
            return end("The Host did not present a valid identity", close: .protocolError)
        }
        if let pin = pinnedFingerprint {
            // TLS already enforced the pin; checking again costs nothing and guards against a transport regression.
            guard pin == fp else { return end(Self.identityChangedMessage, close: .protocolError) }
            phase = .awaitingApproval(hostFingerprint: fp)
            return .sendHandshake(hostFingerprint: fp)
        }
        phase = .verifyingHost(fingerprint: fp, firstTime: !isKnownFingerprint)
        return .verify(fingerprint: fp, firstTime: !isKnownFingerprint)
    }

    public mutating func userTrusted() -> Effect? {
        guard case .verifyingHost(let fp, _) = phase else { return nil }
        phase = .awaitingApproval(hostFingerprint: fp)
        return .sendHandshake(hostFingerprint: fp)
    }

    public mutating func userRejected() -> Effect? {
        guard case .verifyingHost = phase else { return nil }
        return end("You did not trust the Host's identity", close: .userInitiated)
    }

    public mutating func userDisconnected() -> Effect? {
        switch phase {
        case .ended: return nil
        default: return end("Disconnected", close: .userInitiated)
        }
    }

    /// No answer from the Host's operator within the Viewer's own patience window.
    public mutating func approvalTimedOut() -> Effect? {
        guard case .awaitingApproval = phase else { return nil }
        return end("The Host did not answer the request", close: .timeout)
    }

    /// Control messages relevant to the handshake (ACCEPT, DENY, CONFIG, DISCONNECT). Others return nil.
    public mutating func receive(_ message: ControlMessage) -> Effect? {
        switch (phase, message) {
        case (.awaitingApproval, .accept(let accept)):
            phase = .streaming(accept)
            return .startStreaming(accept)
        case (.streaming, .config(let config)):
            return .configure(config)
        case (.awaitingApproval(let hostFingerprint), .passwordChallenge(let challenge)):
            // Only reachable after HELLO/AUTH, i.e. after the user verified this Host (or its pin matched in TLS):
            // a proof is never computed for an unverified Host.
            guard !challengeAnswered else {
                return end("The Host sent an unexpected message", close: .protocolError)
            }
            challengeAnswered = true
            guard AccessPassword.acceptedIterations.contains(challenge.iterations) else { return .declineChallenge }
            return .answerChallenge(challenge, hostFingerprint: hostFingerprint)
        case (.awaitingApproval, .passwordResponse(let response)):
            // Host → Viewer PASSWORD_RESPONSE(none) = "prompting instead". Meaningful only after a challenge.
            guard challengeAnswered, response.kind == .none else { return nil }
            return .passwordFallback
        case (.connecting, .passwordChallenge), (.verifyingHost, .passwordChallenge), (.streaming, .passwordChallenge):
            return end("The Host sent an unexpected message", close: .protocolError)
        case (.ended, _):
            return nil
        case (_, .deny(let deny)):
            return end(Self.message(for: deny), close: nil)
        case (_, .disconnect(let reason)):
            return end(Self.message(for: reason), close: nil)
        case (.connecting, .accept), (.verifyingHost, .accept), (.streaming, .accept):
            return end("The Host sent an unexpected message", close: .protocolError)
        default:
            return nil
        }
    }

    /// Transport reached a terminal state.
    public mutating func transportEnded(_ state: PeerConnectionState) -> Effect? {
        guard !isEnded else { return nil }
        switch state {
        case .failed(let reason):
            if reason == PeerConnection.pinMismatchMessage {
                return end(Self.identityChangedMessage, close: nil)
            }
            if case .connecting = phase {
                return end("Could not connect: \(reason)", close: nil)
            }
            return end("Connection lost: \(reason)", close: nil)
        case .closed:
            return end("Connection closed", close: nil)
        case .connecting, .ready:
            return nil
        }
    }

    private mutating func end(_ message: String, close: DisconnectReason?) -> Effect {
        phase = .ended(message)
        return .end(message: message, closeReason: close)
    }

    public static func message(for deny: Deny) -> String {
        let base: String = switch deny.reason {
        case .userDenied: "The Host declined the connection"
        case .busy: "The Host is busy with another session"
        case .rateLimited: "Too many connection attempts; try again later"
        case .versionMismatch: "The Host runs an incompatible version of SwiftDesk"
        case .identityMismatch: "The Host could not verify this device's identity"
        case .permissionsMissing: "The Host has not granted Screen Recording permission"
        case .timeout: "The request timed out on the Host"
        case .authFailed: incorrectPasswordMessage
        }
        if deny.reason == .authFailed { return base }
        return deny.message.isEmpty ? base : "\(base) (\(deny.message))"
    }

    public static func message(for reason: DisconnectReason) -> String {
        switch reason {
        case .userInitiated: "The Host ended the session"
        case .hostStopped: "The Host stopped sharing"
        case .timeout: "The session timed out"
        case .protocolError: "The session ended because of a protocol error"
        case .permissionRevoked: "The Host revoked screen sharing permission"
        case .appQuit: "SwiftDesk quit on the Host"
        }
    }
}
