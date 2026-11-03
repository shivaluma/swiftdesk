import Foundation
import InputCore
import RenderCore
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// 0.1.7 system shortcuts: the arming rule (pure) and, over real QUIC on 127.0.0.1, Send Keys and the keyboard tap's
/// lifecycle with a fake tap and a scripted Accessibility answer.
@Suite struct SystemShortcutCaptureTests {
    @Test func tapArmsOnlyWhenEveryConditionHolds() {
        #expect(SystemShortcutCaptureStatus.shouldArm(enabled: true, permitted: true, streaming: true, capturing: true,
                                                      focused: true))
        for missing in 0..<5 {
            var flags = [true, true, true, true, true]
            flags[missing] = false
            #expect(!SystemShortcutCaptureStatus.shouldArm(enabled: flags[0], permitted: flags[1], streaming: flags[2],
                                                           capturing: flags[3], focused: flags[4]), "\(missing)")
        }
    }

    @Test func statusSaysWhatIsMissing() {
        typealias S = SystemShortcutCaptureStatus
        #expect(S.make(enabled: false, permitted: true, armed: false, installed: false) == .off)
        #expect(S.make(enabled: true, permitted: false, armed: false, installed: false) == .needsPermission)
        #expect(S.make(enabled: true, permitted: true, armed: false, installed: false) == .standby)
        #expect(S.make(enabled: true, permitted: true, armed: true, installed: true) == .active)
        #expect(S.make(enabled: true, permitted: true, armed: true, installed: false) == .unavailable)
    }
}

extension EndToEndTests {
    /// Scripted Accessibility answer and the fake taps a Viewer created.
    @MainActor
    final class ShortcutRig {
        var permitted = false
        private(set) var prompts = 0
        private(set) var taps: [FakeShortcutTap] = []
        var refuseInstall = false

        var tap: FakeShortcutTap? { taps.last }

        func permission(_ prompt: Bool) -> Bool {
            if prompt { prompts += 1 }
            return permitted
        }

        func make(_ isArmed: @escaping @MainActor () -> Bool,
                  _ deliver: @escaping @MainActor (TapKeyEvent) -> Void) -> any SystemShortcutTapping {
            let tap = FakeShortcutTap(isArmed: isArmed, deliver: deliver)
            tap.refuseInstall = refuseInstall
            taps.append(tap)
            return tap
        }
    }

    private func approvedShortcutSession(_ h: Harness, port: UInt16, rig: ShortcutRig) async throws -> ViewerSession {
        let viewer = h.makeViewer(shortcutPermission: { rig.permission($0) }, makeShortcutTap: { rig.make($0, $1) })
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "\(viewer.state)")
        viewer.trustHost(remember: false)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        return viewer
    }

    private func keyMessages(_ messages: [ControlMessage]) -> [(down: Bool, code: UInt16, flags: UInt64)] {
        messages.compactMap { message in
            switch message {
            case .keyDown(let k): (true, k.keyCode, k.modifiers)
            case .keyUp(let k): (false, k.keyCode, k.modifiers)
            default: nil
            }
        }
    }

    /// 0.2.0: the stream view forwards ⌘Q only while "Send system shortcuts" is on.
    @Test func quitShortcutFollowsTheSystemShortcutSwitch() async throws {
        let h = try Harness()
        let viewer = h.makeViewer()
        let view = RemoteDisplayView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        viewer.attach(renderView: view)
        #expect(!view.forwardsQuitShortcut)
        viewer.sendsSystemShortcuts = true
        #expect(view.forwardsQuitShortcut)
        let replacement = RemoteDisplayView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        viewer.attach(renderView: replacement)
        #expect(replacement.forwardsQuitShortcut && !view.forwardsQuitShortcut)
        viewer.sendsSystemShortcuts = false
        #expect(!replacement.forwardsQuitShortcut)
        viewer.attach(renderView: nil)
        await h.close()
    }

    /// Send Keys presses the chord on the Host through the ordinary input path, captured or not, and leaves nothing
    /// held there.
    @Test func sendKeysPressesTheShortcutOnTheHost() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let rig = ShortcutRig()
        let viewer = try await approvedShortcutSession(h, port: port, rig: rig)
        let sink = try #require(h.sinks.last)
        #expect(!viewer.isCapturingInput)

        #expect(viewer.send(.forceQuit))
        #expect(await eventually { sink.messages.count >= 6 }, "host received \(sink.messages)")
        let received = keyMessages(sink.messages)
        let expected = SystemShortcut.forceQuit.chord.strokes
        #expect(received.count == expected.count)
        for (got, want) in zip(received, expected) {
            #expect(got.down == want.isDown && got.code == want.keyCode && got.flags == want.flags, "\(got)")
        }
        #expect(rig.taps.isEmpty, "Send Keys never needs the tap or Accessibility on the Viewer")
        #expect(rig.prompts == 0)

        viewer.disconnect()
        #expect(!viewer.send(.spotlight), "nothing is sent outside a session")
        await h.close()
    }

    /// The tap exists only while the switch is on, Accessibility is granted, and the user controls the streaming
    /// session in the focused stream view; every other state removes it, and what it takes reaches the Host in order.
    @Test func shortcutTapFollowsControlFocusAndPermission() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let rig = ShortcutRig()
        let viewer = try await approvedShortcutSession(h, port: port, rig: rig)
        let sink = try #require(h.sinks.last)
        #expect(viewer.systemShortcutStatus == .off)

        // On, but no Accessibility: nothing installed, the UI is told why, macOS is not prompted by itself.
        viewer.sendsSystemShortcuts = true
        #expect(viewer.systemShortcutStatus == .needsPermission)
        #expect(rig.prompts == 0)
        viewer.requestShortcutPermission()
        #expect(rig.prompts == 1)
        #expect(viewer.systemShortcutStatus == .needsPermission)

        rig.permitted = true
        viewer.refreshShortcutPermission()
        #expect(viewer.systemShortcutStatus == .standby, "not controlling yet")
        #expect(rig.tap?.isInstalled != true)

        viewer.inputFocusOverride = true
        viewer.isCapturingInput = true
        let tap = try #require(rig.tap)
        #expect(tap.isInstalled)
        #expect(viewer.systemShortcutStatus == .active)

        // ⌘Tab as the tap sees it: the ⌘ flagsChanged, Tab down/up, ⌘ release. All reach the Host, in order.
        let command = ModifierKeys.commandFlag | ModifierKeys.deviceLeftCommandFlag
        #expect(tap.press(TapKeyEvent(kind: .flagsChanged, keyCode: ModifierKeys.command, flags: command)))
        #expect(tap.press(TapKeyEvent(kind: .down, keyCode: 0x30, flags: command)))
        #expect(tap.press(TapKeyEvent(kind: .up, keyCode: 0x30, flags: command)))
        #expect(tap.press(TapKeyEvent(kind: .flagsChanged, keyCode: ModifierKeys.command, flags: 0)))
        #expect(await eventually { sink.messages.count >= 4 }, "host received \(sink.messages)")
        let received = keyMessages(sink.messages)
        #expect(received.map(\.code) == [ModifierKeys.command, 0x30, 0x30, ModifierKeys.command])
        #expect(received.map(\.down) == [true, true, false, false])

        // Focus leaves the stream view (another window or app): removed at once, nothing taken any more.
        viewer.inputFocusOverride = false
        viewer.focusChanged(false)
        #expect(!tap.isInstalled)
        #expect(viewer.systemShortcutStatus == .standby)
        #expect(!tap.press(TapKeyEvent(kind: .down, keyCode: 0x30, flags: command)))
        viewer.inputFocusOverride = true
        viewer.focusChanged(true)
        #expect(tap.isInstalled)
        #expect(rig.taps.count == 1, "the same tap is reinstalled, not recreated")

        // Capture off (toolbar toggle, click outside): removed.
        viewer.isCapturingInput = false
        #expect(!tap.isInstalled)
        viewer.isCapturingInput = true
        #expect(tap.isInstalled)

        // The switch off: removed; back on: installed again.
        viewer.sendsSystemShortcuts = false
        #expect(!tap.isInstalled)
        #expect(viewer.systemShortcutStatus == .off)
        viewer.sendsSystemShortcuts = true
        #expect(tap.isInstalled)

        // Accessibility revoked in System Settings: removed on the next check.
        rig.permitted = false
        viewer.refreshShortcutPermission()
        #expect(!tap.isInstalled)
        #expect(viewer.systemShortcutStatus == .needsPermission)
        rig.permitted = true
        viewer.refreshShortcutPermission()
        #expect(tap.isInstalled)

        // ⌃⌥⎋ reported through the tap is still the local release: capture ends, the tap goes, nothing is sent
        // for Escape, and the ⌃ ⌥ that were forwarded are released on the Host.
        let before = sink.messages.count
        let ctrlOpt = ModifierKeys.controlFlag | ModifierKeys.optionFlag
        #expect(tap.press(TapKeyEvent(kind: .flagsChanged, keyCode: ModifierKeys.control,
                                      flags: ModifierKeys.controlFlag | ModifierKeys.deviceLeftControlFlag)))
        #expect(tap.press(TapKeyEvent(kind: .flagsChanged, keyCode: ModifierKeys.option,
                                      flags: ctrlOpt | ModifierKeys.deviceLeftControlFlag
                                          | ModifierKeys.deviceLeftOptionFlag)))
        #expect(tap.press(TapKeyEvent(kind: .down, keyCode: ModifierKeys.escape, flags: ctrlOpt)))
        #expect(!viewer.isCapturingInput)
        #expect(!tap.isInstalled)
        #expect(await eventually { sink.messages.count >= before + 4 }, "host received \(sink.messages)")
        let tail = keyMessages(Array(sink.messages.dropFirst(before)))
        #expect(tail.map(\.down) == [true, true, false, false])
        #expect(!tail.contains { $0.code == ModifierKeys.escape })

        // An event that was already queued when capture ended is dropped by the session itself.
        let count = sink.messages.count
        tap.deliver(TapKeyEvent(kind: .down, keyCode: 0x00, flags: 0))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sink.messages.count == count)

        // Ending the session removes it.
        viewer.isCapturingInput = true
        #expect(tap.isInstalled)
        viewer.disconnect()
        #expect(!tap.isInstalled)
        #expect(viewer.systemShortcutStatus == .standby)
        await h.close()
    }

    /// macOS refusing the tap despite an apparent grant is reported, not hidden.
    @Test func refusedTapIsReportedAsUnavailable() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let rig = ShortcutRig()
        rig.permitted = true
        rig.refuseInstall = true
        let viewer = try await approvedShortcutSession(h, port: port, rig: rig)
        viewer.sendsSystemShortcuts = true
        viewer.inputFocusOverride = true
        viewer.isCapturingInput = true
        #expect(viewer.systemShortcutStatus == .unavailable)
        #expect(rig.tap?.isInstalled == false)
        viewer.isCapturingInput = false
        #expect(viewer.systemShortcutStatus == .standby)
        await h.close()
    }
}
