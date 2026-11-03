import AppKit
import CaptureCore
import Combine
import SessionCore
import SwiftUI
import TransportCore
import WireProtocol

/// "Share this Mac" (PRD §4 Host): permissions, display choice, how to reach this Mac, its identity fingerprint,
/// listening control, and — while a session is active — an unmissable red banner with Stop Sharing.
///
/// The approval sheet is not attached here but at the window root (`RootView`), so a request is shown whatever
/// screen the operator is looking at.
struct HostView: View {
    @Bindable var host: HostSession
    /// "Start listening when SwiftDesk opens" (AppModel, persisted in UserDefaults).
    @Binding var startListeningAtLaunch: Bool
    /// Host › Display › Quality (AppModel, persisted in UserDefaults; applies to the next session).
    @Binding var streamQuality: StreamQuality
    /// Host › Connection › "Let an allowed Viewer reconnect without asking" (AppModel, persisted in UserDefaults).
    @Binding var allowsReconnectWithoutPrompt: Bool
    /// Host › Clipboard › "Allow clipboard sharing" (AppModel, persisted in UserDefaults; live during a session).
    @Binding var allowsClipboardSharing: Bool
    /// Host › Display › "Show my pointer shape to the Viewer" (AppModel, persisted in UserDefaults; live).
    @Binding var sharesPointerShape: Bool
    /// Host › Startup › "Open at Login" (AppModel; the system's Login Items status).
    let loginItem: LoginItemController

    /// The bound port once listening (differs from the configured one only when port 0 was requested).
    private var listeningPort: UInt16 {
        if case .listening(let port) = host.state { port } else { host.configuration.port }
    }

    var body: some View {
        Form {
            if let peer = host.activePeer {
                Section {
                    ActiveSharingBanner(peer: peer, stop: host.stopSharing)
                    if host.isPeerSilent {
                        NoticeBanner(symbol: Symbols.poorConnection,
                                     message: "\(peer.name) is not responding. Keys and mouse buttons it was holding were released; the session continues if the connection recovers.")
                    } else if let notice = host.reconnectedNotice {
                        ReconnectedNoteRow(notice: notice, dismiss: host.dismissReconnectedNotice)
                    }
                    ClipboardSessionRow(status: host.clipboardStatus, peerName: peer.name,
                                        isOn: $allowsClipboardSharing)
                    LiveMetricsGrid(metrics: host.metrics, role: .host)
                        .padding(.vertical, 4)
                }
            }

            Section {
                HostStatusRow(host: host)
            }

            Section {
                PermissionCard(
                    title: "Screen & System Audio Recording",
                    symbol: Symbols.screenRecording,
                    granted: host.screenRecordingGranted,
                    explanation: "Needed to stream the display you select below. Capture runs only during a session you approved (or one started with your access password, if you turned that on), and frames are never saved.",
                    missingConsequence: "Viewers are refused until this is allowed. After allowing it, macOS may ask you to quit and reopen SwiftDesk.",
                    request: { host.requestScreenRecordingPermission() },
                    openSettings: host.openScreenRecordingSettings)
                PermissionCard(
                    title: "Accessibility",
                    symbol: Symbols.accessibility,
                    granted: host.accessibilityGranted,
                    explanation: "Needed so the Viewer's mouse and keyboard input can be applied to this Mac. Input is accepted only during an approved or password session.",
                    missingConsequence: "Without it, sessions are view-only: the Viewer can see this display but not control it.",
                    request: { host.requestAccessibilityPermission() },
                    openSettings: host.openAccessibilitySettings)
            } header: {
                HStack {
                    Text("Permissions")
                    Spacer()
                    Button {
                        host.refreshPermissions()
                    } label: {
                        Label("Refresh", systemImage: Symbols.refresh)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Check the permission status again")
                }
            }

            Section("Display") {
                if host.displays.isEmpty {
                    Text("No display found.").foregroundStyle(.secondary)
                } else {
                    Picker("Share", selection: $host.selectedDisplayID) {
                        ForEach(host.displays) { display in
                            Text(verbatim: "\(display.name) — \(display.pixelWidth)×\(display.pixelHeight)")
                                .tag(Optional(display.id))
                        }
                    }
                }
                Picker(selection: $streamQuality) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(verbatim: quality.label).tag(quality)
                    }
                } label: {
                    Label("Quality", systemImage: Symbols.quality)
                }
                .help("Sharp streams the display at its own resolution (up to 1920×1080) for crisp text and needs a good network. Balanced is SwiftDesk's previous 1280×720 mode, for weak Wi-Fi.")
                Toggle(isOn: $sharesPointerShape) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show my pointer shape to the Viewer")
                        Text(PointerPresentation.hostCaption(host.cursorShapeStatus,
                                                             peerName: host.activePeer?.name))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help("The Viewer always draws its own pointer so it moves without delay; this gives it the shape of yours.")
                HStack {
                    Text(Self.streamSummary(isSharing: host.isSharing, size: host.expectedStreamSize,
                                            fps: host.sessionAdaptation.ladder.first?.fps ?? 60))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Displays", action: host.refreshDisplays)
                        .controlSize(.small)
                }
            }

            Section {
                LabeledContent("Name", value: host.deviceName)
                HostAddressList(host: host)
                LabeledContent("Port", value: String(listeningPort))
                LabeledContent("Identity") {
                    FingerprintText(display: host.fingerprintDisplay, full: host.fingerprintDisplayFull)
                }
            } header: {
                HStack {
                    Text("This Mac")
                    Spacer()
                    Button {
                        host.refreshNetworkInfo()
                    } label: {
                        Label("Refresh", systemImage: Symbols.refresh)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } footer: {
                HStack {
                    Text("The Viewer shows this identity fingerprint the first time it connects. Ask the person connecting to compare it character by character before they trust this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }

            Section {
                Toggle(isOn: $allowsReconnectWithoutPrompt) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let an allowed Viewer reconnect without asking")
                        Text("For 2 minutes after a session's connection drops, the same Mac (same identity fingerprint) gets back in without a new prompt. Stop Sharing, Deny or Stop Listening cancels this.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label("Dropped connections", systemImage: Symbols.reconnect)
            } footer: {
                HStack {
                    Text("A session survives short network dropouts on its own. If the Viewer stops responding for a second, keys and mouse buttons it was holding are released on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }

            Section {
                Toggle(isOn: $allowsClipboardSharing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow clipboard sharing")
                        Text("During a session, text, rich text, images and links copied on either Mac can be pasted on the other. What you copied before the session is not sent, and items from password managers are never shared.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if allowsClipboardSharing,
                   let hint = ClipboardPresentation.accessHint(host.pasteboardAccess,
                                                               denied: host.clipboardStatus.accessDenied) {
                    PasteboardAccessHint(message: hint, blocked: host.pasteboardAccess == .alwaysDeny
                                         || host.clipboardStatus.accessDenied)
                }
            } header: {
                Label("Clipboard", systemImage: Symbols.clipboard)
            } footer: {
                HStack {
                    Text("Up to \(ClipboardPresentation.megabytes(ClipboardContent.maxTextBytes)) of text and \(ClipboardPresentation.megabytes(ClipboardContent.maxImageBytes)) per image. You can switch this off during a session from the menu bar or the Session menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }

            if host.supportsPasswordAccess {
                PasswordAccessSection(host: host)
            }

            StartupSection(loginItem: loginItem, startListeningAtLaunch: $startListeningAtLaunch)

            Section {
                DiagnosticsDisclosure(metrics: host.metrics, role: .host)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Permissions are usually granted in System Settings; re-read them when the user comes back.
            host.refreshPermissions()
            host.refreshNetworkInfo()
            host.refreshPasswordState()
            host.refreshPasteboardAccess()
            // Open at Login can be switched off or approved in System Settings › General › Login Items.
            loginItem.refresh()
        }
    }
}

extension HostView {
    /// The Display section's footnote, e.g. "Streams at 1600×900, 60 fps; drops lower on a weak network."
    nonisolated static func streamSummary(isSharing: Bool, size: (width: Int, height: Int)?, fps: Int) -> String {
        if isSharing { return "A new display or quality applies to the next session." }
        guard let size else { return "Streams at the display's resolution, \(fps) fps; drops lower on a weak network." }
        return "Streams at \(size.width)×\(size.height), \(fps) fps; drops lower on a weak network."
    }
}

/// Opt-in unattended access: an access password lets a Viewer in without anyone clicking Allow on this Mac.
///
/// The password is never stored: SessionCore keeps a PBKDF2 key in the keychain. The form enforces the minimum length
/// and a matching confirmation; the warning says plainly what turning this on means.
private struct PasswordAccessSection: View {
    let host: HostSession

    @State private var editing = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemoval = false

    private var enabledBinding: Binding<Bool> {
        Binding(get: { host.passwordAccessEnabled }, set: { newValue in
            if newValue && !host.passwordAccessConfigured {
                editing = true
                return
            }
            do {
                try host.setPasswordAccessEnabled(newValue)
                error = nil
            } catch {
                self.error = "\(error)"
            }
        })
    }

    var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow connections with a password")
                    Text(host.passwordAccessEnabled
                         ? "A Viewer that enters the password gets control without your approval."
                         : (host.passwordAccessConfigured ? "A password is set but switched off. Every connection needs your approval."
                                                          : "Off. Every connection needs your approval."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            NoticeBanner(symbol: Symbols.warning,
                         message: "Anyone with this password can control this Mac while SwiftDesk is listening.",
                         color: host.passwordAccessEnabled ? .orange : .secondary)

            if editing {
                SecureField("New password", text: $password, prompt: Text("At least \(AccessPassword.minimumLength) characters"))
                    .textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmation)
                    .textContentType(.newPassword)
                    .onSubmit(save)
                let problem = PasswordFormValidation.problem(password: password, confirmation: confirmation)
                HStack {
                    if let problem, !password.isEmpty {
                        Label(problem, systemImage: Symbols.warning)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Cancel") { resetForm() }
                    Button("Save Password", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(problem != nil || saving)
                }
            } else {
                HStack {
                    Button(host.passwordAccessConfigured ? "Change Password…" : "Set Password…") { editing = true }
                    if host.passwordAccessConfigured {
                        Button("Remove Password", role: .destructive) { confirmRemoval = true }
                    }
                    Spacer()
                }
            }

            if let error {
                NoticeBanner(symbol: Symbols.warning, message: error, color: .red)
            }
            if let failure = host.lastPasswordFailure {
                Text("\(host.passwordFailureCount) wrong password attempt\(host.passwordFailureCount == 1 ? "" : "s") since SwiftDesk opened. Latest: \(failure).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("Password access", systemImage: Symbols.password)
        } footer: {
            HStack {
                Text("Sessions started with the password show the same red banner, menu-bar indicator and Stop Sharing as approved ones. After 5 wrong passwords a device or address cannot use a password for 15 minutes; it can still ask for your approval. For access with nobody here, this Mac must stay awake and logged in: in System Settings › Energy, turn on \u{201C}Prevent automatic sleeping when the display is off\u{201D} and \u{201C}Wake for network access\u{201D}. A locked screen shows the Viewer the lock screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .confirmationDialog("Remove the access password?", isPresented: $confirmRemoval) {
            Button("Remove Password", role: .destructive) {
                host.clearAccessPassword()
                resetForm()
            }
        } message: {
            Text("Every connection will need your approval again. Viewers that saved the password have to forget it.")
        }
    }

    private func save() {
        guard PasswordFormValidation.problem(password: password, confirmation: confirmation) == nil, !saving else { return }
        saving = true
        let newPassword = password
        Task {
            do {
                try await host.setAccessPassword(newPassword)
                resetForm()
            } catch {
                self.error = "\(error)"
            }
            saving = false
        }
    }

    private func resetForm() {
        editing = false
        password = ""
        confirmation = ""
        error = nil
    }
}

/// Host › Startup (0.1.9): "Open at Login" (a login item via `SMAppService.mainApp`, its switch showing the real Login
/// Items status, with an approval note and a button to System Settings) next to "Start listening when SwiftDesk
/// opens". Together they bring an unattended Host back after a restart once someone is logged in.
private struct StartupSection: View {
    let loginItem: LoginItemController
    @Binding var startListeningAtLaunch: Bool

    private var openAtLoginBinding: Binding<Bool> {
        Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) })
    }

    var body: some View {
        let presentation = loginItem.presentation(listensAtLaunch: startListeningAtLaunch)
        Section {
            Toggle(isOn: openAtLoginBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open SwiftDesk at login")
                    Text(presentation.caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!presentation.isAvailable)
            .help("Adds SwiftDesk to System Settings › General › Login Items")
            if presentation.needsApproval {
                LoginItemApprovalRow(open: loginItem.openSystemSettings)
            }
            if let note = presentation.note {
                LoginItemNoteRow(note: note, tone: presentation.noteTone)
            }

            Toggle(isOn: $startListeningAtLaunch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start listening when SwiftDesk opens")
                    Text("Viewers can ask to connect as soon as SwiftDesk is open, without clicking Start Listening.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Label("Startup", systemImage: Symbols.openAtLogin)
        } footer: {
            HStack {
                Text("Login items open after someone logs in, not at the login window. For a Mac nobody is at, it must log in on its own after a restart (automatic login, which FileVault doesn\u{2019}t allow) and stay awake.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
    }
}

/// "Open at Login" is registered but switched off (or not yet allowed) in Login Items.
struct LoginItemApprovalRow: View {
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Symbols.warning).foregroundStyle(.orange)
            Text(LoginItemPresentation.approvalMessage)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Login Items…", action: open)
                .controlSize(.small)
                .help("Opens System Settings › General › Login Items")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A failure, a login item removed outside SwiftDesk, or where the app runs from.
struct LoginItemNoteRow: View {
    let note: String
    let tone: LoginItemPresentation.NoteTone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone == .warning ? Symbols.warning : Symbols.info)
                .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Header row: status dot, explanation, and the Start/Stop listening control.
private struct HostStatusRow: View {
    let host: HostSession

    var body: some View {
        let status = HostStatusPresentation.make(host.state, passwordAccess: host.passwordAccessEnabled)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(color: color(for: status.phase), pulsing: status.phase == .listening)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title).font(.headline)
                    Text(status.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                control(for: status.phase)
            }
            if let error = host.lastError {
                NoticeBanner(symbol: Symbols.warning, message: error, color: .red)
            } else if let reason = host.lastEndReason, status.phase == .listening || status.phase == .idle {
                Text("Last session: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let grace = host.reconnectGrace, status.phase == .listening {
                ReconnectGraceRow(grace: grace, revoke: host.revokeReconnectGrace)
            }
            if !host.screenRecordingGranted, status.phase == .listening {
                NoticeBanner(symbol: Symbols.warning,
                             message: "Screen Recording is not allowed, so incoming requests will be refused.")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func control(for phase: HostStatusPresentation.Phase) -> some View {
        switch phase {
        case .idle:
            Button("Start Listening", action: host.startListening)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .starting:
            ProgressView().controlSize(.small)
        case .listening, .awaitingApproval:
            Button("Stop Listening", action: host.stopListening)
                .controlSize(.large)
        case .active:
            Button("Stop Listening", action: host.stopListening)
                .controlSize(.large)
                .help("Ends the session and stops accepting new connections")
        }
    }

    private func color(for phase: HostStatusPresentation.Phase) -> Color {
        switch phase {
        case .idle: .secondary
        case .starting: .yellow
        case .listening: .green
        case .awaitingApproval: .orange
        case .active: .red
        }
    }
}

/// A dropped session's Viewer may come back without a prompt until the grace window ends; the operator can revoke it.
private struct ReconnectGraceRow: View {
    let grace: ReconnectGraceInfo
    let revoke: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Symbols.reconnect).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(grace.peerName)'s connection dropped.")
                Text("It can reconnect without asking until \(grace.expiresAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Require Approval", action: revoke)
                .controlSize(.small)
                .help("The next connection from this Mac asks you again")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Non-modal note after a session resumed without a prompt.
private struct ReconnectedNoteRow: View {
    let notice: ReconnectedNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Symbols.reconnect).foregroundStyle(.green)
            Text("Reconnected \(notice.peerName) after a dropped connection, without a new prompt (\(notice.at.formatted(date: .omitted, time: .shortened))).")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("OK", action: dismiss)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The local and Tailscale addresses a Viewer can dial, with Tailscale ones tagged.
private struct HostAddressList: View {
    let host: HostSession

    var body: some View {
        let port: UInt16 = if case .listening(let p) = host.state { p } else { host.configuration.port }
        let rows = AddressPresentation.rows(host.localAddresses, port: port)
        LabeledContent("Addresses") {
            if rows.isEmpty {
                Text("No network connection").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            if row.isTailscale {
                                TagLabel(text: "Tailscale", color: .purple)
                            } else {
                                Text(row.interface)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(row.address)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            CopyButton(value: row.endpoint, label: "Copy \(row.endpoint)")
                        }
                    }
                }
            }
        }
    }
}

/// Persistent red banner while a Viewer is connected (PRD §4: "prominent active-sharing indicator").
struct ActiveSharingBanner: View {
    let peer: HostPeer
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: Symbols.sharingActive)
                .font(.system(size: 30))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(HostPeerPresentation.title(peer))
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Text(peer.remoteAddress)
                    Text("·")
                    Text(peer.startedAt, style: .timer)
                        .monospacedDigit()
                    if peer.isViewOnly {
                        Text("·")
                        Label("View only", systemImage: Symbols.viewOnly)
                    }
                    if peer.viaPassword {
                        Text("·")
                        Label("No approval: password", systemImage: Symbols.password)
                    }
                    if peer.resumed {
                        Text("·")
                        Label("Reconnected", systemImage: Symbols.reconnect)
                    }
                }
                .font(.callout)
                .opacity(0.9)
            }
            .foregroundStyle(.white)
            Spacer()
            Button(action: stop) {
                Label("Stop Sharing", systemImage: Symbols.stop)
                    .font(.headline)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .controlSize(.large)
            .help("End the session now (⌘. from the Session menu)")
        }
        .padding(14)
        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(HostPeerPresentation.title(peer))
    }
}

/// Clipboard state of the active session with the live switch: shared both ways, off here, off on the Viewer, or an
/// older Viewer. A copy that could not be shared shows its reason underneath.
struct ClipboardSessionRow: View {
    let status: ClipboardSyncStatus
    let peerName: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Label {
                    Text(ClipboardPresentation.status(status, peerName: peerName))
                } icon: {
                    Image(systemName: status.isActive ? Symbols.clipboard : Symbols.clipboardOff)
                        .symbolVariant(status.isActive ? .fill : .none)
                        .foregroundStyle(status.isActive ? Color.accentColor : Color.secondary)
                }
            }
            .disabled(!status.peerSupports)
            .help("Allow clipboard sharing in this and later sessions")
            if let notice = status.notice {
                Text(ClipboardPresentation.notice(notice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }
}

/// Slim reminder shown at the top of other screens while this Mac is shared.
struct SharingStrip: View {
    let peer: HostPeer
    let stop: () -> Void
    let show: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Symbols.sharingActive)
                .symbolEffect(.pulse, options: .repeating)
            Text(HostPeerPresentation.title(peer))
                .font(.callout.weight(.semibold))
            Spacer()
            Button("Show", action: show)
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
            Button("Stop Sharing", action: stop)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.red)
    }
}

/// "Allow Control / Deny" decision for one connection request (PRD §4 Host step 4).
///
/// Safety choices: Deny is the cancel action (Esc) and Allow has no keyboard shortcut, so a stray Return can never
/// grant control; the countdown makes the automatic denial visible; a missing Accessibility permission is called
/// out because the session would then be view-only.
struct ApprovalSheet: View {
    let request: ConnectionRequest
    let timeout: Duration
    let approve: () -> Void
    let deny: () -> Void
    let openAccessibilitySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: Symbols.lock)
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    // peerName is sanitized to one line in SessionCore; the limits are a second guard.
                    Text("Allow “\(request.peerName)” to control this Mac?")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The Viewer will see the selected display and can use your keyboard and mouse until you stop sharing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Device name").foregroundStyle(.secondary)
                    Text(request.peerName).lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("Fingerprint").foregroundStyle(.secondary)
                    FingerprintText(display: request.fingerprintDisplay)
                }
                GridRow {
                    Text("Address").foregroundStyle(.secondary)
                    Text(request.remoteAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text("App version").foregroundStyle(.secondary)
                    Text(request.appVersion)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("The device name is chosen by the other Mac. If you are unsure, compare the fingerprint with the one shown under “This Mac” in SwiftDesk on that Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.accessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    NoticeBanner(symbol: Symbols.viewOnly,
                                 message: "Accessibility is not allowed for SwiftDesk, so this session will be view-only: the Viewer can watch but not control.")
                    Button("Open Accessibility Settings", action: openAccessibilitySettings)
                        .controlSize(.small)
                }
            }

            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = ApprovalCountdown.secondsRemaining(receivedAt: request.receivedAt, timeout: timeout,
                                                                  now: context.date)
                    Text("Denied automatically in \(left) s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Deny", role: .cancel, action: deny)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Allow Control", action: approve)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }
}
