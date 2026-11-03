import AppKit
import RenderCore
import SessionCore
import SwiftUI
import WireProtocol

/// Everything the app target needs: the main window, the menu-bar sharing indicator and the Session menu.
///
/// The main window is a single-instance `Window`, not a `WindowGroup`: each session drives exactly one render view,
/// and a second window would silently steal the video and input capture from the first.
public struct SwiftDeskScenes: Scene {
    public static let mainWindowID = "main"

    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        Window("SwiftDesk", id: Self.mainWindowID) {
            RootView(model: model)
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SessionCommands(model: model)
        }

        MenuBarExtra {
            SharingMenuContent(model: model)
        } label: {
            SharingMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// View › Actual Size (⌘0) and the "Session" menu: keyboard routes to end a session from anywhere in the app.
///
/// While the Viewer captures input, key equivalents go to the remote Mac (that is what capture means), so these
/// shortcuts work after releasing capture with ⌃⌥⎋ — the release shortcut itself is handled by the input layer.
struct SessionCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            // While input is captured, ⌘0 goes to the remote Mac like every other key equivalent; release capture
            // (⌃⌥⎋) or use the toolbar's 1:1 button.
            Button("Actual Size") {
                NotificationCenter.default.post(name: ViewerWindowSizer.actualSizeNotification, object: nil)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(!model.isViewerStreaming)
            Divider()
        }
        CommandMenu("Session") {
            Button("Stop Sharing") { model.host?.stopSharing() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isHostSharing)
            Button("Stop Listening") { model.host?.stopListening() }
                .disabled(model.host.map { $0.state == .idle } ?? true)
            Divider()
            // Address book (0.1.8): Favorites and recent Hosts, one click away from anywhere in the app.
            Menu("Connect To") {
                QuickConnectMenuItems(model: model)
            }
            .disabled(!model.canQuickConnect)
            Button("Disconnect") { model.viewer?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.isViewerStreaming)
            Button("Release Keyboard and Mouse (\(ViewerSession.releaseShortcutDescription))") {
                model.viewer?.isCapturingInput = false
            }
            .disabled(!(model.viewer?.isCapturingInput ?? false))
            // System shortcuts (0.1.7): press one on the remote Mac, and the live, persisted capture switch.
            Menu("Send Keys to Remote Mac") {
                SendKeysMenuItems(send: { model.send($0) })
            }
            .disabled(!(model.viewer?.isStreaming ?? false))
            Toggle("Send System Shortcuts to Remote Mac", isOn: $model.viewerSendsSystemShortcuts)
            Divider()
            // Clipboard switches (0.1.5), live during a session and persisted.
            Toggle("Allow Clipboard Sharing on This Mac", isOn: $model.hostAllowsClipboardSharing)
            Toggle("Share Clipboard with Remote Mac", isOn: $model.viewerSharesClipboard)
            Divider()
            // Pointer-shape switches (0.1.6), live and persisted.
            Toggle("Show This Mac’s Pointer Shape to the Viewer", isOn: $model.hostSharesPointerShape)
            Toggle("Show the Remote Mac’s Pointer Shape", isOn: $model.viewerShowsRemotePointer)
        }
    }
}

/// Owns the `AppModel` for the process and ends sessions cleanly on quit (DISCONNECT, held keys released, capture
/// stopped) before allowing termination, bounded so quitting can never hang.
@MainActor
public final class SwiftDeskAppDelegate: NSObject, NSApplicationDelegate {
    public let model = AppModel(addressBook: AddressBookStore.standard())

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        model.applyLaunchPreferences()
    }

    /// Open at Login (0.1.9) can be changed in System Settings › General › Login Items; re-read it on coming back.
    public func applicationDidBecomeActive(_ notification: Notification) {
        model.loginItem.refresh()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasLiveSessions else { return .terminateNow }
        // A stray ⌘Q in the stream window (no longer sent to the Host unless system shortcuts are) must not end the
        // session silently. The Quit menu item, the Dock and log-out quit at once.
        let quitKey = NSApp.currentEvent.map(RemoteDisplayView.isQuitShortcut) ?? false
        if let viewer = model.viewer,
           QuitPresentation.asksFirst(presentingStream: viewer.isPresentingStream, triggeredByQuitKey: quitKey) {
            let alert = NSAlert()
            alert.messageText = QuitPresentation.title
            alert.informativeText = QuitPresentation.message(viewer.state)
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        let model = self.model
        Task { @MainActor in
            await model.shutdown(timeout: .seconds(2))
            // Give the transport a moment to flush DISCONNECT before the process exits.
            try? await Task.sleep(for: .milliseconds(150))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Hosting continues from the menu bar after the window closes, so closing the last window must not quit.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Favorites, then recent Hosts, as menu items (Session › Connect To, menu-bar panel). Choosing one shows the Viewer
/// screen and connects like a click on its card.
struct QuickConnectMenuItems: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let hosts = model.quickConnectHosts()
        let all = hosts.favorites + hosts.recent
        if !hosts.favorites.isEmpty {
            Section("Favorites") {
                ForEach(hosts.favorites) { item($0, among: all) }
            }
        }
        if !hosts.recent.isEmpty {
            Section("Recent") {
                ForEach(hosts.recent) { item($0, among: all) }
            }
        }
    }

    private func item(_ entry: SavedHost, among all: [SavedHost]) -> some View {
        Button(AddressBookPresentation.menuTitle(entry, among: all, defaultPort: WireConstants.defaultPort)) {
            // A Viewer that could not be created (keychain) shows why on its screen.
            guard model.connect(to: entry) || model.viewerSetupError != nil else { return }
            openWindow(id: SwiftDeskScenes.mainWindowID)
            NSApp.activate()
        }
    }
}
