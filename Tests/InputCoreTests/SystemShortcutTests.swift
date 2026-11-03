import CoreGraphics
import Synchronization
import Testing
import WireProtocol
@testable import InputCore

/// 0.1.7 system shortcuts: the Send Keys key sequences and the keyboard tap's filter decision (both pure).
@Suite struct SystemShortcutTests {
    private let leftCommand = ModifierKeys.deviceLeftCommandFlag
    private let leftOption = ModifierKeys.deviceLeftOptionFlag
    private let leftControl = ModifierKeys.deviceLeftControlFlag
    private let leftShift = ModifierKeys.deviceLeftShiftFlag

    // MARK: Key sequences

    @Test func forceQuitIsModifiersDownKeyThenModifiersUpInReverse() {
        let strokes = SystemShortcut.forceQuit.chord.strokes
        let option = Flags.option | leftOption
        let both = option | Flags.command | leftCommand
        #expect(strokes == [
            KeyStroke(keyCode: ModifierKeys.option, isDown: true, flags: option),
            KeyStroke(keyCode: ModifierKeys.command, isDown: true, flags: both),
            KeyStroke(keyCode: ModifierKeys.escape, isDown: true, flags: both),
            KeyStroke(keyCode: ModifierKeys.escape, isDown: false, flags: both),
            KeyStroke(keyCode: ModifierKeys.command, isDown: false, flags: option),
            KeyStroke(keyCode: ModifierKeys.option, isDown: false, flags: 0),
        ])
    }

    @Test func everyShortcutIsBalancedAndEndsWithNothingHeld() {
        for shortcut in SystemShortcut.allCases {
            let chord = shortcut.chord
            let strokes = chord.strokes
            #expect(strokes.count == chord.modifiers.count * 2 + 2, "\(shortcut)")
            #expect(strokes.filter(\.isDown).count == strokes.filter { !$0.isDown }.count, "\(shortcut)")
            // Only the key's own fn / keypad flags may remain (on its key-up when there are no modifiers).
            let leftover = (strokes.last?.flags ?? 0) & ~ModifierKeys.intrinsicFlags(forKeyCode: chord.keyCode)
            #expect(leftover == 0, "\(shortcut): a modifier flag would stay set on the Host")
            // Downs first (modifiers in order, then the key), ups mirror them.
            let downs = strokes.prefix(chord.modifiers.count + 1).map(\.keyCode)
            let ups = strokes.suffix(chord.modifiers.count + 1).map(\.keyCode)
            #expect(downs == chord.modifiers + [chord.keyCode], "\(shortcut)")
            #expect(ups == [chord.keyCode] + chord.modifiers.reversed(), "\(shortcut)")
            let leadingDowns = strokes.prefix(chord.modifiers.count + 1).filter(\.isDown).count
            #expect(leadingDowns == chord.modifiers.count + 1, "\(shortcut)")
            // The key itself carries every modifier's flag.
            let keyDown = strokes[chord.modifiers.count]
            for modifier in chord.modifiers {
                #expect(keyDown.flags & (ModifierKeys.flag(forKeyCode: modifier) ?? 0) != 0, "\(shortcut)")
            }
        }
    }

    @Test func defaultChordsMatchTheMacOSShortcuts() {
        #expect(SystemShortcut.appSwitcher.chord == KeyChord(keyCode: 0x30, modifiers: [ModifierKeys.command]))
        #expect(SystemShortcut.spotlight.chord == KeyChord(keyCode: 0x31, modifiers: [ModifierKeys.command]))
        #expect(SystemShortcut.emojiAndSymbols.chord
            == KeyChord(keyCode: 0x31, modifiers: [ModifierKeys.control, ModifierKeys.command]))
        #expect(SystemShortcut.missionControl.chord == KeyChord(keyCode: 0x7E, modifiers: [ModifierKeys.control]))
        #expect(SystemShortcut.appExpose.chord == KeyChord(keyCode: 0x7D, modifiers: [ModifierKeys.control]))
        #expect(SystemShortcut.showDesktop.chord == KeyChord(keyCode: 0x67))
        #expect(SystemShortcut.launchpad.chord == KeyChord(keyCode: 131))
        #expect(SystemShortcut.screenshotScreen.chord
            == KeyChord(keyCode: 0x14, modifiers: [ModifierKeys.shift, ModifierKeys.command]))
        #expect(SystemShortcut.screenshotSelection.chord.keyCode == 0x15)
        #expect(SystemShortcut.screenshotOptions.chord.keyCode == 0x17)
        #expect(SystemShortcut.lockScreen.chord
            == KeyChord(keyCode: 0x0C, modifiers: [ModifierKeys.control, ModifierKeys.command]))
    }

    @Test func arrowAndFunctionKeysCarryTheirHardwareFlags() {
        // Mission Control's default is stored as ⌃ + fn + ↑: without fn the WindowServer would not match it.
        let mission = SystemShortcut.missionControl.chord.strokes
        #expect(mission[1] == KeyStroke(keyCode: 0x7E, isDown: true,
                                        flags: Flags.control | leftControl | Flags.fn | ModifierKeys.numericPadFlag))
        #expect(mission[0].flags & Flags.fn == 0, "only the arrow itself carries fn")
        let desktop = SystemShortcut.showDesktop.chord.strokes
        #expect(desktop == [KeyStroke(keyCode: 0x67, isDown: true, flags: Flags.fn),
                            KeyStroke(keyCode: 0x67, isDown: false, flags: Flags.fn)])
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 0x7B) == Flags.fn | ModifierKeys.numericPadFlag)
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 0x7A) == Flags.fn)   // F1
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 0x5A) == Flags.fn)   // F20
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 0x75) == Flags.fn)   // forward delete
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 0x0C) == 0)          // Q
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 0x31) == 0)          // space
        #expect(ModifierKeys.intrinsicFlags(forKeyCode: 131) == 0)           // Launchpad key
    }

    @Test func keysAreDescribedInApplesModifierOrder() {
        #expect(SystemShortcut.appSwitcher.keysDescription == "⌘Tab")
        #expect(SystemShortcut.spotlight.keysDescription == "⌘Space")
        #expect(SystemShortcut.emojiAndSymbols.keysDescription == "⌃⌘Space")
        #expect(SystemShortcut.forceQuit.keysDescription == "⌥⌘Esc")
        #expect(SystemShortcut.lockScreen.keysDescription == "⌃⌘Q")
        #expect(SystemShortcut.screenshotScreen.keysDescription == "⇧⌘3")
        #expect(SystemShortcut.missionControl.keysDescription == "⌃↑")
        #expect(SystemShortcut.showDesktop.keysDescription == "F11")
        // Modifier order in the chord does not change the description.
        #expect(KeyChord(keyCode: 0x14, modifiers: [ModifierKeys.command, ModifierKeys.shift]).symbols == "⇧⌘3")
    }

    @Test func menuGroupsCoverEveryShortcutOnceAndOnlyLockScreenAsksFirst() {
        let grouped = SystemShortcut.Group.allCases.flatMap(SystemShortcut.shortcuts(in:))
        #expect(grouped.count == SystemShortcut.allCases.count)
        #expect(Set(grouped) == Set(SystemShortcut.allCases))
        #expect(SystemShortcut.allCases.filter(\.needsConfirmation) == [.lockScreen])
        #expect(Set(SystemShortcut.allCases.map(\.title)).count == SystemShortcut.allCases.count)
    }

    // MARK: Translator / controller

    @Test func chordBecomesOrderedKeyMessagesAfterReleasingHeldKeys() {
        var translator = ViewerInputTranslator()
        var out = Collected()
        _ = translator.key(.down, keyCode: 0, appKitFlags: 0, isRepeat: false) { out.items.append($0) }
        translator.chord(SystemShortcut.spotlight.chord) { out.items.append($0) }
        let m = out.messages
        #expect(m.count == 6)
        guard m.count == 6 else { return }
        // The held "A" is released first, so the Host sees ⌘Space and nothing else.
        if case .keyUp(let k) = m[1] { #expect(k.keyCode == 0) } else { Issue.record("expected key-up, got \(m[1])") }
        let expected: [(Bool, UInt16, UInt64)] = [
            (true, ModifierKeys.command, Flags.command | leftCommand),
            (true, 0x31, Flags.command | leftCommand),
            (false, 0x31, Flags.command | leftCommand),
            (false, ModifierKeys.command, 0),
        ]
        for (message, (down, code, flags)) in zip(m[2...], expected) {
            switch message {
            case .keyDown(let k) where down, .keyUp(let k) where !down:
                #expect(k.keyCode == code && k.modifiers == flags && !k.isRepeat, "\(message)")
            default:
                Issue.record("unexpected \(message)")
            }
        }
        let seqs = out.items.compactMap(\.seq)
        #expect(seqs == Array(seqs.sorted()) && Set(seqs).count == seqs.count, "one shared, increasing sequence")
        #expect(translator.tracker.isIdle)
        #expect(translator.tracker.modifiers == 0)
    }

    @MainActor
    @Test func controllerForwardsTapEventsLikeAppKitEvents() {
        let sent = Mutex<[OutgoingInput]>([])
        let controller = ViewerInputController(send: { item in sent.withLock { $0.append(item) } })
        let command = Flags.command | leftCommand
        #expect(controller.handleKey(TapKeyEvent(kind: .flagsChanged, keyCode: ModifierKeys.command, flags: command)))
        #expect(controller.handleKey(TapKeyEvent(kind: .down, keyCode: 0x30, flags: command)))
        #expect(controller.handleKey(TapKeyEvent(kind: .down, keyCode: 0x30, flags: command, isRepeat: true)))
        #expect(controller.handleKey(TapKeyEvent(kind: .up, keyCode: 0x30, flags: command)))
        #expect(controller.handleKey(TapKeyEvent(kind: .flagsChanged, keyCode: ModifierKeys.command, flags: 0)))
        let messages = sent.withLock { $0 }.compactMap { if case .reliable(let m) = $0 { m } else { nil } }
        #expect(messages.count == 5)
        if messages.count == 5 {
            #expect(messages[0].isKeyDown(ModifierKeys.command) && messages[1].isKeyDown(0x30))
            if case .keyDown(let k) = messages[2] { #expect(k.isRepeat) }
            #expect(messages[3].isKeyUp(0x30) && messages[4].isKeyUp(ModifierKeys.command))
        }
        // The release shortcut reported through the tap is still local: nothing sent, false returned.
        let before = sent.withLock { $0.count }
        #expect(!controller.handleKey(TapKeyEvent(kind: .down, keyCode: ModifierKeys.escape,
                                                  flags: Flags.control | Flags.option)))
        #expect(sent.withLock { $0.count } == before)
        controller.send(SystemShortcut.lockScreen.chord)
        #expect(sent.withLock { $0.count } == before + 6)
        #expect(controller.state.isIdle)
    }

    // MARK: Tap filter

    @Test func nothingIsTakenWhileNotArmed() {
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            #expect(SystemShortcutFilter.decide(type: type, keyCode: 0x30, flags: Flags.command, armed: false) == .pass)
        }
        #expect(SystemShortcutFilter.decide(type: .tapDisabledByTimeout, keyCode: 0, flags: 0, armed: false) == .pass)
    }

    @Test func armedTapTakesSystemShortcutsAndEveryOtherKey() {
        let cases: [(UInt16, UInt64)] = [
            (0x30, Flags.command),                                       // ⌘Tab
            (0x31, Flags.command),                                       // ⌘Space
            (0x7E, Flags.control | Flags.fn | ModifierKeys.numericPadFlag), // ⌃↑ Mission Control
            (0x7C, Flags.control | Flags.fn),                            // ⌃→ next Space
            (0x14, Flags.shift | Flags.command),                         // ⇧⌘3
            (ModifierKeys.escape, Flags.option | Flags.command),         // ⌥⌘⎋ Force Quit
            (ModifierKeys.escape, Flags.control | Flags.option | Flags.command), // ⌃⌥⌘⎋: Force Quit, not release
            (0x0C, Flags.control | Flags.command),                       // ⌃⌘Q
            (0x0C, Flags.command),                                       // ⌘Q (the stream view forwards it anyway)
            (0x00, 0),                                                   // plain "a"
        ]
        for (code, flags) in cases {
            for type in [CGEventType.keyDown, .keyUp] {
                #expect(SystemShortcutFilter.decide(type: type, keyCode: code, flags: flags, armed: true) == .forward,
                        "\(code) \(flags) \(type.rawValue)")
            }
        }
        #expect(SystemShortcutFilter.decide(type: .flagsChanged, keyCode: ModifierKeys.command, flags: Flags.command,
                                            armed: true) == .forward)
    }

    @Test func releaseShortcutAlwaysStaysLocal() {
        #expect(SystemShortcutFilter.decide(type: .keyDown, keyCode: ModifierKeys.escape,
                                            flags: Flags.control | Flags.option, armed: true) == .pass)
        #expect(SystemShortcutFilter.decide(type: .keyDown, keyCode: ModifierKeys.escape,
                                            flags: Flags.control | Flags.option | Flags.shift | leftControl,
                                            armed: true) == .pass)
        // Raw CGEvent flags carry extra bits (non-coalesced etc.); they must not hide the shortcut.
        #expect(SystemShortcutFilter.decide(type: .keyDown, keyCode: ModifierKeys.escape,
                                            flags: Flags.control | Flags.option | 0x100, armed: true) == .pass)
    }

    @Test func ownEventsAndLocalMenusAreNeverTaken() {
        #expect(SystemShortcutFilter.decide(type: .keyDown, keyCode: 0x30, flags: Flags.command, armed: true,
                                            postedByThisProcess: true) == .pass)
        #expect(SystemShortcutFilter.decide(type: .keyDown, keyCode: 0x7D, flags: 0, armed: true,
                                            trackingLocalUI: true) == .pass)
    }

    @Test func otherEventTypesPassAndADisabledTapIsReenabledOnlyWhileArmed() {
        for type in [CGEventType.leftMouseDown, .mouseMoved, .scrollWheel, .null] {
            #expect(SystemShortcutFilter.decide(type: type, keyCode: 0, flags: 0, armed: true) == .pass)
        }
        #expect(SystemShortcutFilter.decide(type: .tapDisabledByTimeout, keyCode: 0, flags: 0, armed: true) == .reenable)
        #expect(SystemShortcutFilter.decide(type: .tapDisabledByUserInput, keyCode: 0, flags: 0, armed: true) == .reenable)
    }

    @Test func tapEventsKeepTheirKindRepeatAndFlags() {
        #expect(SystemShortcutFilter.keyEvent(type: .keyDown, keyCode: 1, flags: 2, autorepeat: true)
            == TapKeyEvent(kind: .down, keyCode: 1, flags: 2, isRepeat: true))
        #expect(SystemShortcutFilter.keyEvent(type: .keyUp, keyCode: 1, flags: 2, autorepeat: true)
            == TapKeyEvent(kind: .up, keyCode: 1, flags: 2))
        #expect(SystemShortcutFilter.keyEvent(type: .flagsChanged, keyCode: 55, flags: Flags.command, autorepeat: false)
            == TapKeyEvent(kind: .flagsChanged, keyCode: 55, flags: Flags.command))
        #expect(SystemShortcutFilter.keyEvent(type: .leftMouseDown, keyCode: 0, flags: 0, autorepeat: false) == nil)
    }

    @MainActor
    @Test func unpermittedTapIsNeverInstalledAndRemoveIsSafe() {
        // Without Accessibility (the test runner has none) macOS refuses the tap; with it, it is removed again.
        let tap = SystemShortcutTap(isArmed: { false }, deliver: { _ in Issue.record("nothing may be delivered") })
        let installed = tap.install()
        #expect(tap.isInstalled == installed)
        tap.remove()
        tap.remove()
        #expect(!tap.isInstalled)
    }
}

private extension ControlMessage {
    func isKeyDown(_ code: UInt16) -> Bool { if case .keyDown(let k) = self { k.keyCode == code } else { false } }
    func isKeyUp(_ code: UInt16) -> Bool { if case .keyUp(let k) = self { k.keyCode == code } else { false } }
}
