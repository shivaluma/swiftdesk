import CoreGraphics
import WireProtocol

/// The Viewer's input logic on plain values (no AppKit), so every rule is unit-testable with synthetic input.
///
/// Output goes through a non-escaping `emit` closure instead of returned arrays: no allocation per event.
struct ViewerInputTranslator {
    /// At most one pointer update per 4 ms (250 Hz): faster than any display refresh the Host renders at, yet it
    /// caps datagram rate from 1 kHz gaming mice so pointer traffic never competes with video for bandwidth.
    static let minPointerIntervalNanos: UInt64 = 4_000_000

    enum KeyKind: Sendable { case down, up, flagsChanged }

    private(set) var tracker = InputStateTracker()
    private(set) var lastPointerSentNanos: UInt64?
    /// A newer position than the last one sent is waiting for the throttle window (stored in `tracker.lastX/Y`).
    private(set) var hasPendingPointer = false

    /// Control+Option+Escape (Shift tolerated, Command excluded so Cmd+Opt+Esc "Force Quit" muscle memory never
    /// silently drops capture).
    static func isReleaseShortcut(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCode == ModifierKeys.escape
            && flags & ModifierKeys.controlFlag != 0
            && flags & ModifierKeys.optionFlag != 0
            && flags & ModifierKeys.commandFlag == 0
    }

    /// Returns false for the local release shortcut (nothing is emitted and no state changes).
    mutating func key(_ kind: KeyKind, keyCode: UInt16, appKitFlags: UInt, isRepeat: Bool,
                      emit: (OutgoingInput) -> Void) -> Bool {
        let flags = ModifierKeys.cgFlags(fromAppKitRawValue: appKitFlags)
        switch kind {
        case .down:
            if Self.isReleaseShortcut(keyCode: keyCode, flags: flags) { return false }
            emit(.reliable(tracker.keyDown(keyCode: keyCode, modifiers: flags, isRepeat: isRepeat)))
        case .up:
            if let message = tracker.keyUp(keyCode: keyCode, modifiers: flags) { emit(.reliable(message)) }
        case .flagsChanged:
            modifierChanged(keyCode: keyCode, flags: flags, emit: emit)
        }
        return true
    }

    /// `flagsChanged` carries only the new flag word; derive which transition the specific key made.
    private mutating func modifierChanged(keyCode: UInt16, flags: UInt64, emit: (OutgoingInput) -> Void) {
        guard let flag = ModifierKeys.flag(forKeyCode: keyCode) else { return }
        if keyCode == ModifierKeys.capsLock {
            // AppKit reports caps lock once per toggle, never its release: forward a complete press.
            let tap = tracker.keyTap(keyCode: keyCode, modifiers: flags)
            emit(.reliable(tap.down))
            emit(.reliable(tap.up))
            return
        }
        let held = tracker.isKeyHeld(keyCode)
        let isDown: Bool
        if flags & flag == 0 {
            isDown = false
        } else if let device = ModifierKeys.deviceFlag(forKeyCode: keyCode),
                  let sibling = ModifierKeys.siblingDeviceFlag(forKeyCode: keyCode),
                  flags & (device | sibling) != 0 {
            // Hardware events carry left/right bits: exact answer even while the sibling key is held.
            isDown = flags & device != 0
        } else {
            // No device bits (synthetic events, fn): the flag stays set while the sibling is held, so a change
            // for a key we already hold must be its release.
            isDown = !held
        }
        if isDown {
            if !held { emit(.reliable(tracker.keyDown(keyCode: keyCode, modifiers: flags, isRepeat: false))) }
        } else if let message = tracker.keyUp(keyCode: keyCode, modifiers: flags) {
            emit(.reliable(message))
        }
    }

    /// Button transition. Downs outside the video are not forwarded; an up for a held button is always forwarded
    /// (at the last known in-video position when released outside) so the Host never keeps a button stuck.
    mutating func mouseButton(_ button: MouseButton, down: Bool, normalized: CGPoint?, clickCount: Int,
                              appKitFlags: UInt, timestampNanos: UInt64, emit: (OutgoingInput) -> Void) {
        let flags = ModifierKeys.cgFlags(fromAppKitRawValue: appKitFlags)
        if down {
            guard let point = normalized else { return }
            flushPendingPointer(nowNanos: timestampNanos, emit: emit)
            emit(.reliable(tracker.buttonDown(button, x: Float(point.x), y: Float(point.y),
                                              clickCount: clickCount, modifiers: flags)))
        } else {
            guard tracker.isButtonHeld(button) else { return }
            flushPendingPointer(nowNanos: timestampNanos, emit: emit)
            let x = normalized.map { Float($0.x) } ?? tracker.lastX
            let y = normalized.map { Float($0.y) } ?? tracker.lastY
            if let message = tracker.buttonUp(button, x: x, y: y, clickCount: clickCount, modifiers: flags) {
                emit(.reliable(message))
            }
        }
    }

    /// Pointer move/drag. Returns the uptime (ns) at which a trailing flush is due when a position was deferred
    /// by the throttle, so the final resting position is always delivered even if no further event arrives.
    mutating func mouseMoved(normalized: CGPoint?, timestampNanos: UInt64, emit: (OutgoingInput) -> Void) -> UInt64? {
        guard let point = normalized else { return hasPendingPointer ? dueNanos : nil }
        tracker.updatePosition(x: Float(point.x), y: Float(point.y))
        if let last = lastPointerSentNanos, timestampNanos >= last, timestampNanos - last < Self.minPointerIntervalNanos {
            hasPendingPointer = true
            return last + Self.minPointerIntervalNanos
        }
        emit(.pointer(tracker.pointer()))
        lastPointerSentNanos = timestampNanos
        hasPendingPointer = false
        return nil
    }

    private var dueNanos: UInt64? {
        lastPointerSentNanos.map { $0 + Self.minPointerIntervalNanos }
    }

    /// Sends the deferred position, if any.
    mutating func flushPendingPointer(nowNanos: UInt64, emit: (OutgoingInput) -> Void) {
        guard hasPendingPointer else { return }
        hasPendingPointer = false
        emit(.pointer(tracker.pointer()))
        lastPointerSentNanos = nowNanos
    }

    /// `phase`/`momentumPhase` are `NSEvent.Phase` raw bits; the Host converts them to CoreGraphics phases.
    mutating func scroll(deltaX: Double, deltaY: Double, isPrecise: Bool, phase: UInt8, momentumPhase: UInt8,
                         emit: (OutgoingInput) -> Void) {
        // Phase-only events (began/ended with zero delta) still matter to apps tracking gestures.
        if deltaX == 0, deltaY == 0, phase == 0, momentumPhase == 0 { return }
        emit(.reliable(tracker.scroll(deltaX: Float(deltaX), deltaY: Float(deltaY), isPrecise: isPrecise,
                                      phase: phase, momentumPhase: momentumPhase)))
    }

    /// One complete press of `chord` (KEY_DOWN / KEY_UP in `KeyChord.strokes` order). Everything still held is
    /// released first, so the chord's modifiers start from a clean state on the Host and the press leaves nothing held.
    mutating func chord(_ chord: KeyChord, emit: (OutgoingInput) -> Void) {
        releaseAll(emit: emit)
        for stroke in chord.strokes {
            if stroke.isDown {
                emit(.reliable(tracker.keyDown(keyCode: stroke.keyCode, modifiers: stroke.flags, isRepeat: false)))
            } else if let message = tracker.keyUp(keyCode: stroke.keyCode, modifiers: stroke.flags) {
                emit(.reliable(message))
            }
        }
    }

    /// Key-up for every held key, mouse-up for every held button; drops any deferred pointer position.
    mutating func releaseAll(emit: (OutgoingInput) -> Void) {
        hasPendingPointer = false
        for message in tracker.releaseAll() { emit(.reliable(message)) }
    }
}
