import AppKit
import WireProtocol

/// Viewer side. Translates NSEvents into wire messages, tracks held keys/buttons and owns sequence numbers.
///
/// A thin AppKit adapter over `ViewerInputTranslator`: it only extracts plain values from `NSEvent` and calls
/// `send` synchronously on the main thread (where AppKit delivers events), so input is never delayed by an
/// actor hop or task. `send` must be cheap and non-blocking (hand off to the transport queue).
@MainActor
public final class ViewerInputController {
    /// Local shortcut that stops remote keyboard capture. Never forwarded to the Host.
    public nonisolated static let releaseShortcutDescription: String = "⌃⌥⎋"

    private let send: @Sendable (OutgoingInput) -> Void
    private var translator = ViewerInputTranslator()
    private var trailingFlushScheduled = false

    public init(send: @escaping @Sendable (OutgoingInput) -> Void) {
        self.send = send
    }

    /// Current held-state snapshot (diagnostics/tests).
    public var state: InputStateTracker { translator.tracker }

    /// Mouse buttons, moves and drags. `normalized` is the point in the video (0,0 top-left), nil outside it.
    /// Buttons beyond the third (back/forward) are not forwarded: the protocol has a single "other" button and
    /// turning "back" into a middle click on the Host would be worse than doing nothing.
    public func handleMouse(_ event: NSEvent, normalized: CGPoint?) {
        let send = self.send
        let timestamp = Self.nanos(event.timestamp)
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            guard let (button, down) = Self.button(for: event) else { return }
            translator.mouseButton(button, down: down, normalized: normalized, clickCount: event.clickCount,
                                   appKitFlags: event.modifierFlags.rawValue, timestampNanos: timestamp) { send($0) }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if let due = translator.mouseMoved(normalized: normalized, timestampNanos: timestamp, emit: { send($0) }) {
                scheduleTrailingFlush(dueNanos: due, eventNanos: timestamp)
            }
        default:
            return
        }
    }

    public func handleScroll(_ event: NSEvent) {
        guard event.type == .scrollWheel else { return }
        let send = self.send
        translator.scroll(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
                          isPrecise: event.hasPreciseScrollingDeltas,
                          phase: UInt8(truncatingIfNeeded: event.phase.rawValue),
                          momentumPhase: UInt8(truncatingIfNeeded: event.momentumPhase.rawValue)) { send($0) }
    }

    /// Returns false if this was the local release shortcut (caller stops capturing; nothing is sent).
    /// The caller should then call `releaseAll()` so the Control/Option already forwarded are released on the Host;
    /// the shortcut's Escape itself is never recorded as held, so its later key-up is not forwarded either.
    public func handleKey(_ event: NSEvent) -> Bool {
        let kind: ViewerInputTranslator.KeyKind
        switch event.type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .flagsChanged
        default: return true
        }
        let send = self.send
        let isRepeat = kind == .down ? event.isARepeat : false
        return translator.key(kind, keyCode: event.keyCode, appKitFlags: event.modifierFlags.rawValue,
                              isRepeat: isRepeat) { send($0) }
    }

    /// A key event taken by `SystemShortcutTap` (plain values; the tap never hands out its `CGEvent`). Same rules
    /// and return value as `handleKey(_:)`.
    public func handleKey(_ event: TapKeyEvent) -> Bool {
        let kind: ViewerInputTranslator.KeyKind = switch event.kind {
        case .down: .down
        case .up: .up
        case .flagsChanged: .flagsChanged
        }
        let send = self.send
        return translator.key(kind, keyCode: event.keyCode, appKitFlags: UInt(truncatingIfNeeded: event.flags),
                              isRepeat: kind == .down ? event.isRepeat : false) { send($0) }
    }

    /// Presses `chord` once on the Host ("Send Keys" menu): releases anything held, then modifiers down, the key down
    /// and up, and the modifiers up in reverse order, all on the reliable stream.
    public func send(_ chord: KeyChord) {
        let send = self.send
        translator.chord(chord) { send($0) }
    }

    /// Key-up for every held key, mouse-up for every held button. Call on focus loss, capture stop and disconnect.
    public func releaseAll() {
        let send = self.send
        translator.releaseAll { send($0) }
    }

    // MARK: - Private

    private static func button(for event: NSEvent) -> (MouseButton, Bool)? {
        switch event.type {
        case .leftMouseDown: (.left, true)
        case .leftMouseUp: (.left, false)
        case .rightMouseDown: (.right, true)
        case .rightMouseUp: (.right, false)
        case .otherMouseDown where event.buttonNumber == 2: (.other, true)
        case .otherMouseUp where event.buttonNumber == 2: (.other, false)
        default: nil
        }
    }

    /// One outstanding timer at most (not one per event) delivers a throttled final position.
    private func scheduleTrailingFlush(dueNanos: UInt64, eventNanos: UInt64) {
        guard !trailingFlushScheduled else { return }
        trailingFlushScheduled = true
        let delay = dueNanos > eventNanos ? dueNanos - eventNanos : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(min(delay, 1_000_000_000)))) { [weak self] in
            MainActor.assumeIsolated { self?.trailingFlush(atNanos: dueNanos) }
        }
    }

    /// Uses the due time (event clock) as "now" so the throttle stays in the `NSEvent.timestamp` time base.
    private func trailingFlush(atNanos nanos: UInt64) {
        trailingFlushScheduled = false
        let send = self.send
        translator.flushPendingPointer(nowNanos: nanos) { send($0) }
    }

    /// `NSEvent.timestamp` is seconds of system uptime; nanoseconds keep the translator integer-only.
    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    }
}
