import AppKit
import DiagnosticsCore
import Foundation
import InputCore
import SessionCore
import Testing
import WireProtocol
@testable import AppUI

private func request(name: String = "Viewer Mac", accessibility: Bool = true, at date: Date = Date()) -> ConnectionRequest {
    ConnectionRequest(peerName: name, appVersion: "1.0", fingerprint: Data(repeating: 0xAB, count: 32),
                      fingerprintDisplay: "ABAB ABAB", remoteAddress: "192.168.1.30:50123",
                      accessibilityGranted: accessibility, receivedAt: date)
}

private func peer(name: String = "Viewer Mac", viewOnly: Bool = false, viaPassword: Bool = false) -> HostPeer {
    HostPeer(name: name, fingerprintDisplay: "ABAB ABAB", remoteAddress: "192.168.1.30:50123", sessionId: 7,
             startedAt: Date(), isViewOnly: viewOnly, viaPassword: viaPassword)
}

@Suite("Password access presentation")
struct PasswordPresentationTests {
    @Test func passwordSessionIsNamedEverywhere() {
        let status = MenuBarStatus.make(hostState: .active(peer(viaPassword: true)), viewerStreamingHost: nil)
        #expect(status.tone == .sharing)
        #expect(status.title == "Controlled via password by Viewer Mac")
        let headline = HostStatusPresentation.make(.active(peer(viaPassword: true)))
        #expect(headline.title == "Controlled via password by Viewer Mac")
        #expect(headline.detail.hasPrefix("Signed in with the access password."))
        #expect(HostPeerPresentation.title(peer()) == "Sharing this Mac with Viewer Mac")
        #expect(HostPeer(name: "x", fingerprintDisplay: "", remoteAddress: "", sessionId: 1, startedAt: Date(),
                         isViewOnly: false).viaPassword == false, "default: approved session")
    }

    @Test func passwordFormValidation() {
        #expect(PasswordFormValidation.problem(password: "", confirmation: "") == "Enter a password.")
        #expect(PasswordFormValidation.problem(password: "short", confirmation: "short") == "Use at least 8 characters.")
        #expect(PasswordFormValidation.problem(password: "long enough", confirmation: "long enougH") == "The passwords do not match.")
        #expect(PasswordFormValidation.problem(password: "long enough", confirmation: "long enough") == nil)
    }

    @Test func incorrectPasswordNotice() {
        let notice = ViewerNotice.make(reason: ViewerHandshake.incorrectPasswordMessage)
        #expect(notice.kind == .incorrectPassword)
        #expect(ViewerPhase.make(.disconnected(reason: "Incorrect password")) == .form(notice: notice))
    }

    @Test func passwordSymbolIsListed() {
        #expect(Symbols.all.contains(Symbols.password))
    }
}

@Suite("Menu-bar status")
struct MenuBarStatusTests {
    @Test func sharingIsRedAndNamesThePeer() {
        let status = MenuBarStatus.make(hostState: .active(peer()), viewerStreamingHost: nil)
        #expect(status.tone == .sharing)
        #expect(status.symbol == Symbols.sharingActive)
        #expect(status.title == "Sharing this Mac with Viewer Mac")
        #expect(status.detail == "192.168.1.30:50123")
    }

    @Test func viewOnlySessionSaysSo() {
        let status = MenuBarStatus.make(hostState: .active(peer(viewOnly: true)), viewerStreamingHost: nil)
        #expect(status.tone == .sharing)
        #expect(status.detail?.hasPrefix("View only") == true)
    }

    @Test func pendingRequestNeedsAttention() {
        let status = MenuBarStatus.make(hostState: .awaitingApproval(request()), viewerStreamingHost: nil)
        #expect(status.tone == .attention)
        #expect(status.title.contains("Viewer Mac"))
    }

    @Test func idleListeningAndViewerStates() {
        #expect(MenuBarStatus.make(hostState: nil, viewerStreamingHost: nil).title == "Not sharing")
        #expect(MenuBarStatus.make(hostState: .idle, viewerStreamingHost: nil).tone == .neutral)
        let listening = MenuBarStatus.make(hostState: .listening(port: 47800), viewerStreamingHost: nil)
        #expect(listening.tone == .neutral)
        #expect(listening.detail == "Listening on port 47800")
        let withPassword = MenuBarStatus.make(hostState: .listening(port: 47800), viewerStreamingHost: nil,
                                              passwordAccess: true)
        #expect(withPassword.detail == "Listening on port 47800 · password access on")
        #expect(MenuBarStatus.make(hostState: .starting, viewerStreamingHost: nil).title == "Starting…")
        let viewing = MenuBarStatus.make(hostState: .idle, viewerStreamingHost: "Studio")
        #expect(viewing.title == "Controlling Studio")
    }

    @Test func hostSharingWinsOverViewerStatus() {
        // Being shared is the security-relevant fact; it must never be hidden by the Viewer role.
        let status = MenuBarStatus.make(hostState: .active(peer()), viewerStreamingHost: "Studio")
        #expect(status.tone == .sharing)
    }

    @Test @MainActor func menuBarImagesAreTemplateOnlyWhenNeutral() {
        let neutral = MenuBarImage.image(for: MenuBarStatus.make(hostState: .idle, viewerStreamingHost: nil))
        let sharing = MenuBarImage.image(for: MenuBarStatus.make(hostState: .active(peer()), viewerStreamingHost: nil))
        let attention = MenuBarImage.image(for: MenuBarStatus.make(hostState: .awaitingApproval(request()), viewerStreamingHost: nil))
        #expect(neutral.isTemplate)
        #expect(!sharing.isTemplate)
        #expect(!attention.isTemplate)
        #expect(sharing.size.width > 0 && sharing.size.height > 0)
    }
}

@Suite("Host status and approval countdown")
struct HostPresentationTests {
    @Test func phasesFollowState() {
        #expect(HostStatusPresentation.make(.idle).phase == .idle)
        #expect(HostStatusPresentation.make(.starting).phase == .starting)
        #expect(HostStatusPresentation.make(.listening(port: 47800)).detail.contains("47800"))
        #expect(HostStatusPresentation.make(.awaitingApproval(request())).phase == .awaitingApproval)
        let active = HostStatusPresentation.make(.active(peer()))
        #expect(active.phase == .active)
        #expect(active.title == "Sharing this Mac with Viewer Mac")
        #expect(HostStatusPresentation.make(.active(peer(viewOnly: true))).detail.hasPrefix("View only"))
    }

    /// With password access on, the Host must not promise that it will be asked first (review finding ux-2).
    @Test func passwordAccessChangesThePromise() {
        let off = HostStatusPresentation.make(.listening(port: 47800))
        #expect(off.detail == "Listening on port 47800. You will be asked before anyone can see or control this Mac.")
        let on = HostStatusPresentation.make(.listening(port: 47800), passwordAccess: true)
        #expect(on.detail.contains("47800"))
        #expect(!on.detail.contains("You will be asked"))
        #expect(on.detail.contains("without asking"))
        #expect(HostStatusPresentation.make(.idle).detail.contains("until you approve"))
        #expect(!HostStatusPresentation.make(.idle, passwordAccess: true).detail.contains("until you approve"))
    }

    @Test func countdownRoundsUpAndClampsAtZero() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(ApprovalCountdown.secondsRemaining(receivedAt: start, timeout: .seconds(60), now: start) == 60)
        #expect(ApprovalCountdown.secondsRemaining(receivedAt: start, timeout: .seconds(60),
                                                   now: start.addingTimeInterval(59.2)) == 1)
        #expect(ApprovalCountdown.secondsRemaining(receivedAt: start, timeout: .seconds(60),
                                                   now: start.addingTimeInterval(60)) == 0)
        #expect(ApprovalCountdown.secondsRemaining(receivedAt: start, timeout: .seconds(60),
                                                   now: start.addingTimeInterval(500)) == 0)
        #expect(ApprovalCountdown.secondsRemaining(receivedAt: start, timeout: .milliseconds(1500), now: start) == 2)
    }
}

@Suite("Viewer phases")
struct ViewerPhaseTests {
    @Test func statesMapToPhases() {
        #expect(ViewerPhase.make(.idle) == .form(notice: nil))
        #expect(ViewerPhase.make(.connecting(host: "fd7a::1", port: 47800)) == .connecting(target: "[fd7a::1]:47800"))
        #expect(ViewerPhase.make(.awaitingApproval) == .waitingForApproval)
        // .verifyingHost / .streaming carry SessionCore values with internal initializers; they are checked with
        // real values in AppModelTests.activeSessionDrivesIndicatorAssertionAndShutdown.
    }

    @Test func identityChangeIsItsOwnKindOfNotice() {
        let notice = ViewerNotice.make(reason: ViewerHandshake.identityChangedMessage)
        #expect(notice.kind == .identityChanged)
        #expect(ViewerPhase.make(.disconnected(reason: ViewerHandshake.identityChangedMessage))
                == .form(notice: notice))
    }

    @Test func userEndingsAreInformationalAndDenialsAreProblems() {
        #expect(ViewerNotice.make(reason: "Disconnected").kind == .info)
        #expect(ViewerNotice.make(reason: "You did not trust the Host's identity").kind == .info)
        let denied = ViewerHandshake.message(for: Deny(reason: .userDenied, message: ""))
        #expect(ViewerNotice.make(reason: denied).kind == .problem)
        #expect(ViewerNotice.make(reason: "Connection lost: timeout").kind == .problem)
    }
}

@Suite("Process activity policy")
struct SessionActivityPolicyTests {
    @Test func nothingRunningHoldsNoAssertion() {
        #expect(SessionActivityPolicy.options(hostSharing: false, viewerStreaming: false, loopbackRunning: false) == nil)
    }

    @Test func hostingKeepsDisplayAwakeAndDisablesAppNap() throws {
        let options = try #require(SessionActivityPolicy.options(hostSharing: true, viewerStreaming: false, loopbackRunning: false))
        #expect(options.contains(.idleDisplaySleepDisabled))
        #expect(options.contains(.latencyCritical))
        #expect(options.contains(.userInitiated))
    }

    @Test func viewerAndLoopbackAreLatencyCriticalButAllowDisplaySleep() throws {
        for (viewer, loopback) in [(true, false), (false, true)] {
            let options = try #require(SessionActivityPolicy.options(hostSharing: false, viewerStreaming: viewer,
                                                                     loopbackRunning: loopback))
            #expect(options.contains(.latencyCritical))
            #expect(!options.contains(.idleDisplaySleepDisabled))
        }
        #expect(SessionActivityPolicy.reason(hostSharing: false, viewerStreaming: true, loopbackRunning: false)
                .contains("controlling"))
    }
}

@Suite("Roles and symbols")
struct RoleAndSymbolTests {
    @Test func everySymbolExistsOnThisSystem() {
        for name in Symbols.all {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
        for role in AppRole.allCases {
            #expect(Symbols.all.contains(role.symbol))
        }
    }

    @Test func rolesHaveDistinctTitles() {
        let titles = AppRole.allCases.map(\.title)
        #expect(titles == ["Share this Mac", "Control a Mac", "Local Loopback Test"])
        #expect(AppRole(rawValue: "host") == .host)
    }
}

@Suite("Loopback table")
struct LoopbackStageRowTests {
    @Test func emptyWindowsShowPlaceholders() {
        let rows = LoopbackStageRow.rows(LoopbackMetrics())
        #expect(rows.map(\.stage) == ["Capture → encoded", "Encoded → decoded", "Decoded → on glass", "Capture → on glass"])
        #expect(rows.allSatisfy { $0.p50 == MetricsFormat.placeholder && $0.count == "0" })
    }

    @Test func summariesAreFormatted() {
        var m = LoopbackMetrics()
        // Nearest-rank: p50 of 1...20 is 10, p95 is 19.
        m.captureToEncodeDone = RollingStats.summarize((1...20).map(Double.init))
        m.captureToPresent = RollingStats.summarize([18.25, 31, 140])
        let rows = LoopbackStageRow.rows(m)
        let s = m.captureToEncodeDone
        #expect(rows[0] == LoopbackStageRow(stage: "Capture → encoded", p50: MetricsFormat.millis(s.p50),
                                            p95: MetricsFormat.millis(s.p95), max: "20.0 ms", count: "20"))
        #expect(rows[3].max == "140 ms")
        #expect(rows[3].count == "3")
        #expect(rows[1].p50 == MetricsFormat.placeholder)
    }
}

@Suite("Viewer window sizing policy")
struct ViewerWindowSizerPolicyTests {
    private typealias Key = ViewerWindowSizer.StreamKey

    private static let nativeSize = CGSize(width: 1600, height: 900)

    @Test func firstConfigSnaps() {
        let first = Key(width: 1600, height: 900, displayPointWidth: 1600, displayPointHeight: 900)
        #expect(ViewerWindowSizer.action(previous: nil, nativeBefore: nil, next: first, userResized: false) == .snap)
        #expect(ViewerWindowSizer.action(previous: nil, nativeBefore: nil, next: first, userResized: true) == .snap)
        let empty = Key(width: 0, height: 0, displayPointWidth: 0, displayPointHeight: 0)
        #expect(ViewerWindowSizer.action(previous: nil, nativeBefore: nil, next: empty, userResized: false) == .none)
    }

    @Test func adaptationStepsKeepTheWindow() {
        let native = Key(width: 1600, height: 900, displayPointWidth: 1600, displayPointHeight: 900)
        let stepped = Key(width: 1280, height: 720, displayPointWidth: 1600, displayPointHeight: 900)
        #expect(ViewerWindowSizer.action(previous: native, nativeBefore: Self.nativeSize, next: stepped,
                                         userResized: false) == .none)
        #expect(ViewerWindowSizer.action(previous: stepped, nativeBefore: Self.nativeSize, next: native,
                                         userResized: false) == .none)
    }

    /// The window is sized for the largest stream seen on the display, not the current rung: a snap (or ⌘0) during
    /// a step down must not leave a too-small window once the stream steps back up.
    @Test func sizesForTheNativeStreamNotTheCurrentRung() {
        let native = Key(width: 1600, height: 900, displayPointWidth: 1600, displayPointHeight: 900)
        let stepped = Key(width: 1280, height: 720, displayPointWidth: 1600, displayPointHeight: 900)
        // Step down: the native size is kept.
        #expect(ViewerWindowSizer.nativePixels(previousNative: Self.nativeSize, previous: native, next: stepped)
                == Self.nativeSize)
        // Session that started on a lower rung: stepping up past what the window was sized for re-snaps (unless
        // the user resized the window) and becomes the native size.
        let small = CGSize(width: 1280, height: 720)
        #expect(ViewerWindowSizer.action(previous: stepped, nativeBefore: small, next: native, userResized: false) == .snap)
        #expect(ViewerWindowSizer.action(previous: stepped, nativeBefore: small, next: native, userResized: true) == .none)
        #expect(ViewerWindowSizer.nativePixels(previousNative: small, previous: stepped, next: native) == Self.nativeSize)
        // A new display starts over.
        let other = Key(width: 1280, height: 800, displayPointWidth: 1280, displayPointHeight: 800)
        #expect(ViewerWindowSizer.nativePixels(previousNative: Self.nativeSize, previous: native, next: other)
                == CGSize(width: 1280, height: 800))
    }

    @Test func hostDisplayChangeResizesUnlessTheUserResized() {
        let before = Key(width: 1600, height: 900, displayPointWidth: 1600, displayPointHeight: 900)
        let after = Key(width: 1920, height: 1080, displayPointWidth: 1920, displayPointHeight: 1080)
        #expect(ViewerWindowSizer.action(previous: before, nativeBefore: Self.nativeSize, next: after,
                                         userResized: false) == .snap)
        #expect(ViewerWindowSizer.action(previous: before, nativeBefore: Self.nativeSize, next: after,
                                         userResized: true) == .none)
        // Same point size but a different picture shape is a display change too (e.g. 16:10 → 16:9 mode).
        let reshaped = Key(width: 1600, height: 1000, displayPointWidth: 1600, displayPointHeight: 900)
        #expect(ViewerWindowSizer.action(previous: before, nativeBefore: Self.nativeSize, next: reshaped,
                                         userResized: false) == .snap)
    }
}

@Suite("Host stream summary")
struct HostStreamSummaryTests {
    @Test func summaryNamesTheResultingSize() {
        #expect(HostView.streamSummary(isSharing: false, size: (1600, 900), fps: 60)
                == "Streams at 1600×900, 60 fps; drops lower on a weak network.")
        #expect(HostView.streamSummary(isSharing: false, size: nil, fps: 60)
                == "Streams at the display's resolution, 60 fps; drops lower on a weak network.")
        #expect(HostView.streamSummary(isSharing: true, size: (1600, 900), fps: 60)
                == "A new display or quality applies to the next session.")
    }
}

@Suite("Dropout presentation")
struct DropoutPresentationTests {
    private func info() -> ViewerSession.StreamInfo {
        ViewerSession.StreamInfo(hostName: "Studio", remoteAddress: "192.168.1.20:47800", sessionId: 3,
                                 hostFingerprintDisplay: "ABAB ABAB", isTrusted: true)
    }

    private func status(_ phase: ViewerSession.ReconnectStatus.Phase, attempt: Int = 0, resume: Bool = true,
                        now: Date) -> ViewerSession.ReconnectStatus {
        ViewerSession.ReconnectStatus(stream: info(), host: "192.168.1.20", port: 47800, phase: phase, attempt: attempt,
                                      lostReason: "Connection lost: timeout", lastError: nil, startedAt: now,
                                      deadline: now.addingTimeInterval(60), hostSupportsResume: resume)
    }

    @Test func reconnectingKeepsTheStreamScreen() {
        let now = Date()
        // Same phase as streaming, so the same Metal view (with the last frame) stays on screen.
        #expect(ViewerPhase.make(.reconnecting(status(.connecting, now: now))) == .streaming(info()))
    }

    @Test func reconnectCardExplainsEachPhase() {
        let now = Date()
        let first = ReconnectPresentation.detail(status(.waiting(nextAttemptAt: now.addingTimeInterval(2.2)), now: now),
                                                 usingPassword: false, now: now)
        #expect(first == "The connection dropped. Next attempt in 3 s · gives up in 60 s.")
        let later = ReconnectPresentation.detail(status(.waiting(nextAttemptAt: now), attempt: 2, now: now),
                                                 usingPassword: false, now: now)
        #expect(later == "Attempt 2 did not get through. Trying again…")
        #expect(ReconnectPresentation.detail(status(.connecting, attempt: 3, now: now), usingPassword: false, now: now)
            .hasPrefix("Attempt 3: connecting"))
        #expect(ReconnectPresentation.detail(status(.awaitingApproval, now: now), usingPassword: false, now: now)
            .contains("without asking"))
        #expect(ReconnectPresentation.detail(status(.awaitingApproval, resume: false, now: now), usingPassword: false,
                                             now: now).contains("has to allow"))
        #expect(ReconnectPresentation.detail(status(.awaitingApproval, now: now), usingPassword: true, now: now)
            .contains("password"))
    }

    @Test func menuBarSaysReconnectingAndNotResponding() {
        let viewer = MenuBarStatus.make(hostState: nil, viewerStreamingHost: "Studio", viewerReconnecting: true)
        #expect(viewer.title == "Reconnecting to Studio…")
        #expect(viewer.symbol == Symbols.reconnect)
        var resumed = HostPeer(name: "Viewer Mac", fingerprintDisplay: "AB", remoteAddress: "10.0.0.2:5", sessionId: 1,
                               startedAt: Date(), isViewOnly: false, resumed: true)
        #expect(MenuBarStatus.make(hostState: .active(resumed), viewerStreamingHost: nil).detail == "Reconnected · 10.0.0.2:5")
        #expect(MenuBarStatus.make(hostState: .active(resumed), viewerStreamingHost: nil, peerSilent: true).detail
                == "Not responding · 10.0.0.2:5")
        #expect(HostStatusPresentation.make(.active(resumed)).detail.hasPrefix("Reconnected after a dropped connection."))
        resumed.resumed = false
        #expect(!HostStatusPresentation.make(.active(resumed)).detail.contains("Reconnected"))
    }
}

@Suite("Clipboard presentation")
struct ClipboardPresentationTests {
    @Test func statusNamesWhoseSwitchIsOff() {
        let name = "Studio"
        #expect(ClipboardPresentation.status(.inactive, peerName: name) == "Studio runs a SwiftDesk without clipboard sharing")
        #expect(ClipboardPresentation.status(ClipboardSyncStatus(peerSupports: true, peerEnabled: true, localEnabled: false),
                                             peerName: name) == "Clipboard sharing is off on this Mac")
        #expect(ClipboardPresentation.status(ClipboardSyncStatus(peerSupports: true, peerEnabled: false, localEnabled: true),
                                             peerName: name) == "Clipboard sharing is off on Studio")
        #expect(ClipboardPresentation.status(ClipboardSyncStatus(peerSupports: true, peerEnabled: true, localEnabled: true),
                                             peerName: name) == "Clipboard shared with Studio")
    }

    @Test func noticesAreShortAndSayWhy() {
        #expect(ClipboardPresentation.notice(ClipboardNotice(kind: .tooLarge(bytes: 24_536_678, limit: 16 << 20)))
                == "Not shared: the copied item is 23 MB (limit 16 MB)")
        #expect(ClipboardPresentation.notice(ClipboardNotice(kind: .tooLarge(bytes: 1_200_000, limit: 1 << 20)))
                == "Not shared: the copied item is 1.1 MB (limit 1 MB)")
        #expect(ClipboardPresentation.notice(ClipboardNotice(kind: .filesNotShared)).contains("files"))
        #expect(ClipboardPresentation.notice(ClipboardNotice(kind: .accessDenied)).contains("macOS"))
    }

    @Test func accessHintPointsToPasteFromOtherApps() throws {
        #expect(ClipboardPresentation.accessHint(.unrestricted, denied: false) == nil)
        #expect(ClipboardPresentation.accessHint(.alwaysAllow, denied: false) == nil)
        let ask = try #require(ClipboardPresentation.accessHint(.ask, denied: false))
        #expect(ask.contains("may ask") && ask.contains("Paste from Other Apps"))
        #expect(ClipboardPresentation.accessHint(.default, denied: false) == ask)
        let blocked = try #require(ClipboardPresentation.accessHint(.alwaysDeny, denied: false))
        #expect(blocked.contains("blocking") && blocked.contains("Paste from Other Apps"))
        #expect(ClipboardPresentation.accessHint(.alwaysAllow, denied: true) == blocked)
    }

    @Test func clipboardSymbolsExist() {
        for name in [Symbols.clipboard, Symbols.clipboardOff] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}

@Suite("Shortcut presentation")
struct ShortcutPresentationTests {
    @Test func menuTitlesMarkItemsThatAskFirst() {
        #expect(ShortcutPresentation.menuTitle(.lockScreen) == "Lock Screen…")
        #expect(ShortcutPresentation.menuTitle(.spotlight) == "Spotlight")
        #expect(ShortcutPresentation.menuTitle(.forceQuit) == "Force Quit Applications…", "no double ellipsis")
    }

    @Test func statusNamesWhereShortcutsGo() {
        #expect(ShortcutPresentation.status(.off, hostName: "Studio").contains("act on this Mac"))
        #expect(ShortcutPresentation.status(.standby, hostName: "Studio") == "System shortcuts go to Studio while you control it")
        #expect(ShortcutPresentation.status(.active, hostName: "Studio").hasSuffix("go to Studio"))
        #expect(ShortcutPresentation.status(.needsPermission, hostName: "Studio").contains("Accessibility"))
        #expect(ShortcutPresentation.status(.unavailable, hostName: "Studio").contains("Accessibility"))
    }

    /// 0.2.0: ⌘Q with the stream window up asks first; other ways to quit do not.
    @Test func quitAsksFirstOnlyForCommandQDuringAStream() {
        #expect(QuitPresentation.asksFirst(presentingStream: true, triggeredByQuitKey: true))
        #expect(!QuitPresentation.asksFirst(presentingStream: true, triggeredByQuitKey: false))
        #expect(!QuitPresentation.asksFirst(presentingStream: false, triggeredByQuitKey: true))
        let info = ViewerSession.StreamInfo(hostName: "Studio", remoteAddress: "1.2.3.4:47800", sessionId: 1,
                                            hostFingerprintDisplay: "AB", isTrusted: false)
        #expect(QuitPresentation.message(.streaming(info)).contains("Studio"))
        #expect(QuitPresentation.message(.idle).contains("your session."))
    }

    @Test func permissionHintOnlyWhenSomethingIsMissing() {
        #expect(ShortcutPresentation.permissionHint(.needsPermission)?.contains("Privacy & Security") == true)
        #expect(ShortcutPresentation.permissionHint(.unavailable) != nil)
        for status in [SystemShortcutCaptureStatus.off, .standby, .active] {
            #expect(ShortcutPresentation.permissionHint(status) == nil)
        }
        #expect(ShortcutPresentation.settingsCaption.contains(ViewerSession.releaseShortcutDescription))
        // Review 0.2.0: the note over the video while streaming, for the same two states only.
        #expect(ShortcutPresentation.streamNote(.needsPermission)?.contains("Accessibility") == true)
        #expect(ShortcutPresentation.streamNote(.unavailable)?.contains("Accessibility") == true)
        for status in [SystemShortcutCaptureStatus.off, .standby, .active] {
            #expect(ShortcutPresentation.streamNote(status) == nil)
        }
    }

    @Test func lockScreenConfirmationExplainsTheConsequence() {
        #expect(ShortcutPresentation.confirmationTitle(.lockScreen, hostName: "Studio") == "Lock Screen on Studio?")
        #expect(ShortcutPresentation.confirmationMessage(.lockScreen).contains("unlock"))
    }

    @Test func sendKeysSymbolExists() {
        #expect(NSImage(systemSymbolName: Symbols.sendKeys, accessibilityDescription: nil) != nil)
        #expect(Symbols.all.contains(Symbols.sendKeys))
    }
}

@Suite("Pointer presentation")
struct PointerPresentationTests {
    @Test func hostCaptionSaysWhatTheViewerSees() {
        #expect(PointerPresentation.hostCaption(.inactive, peerName: nil).contains("Only the shape is sent"))
        #expect(PointerPresentation.hostCaption(.inactive, peerName: "Air")
                == "Air runs a SwiftDesk without pointer shapes; it shows a plain arrow.")
        #expect(PointerPresentation.hostCaption(CursorShapeStatus(peerSupports: true, enabled: true), peerName: "Air")
            .hasPrefix("Air sees your pointer’s shape"))
        #expect(PointerPresentation.hostCaption(CursorShapeStatus(peerSupports: true, enabled: false), peerName: "Air")
                == "Air sees a plain arrow.")
    }

    @Test func viewerStatusNamesTheReason() {
        let name = "Studio"
        #expect(PointerPresentation.viewerStatus(.active, enabled: false, hostName: name) == "Pointer shapes are off on this Mac")
        #expect(PointerPresentation.viewerStatus(.active, enabled: true, hostName: name) == "Showing Studio’s pointer shape")
        #expect(PointerPresentation.viewerStatus(.offOnHost, enabled: true, hostName: name) == "Studio doesn’t share its pointer shape")
        #expect(PointerPresentation.viewerStatus(.unsupported, enabled: true, hostName: name)
                == "Studio runs a SwiftDesk without pointer shapes")
        #expect(PointerPresentation.viewerStatus(.unavailable, enabled: true, hostName: name).contains("can’t tell"))
    }

    @Test func pointerSymbolExists() {
        #expect(NSImage(systemSymbolName: Symbols.pointer, accessibilityDescription: nil) != nil)
        #expect(Symbols.all.contains(Symbols.pointer))
    }
}

@Suite("Address book presentation")
struct AddressBookPresentationTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(name: String = "Studio", addresses: [SavedHostAddress] = [SavedHostAddress(host: "studio.local", port: 47800)],
                       favorite: Bool = false, custom: String? = nil) -> SavedHost {
        SavedHost(customName: custom, hostName: name, addresses: addresses,
                  fingerprintHex: String(repeating: "ab", count: 32), addedAt: Self.now, lastConnectedAt: Self.now,
                  isFavorite: favorite)
    }

    @Test func lastConnectedIsRelative() {
        let now = Self.now
        #expect(AddressBookPresentation.lastConnected(nil, now: now) == "Not connected recently")
        #expect(AddressBookPresentation.lastConnected(now.addingTimeInterval(-20), now: now) == "Connected just now")
        #expect(AddressBookPresentation.lastConnected(now.addingTimeInterval(-300), now: now) == "Connected 5 min ago")
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        #expect(AddressBookPresentation.lastConnected(noon.addingTimeInterval(-3 * 3600), now: noon)
                == "Connected 3 hours ago")
        #expect(AddressBookPresentation.lastConnected(noon.addingTimeInterval(-3600), now: noon) == "Connected 1 hour ago")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        #expect(AddressBookPresentation.lastConnected(yesterday, now: noon) == "Connected yesterday")
        let older = calendar.date(byAdding: .day, value: -10, to: noon)!
        #expect(AddressBookPresentation.lastConnected(older, now: noon).hasPrefix("Connected "))
        #expect(AddressBookPresentation.lastConnected(older, now: noon) != "Connected yesterday")
    }

    @Test func addressLineShowsTheLastAddressAndHowManyMore() {
        #expect(AddressBookPresentation.addressLine(entry(), defaultPort: 47800) == "studio.local")
        let several = entry(addresses: [SavedHostAddress(host: "fd7a::1", port: 5000),
                                        SavedHostAddress(host: "studio.local", port: 47800)])
        #expect(AddressBookPresentation.addressLine(several, defaultPort: 47800) == "[fd7a::1]:5000 +1")
        #expect(SavedHostAddress(host: "fd7a::1", port: 47800).shareable(defaultPort: 47800) == "fd7a::1")
    }

    @Test func badgesMenusAndInitials() {
        #expect(AddressBookPresentation.pinCaption(.unpinned) == nil)
        #expect(AddressBookPresentation.pinCaption(.pinned)?.contains("pinned") == true)
        #expect(AddressBookPresentation.pinCaption(.pinnedToOtherIdentity)?.contains("Trusted Hosts") == true)

        let a = entry(name: "Mac", addresses: [SavedHostAddress(host: "a.local", port: 47800)])
        let b = entry(name: "Mac", addresses: [SavedHostAddress(host: "b.local", port: 47801)])
        let c = entry(name: "Air")
        #expect(AddressBookPresentation.menuTitle(c, among: [a, b, c], defaultPort: 47800) == "Air")
        #expect(AddressBookPresentation.menuTitle(b, among: [a, b, c], defaultPort: 47800) == "Mac (b.local:47801)")

        #expect(AddressBookPresentation.initials("Studio Mac") == "SM")
        #expect(AddressBookPresentation.initials("mini") == "MI")
        #expect(AddressBookPresentation.initials("isas-macbook.local") == "IM")
        #expect(AddressBookPresentation.initials("—") == "?")

        let label = AddressBookPresentation.accessibilityLabel(entry(favorite: true, custom: "Office"), defaultPort: 47800,
                                                               now: Self.now)
        #expect(label == "Office, studio.local, Connected just now, favorite")
    }

    @Test func addressBookSymbolsExist() {
        for symbol in [Symbols.favorite, Symbols.unfavorite, Symbols.recent, Symbols.rename, Symbols.savedHostPlaceholder,
                       Symbols.thumbnails, Symbols.clearHistory, Symbols.connect] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            #expect(Symbols.all.contains(symbol))
        }
    }
}
