import Foundation

/// Type byte of a control message on the reliable stream.
public enum ControlMessageType: UInt8, Sendable, CaseIterable {
    case hello = 1, auth = 2, accept = 3, deny = 4, config = 5, ping = 6, pong = 7,
         keyDown = 8, keyUp = 9, mouseDown = 10, mouseUp = 11, mouseMove = 12, scroll = 13,
         requestKeyframe = 14, disconnect = 15, stats = 16,
         /// Host → Viewer, only to a Viewer that announced `Auth.Capabilities.passwordAuth` (opt-in password access).
         passwordChallenge = 17,
         /// Viewer → Host, answer to `passwordChallenge`.
         passwordResponse = 18,
         /// 0.1.5, both directions, control stream, only when both sides announced `PeerCapabilities.clipboard`:
         /// the sender's clipboard sharing switch (`ClipboardState`).
         clipboardState = 19,
         /// 0.1.5, both directions, **side stream only**, same capability: one copied clipboard (`ClipboardContent`).
         clipboard = 20,
         /// 0.1.6, Host → Viewer, **side stream only**, only when both sides announced `PeerCapabilities.cursorShape`:
         /// defines one pointer shape under an id (`CursorImage`).
         cursorImage = 21,
         /// 0.1.6, Host → Viewer, control stream, same capability: the Host pointer's current shape (`CursorShape`).
         cursorShape = 22
}

/// First message from the Viewer. Carries the protocol version so mismatches are refused before any media flows.
public struct Hello: Sendable, Equatable {
    public var protocolVersion: UInt16
    public var deviceName: String
    public var appVersion: String

    public init(protocolVersion: UInt16 = WireConstants.protocolVersion, deviceName: String, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.appVersion = appVersion
    }
}

/// Channel-binding confirmation sent by the Viewer after HELLO: the fingerprints it observed in TLS.
///
/// Fixed sizes are enforced on decode; on encode a mis-sized field is truncated or zero-padded so it can only
/// cause an identity mismatch (fail closed), never a framing error.
public struct Auth: Sendable, Equatable {
    public static let fingerprintSize = 32
    public static let nonceSize = 16

    public var viewerFingerprint: Data
    public var hostFingerprint: Data
    public var nonce: Data

    public init(viewerFingerprint: Data, hostFingerprint: Data, nonce: Data) {
        self.viewerFingerprint = viewerFingerprint
        self.hostFingerprint = hostFingerprint
        self.nonce = nonce
    }

    // MARK: Capabilities (carried in the nonce)

    /// Optional features a Viewer supports, announced inside the AUTH nonce. See `PeerCapabilities` for the carrier
    /// layout (`"SDC1"` + one flags byte + 11 random bytes), the bit table and the "both sides" rule.
    public typealias Capabilities = PeerCapabilities

    /// "SDC1".
    public static let capabilityMarker = PeerCapabilities.marker

    /// A nonce announcing `capabilities`: marker, flags, then the first 11 bytes of `random` (zero-padded).
    public static func nonce(capabilities: Capabilities, random: Data) -> Data {
        PeerCapabilities.carrier(capabilities, random: random)
    }

    /// Capabilities announced in `nonce`; empty for a nonce without the marker (older Viewers).
    public var capabilities: Capabilities { PeerCapabilities.announced(in: nonce) }
}

/// Host approval. `sessionId` scopes every video datagram. `sessionToken` is 16 opaque bytes (reserved for a
/// fallback transport that was never needed); since 0.1.4 it carries the Host's `PeerCapabilities`
/// (`Accept.capabilities`, `Accept.sessionToken(capabilities:random:)`).
public struct Accept: Sendable, Equatable {
    public static let sessionTokenSize = 16

    public var sessionId: UInt32
    public var sessionToken: Data
    public var hostName: String

    public init(sessionId: UInt32, sessionToken: Data, hostName: String) {
        self.sessionId = sessionId
        self.sessionToken = sessionToken
        self.hostName = hostName
    }
}

public enum DenyReason: UInt8, Sendable, CaseIterable {
    case userDenied = 1, busy, rateLimited, versionMismatch, identityMismatch, permissionsMissing, timeout,
         /// Wrong access password (PASSWORD_RESPONSE). Sent only to Viewers that announced `passwordAuth`.
         authFailed
}

public struct Deny: Sendable, Equatable {
    public var reason: DenyReason
    public var message: String

    public init(reason: DenyReason, message: String = "") {
        self.reason = reason
        self.message = message
    }
}

/// Current stream parameters announced by the Host (sent at start and on every adaptation step), so the Viewer
/// can size its renderer and map input without inspecting the bitstream.
public struct StreamConfig: Sendable, Equatable {
    public static let codecH264: UInt8 = 1

    public var width: UInt16
    public var height: UInt16
    public var fps: UInt8
    public var bitrateKbps: UInt32
    /// Host display size in points.
    public var displayPointWidth: Float
    public var displayPointHeight: Float
    /// 1 = H.264.
    public var codec: UInt8

    public init(width: UInt16, height: UInt16, fps: UInt8, bitrateKbps: UInt32,
                displayPointWidth: Float, displayPointHeight: Float, codec: UInt8 = StreamConfig.codecH264) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.displayPointWidth = displayPointWidth
        self.displayPointHeight = displayPointHeight
        self.codec = codec
    }
}

/// RTT probe. PONG echoes the same struct so the sender can compute RTT with its own clock only.
public struct Ping: Sendable, Equatable {
    public var id: UInt32
    public var sentAtNanos: UInt64

    public init(id: UInt32, sentAtNanos: UInt64) {
        self.id = id
        self.sentAtNanos = sentAtNanos
    }
}

/// Physical key transition. Key codes are never logged or persisted.
public struct KeyEvent: Sendable, Equatable {
    public var seq: UInt32
    public var keyCode: UInt16
    /// `CGEventFlags.rawValue`.
    public var modifiers: UInt64
    public var isRepeat: Bool

    public init(seq: UInt32, keyCode: UInt16, modifiers: UInt64, isRepeat: Bool = false) {
        self.seq = seq
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

public enum MouseButton: UInt8, Sendable, CaseIterable {
    case left = 0, right = 1, other = 2
}

/// x/y normalized to the video frame: (0,0) top-left, (1,1) bottom-right.
public struct MouseButtonEvent: Sendable, Equatable {
    public var seq: UInt32
    public var button: MouseButton
    public var x: Float
    public var y: Float
    public var clickCount: UInt8
    public var modifiers: UInt64

    public init(seq: UInt32, button: MouseButton, x: Float, y: Float, clickCount: UInt8, modifiers: UInt64) {
        self.seq = seq
        self.button = button
        self.x = x
        self.y = y
        self.clickCount = clickCount
        self.modifiers = modifiers
    }
}

/// Latest pointer state. Sent as MOUSE_MOVE (reliable) or as a pointer datagram (preferred, unreliable).
/// Receiver ignores seq <= last applied, so a stale move can never overwrite a newer one.
public struct PointerState: Sendable, Equatable {
    public var seq: UInt32
    public var x: Float
    public var y: Float
    /// bit0 left, bit1 right, bit2 other.
    public var buttonsMask: UInt8

    public init(seq: UInt32, x: Float, y: Float, buttonsMask: UInt8) {
        self.seq = seq
        self.x = x
        self.y = y
        self.buttonsMask = buttonsMask
    }
}

public struct ScrollEvent: Sendable, Equatable {
    public var seq: UInt32
    public var deltaX: Float
    public var deltaY: Float
    /// true: pixels, false: lines.
    public var isPrecise: Bool
    public var phase: UInt8
    public var momentumPhase: UInt8

    public init(seq: UInt32, deltaX: Float, deltaY: Float, isPrecise: Bool, phase: UInt8 = 0, momentumPhase: UInt8 = 0) {
        self.seq = seq
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

public enum DisconnectReason: UInt8, Sendable, CaseIterable {
    case userInitiated = 1, hostStopped, timeout, protocolError, permissionRevoked, appQuit
}

/// Periodic Viewer-side delivery report that drives Host adaptation (bitrate/resolution ladder).
public struct ViewerStats: Sendable, Equatable {
    public var windowMillis: UInt32
    public var packetsReceived: UInt32
    /// Estimated.
    public var packetsLost: UInt32
    public var framesCompleted: UInt32
    public var framesLost: UInt32
    public var framesPresented: UInt32
    public var decodeMicrosAvg: UInt32
    public var decodeToPresentMicrosAvg: UInt32

    public init(windowMillis: UInt32 = 0, packetsReceived: UInt32 = 0, packetsLost: UInt32 = 0,
                framesCompleted: UInt32 = 0, framesLost: UInt32 = 0, framesPresented: UInt32 = 0,
                decodeMicrosAvg: UInt32 = 0, decodeToPresentMicrosAvg: UInt32 = 0) {
        self.windowMillis = windowMillis
        self.packetsReceived = packetsReceived
        self.packetsLost = packetsLost
        self.framesCompleted = framesCompleted
        self.framesLost = framesLost
        self.framesPresented = framesPresented
        self.decodeMicrosAvg = decodeMicrosAvg
        self.decodeToPresentMicrosAvg = decodeToPresentMicrosAvg
    }
}

/// Opt-in password access: the Host asks a capable Viewer to prove it knows the access password.
///
/// The Viewer derives `key = PBKDF2-HMAC-SHA256(NFC(password), salt, iterations)` and answers with
/// `HMAC-SHA256(key, "swiftdesk-password-v1" ‖ nonce ‖ hostFingerprint ‖ viewerFingerprint)`, which binds the proof to
/// this nonce and to both TLS-authenticated identities. Fixed sizes are enforced on decode; on encode mis-sized
/// fields are truncated or zero-padded (fail closed).
public struct PasswordChallenge: Sendable, Equatable {
    public static let saltSize = 16
    public static let nonceSize = 32

    public var salt: Data
    public var iterations: UInt32
    /// Fresh per connection, single use.
    public var nonce: Data

    public init(salt: Data, iterations: UInt32, nonce: Data) {
        self.salt = salt
        self.iterations = iterations
        self.nonce = nonce
    }
}

/// The Viewer's answer to a `PasswordChallenge`. `kind == .none` (no password available) carries an all-zero proof
/// and makes the Host fall back to its operator prompt.
public struct PasswordResponse: Sendable, Equatable {
    public static let proofSize = 32

    public enum Kind: UInt8, Sendable, CaseIterable {
        case none = 0
        case proof = 1
    }

    public var kind: Kind
    public var proof: Data

    public init(kind: Kind, proof: Data) {
        self.kind = kind
        self.proof = kind == .none ? Data(count: Self.proofSize) : proof
    }

    /// "I have no password": the Host shows its operator prompt instead.
    public static let none = PasswordResponse(kind: .none, proof: Data())

    public static func proof(_ proof: Data) -> PasswordResponse {
        PasswordResponse(kind: .proof, proof: proof)
    }
}

/// Every message carried on the reliable, ordered control stream — and, for the few types with
/// `ControlMessageType.isSideStream` (0.1.5: CLIPBOARD; 0.1.6: CURSOR_IMAGE), on the side stream with the same framing.
///
/// Encoded as a compact fixed binary layout (no JSON/Codable) because input events share this path and must be
/// cheap to produce and parse at hundreds of events per second.
public enum ControlMessage: Sendable, Equatable {
    case hello(Hello)
    case auth(Auth)
    case accept(Accept)
    case deny(Deny)
    case config(StreamConfig)
    case ping(Ping)
    case pong(Ping)
    case keyDown(KeyEvent)
    case keyUp(KeyEvent)
    case mouseDown(MouseButtonEvent)
    case mouseUp(MouseButtonEvent)
    case mouseMove(PointerState)
    case scroll(ScrollEvent)
    case requestKeyframe(reason: UInt8)
    case disconnect(DisconnectReason)
    case stats(ViewerStats)
    case passwordChallenge(PasswordChallenge)
    case passwordResponse(PasswordResponse)
    case clipboardState(ClipboardState)
    case clipboard(ClipboardContent)
    case cursorImage(CursorImage)
    case cursorShape(CursorShape)

    public var type: ControlMessageType {
        switch self {
        case .hello: .hello
        case .auth: .auth
        case .accept: .accept
        case .deny: .deny
        case .config: .config
        case .ping: .ping
        case .pong: .pong
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .mouseDown: .mouseDown
        case .mouseUp: .mouseUp
        case .mouseMove: .mouseMove
        case .scroll: .scroll
        case .requestKeyframe: .requestKeyframe
        case .disconnect: .disconnect
        case .stats: .stats
        case .passwordChallenge: .passwordChallenge
        case .passwordResponse: .passwordResponse
        case .clipboardState: .clipboardState
        case .clipboard: .clipboard
        case .cursorImage: .cursorImage
        case .cursorShape: .cursorShape
        }
    }
}
