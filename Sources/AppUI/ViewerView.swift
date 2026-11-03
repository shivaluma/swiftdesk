import AppKit
import InputCore
import SessionCore
import SwiftUI
import TransportCore
import WireProtocol

/// "Control a Mac" (PRD §4 Viewer): connect form → fingerprint verification → waiting for the Host's approval →
/// full-window stream. Each phase is a separate view chosen from `ViewerPhase`, so the session state machine stays
/// the single source of truth. The connect form is also the Viewer's home (0.1.8): Favorites and Recent Hosts from
/// the address book, then Bonjour discoveries and the trusted (pinned) Hosts.
struct ViewerView: View {
    let viewer: ViewerSession
    /// "Reconnect automatically after a dropout" (AppModel, persisted in UserDefaults).
    @Binding var autoReconnect: Bool
    /// "Share clipboard" (AppModel, persisted in UserDefaults; also on the stream toolbar).
    @Binding var sharesClipboard: Bool
    /// "Show the Host's pointer shape" (AppModel, persisted in UserDefaults; also in the Session menu).
    @Binding var showsRemotePointer: Bool
    /// "Send system shortcuts to the remote Mac" (AppModel, persisted; also in the Send Keys menus).
    @Binding var sendsSystemShortcuts: Bool
    /// "Save thumbnails of remote screens" (AppModel, persisted).
    @Binding var savesThumbnails: Bool
    /// A Send Keys item (AppModel: asks first for Lock Screen).
    let sendShortcut: (SystemShortcut) -> Void
    @State private var discovery = BonjourDiscovery()
    /// The last address dialed, so an "identity changed" error can offer to forget exactly that pin.
    @State private var lastTarget: ConnectTarget?

    var body: some View {
        let phase = ViewerPhase.make(viewer.state)
        Group {
            switch phase {
            case .form(let notice):
                ConnectForm(viewer: viewer, discovery: discovery, notice: notice, lastTarget: $lastTarget,
                            autoReconnect: $autoReconnect, sharesClipboard: $sharesClipboard,
                            showsRemotePointer: $showsRemotePointer, sendsSystemShortcuts: $sendsSystemShortcuts,
                            savesThumbnails: $savesThumbnails)
            case .connecting(let target):
                ProgressPane(title: "Connecting to \(target)…",
                             detail: "Establishing an encrypted QUIC connection and checking the Host's identity.",
                             cancel: viewer.disconnect)
            case .verifying:
                ProgressPane(title: "Verify the Host's identity",
                             detail: "Compare the fingerprint in the sheet with the one shown on the Host.",
                             cancel: viewer.rejectHost)
            case .waitingForApproval:
                if viewer.isUsingPassword {
                    ProgressPane(title: "Signing in with password…",
                                 detail: "The Host is checking the password. Nobody needs to click Allow on it.",
                                 cancel: viewer.disconnect)
                } else {
                    ProgressPane(title: "Waiting for approval…",
                                 detail: "Ask the person at the Host to click “Allow Control”. The request expires after about a minute.",
                                 cancel: viewer.disconnect)
                }
            case .streaming(let info):
                StreamingView(viewer: viewer, info: info, sharesClipboard: $sharesClipboard,
                              showsRemotePointer: $showsRemotePointer, sendsSystemShortcuts: $sendsSystemShortcuts,
                              sendShortcut: sendShortcut)
            }
        }
        .sheet(item: verificationBinding) { item in
            HostVerificationSheet(prompt: HostIdentityPrompt(item.verification),
                                  trust: { remember in viewer.trustHost(remember: remember) },
                                  cancel: viewer.rejectHost)
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .onChange(of: viewer.state) { _, state in
            // Whatever started the attempt (the form, a saved Host, the Session menu), remember the address so an
            // "identity changed" error can offer to forget exactly that pin.
            if case .connecting(let host, let port) = state { lastTarget = ConnectTarget(host: host, port: port) }
        }
    }

    /// Presented while the session is in `.verifyingHost`; dismissing it any other way counts as "Cancel".
    private var verificationBinding: Binding<VerificationItem?> {
        Binding(
            get: {
                if case .verifyingHost(let verification) = viewer.state { VerificationItem(verification: verification) } else { nil }
            },
            set: { newValue in
                if newValue == nil, case .verifyingHost = viewer.state { viewer.rejectHost() }
            })
    }
}

/// Sheet item for one verification prompt; a new address or fingerprint is a new sheet.
private struct VerificationItem: Identifiable {
    let verification: ViewerSession.HostVerification
    var id: String {
        "\(verification.host):\(verification.port):\(TrustedHostStore.hex(verification.fingerprint))"
    }
}

/// Centered spinner with a title, explanation and Cancel.
private struct ProgressPane: View {
    let title: String
    let detail: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Connect form

private struct ConnectForm: View {
    let viewer: ViewerSession
    let discovery: BonjourDiscovery
    let notice: ViewerNotice?
    @Binding var lastTarget: ConnectTarget?
    @Binding var autoReconnect: Bool
    @Binding var sharesClipboard: Bool
    @Binding var showsRemotePointer: Bool
    @Binding var sendsSystemShortcuts: Bool
    @Binding var savesThumbnails: Bool

    @AppStorage("SwiftDesk.viewer.lastHost") private var hostText = ""
    @AppStorage("SwiftDesk.viewer.lastPort") private var portText = String(WireConstants.defaultPort)
    @AppStorage("SwiftDesk.viewer.rememberPassword") private var rememberPassword = false
    /// Never persisted here: a remembered password lives in the keychain (SessionCore), only after it worked.
    @State private var passwordText = ""
    @State private var validationError: String?
    @State private var pendingRemoval: TrustedHost?
    /// The saved Host being renamed, and the text field's contents.
    @State private var renaming: SavedHost?
    @State private var renameText = ""
    @State private var confirmingClearHistory = false

    var body: some View {
        Form {
            if let notice {
                Section { NoticeView(notice: notice, lastTarget: lastTarget, viewer: viewer) }
            }

            Section {
                TextField("Host", text: $hostText, prompt: Text("Name or IP address, e.g. studio.local or 100.101.102.103"))
                    .onSubmit(connect)
                TextField("Port", text: $portText, prompt: Text(String(WireConstants.defaultPort)))
                    .onSubmit(connect)
                SecureField("Password", text: $passwordText,
                            prompt: Text("Optional: only if the Host allows password access"))
                    .textContentType(.password)
                    .onSubmit(connect)
                if !passwordText.isEmpty {
                    Toggle("Remember for this Host", isOn: $rememberPassword)
                        .help("Saved in the keychain after the password worked, only for a Host you trusted with “Remember this Host”.")
                }
                if let validationError {
                    Label(validationError, systemImage: Symbols.warning)
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                HStack {
                    Text("LAN addresses and Tailscale IPs or MagicDNS names all work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(hostText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Connect to a Mac")
            }

            let saved = SavedHostSections(viewer.savedHosts)
            if !saved.favorites.isEmpty {
                Section {
                    SavedHostGrid(entries: saved.favorites, viewer: viewer, connect: connect(saved:address:),
                                  rename: beginRename)
                } header: {
                    Label("Favorites", systemImage: Symbols.favorite)
                }
            }

            if viewer.addressBook != nil {
                Section {
                    if saved.recent.isEmpty {
                        Text(AddressBookPresentation.emptyRecent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        SavedHostGrid(entries: saved.recent, viewer: viewer, connect: connect(saved:address:),
                                      rename: beginRename)
                    }
                } header: {
                    Label("Recent", systemImage: Symbols.recent)
                }
            }

            Section {
                if viewer.trustedHosts.isEmpty {
                    Text("Hosts you trust with “Remember this Host” appear here. Their fingerprint is pinned, so a different certificate at the same address is refused.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewer.trustedHosts) { trusted in
                        TrustedHostRow(trusted: trusted,
                                       hasSavedPassword: viewer.hasSavedPassword(trusted),
                                       connect: { connect(key: trusted.key) },
                                       forgetPassword: { viewer.forgetSavedPassword(for: trusted) },
                                       remove: { pendingRemoval = trusted })
                    }
                }
            } header: {
                Text("Trusted Hosts")
            }

            Section {
                if discovery.results.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs sharing on this network…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(discovery.results, id: \.self) { result in
                        HStack {
                            Image(systemName: Symbols.controlMac).foregroundStyle(.secondary)
                            Text(result.name)
                            if result.name == viewer.deviceName {
                                TagLabel(text: "This Mac", color: .secondary)
                            }
                            Spacer()
                            if discovery.resolving == result {
                                ProgressView().controlSize(.small)
                            }
                            Button("Connect") { connect(discovered: result) }
                                .disabled(discovery.resolving != nil)
                        }
                    }
                }
            } header: {
                Label("Nearby", systemImage: Symbols.bonjour)
            } footer: {
                HStack {
                    Text("Discovery is only a shortcut: you still verify the Host's fingerprint, and the Host still has to approve (unless it allows password access and you enter its password).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }

            Section {
                Toggle(isOn: $autoReconnect) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reconnect automatically after a dropout")
                        Text("If the network drops, the last picture stays on screen and SwiftDesk redials the same Host for up to a minute, checking its identity again. A Host that allows it lets you back in without asking.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $sharesClipboard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share clipboard")
                        Text("Copy here, click into the remote screen and paste — and what you copy on the Host lands on this Mac's clipboard. Text, rich text, images and links; items from password managers are never shared. The Host can turn this off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if sharesClipboard,
                   let hint = ClipboardPresentation.accessHint(viewer.pasteboardAccess,
                                                               denied: viewer.clipboardStatus.accessDenied) {
                    PasteboardAccessHint(message: hint, blocked: viewer.pasteboardAccess == .alwaysDeny
                                         || viewer.clipboardStatus.accessDenied)
                }
                Toggle(isOn: $showsRemotePointer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the Host's pointer shape")
                        Text("While you control the Host, your pointer takes the shape of the Host's — text cursor, resize arrows, pointing hand, an app's own cursor, or hidden. It still moves instantly because it is drawn on this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $sendsSystemShortcuts) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send system shortcuts to the remote Mac")
                        Text(ShortcutPresentation.settingsCaption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if sendsSystemShortcuts, let hint = ShortcutPresentation.permissionHint(viewer.systemShortcutStatus) {
                    ShortcutPermissionHint(message: hint, request: viewer.requestShortcutPermission,
                                           openSettings: viewer.openShortcutPermissionSettings)
                }
                if viewer.addressBook != nil {
                    Toggle(isOn: $savesThumbnails) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save thumbnails of remote screens")
                            Text(AddressBookPresentation.thumbnailsCaption)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Text("Recent connections and their pictures")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            confirmingClearHistory = true
                        } label: {
                            Label("Clear History…", systemImage: Symbols.clearHistory)
                        }
                        .disabled(!hasHistory)
                    }
                }
            } header: {
                Label("Connection", systemImage: Symbols.reconnect)
            }

            Section {
                LabeledContent("Name", value: viewer.deviceName)
                LabeledContent("Identity") { FingerprintText(display: viewer.fingerprintDisplay) }
            } header: {
                Text("This Mac")
            } footer: {
                HStack {
                    Text("The Host sees this fingerprint in its approval prompt.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewer.refreshTrustedHosts()
            viewer.refreshSavedHosts()
            viewer.refreshPasteboardAccess()
            if sendsSystemShortcuts { viewer.refreshShortcutPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The paste-privacy and Accessibility settings are changed in System Settings; re-read them when the
            // user comes back.
            viewer.refreshPasteboardAccess()
            if sendsSystemShortcuts { viewer.refreshShortcutPermission() }
        }
        .confirmationDialog("Remove “\(pendingRemoval?.name ?? "")” from Trusted Hosts?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { trusted in
            Button("Remove", role: .destructive) { viewer.forgetTrustedHost(key: trusted.key) }
        } message: { _ in
            Text("The next connection to this address asks you to verify its fingerprint again.")
        }
        .confirmationDialog("Clear connection history?", isPresented: $confirmingClearHistory) {
            Button("Clear History", role: .destructive) { viewer.clearHistory() }
        } message: {
            Text(AddressBookPresentation.clearHistoryMessage)
        }
        .alert("Rename “\(renaming?.displayName ?? "")”", isPresented: Binding(get: { renaming != nil },
                                                                                set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming { viewer.renameSavedHost(id: renaming.id, to: renameText) }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Only on this Mac. Leave it empty to use the name the Host reports (“\(renaming?.hostName ?? "")”).")
        }
    }

    /// Recent entries or any saved picture exist (what Clear History removes).
    private var hasHistory: Bool {
        viewer.savedHosts.contains { !$0.isFavorite || $0.hasThumbnail || $0.lastConnectedAt != nil }
    }

    private func beginRename(_ entry: SavedHost) {
        renameText = entry.customName ?? entry.hostName
        renaming = entry
    }

    /// A saved Host's card (or one of its addresses from "Connect Via").
    private func connect(saved entry: SavedHost, address: SavedHostAddress?) {
        guard let address = address ?? entry.primaryAddress else { return }
        validationError = nil
        dial(ConnectTarget(host: address.host, port: address.port))
    }

    private func connect() {
        switch ConnectTarget.parse(host: hostText, port: portText) {
        case .success(let target):
            validationError = nil
            dial(target)
        case .failure(let error):
            validationError = error.description
        }
    }

    private func connect(key: String) {
        // Keys are "host:port" as produced by TrustedHostStore.key(host:port:).
        guard case .success(let target) = ConnectTarget.parse(host: key) else {
            validationError = "This saved entry is not a valid address."
            return
        }
        dial(target)
    }

    private func connect(discovered result: BonjourBrowser.Result) {
        Task {
            if let target = await discovery.resolve(result) {
                dial(target)
            } else {
                validationError = "Could not resolve “\(result.name)”. Try its IP address instead."
            }
        }
    }

    private func dial(_ target: ConnectTarget) {
        hostText = target.host
        portText = String(target.port)
        lastTarget = target
        let password = passwordText
        passwordText = ""
        viewer.connect(host: target.host, port: target.port, password: password.isEmpty ? nil : password,
                       rememberPassword: rememberPassword)
    }
}

private struct TrustedHostRow: View {
    let trusted: TrustedHost
    let hasSavedPassword: Bool
    let connect: () -> Void
    let forgetPassword: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Symbols.trusted).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(trusted.name)
                HStack(spacing: 6) {
                    Text(trusted.key).font(.system(.caption, design: .monospaced))
                    if let fingerprint = trusted.fingerprint {
                        Text(DeviceIdentity.display(fingerprint)).font(.system(.caption, design: .monospaced))
                    }
                    if hasSavedPassword {
                        Label("Password saved", systemImage: Symbols.password)
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if hasSavedPassword {
                Button("Forget Saved Password", action: forgetPassword)
                    .controlSize(.small)
                    .help("Delete the password saved in the keychain for this Host")
            }
            Button("Connect", action: connect)
            Button(role: .destructive, action: remove) {
                Image(systemName: Symbols.trash)
            }
            .buttonStyle(.borderless)
            .help("Remove from Trusted Hosts")
        }
    }
}

/// Why the last session ended. An identity change gets its own treatment: it may mean impersonation, so it is
/// never resolved automatically — the user must deliberately forget the pinned fingerprint.
private struct NoticeView: View {
    let notice: ViewerNotice
    let lastTarget: ConnectTarget?
    let viewer: ViewerSession

    var body: some View {
        switch notice.kind {
        case .info:
            NoticeBanner(symbol: Symbols.disconnect, message: notice.message, color: .secondary)
        case .problem:
            NoticeBanner(symbol: Symbols.warning, message: notice.message, color: .orange)
        case .incorrectPassword:
            NoticeBanner(symbol: Symbols.password,
                         message: "\(notice.message). Type it again and connect, or leave it empty to ask the Host for approval.",
                         color: .orange)
        case .identityChanged:
            VStack(alignment: .leading, spacing: 8) {
                NoticeBanner(symbol: Symbols.identityChanged, message: notice.message, color: .red)
                if let lastTarget,
                   viewer.trustStore.entry(host: lastTarget.host, port: lastTarget.port) != nil {
                    Text("Only continue if you know why the Host's identity changed (for example, it was reinstalled). Otherwise someone may be impersonating it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Forget Saved Fingerprint for \(lastTarget.displayString)", role: .destructive) {
                        viewer.forgetTrustedHost(key: TrustedHostStore.key(host: lastTarget.host, port: lastTarget.port))
                    }
                }
            }
        }
    }
}

// MARK: - Verification sheet

/// What the verification sheet shows, decoupled from `ViewerSession.HostVerification` so the sheet can be built
/// and tested without a live connection.
struct HostIdentityPrompt: Equatable {
    var host: String
    var port: UInt16
    var fingerprintDisplay: String
    var fingerprintDisplayFull: String
    var firstTime: Bool

    init(host: String, port: UInt16, fingerprintDisplay: String, fingerprintDisplayFull: String, firstTime: Bool) {
        self.host = host
        self.port = port
        self.fingerprintDisplay = fingerprintDisplay
        self.fingerprintDisplayFull = fingerprintDisplayFull
        self.firstTime = firstTime
    }

    init(_ verification: ViewerSession.HostVerification) {
        self.init(host: verification.host, port: verification.port, fingerprintDisplay: verification.fingerprintDisplay,
                  fingerprintDisplayFull: verification.fingerprintDisplayFull, firstTime: verification.firstTime)
    }
}

/// First connection to an address: the user compares the Host's fingerprint with the one on the Host's screen
/// before anything (even HELLO with this Mac's name) is sent.
struct HostVerificationSheet: View {
    let prompt: HostIdentityPrompt
    let trust: (Bool) -> Void
    let cancel: () -> Void
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: prompt.firstTime ? Symbols.untrusted : Symbols.trusted)
                    .font(.system(size: 28))
                    .foregroundStyle(prompt.firstTime ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify the Host's identity")
                        .font(.title3.weight(.semibold))
                    Text(ConnectTarget.endpointString(host: prompt.host, port: prompt.port))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Text("On the Host, open SwiftDesk → Share this Mac and look at “Identity” under This Mac. Continue only if it matches exactly.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Text(prompt.fingerprintDisplay)
                    .font(.system(.title2, design: .monospaced).weight(.medium))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                DisclosureGroup("Full fingerprint (SHA-256)") {
                    Text(prompt.fingerprintDisplayFull)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !prompt.firstTime {
                NoticeBanner(symbol: Symbols.trusted,
                             message: "You already trust this identity under another address (for example its LAN address vs. its Tailscale address).",
                             color: .green)
            }

            Toggle("Remember this Host (pin its fingerprint for this address)", isOn: $remember)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Trust & Connect") { trust(remember) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
