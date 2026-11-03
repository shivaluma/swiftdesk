import AppKit
import DiagnosticsCore
import Foundation
import InputCore
import Observation
import RenderCore
import TransportCore
import WireProtocol

/// The "Control a Mac" role: connects, verifies the Host's identity, waits for approval, then shows the stream and
/// forwards local input.
///
/// Trust (PRD §4 Viewer step 3, §7): a dialed address with a pinned fingerprint is enforced by TLS; a different
/// certificate ends the attempt with `ViewerHandshake.identityChangedMessage` and is never re-pinned silently.
/// Without a pin the session stops in `.verifyingHost` and sends nothing until `trustHost(remember:)`.
///
/// Password access (opt-in on the Host): `connect(host:port:password:rememberPassword:)` takes an optional password.
/// HELLO/AUTH announce `Auth.Capabilities.passwordAuth`; a PASSWORD_CHALLENGE (only possible after the Host was
/// verified) is answered with a proof derived off the main actor from the typed password or the one saved for this
/// Host's fingerprint, else with "no password" (the Host then prompts). If the Host then reports that it fell back to
/// its prompt (PASSWORD_RESPONSE none, e.g. the proof was too late), the proof is dropped and a later ACCEPT is an
/// ordinary approval. A password is saved only for a pinned Host after a password login worked; a saved password that
/// the Host rejects is deleted.
///
/// Input safety: input is forwarded only while streaming; focus loss, the local release shortcut (⌃⌥⎋), turning
/// capture off and disconnect all send key-up / button-up for everything held, so nothing stays stuck on the Host.
///
/// Dropouts (0.1.4): after 1 s with nothing from the Host, `isLinkStalled` turns on (the UI dims the last frame with
/// "Poor connection"); the QUIC connection itself survives up to 30 s of silence. If a streaming session's connection
/// does fail (and `autoReconnect` is on), the session enters `.reconnecting` instead of ending: the last frame stays,
/// and it redials the same address with back-off (`ReconnectBackoff`: 0.5, 1, 2, 4, 8 … s, no new attempt after 60 s),
/// pinned to the certificate fingerprint the session was verified with — a different certificate ends it with the
/// identity-changed error, never a prompt. The AUTH nonce announces `sessionResume`, so a Host whose grace allows it
/// lets the Viewer back without a new prompt; otherwise the Host prompts (or challenges, answered with the password
/// typed for the original connection or the saved one) as usual. Only connection failures and DENY(busy) are
/// retried; a DENY, DISCONNECT, identity change or `disconnect()` (the Cancel button) ends it.
///
/// Clipboard sharing (0.1.5): with a Host that announces `PeerCapabilities.clipboard`, both clipboards are synced
/// while `sharesClipboard` is on here and the Host's switch is on. This Mac's clipboard is read only while the stream
/// window is the key window (checked when it becomes key, and on a ≈ 4 Hz change-count poll while it stays key):
/// copy locally, click into the remote screen, paste. The Host's copies arrive on this Mac's clipboard at any time.
///
/// Pointer shape (0.1.6): with a Host that announces `PeerCapabilities.cursorShape`, the attached `RemoteDisplayView`
/// draws its local pointer in the Host pointer's current shape (I-beam, resize arrows, hidden …) while capturing input
/// and `showsRemotePointer` is on; otherwise, before the first shape and for older Hosts, the arrow.
///
/// System shortcuts (0.1.7): `send(_:)` presses one of the `SystemShortcut`s (⌘Tab, Spotlight, Mission Control,
/// screenshots, Force Quit, Lock Screen …) on the Host as ordinary KEY_DOWN / KEY_UP — nothing new on the wire, so it
/// works with every Host. With `sendsSystemShortcuts` on (default off) and Accessibility granted on this Mac, a
/// keyboard event tap (`SystemShortcutTap`) is installed while the user controls a streaming session in the focused
/// stream view, and takes every key event so that shortcuts this Mac would otherwise consume go to the Host; it is
/// removed as soon as any of that stops (capture off, ⌃⌥⎋, window resigns key, app deactivates, reconnect, end).
///
/// Address book (0.1.8): with an `AddressBookStore` (the app passes `AddressBookStore.standard()`; tests a temporary
/// folder or none), every successful connection is recorded in `savedHosts` (merged by the Host's certificate
/// fingerprint, recent list capped at 20) and, while `savesThumbnails` is on, the last decoded frame of the session is
/// saved as a ≈ 320 px JPEG when it ends. Entries are not pins: connecting from one is an ordinary `connect` (the
/// address's pin in `trustStore`, if any, applies). Local only; nothing new on the wire.
///
/// Threading: main actor for state and AppKit input (sent synchronously from the event handler — no hop). Datagrams,
/// reassembly, decode and rendering hand-off run on `ViewerMediaPipeline`'s receive queue; metrics arrive at 2 Hz.
@MainActor
@Observable
public final class ViewerSession {
    public enum State: Sendable, Equatable {
        case idle
        case connecting(host: String, port: UInt16)
        /// First connection to this address: the user must compare the fingerprint (shown on the Host) and decide.
        case verifyingHost(HostVerification)
        case awaitingApproval
        case streaming(StreamInfo)
        /// The streaming session's connection failed; redialing automatically (0.1.4). The last frame stays visible.
        case reconnecting(ReconnectStatus)
        case disconnected(reason: String)
    }

    /// Progress of an automatic reconnect, for the "Reconnecting…" overlay.
    public struct ReconnectStatus: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            /// Next attempt at this time (the UI counts down; `reconnectNow()` skips the wait).
            case waiting(nextAttemptAt: Date)
            /// Dialing (QUIC + mTLS, pinned to the session's Host certificate).
            case connecting
            /// Connected; waiting for the Host to accept (at once within its grace window, else after a prompt or
            /// the password check).
            case awaitingApproval
        }

        /// The session being resumed (its Host name, address and identity).
        public var stream: StreamInfo
        public var host: String
        public var port: UInt16
        public var phase: Phase
        /// Attempts started so far (0 while waiting for the first).
        public var attempt: Int
        /// Why the connection ended, e.g. "Connection lost: …".
        public var lostReason: String
        /// The latest failed attempt's reason, if any.
        public var lastError: String?
        public var startedAt: Date
        /// No attempt starts after this.
        public var deadline: Date
        /// The Host announced `sessionResume` on the lost session: it may let this Viewer back without asking.
        public var hostSupportsResume: Bool

        public init(stream: StreamInfo, host: String, port: UInt16, phase: Phase, attempt: Int, lostReason: String,
                    lastError: String?, startedAt: Date, deadline: Date, hostSupportsResume: Bool) {
            self.stream = stream
            self.host = host
            self.port = port
            self.phase = phase
            self.attempt = attempt
            self.lostReason = lostReason
            self.lastError = lastError
            self.startedAt = startedAt
            self.deadline = deadline
            self.hostSupportsResume = hostSupportsResume
        }
    }

    public struct HostVerification: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var fingerprint: Data
        /// First 16 bytes, as the Host shows it ("3F2A 9C01 …").
        public var fingerprintDisplay: String
        public var fingerprintDisplayFull: String
        /// False if this fingerprint is already trusted under another address (e.g. LAN vs Tailscale).
        public var firstTime: Bool
    }

    public struct StreamInfo: Sendable, Equatable {
        public var hostName: String
        public var remoteAddress: String
        public var sessionId: UInt32
        public var hostFingerprintDisplay: String
        /// True if this address is in the trusted-host store.
        public var isTrusted: Bool
        /// The Host accepted this Viewer's password (no one clicked Allow on the Host).
        public var viaPassword: Bool = false

        public init(hostName: String, remoteAddress: String, sessionId: UInt32, hostFingerprintDisplay: String,
                    isTrusted: Bool, viaPassword: Bool = false) {
            self.hostName = hostName
            self.remoteAddress = remoteAddress
            self.sessionId = sessionId
            self.hostFingerprintDisplay = hostFingerprintDisplay
            self.isTrusted = isTrusted
            self.viaPassword = viaPassword
        }
    }

    public struct Configuration: Sendable {
        public var deviceName: String = SessionSupport.computerName()
        public var appVersion: String = SessionSupport.appVersion()
        public var establishmentTimeout: TimeInterval = 10
        /// The Host operator has 60 s; the Viewer gives up a little later in case DENY(timeout) was lost.
        public var approvalTimeout: Duration = .seconds(75)
        /// How often to re-run `TailscaleProbe` while streaming over a tailnet address (direct/relay can change).
        public var tailscaleProbeInterval: Duration = .seconds(15)
        /// Retry schedule after a streaming session's connection failed (0.1.4).
        public var reconnect = ReconnectBackoff.Configuration()
        /// Establishment timeout of each reconnect attempt: short, so an attempt started during the outage does not
        /// hold up the next one (QUIC retransmits its handshake within it).
        public var reconnectAttemptTimeout: TimeInterval = 4
        /// Announce `PeerCapabilities.clipboard` (0.1.5); `sharesClipboard` is the live switch.
        public var clipboardSharing = true
        /// How often the pasteboard's change count is polled while streaming with clipboard sharing.
        public var clipboardPollInterval: Duration = .milliseconds(250)
        /// Announce `PeerCapabilities.cursorShape` (0.1.6); `showsRemotePointer` is the live switch.
        public var cursorShapes = true

        public init() {}
    }

    // MARK: Observable state

    public private(set) var state: State = .idle {
        didSet { updateShortcutTap() }
    }
    public private(set) var metrics = MetricsSnapshot()
    public private(set) var streamConfig: StreamConfig?
    public private(set) var trustedHosts: [TrustedHost] = []
    /// "LAN", "Loopback", "Tailscale", or a probe result such as "Tailscale (relay: fra)".
    public private(set) var pathDescription = ""
    /// A password proof was sent on the current connection (the UI shows "Signing in with password…").
    public private(set) var isUsingPassword = false
    /// Lowercase fingerprint hex of every trusted Host with a saved password (for "Forget saved password").
    public private(set) var savedPasswordFingerprints: Set<String> = []
    /// Reconnect automatically when a streaming session's connection fails (0.1.4, on by default; AppModel persists it).
    /// Also decides whether HELLO/AUTH announce `sessionResume`.
    public var autoReconnect = true {
        didSet {
            if !autoReconnect, reconnect != nil { disconnect() }
        }
    }
    /// Nothing has arrived from the Host for 1 s while streaming ("Poor connection"); clears when traffic resumes.
    public private(set) var isLinkStalled = false
    /// When the latest automatic reconnect succeeded (the UI shows a short "Reconnected" note).
    public private(set) var lastReconnectedAt: Date?
    /// The streaming Host announced `PeerCapabilities.sessionResume` in its ACCEPT.
    public private(set) var hostSupportsResume = false
    /// "Share clipboard" (0.1.5, default on; AppModel persists it). Live: the Host is told at once.
    public var sharesClipboard = true {
        didSet {
            guard sharesClipboard != oldValue else { return }
            if let clipboard {
                clipboard.setLocalEnabled(sharesClipboard)
            } else if isPresentingStream {
                clipboardStatus.localEnabled = sharesClipboard
            }
        }
    }
    /// Clipboard sharing in the current session (`.inactive` when not streaming).
    public private(set) var clipboardStatus = ClipboardSyncStatus.inactive
    /// How macOS treats SwiftDesk reading this Mac's clipboard (for the hint in settings); `refreshPasteboardAccess()`.
    public private(set) var pasteboardAccess = PasteboardAccessBehavior.unrestricted
    /// "Show the Host's pointer shape" (0.1.6, default on; AppModel persists it). Live and local: off draws the arrow;
    /// the Host keeps sending, so switching it back on shows the current shape at once.
    public var showsRemotePointer = true {
        didSet {
            guard showsRemotePointer != oldValue else { return }
            applyRemotePointer()
        }
    }
    /// What the Host says about its pointer in the current session (`.inactive` when not streaming).
    public private(set) var remotePointerStatus = RemotePointerStatus.inactive
    /// The pointer the stream view draws while capturing (`.standard` = the arrow).
    public private(set) var remotePointer = RemotePointer.standard
    /// "Send system shortcuts to the remote Mac" (0.1.7, default off; AppModel persists it). Live: takes effect the
    /// next time the stream view has focus while controlling (at once if it has).
    public var sendsSystemShortcuts = false {
        didSet {
            guard sendsSystemShortcuts != oldValue else { return }
            remoteView?.forwardsQuitShortcut = sendsSystemShortcuts
            updateShortcutTap()
        }
    }
    /// The address book (0.1.8): every Host this Mac connected to (empty without an `addressBook`).
    public private(set) var savedHosts: [SavedHost] = []
    /// "Save thumbnails of remote screens" (0.1.8, default on; AppModel persists it). Off deletes every saved
    /// thumbnail and stops keeping the last frame for one.
    public var savesThumbnails = true {
        didSet {
            guard savesThumbnails != oldValue else { return }
            sinkSlot.keepsLatestFrame = addressBook != nil && savesThumbnails
            if !savesThumbnails {
                thumbnailTask?.cancel()
                addressBook?.removeAllThumbnails()
                refreshSavedHosts()
            }
        }
    }
    /// Where the system-shortcut switch stands (needs permission, waiting for control, active …).
    public private(set) var systemShortcutStatus = SystemShortcutCaptureStatus.off
    /// Accessibility as last checked for the keyboard tap (re-checked when the switch is on and the tap would arm).
    public private(set) var shortcutPermissionGranted = false
    public let fingerprintDisplay: String
    public let deviceName: String

    /// Whether local keyboard/mouse is forwarded. Turning it off releases everything held on the Host.
    public var isCapturingInput = false {
        didSet {
            guard isCapturingInput != oldValue else { return }
            remoteView?.isCapturingInput = isCapturingInput
            if !isCapturingInput { inputController?.releaseAll() }
            updateShortcutTap()
        }
    }

    public nonisolated static let releaseShortcutDescription = ViewerInputController.releaseShortcutDescription

    public var isStreaming: Bool {
        if case .streaming = state { true } else { false }
    }

    /// Streaming, or reconnecting with the last frame still on screen: the stream window stays up.
    public var isPresentingStream: Bool {
        switch state {
        case .streaming, .reconnecting: true
        default: false
        }
    }

    public var isReconnecting: Bool {
        if case .reconnecting = state { true } else { false }
    }

    // MARK: Private

    @ObservationIgnored public let configuration: Configuration
    @ObservationIgnored public let trustStore: TrustedHostStore
    @ObservationIgnored public let savedPasswords: SavedHostPasswords
    /// Saved Hosts and thumbnails (0.1.8); nil keeps no history (tests, NetBench).
    @ObservationIgnored public let addressBook: AddressBookStore?
    /// The address-book entry of the current stream (kept through a reconnect) for its thumbnail at the end.
    @ObservationIgnored private var currentSavedHostID: UUID?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    /// Password typed for the current attempt, and whether to save it once it worked.
    @ObservationIgnored private var typedPassword: String?
    @ObservationIgnored private var rememberPassword = false
    /// The proof sent on this connection came from the saved password.
    @ObservationIgnored private var usedSavedPassword = false
    @ObservationIgnored private var proofTask: Task<Void, Never>?
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private let sinkSlot = FrameSinkSlot()
    @ObservationIgnored private let routerBox = ViewerRouterBox()
    @ObservationIgnored private var router: ViewerConnectionRouter?
    @ObservationIgnored private var handshake: ViewerHandshake?
    @ObservationIgnored private var target: (host: String, port: UInt16)?
    @ObservationIgnored private var inputController: ViewerInputController?
    @ObservationIgnored private weak var renderView: MetalVideoView?
    @ObservationIgnored private weak var remoteView: RemoteDisplayView?
    @ObservationIgnored private var approvalTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var reconnect: ReconnectContext?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private let makePasteboard: @MainActor () -> any PasteboardAccess
    @ObservationIgnored private var clipboard: ClipboardChannel?
    /// Pointer-shape definitions and the current shape of this stream (nil: no stream, or the Host lacks the feature).
    @ObservationIgnored private var cursorState: RemoteCursorState<RemotePointerImage>?
    @ObservationIgnored private var keyWindowObserver: (any NSObjectProtocol)?
    /// Tests: stands in for "the stream window is key" (no window exists headless).
    @ObservationIgnored var clipboardWindowIsKeyOverride: Bool?
    @ObservationIgnored private let shortcutPermission: @MainActor (_ prompt: Bool) -> Bool
    @ObservationIgnored private let makeShortcutTap: SystemShortcutTapFactory
    /// Created on first use, installed only while armed (`updateShortcutTap`).
    @ObservationIgnored private var shortcutTap: (any SystemShortcutTapping)?
    /// Tests: stands in for "the stream view has keyboard focus in the active app" (no window exists headless).
    @ObservationIgnored var inputFocusOverride: Bool?

    /// What an automatic reconnect needs from the lost session. The password stays in memory only.
    private struct ReconnectContext {
        var host: String
        var port: UInt16
        var hostFingerprint: Data
        var stream: StreamInfo
        var password: String?
        var backoff: ReconnectBackoff
        var droppedAt: ContinuousClock.Instant
        var startedAt: Date
        var lostReason: String
        var lastError: String?
        var wasCapturing: Bool
        var hostSupportsResume: Bool
    }

    public init(identity: DeviceIdentity, trustStore: TrustedHostStore = TrustedHostStore(),
                savedPasswords: SavedHostPasswords = SavedHostPasswords(),
                addressBook: AddressBookStore? = nil,
                configuration: Configuration = Configuration(),
                makePasteboard: @escaping @MainActor () -> any PasteboardAccess = { SystemPasteboard() },
                shortcutPermission: @escaping @MainActor (_ prompt: Bool) -> Bool = {
                    AccessibilityPermission.isTrusted(prompt: $0)
                },
                makeShortcutTap: @escaping SystemShortcutTapFactory = { isArmed, deliver in
                    SystemShortcutTap(isArmed: isArmed, deliver: deliver)
                }) {
        self.identity = identity
        self.makePasteboard = makePasteboard
        self.shortcutPermission = shortcutPermission
        self.makeShortcutTap = makeShortcutTap
        self.trustStore = trustStore
        self.savedPasswords = savedPasswords
        self.addressBook = addressBook
        self.configuration = configuration
        self.fingerprintDisplay = identity.fingerprintDisplay
        self.deviceName = configuration.deviceName
        self.trustedHosts = trustStore.list()
        self.savedHosts = addressBook?.list() ?? []
        sinkSlot.keepsLatestFrame = addressBook != nil
        refreshSavedPasswords()
        refreshPasteboardAccess()
    }

    /// Re-reads how macOS treats programmatic clipboard reads (no prompt; metadata only).
    public func refreshPasteboardAccess() {
        pasteboardAccess = makePasteboard().accessBehavior
    }

    /// Production instance: loads (or creates) the keychain device identity; the address book lives in
    /// Application Support/SwiftDesk.
    public static func makeDefault(configuration: Configuration = Configuration()) throws -> ViewerSession {
        ViewerSession(identity: try DeviceIdentity.loadOrCreate(), addressBook: AddressBookStore.standard(),
                      configuration: configuration)
    }

    // MARK: Rendering

    /// Shows decoded video in `view` (held weakly). A `RemoteDisplayView` also gets its input callbacks wired.
    /// Pass nil to detach (e.g. the window closed).
    public func attach(renderView view: MetalVideoView?) {
        if let old = renderView, old !== view {
            old.onPresented = nil
            if let oldRemote = old as? RemoteDisplayView {
                oldRemote.onMouse = nil
                oldRemote.onScroll = nil
                oldRemote.onKey = nil
                oldRemote.onFocusChange = nil
                oldRemote.isCapturingInput = false
                oldRemote.forwardsQuitShortcut = false
                oldRemote.remotePointer = .standard
            }
        }
        renderView = view
        remoteView = view as? RemoteDisplayView
        sinkSlot.sink = view
        guard let view else { return }
        let box = routerBox
        view.onPresented = { info in box.current?.notePresented(info) }
        if let remote = view as? RemoteDisplayView {
            remote.onMouse = { [weak self] event, point in self?.handleMouse(event, normalized: point) }
            remote.onScroll = { [weak self] event in self?.handleScroll(event) }
            remote.onKey = { [weak self] event in _ = self?.handleKey(event) }
            remote.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
            remote.isCapturingInput = isCapturingInput
            remote.forwardsQuitShortcut = sendsSystemShortcuts
            remote.remotePointer = remotePointer
            remote.remoteDisplayPointSize = streamConfig.map(Self.hostPointSize)
        }
    }

    /// Headless / custom destination for decoded frames (tests, recording). Replaces any attached view as the sink.
    public func attach(frameSink: (any VideoFrameSink)?) {
        sinkSlot.sink = frameSink
    }

    // MARK: Input (normally driven by RemoteDisplayView; public for custom views)

    public func handleMouse(_ event: NSEvent, normalized: CGPoint?) {
        guard isStreaming else { return }
        inputController?.handleMouse(event, normalized: normalized)
    }

    public func handleScroll(_ event: NSEvent) {
        guard isStreaming else { return }
        inputController?.handleScroll(event)
    }

    /// Returns false if the event was the local release shortcut; capture is then turned off (releasing held input).
    @discardableResult
    public func handleKey(_ event: NSEvent) -> Bool {
        guard isStreaming, let inputController else { return true }
        let forwarded = inputController.handleKey(event)
        if !forwarded { isCapturingInput = false }
        return forwarded
    }

    /// Focus lost (window/app/first responder): release everything held on the Host.
    public func focusChanged(_ focused: Bool) {
        if !focused { inputController?.releaseAll() }
        updateShortcutTap()
    }

    // MARK: System shortcuts (0.1.7)

    /// Presses `shortcut` once on the Host (the "Send Keys" menu). Works whether or not input is captured; false when
    /// not streaming. Anything held is released first. The key codes are never logged.
    @discardableResult
    public func send(_ shortcut: SystemShortcut) -> Bool {
        send(shortcut.chord)
    }

    /// Presses an arbitrary chord once on the Host; see `send(_:)`.
    @discardableResult
    public func send(_ chord: KeyChord) -> Bool {
        guard isStreaming, let inputController else { return false }
        inputController.send(chord)
        return true
    }

    /// Asks macOS for Accessibility (its one-time alert, which also lists SwiftDesk in Privacy & Security), then
    /// re-evaluates the tap.
    public func requestShortcutPermission() {
        shortcutPermissionGranted = shortcutPermission(true)
        updateShortcutTap()
    }

    /// Re-checks Accessibility without prompting (e.g. when the user comes back from System Settings).
    public func refreshShortcutPermission() {
        shortcutPermissionGranted = shortcutPermission(false)
        updateShortcutTap()
    }

    /// Opens Privacy & Security › Accessibility.
    public func openShortcutPermissionSettings() {
        AccessibilityPermission.openSettings()
    }

    /// The stream view holds keyboard focus in the active app (live, not the last notification).
    private var streamHasInputFocus: Bool {
        if let inputFocusOverride { return inputFocusOverride }
        guard let remoteView, remoteView.hasInputFocus else { return false }
        return NSApp?.isActive ?? false
    }

    /// Evaluated by the tap for every event, so a tap that outlived its moment never swallows a key.
    private var shortcutTapShouldTake: Bool {
        SystemShortcutCaptureStatus.shouldArm(enabled: sendsSystemShortcuts, permitted: shortcutPermissionGranted,
                                              streaming: isStreaming, capturing: isCapturingInput,
                                              focused: streamHasInputFocus)
    }

    /// Installs the keyboard tap while armed, removes it otherwise, and refreshes `systemShortcutStatus`. Called on
    /// every change that can arm or disarm it (switch, capture, focus, session state).
    private func updateShortcutTap() {
        let wouldArm = SystemShortcutCaptureStatus.shouldArm(enabled: sendsSystemShortcuts, permitted: true,
                                                             streaming: isStreaming, capturing: isCapturingInput,
                                                             focused: streamHasInputFocus)
        // Accessibility can be granted or revoked in System Settings at any time: check (cheaply, never prompting)
        // whenever the tap is about to be needed, and keep the status honest while the switch is on.
        if wouldArm || (sendsSystemShortcuts && !shortcutPermissionGranted) {
            shortcutPermissionGranted = shortcutPermission(false)
        }
        let armed = wouldArm && shortcutPermissionGranted
        if armed {
            let tap = shortcutTap ?? makeShortcutTap({ [weak self] in self?.shortcutTapShouldTake ?? false },
                                                     { [weak self] event in self?.shortcutTapTook(event) })
            shortcutTap = tap
            if !tap.isInstalled, !tap.install() {
                Log.input.error("System shortcut tap could not be installed")
            }
        } else {
            shortcutTap?.remove()
        }
        let status = SystemShortcutCaptureStatus.make(enabled: sendsSystemShortcuts,
                                                      permitted: shortcutPermissionGranted, armed: armed,
                                                      installed: shortcutTap?.isInstalled ?? false)
        if status != systemShortcutStatus {
            systemShortcutStatus = status
            if status == .active || status == .standby {
                Log.input.info("System shortcut capture \(status == .active ? "active" : "standby", privacy: .public)")
            }
        }
    }

    /// A key event the tap took: forwarded exactly like one the stream view received. Dropped if capture ended in
    /// the meantime (that already released everything held, so a late key-down must not press anything again).
    private func shortcutTapTook(_ event: TapKeyEvent) {
        guard shortcutTapShouldTake, let inputController else { return }
        if !inputController.handleKey(event) { isCapturingInput = false }
    }

    /// Key-up / button-up for everything currently held.
    public func releaseAllInput() {
        inputController?.releaseAll()
    }

    // MARK: Trusted hosts

    public func refreshTrustedHosts() {
        trustedHosts = trustStore.list()
        refreshSavedPasswords()
    }

    /// Removes the pin. The saved password goes too, unless the same identity is still trusted at another address.
    public func forgetTrustedHost(key: String) {
        let fingerprint = trustStore.list().first { $0.key == key }?.fingerprintHex
        trustStore.remove(key: key)
        if let fingerprint, !trustStore.list().contains(where: { $0.fingerprintHex == fingerprint }) {
            savedPasswords.remove(fingerprintHex: fingerprint)
        }
        refreshTrustedHosts()
    }

    /// True if a password is saved for this trusted Host.
    public func hasSavedPassword(_ host: TrustedHost) -> Bool {
        savedPasswordFingerprints.contains(host.fingerprintHex.lowercased())
    }

    /// "Forget saved password" for a trusted Host; the pin stays.
    public func forgetSavedPassword(for host: TrustedHost) {
        savedPasswords.remove(fingerprintHex: host.fingerprintHex)
        refreshSavedPasswords()
    }

    private func refreshSavedPasswords() {
        savedPasswordFingerprints = Set(trustedHosts.map { $0.fingerprintHex.lowercased() }
            .filter { savedPasswords.hasPassword(fingerprintHex: $0) })
    }

    // MARK: Address book (0.1.8)

    public func refreshSavedHosts() {
        savedHosts = addressBook?.list() ?? []
    }

    /// Rename; an empty name goes back to the name the Host reports.
    public func renameSavedHost(id: UUID, to name: String) {
        addressBook?.rename(id: id, to: name)
        refreshSavedHosts()
    }

    public func setFavorite(id: UUID, _ favorite: Bool) {
        addressBook?.setFavorite(id: id, favorite)
        refreshSavedHosts()
    }

    /// Removes the entry and its thumbnail. A pin or saved password for the Host stays (Trusted Hosts manages those).
    public func removeSavedHost(id: UUID) {
        addressBook?.remove(id: id)
        refreshSavedHosts()
    }

    /// "Clear History": every recent entry and every thumbnail; favorites stay.
    public func clearHistory() {
        thumbnailTask?.cancel()
        addressBook?.clearHistory()
        refreshSavedHosts()
    }

    /// The thumbnail file of `entry`, if it has one.
    public func thumbnailURL(for entry: SavedHost) -> URL? {
        addressBook?.thumbnailURL(for: entry)
    }

    /// How an entry's address relates to the pins in Trusted Hosts (observes `trustedHosts`).
    public func pinState(of entry: SavedHost, address: SavedHostAddress? = nil) -> SavedHostPinState {
        guard let address = address ?? entry.primaryAddress else { return .unpinned }
        return entry.pinState(of: address, trusted: trustedHosts)
    }

    /// Waits until the thumbnail of the session that just ended is written (app quit, tests).
    public func waitForPendingThumbnail() async {
        await thumbnailTask?.value
    }

    /// A stream just started (not a resume): record the Host in the address book.
    private func recordSavedHost(host: String, port: UInt16, fingerprint: Data?, hostName: String) {
        guard let addressBook, let fingerprint else { return }
        currentSavedHostID = addressBook.recordConnection(host: host, port: port, fingerprint: fingerprint,
                                                          hostName: hostName).id
        refreshSavedHosts()
    }

    /// The stream ended: turn its last frame into the entry's thumbnail (encoded off the main actor), if wanted.
    private func saveThumbnailOfEndedStream() {
        let frame = sinkSlot.takeLatestFrame()
        guard let id = currentSavedHostID else { return }
        currentSavedHostID = nil
        guard savesThumbnails, let addressBook, let frame else { return }
        let previous = thumbnailTask
        thumbnailTask = Task { [weak self] in
            await previous?.value
            let jpeg = await Task.detached(priority: .utility) {
                SessionThumbnail.jpeg(from: frame.pixelBuffer)
            }.value
            // The switch or "Clear History" may have changed while encoding: check again before writing.
            guard !Task.isCancelled, let self, self.savesThumbnails, let jpeg else { return }
            if addressBook.saveThumbnail(jpeg, for: id) { self.refreshSavedHosts() }
        }
    }

    // MARK: Connection lifecycle

    /// Dials `host:port`, pinning the stored fingerprint if the user trusted this address before.
    /// - Parameters:
    ///   - password: offered only if the Host challenges (password access enabled there), and only after its identity
    ///     was verified. Empty means none; a saved password for this Host is used when none is typed.
    ///   - rememberPassword: save `password` in the keychain for this Host once it worked — only if the Host is pinned.
    public func connect(host rawHost: String, port: UInt16 = WireConstants.defaultPort, password: String? = nil,
                        rememberPassword: Bool = false) {
        switch state {
        case .idle, .disconnected: break
        default: return
        }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            state = .disconnected(reason: "Enter a host name or IP address")
            return
        }
        teardown(close: nil)
        let pin = trustStore.pinnedFingerprint(host: host, port: port)
        open(host: host, port: port, pin: pin, password: password, rememberPassword: rememberPassword,
             establishmentTimeout: configuration.establishmentTimeout)
        state = .connecting(host: host, port: port)
        Log.session.notice("Viewer connecting (pinned: \(pin != nil, privacy: .public))")
    }

    /// Dials one connection attempt (a user's connect or an automatic reconnect).
    private func open(host: String, port: UInt16, pin: Data?, password: String?, rememberPassword: Bool,
                      establishmentTimeout: TimeInterval) {
        typedPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        self.rememberPassword = rememberPassword
        handshake = ViewerHandshake(pinnedFingerprint: pin)
        target = (host, port)
        metrics = MetricsSnapshot()
        streamConfig = nil
        pathDescription = SessionSupport.pathLabel(forHost: host)

        let connection = PeerConnection.connect(host: host, port: port, identity: identity, pinnedHostFingerprint: pin,
                                                establishmentTimeout: establishmentTimeout)
        let router = ViewerConnectionRouter(connection: connection, sinkSlot: sinkSlot,
                                            announced: optionalFeatures) { [weak self] event in
            onMain { [weak self] in self?.routerEvent(event, from: connection) }
        }
        self.router = router
        routerBox.current = router
        router.attach()
    }

    /// The user compared the fingerprint and trusts this Host. `remember` pins it for this address.
    public func trustHost(remember: Bool) {
        guard case .verifyingHost(let verification) = state, var handshake else { return }
        if remember {
            trustStore.add(host: verification.host, port: verification.port, fingerprint: verification.fingerprint,
                           name: verification.host)
            refreshTrustedHosts()
        }
        let effect = handshake.userTrusted()
        self.handshake = handshake
        if let effect { execute(effect) }
    }

    public func rejectHost() {
        guard var handshake else { return }
        let effect = handshake.userRejected()
        self.handshake = handshake
        if let effect { execute(effect) }
    }

    /// Ends the session: releases held input, sends DISCONNECT(userInitiated) and stops the pipeline. While
    /// reconnecting it cancels the reconnect.
    public func disconnect() {
        if reconnect != nil, handshake == nil {
            finish(message: "Disconnected", close: nil)
            return
        }
        guard var handshake else {
            if case .disconnected = state { return }
            state = .idle
            return
        }
        let effect = handshake.userDisconnected()
        self.handshake = handshake
        if let effect { execute(effect) }
    }

    /// Tests: the current connection fails the way a network loss does (closed without DISCONNECT, reported as a
    /// transport failure), so the reconnect path can be exercised on loopback.
    func simulateConnectionLoss() {
        guard let router else { return }
        let connection = router.connection
        connection.close(reason: nil)
        routerEvent(.stateChanged(.failed("Simulated network loss")), from: connection)
    }

    /// Skips the wait before the next reconnect attempt.
    public func reconnectNow() {
        guard reconnect != nil, case .reconnecting(let status) = state, case .waiting = status.phase else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        attemptReconnect()
    }

    // MARK: Events

    private func routerEvent(_ event: ViewerConnectionRouter.Event, from connection: PeerConnection) {
        guard let router, router.connection === connection, var handshake else { return }
        let effect: ViewerHandshake.Effect?
        switch event {
        case .clipboardState(let clipboardState):
            clipboard?.peerStateChanged(clipboardState)
            return
        case .clipboard(let content):
            clipboard?.received(content)
            return
        case .sideStreamReady:
            clipboard?.sideStreamReady()
            return
        case .cursorShape(let shape):
            remoteShapeChanged(shape)
            return
        case .cursorImage(let image):
            remoteShapeDefined(image)
            return
        case .stateChanged, .message:
            break
        }
        var retryable = false
        var dropped = false
        switch event {
        case .stateChanged(.ready):
            let fingerprint = connection.peerFingerprint
            let known = fingerprint.map(trustStore.contains(fingerprint:)) ?? false
            effect = handshake.transportReady(peerFingerprint: fingerprint, isKnownFingerprint: known)
        case .stateChanged(let terminal):
            if case .streaming = handshake.phase { dropped = true }
            retryable = ReconnectPolicy.shouldRetry(after: terminal)
            effect = handshake.transportEnded(terminal)
        case .message(let message):
            if case .deny(let deny) = message {
                if deny.reason == .authFailed { passwordRejected() }
                retryable = ReconnectPolicy.shouldRetry(after: deny.reason)
            }
            effect = handshake.receive(message)
        case .clipboardState, .clipboard, .sideStreamReady, .cursorShape, .cursorImage:
            return
        }
        self.handshake = handshake
        // A failed connection (not anyone's decision) of a streaming session, or of a reconnect attempt: retry.
        if case .end(let message, _)? = effect, retryable, autoReconnect {
            if dropped, case .streaming = state {
                beginReconnect(lostReason: message)
                return
            }
            if reconnect != nil {
                scheduleReconnectAttempt(lastError: message)
                return
            }
        }
        if let effect { execute(effect) }
    }

    private func execute(_ effect: ViewerHandshake.Effect) {
        guard let router, let target else { return }
        switch effect {
        case .verify(let fingerprint, let firstTime):
            state = .verifyingHost(HostVerification(host: target.host, port: target.port, fingerprint: fingerprint,
                                                    fingerprintDisplay: DeviceIdentity.display(fingerprint),
                                                    fingerprintDisplayFull: DeviceIdentity.displayFull(fingerprint),
                                                    firstTime: firstTime))
        case .sendHandshake(let hostFingerprint):
            let nonce: Data
            do {
                nonce = try SecureRandom.bytes(Auth.nonceSize)
            } catch {
                finish(message: "Could not generate a secure nonce", close: .protocolError)
                return
            }
            router.markHandshakeSent()
            router.connection.sendControl(.hello(Hello(deviceName: deviceName, appVersion: configuration.appVersion)))
            // The nonce announces this Viewer's optional features; older Hosts ignore the marker (PeerCapabilities).
            var capabilities: PeerCapabilities = optionalFeatures.union(.passwordAuth)
            if autoReconnect { capabilities.insert(.sessionResume) }
            router.connection.sendControl(.auth(Auth(viewerFingerprint: identity.fingerprint,
                                                     hostFingerprint: hostFingerprint,
                                                     nonce: Auth.nonce(capabilities: capabilities, random: nonce))))
            if reconnect != nil {
                updateReconnectStatus(phase: .awaitingApproval)
            } else {
                state = .awaitingApproval
            }
            scheduleApprovalTimeout()
        case .answerChallenge(let challenge, let hostFingerprint):
            answer(challenge, hostFingerprint: hostFingerprint, router: router)
        case .declineChallenge:
            router.connection.sendControl(.passwordResponse(.none))
        case .passwordFallback:
            // The Host ignored (or never got) the proof and asks its operator: whatever happens next is not a
            // password login, so nothing is saved and the session is not marked "via password".
            proofTask?.cancel()
            proofTask = nil
            isUsingPassword = false
            usedSavedPassword = false
            Log.session.notice("Host fell back to its approval prompt")
        case .startStreaming(let accept):
            approvalTask?.cancel()
            approvalTask = nil
            let key = TrustedHostStore.key(host: target.host, port: target.port)
            let trusted = trustStore.entry(host: target.host, port: target.port) != nil
            let resumed = reconnect
            reconnect = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            // A resumed password session stays one (the Host does not say whether it prompted; display only).
            let viaPassword = isUsingPassword || (resumed?.stream.viaPassword ?? false)
            savePasswordIfWanted(trusted: trusted, router: router)
            // The Host's name is peer-supplied: one sanitized line, like the Host does for HELLO.
            let hostName = SessionSupport.displayName(accept.hostName)
            if trusted { trustStore.rename(key: key, to: hostName) }
            refreshTrustedHosts()
            let box = routerBox
            inputController = ViewerInputController(send: { input in box.current?.send(input) })
            router.mediaPipeline?.onMetrics = { [weak self] snapshot in
                onMain { [weak self] in self?.metricsArrived(snapshot) }
            }
            router.mediaPipeline?.onLinkStall = { [weak self, weak router] stalled in
                onMain { [weak self, weak router] in
                    guard let self, let router, self.router === router, self.isStreaming else { return }
                    self.isLinkStalled = stalled
                }
            }
            if resumed == nil {
                recordSavedHost(host: target.host, port: target.port, fingerprint: router.connection.peerFingerprint,
                                hostName: hostName)
            }
            hostSupportsResume = accept.capabilities.contains(.sessionResume)
            isLinkStalled = false
            state = .streaming(StreamInfo(hostName: hostName, remoteAddress: router.connection.remoteAddress,
                                          sessionId: accept.sessionId,
                                          hostFingerprintDisplay: DeviceIdentity.display(router.connection.peerFingerprint ?? Data()),
                                          isTrusted: trusted, viaPassword: viaPassword))
            startPathProbe(host: target.host)
            startClipboard(accept: accept, router: router)
            startRemotePointer(accept: accept)
            if let resumed {
                lastReconnectedAt = Date()
                // Capture resumes only if it was on and the stream window is still the key window.
                if resumed.wasCapturing, remoteView?.window?.isKeyWindow == true { isCapturingInput = true }
                Log.session.notice("Viewer reconnected after \(resumed.backoff.attempts, privacy: .public) attempt(s)")
            } else {
                Log.session.notice("Viewer streaming")
            }
        case .configure(let config):
            streamConfig = config
            remoteView?.remoteDisplayPointSize = Self.hostPointSize(config)
        case .end(let message, let closeReason):
            finish(message: message, close: closeReason)
        }
    }

    /// Optional features this build announces regardless of settings (switches travel separately).
    private var optionalFeatures: PeerCapabilities {
        var features: PeerCapabilities = []
        if configuration.clipboardSharing { features.insert(.clipboard) }
        if configuration.cursorShapes { features.insert(.cursorShape) }
        return features
    }

    // MARK: Pointer shape

    /// Starts following the Host's pointer shape if it speaks it too (its first CURSOR_SHAPE follows ACCEPT).
    private func startRemotePointer(accept: Accept) {
        guard configuration.cursorShapes, accept.capabilities.contains(.cursorShape) else {
            cursorState = nil
            remotePointerStatus = .unsupported
            applyRemotePointer()
            return
        }
        cursorState = RemoteCursorState()
        remotePointerStatus = .unavailable
        applyRemotePointer()
    }

    private func stopRemotePointer() {
        cursorState = nil
        remotePointerStatus = .inactive
        applyRemotePointer()
    }

    private func remoteShapeChanged(_ shape: CursorShape) {
        guard isStreaming, var state = cursorState else { return }
        let changed = state.apply(shape)
        cursorState = state
        switch shape {
        case .off: remotePointerStatus = .offOnHost
        case .unavailable: remotePointerStatus = .unavailable
        case .hidden, .image: remotePointerStatus = .active
        }
        if changed { applyRemotePointer() }
    }

    private func remoteShapeDefined(_ image: CursorImage) {
        guard isStreaming, cursorState != nil else { return }
        // A definition that does not decode to what it announced is ignored: that shape keeps the previous pointer.
        guard let pointer = CursorRendering.pointerImage(image) else {
            Log.session.notice("Ignoring an undecodable pointer shape from the Host")
            return
        }
        if cursorState?.define(id: image.id, image: pointer) == true { applyRemotePointer() }
    }

    /// Pushes the pointer to draw to the stream view.
    private func applyRemotePointer() {
        var pointer = RemotePointer.standard
        if showsRemotePointer, let cursorState {
            switch cursorState.appearance {
            case .standard: pointer = .standard
            case .hidden: pointer = .hidden
            case .image(_, let image): pointer = .image(image)
            }
        }
        if remotePointer != pointer { remotePointer = pointer }
        remoteView?.remotePointer = pointer
    }

    /// The Host display's size in points, from CONFIG (scales the pointer like the picture).
    private static func hostPointSize(_ config: StreamConfig) -> CGSize {
        CGSize(width: CGFloat(config.displayPointWidth), height: CGFloat(config.displayPointHeight))
    }

    // MARK: Clipboard

    /// Starts clipboard sharing for the new stream if the Host speaks it too (its CLIPBOARD_STATE follows ACCEPT).
    private func startClipboard(accept: Accept, router: ViewerConnectionRouter) {
        stopClipboard()
        refreshPasteboardAccess()
        guard configuration.clipboardSharing, accept.capabilities.contains(.clipboard) else {
            clipboardStatus = ClipboardSyncStatus(peerSupports: false, localEnabled: sharesClipboard)
            return
        }
        let channel = ClipboardChannel(pasteboard: makePasteboard(), transport: router.connection,
                                       localEnabled: sharesClipboard, baselineAtStart: false,
                                       pollInterval: configuration.clipboardPollInterval,
                                       canReadLocal: { [weak self] in self?.streamWindowIsKey ?? false }) {
            [weak self, weak router] status in
            guard let self, let router, self.router === router else { return }
            self.clipboardStatus = status
            if status.accessDenied { self.refreshPasteboardAccess() }
        }
        clipboard = channel
        channel.start()
        if router.connection.isSideStreamOpen { channel.sideStreamReady() }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                // Copy locally, focus the remote screen, paste: the stream window becoming key is the moment to sync.
                guard let self, let window, window === self.remoteView?.window else { return }
                self.clipboard?.checkLocal()
            }
        }
    }

    private func stopClipboard() {
        clipboard?.stop()
        clipboard = nil
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
        clipboardStatus = .inactive
    }

    /// Viewer → Host sync only while the stream window is the key window of the active app.
    private var streamWindowIsKey: Bool {
        if let clipboardWindowIsKeyOverride { return clipboardWindowIsKeyOverride }
        guard let window = remoteView?.window else { return false }
        return window.isKeyWindow && NSApp.isActive
    }

    /// Checks this Mac's clipboard now (e.g. the stream window became key through a path the observer misses).
    public func syncClipboardNow() {
        clipboard?.checkLocal()
    }

    // MARK: Password

    /// Answers a PASSWORD_CHALLENGE: proof from the typed or saved password (PBKDF2 off the main actor), else "none".
    private func answer(_ challenge: PasswordChallenge, hostFingerprint: Data, router: ViewerConnectionRouter) {
        // The TLS-observed fingerprint, which the handshake already bound (pin or user verification).
        guard router.connection.peerFingerprint == hostFingerprint else {
            router.connection.sendControl(.passwordResponse(.none))
            return
        }
        let saved = typedPassword == nil ? savedPasswords.password(forFingerprint: hostFingerprint) : nil
        guard let password = typedPassword ?? saved else {
            router.connection.sendControl(.passwordResponse(.none))
            return
        }
        usedSavedPassword = typedPassword == nil
        isUsingPassword = true
        let viewerFingerprint = identity.fingerprint
        proofTask?.cancel()
        proofTask = Task { [weak self] in
            let proof = try? await Task.detached(priority: .userInitiated) {
                try AccessPassword.answer(challenge, password: password, hostFingerprint: hostFingerprint,
                                          viewerFingerprint: viewerFingerprint)
            }.value
            guard !Task.isCancelled, let self, self.router === router else { return }
            if let proof {
                router.connection.sendControl(.passwordResponse(.proof(proof)))
            } else {
                self.isUsingPassword = false
                router.connection.sendControl(.passwordResponse(.none))
            }
        }
    }

    /// DENY(authFailed): a saved password that just failed is deleted, so the next attempt asks for it again.
    private func passwordRejected() {
        guard isUsingPassword, usedSavedPassword, let fingerprint = router?.connection.peerFingerprint else { return }
        savedPasswords.remove(fingerprintHex: TrustedHostStore.hex(fingerprint))
        refreshSavedPasswords()
    }

    /// After a successful password login: save a typed password for a pinned Host if the user asked to.
    private func savePasswordIfWanted(trusted: Bool, router: ViewerConnectionRouter) {
        guard isUsingPassword, !usedSavedPassword, rememberPassword, trusted, let password = typedPassword,
              let fingerprint = router.connection.peerFingerprint,
              let target, trustStore.pinnedFingerprint(host: target.host, port: target.port) == fingerprint else { return }
        do {
            try savedPasswords.save(password, forFingerprint: fingerprint)
        } catch {
            Log.session.error("Could not save the Host password in the keychain")
        }
        refreshSavedPasswords()
    }

    private func metricsArrived(_ snapshot: MetricsSnapshot) {
        guard isStreaming else { return }
        var m = snapshot
        m.pathDescription = pathDescription
        m.framesReplacedBeforeDisplay = renderView?.framesReplacedBeforeDisplay ?? 0
        metrics = m
    }

    private func finish(message: String, close reason: DisconnectReason?) {
        saveThumbnailOfEndedStream()
        reconnect = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown(close: reason)
        state = .disconnected(reason: message)
        Log.session.notice("Viewer session ended")
    }

    // MARK: Reconnect

    /// The streaming session's connection failed: keep the last frame and start redialing.
    private func beginReconnect(lostReason: String) {
        guard case .streaming(let info) = state, let target,
              let hostFingerprint = router?.connection.peerFingerprint else {
            finish(message: lostReason, close: nil)
            return
        }
        let backoff = ReconnectBackoff(configuration: configuration.reconnect)
        let budget = configuration.reconnect.budget
        let budgetSeconds = Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18
        let now = Date()
        let context = ReconnectContext(host: target.host, port: target.port, hostFingerprint: hostFingerprint,
                                       stream: info, password: typedPassword, backoff: backoff,
                                       droppedAt: .now, startedAt: now, lostReason: lostReason, lastError: nil,
                                       wasCapturing: isCapturingInput, hostSupportsResume: hostSupportsResume)
        teardown(close: nil, keepPicture: true)
        reconnect = context
        state = .reconnecting(ReconnectStatus(stream: info, host: target.host, port: target.port,
                                              phase: .waiting(nextAttemptAt: now), attempt: 0, lostReason: lostReason,
                                              lastError: nil, startedAt: now,
                                              deadline: now.addingTimeInterval(budgetSeconds),
                                              hostSupportsResume: context.hostSupportsResume))
        Log.session.notice("Viewer connection lost; reconnecting")
        scheduleReconnectAttempt(lastError: nil)
    }

    /// Drops a failed attempt (if any) and waits for the next one, or gives up when the budget is spent.
    private func scheduleReconnectAttempt(lastError: String?) {
        guard var context = reconnect else { return }
        if router != nil { teardown(close: nil, keepPicture: true) }
        guard let delay = context.backoff.nextDelay(elapsed: .now - context.droppedAt) else {
            let name = context.stream.hostName
            finish(message: "Could not reconnect to \(name). \(context.lastError ?? context.lostReason)", close: nil)
            return
        }
        if let lastError { context.lastError = lastError }
        reconnect = context
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        updateReconnectStatus(phase: .waiting(nextAttemptAt: Date().addingTimeInterval(seconds)))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard let context = reconnect, case .reconnecting = state, router == nil else { return }
        reconnectTask = nil
        // Pinned to the certificate this session was verified with: no prompt, and a different one is refused.
        open(host: context.host, port: context.port, pin: context.hostFingerprint, password: context.password,
             rememberPassword: false, establishmentTimeout: configuration.reconnectAttemptTimeout)
        updateReconnectStatus(phase: .connecting)
        Log.session.notice("Viewer reconnect attempt \(context.backoff.attempts, privacy: .public)")
    }

    private func updateReconnectStatus(phase: ReconnectStatus.Phase) {
        guard let context = reconnect, case .reconnecting(var status) = state else { return }
        status.phase = phase
        status.attempt = phase == .connecting ? context.backoff.attempts : status.attempt
        status.lastError = context.lastError
        state = .reconnecting(status)
    }

    /// Release held input while the route is still up (so key-ups reach the Host before DISCONNECT), then stop.
    /// `keepPicture`: leave the last frame on screen (reconnecting).
    private func teardown(close reason: DisconnectReason?, keepPicture: Bool = false) {
        approvalTask?.cancel()
        approvalTask = nil
        proofTask?.cancel()
        proofTask = nil
        usedSavedPassword = false
        isUsingPassword = false
        typedPassword = nil
        probeTask?.cancel()
        probeTask = nil
        stopClipboard()
        stopRemotePointer()
        inputController?.releaseAll()
        inputController = nil
        isCapturingInput = false
        shortcutTap?.remove()
        if let router {
            router.stop()
            router.connection.close(reason: reason)
        }
        router = nil
        routerBox.current = nil
        handshake = nil
        isLinkStalled = false
        if !keepPicture {
            renderView?.clear()
            sinkSlot.dropLatestFrame()
            currentSavedHostID = nil
        }
        metrics = MetricsSnapshot()
    }

    private func scheduleApprovalTimeout() {
        approvalTask?.cancel()
        let timeout = configuration.approvalTimeout
        approvalTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, var handshake = self.handshake else { return }
            let effect = handshake.approvalTimedOut()
            self.handshake = handshake
            if let effect { self.execute(effect) }
        }
    }

    private func startPathProbe(host: String) {
        probeTask?.cancel()
        guard SessionSupport.shouldProbeTailscale(host: host) else { return }
        let interval = configuration.tailscaleProbeInterval
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                if let path = await TailscaleProbe.path(to: host) {
                    guard !Task.isCancelled else { return }
                    self?.pathDescription = path.summary
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
