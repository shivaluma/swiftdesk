import CoreGraphics
import WireProtocol

/// Description of one CGEvent to post. Keeps the injection rules pure: the engine decides *what* to post, an
/// `EventPoster` turns it into a real `CGEvent` (or records it in tests).
enum PostedEvent: Equatable, Sendable {
    /// `clickState` is applied to `.mouseEventClickState` when > 0.
    case mouse(type: CGEventType, button: CGMouseButton, point: CGPoint, clickState: Int64, flags: UInt64)
    case key(keyCode: UInt16, down: Bool, flags: UInt64, autorepeat: Bool)
    /// `wheel1` vertical, `wheel2` horizontal. `fixedPoint1/2` (line units only) carry the exact fractional line
    /// delta, which is what AppKit reports as `scrollingDeltaY/X` for non-precise events.
    case scroll(units: CGScrollEventUnit, wheel1: Int32, wheel2: Int32, fixedPoint1: Double?, fixedPoint2: Double?,
                scrollPhase: Int64, momentumPhase: Int64, continuous: Bool, flags: UInt64)
}

/// Wire scroll phases are `NSEvent.Phase` bits (began 1, stationary 2, changed 4, ended 8, cancelled 16,
/// mayBegin 32); CoreGraphics uses different values (`CGScrollPhase` 1/2/4/8/128, `CGMomentumScrollPhase` 0–3).
enum ScrollPhaseMapping {
    static func cgScrollPhase(fromAppKit phase: UInt8) -> Int64 {
        if phase & 0x01 != 0 { return Int64(CGScrollPhase.began.rawValue) }
        if phase & 0x04 != 0 || phase & 0x02 != 0 { return Int64(CGScrollPhase.changed.rawValue) }
        if phase & 0x08 != 0 { return Int64(CGScrollPhase.ended.rawValue) }
        if phase & 0x10 != 0 { return Int64(CGScrollPhase.cancelled.rawValue) }
        if phase & 0x20 != 0 { return Int64(CGScrollPhase.mayBegin.rawValue) }
        return 0
    }

    static func cgMomentumPhase(fromAppKit phase: UInt8) -> Int64 {
        if phase & 0x01 != 0 { return Int64(CGMomentumScrollPhase.begin.rawValue) }
        if phase & 0x04 != 0 || phase & 0x02 != 0 { return Int64(CGMomentumScrollPhase.continuous.rawValue) }
        if phase & 0x18 != 0 { return Int64(CGMomentumScrollPhase.end.rawValue) }
        return Int64(CGMomentumScrollPhase.none.rawValue)
    }
}

/// Converts fractional wire deltas to the integer wheel deltas CGEvent takes without losing the fractions:
/// sub-unit remainders carry into the next event (slow trackpad scrolls would otherwise never move), and are
/// discarded on a direction or unit change so a reversal responds immediately.
struct ScrollAccumulator: Equatable {
    /// Bounds a hostile/corrupt delta before integer conversion (Int32(Double) traps on overflow).
    static let maxMagnitude: Double = 10_000

    private var remainder = (x: 0.0, y: 0.0)
    private var direction = (x: 0.0, y: 0.0)
    private var precise: Bool?

    static func == (a: ScrollAccumulator, b: ScrollAccumulator) -> Bool {
        a.remainder == b.remainder && a.direction == b.direction && a.precise == b.precise
    }

    mutating func reset() { self = ScrollAccumulator() }

    /// Pixels truncate (sub-pixel carry, like hardware); lines round to nearest so a single 0.5+ line notch
    /// scrolls at once, with the over/undershoot carried.
    mutating func take(deltaX: Double, deltaY: Double, isPrecise: Bool) -> (x: Int32, y: Int32) {
        if precise != isPrecise {
            remainder = (0, 0)
            direction = (0, 0)
            precise = isPrecise
        }
        let x = Self.step(Self.sanitize(deltaX), remainder: &remainder.x, direction: &direction.x, precise: isPrecise)
        let y = Self.step(Self.sanitize(deltaY), remainder: &remainder.y, direction: &direction.y, precise: isPrecise)
        return (x, y)
    }

    static func sanitize(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, -maxMagnitude), maxMagnitude)
    }

    private static func step(_ delta: Double, remainder: inout Double, direction: inout Double, precise: Bool) -> Int32 {
        guard delta != 0 else { return 0 }
        let sign: Double = delta > 0 ? 1 : -1
        if sign != direction {
            remainder = 0
            direction = sign
        }
        let total = remainder + delta
        // The epsilon absorbs summation drift (10 × 0.3 = 2.999…) so carried fractions are never lost.
        let nudged = total + sign * 1e-6
        let whole = precise ? nudged.rounded(.towardZero) : nudged.rounded(.toNearestOrAwayFromZero)
        remainder = total - whole
        return Int32(whole)
    }
}

/// Host-side injection rules on plain values. Not thread-safe: owned by `HostInputInjector`'s serial queue.
struct HostInjectionEngine {
    var displayFrame: CGRect
    private(set) var heldKeys: [UInt16] = []
    private(set) var heldButtons: [MouseButton] = []
    /// Click count of the last down per button, reused on drags so double-click-drag (word selection) works.
    private var clickStates: [Int64] = [1, 1, 1]
    /// Last applied `CGEventFlags` raw value (from the latest key/button message).
    private(set) var modifiers: UInt64 = 0
    /// Last position the engine moved the cursor to.
    private(set) var cursor: CGPoint?
    /// Highest seq applied from any pointer-affecting message (MOUSE_MOVE, pointer datagram, button events).
    private(set) var lastPointerSeq: UInt32 = 0
    private(set) var stalePointerDrops: UInt64 = 0
    /// Newest pointer state whose `buttonsMask` disagrees with the buttons this engine holds. Button transitions
    /// travel on the reliable stream and pointer states as datagrams, so a lost stream packet can delay a MOUSE_UP
    /// (or MOUSE_DOWN) by a retransmission while newer datagrams keep arriving. Posting those as drags (or plain
    /// moves) would carry a window past the release point (or lose a drag), so the position is held here and applied
    /// right after the button event that makes the masks agree.
    private(set) var deferredPointer: PointerState?
    /// Seq of the first pointer state of the current mismatch run, nil while the masks agree (bounds the wait).
    private var mismatchSinceSeq: UInt32?
    private(set) var deferredPointerCount: UInt64 = 0
    private var scroll = ScrollAccumulator()

    /// Safety valve: if the masks still disagree this many sequence numbers after the mismatch began (~0.25 s of
    /// pointer traffic at the Viewer's 250 Hz cap), the button event is presumed gone for good (or the two sides'
    /// button state diverged, e.g. across a view-only transition) and positions are applied again as before, so the
    /// cursor can never freeze.
    static let maxDeferredSeqSpan: UInt32 = 64

    init(displayFrame: CGRect) {
        self.displayFrame = displayFrame
    }

    /// Forget sequence/scroll history, e.g. for a new session whose Viewer restarts its counter at 1.
    mutating func resetSession() {
        lastPointerSeq = 0
        deferredPointer = nil
        mismatchSinceSeq = nil
        scroll.reset()
    }

    mutating func handle(_ message: ControlMessage, emit: (PostedEvent) -> Void) {
        switch message {
        case .keyDown(let key):
            modifiers = Self.sanitizeFlags(key.modifiers)
            if !heldKeys.contains(key.keyCode) { heldKeys.append(key.keyCode) }
            emit(.key(keyCode: key.keyCode, down: true, flags: modifiers, autorepeat: key.isRepeat))
        case .keyUp(let key):
            modifiers = Self.sanitizeFlags(key.modifiers)
            if let index = heldKeys.firstIndex(of: key.keyCode) { heldKeys.remove(at: index) }
            emit(.key(keyCode: key.keyCode, down: false, flags: modifiers, autorepeat: false))
        case .mouseDown(let event):
            mouseDown(event, emit: emit)
        case .mouseUp(let event):
            mouseUp(event, emit: emit)
        case .mouseMove(let state):
            pointer(state, emit: emit)
        case .scroll(let event):
            scrollEvent(event, emit: emit)
        default:
            return
        }
    }

    /// Latest-state pointer (datagram or MOUSE_MOVE). Drops anything not newer than the last applied seq, so a
    /// late datagram can never pull the cursor back behind a click or a newer move.
    mutating func pointer(_ state: PointerState, emit: (PostedEvent) -> Void) {
        guard state.seq > lastPointerSeq else {
            stalePointerDrops &+= 1
            return
        }
        lastPointerSeq = state.seq
        if state.buttonsMask & Self.knownButtonsMask != heldButtonsMask {
            let since = mismatchSinceSeq ?? state.seq
            mismatchSinceSeq = since
            if state.seq &- since < Self.maxDeferredSeqSpan {
                deferredPointer = state
                deferredPointerCount &+= 1
                return
            }
        } else {
            mismatchSinceSeq = nil
        }
        deferredPointer = nil
        let point = map(state.x, state.y)
        if point == cursor { return }
        emitMove(to: point, emit: emit)
    }

    /// bit0 left, bit1 right, bit2 other — `PointerState.buttonsMask` layout. Other bits are ignored.
    static let knownButtonsMask: UInt8 = 0b111

    var heldButtonsMask: UInt8 {
        var mask: UInt8 = 0
        for button in heldButtons { mask |= 1 << button.rawValue }
        return mask
    }

    /// After a button event: a deferred position newer than it whose mask now matches is applied (as a drag or move
    /// per the new held state); one not newer than the event is superseded by it.
    private mutating func applyDeferredPointer(after eventSeq: UInt32, emit: (PostedEvent) -> Void) {
        mismatchSinceSeq = nil   // a button event arrived: a later mismatch starts a fresh wait
        guard let deferred = deferredPointer else { return }
        guard deferred.seq > eventSeq else {
            deferredPointer = nil
            return
        }
        guard deferred.buttonsMask & Self.knownButtonsMask == heldButtonsMask else { return }
        deferredPointer = nil
        let point = map(deferred.x, deferred.y)
        if point != cursor { emitMove(to: point, emit: emit) }
    }

    /// Releases everything this engine pressed: button-ups at the cursor, then non-modifier key-ups, then modifier
    /// key-ups with their flags progressively cleared.
    mutating func releaseAll(fallbackCursor: CGPoint?, emit: (PostedEvent) -> Void) {
        let point = cursor ?? fallbackCursor ?? CGPoint(x: displayFrame.midX, y: displayFrame.midY)
        for button in heldButtons {
            emit(.mouse(type: Self.upType(button), button: Self.cgButton(button), point: point, clickState: 1, flags: modifiers))
        }
        heldButtons.removeAll(keepingCapacity: true)
        for keyCode in heldKeys where !ModifierKeys.isModifier(keyCode) {
            emit(.key(keyCode: keyCode, down: false, flags: modifiers, autorepeat: false))
        }
        for keyCode in heldKeys where ModifierKeys.isModifier(keyCode) {
            modifiers = ModifierKeys.flags(modifiers, releasing: keyCode)
            emit(.key(keyCode: keyCode, down: false, flags: modifiers, autorepeat: false))
        }
        heldKeys.removeAll(keepingCapacity: true)
        modifiers &= ModifierKeys.alphaShiftFlag
        deferredPointer = nil
        mismatchSinceSeq = nil
        scroll.reset()
    }

    // MARK: - Private

    private mutating func mouseDown(_ event: MouseButtonEvent, emit: (PostedEvent) -> Void) {
        advancePointerSeq(event.seq)
        modifiers = Self.sanitizeFlags(event.modifiers)
        let point = map(event.x, event.y)
        // Move first so the click lands exactly where the Viewer saw the pointer, even if the last pointer
        // datagram was lost; a held other button turns this into its drag.
        emitMove(to: point, emit: emit)
        let clickState = Int64(max(event.clickCount, 1))
        clickStates[Int(event.button.rawValue)] = clickState
        if !heldButtons.contains(event.button) { heldButtons.append(event.button) }
        emit(.mouse(type: Self.downType(event.button), button: Self.cgButton(event.button), point: point,
                    clickState: clickState, flags: modifiers))
        applyDeferredPointer(after: event.seq, emit: emit)
    }

    private mutating func mouseUp(_ event: MouseButtonEvent, emit: (PostedEvent) -> Void) {
        advancePointerSeq(event.seq)
        modifiers = Self.sanitizeFlags(event.modifiers)
        let point = map(event.x, event.y)
        if let index = heldButtons.firstIndex(of: event.button) { heldButtons.remove(at: index) }
        cursor = point
        emit(.mouse(type: Self.upType(event.button), button: Self.cgButton(event.button), point: point,
                    clickState: Int64(max(event.clickCount, 1)), flags: modifiers))
        applyDeferredPointer(after: event.seq, emit: emit)
    }

    private mutating func scrollEvent(_ event: ScrollEvent, emit: (PostedEvent) -> Void) {
        let dx = ScrollAccumulator.sanitize(Double(event.deltaX))
        let dy = ScrollAccumulator.sanitize(Double(event.deltaY))
        let wheels = scroll.take(deltaX: dx, deltaY: dy, isPrecise: event.isPrecise)
        let phase = ScrollPhaseMapping.cgScrollPhase(fromAppKit: event.phase)
        let momentum = ScrollPhaseMapping.cgMomentumPhase(fromAppKit: event.momentumPhase)
        let hasLineFraction = !event.isPrecise && (dx != 0 || dy != 0)
        // Nothing to say: every delta was carried as remainder and there is no gesture phase to report.
        if wheels.x == 0, wheels.y == 0, phase == 0, momentum == 0, !hasLineFraction { return }
        emit(.scroll(units: event.isPrecise ? .pixel : .line, wheel1: wheels.y, wheel2: wheels.x,
                     fixedPoint1: event.isPrecise ? nil : dy, fixedPoint2: event.isPrecise ? nil : dx,
                     scrollPhase: phase, momentumPhase: momentum, continuous: event.isPrecise, flags: modifiers))
    }

    private mutating func emitMove(to point: CGPoint, emit: (PostedEvent) -> Void) {
        cursor = point
        if let button = Self.dragButton(heldButtons) {
            emit(.mouse(type: Self.dragType(button), button: Self.cgButton(button), point: point,
                        clickState: clickStates[Int(button.rawValue)], flags: modifiers))
        } else {
            emit(.mouse(type: .mouseMoved, button: .left, point: point, clickState: 0, flags: modifiers))
        }
    }

    private mutating func advancePointerSeq(_ seq: UInt32) {
        if seq > lastPointerSeq { lastPointerSeq = seq }
    }

    private func map(_ x: Float, _ y: Float) -> CGPoint {
        HostCoordinateMapper.globalPoint(normalizedX: x, normalizedY: y, displayFrame: displayFrame)
    }

    /// Only key-state bits are applied; anything else in a received word is ignored.
    @inline(__always)
    static func sanitizeFlags(_ flags: UInt64) -> UInt64 { flags & ModifierKeys.forwardedMask }

    /// Drag type follows the primary held button, matching what the HID system generates.
    static func dragButton(_ held: [MouseButton]) -> MouseButton? {
        if held.contains(.left) { return .left }
        if held.contains(.right) { return .right }
        if held.contains(.other) { return .other }
        return nil
    }

    static func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .other: .center
        }
    }

    static func downType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .other: .otherMouseDown
        }
    }

    static func upType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .other: .otherMouseUp
        }
    }

    static func dragType(_ button: MouseButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .other: .otherMouseDragged
        }
    }
}
