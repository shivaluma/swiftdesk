import Testing
import WireProtocol
@testable import SessionCore

/// The `input` signpost carries only the sequence number; make sure every input type has one and nothing else does.
@Suite struct InputSequenceTests {
    @Test func everyInputMessageExposesItsSequence() {
        let key = KeyEvent(seq: 7, keyCode: 0, modifiers: 0)
        let button = MouseButtonEvent(seq: 8, button: .left, x: 0.5, y: 0.5, clickCount: 1, modifiers: 0)
        #expect(ControlMessage.keyDown(key).inputSequence == 7)
        #expect(ControlMessage.keyUp(key).inputSequence == 7)
        #expect(ControlMessage.mouseDown(button).inputSequence == 8)
        #expect(ControlMessage.mouseUp(button).inputSequence == 8)
        #expect(ControlMessage.mouseMove(PointerState(seq: 9, x: 0, y: 0, buttonsMask: 0)).inputSequence == 9)
        #expect(ControlMessage.scroll(ScrollEvent(seq: 10, deltaX: 0, deltaY: 1, isPrecise: true)).inputSequence == 10)
    }

    @Test func nonInputMessagesHaveNone() {
        #expect(ControlMessage.ping(Ping(id: 1, sentAtNanos: 2)).inputSequence == nil)
        #expect(ControlMessage.requestKeyframe(reason: 1).inputSequence == nil)
        #expect(ControlMessage.disconnect(.userInitiated).inputSequence == nil)
    }
}
