import AppKit
import Foundation
import ImageIO
import RenderCore
import UniformTypeIdentifiers
import WireProtocol

// Remote pointer shape (0.1.6): the pure rules (fingerprint, Host-side definition cache, Viewer-side state) apart from
// AppKit, so they are unit tested without a cursor or a window. `CursorShapeChannel` drives the Host side during a
// session; `ViewerSession` drives the Viewer side.

/// One rendition of the Host pointer: premultiplied RGBA, 8 bits per channel, rows top to bottom, plus its geometry
/// in points. Built by `CursorRendering.snapshot(image:hotSpot:)` from `NSCursor.currentSystem`.
public struct CursorSnapshot: Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// `pixelWidth × 4` bytes per row.
    public var rgba: Data
    /// The cursor's size on the Host, in points.
    public var pointSize: CGSize
    /// Hot spot in points from the top-left corner.
    public var hotSpot: CGPoint

    public init(pixelWidth: Int, pixelHeight: Int, rgba: Data, pointSize: CGSize, hotSpot: CGPoint) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rgba = rgba
        self.pointSize = pointSize
        self.hotSpot = hotSpot
    }

    /// Every pixel is fully transparent (some apps hide the pointer by setting an empty cursor).
    public var isFullyTransparent: Bool {
        rgba.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 3
            while index < bytes.count {
                if bytes[index] != 0 { return false }
                index += 4
            }
            return true
        }
    }

    /// 64-bit FNV-1a over the geometry and the pixels: equal shapes give equal values, so a shape seen before is
    /// recognised without comparing images. (A collision would show a wrong pointer shape, nothing worse.)
    public var fingerprint: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            var v = value
            for _ in 0..<8 {
                hash ^= v & 0xff
                hash = hash &* 0x0000_0100_0000_01b3
                v >>= 8
            }
        }
        mix(UInt64(pixelWidth))
        mix(UInt64(pixelHeight))
        mix(UInt64(Float(pointSize.width).bitPattern) << 32 | UInt64(Float(pointSize.height).bitPattern))
        mix(UInt64(Float(hotSpot.x).bitPattern) << 32 | UInt64(Float(hotSpot.y).bitPattern))
        rgba.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }
}

/// What the Host can tell about its pointer at one moment.
public enum CursorObservation: Sendable, Equatable {
    /// No shape available (`NSCursor.currentSystem` returned nil, or the image could not be rendered).
    case unavailable
    case hidden
    case image(CursorSnapshot)
}

/// Host side: turns pointer observations into the CURSOR_SHAPE / CURSOR_IMAGE traffic. Pure.
///
/// - A shape is identified by `CursorSnapshot.fingerprint`. The first time a shape is seen it gets the next id and is
///   defined (CURSOR_IMAGE through `define`); afterwards only its id is sent.
/// - The definitions are kept first-in first-out, `capacity` (`CursorImage.hostCacheSize`) of them: the oldest is
///   forgotten (a later sighting defines it again under a new id). The Viewer keeps at least as many in the same
///   order, so an id this side may name is always still known there (`docs/TRANSPORT.md`, "Remote pointer shape").
/// - A CURSOR_SHAPE is produced only when the shape differs from the last one sent.
/// - Without a way to define (`define == nil`: the side stream is not open yet) a new shape counts as `.unavailable`
///   for now and is defined on the first observation after it opened. A shape whose PNG could not be made (or does not
///   fit the limits) is `.unavailable`; it is not encoded again until the pointer changes.
public struct CursorShapeTracker: Sendable {
    public let capacity: Int
    public private(set) var lastSent: CursorShape?
    /// Fingerprint → id of every definition still referenced, and their order (oldest first).
    private var ids: [UInt64: UInt32] = [:]
    private var order: [UInt64] = []
    private var nextId: UInt32 = 1
    /// The last image observation and what it resolved to (skips the lookup while the pointer does not change).
    private var memo: (fingerprint: UInt64, shape: CursorShape)?

    public init(capacity: Int = CursorImage.hostCacheSize) {
        self.capacity = max(1, capacity)
    }

    /// Ids currently defined (tests, diagnostics).
    public var definedCount: Int { ids.count }

    /// - Parameters:
    ///   - encodePNG: PNG of a snapshot, called only for a shape that is about to be defined.
    ///   - define: sends a CURSOR_IMAGE; returns false if it could not be sent (the shape is then not cached). nil:
    ///     defining is not possible yet.
    /// - Returns: the CURSOR_SHAPE to send, or nil when it did not change.
    public mutating func observe(_ observation: CursorObservation, encodePNG: (CursorSnapshot) -> Data?,
                                 define: ((CursorImage) -> Bool)?) -> CursorShape? {
        send(resolve(observation, encodePNG: encodePNG, define: define))
    }

    /// The Host's switch went off: `.off` once.
    public mutating func switchedOff() -> CursorShape? {
        memo = nil
        return send(.off)
    }

    /// Forget what was sent last, so the next observation is announced even if unchanged (switch back on).
    public mutating func forgetLastSent() {
        lastSent = nil
        memo = nil
    }

    private mutating func send(_ shape: CursorShape) -> CursorShape? {
        guard shape != lastSent else { return nil }
        lastSent = shape
        return shape
    }

    private mutating func resolve(_ observation: CursorObservation, encodePNG: (CursorSnapshot) -> Data?,
                                  define: ((CursorImage) -> Bool)?) -> CursorShape {
        guard case .image(let snapshot) = observation else {
            memo = nil
            return observation == .hidden ? .hidden : .unavailable
        }
        let fingerprint = snapshot.fingerprint
        if let memo, memo.fingerprint == fingerprint { return memo.shape }
        if snapshot.isFullyTransparent {
            memo = (fingerprint, .hidden)
            return .hidden
        }
        if let id = ids[fingerprint] {
            memo = (fingerprint, .image(id: id))
            return .image(id: id)
        }
        guard let define else { return .unavailable }   // not memoized: defined once the side stream is open
        guard let png = encodePNG(snapshot), let image = Self.image(snapshot, id: nextId, png: png) else {
            memo = (fingerprint, .unavailable)
            return .unavailable
        }
        guard define(image) else { return .unavailable }
        let id = nextId
        nextId = nextId == .max ? 1 : nextId + 1
        ids[fingerprint] = id
        order.append(fingerprint)
        if order.count > capacity { ids[order.removeFirst()] = nil }
        memo = (fingerprint, .image(id: id))
        return .image(id: id)
    }

    /// The CURSOR_IMAGE for a snapshot, or nil if it would break the wire limits.
    static func image(_ snapshot: CursorSnapshot, id: UInt32, png: Data) -> CursorImage? {
        guard (1...CursorImage.maxPixelSize).contains(snapshot.pixelWidth),
              (1...CursorImage.maxPixelSize).contains(snapshot.pixelHeight) else { return nil }
        let pointWidth = Float(snapshot.pointSize.width)
        let pointHeight = Float(snapshot.pointSize.height)
        let image = CursorImage(id: id, pixelWidth: UInt16(snapshot.pixelWidth), pixelHeight: UInt16(snapshot.pixelHeight),
                                pointWidth: pointWidth, pointHeight: pointHeight,
                                hotSpotX: min(max(Float(snapshot.hotSpot.x), 0), pointWidth),
                                hotSpotY: min(max(Float(snapshot.hotSpot.y), 0), pointHeight), png: png)
        return image.isWellFormed ? image : nil
    }
}

/// Viewer side: which pointer to draw, from CURSOR_IMAGE definitions and CURSOR_SHAPE updates. Pure; `Image` is
/// whatever the definitions decode to (`RemotePointerImage` in the app, anything in tests).
///
/// Definitions are kept first-in first-out, `capacity` (`CursorImage.viewerCacheSize`, twice the Host's) of them.
/// A CURSOR_SHAPE naming an id not defined yet (its CURSOR_IMAGE is still on the side stream) keeps the previous
/// pointer until the definition arrives; a later CURSOR_SHAPE replaces that wait.
public struct RemoteCursorState<Image> {
    public enum Appearance {
        /// The Viewer's standard arrow (no shape yet, an older Host, unavailable, or off on the Host).
        case standard
        case hidden
        case image(id: UInt32, Image)
    }

    public let capacity: Int
    /// The latest CURSOR_SHAPE (nil before the first).
    public private(set) var shape: CursorShape?
    public private(set) var appearance: Appearance = .standard
    private var images: [UInt32: Image] = [:]
    private var order: [UInt32] = []

    public init(capacity: Int = CursorImage.viewerCacheSize) {
        self.capacity = max(1, capacity)
    }

    public var definedCount: Int { images.count }

    /// A CURSOR_IMAGE arrived. Returns true when the pointer to draw changed (it was waiting for this id).
    @discardableResult
    public mutating func define(id: UInt32, image: Image) -> Bool {
        if images.updateValue(image, forKey: id) == nil {
            order.append(id)
            if order.count > capacity { images[order.removeFirst()] = nil }
        }
        guard shape == .image(id: id) else { return false }
        appearance = .image(id: id, image)
        return true
    }

    /// A CURSOR_SHAPE arrived. Returns true when the pointer to draw changed.
    @discardableResult
    public mutating func apply(_ newShape: CursorShape) -> Bool {
        shape = newShape
        let before = key
        switch newShape {
        case .unavailable, .off:
            appearance = .standard
        case .hidden:
            appearance = .hidden
        case .image(let id):
            if let image = images[id] { appearance = .image(id: id, image) }
            // else: keep the current pointer until the definition arrives
        }
        return key != before
    }

    /// The shape names an id whose definition has not arrived.
    public var isWaitingForDefinition: Bool {
        if case .image(let id)? = shape { return images[id] == nil }
        return false
    }

    private enum Key: Equatable { case standard, hidden, image(UInt32) }

    private var key: Key {
        switch appearance {
        case .standard: .standard
        case .hidden: .hidden
        case .image(let id, _): .image(id)
        }
    }
}

/// AppKit / ImageIO helpers: render the Host pointer, PNG-encode it, decode it on the Viewer.
public enum CursorRendering {
    /// Renditions are at most this many pixels per point (Retina).
    public static let maxPixelsPerPoint: CGFloat = 2

    /// The pointer rendered at up to 2× (never more than `CursorImage.maxPixelSize` per side); nil for an empty or
    /// absurd image. AppKit picks the best representation for the pixel size.
    @MainActor
    public static func snapshot(image: NSImage, hotSpot: NSPoint) -> CursorSnapshot? {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= CGFloat(CursorImage.maxPointSize), size.height <= CGFloat(CursorImage.maxPointSize)
        else { return nil }
        let scale = min(maxPixelsPerPoint, CGFloat(CursorImage.maxPixelSize) / max(size.width, size.height))
        let width = min(CursorImage.maxPixelSize, max(1, Int((size.width * scale).rounded())))
        let height = min(CursorImage.maxPixelSize, max(1, Int((size.height * scale).rounded())))
        let bytesPerRow = width * 4
        var rgba = Data(count: bytesPerRow * height)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
            return true
        }
        guard drawn else { return nil }
        return CursorSnapshot(pixelWidth: width, pixelHeight: height, rgba: rgba, pointSize: size,
                              hotSpot: CGPoint(x: hotSpot.x, y: hotSpot.y))
    }

    /// A CGImage over the snapshot's pixels.
    public static func cgImage(_ snapshot: CursorSnapshot) -> CGImage? {
        guard snapshot.pixelWidth > 0, snapshot.pixelHeight > 0,
              snapshot.rgba.count == snapshot.pixelWidth * snapshot.pixelHeight * 4,
              let provider = CGDataProvider(data: snapshot.rgba as CFData) else { return nil }
        return CGImage(width: snapshot.pixelWidth, height: snapshot.pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: snapshot.pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG of the snapshot; nil if ImageIO fails or the result exceeds `CursorImage.maxPNGBytes`.
    public static func png(_ snapshot: CursorSnapshot) -> Data? {
        guard let image = cgImage(snapshot) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= CursorImage.maxPNGBytes else { return nil }
        return data as Data
    }

    /// The Viewer's pointer image for a definition: the PNG decoded, checked against the announced pixel size.
    public static func pointerImage(_ image: CursorImage) -> RemotePointerImage? {
        guard image.isWellFormed,
              let source = CGImageSourceCreateWithData(image.png as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary),
              decoded.width == Int(image.pixelWidth), decoded.height == Int(image.pixelHeight) else { return nil }
        return RemotePointerImage(id: image.id, image: decoded,
                                  pointSize: CGSize(width: CGFloat(image.pointWidth), height: CGFloat(image.pointHeight)),
                                  hotSpot: CGPoint(x: CGFloat(image.hotSpotX), y: CGFloat(image.hotSpotY)))
    }
}

/// Where the Host reads its pointer from. Main actor (AppKit).
@MainActor
public protocol CursorSource: AnyObject {
    func observe() -> CursorObservation
}

/// The system pointer: `NSCursor.currentSystem`, the only public API that returns the cursor another app set
/// (ScreenCaptureKit can only draw it into the frames, which SwiftDesk does not do: the Viewer draws its own pointer).
/// Apple notes it "will always be nil in a future version of macOS"; then every observation is `.unavailable` and the
/// Viewer keeps its standard arrow. A hidden pointer is detected from `CGCursorIsVisible()` (a public CoreGraphics
/// call, deprecated without replacement, looked up at run time so the build stays warning-free; when it is missing it
/// is not used) and from a fully transparent cursor image.
@MainActor
public final class SystemCursorSource: CursorSource {
    private typealias VisibleFunction = @convention(c) () -> Int32
    private static let cursorIsVisible: VisibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: VisibleFunction.self)
    }()

    public init() {}

    public func observe() -> CursorObservation {
        if let visible = Self.cursorIsVisible, visible() == 0 { return .hidden }
        guard let cursor = NSCursor.currentSystem,
              let snapshot = CursorRendering.snapshot(image: cursor.image, hotSpot: cursor.hotSpot) else { return .unavailable }
        return .image(snapshot)
    }
}
