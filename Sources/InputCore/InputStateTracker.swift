import WireProtocol

/// Viewer-side record of what the Host currently believes is pressed, plus the shared input sequence counter.
///
/// It exists so that every transition that was sent can be undone: on focus loss, release shortcut or disconnect,
/// `releaseAll()` produces exactly the key-ups and button-ups the Host needs, so no key or button stays stuck.
/// Ups for things that were never sent down are suppressed for the same reason in reverse (e.g. the Escape of the
/// release shortcut, or a key pressed before capture started).
///
/// Pure value type with no clocks or AppKit, so it is cheap on the event path and fully unit-testable.
public struct InputStateTracker: Sendable, Equatable {
    /// Sequence number the next message will carry. Shared by every input message (keys, buttons, pointer, scroll),
    /// so the Host can order pointer datagrams against reliable button events.
    public private(set) var nextSequence: UInt32
    /// Held keys (including modifiers) in press order. Arrays beat sets at this size (a handful of keys) and keep
    /// release order deterministic.
    public private(set) var heldKeys: [UInt16] = []
    public private(set) var heldButtons: [MouseButton] = []
    /// Last forwarded `CGEventFlags` raw value.
    public private(set) var modifiers: UInt64 = 0
    /// Last known normalized pointer position inside the video, used for button-ups released outside the video.
    public private(set) var lastX: Float = 0.5
    public private(set) var lastY: Float = 0.5
    public private(set) var hasPosition = false

    public init(firstSequence: UInt32 = 1) {
        nextSequence = firstSequence
    }

    @inline(__always)
    public mutating func takeSequence() -> UInt32 {
        let seq = nextSequence
        nextSequence &+= 1
        return seq
    }

    public func isKeyHeld(_ keyCode: UInt16) -> Bool { heldKeys.contains(keyCode) }
    public func isButtonHeld(_ button: MouseButton) -> Bool { heldButtons.contains(button) }
    public var isIdle: Bool { heldKeys.isEmpty && heldButtons.isEmpty }

    /// bit0 left, bit1 right, bit2 other — the `PointerState.buttonsMask` layout.
    public var buttonsMask: UInt8 {
        var mask: UInt8 = 0
        for button in heldButtons { mask |= Self.maskBit(button) }
        return mask
    }

    @inline(__always)
    public static func maskBit(_ button: MouseButton) -> UInt8 { 1 << button.rawValue }

    /// Records the latest pointer position (clamped to the unit square; NaN becomes 0).
    public mutating func updatePosition(x: Float, y: Float) {
        lastX = Self.clampUnit(x)
        lastY = Self.clampUnit(y)
        hasPosition = true
    }

    public mutating func keyDown(keyCode: UInt16, modifiers: UInt64, isRepeat: Bool) -> ControlMessage {
        self.modifiers = modifiers
        if !heldKeys.contains(keyCode) { heldKeys.append(keyCode) }
        return .keyDown(KeyEvent(seq: takeSequence(), keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat))
    }

    /// nil when the key is not held (nothing was sent down, so nothing must be sent up).
    public mutating func keyUp(keyCode: UInt16, modifiers: UInt64) -> ControlMessage? {
        guard let index = heldKeys.firstIndex(of: keyCode) else { return nil }
        heldKeys.remove(at: index)
        self.modifiers = modifiers
        return .keyUp(KeyEvent(seq: takeSequence(), keyCode: keyCode, modifiers: modifiers, isRepeat: false))
    }

    /// A toggle (caps lock) has no held state on the wire: it is sent as an immediate down+up pair.
    public mutating func keyTap(keyCode: UInt16, modifiers: UInt64) -> (down: ControlMessage, up: ControlMessage) {
        self.modifiers = modifiers
        let down = ControlMessage.keyDown(KeyEvent(seq: takeSequence(), keyCode: keyCode, modifiers: modifiers, isRepeat: false))
        let up = ControlMessage.keyUp(KeyEvent(seq: takeSequence(), keyCode: keyCode, modifiers: modifiers, isRepeat: false))
        return (down, up)
    }

    public mutating func buttonDown(_ button: MouseButton, x: Float, y: Float, clickCount: Int, modifiers: UInt64) -> ControlMessage {
        updatePosition(x: x, y: y)
        self.modifiers = modifiers
        if !heldButtons.contains(button) { heldButtons.append(button) }
        return .mouseDown(MouseButtonEvent(seq: takeSequence(), button: button, x: lastX, y: lastY,
                                           clickCount: Self.clampClickCount(clickCount), modifiers: modifiers))
    }

    /// nil when the button is not held.
    public mutating func buttonUp(_ button: MouseButton, x: Float, y: Float, clickCount: Int, modifiers: UInt64) -> ControlMessage? {
        guard let index = heldButtons.firstIndex(of: button) else { return nil }
        heldButtons.remove(at: index)
        updatePosition(x: x, y: y)
        self.modifiers = modifiers
        return .mouseUp(MouseButtonEvent(seq: takeSequence(), button: button, x: lastX, y: lastY,
                                         clickCount: Self.clampClickCount(clickCount), modifiers: modifiers))
    }

    /// Pointer state at the last known position with the current button mask.
    public mutating func pointer() -> PointerState {
        PointerState(seq: takeSequence(), x: lastX, y: lastY, buttonsMask: buttonsMask)
    }

    public mutating func scroll(deltaX: Float, deltaY: Float, isPrecise: Bool, phase: UInt8, momentumPhase: UInt8) -> ControlMessage {
        .scroll(ScrollEvent(seq: takeSequence(), deltaX: deltaX, deltaY: deltaY, isPrecise: isPrecise,
                            phase: phase, momentumPhase: momentumPhase))
    }

    /// MOUSE_UP for every held button (at the last known position), then KEY_UP for every held non-modifier key,
    /// then for every held modifier with its flag progressively cleared, and clears the held state.
    ///
    /// Buttons go first so a modifier-drag ends while the modifier is still down, like a physical release would.
    public mutating func releaseAll() -> [ControlMessage] {
        var out: [ControlMessage] = []
        out.reserveCapacity(heldButtons.count + heldKeys.count)
        for button in heldButtons {
            out.append(.mouseUp(MouseButtonEvent(seq: takeSequence(), button: button, x: lastX, y: lastY,
                                                 clickCount: 1, modifiers: modifiers)))
        }
        heldButtons.removeAll(keepingCapacity: true)

        for keyCode in heldKeys where !ModifierKeys.isModifier(keyCode) {
            out.append(.keyUp(KeyEvent(seq: takeSequence(), keyCode: keyCode, modifiers: modifiers, isRepeat: false)))
        }
        for keyCode in heldKeys where ModifierKeys.isModifier(keyCode) {
            modifiers = ModifierKeys.flags(modifiers, releasing: keyCode)
            out.append(.keyUp(KeyEvent(seq: takeSequence(), keyCode: keyCode, modifiers: modifiers, isRepeat: false)))
        }
        heldKeys.removeAll(keepingCapacity: true)
        // Only lock state can remain; every momentary modifier has been released.
        modifiers &= ModifierKeys.alphaShiftFlag
        return out
    }

    @inline(__always)
    static func clampUnit(_ v: Float) -> Float {
        guard v.isFinite else { return v == .infinity ? 1 : 0 }
        return min(max(v, 0), 1)
    }

    @inline(__always)
    static func clampClickCount(_ count: Int) -> UInt8 { UInt8(clamping: max(count, 1)) }
}
