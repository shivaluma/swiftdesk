import AppKit
import Synchronization
import Testing
import WireProtocol
@testable import InputCore

/// End-to-end through real `NSEvent`s, covering the AppKit extraction layer on top of the translator.
@MainActor
@Suite struct ViewerInputControllerTests {
    final class Sink: Sendable {
        private let storage = Mutex<[OutgoingInput]>([])
        func append(_ item: OutgoingInput) { storage.withLock { $0.append(item) } }
        var items: [OutgoingInput] { storage.withLock { $0 } }
        var messages: [ControlMessage] { items.compactMap { if case .reliable(let m) = $0 { m } else { nil } } }
        var pointers: [PointerState] { items.compactMap { if case .pointer(let p) = $0 { p } else { nil } } }
    }

    private func make() -> (ViewerInputController, Sink) {
        let sink = Sink()
        return (ViewerInputController(send: { sink.append($0) }), sink)
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [],
                     repeat r: Bool = false, t: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: t, windowNumber: 0,
                                      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: r,
                                      keyCode: code))
    }

    /// Hardware-like flagsChanged: CoreGraphics stamps the device (left/right) bits like a real keyboard would.
    private func flagsChanged(_ code: UInt16, flags: UInt64) throws -> NSEvent {
        let cg = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        cg.flags = CGEventFlags(rawValue: flags)
        let event = try #require(NSEvent(cgEvent: cg))
        #expect(event.type == .flagsChanged)
        return event
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1, flags: NSEvent.ModifierFlags = [], t: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: t, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    @Test func releaseShortcutDescription() {
        #expect(ViewerInputController.releaseShortcutDescription == "⌃⌥⎋")
    }

    @Test func keyEventsAreForwardedWithAppKitFlagsConverted() throws {
        let (c, sink) = make()
        #expect(c.handleKey(try key(.keyDown, 0, [.command, .shift])))
        #expect(c.handleKey(try key(.keyDown, 0, [.command, .shift], repeat: true)))
        #expect(c.handleKey(try key(.keyUp, 0, [.command, .shift])))
        let cmdShift = ModifierKeys.commandFlag | ModifierKeys.shiftFlag
        #expect(sink.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: cmdShift, isRepeat: false)),
            .keyDown(KeyEvent(seq: 2, keyCode: 0, modifiers: cmdShift, isRepeat: true)),
            .keyUp(KeyEvent(seq: 3, keyCode: 0, modifiers: cmdShift, isRepeat: false)),
        ])
    }

    @Test func flagsChangedFromHardwareStyleEvents() throws {
        let (c, sink) = make()
        let leftShift = ModifierKeys.shiftFlag | ModifierKeys.deviceLeftShiftFlag
        #expect(c.handleKey(try flagsChanged(56, flags: leftShift)))
        #expect(c.handleKey(try flagsChanged(56, flags: 0)))
        #expect(sink.messages == [
            .keyDown(KeyEvent(seq: 1, keyCode: 56, modifiers: leftShift, isRepeat: false)),
            .keyUp(KeyEvent(seq: 2, keyCode: 56, modifiers: 0, isRepeat: false)),
        ])
        #expect(c.state.isIdle)
    }

    @Test func releaseShortcutThroughNSEvent() throws {
        let (c, sink) = make()
        let ctrl = ModifierKeys.controlFlag | ModifierKeys.deviceLeftControlFlag
        let ctrlOpt = ctrl | ModifierKeys.optionFlag | ModifierKeys.deviceLeftOptionFlag
        #expect(c.handleKey(try flagsChanged(59, flags: ctrl)))
        #expect(c.handleKey(try flagsChanged(58, flags: ctrlOpt)))
        #expect(c.handleKey(try key(.keyDown, 53, [.control, .option])) == false)
        #expect(sink.messages.count == 2)
        c.releaseAll()
        #expect(sink.messages.count == 4)
        #expect(c.state.isIdle)
        #expect(c.handleKey(try key(.keyUp, 53, [])))
        #expect(sink.messages.count == 4)
    }

    @Test func mouseClickAndDoubleClick() throws {
        let (c, sink) = make()
        let p = CGPoint(x: 0.25, y: 0.75)
        c.handleMouse(try mouse(.leftMouseDown, clicks: 1), normalized: p)
        c.handleMouse(try mouse(.leftMouseUp, clicks: 1), normalized: p)
        c.handleMouse(try mouse(.leftMouseDown, clicks: 2), normalized: p)
        c.handleMouse(try mouse(.leftMouseUp, clicks: 2), normalized: p)
        let counts = sink.messages.compactMap { m -> UInt8? in
            switch m {
            case .mouseDown(let e), .mouseUp(let e): e.clickCount
            default: nil
            }
        }
        #expect(counts == [1, 1, 2, 2])
    }

    @Test func rightClickWithControlModifier() throws {
        let (c, sink) = make()
        c.handleMouse(try mouse(.rightMouseDown, flags: .control), normalized: CGPoint(x: 0.5, y: 0.5))
        c.handleMouse(try mouse(.rightMouseUp, flags: .control), normalized: CGPoint(x: 0.5, y: 0.5))
        #expect(sink.messages == [
            .mouseDown(MouseButtonEvent(seq: 1, button: .right, x: 0.5, y: 0.5, clickCount: 1, modifiers: ModifierKeys.controlFlag)),
            .mouseUp(MouseButtonEvent(seq: 2, button: .right, x: 0.5, y: 0.5, clickCount: 1, modifiers: ModifierKeys.controlFlag)),
        ])
    }

    @Test func dragEventsCarryButtonMask() throws {
        let (c, sink) = make()
        c.handleMouse(try mouse(.leftMouseDown, t: 1), normalized: CGPoint(x: 0.5, y: 0.5))
        c.handleMouse(try mouse(.leftMouseDragged, t: 1.010), normalized: CGPoint(x: 0.625, y: 0.5))
        c.handleMouse(try mouse(.leftMouseUp, t: 1.020), normalized: CGPoint(x: 0.625, y: 0.5))
        #expect(sink.pointers == [PointerState(seq: 2, x: 0.625, y: 0.5, buttonsMask: 1)])
    }

    @Test func throttledFinalPositionIsDeliveredByTrailingFlush() async throws {
        let (c, sink) = make()
        c.handleMouse(try mouse(.mouseMoved, t: 5.000), normalized: CGPoint(x: 0.25, y: 0.25))
        c.handleMouse(try mouse(.mouseMoved, t: 5.001), normalized: CGPoint(x: 0.5, y: 0.5))
        #expect(sink.pointers.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sink.pointers.map(\.x) == [0.25, 0.5])
    }

    @Test func scrollEventFromCoreGraphics() throws {
        let (c, sink) = make()
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -7, wheel2: 3, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))
        c.handleScroll(try #require(NSEvent(cgEvent: cg)))
        #expect(sink.messages == [
            .scroll(ScrollEvent(seq: 1, deltaX: 3, deltaY: -7, isPrecise: true, phase: UInt8(NSEvent.Phase.changed.rawValue), momentumPhase: 0)),
        ])
    }

    @Test func nonInputEventTypesAreIgnored() throws {
        let (c, sink) = make()
        c.handleMouse(try key(.keyDown, 0), normalized: CGPoint(x: 0.5, y: 0.5))
        c.handleScroll(try mouse(.leftMouseDown))
        #expect(sink.items.isEmpty)
    }
}
