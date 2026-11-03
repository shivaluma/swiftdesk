import CoreGraphics

/// One key transition of a synthesized key press: what the Viewer turns into a KEY_DOWN or KEY_UP.
public struct KeyStroke: Sendable, Equatable {
    public var keyCode: UInt16
    public var isDown: Bool
    /// `CGEventFlags` raw value the event carries: the flag word *after* this transition, as hardware reports it.
    public var flags: UInt64

    public init(keyCode: UInt16, isDown: Bool, flags: UInt64) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.flags = flags
    }
}

/// A key with modifiers, pressed and released once, the way a person types a shortcut.
///
/// Sent as plain KEY_DOWN / KEY_UP through the normal input path, so it needs nothing new on the wire and works with
/// every Host version: the Host posts them at the HID event tap (`CGEventPoster`), where they enter the event system
/// exactly like hardware events, so the WindowServer's system shortcuts (⌘Tab, Spotlight, Mission Control,
/// screenshots …) trigger on the Host as they would from its own keyboard.
public struct KeyChord: Sendable, Equatable, Hashable {
    public var keyCode: UInt16
    /// Modifier virtual key codes (`ModifierKeys.command` …), pressed in this order and released in reverse.
    public var modifiers: [UInt16]

    public init(keyCode: UInt16, modifiers: [UInt16] = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Modifiers down (each adding its flag and its left/right device flag), the key down and up (with every modifier
    /// flag plus the key's intrinsic fn / keypad flags), then the modifiers up in reverse order, each clearing its own
    /// flags. Ends with no momentary flag set, so nothing can stay held on the Host.
    public var strokes: [KeyStroke] {
        var out: [KeyStroke] = []
        out.reserveCapacity(modifiers.count * 2 + 2)
        var flags: UInt64 = 0
        for modifier in modifiers {
            flags |= ModifierKeys.flag(forKeyCode: modifier) ?? 0
            flags |= ModifierKeys.deviceFlag(forKeyCode: modifier) ?? 0
            out.append(KeyStroke(keyCode: modifier, isDown: true, flags: flags))
        }
        let keyFlags = flags | ModifierKeys.intrinsicFlags(forKeyCode: keyCode)
        out.append(KeyStroke(keyCode: keyCode, isDown: true, flags: keyFlags))
        out.append(KeyStroke(keyCode: keyCode, isDown: false, flags: keyFlags))
        for modifier in modifiers.reversed() {
            flags = ModifierKeys.flags(flags, releasing: modifier)
            out.append(KeyStroke(keyCode: modifier, isDown: false, flags: flags))
        }
        return out
    }

    /// "⌃⌘Q", "⇧⌘3", "⌘Tab": modifier symbols in Apple's order (⌃ ⌥ ⇧ ⌘), then the key's name.
    public var symbols: String {
        let order: [(UInt16, String)] = [(ModifierKeys.control, "⌃"), (ModifierKeys.option, "⌥"),
                                         (ModifierKeys.shift, "⇧"), (ModifierKeys.command, "⌘")]
        let flags = Set(modifiers.compactMap(ModifierKeys.flag(forKeyCode:)))
        let prefix = order.filter { flags.contains(ModifierKeys.flag(forKeyCode: $0.0) ?? 0) }.map(\.1).joined()
        return prefix + SystemShortcut.keyName(keyCode)
    }
}

/// The macOS system shortcuts offered by the Viewer's "Send Keys" menu. Without "Send system shortcuts" these never
/// reach SwiftDesk (the Viewer Mac's WindowServer acts on them first), so the menu is the only way to send them.
///
/// The chords are the macOS defaults (System Settings › Keyboard › Keyboard Shortcuts). A Host whose user changed
/// or turned off a shortcut there does not react to the default chord; Launchpad has no default chord at all and is
/// sent as the dedicated Launchpad key of Apple keyboards (key code 131), which opens Apps on macOS 26 and later.
public enum SystemShortcut: String, CaseIterable, Sendable, Identifiable, Hashable {
    case appSwitcher
    case spotlight
    case emojiAndSymbols
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case screenshotScreen
    case screenshotSelection
    case screenshotOptions
    case forceQuit
    case lockScreen

    /// Menu sections, in menu order.
    public enum Group: CaseIterable, Sendable {
        case apps, windows, screenshots, system
    }

    public var id: String { rawValue }

    public var group: Group {
        switch self {
        case .appSwitcher, .spotlight, .emojiAndSymbols: .apps
        case .missionControl, .appExpose, .showDesktop, .launchpad: .windows
        case .screenshotScreen, .screenshotSelection, .screenshotOptions: .screenshots
        case .forceQuit, .lockScreen: .system
        }
    }

    public static func shortcuts(in group: Group) -> [SystemShortcut] {
        allCases.filter { $0.group == group }
    }

    public var title: String {
        switch self {
        case .appSwitcher: "App Switcher"
        case .spotlight: "Spotlight"
        case .emojiAndSymbols: "Emoji & Symbols"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .launchpad: "Launchpad / Apps"
        case .screenshotScreen: "Screenshot of Entire Screen"
        case .screenshotSelection: "Screenshot of Selection"
        case .screenshotOptions: "Screenshot & Recording Options"
        case .forceQuit: "Force Quit Applications…"
        case .lockScreen: "Lock Screen"
        }
    }

    public var chord: KeyChord {
        switch self {
        case .appSwitcher: KeyChord(keyCode: Self.tab, modifiers: [ModifierKeys.command])
        case .spotlight: KeyChord(keyCode: Self.space, modifiers: [ModifierKeys.command])
        case .emojiAndSymbols: KeyChord(keyCode: Self.space, modifiers: [ModifierKeys.control, ModifierKeys.command])
        case .missionControl: KeyChord(keyCode: Self.upArrow, modifiers: [ModifierKeys.control])
        case .appExpose: KeyChord(keyCode: Self.downArrow, modifiers: [ModifierKeys.control])
        case .showDesktop: KeyChord(keyCode: Self.f11)
        case .launchpad: KeyChord(keyCode: Self.launchpadKey)
        case .screenshotScreen: KeyChord(keyCode: Self.digit3, modifiers: [ModifierKeys.shift, ModifierKeys.command])
        case .screenshotSelection: KeyChord(keyCode: Self.digit4, modifiers: [ModifierKeys.shift, ModifierKeys.command])
        case .screenshotOptions: KeyChord(keyCode: Self.digit5, modifiers: [ModifierKeys.shift, ModifierKeys.command])
        case .forceQuit: KeyChord(keyCode: ModifierKeys.escape, modifiers: [ModifierKeys.option, ModifierKeys.command])
        case .lockScreen: KeyChord(keyCode: Self.q, modifiers: [ModifierKeys.control, ModifierKeys.command])
        }
    }

    /// The keys, for menus and tooltips ("⌥⌘Esc").
    public var keysDescription: String { chord.symbols }

    /// Locking the Host is easy to send and hard to undo remotely: SwiftDesk cannot type into the lock screen
    /// (secure input), so someone at the Host has to unlock it. The UI asks first.
    public var needsConfirmation: Bool { self == .lockScreen }

    // MARK: Key codes (kVK_* from Carbon HIToolbox Events.h)

    static let q: UInt16 = 0x0C
    static let digit3: UInt16 = 0x14
    static let digit4: UInt16 = 0x15
    static let digit5: UInt16 = 0x17
    static let tab: UInt16 = 0x30
    static let space: UInt16 = 0x31
    static let f11: UInt16 = 0x67
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E
    /// Apple keyboards' Launchpad key (F4 row). Not in Events.h; the value Apple's keyboards report.
    static let launchpadKey: UInt16 = 131

    static func keyName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case q: "Q"
        case digit3: "3"
        case digit4: "4"
        case digit5: "5"
        case tab: "Tab"
        case space: "Space"
        case ModifierKeys.escape: "Esc"
        case f11: "F11"
        case downArrow: "↓"
        case upArrow: "↑"
        case launchpadKey: "Launchpad key"
        default: "Key \(keyCode)"
        }
    }
}
