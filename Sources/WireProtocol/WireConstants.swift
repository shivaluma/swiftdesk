import Foundation

/// Protocol-wide constants shared by Host and Viewer.
///
/// Every limit here exists to bound memory and CPU per message: the receive paths treat any peer input as
/// potentially hostile, so sizes are checked against these values before anything is allocated.
public enum WireConstants {
    public static let protocolVersion: UInt16 = 1
    public static let alpn = "swiftdesk/1"
    public static let defaultPort: UInt16 = 47800
    public static let bonjourServiceType = "_swiftdesk._udp"
    /// Whole datagram including the header. Stays below Tailscale's 1280-byte MTU after QUIC/UDP/IP overhead
    /// so video fragments are never IP-fragmented (a lost IP fragment loses the whole datagram).
    public static let defaultMaxDatagramSize = 1150
    public static let maxControlMessageSize = 64 * 1024
    /// 0.1.5: largest message on the side stream (one CLIPBOARD: every representation at its limit, ≈ 19 MiB; a
    /// 0.1.6 CURSOR_IMAGE is at most ≈ 320 KiB).
    public static let maxSideStreamMessageSize = 1 + max(ClipboardContent.maxPayloadBytes, CursorImage.maxPayloadBytes)
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxPacketsPerFrame = 4096
    public static let maxStringBytes = 256

    /// First byte of a video fragment datagram (`'V'`).
    public static let videoMagic: UInt8 = 0x56
    /// First byte of a pointer-state datagram (`'P'`).
    public static let pointerMagic: UInt8 = 0x50
    /// First byte of an FEC parity datagram (`'F'`). Receivers without FEC support reject it as `badMagic`.
    public static let parityMagic: UInt8 = 0x46
    /// Datagram format version carried in byte 1 of every datagram.
    public static let datagramVersion: UInt8 = 1
    /// Size of the length prefix in front of every control message on the stream.
    public static let controlLengthPrefixSize = 4
}

/// Errors raised while decoding peer input.
///
/// Decoding never traps: every malformed, truncated or oversized input surfaces as one of these so the transport
/// can drop the datagram or tear down the control stream deliberately.
public enum WireError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case oversized
    case malformed(String)
}
