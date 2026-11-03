import AppKit
import SessionCore
import SwiftUI

/// Menu-bar status item label. While this Mac is shared it is a red, non-template symbol (template images are
/// tinted monochrome by the menu bar, which would hide the warning colour); orange while a request is waiting.
///
/// The label is the one SwiftUI view that exists for the whole process, even with every window closed, so it also
/// reopens the main window when a connection request arrives — an approval prompt must never be invisible.
struct SharingMenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.menuBarStatus
        Image(nsImage: MenuBarImage.image(for: status))
            .accessibilityLabel(status.title)
            .onChange(of: model.host?.pendingRequest?.id) { _, id in
                guard id != nil else { return }
                openWindow(id: SwiftDeskScenes.mainWindowID)
                NSApp.activate()
            }
            .onChange(of: model.passwordSessionID) { _, id in
                // A password session needs no click on this Mac, so make it visible: the window (with its red
                // banner and Stop Sharing) opens, without stealing focus from the person using the Mac.
                guard id != nil else { return }
                openWindow(id: SwiftDeskScenes.mainWindowID)
            }
    }
}

/// Builds the status-item image for a `MenuBarStatus`.
enum MenuBarImage {
    @MainActor
    static func image(for status: MenuBarStatus) -> NSImage {
        let base = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.title)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let sized = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? base
        switch status.tone {
        case .neutral:
            sized.isTemplate = true
            return sized
        case .attention, .sharing:
            let color: NSColor = status.tone == .sharing ? .systemRed : .systemOrange
            let tinted = sized.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? sized
            tinted.isTemplate = false
            return tinted
        }
    }
}

/// The menu-bar panel: always-available status and the controls to end any session (PRD §4: "The Host must
/// always have a visible way to revoke access").
struct SharingMenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.menuBarStatus
        VStack(alignment: .leading, spacing: 12) {
            header(status)

            if let host = model.host {
                if host.isSharing {
                    Button(role: .destructive) {
                        host.stopSharing()
                    } label: {
                        Label("Stop Sharing", systemImage: Symbols.stop)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                } else if host.pendingRequest != nil {
                    Button {
                        showMainWindow(role: .host)
                    } label: {
                        Text("Review Request…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if host.state != .idle {
                    Button("Stop Listening", action: host.stopListening)
                }
                if host.isSharing {
                    // The Host's live clipboard switch, reachable without opening the window.
                    Toggle(isOn: $model.hostAllowsClipboardSharing) {
                        Label("Allow Clipboard Sharing", systemImage: Symbols.clipboard)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(host.activePeer.map { ClipboardPresentation.status(host.clipboardStatus, peerName: $0.name) } ?? "")
                    Toggle(isOn: $model.hostSharesPointerShape) {
                        Label("Show Pointer Shape", systemImage: Symbols.pointer)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(PointerPresentation.hostCaption(host.cursorShapeStatus, peerName: host.activePeer?.name))
                }
            }

            if let viewer = model.viewer, viewer.isPresentingStream {
                Button {
                    viewer.disconnect()
                } label: {
                    Label("Disconnect from Remote Mac", systemImage: Symbols.disconnect)
                }
                Toggle(isOn: $model.viewerSharesClipboard) {
                    Label("Share Clipboard", systemImage: Symbols.clipboard)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                // System shortcuts (0.1.7): reachable while the stream window is behind other windows.
                Menu {
                    SendKeysMenuItems(send: { model.send($0) })
                } label: {
                    Label("Send Keys to Remote Mac", systemImage: Symbols.sendKeys)
                }
                .disabled(!viewer.isStreaming)
                Toggle(isOn: $model.viewerSendsSystemShortcuts) {
                    Label("Send System Shortcuts", systemImage: Symbols.keyboard)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(ShortcutPresentation.status(viewer.systemShortcutStatus, hostName: "the remote Mac"))
            }

            if model.canQuickConnect {
                // Address book (0.1.8): connect to a favorite or recent Host without opening the window first.
                Menu {
                    QuickConnectMenuItems(model: model)
                } label: {
                    Label("Connect To", systemImage: Symbols.controlMac)
                }
            }

            Divider()

            HStack {
                Button("Open SwiftDesk") { showMainWindow(role: nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private func header(_ status: MenuBarStatus) -> some View {
        let color: Color = switch status.tone {
        case .sharing: .red
        case .attention: .orange
        case .neutral: .secondary
        }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.symbol)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let peer = model.host?.activePeer {
                    Text(peer.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(status.tone == .sharing ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.tone == .sharing ? Color.red.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func showMainWindow(role: AppRole?) {
        if let role { model.selectedRole = role }
        openWindow(id: SwiftDeskScenes.mainWindowID)
        NSApp.activate()
    }
}
