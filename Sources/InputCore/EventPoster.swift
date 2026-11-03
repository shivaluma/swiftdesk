import CoreGraphics

/// Sink for injected events. Lets the injection rules be tested with a recorder instead of moving the real cursor.
/// Called only on `HostInputInjector`'s serial queue.
protocol EventPoster: AnyObject, Sendable {
    func post(_ event: PostedEvent)
    /// Current system cursor position (global points), used when releasing buttons before anything was moved.
    func cursorLocation() -> CGPoint?
}

/// Real poster: builds `CGEvent`s from a `.hidSystemState` source and posts them at the HID tap, so injected
/// events enter the system exactly where hardware events do (window server routing, key repeat, cursor movement).
///
/// `@unchecked Sendable`: the event source is created once and used only from the injector's serial queue.
final class CGEventPoster: EventPoster, @unchecked Sendable {
    private var source: CGEventSource?
    private(set) var creationFailures: UInt64 = 0

    init() {}

    private func eventSource() -> CGEventSource? {
        if source == nil { source = CGEventSource(stateID: .hidSystemState) }
        return source
    }

    func cursorLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    func post(_ event: PostedEvent) {
        let source = eventSource()
        let cgEvent: CGEvent?
        let flags: UInt64
        switch event {
        case let .mouse(type, button, point, clickState, eventFlags):
            cgEvent = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            if clickState > 0 { cgEvent?.setIntegerValueField(.mouseEventClickState, value: clickState) }
            flags = eventFlags
        case let .key(keyCode, down, eventFlags, autorepeat):
            // Modifier virtual keys come out as `flagsChanged` automatically (verified on macOS 27.2), and the
            // key-up still carries the modifier's bit, so flags are always set explicitly below.
            cgEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            if autorepeat { cgEvent?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            flags = eventFlags
        case let .scroll(units, wheel1, wheel2, fixed1, fixed2, scrollPhase, momentumPhase, continuous, eventFlags):
            cgEvent = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                              wheel1: wheel1, wheel2: wheel2, wheel3: 0)
            if let fixed1 { cgEvent?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed1) }
            if let fixed2 { cgEvent?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed2) }
            cgEvent?.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
            cgEvent?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            cgEvent?.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
            flags = eventFlags
        }
        guard let cgEvent else {
            creationFailures &+= 1
            return
        }
        // Replace only key-state bits; keep whatever else the source stamped on the event.
        cgEvent.flags = CGEventFlags(rawValue: (cgEvent.flags.rawValue & ~ModifierKeys.forwardedMask) | flags)
        cgEvent.post(tap: .cghidEventTap)
    }
}
