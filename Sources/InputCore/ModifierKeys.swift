import CoreGraphics

/// Modifier-key knowledge shared by the Viewer translator and the Host injector.
///
/// AppKit reports modifier presses only as `flagsChanged` events that carry the *new* flag word, not whether the
/// key went down or up. To forward them as explicit KEY_DOWN/KEY_UP (so the Host's HID state matches the Viewer's
/// physical keyboard and nothing is left stuck), we need to know which flag each physical modifier key controls.
///
/// All flag values are `CGEventFlags` raw values. `NSEvent.ModifierFlags` uses the same bit positions (both are the
/// IOKit `NX_*MASK` word), verified against the macOS 27.2 SDK at runtime, so AppKit flags convert by masking only.
public enum ModifierKeys {
    // MARK: Virtual key codes (kVK_* from Carbon HIToolbox Events.h, US ANSI physical positions)

    public static let command: UInt16 = 55
    public static let shift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let option: UInt16 = 58
    public static let control: UInt16 = 59
    public static let rightCommand: UInt16 = 54
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62
    public static let function: UInt16 = 63
    public static let escape: UInt16 = 53

    // MARK: Device-independent flags (CGEventFlags raw values)

    public static let alphaShiftFlag: UInt64 = CGEventFlags.maskAlphaShift.rawValue    // 0x0001_0000
    public static let shiftFlag: UInt64 = CGEventFlags.maskShift.rawValue              // 0x0002_0000
    public static let controlFlag: UInt64 = CGEventFlags.maskControl.rawValue          // 0x0004_0000
    public static let optionFlag: UInt64 = CGEventFlags.maskAlternate.rawValue         // 0x0008_0000
    public static let commandFlag: UInt64 = CGEventFlags.maskCommand.rawValue          // 0x0010_0000
    public static let numericPadFlag: UInt64 = CGEventFlags.maskNumericPad.rawValue    // 0x0020_0000
    public static let helpFlag: UInt64 = CGEventFlags.maskHelp.rawValue                // 0x0040_0000
    public static let functionFlag: UInt64 = CGEventFlags.maskSecondaryFn.rawValue     // 0x0080_0000

    // MARK: Device-dependent (left/right) flags, NX_DEVICE*KEYMASK in IOKit/hidsystem/IOLLEvent.h

    public static let deviceLeftControlFlag: UInt64 = 0x0000_0001
    public static let deviceLeftShiftFlag: UInt64 = 0x0000_0002
    public static let deviceRightShiftFlag: UInt64 = 0x0000_0004
    public static let deviceLeftCommandFlag: UInt64 = 0x0000_0008
    public static let deviceRightCommandFlag: UInt64 = 0x0000_0010
    public static let deviceLeftOptionFlag: UInt64 = 0x0000_0020
    public static let deviceRightOptionFlag: UInt64 = 0x0000_0040
    public static let deviceRightControlFlag: UInt64 = 0x0000_2000

    /// Every device-independent flag the protocol carries.
    public static let deviceIndependentMask: UInt64 =
        alphaShiftFlag | shiftFlag | controlFlag | optionFlag | commandFlag | numericPadFlag | helpFlag | functionFlag
    /// Left/right distinctions, kept so Host apps that care (games, remappers) see the same side the user pressed.
    public static let deviceDependentMask: UInt64 =
        deviceLeftControlFlag | deviceLeftShiftFlag | deviceRightShiftFlag | deviceLeftCommandFlag
        | deviceRightCommandFlag | deviceLeftOptionFlag | deviceRightOptionFlag | deviceRightControlFlag
    /// Bits forwarded on the wire and applied on the Host. Excludes non-coalesced and other event-source bits that
    /// describe the Viewer's local event stream rather than key state.
    public static let forwardedMask: UInt64 = deviceIndependentMask | deviceDependentMask

    /// Device-independent flag controlled by a physical modifier key, or nil if `keyCode` is not a modifier.
    public static func flag(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case shift, rightShift: shiftFlag
        case control, rightControl: controlFlag
        case option, rightOption: optionFlag
        case command, rightCommand: commandFlag
        case function: functionFlag
        case capsLock: alphaShiftFlag
        default: nil
        }
    }

    /// Left/right device flag for a physical modifier key; nil for keys without one (fn, caps lock, non-modifiers).
    public static func deviceFlag(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case shift: deviceLeftShiftFlag
        case rightShift: deviceRightShiftFlag
        case control: deviceLeftControlFlag
        case rightControl: deviceRightControlFlag
        case option: deviceLeftOptionFlag
        case rightOption: deviceRightOptionFlag
        case command: deviceLeftCommandFlag
        case rightCommand: deviceRightCommandFlag
        default: nil
        }
    }

    /// Device flag of the *other* key of a left/right pair (e.g. right shift for left shift).
    public static func siblingDeviceFlag(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case shift: deviceRightShiftFlag
        case rightShift: deviceLeftShiftFlag
        case control: deviceRightControlFlag
        case rightControl: deviceLeftControlFlag
        case option: deviceRightOptionFlag
        case rightOption: deviceLeftOptionFlag
        case command: deviceRightCommandFlag
        case rightCommand: deviceLeftCommandFlag
        default: nil
        }
    }

    @inline(__always)
    public static func isModifier(_ keyCode: UInt16) -> Bool { flag(forKeyCode: keyCode) != nil }

    /// Flags a hardware keyboard always sets on this key's own events: fn on function and navigation keys, fn and
    /// keypad on the arrow keys. Synthesized presses (`KeyChord`) add them so they look like the real key; the
    /// system's default shortcuts include them (Mission Control is stored as ⌃ + fn + ↑, Show Desktop as fn + F11).
    public static func intrinsicFlags(forKeyCode keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 0x7B...0x7E: functionFlag | numericPadFlag                      // ← → ↓ ↑
        case 0x72...0x77, 0x79: functionFlag                                 // help, home, page up, ⌦, F4, end, page down
        case 0x40, 0x4F, 0x50, 0x5A, 0x60...0x65, 0x67, 0x69...0x6B, 0x6D, 0x6F, 0x71, 0x78, 0x7A:
            functionFlag                                                     // F1 … F20
        default: 0
        }
    }

    /// Converts `NSEvent.ModifierFlags.rawValue` to the forwarded `CGEventFlags` raw value (same bit layout).
    @inline(__always)
    public static func cgFlags(fromAppKitRawValue raw: UInt) -> UInt64 { UInt64(raw) & forwardedMask }

    /// Flags left after `keyCode` is released: clears its device bit, and its device-independent bit unless the
    /// sibling key of the pair is still held. Caps lock is a toggle and is left unchanged.
    public static func flags(_ flags: UInt64, releasing keyCode: UInt16) -> UInt64 {
        guard let flag = flag(forKeyCode: keyCode), keyCode != capsLock else { return flags }
        var result = flags
        if let device = deviceFlag(forKeyCode: keyCode) { result &= ~device }
        let siblingHeld = siblingDeviceFlag(forKeyCode: keyCode).map { result & $0 != 0 } ?? false
        if !siblingHeld { result &= ~flag }
        return result
    }
}
