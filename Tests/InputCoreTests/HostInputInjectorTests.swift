import CoreGraphics
import Testing
import WireProtocol
@testable import InputCore

@Suite struct HostInputInjectorTests {
    private static let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)

    private func makeInjector(trusted: Bool = true, authorize: Bool = true) -> (HostInputInjector, RecordingPoster) {
        let poster = RecordingPoster()
        let injector = HostInputInjector(displayFrame: Self.frame, poster: poster, trustCheck: { trusted })
        if authorize { injector.setAuthorized(true) }
        return (injector, poster)
    }

    private func down(_ seq: UInt32, _ button: MouseButton = .left, x: Float, y: Float, clicks: UInt8 = 1, flags: UInt64 = 0) -> ControlMessage {
        .mouseDown(MouseButtonEvent(seq: seq, button: button, x: x, y: y, clickCount: clicks, modifiers: flags))
    }

    private func up(_ seq: UInt32, _ button: MouseButton = .left, x: Float, y: Float, clicks: UInt8 = 1, flags: UInt64 = 0) -> ControlMessage {
        .mouseUp(MouseButtonEvent(seq: seq, button: button, x: x, y: y, clickCount: clicks, modifiers: flags))
    }

    // MARK: Authorization

    @Test func unauthorizedDropsEverything() {
        let (injector, poster) = makeInjector(authorize: false)
        injector.handle(down(1, x: 0.5, y: 0.5))
        injector.handle(.keyDown(KeyEvent(seq: 2, keyCode: 0, modifiers: 0)))
        injector.handlePointer(PointerState(seq: 3, x: 0.1, y: 0.1, buttonsMask: 0))
        injector.waitUntilIdle()
        #expect(poster.events.isEmpty)
        #expect(!injector.canInject)
        #expect(injector.stats.droppedUnauthorized == 3)
    }

    @Test func untrustedProcessNeverInjectsEvenWhenAuthorized() {
        let (injector, poster) = makeInjector(trusted: false)
        #expect(!injector.canInject)
        injector.handle(down(1, x: 0.5, y: 0.5))
        injector.waitUntilIdle()
        #expect(poster.events.isEmpty)
    }

    @Test func nonInputMessagesAreIgnored() {
        let (injector, poster) = makeInjector()
        #expect(injector.canInject)
        injector.handle(.ping(Ping(id: 1, sentAtNanos: 2)))
        injector.handle(.requestKeyframe(reason: 0))
        injector.waitUntilIdle()
        #expect(poster.events.isEmpty)
        #expect(injector.stats.droppedUnauthorized == 0)
    }

    // MARK: Mouse

    @Test func clickIsMoveThenDownThenUp() {
        let (injector, poster) = makeInjector()
        injector.handle(down(1, x: 0.5, y: 0.5, flags: ModifierKeys.commandFlag))
        injector.handle(up(2, x: 0.5, y: 0.5, flags: ModifierKeys.commandFlag))
        injector.waitUntilIdle()
        let p = CGPoint(x: 500, y: 250)
        #expect(poster.events == [
            .mouse(type: .mouseMoved, button: .left, point: p, clickState: 0, flags: ModifierKeys.commandFlag),
            .mouse(type: .leftMouseDown, button: .left, point: p, clickState: 1, flags: ModifierKeys.commandFlag),
            .mouse(type: .leftMouseUp, button: .left, point: p, clickState: 1, flags: ModifierKeys.commandFlag),
        ])
        #expect(injector.stats.eventsPosted == 3)
    }

    @Test func doubleClickCarriesClickState2() {
        let (injector, poster) = makeInjector()
        injector.handle(down(1, x: 0.1, y: 0.2))
        injector.handle(up(2, x: 0.1, y: 0.2))
        injector.handle(down(3, x: 0.1, y: 0.2, clicks: 2))
        injector.handle(up(4, x: 0.1, y: 0.2, clicks: 2))
        injector.waitUntilIdle()
        let states = poster.events.compactMap { e -> Int64? in
            if case let .mouse(type, _, _, clickState, _) = e, type != .mouseMoved { clickState } else { nil }
        }
        #expect(states == [1, 1, 2, 2])
    }

    @Test func rightAndOtherButtonsUseTheirEventTypes() {
        let (injector, poster) = makeInjector()
        injector.handle(down(1, .right, x: 0, y: 0))
        injector.handle(up(2, .right, x: 0, y: 0))
        injector.handle(down(3, .other, x: 0, y: 0))
        injector.handle(up(4, .other, x: 0, y: 0))
        injector.waitUntilIdle()
        let typed = poster.events.compactMap { e -> String? in
            if case let .mouse(type, button, _, _, _) = e { "\(type.rawValue):\(button.rawValue)" } else { nil }
        }
        #expect(typed == [
            "\(CGEventType.mouseMoved.rawValue):0",
            "\(CGEventType.rightMouseDown.rawValue):\(CGMouseButton.right.rawValue)",
            "\(CGEventType.rightMouseUp.rawValue):\(CGMouseButton.right.rawValue)",
            "\(CGEventType.mouseMoved.rawValue):0",
            "\(CGEventType.otherMouseDown.rawValue):\(CGMouseButton.center.rawValue)",
            "\(CGEventType.otherMouseUp.rawValue):\(CGMouseButton.center.rawValue)",
        ])
    }

    @Test func pointerMovesWhileHeldBecomeDrags() {
        let (injector, poster) = makeInjector()
        injector.handlePointer(PointerState(seq: 1, x: 0.125, y: 0.125, buttonsMask: 0))
        injector.handle(down(2, x: 0.25, y: 0.25, clicks: 2))
        injector.handlePointer(PointerState(seq: 3, x: 0.375, y: 0.375, buttonsMask: 1))
        injector.handle(.mouseMove(PointerState(seq: 4, x: 0.5, y: 0.5, buttonsMask: 1)))
        injector.handle(up(5, x: 0.5, y: 0.5, clicks: 2))
        injector.handlePointer(PointerState(seq: 6, x: 0.625, y: 0.625, buttonsMask: 0))
        injector.waitUntilIdle()
        #expect(poster.events == [
            .mouse(type: .mouseMoved, button: .left, point: CGPoint(x: 125, y: 62.5), clickState: 0, flags: 0),
            .mouse(type: .mouseMoved, button: .left, point: CGPoint(x: 250, y: 125), clickState: 0, flags: 0),
            .mouse(type: .leftMouseDown, button: .left, point: CGPoint(x: 250, y: 125), clickState: 2, flags: 0),
            .mouse(type: .leftMouseDragged, button: .left, point: CGPoint(x: 375, y: 187.5), clickState: 2, flags: 0),
            .mouse(type: .leftMouseDragged, button: .left, point: CGPoint(x: 500, y: 250), clickState: 2, flags: 0),
            .mouse(type: .leftMouseUp, button: .left, point: CGPoint(x: 500, y: 250), clickState: 2, flags: 0),
            .mouse(type: .mouseMoved, button: .left, point: CGPoint(x: 625, y: 312.5), clickState: 0, flags: 0),
        ])
    }

    @Test func rightAndOtherDragTypes() {
        let (injector, poster) = makeInjector()
        injector.handle(down(1, .right, x: 0.1, y: 0.1))
        injector.handlePointer(PointerState(seq: 2, x: 0.2, y: 0.1, buttonsMask: 2))
        injector.handle(up(3, .right, x: 0.2, y: 0.1))
        injector.handle(down(4, .other, x: 0.2, y: 0.1))
        injector.handlePointer(PointerState(seq: 5, x: 0.3, y: 0.1, buttonsMask: 4))
        injector.waitUntilIdle()
        let drags = poster.events.compactMap { e -> CGEventType? in
            if case let .mouse(type, _, _, _, _) = e,
               [.rightMouseDragged, .otherMouseDragged, .leftMouseDragged].contains(type) { type } else { nil }
        }
        #expect(drags == [.rightMouseDragged, .otherMouseDragged])
    }

    @Test func stalePointerSequenceIsDropped() {
        let (injector, poster) = makeInjector()
        injector.handlePointer(PointerState(seq: 10, x: 0.5, y: 0.5, buttonsMask: 0))
        injector.handlePointer(PointerState(seq: 9, x: 0.1, y: 0.1, buttonsMask: 0))
        injector.handlePointer(PointerState(seq: 10, x: 0.2, y: 0.2, buttonsMask: 0))
        injector.handle(.mouseMove(PointerState(seq: 8, x: 0.3, y: 0.3, buttonsMask: 0)))
        injector.waitUntilIdle()
        #expect(poster.events.count == 1)
        #expect(injector.stats.droppedStalePointer == 3)
    }

    /// A pointer datagram that was overtaken by a reliable click must not drag the cursor back behind it.
    @Test func pointerOlderThanAButtonEventIsDropped() {
        let (injector, poster) = makeInjector()
        injector.handle(down(5, x: 0.5, y: 0.5))
        injector.handlePointer(PointerState(seq: 4, x: 0.1, y: 0.1, buttonsMask: 0))
        injector.waitUntilIdle()
        #expect(poster.events.count == 2) // move + down only
        #expect(injector.stats.droppedStalePointer == 1)
    }

    /// MOUSE_UP (reliable stream) delayed by a retransmission while newer pointer datagrams (mask 0) arrive: they
    /// must not be posted as drags past the release point; the latest one is applied right after the late up
    /// (review finding input-2).
    @Test func pointerAfterADelayedMouseUpIsNotADrag() {
        let (injector, poster) = makeInjector()
        injector.handle(down(1, x: 0.25, y: 0.25))
        injector.handlePointer(PointerState(seq: 2, x: 0.375, y: 0.25, buttonsMask: 1))
        // MOUSE_UP seq 3 is held back; the user already moved away with the button released.
        injector.handlePointer(PointerState(seq: 4, x: 0.625, y: 0.5, buttonsMask: 0))
        injector.handlePointer(PointerState(seq: 5, x: 0.75, y: 0.5, buttonsMask: 0))
        injector.handle(up(3, x: 0.375, y: 0.25))
        injector.handlePointer(PointerState(seq: 6, x: 0.875, y: 0.5, buttonsMask: 0))
        injector.waitUntilIdle()
        #expect(poster.events == [
            .mouse(type: .mouseMoved, button: .left, point: CGPoint(x: 250, y: 125), clickState: 0, flags: 0),
            .mouse(type: .leftMouseDown, button: .left, point: CGPoint(x: 250, y: 125), clickState: 1, flags: 0),
            .mouse(type: .leftMouseDragged, button: .left, point: CGPoint(x: 375, y: 125), clickState: 1, flags: 0),
            .mouse(type: .leftMouseUp, button: .left, point: CGPoint(x: 375, y: 125), clickState: 1, flags: 0),
            .mouse(type: .mouseMoved, button: .left, point: CGPoint(x: 750, y: 250), clickState: 0, flags: 0),
            .mouse(type: .mouseMoved, button: .left, point: CGPoint(x: 875, y: 250), clickState: 0, flags: 0),
        ])
    }

    /// MOUSE_DOWN delayed while drag datagrams (mask left) arrive: they are held, then applied as a drag after the
    /// down, so the drag is not lost as plain moves.
    @Test func pointerBeforeADelayedMouseDownBecomesTheDrag() {
        let (injector, poster) = makeInjector()
        injector.handlePointer(PointerState(seq: 1, x: 0.125, y: 0.125, buttonsMask: 0))
        // MOUSE_DOWN seq 2 is held back.
        injector.handlePointer(PointerState(seq: 3, x: 0.25, y: 0.125, buttonsMask: 1))
        injector.handlePointer(PointerState(seq: 4, x: 0.375, y: 0.125, buttonsMask: 1))
        injector.handle(down(2, x: 0.125, y: 0.125))
        injector.handlePointer(PointerState(seq: 5, x: 0.5, y: 0.125, buttonsMask: 1))
        injector.handle(up(6, x: 0.5, y: 0.125))
        injector.waitUntilIdle()
        let types = poster.events.compactMap { e -> CGEventType? in
            if case let .mouse(type, _, _, _, _) = e { type } else { nil }
        }
        // The down itself always moves to its own point first (unchanged behavior).
        #expect(types == [.mouseMoved, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp])
        #expect(poster.events[3] == .mouse(type: .leftMouseDragged, button: .left, point: CGPoint(x: 375, y: 62.5),
                                           clickState: 1, flags: 0))
    }

    /// Safety valve: a mismatch that never resolves (the button event is gone, or state diverged) stops deferring
    /// after `maxDeferredSeqSpan`, so the cursor cannot freeze.
    @Test func persistentMaskMismatchStopsDeferring() {
        let (injector, poster) = makeInjector()
        let span = HostInjectionEngine.maxDeferredSeqSpan
        for seq in 1...(span + 2) {
            injector.handlePointer(PointerState(seq: seq, x: Float(seq) / Float(span * 2), y: 0.5, buttonsMask: 1))
        }
        injector.waitUntilIdle()
        #expect(poster.events.count == 2, "moves resume once the wait is exhausted: \(poster.events.count)")
    }

    @Test func reauthorizationResetsPointerSequence() {
        let (injector, poster) = makeInjector()
        injector.handlePointer(PointerState(seq: 500, x: 0.5, y: 0.5, buttonsMask: 0))
        injector.setAuthorized(false)
        injector.setAuthorized(true)
        injector.handlePointer(PointerState(seq: 1, x: 0.1, y: 0.1, buttonsMask: 0))
        injector.waitUntilIdle()
        #expect(poster.events.count == 2)
    }

    @Test func displayFrameUpdateAppliesToSubsequentEvents() {
        let (injector, poster) = makeInjector()
        injector.updateDisplayFrame(CGRect(x: -800, y: 0, width: 800, height: 600))
        injector.handlePointer(PointerState(seq: 1, x: 0.5, y: 0.5, buttonsMask: 0))
        injector.waitUntilIdle()
        #expect(poster.events == [.mouse(type: .mouseMoved, button: .left, point: CGPoint(x: -400, y: 300), clickState: 0, flags: 0)])
    }

    // MARK: Keys

    @Test func keysCarryFlagsAndAutorepeat() {
        let (injector, poster) = makeInjector()
        let shift = ModifierKeys.shiftFlag
        injector.handle(.keyDown(KeyEvent(seq: 1, keyCode: 56, modifiers: shift)))
        injector.handle(.keyDown(KeyEvent(seq: 2, keyCode: 0, modifiers: shift)))
        injector.handle(.keyDown(KeyEvent(seq: 3, keyCode: 0, modifiers: shift, isRepeat: true)))
        injector.handle(.keyUp(KeyEvent(seq: 4, keyCode: 0, modifiers: shift)))
        injector.handle(.keyUp(KeyEvent(seq: 5, keyCode: 56, modifiers: 0)))
        injector.waitUntilIdle()
        #expect(poster.events == [
            .key(keyCode: 56, down: true, flags: shift, autorepeat: false),
            .key(keyCode: 0, down: true, flags: shift, autorepeat: false),
            .key(keyCode: 0, down: true, flags: shift, autorepeat: true),
            .key(keyCode: 0, down: false, flags: shift, autorepeat: false),
            .key(keyCode: 56, down: false, flags: 0, autorepeat: false),
        ])
    }

    @Test func receivedFlagsAreSanitized() {
        let (injector, poster) = makeInjector()
        injector.handle(.keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: ModifierKeys.commandFlag | 0xFFFF_0000_0000_0100)))
        injector.waitUntilIdle()
        #expect(poster.events == [.key(keyCode: 0, down: true, flags: ModifierKeys.commandFlag, autorepeat: false)])
    }

    // MARK: Release

    @Test func revokeReleasesHeldKeysAndButtonsThenRejects() {
        let (injector, poster) = makeInjector()
        let cmd = ModifierKeys.commandFlag
        injector.handle(.keyDown(KeyEvent(seq: 1, keyCode: 55, modifiers: cmd)))
        injector.handle(.keyDown(KeyEvent(seq: 2, keyCode: 8, modifiers: cmd)))
        injector.handle(down(3, x: 0.5, y: 0.5, flags: cmd))
        injector.waitUntilIdle()
        poster.clear()

        injector.setAuthorized(false)
        #expect(!injector.canInject)
        injector.handle(.keyDown(KeyEvent(seq: 4, keyCode: 9, modifiers: 0)))
        injector.waitUntilIdle()
        #expect(poster.events == [
            .mouse(type: .leftMouseUp, button: .left, point: CGPoint(x: 500, y: 250), clickState: 1, flags: cmd),
            .key(keyCode: 8, down: false, flags: cmd, autorepeat: false),
            .key(keyCode: 55, down: false, flags: 0, autorepeat: false),
        ])
    }

    @Test func releaseAllIsIdempotent() {
        let (injector, poster) = makeInjector()
        injector.handle(.keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: 0)))
        injector.releaseAll()
        injector.releaseAll()
        injector.waitUntilIdle()
        #expect(poster.events == [
            .key(keyCode: 0, down: true, flags: 0, autorepeat: false),
            .key(keyCode: 0, down: false, flags: 0, autorepeat: false),
        ])
    }

    @Test func releaseWithoutCursorStillReleasesKeys() {
        var engine = HostInjectionEngine(displayFrame: Self.frame)
        var out: [PostedEvent] = []
        // Nothing was ever positioned by this engine: the release must not need a cursor position.
        engine.handle(.keyDown(KeyEvent(seq: 1, keyCode: 0, modifiers: 0))) { out.append($0) }
        engine.releaseAll(fallbackCursor: CGPoint(x: 7, y: 9)) { out.append($0) }
        #expect(out.last == .key(keyCode: 0, down: false, flags: 0, autorepeat: false))
        #expect(engine.heldKeys.isEmpty)
    }

    // MARK: Scroll

    @Test func preciseScrollPostsPixelsWithPhasesAndCarriesRemainders() {
        let (injector, poster) = makeInjector()
        injector.handle(.scroll(ScrollEvent(seq: 1, deltaX: 0, deltaY: 0, isPrecise: true, phase: 1)))          // began
        injector.handle(.scroll(ScrollEvent(seq: 2, deltaX: -2.5, deltaY: 10.6, isPrecise: true, phase: 4)))    // changed
        injector.handle(.scroll(ScrollEvent(seq: 3, deltaX: -0.5, deltaY: 0.5, isPrecise: true, phase: 4)))
        injector.handle(.scroll(ScrollEvent(seq: 4, deltaX: 0, deltaY: 0, isPrecise: true, phase: 8)))          // ended
        injector.handle(.scroll(ScrollEvent(seq: 5, deltaX: 0, deltaY: 30, isPrecise: true, momentumPhase: 1))) // momentum begin
        injector.waitUntilIdle()
        #expect(poster.events == [
            .scroll(units: .pixel, wheel1: 0, wheel2: 0, fixedPoint1: nil, fixedPoint2: nil, scrollPhase: 1, momentumPhase: 0, continuous: true, flags: 0),
            .scroll(units: .pixel, wheel1: 10, wheel2: -2, fixedPoint1: nil, fixedPoint2: nil, scrollPhase: 2, momentumPhase: 0, continuous: true, flags: 0),
            .scroll(units: .pixel, wheel1: 1, wheel2: -1, fixedPoint1: nil, fixedPoint2: nil, scrollPhase: 2, momentumPhase: 0, continuous: true, flags: 0),
            .scroll(units: .pixel, wheel1: 0, wheel2: 0, fixedPoint1: nil, fixedPoint2: nil, scrollPhase: 4, momentumPhase: 0, continuous: true, flags: 0),
            .scroll(units: .pixel, wheel1: 30, wheel2: 0, fixedPoint1: nil, fixedPoint2: nil, scrollPhase: 0, momentumPhase: 1, continuous: true, flags: 0),
        ])
    }

    @Test func lineScrollRoundsAndCarriesExactFraction() {
        let (injector, poster) = makeInjector()
        injector.handle(.scroll(ScrollEvent(seq: 1, deltaX: 0, deltaY: 3, isPrecise: false)))
        injector.handle(.scroll(ScrollEvent(seq: 2, deltaX: 0, deltaY: 0.25, isPrecise: false)))
        injector.handle(.scroll(ScrollEvent(seq: 3, deltaX: 0, deltaY: 0.25, isPrecise: false)))
        injector.waitUntilIdle()
        #expect(poster.events == [
            .scroll(units: .line, wheel1: 3, wheel2: 0, fixedPoint1: 3, fixedPoint2: 0, scrollPhase: 0, momentumPhase: 0, continuous: false, flags: 0),
            .scroll(units: .line, wheel1: 0, wheel2: 0, fixedPoint1: 0.25, fixedPoint2: 0, scrollPhase: 0, momentumPhase: 0, continuous: false, flags: 0),
            .scroll(units: .line, wheel1: 1, wheel2: 0, fixedPoint1: 0.25, fixedPoint2: 0, scrollPhase: 0, momentumPhase: 0, continuous: false, flags: 0),
        ])
    }

    @Test func scrollUsesHeldModifiers() {
        let (injector, poster) = makeInjector()
        injector.handle(.keyDown(KeyEvent(seq: 1, keyCode: 59, modifiers: ModifierKeys.controlFlag)))
        injector.handle(.scroll(ScrollEvent(seq: 2, deltaX: 0, deltaY: 5, isPrecise: true, phase: 4)))
        injector.waitUntilIdle()
        guard case let .scroll(_, _, _, _, _, _, _, _, flags) = poster.events.last else {
            Issue.record("expected scroll")
            return
        }
        #expect(flags == ModifierKeys.controlFlag)
    }
}

@Suite struct ScrollConversionTests {
    @Test func phaseMappingAppKitToCoreGraphics() {
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 0) == 0)
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 1) == Int64(CGScrollPhase.began.rawValue))
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 2) == Int64(CGScrollPhase.changed.rawValue))
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 4) == Int64(CGScrollPhase.changed.rawValue))
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 8) == Int64(CGScrollPhase.ended.rawValue))
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 16) == Int64(CGScrollPhase.cancelled.rawValue))
        #expect(ScrollPhaseMapping.cgScrollPhase(fromAppKit: 32) == Int64(CGScrollPhase.mayBegin.rawValue))
        #expect(ScrollPhaseMapping.cgMomentumPhase(fromAppKit: 0) == 0)
        #expect(ScrollPhaseMapping.cgMomentumPhase(fromAppKit: 1) == Int64(CGMomentumScrollPhase.begin.rawValue))
        #expect(ScrollPhaseMapping.cgMomentumPhase(fromAppKit: 4) == Int64(CGMomentumScrollPhase.continuous.rawValue))
        #expect(ScrollPhaseMapping.cgMomentumPhase(fromAppKit: 8) == Int64(CGMomentumScrollPhase.end.rawValue))
        #expect(ScrollPhaseMapping.cgMomentumPhase(fromAppKit: 16) == Int64(CGMomentumScrollPhase.end.rawValue))
    }

    @Test func pixelRemaindersAccumulateAndResetOnReversal() {
        var acc = ScrollAccumulator()
        var total: Int32 = 0
        for _ in 0..<10 { total += acc.take(deltaX: 0, deltaY: 0.3, isPrecise: true).y }
        #expect(total == 3)
        // Reversal discards the pending +0.0..0.9 remainder: the first -0.6 alone does not move yet, -1.2 does.
        #expect(acc.take(deltaX: 0, deltaY: -0.6, isPrecise: true).y == 0)
        #expect(acc.take(deltaX: 0, deltaY: -0.6, isPrecise: true).y == -1)
    }

    @Test func hostileDeltasNeverTrap() {
        var acc = ScrollAccumulator()
        let a = acc.take(deltaX: .infinity, deltaY: -1e30, isPrecise: true)
        #expect(a.x == 0 && a.y == -10_000)
        let b = acc.take(deltaX: .nan, deltaY: 1e30, isPrecise: false)
        #expect(b.x == 0 && b.y == 10_000)
    }

    @Test func unitChangeResetsRemainders() {
        var acc = ScrollAccumulator()
        #expect(acc.take(deltaX: 0, deltaY: 0.9, isPrecise: true).y == 0)
        #expect(acc.take(deltaX: 0, deltaY: 0.4, isPrecise: false).y == 0)
    }
}
