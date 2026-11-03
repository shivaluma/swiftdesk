import AppKit
import CoreGraphics

/// A physical display as the Host sees it.
///
/// Carries both coordinate systems explicitly because macOS points are not Retina pixels: `frame` (points, global
/// CoreGraphics space, origin top-left of the main display) is what input injection maps into, while
/// `pixelWidth`/`pixelHeight` (the current mode's backing resolution) drive capture sizing.
public struct DisplayInfo: Sendable, Identifiable, Hashable {
    public var id: CGDirectDisplayID
    public var name: String
    /// Global display coordinates in points (`CGDisplayBounds`).
    public var frame: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: CGDirectDisplayID, name: String, frame: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.name = name
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Display size in points.
    public var pointSize: CGSize { frame.size }

    /// Backing pixels per point (2.0 on a typical Retina mode, 1.0 on a standard display). 1 if unknown.
    public var backingScale: Double {
        frame.width > 0 && pixelWidth > 0 ? Double(pixelWidth) / Double(frame.width) : 1
    }

    // CGRect is not Hashable in every SDK, so hashing is spelled out field by field.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.size.width)
        hasher.combine(frame.size.height)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
    }

    public static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.frame == rhs.frame
            && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
    }
}

// MARK: - CoreGraphics enumeration (no Screen Recording permission required)

extension DisplayInfo {
    /// IDs of every active (drawable) display, main display first. Uses CoreGraphics only, so it never
    /// triggers a Screen Recording prompt and is safe to call from any thread.
    ///
    /// When every display is asleep the active list is empty (measured: 0 active, 1 online), which would leave
    /// a Host that is set up while its screen sleeps with nothing to share. In that case the online displays
    /// that are not mirror copies of another display are returned instead; their bounds and modes stay valid
    /// while asleep, and the window server wakes them when capture starts.
    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var ids = displayList(CGGetActiveDisplayList)
        if ids.isEmpty {
            ids = displayList(CGGetOnlineDisplayList).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        }
        let main = CGMainDisplayID()
        if let index = ids.firstIndex(of: main), index != 0 {
            ids.remove(at: index)
            ids.insert(main, at: 0)
        }
        return ids
    }

    private static func displayList(
        _ query: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard query(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard query(count, &ids, &count) == .success else { return [] }
        ids.removeSubrange(Int(count)...)
        return ids
    }

    /// Current backing pixel size of a display's mode, or nil if the display is gone.
    /// Re-read at stream start and on reconfiguration because the user may change the resolution mid-session.
    public static func currentPixelSize(of id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        let width = mode.pixelWidth
        let height = mode.pixelHeight
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Builds a `DisplayInfo` from CoreGraphics for one display. `name` falls back to a generic label
    /// when nil. Returns nil if the display has no current mode (disconnected / asleep).
    public static func make(id: CGDirectDisplayID, name: String?) -> DisplayInfo? {
        guard let pixels = currentPixelSize(of: id) else { return nil }
        return DisplayInfo(id: id,
                           name: name ?? fallbackName(for: id),
                           frame: CGDisplayBounds(id),
                           pixelWidth: pixels.width,
                           pixelHeight: pixels.height)
    }

    /// Every active display, named with the supplied lookup (e.g. from `screenNames()`). Thread-safe.
    public static func activeDisplays(names: [CGDirectDisplayID: String]) -> [DisplayInfo] {
        activeDisplayIDs().compactMap { make(id: $0, name: names[$0]) }
    }

    /// Every active display with user-facing names from `NSScreen.localizedName`. Main actor because it
    /// reads AppKit screen state; not used on any hot path.
    @MainActor
    public static func activeDisplays() -> [DisplayInfo] {
        activeDisplays(names: screenNames())
    }

    /// `NSScreen.localizedName` keyed by display ID (`NSScreenNumber` in the device description).
    @MainActor
    public static func screenNames() -> [CGDirectDisplayID: String] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            let name = screen.localizedName
            if !name.isEmpty { names[number.uint32Value] = name }
        }
        return names
    }

    static func fallbackName(for id: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }
}
