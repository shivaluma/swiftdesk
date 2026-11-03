import Foundation

/// Optional features a peer supports, exchanged once per connection in both directions: the Viewer announces its set
/// in the AUTH nonce (`Auth.capabilities`), the Host in the ACCEPT session token (`Accept.capabilities`).
///
/// Why inside those fixed 16-byte fields: every decoder rejects unknown message types and trailing bytes, so a new
/// message or field sent to an older peer tears its connection down. Both fields are only length-checked by every
/// 0.1.x version, so a peer marks them `"SDC1"` + one flags byte + 11 random bytes. An older peer ignores the marker
/// (and never sets it, so the other side sees `[]`). A random value carries the marker by chance with probability
/// 2⁻³², and then at worst announces features the peer never uses.
///
/// Rule for every optional feature: it is used only when **both** sides announce its bit
/// (`viewer.intersection(host)`), and a peer never sends a message type that belongs to a feature the other side did
/// not announce. Bits are allocated here, once, for both directions:
///
/// | bit | name | meaning |
/// |---|---|---|
/// | 0 | `passwordAuth` | Viewer → Host only (0.1.2): understands PASSWORD_CHALLENGE / PASSWORD_RESPONSE and DENY(authFailed) |
/// | 1 | `sessionResume` | (0.1.4) Viewer: reconnects on its own after a dropped connection. Host: may let a Viewer it allowed back in without a new prompt within its grace window |
/// | 2 | `clipboard` | (0.1.5) understands CLIPBOARD_STATE (control stream) and CLIPBOARD (side stream); the Viewer opens the side stream once both sides announced it |
/// | 3 | `cursorShape` | (0.1.6) Host → Viewer pointer shape: CURSOR_SHAPE (control stream) and CURSOR_IMAGE (side stream); the Viewer opens the side stream once both sides announced it |
/// | 4–7 | — | free for later features |
public struct PeerCapabilities: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Viewer: understands PASSWORD_CHALLENGE / PASSWORD_RESPONSE and DENY(authFailed). Never set by a Host.
    public static let passwordAuth = PeerCapabilities(rawValue: 1 << 0)
    /// Survives dropouts: the Viewer reconnects automatically; the Host may resume an allowed session without a prompt.
    public static let sessionResume = PeerCapabilities(rawValue: 1 << 1)
    /// Clipboard sharing (0.1.5): CLIPBOARD_STATE / CLIPBOARD and the side stream. Announced whenever the build
    /// supports it; whether sharing is switched on travels in CLIPBOARD_STATE, so it can change during a session.
    public static let clipboard = PeerCapabilities(rawValue: 1 << 2)
    /// Remote pointer shape (0.1.6): the Host sends CURSOR_SHAPE / CURSOR_IMAGE, the Viewer draws its local pointer in
    /// that shape. Announced whenever the build supports it; the Host's switch travels as `CursorShape.off`.
    public static let cursorShape = PeerCapabilities(rawValue: 1 << 3)

    /// Features that use the side stream: the Viewer opens it at an ACCEPT when both sides share at least one.
    public static let sideStreamFeatures: PeerCapabilities = [.clipboard, .cursorShape]

    /// "SDC1".
    public static let marker = Data([0x53, 0x44, 0x43, 0x31])
    /// Size of both carrier fields (AUTH nonce, ACCEPT session token).
    public static let carrierSize = 16

    /// A 16-byte value announcing `capabilities`: marker, flags, then the first 11 bytes of `random` (zero-padded).
    public static func carrier(_ capabilities: PeerCapabilities, random: Data) -> Data {
        var value = marker
        value.append(capabilities.rawValue)
        value.append(contentsOf: random.prefix(carrierSize - value.count))
        if value.count < carrierSize { value.append(Data(count: carrierSize - value.count)) }
        return value
    }

    /// Capabilities announced in a 16-byte carrier; empty without the marker (older peers) or at any other size.
    public static func announced(in carrier: Data) -> PeerCapabilities {
        guard carrier.count == carrierSize, carrier.prefix(marker.count).elementsEqual(marker) else { return [] }
        return PeerCapabilities(rawValue: carrier[carrier.startIndex + marker.count])
    }
}

extension Accept {
    /// A session token announcing the Host's capabilities: marker, flags, then 11 random bytes. The token is only
    /// length-checked by every Viewer version (its 88 random bits still make it unique per session).
    public static func sessionToken(capabilities: PeerCapabilities, random: Data) -> Data {
        PeerCapabilities.carrier(capabilities, random: random)
    }

    /// Capabilities the Host announced; empty for a token without the marker (0.1.x Hosts).
    public var capabilities: PeerCapabilities { PeerCapabilities.announced(in: sessionToken) }
}
