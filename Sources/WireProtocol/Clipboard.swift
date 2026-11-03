import Foundation

/// 0.1.5 clipboard sharing. One copied clipboard, as a few representations of the same content (plain text, RTF, PNG,
/// URL), sent whole in one CLIPBOARD message on the **side stream** (never on the control stream: an image there would
/// hold up input events; see `docs/TRANSPORT.md`, "Side stream").
///
/// Payload: `u8 count (1…4)`, then `count ×` `{ u8 kind, u32 length, length bytes }`. Strict on decode, like every
/// other message: a kind at most once, `1 ≤ length ≤ limit(for: kind)`, text and URL valid UTF-8, PNG data starting
/// with the PNG signature, no trailing bytes. Senders must check `isWellFormed` before sending: a peer that receives
/// a malformed CLIPBOARD closes the connection.
public struct ClipboardContent: Sendable, Equatable {
    public enum Kind: UInt8, Sendable, CaseIterable, Comparable {
        /// UTF-8 text (`public.utf8-plain-text`).
        case plainText = 1
        /// RTF document data (`public.rtf`).
        case richText = 2
        /// PNG image data (`public.png`); TIFF on the pasteboard is converted to PNG before sending.
        case png = 3
        /// A URL as UTF-8 (`public.url`).
        case url = 4

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Item: Sendable, Equatable {
        public var kind: Kind
        public var data: Data

        public init(kind: Kind, data: Data) {
            self.kind = kind
            self.data = data
        }
    }

    /// Largest plain-text, RTF or URL representation (1 MiB each).
    public static let maxTextBytes = 1 << 20
    /// Largest PNG (16 MiB, measured after encoding).
    public static let maxImageBytes = 16 << 20
    public static let maxItems = Kind.allCases.count
    /// The 8-byte PNG file signature.
    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// Largest possible payload: every representation at its limit plus the item headers.
    public static let maxPayloadBytes = 1 + maxItems * 5 + 3 * maxTextBytes + maxImageBytes

    public static func limit(for kind: Kind) -> Int {
        kind == .png ? maxImageBytes : maxTextBytes
    }

    /// At most one item per kind, kept in kind order.
    public private(set) var items: [Item]

    public init(items: [Item]) {
        self.items = items.sorted { $0.kind < $1.kind }
    }

    public func data(for kind: Kind) -> Data? {
        items.first { $0.kind == kind }?.data
    }

    public var kinds: [Kind] { items.map(\.kind) }
    public var totalBytes: Int { items.reduce(0) { $0 + $1.data.count } }
    public var isEmpty: Bool { items.isEmpty }

    /// True when a peer would accept this content (same rules as the decoder).
    public var isWellFormed: Bool {
        guard (1...Self.maxItems).contains(items.count), Set(kinds).count == items.count else { return false }
        return items.allSatisfy { Self.isValid($0) }
    }

    static func isValid(_ item: Item) -> Bool {
        guard (1...limit(for: item.kind)).contains(item.data.count) else { return false }
        switch item.kind {
        case .plainText, .url:
            return String(validating: item.data, as: UTF8.self) != nil
        case .png:
            return item.data.starts(with: pngSignature)
        case .richText:
            return true
        }
    }

    func encode(into w: inout ByteWriter) {
        w.u8(UInt8(truncatingIfNeeded: items.count))
        for item in items {
            w.u8(item.kind.rawValue)
            w.u32(UInt32(truncatingIfNeeded: item.data.count))
            w.bytes(item.data)
        }
    }

    static func decode(from r: inout ByteReader) throws -> ClipboardContent {
        let count = Int(try r.u8())
        guard (1...maxItems).contains(count) else { throw WireError.malformed("clipboard item count \(count)") }
        var items: [Item] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            let kind = try r.enumValue(Kind.self, "clipboard kind")
            guard !items.contains(where: { $0.kind == kind }) else { throw WireError.malformed("duplicate clipboard kind") }
            let length = Int(try r.u32())
            // Checked before reading, so a hostile length never makes the reader copy anything.
            guard length <= limit(for: kind) else { throw WireError.oversized }
            let item = Item(kind: kind, data: try r.bytes(count: length))
            guard isValid(item) else { throw WireError.malformed("invalid clipboard \(kind)") }
            items.append(item)
        }
        return ClipboardContent(items: items)
    }
}

/// 0.1.5. Whether the sender currently shares its clipboard (sends its copies and accepts the peer's). Sent on the
/// control stream by each side right after the session starts and again whenever its setting changes; clipboard
/// data flows only while both sides say `enabled`. Payload: `u8 flags`, bit 0 = enabled, other bits must be 0.
public struct ClipboardState: Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    var flags: UInt8 { enabled ? 1 : 0 }

    init(flags: UInt8) throws {
        guard flags & ~1 == 0 else { throw WireError.malformed("reserved clipboard state bits") }
        enabled = flags & 1 != 0
    }
}

extension ControlMessageType {
    /// True for message types that travel only on the side stream (bulk payloads); every other type only on the
    /// control stream. The transport closes the connection when a type arrives on the wrong stream.
    public var isSideStream: Bool { self == .clipboard || self == .cursorImage }
}
