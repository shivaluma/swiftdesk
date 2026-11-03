import AppKit
import InputCore
import SessionCore
import SwiftUI

/// Main window: a sidebar role picker (Share / Control / Loopback) and the selected role's screen.
///
/// Two security behaviours live here rather than in the role screens, so they apply whatever screen is showing:
/// the Host's approval sheet, and a red "Sharing this Mac" strip with Stop Sharing whenever this Mac is shared.
/// While streaming as a Viewer the sidebar collapses so the remote desktop fills the window.
public struct RootView: View {
    @Bindable var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    public init(model: AppModel) {
        self.model = model
    }

    static let streamingMinimum = CGSize(width: 480, height: 300)

    public var body: some View {
        VStack(spacing: 0) {
            if let peer = model.host?.activePeer, model.selectedRole != .host {
                SharingStrip(peer: peer,
                             stop: { model.host?.stopSharing() },
                             show: { model.selectedRole = .host })
            }
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List(selection: $model.selectedRole) {
                    Section("SwiftDesk") {
                        ForEach(AppRole.allCases) { role in
                            RoleRow(role: role, badge: badge(for: role))
                                .tag(role)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } detail: {
                detail
            }
        }
        // While streaming, the window may be smaller so a stream can be shown pixel for pixel (strict 1:1 via ⌘0:
        // 1600×900 on a Retina Viewer is 800×450 pt); the setup screens need the larger minimum.
        .frame(minWidth: model.isViewerStreaming ? Self.streamingMinimum.width : 860,
               minHeight: model.isViewerStreaming ? Self.streamingMinimum.height : 560)
        .sheet(item: approvalBinding) { request in
            ApprovalSheet(request: request,
                          timeout: model.host?.configuration.approvalTimeout ?? .seconds(60),
                          approve: { model.host?.approve() },
                          deny: { model.host?.deny() },
                          openAccessibilitySettings: { model.host?.openAccessibilitySettings() })
        }
        .confirmationDialog(model.pendingShortcut.map {
                                ShortcutPresentation.confirmationTitle($0, hostName: streamingHostName)
                            } ?? "",
                            isPresented: Binding(get: { model.pendingShortcut != nil },
                                                 set: { if !$0 { model.pendingShortcut = nil } }),
                            presenting: model.pendingShortcut) { shortcut in
            Button(shortcut.title) { model.confirmPendingShortcut() }
            Button("Cancel", role: .cancel) { model.pendingShortcut = nil }
        } message: { shortcut in
            Text(ShortcutPresentation.confirmationMessage(shortcut))
        }
        .onChange(of: model.selectedRole, initial: true) { _, role in
            if let role { model.prepare(role) }
        }
        .onChange(of: model.isViewerStreaming) { _, streaming in
            withAnimation { columnVisibility = streaming ? .detailOnly : .automatic }
        }
        .onDisappear {
            // Closing the window ends Viewer and loopback sessions (nothing should run unseen); hosting continues
            // and stays visible and revocable from the menu-bar item.
            model.viewer?.disconnect()
            Task { await model.loopback.stop() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedRole {
        case .none:
            RolePicker { model.selectedRole = $0 }
        case .host?:
            if let host = model.host {
                HostView(host: host, startListeningAtLaunch: $model.startListeningAtLaunch,
                         streamQuality: $model.hostStreamQuality,
                         allowsReconnectWithoutPrompt: $model.hostAllowsReconnectWithoutPrompt,
                         allowsClipboardSharing: $model.hostAllowsClipboardSharing,
                         sharesPointerShape: $model.hostSharesPointerShape,
                         loginItem: model.loginItem)
                    .navigationTitle(AppRole.host.title)
            } else {
                SetupStateView(error: model.hostSetupError) { model.retrySetup(.host) }
            }
        case .viewer?:
            if let viewer = model.viewer {
                ViewerView(viewer: viewer, autoReconnect: $model.viewerAutoReconnect,
                           sharesClipboard: $model.viewerSharesClipboard,
                           showsRemotePointer: $model.viewerShowsRemotePointer,
                           sendsSystemShortcuts: $model.viewerSendsSystemShortcuts,
                           savesThumbnails: $model.viewerSavesThumbnails,
                           sendShortcut: { model.send($0) })
                    .navigationTitle(AppRole.viewer.title)
            } else {
                SetupStateView(error: model.viewerSetupError) { model.retrySetup(.viewer) }
            }
        case .loopback?:
            LoopbackView(loopback: model.loopback)
                .navigationTitle(AppRole.loopback.title)
        }
    }

    /// The Host this Mac is controlling, for the Send Keys confirmation.
    private var streamingHostName: String {
        if case .streaming(let info)? = model.viewer?.state { return info.hostName }
        return "the remote Mac"
    }

    /// Shown while a request is pending; it can only be closed by Allow / Deny (or the Host's timeout).
    private var approvalBinding: Binding<ConnectionRequest?> {
        Binding(get: { model.host?.pendingRequest }, set: { _ in })
    }

    private func badge(for role: AppRole) -> RoleRow.Badge? {
        switch role {
        case .host:
            if model.isHostSharing { return .sharing }
            if model.host?.pendingRequest != nil { return .attention }
            if case .listening? = model.host?.state { return .listening }
            return nil
        case .viewer:
            return model.isViewerStreaming ? .active : nil
        case .loopback:
            return model.isLoopbackRunning ? .active : nil
        }
    }
}

private struct RoleRow: View {
    enum Badge { case listening, attention, sharing, active }

    let role: AppRole
    let badge: Badge?

    var body: some View {
        HStack {
            Label(role.title, systemImage: role.symbol)
            Spacer()
            switch badge {
            case .listening?: StatusDot(color: .green).help("Listening")
            case .attention?: StatusDot(color: .orange).help("Connection request waiting")
            case .sharing?: StatusDot(color: .red).help("Sharing this Mac")
            case .active?: StatusDot(color: .accentColor).help("Running")
            case nil: EmptyView()
            }
        }
    }
}

/// First-run landing page: the three roles as large, explained choices.
private struct RolePicker: View {
    let choose: (AppRole) -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("SwiftDesk")
                    .font(.largeTitle.weight(.semibold))
                Text("Low-latency remote control between your Macs.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(AppRole.allCases) { role in
                    Button { choose(role) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: role.symbol)
                                .font(.system(size: 30))
                                .foregroundStyle(Color.accentColor)
                            Text(role.title).font(.headline)
                            Text(role.subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .frame(width: 210, height: 170, alignment: .topLeading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Placeholder while a session is being created, or the keychain error if creating it failed.
private struct SetupStateView: View {
    let error: String?
    let retry: () -> Void

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label("Identity unavailable", systemImage: Symbols.identityChanged)
            } description: {
                Text(error)
            } actions: {
                Button("Try Again", action: retry)
            }
        } else {
            ProgressView("Loading this Mac's identity…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
