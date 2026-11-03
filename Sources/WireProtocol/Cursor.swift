import Foundation

/// 0.1.6 remote pointer shape. The Viewer keeps drawing its own local pointer (instant feedback; the Host's cursor is
/// excluded from the captured video), but in the *shape* the Host's pointer has right now: I-beam, resize arrows,
/// pointing hand, an app's custom cursor, or none at all.
///
/// Two messages, both Host → Viewer and only when both sides announced `PeerCapabilities.cursorShape`:
/// - CURSOR_IMAGE (21, **side stream only**: it carries a PNG) defines one shape under a small id, once;
/// - CURSOR_SHAPE (22, control stream, 5 bytes) says which shape is current: a defined id, hidden, unknown, or
///   switched off on the Host. A shape seen before costs only this message.
///
/// The two streams are not ordered with respect to each other, so a CURSOR_SHAPE may name an id whose CURSOR_IMAGE is
/// still on its way; the Viewer keeps the previous pointer until it arrives. Ids are assigned by the Host from 1
/// upwards and never reused within a connection; the Host references only its `CursorImage.hostCacheSize` most recent
/// definitions, the Viewer keeps at least `CursorImage.viewerCacheSize` (twice as many), so a definition that overtakes
/// a CURSOR_SHAPE cannot evict the id it names.
///
/// Payload: `u32 id, u16 pixelWidth, u16 pixelHeight, f32 pointWidth, f32 pointHeight, f32 hotSpotX, f32 hotSpotY,
/// u32 pngLength, png`. Points are the cursor's size on the Host (its `NSImage.size`); the pixels are a rendition at
/// up to 2× (Retina), never larger than 256 × 256. The hot spot is in points from the top-left corner. Strict on
/// decode like every other message: `id ≠ 0`, `1 ≤ pixel size ≤ 256`, `0 < point size ≤ 512`, hot spot inside the
/// point size, `1 ≤ pngLength ≤ maxPNGBytes` (checked before reading), PNG signature, no trailing bytes. Senders check
/// `isWellFormed` first: a malformed CURSOR_IMAGE closes the connection.
public struct CursorImage: Sendable, Equatable {
    /// Largest rendition the Host sends, per side (RGBA, so ≤ 256 KiB before PNG compression).
    public static let maxPixelSize = 256
    /// Largest point size accepted (an enlarged accessibility pointer stays well below it).
    public static let maxPointSize: Float = 512
    /// Largest PNG: an incompressible 256 × 256 RGBA image plus PNG/zlib overhead fits.
    public static let maxPNGBytes = 320 * 1024
    /// Header bytes in front of the PNG.
    public static let headerSize = 28
    /// Largest possible payload.
    public static let maxPayloadBytes = headerSize + maxPNGBytes
    /// Definitions the Host may still reference (its most recent ones).
    public static let hostCacheSize = 32
    /// Definitions the Viewer keeps (most recent first out last), at least twice `hostCacheSize`.
    public static let viewerCacheSize = 64
    /// The 8-byte PNG file signature.
    public static let pngSignature = ClipboardContent.pngSignature

    public var id: UInt32
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16
    public var pointWidth: Float
    public var pointHeight: Float
    public var hotSpotX: Float
    public var hotSpotY: Float
    public var png: Data

    public init(id: UInt32, pixelWidth: UInt16, pixelHeight: UInt16, pointWidth: Float, pointHeight: Float,
                hotSpotX: Float, hotSpotY: Float, png: Data) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.png = png
    }

    /// True when a peer would accept this image (same rules as the decoder).
    public var isWellFormed: Bool { (try? validate()) != nil }

    func validate() throws {
        guard id != 0 else { throw WireError.malformed("cursor id 0") }
        let pixels = 1...UInt16(Self.maxPixelSize)
        guard pixels.contains(pixelWidth), pixels.contains(pixelHeight) else {
            throw WireError.malformed("cursor pixel size")
        }
        for value in [pointWidth, pointHeight] {
            guard value.isFinite, value > 0, value <= Self.maxPointSize else { throw WireError.malformed("cursor point size") }
        }
        guard hotSpotX.isFinite, hotSpotY.isFinite, (0...pointWidth).contains(hotSpotX),
              (0...pointHeight).contains(hotSpotY) else { throw WireError.malformed("cursor hot spot") }
        guard (1...Self.maxPNGBytes).contains(png.count) else { throw WireError.oversized }
        guard png.starts(with: Self.pngSignature) else { throw WireError.malformed("cursor image is not PNG") }
    }

    func encode(into w: inout ByteWriter) {
        w.u32(id)
        w.u16(pixelWidth)
        w.u16(pixelHeight)
        w.finiteF32(pointWidth)
        w.finiteF32(pointHeight)
        w.finiteF32(hotSpotX)
        w.finiteF32(hotSpotY)
        w.u32(UInt32(truncatingIfNeeded: png.count))
        w.bytes(png)
    }

    static func decode(from r: inout ByteReader) throws -> CursorImage {
        let id = try r.u32()
        let pixelWidth = try r.u16()
        let pixelHeight = try r.u16()
        let pointWidth = try r.finiteF32()
        let pointHeight = try r.finiteF32()
        let hotSpotX = try r.finiteF32()
        let hotSpotY = try r.finiteF32()
        let length = Int(try r.u32())
        // Checked before reading, so a hostile length never makes the reader copy anything.
        guard length <= maxPNGBytes else { throw WireError.oversized }
        let image = CursorImage(id: id, pixelWidth: pixelWidth, pixelHeight: pixelHeight, pointWidth: pointWidth,
                                pointHeight: pointHeight, hotSpotX: hotSpotX, hotSpotY: hotSpotY,
                                png: try r.bytes(count: length))
        try image.validate()
        return image
    }
}

/// 0.1.6. CURSOR_SHAPE (22), control stream, Host → Viewer: the Host pointer's current shape. Sent when it changes
/// (sampled ≈ 30 times a second during a session), once right after the session starts, and when the Host's switch
/// changes. Payload: `u8 kind, u32 id` — kind 0 unavailable, 1 hidden, 2 image (`id` names a CURSOR_IMAGE, ≠ 0),
/// 3 off; `id` must be 0 for every kind but 2.
public enum CursorShape: Sendable, Equatable, Hashable {
    /// The Host cannot tell its pointer's shape (or it could not be encoded): the Viewer shows its standard arrow.
    case unavailable
    /// The Host's pointer is hidden (e.g. while typing, or in a full-screen video or game).
    case hidden
    /// The shape defined by the CURSOR_IMAGE with this id.
    case image(id: UInt32)
    /// The Host operator switched pointer-shape sharing off: the Viewer shows its standard arrow.
    case off

    enum Kind: UInt8 {
        case unavailable = 0, hidden = 1, image = 2, off = 3
    }

    var kind: Kind {
        switch self {
        case .unavailable: .unavailable
        case .hidden: .hidden
        case .image: .image
        case .off: .off
        }
    }

    var id: UInt32 {
        if case .image(let id) = self { id } else { 0 }
    }

    func encode(into w: inout ByteWriter) {
        w.u8(kind.rawValue)
        w.u32(id)
    }

    static func decode(from r: inout ByteReader) throws -> CursorShape {
        let kind = try r.enumValue(Kind.self, "cursor shape kind")
        let id = try r.u32()
        switch kind {
        case .image:
            guard id != 0 else { throw WireError.malformed("cursor image id 0") }
            return .image(id: id)
        case .unavailable, .hidden, .off:
            guard id == 0 else { throw WireError.malformed("cursor id without image") }
            return kind == .hidden ? .hidden : kind == .off ? .off : .unavailable
        }
    }
}
