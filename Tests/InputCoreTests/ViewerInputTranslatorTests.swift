import CoreGraphics
import Testing
import WireProtocol
@testable import InputCore

@Suite struct ViewerInputTranslatorTests {
    // MARK: Helpers

    private final class Harness {
        var translator = ViewerInputTranslator()
        var out = Collected()

        @discardableResult
        func key(_ kind: ViewerInputTranslator.KeyKind, _ code: UInt16, _ flags: UInt64 = 0, repeat r: Bool = false) -> Bool {
            var items: [OutgoingInput] = []
            let result = translator.key(kind, keyCode: code, appKitFlags: Flags.appKit(flags), isRepeat: r) { items.append($0) }
            out.items += items
            return result
        }

        func button(_ b: MouseButton, down: Bool, _ p: CGPoint?, clicks: Int = 1, flags: UInt64 = 0, t: UInt64 = 0) {
            var items: [OutgoingInput] = []
            translator.mouseButton(b, down: down, normalized: p, clickCount: clicks, appKitFlags: Flags.appKit(flags),
                                   timestampNanos: t) { items.append($0) }
            out.items += items
        }

        @discardableResult
        func move(_ p: CGPoint?, t: UInt64) -> UInt64? {
            var items: [OutgoingInput] = []
            let due = translator.mouseMoved(normalized: p, timestampNanos: t) { items.append($0) }
            out.items += items
            return due
        }

        func flush(t: UInt64) {
            var items: [OutgoingInput] = []
            translator.flushPendingPointer(nowNanos: t) { items.append($0) }
            out.items += items
        }

        func scroll(dx: Double, dy: Double, precise: Bool, phase: UInt8 = 0, momentum: UInt8 = 0) {
            var items: [OutgoingInput] = []
            translator.scroll(deltaX: dx, deltaY: dy, isPrecise: precise, phase: phase, momentumPhase: momentum) { items.append($0) }
            out.items += items
        }

        func releaseAll() {
            var items: [OutgoingInput] = []
            translator.releaseAll { items.append($0) }
            out.items += items
        }

        func take() -> [OutgoingInput] {
            defer { out.items.removeAll() }
            return out.items
        }
    }

    private static let ms: UInt64 = 1_000_000

    // MARK: Keys

    @Test func keyDownUpCarryModifiersAndRepeat() {
        let h = Harness()
        #expect(h.key(.down, 0, Flags.shift))
        h.key(.down, 0, Flags.shift, repeat: true)
        h.key(.up, 0, Flags.shift)
        #expect(h.out.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: Flags.shift, isRepeat: false)),
            .keyDown(KeyEvent(seq: 2, keyCode: 0, modifiers: Flags.shift, isRepeat: true)),
            .keyUp(KeyEvent(seq: 3, keyCode: 0, modifiers: Flags.shift, isRepeat: false)),
        ])
    }

    @Test func flagsChangedClassifiesDownAndUpWithoutDeviceBits() {
        let h = Harness()
        h.key(.flagsChanged, 56, Flags.shift)            // shift down
        h.key(.flagsChanged, 56, 0)                      // shift up
        h.key(.flagsChanged, 55, Flags.command)          // cmd down
        h.key(.flagsChanged, 59, Flags.command | Flags.control)
        h.key(.flagsChanged, 55, Flags.control)          // cmd up
        h.key(.flagsChanged, 59, 0)                      // control up
        #expect(h.out.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 56, modifiers: Flags.shift, isRepeat: false)),
            .keyUp(KeyEvent(seq: 2, keyCode: 56, modifiers: 0, isRepeat: false)),
            .keyDown(KeyEvent(seq: 3, keyCode: 55, modifiers: Flags.command, isRepeat: false)),
            .keyDown(KeyEvent(seq: 4, keyCode: 59, modifiers: Flags.command | Flags.control, isRepeat: false)),
            .keyUp(KeyEvent(seq: 5, keyCode: 55, modifiers: Flags.control, isRepeat: false)),
            .keyUp(KeyEvent(seq: 6, keyCode: 59, modifiers: 0, isRepeat: false)),
        ])
        #expect(h.translator.tracker.isIdle)
    }

    @Test func bothShiftsWithoutDeviceBitsUseHeldState() {
        let h = Harness()
        h.key(.flagsChanged, 56, Flags.shift)   // left down
        h.key(.flagsChanged, 60, Flags.shift)   // right down (flag already set)
        h.key(.flagsChanged, 56, Flags.shift)   // left up, right still holds the flag
        h.key(.flagsChanged, 60, 0)             // right up
        let kinds = h.out.messages.map { m -> String in
            switch m {
            case .keyDown(let k): "d\(k.keyCode)"
            case .keyUp(let k): "u\(k.keyCode)"
            default: "?"
            }
        }
        #expect(kinds == ["d56", "d60", "u56", "u60"])
    }

    @Test func bothShiftsWithDeviceBitsUseExactSide() {
        let h = Harness()
        let l = ModifierKeys.deviceLeftShiftFlag, r = ModifierKeys.deviceRightShiftFlag
        h.key(.flagsChanged, 60, Flags.shift | r)        // right down
        h.key(.flagsChanged, 56, Flags.shift | r | l)    // left down
        h.key(.flagsChanged, 60, Flags.shift | l)        // right up
        h.key(.flagsChanged, 56, 0)                      // left up
        #expect(h.out.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 60, modifiers: Flags.shift | r, isRepeat: false)),
            .keyDown(KeyEvent(seq: 2, keyCode: 56, modifiers: Flags.shift | r | l, isRepeat: false)),
            .keyUp(KeyEvent(seq: 3, keyCode: 60, modifiers: Flags.shift | l, isRepeat: false)),
            .keyUp(KeyEvent(seq: 4, keyCode: 56, modifiers: 0, isRepeat: false)),
        ])
    }

    @Test func modifierUpWithoutPriorDownIsNotSent() {
        let h = Harness()
        h.key(.flagsChanged, 58, 0)       // option released, but its press was never captured
        h.key(.flagsChanged, 99, Flags.shift) // unknown key code
        #expect(h.out.items.isEmpty)
    }

    @Test func fnKeyIsTrackedLikeOtherModifiers() {
        let h = Harness()
        h.key(.flagsChanged, 63, Flags.fn)
        h.key(.flagsChanged, 63, 0)
        #expect(h.out.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 63, modifiers: Flags.fn, isRepeat: false)),
            .keyUp(KeyEvent(seq: 2, keyCode: 63, modifiers: 0, isRepeat: false)),
        ])
    }

    @Test func capsLockToggleSendsDownAndUp() {
        let h = Harness()
        h.key(.flagsChanged, 57, Flags.caps)   // toggled on
        h.key(.flagsChanged, 57, 0)            // toggled off
        #expect(h.out.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 57, modifiers: Flags.caps, isRepeat: false)),
            .keyUp(KeyEvent(seq: 2, keyCode: 57, modifiers: Flags.caps, isRepeat: false)),
            .keyDown(KeyEvent(seq: 3, keyCode: 57, modifiers: 0, isRepeat: false)),
            .keyUp(KeyEvent(seq: 4, keyCode: 57, modifiers: 0, isRepeat: false)),
        ])
        #expect(h.translator.tracker.isIdle)
    }

    @Test func releaseShortcutIsNotForwardedAndLeavesNoStuckEscape() {
        let h = Harness()
        let ctrlOpt = Flags.control | Flags.option
        h.key(.flagsChanged, 59, Flags.control)
        h.key(.flagsChanged, 58, ctrlOpt)
        _ = h.take()
        #expect(h.key(.down, 53, ctrlOpt) == false)
        #expect(h.key(.down, 53, ctrlOpt, repeat: true) == false)
        #expect(h.out.items.isEmpty)
        #expect(!h.translator.tracker.isKeyHeld(53))
        #expect(h.key(.up, 53, ctrlOpt))
        #expect(h.out.items.isEmpty)
        h.releaseAll()
        #expect(h.out.messages == [
            .keyUp(KeyEvent(seq: 3, keyCode: 59, modifiers: Flags.option, isRepeat: false)),
            .keyUp(KeyEvent(seq: 4, keyCode: 58, modifiers: 0, isRepeat: false)),
        ])
    }

    @Test func escapeVariantsThatAreNotTheShortcutAreForwarded() {
        let h = Harness()
        #expect(h.key(.down, 53))                                                  // plain Escape
        #expect(h.key(.down, 53, Flags.control))                                   // ⌃⎋
        #expect(h.key(.down, 53, Flags.command | Flags.option))                    // ⌘⌥⎋ (Force Quit)
        #expect(h.key(.down, 53, Flags.command | Flags.option | Flags.control))    // with command: not ours
        #expect(h.key(.down, 53, Flags.control | Flags.option | Flags.shift) == false) // shift tolerated
        #expect(h.out.messages.count == 4)
    }

    // MARK: Mouse

    @Test func mouseButtonsCarryPositionClickCountAndModifiers() {
        let h = Harness()
        h.button(.right, down: true, CGPoint(x: 0.25, y: 0.5), clicks: 1, flags: Flags.control)
        h.button(.right, down: false, CGPoint(x: 0.25, y: 0.5), clicks: 1, flags: Flags.control)
        h.button(.left, down: true, CGPoint(x: 0.75, y: 0.125), clicks: 2)
        h.button(.left, down: false, CGPoint(x: 0.75, y: 0.125), clicks: 2)
        #expect(h.out.messages == [
            .mouseDown(MouseButtonEvent(seq: 1, button: .right, x: 0.25, y: 0.5, clickCount: 1, modifiers: Flags.control)),
            .mouseUp(MouseButtonEvent(seq: 2, button: .right, x: 0.25, y: 0.5, clickCount: 1, modifiers: Flags.control)),
            .mouseDown(MouseButtonEvent(seq: 3, button: .left, x: 0.75, y: 0.125, clickCount: 2, modifiers: 0)),
            .mouseUp(MouseButtonEvent(seq: 4, button: .left, x: 0.75, y: 0.125, clickCount: 2, modifiers: 0)),
        ])
    }

    @Test func movesAreThrottledToOnePer4ms() {
        let h = Harness()
        #expect(h.move(CGPoint(x: 0.1, y: 0.1), t: 100 * Self.ms) == nil)         // sent
        #expect(h.move(CGPoint(x: 0.2, y: 0.2), t: 101 * Self.ms) == 104 * Self.ms) // deferred
        #expect(h.move(CGPoint(x: 0.3, y: 0.3), t: 103 * Self.ms) == 104 * Self.ms) // replaces pending
        #expect(h.move(CGPoint(x: 0.4, y: 0.4), t: 104 * Self.ms) == nil)           // window elapsed: sent
        #expect(h.out.pointers.map(\.x) == [0.1, 0.4])
        #expect(!h.translator.hasPendingPointer)
    }

    @Test func trailingFlushDeliversFinalPosition() {
        let h = Harness()
        h.move(CGPoint(x: 0.1, y: 0.1), t: 0)
        h.move(CGPoint(x: 0.9, y: 0.8), t: 1 * Self.ms)
        #expect(h.translator.hasPendingPointer)
        h.flush(t: 4 * Self.ms)
        h.flush(t: 9 * Self.ms) // nothing pending: no duplicate
        #expect(h.out.pointers.map(\.x) == [0.1, 0.9])
        #expect(h.out.pointers.last?.y == 0.8)
    }

    @Test func pendingPositionIsFlushedBeforeButtonEvents() {
        let h = Harness()
        h.move(CGPoint(x: 0.1, y: 0.1), t: 0)
        h.move(CGPoint(x: 0.5, y: 0.5), t: 1 * Self.ms)   // pending
        h.button(.left, down: true, CGPoint(x: 0.5, y: 0.5), t: 2 * Self.ms)
        h.move(CGPoint(x: 0.6, y: 0.6), t: 7 * Self.ms)   // drag sent
        h.move(CGPoint(x: 0.7, y: 0.7), t: 8 * Self.ms)   // pending
        h.button(.left, down: false, CGPoint(x: 0.7, y: 0.7), t: 9 * Self.ms)
        let items = h.out.items
        #expect(items.count == 6)
        guard case .pointer(let p1) = items[1], case .reliable(.mouseDown) = items[2],
              case .pointer(let p3) = items[3], case .pointer(let p4) = items[4],
              case .reliable(.mouseUp(let up)) = items[5] else {
            Issue.record("unexpected order \(items)")
            return
        }
        #expect(p1.x == 0.5 && p1.buttonsMask == 0)          // flushed before the down
        #expect(p3.x == 0.6 && p3.buttonsMask == 0b001)      // drag mask
        #expect(p4.x == 0.7 && p4.buttonsMask == 0b001)      // flushed before the up, still dragging
        #expect(up.x == 0.7)
        let seqs = items.compactMap(\.seq)
        #expect(seqs == seqs.sorted() && Set(seqs).count == seqs.count)
    }

    @Test func dragMaskTracksAllHeldButtons() {
        let h = Harness()
        h.button(.right, down: true, CGPoint(x: 0.5, y: 0.5))
        h.button(.other, down: true, CGPoint(x: 0.5, y: 0.5))
        h.move(CGPoint(x: 0.6, y: 0.5), t: 10 * Self.ms)
        #expect(h.out.pointers.last?.buttonsMask == 0b110)
    }

    @Test func eventsOutsideVideoAreNotSentExceptHeldButtonUp() {
        let h = Harness()
        h.move(nil, t: 0)
        h.button(.left, down: true, nil)
        h.button(.left, down: false, nil)       // never pressed inside: dropped
        #expect(h.out.items.isEmpty)

        h.button(.left, down: true, CGPoint(x: 0.9, y: 0.95), t: 10 * Self.ms)
        h.move(nil, t: 20 * Self.ms)            // dragged out of the video: not sent
        h.button(.left, down: false, nil, t: 30 * Self.ms)
        #expect(h.out.messages == [
            .mouseDown(MouseButtonEvent(seq: 1, button: .left, x: 0.9, y: 0.95, clickCount: 1, modifiers: 0)),
            .mouseUp(MouseButtonEvent(seq: 2, button: .left, x: 0.9, y: 0.95, clickCount: 1, modifiers: 0)),
        ])
        #expect(h.out.pointers.isEmpty)
        #expect(h.translator.tracker.isIdle)
    }

    @Test func positionsAreClampedToUnitSquare() {
        let h = Harness()
        h.move(CGPoint(x: 1.2, y: -0.4), t: 0)
        #expect(h.out.pointers == [PointerState(seq: 1, x: 1, y: 0, buttonsMask: 0)])
    }

    // MARK: Scroll

    @Test func scrollCarriesDeltasPrecisionAndPhases() {
        let h = Harness()
        h.scroll(dx: 1.5, dy: -12.25, precise: true, phase: 4, momentum: 0)
        h.scroll(dx: 0, dy: 3, precise: false)
        h.scroll(dx: 0, dy: 0, precise: true, phase: 8)        // phase-only end is forwarded
        h.scroll(dx: 0, dy: 0, precise: true)                  // empty: dropped
        #expect(h.out.messages == [
            .scroll(ScrollEvent(seq: 1, deltaX: 1.5, deltaY: -12.25, isPrecise: true, phase: 4, momentumPhase: 0)),
            .scroll(ScrollEvent(seq: 2, deltaX: 0, deltaY: 3, isPrecise: false, phase: 0, momentumPhase: 0)),
            .scroll(ScrollEvent(seq: 3, deltaX: 0, deltaY: 0, isPrecise: true, phase: 8, momentumPhase: 0)),
        ])
    }

    // MARK: Release

    @Test func releaseAllReleasesKeysAndButtonsAndDropsPendingPointer() {
        let h = Harness()
        h.key(.flagsChanged, 55, Flags.command)
        h.key(.down, 8, Flags.command)
        h.button(.left, down: true, CGPoint(x: 0.4, y: 0.6), flags: Flags.command)
        h.move(CGPoint(x: 0.45, y: 0.6), t: 0)
        h.move(CGPoint(x: 0.5, y: 0.6), t: 1 * Self.ms) // pending
        _ = h.take()
        h.releaseAll()
        #expect(h.out.messages == [
            .mouseUp(MouseButtonEvent(seq: 5, button: .left, x: 0.5, y: 0.6, clickCount: 1, modifiers: Flags.command)),
            .keyUp(KeyEvent(seq: 6, keyCode: 8, modifiers: Flags.command, isRepeat: false)),
            .keyUp(KeyEvent(seq: 7, keyCode: 55, modifiers: 0, isRepeat: false)),
        ])
        #expect(h.out.pointers.isEmpty)
        #expect(!h.translator.hasPendingPointer)
        #expect(h.translator.tracker.isIdle)
    }
}
