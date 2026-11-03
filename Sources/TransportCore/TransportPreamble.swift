import Foundation
import WireProtocol

/// 8-byte transport handshake exchanged at the very start of the control stream, before any framed
/// `ControlMessage`: `"SDQ1"` magic, preamble version, sender role, stream kind, one reserved zero byte.
///
/// Byte 6 was "reserved (0)" before 0.1.5 and still is 0 on the control stream, so the control preamble is
/// byte-identical to every earlier version. 0.1.5 uses 1 for the Viewer-opened **side stream** (bulk payloads such as
/// clipboard data), which is only ever opened to a Host that announced a feature using it (`PeerCapabilities`).
///
/// Why it exists (validated in QUICSpike): with TLS 1.3 the client finishes its handshake one flight *before* the
/// server has verified the client certificate, and opening a QUIC stream or datagram flow is purely local. So
/// without a host-originated byte the viewer would report `.ready` even when the host rejected its certificate,
/// rate-limited it, or is not running SwiftDesk at all. The host's reply proves the host accepted the connection.
/// It also lets the host identify the control stream immediately (a QUIC stream is invisible to the peer until
/// it carries data) instead of waiting for the session layer's first message.
enum TransportPreamble {
    static let size = 8
    static let magic: [UInt8] = [0x53, 0x44, 0x51, 0x31]   // "SDQ1"
    static let version: UInt8 = 1

    enum Role: UInt8 {
        case viewer = 1
        case host = 2
    }

    /// Byte 6: which stream this preamble opens.
    enum Kind: UInt8 {
        case control = 0
        /// 0.1.5: the side stream for bulk payloads (Viewer → Host only; the Host does not answer it).
        case side = 1
    }

    static func encode(role: Role, kind: Kind = .control) -> Data {
        Data(magic + [version, role.rawValue, kind.rawValue, 0])
    }

    /// Validates exactly `size` bytes sent by a peer expected to have `role`, opening a stream of `kind`.
    static func validate(_ bytes: Data, expectedRole role: Role, kind: Kind = .control) throws(WireError) {
        guard bytes.count == size else { throw .truncated }
        let b = Array(bytes)
        guard Array(b[0..<4]) == magic else { throw .badMagic }
        guard b[4] == version else { throw .unsupportedVersion(b[4]) }
        guard b[5] == role.rawValue else { throw .malformed("unexpected preamble role \(b[5])") }
        guard b[6] == kind.rawValue else { throw .malformed("unexpected preamble stream kind \(b[6])") }
        guard b[7] == 0 else { throw .malformed("non-zero preamble reserved byte") }
    }

    /// The stream kind a viewer preamble announces, or nil if `bytes` is not a valid viewer preamble at all.
    static func viewerKind(_ bytes: Data) -> Kind? {
        guard bytes.count == size, let kind = Kind(rawValue: bytes[bytes.startIndex + 6]),
              (try? validate(bytes, expectedRole: .viewer, kind: kind)) != nil else { return nil }
        return kind
    }
}
