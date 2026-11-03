import AppKit
import CoreGraphics
import Darwin

/// A keyboard event taken by the Viewer's shortcut tap, as plain values (no `CGEvent` leaves the tap callback).
public struct TapKeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case down, up, flagsChanged }

    public var kind: Kind
    public var keyCode: UInt16
    /// `CGEventFlags` raw value (same bit layout as `NSEvent.ModifierFlags`).
    public var flags: UInt64
    public var isRepeat: Bool

    public init(kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
    }
}

/// The decision the Viewer's keyboard tap makes for every event it sees. Pure, so every rule is unit-tested.
///
/// While **armed** (the "Send system shortcuts" switch is on, a session is streaming, input is captured and the stream
/// view has keyboard focus in the active app) the tap takes *every* key event, not only the system-reserved ones: the
/// ⌘ of ⌘Tab must reach the Host before its Tab, and one path for all keys keeps them in order. Everything the stream
/// view used to forward is forwarded exactly as before; the difference is what the Viewer Mac's WindowServer would
/// otherwise have consumed (⌘Tab, ⌘Space, Mission Control, ⌃-arrow Spaces, screenshots, ⌥⌘Esc, ⌃⌘Q …).
///
/// Never taken, so they keep working locally:
/// - anything while not armed (other apps, other windows, SwiftDesk's own screens): the tap swallows nothing outside
///   the session;
/// - the release shortcut ⌃⌥⎋, which goes to the stream view as before and ends capture (and with it the tap);
/// - events SwiftDesk posted itself (a Host session on the same Mac), so nothing can loop;
/// - keys while one of SwiftDesk's own menus or a drag is being tracked (the Send Keys menu must stay usable).
public enum SystemShortcutFilter {
    public enum Decision: Sendable, Equatable {
        /// Leave the event to macOS and the app (normal handling).
        case pass
        /// Swallow it and forward it to the Host.
        case forward
        /// macOS disabled the tap (callback too slow, or secure input): enable it again; the event itself passes.
        case reenable
    }

    public static func decide(type: CGEventType, keyCode: UInt16, flags: UInt64, armed: Bool,
                              postedByThisProcess: Bool = false, trackingLocalUI: Bool = false) -> Decision {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return armed ? .reenable : .pass
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return .pass
        }
        guard armed, !postedByThisProcess, !trackingLocalUI else { return .pass }
        if type == .keyDown,
           ViewerInputTranslator.isReleaseShortcut(keyCode: keyCode, flags: flags & ModifierKeys.forwardedMask) {
            return .pass
        }
        return .forward
    }

    /// The plain-value form of a key event, nil for any other type.
    public static func keyEvent(type: CGEventType, keyCode: UInt16, flags: UInt64, autorepeat: Bool) -> TapKeyEvent? {
        switch type {
        case .keyDown: TapKeyEvent(kind: .down, keyCode: keyCode, flags: flags, isRepeat: autorepeat)
        case .keyUp: TapKeyEvent(kind: .up, keyCode: keyCode, flags: flags)
        case .flagsChanged: TapKeyEvent(kind: .flagsChanged, keyCode: keyCode, flags: flags)
        default: nil
        }
    }
}

/// The installable part of the shortcut tap, so the session's arming rules can be tested without Accessibility.
@MainActor
public protocol SystemShortcutTapping: AnyObject {
    var isInstalled: Bool { get }
    /// Installs the tap; false when macOS refuses (no Accessibility permission). Idempotent.
    func install() -> Bool
    /// Removes the tap. Idempotent; called on every disarm (resign key, capture off, session end, app deactivation).
    func remove()
}

/// Viewer side: an active ("listen and filter") keyboard event tap at the HID level, which sees key events before the
/// WindowServer acts on system shortcuts, so ⌘Tab and friends can be forwarded to the Host instead of switching apps
/// on the Viewer Mac. Requires Accessibility permission (`AccessibilityPermission`); without it `install()` fails.
///
/// The callback runs on the main run loop (in common modes, so it also runs while a menu or a resize is tracked), and
/// decides per event with `SystemShortcutFilter`; `isArmed` is re-evaluated for every event, so a stale tap can never
/// swallow input after focus moved elsewhere. If the main thread stalls, macOS disables the tap after its timeout and
/// keys flow normally again until it is re-enabled. Event contents are never logged.
@MainActor
public final class SystemShortcutTap: SystemShortcutTapping {
    private let isArmed: @MainActor () -> Bool
    private let deliver: @MainActor (TapKeyEvent) -> Void
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// - Parameters:
    ///   - isArmed: whether events should be taken right now (checked for every event).
    ///   - deliver: receives every taken event, in order, synchronously on the main thread.
    public init(isArmed: @escaping @MainActor () -> Bool, deliver: @escaping @MainActor (TapKeyEvent) -> Void) {
        self.isArmed = isArmed
        self.deliver = deliver
    }

    isolated deinit {
        remove()
    }

    public var isInstalled: Bool { port != nil }

    public func install() -> Bool {
        if port != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // The callback finds this object through `userInfo`; `remove()` (also run by deinit) invalidates the port
        // first, so it is never called after this object is gone.
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: systemShortcutTapCallback,
                                           userInfo: info)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    public func remove() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    /// True when the event was taken (forwarded) and must be swallowed.
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, autorepeat: Bool,
                            sourcePID: Int64) -> Bool {
        let tracking = RunLoop.current.currentMode == .eventTracking
        let decision = SystemShortcutFilter.decide(type: type, keyCode: keyCode, flags: flags, armed: isArmed(),
                                                   postedByThisProcess: sourcePID == Int64(getpid()),
                                                   trackingLocalUI: tracking)
        switch decision {
        case .pass:
            return false
        case .reenable:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .forward:
            guard let event = SystemShortcutFilter.keyEvent(type: type, keyCode: keyCode, flags: flags,
                                                            autorepeat: autorepeat)
            else { return false }
            deliver(event)
            return true
        }
    }
}

/// C callback of `SystemShortcutTap`. Runs on the main thread (its run loop source is on the main run loop).
private func systemShortcutTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                       userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    let address = UInt(bitPattern: userInfo)
    let taken = MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return false }
        let tap = Unmanaged<SystemShortcutTap>.fromOpaque(pointer).takeUnretainedValue()
        return tap.handle(type: type, keyCode: keyCode, flags: flags, autorepeat: autorepeat, sourcePID: sourcePID)
    }
    return taken ? nil : Unmanaged.passUnretained(event)
}
