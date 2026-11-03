import Foundation
import InputCore
import SessionCore

/// The three things this app can do, as offered by the role picker.
public enum AppRole: String, CaseIterable, Identifiable, Sendable {
    case host
    case viewer
    case loopback

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .host: "Share this Mac"
        case .viewer: "Control a Mac"
        case .loopback: "Local Loopback Test"
        }
    }

    public var subtitle: String {
        switch self {
        case .host: "Let a trusted Mac see and control this one, after you approve each session."
        case .viewer: "Connect to another Mac by name or IP address and control it."
        case .loopback: "Capture, encode, decode and render on this Mac to measure the video pipeline."
        }
    }

    public var symbol: String {
        switch self {
        case .host: Symbols.shareThisMac
        case .viewer: Symbols.controlMac
        case .loopback: Symbols.loopback
        }
    }
}

/// Every SF Symbol name the UI uses, in one place so a unit test can prove each one exists on this OS
/// (an unknown name renders as an empty image instead of failing loudly).
public enum Symbols {
    public static let shareThisMac = "rectangle.on.rectangle"
    public static let controlMac = "display"
    public static let loopback = "arrow.triangle.2.circlepath"
    public static let sharingActive = "record.circle.fill"
    public static let pendingRequest = "exclamationmark.circle.fill"
    public static let idleMenuBar = "rectangle.on.rectangle"
    public static let listening = "antenna.radiowaves.left.and.right"
    public static let screenRecording = "rectangle.dashed.badge.record"
    public static let accessibility = "accessibility"
    public static let granted = "checkmark.circle.fill"
    public static let missing = "xmark.circle.fill"
    public static let warning = "exclamationmark.triangle.fill"
    public static let fingerprint = "touchid"
    public static let network = "network"
    public static let tailscale = "point.3.connected.trianglepath.dotted"
    public static let copy = "doc.on.doc"
    public static let refresh = "arrow.clockwise"
    public static let trusted = "checkmark.shield"
    public static let untrusted = "exclamationmark.shield"
    public static let trash = "trash"
    public static let bonjour = "dot.radiowaves.left.and.right"
    public static let keyboard = "keyboard"
    public static let disconnect = "xmark.circle"
    public static let stop = "stop.fill"
    public static let play = "play.fill"
    public static let diagnostics = "stethoscope"
    public static let rtt = "timer"
    public static let fps = "film.stack"
    public static let bitrate = "speedometer"
    public static let loss = "chart.line.downtrend.xyaxis"
    public static let latency = "clock.arrow.circlepath"
    public static let resolution = "aspectratio"
    public static let path = "point.topleft.down.to.point.bottomright.curvepath"
    public static let viewOnly = "eye"
    public static let lock = "lock.fill"
    public static let identityChanged = "exclamationmark.lock.fill"
    public static let cursorClick = "cursorarrow.click.2"
    public static let password = "key.fill"
    public static let actualSize = "1.magnifyingglass"
    public static let quality = "sparkles.tv"
    public static let poorConnection = "wifi.exclamationmark"
    public static let reconnect = "arrow.clockwise.circle"
    public static let clipboard = "doc.on.clipboard"
    public static let clipboardOff = "clipboard"
    public static let pointer = "cursorarrow.rays"
    public static let sendKeys = "command"
    public static let favorite = "star.fill"
    public static let unfavorite = "star.slash"
    public static let recent = "clock"
    public static let rename = "pencil"
    public static let savedHostPlaceholder = "desktopcomputer"
    public static let thumbnails = "photo.on.rectangle"
    public static let clearHistory = "clock.badge.xmark"
    public static let connect = "arrow.right.circle"
    public static let openAtLogin = "power"
    public static let info = "info.circle"
    public static let dismiss = "xmark"

    public static let all: [String] = [
        shareThisMac, controlMac, loopback, sharingActive, pendingRequest, idleMenuBar, listening, screenRecording,
        accessibility, granted, missing, warning, fingerprint, network, tailscale, copy, refresh, trusted,
        untrusted, trash, bonjour, keyboard, disconnect, stop, play, diagnostics, rtt, fps, bitrate, loss, latency,
        resolution, path, viewOnly, lock, identityChanged, cursorClick, password, actualSize, quality, poorConnection,
        reconnect, clipboard, clipboardOff, pointer, sendKeys, favorite, unfavorite, recent, rename,
        savedHostPlaceholder, thumbnails, clearHistory, connect, openAtLogin, info, dismiss,
    ]
}

/// Quitting while the stream window is up (0.2.0): ⌘Q is no longer sent to the Host unless "Send system shortcuts" is
/// on, so a ⌘Q meant for the remote Mac would otherwise end the session without a word.
public enum QuitPresentation {
    /// Ask only for ⌘Q (the menu item, the Dock and log-out are deliberate) and only with the stream window up.
    public static func asksFirst(presentingStream: Bool, triggeredByQuitKey: Bool) -> Bool {
        presentingStream && triggeredByQuitKey
    }

    public static let title = "Quit SwiftDesk?"

    public static func message(_ state: ViewerSession.State) -> String {
        let name: String? = switch state {
        case .streaming(let info): info.hostName
        case .reconnecting(let status): status.stream.hostName
        default: nil
        }
        let session = name.map { "your session with \($0)" } ?? "your session"
        return "Quitting ends \(session). To press \u{2318}Q on the remote Mac, use Send Keys or turn on \u{201C}Send system shortcuts\u{201D}."
    }
}

/// What the menu-bar item shows. The Host must always have a visible way to see and revoke an active session
/// (PRD §4 "Security UX"), so this is derived purely from session state and unit-tested.
public struct MenuBarStatus: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        /// Template image, adapts to the menu bar appearance.
        case neutral
        /// Orange: someone is waiting for the operator's decision.
        case attention
        /// Red: this Mac is being shared right now.
        case sharing
    }

    public var tone: Tone
    public var symbol: String
    public var title: String
    public var detail: String?

    /// - Parameters:
    ///   - passwordAccess: the Host's password access is on (the listening state says so).
    ///   - viewerReconnecting: the Viewer lost its connection to `viewerStreamingHost` and is redialing.
    ///   - peerSilent: the active session's Viewer is not responding (its held input was released).
    public static func make(hostState: HostSession.State?, viewerStreamingHost: String?,
                            passwordAccess: Bool = false, viewerReconnecting: Bool = false,
                            peerSilent: Bool = false) -> MenuBarStatus {
        switch hostState {
        case .active(let peer):
            var detail = peer.isViewOnly ? "View only · \(peer.remoteAddress)" : peer.remoteAddress
            if peerSilent {
                detail = "Not responding · \(detail)"
            } else if peer.resumed {
                detail = "Reconnected · \(detail)"
            }
            return MenuBarStatus(tone: .sharing, symbol: Symbols.sharingActive,
                                 title: HostPeerPresentation.title(peer), detail: detail)
        case .awaitingApproval(let request):
            return MenuBarStatus(tone: .attention, symbol: Symbols.pendingRequest,
                                 title: "\(request.peerName) wants to control this Mac",
                                 detail: request.remoteAddress)
        case .listening(let port):
            return MenuBarStatus(tone: .neutral, symbol: Symbols.listening,
                                 title: "Waiting for a Viewer",
                                 detail: "Listening on port \(port)" + (passwordAccess ? " · password access on" : ""))
        case .starting:
            return MenuBarStatus(tone: .neutral, symbol: Symbols.listening, title: "Starting…", detail: nil)
        case .idle, .none:
            if let viewerStreamingHost {
                if viewerReconnecting {
                    return MenuBarStatus(tone: .neutral, symbol: Symbols.reconnect,
                                         title: "Reconnecting to \(viewerStreamingHost)…", detail: nil)
                }
                return MenuBarStatus(tone: .neutral, symbol: Symbols.controlMac,
                                     title: "Controlling \(viewerStreamingHost)", detail: nil)
            }
            return MenuBarStatus(tone: .neutral, symbol: Symbols.idleMenuBar, title: "Not sharing", detail: nil)
        }
    }
}

/// Host-screen headline for the current state.
public struct HostStatusPresentation: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, starting, listening, awaitingApproval, active }

    public var phase: Phase
    public var title: String
    public var detail: String

    /// - Parameter passwordAccess: the Host's password access is on, so a Viewer with the password needs no approval
    ///   and the "you will be asked" promise must not be shown.
    public static func make(_ state: HostSession.State, passwordAccess: Bool = false) -> HostStatusPresentation {
        switch state {
        case .idle:
            HostStatusPresentation(phase: .idle, title: "Not sharing",
                                   detail: passwordAccess
                                       ? "Start listening so a Viewer can connect. Viewers with the access password can connect without asking; others need your approval."
                                       : "Start listening so a Viewer can ask to connect. Nothing is shared until you approve a request.")
        case .starting:
            HostStatusPresentation(phase: .starting, title: "Starting…", detail: "Opening a secure QUIC listener.")
        case .listening(let port):
            HostStatusPresentation(phase: .listening, title: "Waiting for a Viewer",
                                   detail: passwordAccess
                                       ? "Listening on port \(port). Viewers with the access password can connect without asking; others need your approval."
                                       : "Listening on port \(port). You will be asked before anyone can see or control this Mac.")
        case .awaitingApproval(let request):
            HostStatusPresentation(phase: .awaitingApproval, title: "Connection request",
                                   detail: "\(request.peerName) (\(request.remoteAddress)) is waiting for your decision.")
        case .active(let peer):
            HostStatusPresentation(phase: .active, title: HostPeerPresentation.title(peer),
                                   detail: (peer.resumed ? "Reconnected after a dropped connection. " : "")
                                       + (peer.viaPassword ? "Signed in with the access password. " : "") + (peer.isViewOnly
                                       ? "View only: Accessibility is off, so the Viewer cannot control this Mac."
                                       : "The Viewer can see this display and control the keyboard and mouse."))
        }
    }
}

/// How the active Viewer is named everywhere on the Host (banner, strip, menu bar, status row).
public enum HostPeerPresentation {
    /// "Controlled via password by …" for a password session (nobody clicked Allow), else "Sharing this Mac with …".
    public static func title(_ peer: HostPeer) -> String {
        peer.viaPassword ? "Controlled via password by \(peer.name)" : "Sharing this Mac with \(peer.name)"
    }
}

/// Validation of the Host's "Set password" form.
public enum PasswordFormValidation {
    /// nil when the two entries can be saved, else what to fix.
    public static func problem(password: String, confirmation: String) -> String? {
        if password.isEmpty { return "Enter a password." }
        if !AccessPassword.isAcceptable(password) {
            return "Use at least \(AccessPassword.minimumLength) characters."
        }
        if password != confirmation { return "The passwords do not match." }
        return nil
    }
}

/// Remaining time before the Host auto-denies a request.
public enum ApprovalCountdown {
    /// Whole seconds left (never negative), rounded up so the last second shows `1`, not `0`.
    public static func secondsRemaining(receivedAt: Date, timeout: Duration, now: Date) -> Int {
        let total = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let left = receivedAt.addingTimeInterval(total).timeIntervalSince(now)
        return max(0, Int(left.rounded(.up)))
    }
}

/// The Viewer screen's top-level layout, derived from `ViewerSession.State`.
public enum ViewerPhase: Sendable, Equatable {
    /// Connect form. `notice` is the reason the previous attempt/session ended, if any.
    case form(notice: ViewerNotice?)
    case connecting(target: String)
    case verifying(ViewerSession.HostVerification)
    case waitingForApproval
    case streaming(ViewerSession.StreamInfo)

    public static func make(_ state: ViewerSession.State) -> ViewerPhase {
        switch state {
        case .idle:
            .form(notice: nil)
        case .connecting(let host, let port):
            .connecting(target: ConnectTarget.endpointString(host: host, port: port))
        case .verifyingHost(let verification):
            .verifying(verification)
        case .awaitingApproval:
            .waitingForApproval
        case .streaming(let info):
            .streaming(info)
        case .reconnecting(let status):
            // Same screen as streaming: the last frame stays up, dimmed, under the reconnect overlay.
            .streaming(status.stream)
        case .disconnected(let reason):
            .form(notice: ViewerNotice.make(reason: reason))
        }
    }
}

/// The reconnect card's explanation line, e.g. "Next attempt in 3 s · gives up in 52 s".
public enum ReconnectPresentation {
    public static func detail(_ status: ViewerSession.ReconnectStatus, usingPassword: Bool, now: Date) -> String {
        let left = max(0, Int(status.deadline.timeIntervalSince(now).rounded(.up)))
        switch status.phase {
        case .waiting(let next):
            let wait = max(0, Int(next.timeIntervalSince(now).rounded(.up)))
            let lead = status.attempt == 0 ? "The connection dropped." : "Attempt \(status.attempt) did not get through."
            return wait > 0
                ? "\(lead) Next attempt in \(wait) s · gives up in \(left) s."
                : "\(lead) Trying again…"
        case .connecting:
            return "Attempt \(status.attempt): connecting securely to the same Host (its identity is checked automatically)."
        case .awaitingApproval:
            if usingPassword { return "Connected. Signing in with the password…" }
            return status.hostSupportsResume
                ? "Connected. Resuming the session — the Host normally lets a Mac it allowed back in without asking again."
                : "Connected. The person at the Host has to allow the connection again."
        }
    }
}

/// Why the last Viewer session ended, classified so the UI can style it and offer the right fix.
public struct ViewerNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The user ended it; informational.
        case info
        /// Denied, timed out, lost connection.
        case problem
        /// A pinned address presented a different certificate: possible impersonation, never auto-resolved.
        case identityChanged
        /// The Host rejected the password; the form lets the user type it again.
        case incorrectPassword
    }

    public var kind: Kind
    public var message: String

    public static func make(reason: String) -> ViewerNotice {
        if reason == ViewerHandshake.identityChangedMessage || reason.hasPrefix("Host identity changed") {
            return ViewerNotice(kind: .identityChanged, message: reason)
        }
        if reason == ViewerHandshake.incorrectPasswordMessage {
            return ViewerNotice(kind: .incorrectPassword, message: reason)
        }
        if reason == "Disconnected" || reason == "You did not trust the Host's identity" {
            return ViewerNotice(kind: .info, message: reason)
        }
        return ViewerNotice(kind: .problem, message: reason)
    }
}

/// Which power/App Nap assertion the process should hold.
///
/// Latency rationale: macOS App Nap throttles timers and lowers the QoS of background apps, which would add jitter
/// to the capture → encode → send path whenever the SwiftDesk window is hidden on the Host. An active Host session
/// also keeps the display awake, because a sleeping display stops ScreenCaptureKit from producing frames while the
/// remote user is working.
public enum SessionActivityPolicy {
    public static func options(hostSharing: Bool, viewerStreaming: Bool, loopbackRunning: Bool) -> ProcessInfo.ActivityOptions? {
        var options: ProcessInfo.ActivityOptions = []
        if hostSharing { options.formUnion([.userInitiated, .latencyCritical, .idleDisplaySleepDisabled]) }
        if viewerStreaming || loopbackRunning { options.formUnion([.userInitiated, .latencyCritical]) }
        return options.isEmpty ? nil : options
    }

    public static func reason(hostSharing: Bool, viewerStreaming: Bool, loopbackRunning: Bool) -> String {
        if hostSharing { return "SwiftDesk is sharing this Mac" }
        if viewerStreaming { return "SwiftDesk is controlling a remote Mac" }
        if loopbackRunning { return "SwiftDesk loopback measurement" }
        return "SwiftDesk"
    }
}

/// Wording for clipboard sharing (0.1.5): the session status line, small notices and the macOS paste-privacy hint.
public enum ClipboardPresentation {
    /// One line for the toolbar help / Host session row, e.g. "Clipboard shared with Mac mini".
    public static func status(_ status: ClipboardSyncStatus, peerName: String) -> String {
        if !status.peerSupports { return "\(peerName) runs a SwiftDesk without clipboard sharing" }
        if !status.localEnabled { return "Clipboard sharing is off on this Mac" }
        if !status.peerEnabled { return "Clipboard sharing is off on \(peerName)" }
        return "Clipboard shared with \(peerName)"
    }

    /// The small note shown when a copy was not shared.
    public static func notice(_ notice: ClipboardNotice) -> String {
        switch notice.kind {
        case .tooLarge(let bytes, let limit):
            "Not shared: the copied item is \(megabytes(bytes)) (limit \(megabytes(limit)))"
        case .filesNotShared:
            "Copied files aren’t shared — only text, images and links"
        case .accessDenied:
            "macOS didn’t let SwiftDesk read the clipboard"
        }
    }

    /// Explains the macOS paste prompt / block, or nil when reading the clipboard is unrestricted.
    public static func accessHint(_ behavior: PasteboardAccessBehavior, denied: Bool) -> String? {
        if denied || behavior == .alwaysDeny {
            return "macOS is blocking SwiftDesk from reading the clipboard. To share what you copy, set SwiftDesk to Allow in System Settings › Privacy & Security › Paste from Other Apps."
        }
        if behavior.mayPrompt {
            return "macOS may ask before SwiftDesk reads what you copied. Choose Allow Paste, or set SwiftDesk to Allow in System Settings › Privacy & Security › Paste from Other Apps."
        }
        return nil
    }

    /// "1 MB", "16 MB", "23.4 MB" (binary megabytes, as the limits are defined).
    public static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 10 || mb == mb.rounded() { return "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f MB", mb)
    }
}

/// Wording for remote pointer shapes (0.1.6).
public enum PointerPresentation {
    /// The caption under the Host's switch: what it does, and during a session whether the Viewer gets it.
    public static func hostCaption(_ status: CursorShapeStatus, peerName: String?) -> String {
        if let peerName {
            if !status.peerSupports { return "\(peerName) runs a SwiftDesk without pointer shapes; it shows a plain arrow." }
            if status.enabled { return "\(peerName) sees your pointer’s shape: text cursor, resize arrows, hidden …" }
            return "\(peerName) sees a plain arrow."
        }
        return "The Viewer’s pointer takes your pointer’s shape — text cursor, resize arrows, pointing hand, or hidden. Only the shape is sent, never what is under it."
    }

    /// One line for the Viewer (Session menu help, diagnostics), e.g. "Showing Mac mini’s pointer shape".
    public static func viewerStatus(_ status: RemotePointerStatus, enabled: Bool, hostName: String) -> String {
        guard enabled else { return "Pointer shapes are off on this Mac" }
        switch status {
        case .inactive: return "Not connected"
        case .unsupported: return "\(hostName) runs a SwiftDesk without pointer shapes"
        case .offOnHost: return "\(hostName) doesn’t share its pointer shape"
        case .unavailable: return "\(hostName) can’t tell its pointer shape right now"
        case .active: return "Showing \(hostName)’s pointer shape"
        }
    }
}

/// Wording for the Send Keys menu and the "Send system shortcuts" switch (0.1.7).
public enum ShortcutPresentation {
    /// The menu item: the shortcut's name, with "…" when it asks for confirmation first (Lock Screen).
    public static func menuTitle(_ shortcut: SystemShortcut) -> String {
        shortcut.needsConfirmation && !shortcut.title.hasSuffix("…") ? shortcut.title + "…" : shortcut.title
    }

    /// One line for the toolbar tooltip and the menu's switch: where system shortcuts go right now.
    public static func status(_ status: SystemShortcutCaptureStatus, hostName: String) -> String {
        switch status {
        case .off: "System shortcuts act on this Mac; use Send Keys to press them on \(hostName)"
        case .needsPermission: "Allow SwiftDesk under Accessibility on this Mac to send system shortcuts"
        case .standby: "System shortcuts go to \(hostName) while you control it"
        case .active: "⌘Tab, ⌘Space, Mission Control and other system shortcuts go to \(hostName)"
        case .unavailable: "macOS did not let SwiftDesk take system shortcuts; turn SwiftDesk off and on under Accessibility"
        }
    }

    /// The explanation under the switch in Viewer › Connection.
    public static let settingsCaption = "While you control the remote Mac, ⌘Tab, ⌘Space, Mission Control, ⌃-arrow Spaces, screenshot keys, ⌥⌘Esc and ⌃⌘Q act on it instead of this Mac. Press \(ViewerSession.releaseShortcutDescription), click Controlling on the toolbar or click another window to get them back. Needs Accessibility permission on this Mac. The Send Keys menu on the stream toolbar works without it."

    /// The hint shown while the switch is on but Accessibility is missing (or the tap was refused).
    public static func permissionHint(_ status: SystemShortcutCaptureStatus) -> String? {
        switch status {
        case .needsPermission:
            "To take system shortcuts, SwiftDesk needs Accessibility in System Settings › Privacy & Security on this Mac. It only listens while you control a remote Mac."
        case .unavailable:
            "macOS refused the keyboard tap. In Privacy & Security › Accessibility, turn SwiftDesk off and on again (a rebuilt app needs a fresh grant)."
        case .off, .standby, .active:
            nil
        }
    }

    /// The note over the video when the switch is on during a stream but cannot take shortcuts (review 0.2.0): the
    /// connect form's hint is hidden while streaming, and the switch never prompts on its own.
    public static func streamNote(_ status: SystemShortcutCaptureStatus) -> String? {
        switch status {
        case .needsPermission:
            "System shortcuts stay on this Mac until SwiftDesk is allowed under Accessibility"
        case .unavailable:
            "macOS refused to let SwiftDesk take system shortcuts; turn SwiftDesk off and on under Accessibility"
        case .off, .standby, .active:
            nil
        }
    }

    /// Confirmation for `SystemShortcut.needsConfirmation` items.
    public static func confirmationTitle(_ shortcut: SystemShortcut, hostName: String) -> String {
        "\(shortcut.title) on \(hostName)?"
    }

    public static func confirmationMessage(_ shortcut: SystemShortcut) -> String {
        switch shortcut {
        case .lockScreen:
            "SwiftDesk can’t type into the lock screen, so someone at the remote Mac will have to unlock it before you can continue."
        default:
            "\(shortcut.keysDescription) will be pressed on the remote Mac."
        }
    }
}

/// Wording for the address book on the connect screen (0.1.8): card captions, badges, menus and the settings rows.
public enum AddressBookPresentation {
    /// "Connected just now", "Connected 5 min ago", "Connected yesterday", "Connected 3 Nov 2026"; favorites
    /// whose history was cleared say "Not connected recently".
    public static func lastConnected(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not connected recently" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Connected just now" }
        if seconds < 3600 { return "Connected \(Int(seconds / 60)) min ago" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "Connected 1 hour ago" : "Connected \(hours) hours ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Connected yesterday"
        }
        return "Connected " + date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The card's address line: the address used last, plus how many others the same Mac was reached at.
    public static func addressLine(_ entry: SavedHost, defaultPort: UInt16) -> String {
        guard let primary = entry.primaryAddress else { return "" }
        let main = primary.shareable(defaultPort: defaultPort)
        let others = entry.addresses.count - 1
        return others > 0 ? "\(main) +\(others)" : main
    }

    /// Tooltip / accessibility text of the pin badge, nil when nothing needs saying (unpinned is the normal case).
    public static func pinCaption(_ state: SavedHostPinState) -> String? {
        switch state {
        case .pinned: "Trusted: its fingerprint is pinned for this address"
        case .unpinned: nil
        case .pinnedToOtherIdentity:
            "Another identity is pinned for this address; connecting will fail until you remove it from Trusted Hosts"
        }
    }

    /// The card's accessibility label, e.g. "Studio, studio.local, Connected 5 min ago, favorite".
    public static func accessibilityLabel(_ entry: SavedHost, defaultPort: UInt16, now: Date) -> String {
        var parts = [entry.displayName, addressLine(entry, defaultPort: defaultPort), lastConnected(entry.lastConnectedAt, now: now)]
        if entry.isFavorite { parts.append("favorite") }
        return parts.joined(separator: ", ")
    }

    /// A menu item for one saved Host in the quick-connect menus: its name, with the address when two share a name.
    public static func menuTitle(_ entry: SavedHost, among entries: [SavedHost], defaultPort: UInt16) -> String {
        let clashes = entries.filter { $0.displayName == entry.displayName }.count > 1
        guard clashes, let primary = entry.primaryAddress else { return entry.displayName }
        return "\(entry.displayName) (\(primary.shareable(defaultPort: defaultPort)))"
    }

    /// Two letters for the placeholder of a Host without a thumbnail ("Studio Mac" → "SM", "mini" → "MI").
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters: String
        if words.count >= 2 {
            letters = String(words[0].prefix(1)) + String(words[1].prefix(1))
        } else if let word = words.first {
            letters = String(word.prefix(2))
        } else {
            letters = "?"
        }
        return letters.uppercased()
    }

    public static let emptyRecent = "Macs you connect to appear here, with a picture of their screen from your last session. Right-click one to rename it or add it to Favorites."

    public static let thumbnailsCaption = "When a session ends, SwiftDesk keeps a small picture of the remote screen with the Host in Recent. Pictures stay on this Mac (Application Support › SwiftDesk); turning this off deletes them."

    public static let clearHistoryMessage = "Removes every Host from Recent and deletes all saved screen pictures. Favorites stay; trusted fingerprints and saved passwords are not affected."
}
