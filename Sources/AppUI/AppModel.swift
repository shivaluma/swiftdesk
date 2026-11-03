import AppKit
import DiagnosticsCore
import Foundation
import InputCore
import Observation
import SessionCore

/// App-wide owner of the three session objects and of process-level policy (power assertions, quit handling).
///
/// Why sessions are created lazily: `HostSession.makeDefault()` / `ViewerSession.makeDefault()` load or create the
/// device identity in the login keychain. Doing that at launch would put a keychain prompt (common for ad-hoc
/// signed builds whose code signature changes on every build) in front of a user who only wanted to run the
/// loopback test. Each role's session is created the first time its screen is shown and then lives for the whole
/// process, so hosting keeps running (with its menu-bar indicator) while the user looks at another screen or closes
/// the window.
@MainActor
@Observable
public final class AppModel {
    /// The role screen shown in the main window (`nil` shows the role picker).
    public var selectedRole: AppRole?

    public private(set) var host: HostSession?
    public private(set) var viewer: ViewerSession?
    public let loopback: LoopbackSession

    /// Why a session could not be created (keychain identity failure). Shown instead of the role screen.
    public private(set) var hostSetupError: String?
    public private(set) var viewerSetupError: String?

    /// UserDefaults key of "Start listening when SwiftDesk opens".
    public static let startListeningAtLaunchKey = "SwiftDesk.host.startListeningAtLaunch"

    /// "Start listening when SwiftDesk opens" (default off). Applied by `applyLaunchPreferences()`. Opening SwiftDesk
    /// itself at login is the separate `loginItem` switch (0.1.9).
    public var startListeningAtLaunch: Bool {
        didSet {
            guard startListeningAtLaunch != oldValue else { return }
            defaults.set(startListeningAtLaunch, forKey: Self.startListeningAtLaunchKey)
        }
    }

    /// UserDefaults key of the Host's picture quality (`StreamQuality.rawValue`).
    public static let hostStreamQualityKey = "SwiftDesk.host.streamQuality"

    /// Host › Display › Quality (default Sharp). Applies to the next session; pushed to the Host session.
    public var hostStreamQuality: StreamQuality {
        didSet {
            guard hostStreamQuality != oldValue else { return }
            defaults.set(hostStreamQuality.rawValue, forKey: Self.hostStreamQualityKey)
            host?.streamQuality = hostStreamQuality
        }
    }

    /// UserDefaults key of "Let an allowed Viewer reconnect without asking" (Host, default on).
    public static let hostReconnectWithoutPromptKey = "SwiftDesk.host.reconnectWithoutPrompt"

    /// Host › Connection: a Viewer whose allowed session dropped may come back within 2 minutes without a new prompt
    /// (`HostSession.allowsReconnectWithoutPrompt`). Default on; pushed to the Host session.
    public var hostAllowsReconnectWithoutPrompt: Bool {
        didSet {
            guard hostAllowsReconnectWithoutPrompt != oldValue else { return }
            defaults.set(hostAllowsReconnectWithoutPrompt, forKey: Self.hostReconnectWithoutPromptKey)
            host?.allowsReconnectWithoutPrompt = hostAllowsReconnectWithoutPrompt
        }
    }

    /// UserDefaults key of "Reconnect automatically after a dropout" (Viewer, default on).
    public static let viewerAutoReconnectKey = "SwiftDesk.viewer.autoReconnect"

    /// Viewer › Connection: redial the same Host for up to a minute when a session's connection fails
    /// (`ViewerSession.autoReconnect`). Default on; pushed to the Viewer session.
    public var viewerAutoReconnect: Bool {
        didSet {
            guard viewerAutoReconnect != oldValue else { return }
            defaults.set(viewerAutoReconnect, forKey: Self.viewerAutoReconnectKey)
            viewer?.autoReconnect = viewerAutoReconnect
        }
    }

    /// UserDefaults key of "Allow clipboard sharing" (Host, default on).
    public static let hostAllowClipboardSharingKey = "SwiftDesk.host.allowClipboardSharing"

    /// Host › Clipboard (0.1.5): text, rich text, images and links copied on either Mac during a session reach the
    /// other (`HostSession.allowsClipboardSharing`). Default on; live during a session; pushed to the Host session.
    public var hostAllowsClipboardSharing: Bool {
        didSet {
            guard hostAllowsClipboardSharing != oldValue else { return }
            defaults.set(hostAllowsClipboardSharing, forKey: Self.hostAllowClipboardSharingKey)
            host?.allowsClipboardSharing = hostAllowsClipboardSharing
        }
    }

    /// UserDefaults key of "Share clipboard" (Viewer, default on).
    public static let viewerShareClipboardKey = "SwiftDesk.viewer.shareClipboard"

    /// Viewer › Connection and the stream toolbar (0.1.5): sync clipboards with the Host
    /// (`ViewerSession.sharesClipboard`). Default on; live during a session; pushed to the Viewer session.
    public var viewerSharesClipboard: Bool {
        didSet {
            guard viewerSharesClipboard != oldValue else { return }
            defaults.set(viewerSharesClipboard, forKey: Self.viewerShareClipboardKey)
            viewer?.sharesClipboard = viewerSharesClipboard
        }
    }

    /// UserDefaults key of "Show my pointer shape to the Viewer" (Host, default on).
    public static let hostSharePointerShapeKey = "SwiftDesk.host.sharePointerShape"

    /// Host › Display (0.1.6): the Viewer draws its pointer in this Mac's current pointer shape (I-beam, resize arrows,
    /// hidden …) (`HostSession.sharesPointerShape`). Default on; live during a session; pushed to the Host session.
    public var hostSharesPointerShape: Bool {
        didSet {
            guard hostSharesPointerShape != oldValue else { return }
            defaults.set(hostSharesPointerShape, forKey: Self.hostSharePointerShapeKey)
            host?.sharesPointerShape = hostSharesPointerShape
        }
    }

    /// UserDefaults key of "Show the Host's pointer shape" (Viewer, default on).
    public static let viewerShowRemotePointerKey = "SwiftDesk.viewer.showRemotePointer"

    /// Viewer › Connection (0.1.6): draw the local pointer in the Host pointer's shape while controlling
    /// (`ViewerSession.showsRemotePointer`). Default on; live; pushed to the Viewer session.
    public var viewerShowsRemotePointer: Bool {
        didSet {
            guard viewerShowsRemotePointer != oldValue else { return }
            defaults.set(viewerShowsRemotePointer, forKey: Self.viewerShowRemotePointerKey)
            viewer?.showsRemotePointer = viewerShowsRemotePointer
        }
    }

    /// UserDefaults key of "Send system shortcuts to the remote Mac" (Viewer, default off).
    public static let viewerSendSystemShortcutsKey = "SwiftDesk.viewer.sendSystemShortcuts"

    /// Viewer › Connection and the stream toolbar's Send Keys menu (0.1.7): while controlling, ⌘Tab, ⌘Space, Mission
    /// Control, screenshots … go to the Host instead of this Mac (`ViewerSession.sendsSystemShortcuts`; needs
    /// Accessibility on this Mac). Default off; live; pushed to the Viewer session.
    public var viewerSendsSystemShortcuts: Bool {
        didSet {
            guard viewerSendsSystemShortcuts != oldValue else { return }
            defaults.set(viewerSendsSystemShortcuts, forKey: Self.viewerSendSystemShortcutsKey)
            viewer?.sendsSystemShortcuts = viewerSendsSystemShortcuts
        }
    }

    /// UserDefaults key of "Save thumbnails of remote screens" (Viewer, default on).
    public static let viewerSaveThumbnailsKey = "SwiftDesk.viewer.saveThumbnails"

    /// Viewer › Recent (0.1.8): when a session ends, a ≈ 320 px picture of the last frame is kept with the Host's
    /// address-book entry (`ViewerSession.savesThumbnails`). Default on; off deletes the saved thumbnails; pushed to the
    /// Viewer session.
    public var viewerSavesThumbnails: Bool {
        didSet {
            guard viewerSavesThumbnails != oldValue else { return }
            defaults.set(viewerSavesThumbnails, forKey: Self.viewerSaveThumbnailsKey)
            viewer?.savesThumbnails = viewerSavesThumbnails
        }
    }

    /// Host › Startup › "Open at Login" (0.1.9): SwiftDesk as a login item (`SMAppService.mainApp`). Its truth is the
    /// system's status, refreshed at launch and whenever the app becomes active; the user's last choice is persisted
    /// under `LoginItemController.wantedKey`.
    public let loginItem: LoginItemController

    /// A Send Keys item waiting for the user to confirm it (Lock Screen); the main window shows the question.
    public var pendingShortcut: SystemShortcut?

    @ObservationIgnored private let makeHost: @MainActor () throws -> HostSession
    @ObservationIgnored private let makeViewer: @MainActor () throws -> ViewerSession
    @ObservationIgnored private var activityToken: (any NSObjectProtocol)?
    @ObservationIgnored private var activityOptions: ProcessInfo.ActivityOptions?
    @ObservationIgnored private var lastAttentionRequestID: UUID?
    @ObservationIgnored private var lastPasswordSessionID: UInt32?
    @ObservationIgnored private let defaults: UserDefaults
    /// The address book read for the quick-connect menus before the Viewer session exists (a file read, no keychain);
    /// once it exists, its own `savedHosts` are used. nil: no menus until then (tests).
    @ObservationIgnored private let addressBook: AddressBookStore?

    /// - Parameters: factories are injectable so tests can run without the keychain; `loginItemService` so they never
    ///   touch the real Login Items.
    public init(makeHost: @escaping @MainActor () throws -> HostSession = { try HostSession.makeDefault() },
                makeViewer: @escaping @MainActor () throws -> ViewerSession = { try ViewerSession.makeDefault() },
                loopback: LoopbackSession = LoopbackSession(),
                defaults: UserDefaults = .standard,
                loginItemService: any LoginItemService = SystemLoginItemService(),
                addressBook: AddressBookStore? = nil) {
        self.makeHost = makeHost
        self.addressBook = addressBook
        self.makeViewer = makeViewer
        self.loopback = loopback
        self.defaults = defaults
        self.loginItem = LoginItemController(service: loginItemService, defaults: defaults)
        self.startListeningAtLaunch = defaults.bool(forKey: Self.startListeningAtLaunchKey)
        self.hostStreamQuality = defaults.string(forKey: Self.hostStreamQualityKey).flatMap(StreamQuality.init(rawValue:))
            ?? .sharp
        self.hostAllowsReconnectWithoutPrompt = defaults.object(forKey: Self.hostReconnectWithoutPromptKey) as? Bool ?? true
        self.viewerAutoReconnect = defaults.object(forKey: Self.viewerAutoReconnectKey) as? Bool ?? true
        self.hostAllowsClipboardSharing = defaults.object(forKey: Self.hostAllowClipboardSharingKey) as? Bool ?? true
        self.viewerSharesClipboard = defaults.object(forKey: Self.viewerShareClipboardKey) as? Bool ?? true
        self.hostSharesPointerShape = defaults.object(forKey: Self.hostSharePointerShapeKey) as? Bool ?? true
        self.viewerShowsRemotePointer = defaults.object(forKey: Self.viewerShowRemotePointerKey) as? Bool ?? true
        self.viewerSendsSystemShortcuts = defaults.bool(forKey: Self.viewerSendSystemShortcutsKey)
        self.viewerSavesThumbnails = defaults.object(forKey: Self.viewerSaveThumbnailsKey) as? Bool ?? true
        observeSessions()
    }

    /// Called once at launch: with "Start listening when SwiftDesk opens" on, the Host session is created (keychain
    /// identity) and starts listening, so an unattended Mac only needs SwiftDesk running.
    public func applyLaunchPreferences() {
        guard startListeningAtLaunch, let host = ensureHost() else { return }
        if selectedRole == nil { selectedRole = .host }
        host.startListening()
    }

    // MARK: Session creation

    /// Creates the session behind `role` if needed. Cheap after the first call.
    public func prepare(_ role: AppRole) {
        switch role {
        case .host: _ = ensureHost()
        case .viewer: _ = ensureViewer()
        case .loopback: break
        }
    }

    @discardableResult
    public func ensureHost() -> HostSession? {
        if let host { return host }
        do {
            let session = try makeHost()
            session.streamQuality = hostStreamQuality
            session.allowsReconnectWithoutPrompt = hostAllowsReconnectWithoutPrompt
            session.allowsClipboardSharing = hostAllowsClipboardSharing
            session.sharesPointerShape = hostSharesPointerShape
            host = session
            hostSetupError = nil
            return session
        } catch {
            hostSetupError = "Could not load this Mac's identity from the keychain: \(error)"
            Log.session.error("Host session setup failed")
            return nil
        }
    }

    @discardableResult
    public func ensureViewer() -> ViewerSession? {
        if let viewer { return viewer }
        do {
            let session = try makeViewer()
            session.autoReconnect = viewerAutoReconnect
            session.sharesClipboard = viewerSharesClipboard
            session.showsRemotePointer = viewerShowsRemotePointer
            session.sendsSystemShortcuts = viewerSendsSystemShortcuts
            session.savesThumbnails = viewerSavesThumbnails
            viewer = session
            viewerSetupError = nil
            return session
        } catch {
            viewerSetupError = "Could not load this Mac's identity from the keychain: \(error)"
            Log.session.error("Viewer session setup failed")
            return nil
        }
    }

    public func retrySetup(_ role: AppRole) {
        switch role {
        case .host: hostSetupError = nil
        case .viewer: viewerSetupError = nil
        case .loopback: break
        }
        prepare(role)
    }

    // MARK: Derived state

    public var isHostSharing: Bool { host?.isSharing ?? false }
    /// Streaming, or reconnecting with the stream window still up (0.1.4).
    public var isViewerStreaming: Bool { viewer?.isPresentingStream ?? false }
    public var isLoopbackRunning: Bool {
        switch loopback.state {
        case .starting, .running: true
        case .idle, .failed: false
        }
    }

    public var menuBarStatus: MenuBarStatus {
        var streamingHost: String?
        var reconnecting = false
        switch viewer?.state {
        case .streaming(let info)?: streamingHost = info.hostName
        case .reconnecting(let status)?:
            streamingHost = status.stream.hostName
            reconnecting = true
        default: break
        }
        return MenuBarStatus.make(hostState: host?.state, viewerStreamingHost: streamingHost,
                                  passwordAccess: host?.passwordAccessEnabled ?? false,
                                  viewerReconnecting: reconnecting, peerSilent: host?.isPeerSilent ?? false)
    }

    /// True if quitting must first end sessions cleanly (DISCONNECT, release held input, stop capture).
    public var hasLiveSessions: Bool {
        let hostLive = host.map { $0.state != .idle } ?? false
        let viewerLive: Bool = switch viewer?.state {
        case .none, .idle?, .disconnected?: false
        default: true
        }
        return hostLive || viewerLive || isLoopbackRunning
    }

    // MARK: Actions

    /// A Send Keys menu item (toolbar, Session menu, menu-bar panel): pressed on the Host at once, or — for
    /// `needsConfirmation` items (Lock Screen) — after the user confirms `pendingShortcut`.
    public func send(_ shortcut: SystemShortcut) {
        guard viewer?.isStreaming == true else { return }
        if shortcut.needsConfirmation {
            pendingShortcut = shortcut
        } else {
            viewer?.send(shortcut)
        }
    }

    /// Connects to a saved Host (address book, 0.1.8) at `address` (default: the one used last) and shows the Viewer
    /// screen. An ordinary `connect`: the address's pin applies, else the user verifies the fingerprint. Creates the
    /// Viewer session (keychain identity) if needed. False if the Viewer is busy with another session or could not be
    /// created (then the Viewer screen shows why).
    @discardableResult
    public func connect(to entry: SavedHost, address: SavedHostAddress? = nil) -> Bool {
        guard let target = address ?? entry.primaryAddress else { return false }
        guard let viewer = ensureViewer() else {
            selectedRole = .viewer
            return false
        }
        switch viewer.state {
        case .idle, .disconnected: break
        default: return false
        }
        selectedRole = .viewer
        viewer.connect(host: target.host, port: target.port)
        return true
    }

    /// There are saved Hosts and the Viewer is idle (or not created yet): the quick-connect menus are enabled. Works
    /// from launch, before "Control a Mac" was ever shown (review 0.2.0).
    public var canQuickConnect: Bool {
        if let viewer {
            switch viewer.state {
            case .idle, .disconnected: break
            default: return false
            }
        }
        return !savedHostsForMenus.isEmpty
    }

    /// Favorites, then the most recent others, for the quick-connect menus (Session menu, menu-bar panel).
    public func quickConnectHosts(recentLimit: Int = 8) -> (favorites: [SavedHost], recent: [SavedHost]) {
        let sections = SavedHostSections(savedHostsForMenus)
        return (sections.favorites, Array(sections.recent.prefix(recentLimit)))
    }

    /// The Viewer's live list once it exists, else the address book on disk.
    private var savedHostsForMenus: [SavedHost] {
        if let viewer { return viewer.savedHosts }
        return addressBook?.list() ?? []
    }

    /// The user confirmed `pendingShortcut`.
    public func confirmPendingShortcut() {
        guard let shortcut = pendingShortcut else { return }
        pendingShortcut = nil
        viewer?.send(shortcut)
    }

    /// Ends every session: the Host stops listening (DISCONNECT to the Viewer, input deauthorized, capture
    /// stopped), the Viewer disconnects (held keys released first), the loopback stops. Bounded by `timeout` so a
    /// wedged capture stream can never block quitting.
    public func shutdown(timeout: Duration = .seconds(2)) async {
        viewer?.disconnect()
        host?.stopListening()
        let host = self.host
        let loopback = self.loopback
        let viewer = self.viewer
        await Self.waitAtMost(timeout) {
            await loopback.stop()
            await host?.waitForTeardown()
            // The ended session's address-book thumbnail (encoded off the main actor, then written).
            await viewer?.waitForPendingThumbnail()
        }
        updateActivityAssertion()
    }

    /// Runs `work` but returns after `timeout` even if it has not finished.
    static func waitAtMost(_ timeout: Duration, _ work: @escaping @MainActor () async -> Void) async {
        let gate = OneShotGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.continuation = continuation
            Task { @MainActor in
                await work()
                gate.open()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.open()
            }
        }
    }

    // MARK: Process policy

    /// Re-evaluates the power assertion and operator attention whenever session state changes.
    /// Observation-driven (rare discrete events), never per frame.
    private func observeSessions() {
        withObservationTracking {
            _ = isHostSharing
            _ = isViewerStreaming
            _ = isLoopbackRunning
            _ = host?.pendingRequest?.id
            _ = host?.activePeer?.sessionId
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionStateChanged()
                self.observeSessions()
            }
        }
    }

    private func sessionStateChanged() {
        updateActivityAssertion()
        if let request = host?.pendingRequest, request.id != lastAttentionRequestID {
            lastAttentionRequestID = request.id
            // A connection request must never go unnoticed: bring SwiftDesk forward and bounce the Dock icon.
            selectedRole = selectedRole ?? .host
            NSApp?.activate()
            _ = NSApp?.requestUserAttention(.criticalRequest)
        }
        if let peer = host?.activePeer, peer.viaPassword, peer.sessionId != lastPasswordSessionID {
            lastPasswordSessionID = peer.sessionId
            // Nobody approved this session: show the Host screen with its red banner so anyone at this Mac sees
            // who is in control and can stop it. The menu-bar item opens the window (SharingMenuBarLabel).
            if !isViewerStreaming { selectedRole = .host }
            _ = NSApp?.requestUserAttention(.informationalRequest)
        }
    }

    /// A session that started with the access password, for the window-opening hook (nil otherwise).
    public var passwordSessionID: UInt32? {
        guard let peer = host?.activePeer, peer.viaPassword else { return nil }
        return peer.sessionId
    }

    func updateActivityAssertion() {
        let wanted = SessionActivityPolicy.options(hostSharing: isHostSharing, viewerStreaming: isViewerStreaming,
                                                   loopbackRunning: isLoopbackRunning)
        guard wanted != activityOptions else { return }
        if let activityToken { ProcessInfo.processInfo.endActivity(activityToken) }
        activityToken = nil
        activityOptions = wanted
        if let wanted {
            let reason = SessionActivityPolicy.reason(hostSharing: isHostSharing, viewerStreaming: isViewerStreaming,
                                                      loopbackRunning: isLoopbackRunning)
            activityToken = ProcessInfo.processInfo.beginActivity(options: wanted, reason: reason)
        }
    }

    /// The options of the assertion currently held (for tests and diagnostics).
    public var heldActivityOptions: ProcessInfo.ActivityOptions? { activityOptions }
}

/// Resumes a continuation exactly once, whichever of several racing tasks finishes first.
@MainActor
private final class OneShotGate {
    var continuation: CheckedContinuation<Void, Never>?

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
