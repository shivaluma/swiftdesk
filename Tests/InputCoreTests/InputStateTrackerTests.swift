import Testing
import WireProtocol
@testable import InputCore

@Suite struct InputStateTrackerTests {
    @Test func pressHoldRelease() throws {
        var t = InputStateTracker()
        let down = t.keyDown(keyCode: 0, modifiers: 0, isRepeat: false)
        #expect(down == .keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: 0, isRepeat: false)))
        #expect(t.isKeyHeld(0))
        let repeatDown = t.keyDown(keyCode: 0, modifiers: 0, isRepeat: true)
        #expect(repeatDown == .keyDown(KeyEvent(seq: 2, keyCode: 0, modifiers: 0, isRepeat: true)))
        #expect(t.heldKeys == [0])
        let maybeUp = t.keyUp(keyCode: 0, modifiers: 0)
        let up = try #require(maybeUp)
        #expect(up == .keyUp(KeyEvent(seq: 3, keyCode: 0, modifiers: 0, isRepeat: false)))
        #expect(t.isIdle)
    }

    @Test func upForUnheldKeyOrButtonIsSuppressed() {
        var t = InputStateTracker()
        #expect(t.keyUp(keyCode: 53, modifiers: 0) == nil)
        #expect(t.buttonUp(.left, x: 0.5, y: 0.5, clickCount: 1, modifiers: 0) == nil)
        #expect(t.nextSequence == 1)
    }

    @Test func buttonsMaskReflectsHeldButtons() {
        var t = InputStateTracker()
        _ = t.buttonDown(.left, x: 0.1, y: 0.2, clickCount: 1, modifiers: 0)
        #expect(t.buttonsMask == 0b001)
        _ = t.buttonDown(.other, x: 0.1, y: 0.2, clickCount: 1, modifiers: 0)
        #expect(t.buttonsMask == 0b101)
        _ = t.buttonDown(.right, x: 0.1, y: 0.2, clickCount: 1, modifiers: 0)
        #expect(t.buttonsMask == 0b111)
        _ = t.buttonUp(.left, x: 0.1, y: 0.2, clickCount: 1, modifiers: 0)
        #expect(t.buttonsMask == 0b110)
        #expect(t.pointer().buttonsMask == 0b110)
    }

    @Test func buttonEventsClampPositionAndClickCount() {
        var t = InputStateTracker()
        let m = t.buttonDown(.left, x: 1.5, y: -0.2, clickCount: 0, modifiers: 0)
        guard case .mouseDown(let e) = m else { Issue.record("expected mouseDown"); return }
        #expect(e.x == 1 && e.y == 0)
        #expect(e.clickCount == 1)
        let m2 = t.buttonDown(.right, x: .nan, y: .infinity, clickCount: 999, modifiers: 0)
        guard case .mouseDown(let e2) = m2 else { Issue.record("expected mouseDown"); return }
        #expect(e2.x == 0 && e2.y == 1)
        #expect(e2.clickCount == 255)
    }

    @Test func releaseAllEmitsButtonsThenKeysThenModifiersWithFlagsCleared() {
        var t = InputStateTracker()
        let cmdShift = ModifierKeys.commandFlag | ModifierKeys.shiftFlag
        _ = t.keyDown(keyCode: 55, modifiers: ModifierKeys.commandFlag, isRepeat: false)
        _ = t.keyDown(keyCode: 56, modifiers: cmdShift, isRepeat: false)
        _ = t.keyDown(keyCode: 0, modifiers: cmdShift, isRepeat: false)
        _ = t.buttonDown(.left, x: 0.25, y: 0.75, clickCount: 2, modifiers: cmdShift)
        _ = t.buttonDown(.right, x: 0.3, y: 0.7, clickCount: 1, modifiers: cmdShift)

        let first = t.nextSequence
        let out = t.releaseAll()
        #expect(out == [
            .mouseUp(MouseButtonEvent(seq: first, button: .left, x: 0.3, y: 0.7, clickCount: 1, modifiers: cmdShift)),
            .mouseUp(MouseButtonEvent(seq: first + 1, button: .right, x: 0.3, y: 0.7, clickCount: 1, modifiers: cmdShift)),
            .keyUp(KeyEvent(seq: first + 2, keyCode: 0, modifiers: cmdShift, isRepeat: false)),
            .keyUp(KeyEvent(seq: first + 3, keyCode: 55, modifiers: ModifierKeys.shiftFlag, isRepeat: false)),
            .keyUp(KeyEvent(seq: first + 4, keyCode: 56, modifiers: 0, isRepeat: false)),
        ])
        #expect(t.isIdle)
        #expect(t.modifiers == 0)
        #expect(t.releaseAll().isEmpty)
    }

    @Test func releaseAllKeepsCapsLockState() {
        var t = InputStateTracker()
        _ = t.keyDown(keyCode: 56, modifiers: ModifierKeys.shiftFlag | ModifierKeys.alphaShiftFlag, isRepeat: false)
        let out = t.releaseAll()
        #expect(out == [.keyUp(KeyEvent(seq: 2, keyCode: 56, modifiers: ModifierKeys.alphaShiftFlag, isRepeat: false))])
        #expect(t.modifiers == ModifierKeys.alphaShiftFlag)
    }

    @Test func sequenceNumbersStrictlyIncreaseAcrossAllMessageKinds() {
        var t = InputStateTracker()
        var seqs: [UInt32] = []
        func seq(_ m: ControlMessage?) {
            switch m {
            case .keyDown(let k), .keyUp(let k): seqs.append(k.seq)
            case .mouseDown(let b), .mouseUp(let b): seqs.append(b.seq)
            case .scroll(let s): seqs.append(s.seq)
            default: break
            }
        }
        seq(t.keyDown(keyCode: 1, modifiers: 0, isRepeat: false))
        seqs.append(t.pointer().seq)
        seq(t.buttonDown(.left, x: 0, y: 0, clickCount: 1, modifiers: 0))
        seq(t.scroll(deltaX: 0, deltaY: 1, isPrecise: true, phase: 0, momentumPhase: 0))
        seqs.append(t.pointer().seq)
        seq(t.buttonUp(.left, x: 0, y: 0, clickCount: 1, modifiers: 0))
        let tap = t.keyTap(keyCode: 57, modifiers: ModifierKeys.alphaShiftFlag)
        seq(tap.down); seq(tap.up)
        for m in t.releaseAll() { seq(m) }
        #expect(seqs == Array(1...UInt32(seqs.count)))
        #expect(seqs.count == 9)
    }

    @Test func sequenceWrapsWithoutTrapping() {
        var t = InputStateTracker(firstSequence: .max)
        #expect(t.takeSequence() == .max)
        #expect(t.takeSequence() == 0)
    }
}
