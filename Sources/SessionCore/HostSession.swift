import AppKit
import CaptureCore
import CoreGraphics
import DiagnosticsCore
import Foundation
import InputCore
import Observation
import TransportCore
import WireProtocol

/// A Viewer asking for control, shown to the Host operator for an explicit decision (PRD §4 Host step 4).
public struct ConnectionRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Device name from HELLO, sanitized with `SessionSupport.displayName` (single line, no control/bidi characters).
    /// Self-reported: display only, the fingerprint is the identity.
    public var peerName: String
    public var appVersion: String
    /// SHA-256 of the Viewer's certificate as authenticated by TLS and confirmed by AUTH.
    public var fingerprint: Data
    public var fingerprintDisplay: String
    public var remoteAddress: String
    /// False means the session can only be view-only (no input injection) until Accessibility is granted.
    public var accessibilityGranted: Bool
    public var receivedAt: Date

    public init(id: UUID = UUID(), peerName: String, appVersion: String, fingerprint: Data, fingerprintDisplay: String,
                remoteAddress: String, accessibilityGranted: Bool, receivedAt: Date = Date()) {
        self.id = id
        self.peerName = peerName
        self.appVersion = appVersion
        self.fingerprint = fingerprint
        self.fingerprintDisplay = fingerprintDisplay
        self.remoteAddress = remoteAddress
        self.accessibilityGranted = accessibilityGranted
        self.receivedAt = receivedAt
    }
}

/// The Viewer of the active session.
public struct HostPeer: Sendable, Equatable {
    public var name: String
    public var fingerprintDisplay: String
    public var remoteAddress: String
    public var sessionId: UInt32
    public var startedAt: Date
    /// Input is not injected (Accessibility missing or revoked). Shown prominently on the Host.
    public var isViewOnly: Bool
    /// The Viewer proved the access password; nobody clicked Allow. Shown as "Controlled via password by …".
    /// A resumed session keeps the flag of the session it continues.
    public var viaPassword: Bool
    /// 0.1.4: this session continues one whose connection dropped; the Viewer came back within the reconnect grace
    /// window without a new prompt (`ReconnectGrace`). `startedAt` is the original session's start.
    public var resumed: Bool

    public init(name: String, fingerprintDisplay: String, remoteAddress: String, sessionId: UInt32, startedAt: Date,
                isViewOnly: Bool, viaPassword: Bool = false, resumed: Bool = false) {
        self.name = name
        self.fingerprintDisplay = fingerprintDisplay
        self.remoteAddress = remoteAddress
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.isViewOnly = isViewOnly
        self.viaPassword = viaPassword
        self.resumed = resumed
    }
}

/// A dropped session whose Viewer may come back without a prompt (shown on the Host with a way to revoke it).
public struct ReconnectGraceInfo: Sendable, Equatable {
    public var peerName: String
    public var expiresAt: Date
    public var viaPassword: Bool

    public init(peerName: String, expiresAt: Date, viaPassword: Bool) {
        self.peerName = peerName
        self.expiresAt = expiresAt
        self.viaPassword = viaPassword
    }
}

/// Non-modal "Reconnected <peer>" note for the Host after a session resumed without a prompt.
public struct ReconnectedNotice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var peerName: String
    public var at: Date

    public init(id: UUID = UUID(), peerName: String, at: Date = Date()) {
        self.id = id
        self.peerName = peerName
        self.at = at
    }
}

/// The "Share this Mac" role: listens, authenticates and asks the operator, then streams one display and applies the
/// Viewer's input for the duration of one approved session.
///
/// Consent and safety rules this type enforces (PRD §4, §7, §9):
/// - at most one session; any other connection gets DENY(busy) while a request is awaiting approval or a session is
///   active. Connections that have not yet identified themselves (HELLO + AUTH) do *not* hold that slot: they wait
///   in a small bounded pool (`maxPendingHandshakes`), so a silent peer with a throwaway certificate cannot starve
///   legitimate Viewers for the whole pre-HELLO window;
/// - after the operator denies a request (or lets it time out), the same Viewer identity is answered with
///   DENY(rateLimited) without a new prompt for `deniedPeerCooldown`, so repeated requests cannot wear the operator
///   down;
/// - HELLO must arrive within `preHelloTimeout`, AUTH within `handshakeTimeout` (10 s) after it; AUTH must bind the
///   TLS-observed fingerprints in both directions, otherwise DENY(identityMismatch);
/// - no Screen Recording ⇒ DENY(permissionsMissing); no Accessibility ⇒ the session may only be view-only, flagged in
///   `isViewOnly` and in the request shown to the operator;
/// - nothing is injected before `approve()`; the operator has `approvalTimeout` (60 s) before DENY(timeout);
/// - opt-in password access (off by default): with a password set and enabled, a Viewer that supports it is
///   challenged after AUTH, without a prompt, for `passwordTimeout` (3 s). A valid proof starts the session like
///   `approve()` (flagged `HostPeer.viaPassword`); no password or no answer falls back to the prompt (after a timeout
///   the Viewer is told with PASSWORD_RESPONSE(none)); a wrong one is DENY(authFailed). Repeated failures lock the
///   fingerprint/IP out of password attempts (`PasswordAttemptLimiter`): it is prompted instead of challenged;
/// - `stopSharing()`, Viewer disconnect, connection loss and capture stopped by the system all run the same teardown:
///   stop capture, deauthorize input (which releases held keys/buttons), close with DISCONNECT, back to listening;
/// - dropouts (0.1.4): a Viewer silent for 1 s gets every held key/button released (the session stays up; QUIC's
///   30 s idle timeout decides when the connection is gone, `isPeerSilent` shows it). When an allowed session loses
///   its connection, the same Viewer identity may come back without a prompt for `reconnectGraceWindow` (2 min) —
///   or replace the active session if the Host has not noticed the drop yet — unless the operator switched that off
///   or revoked it (Stop Sharing, Stop Listening, Deny, `revokeReconnectGrace()`); see `ReconnectGrace`. The
///   resumed session is flagged `HostPeer.resumed` and announced by `reconnectedNotice`. When the operator revokes a
///   dropped password session that way (or stops a password session whose Viewer has gone silent), that Viewer's next
///   password login within the window is prompted instead (0.2.0), so its automatic reconnect cannot log back in;
/// - clipboard sharing (0.1.5): only inside an active session, only with a Viewer that announced
///   `PeerCapabilities.clipboard`, and only while `allowsClipboardSharing` is on (the operator's switch, live). Copies
///   made on this Mac before the session are not sent; see `ClipboardChannel`;
/// - pointer shape (0.1.6): only inside an active session, only with a Viewer that announced
///   `PeerCapabilities.cursorShape`, and only while `sharesPointerShape` is on (live): this Mac's pointer shape is
///   read ≈ 30 times a second and sent when it changes; see `CursorShapeChannel`.
///
/// Threading: this object lives on the main actor and is touched only by rare events (connection, handshake,
/// decisions, ≤ 2 Hz metrics). Frames, input and keyframe requests never visit the main actor: they flow through
/// `HostConnectionRouter` and `HostMediaPipeline` on dedicated queues.
@MainActor
@Observable
public final class HostSession {
    public enum State: Sendable, Equatable {
        case idle
        case starting
        case listening(port: UInt16)
        case awaitingApproval(ConnectionRequest)
        case active(HostPeer)
    }

    public struct Configuration: Sendable {
        public var port: UInt16 = WireConstants.defaultPort
        public var deviceName: String = SessionSupport.computerName()
        public var advertiseBonjour = true
        public var rateLimiter = ConnectionRateLimiter()
        /// Time allowed before HELLO. Longer than the HELLO→AUTH budget because, on a first connection, the Viewer
        /// sends HELLO only after its user has compared fingerprints.
        public var preHelloTimeout: Duration = .seconds(60)
        /// HELLO → AUTH budget (PRD: 10 s).
        public var handshakeTimeout: Duration = .seconds(10)
        /// Operator decision budget (60 s, then DENY(timeout)).
        public var approvalTimeout: Duration = .seconds(60)
        /// Cursor / queue-depth settings; size and fps come from the adaptation ladder.
        public var capture = CaptureConfig()
        /// The Sharp profile with its timing and thresholds; `HostSession.streamQuality` picks the ladder and bitrate
        /// range each session actually uses (`StreamQuality.adaptation(base:)`).
        public var adaptation = AdaptationController.Configuration()
        public var adaptationEnabled = true
        /// Send keyframe datagrams twice so on-demand recovery survives random loss (see `HostMediaPipeline`).
        public var duplicateKeyframePackets = true
        /// XOR parity datagrams with K adapted to the Viewer's loss reports (see `HostMediaPipeline`); `.off` disables.
        public var forwardErrorCorrection = FECPolicy.Configuration()
        /// Most video (ms at the target bitrate) that may be queued in the transport ahead of a new frame, beyond the
        /// undrained part of the last keyframe (see `HostMediaPipeline.allowedBacklogAhead`).
        public var sendQueueBudgetMillis = 80
        /// Connections that passed mTLS but have not yet sent HELLO + AUTH, kept apart from the session slot. When
        /// full, a newcomer replaces the oldest one from its own address (else the oldest overall).
        public var maxPendingHandshakes = 4
        /// After an operator Deny or an approval timeout, requests from the same Viewer fingerprint get
        /// DENY(rateLimited) without a prompt for this long.
        public var deniedPeerCooldown: Duration = .seconds(60)
        /// How long the Host waits for PASSWORD_RESPONSE before falling back to the operator prompt.
        public var passwordTimeout: Duration = .seconds(3)
        /// Brute-force limits for password access.
        public var passwordAttempts = PasswordAttemptLimiter.Configuration()
        /// How long after an allowed session lost its connection its Viewer may come back without a prompt.
        public var reconnectGraceWindow: Duration = .seconds(120)
        /// Silence from the Viewer after which every held key/button is released (the session continues).
        public var inputReleaseAfterSilence: Duration = .seconds(1)
        /// Announce `PeerCapabilities.clipboard` (0.1.5). Whether clipboards are actually shared is
        /// `HostSession.allowsClipboardSharing`, which can change during a session.
        public var clipboardSharing = true
        /// How often the pasteboard's change count is polled during a session with clipboard sharing.
        public var clipboardPollInterval: Duration = .milliseconds(250)
        /// Announce `PeerCapabilities.cursorShape` (0.1.6). Whether the shape is actually sent is
        /// `HostSession.sharesPointerShape`, which can change during a session.
        public var cursorShapes = true
        /// How often the pointer shape is sampled during a session that shares it (≈ 30 Hz).
        public var cursorPollInterval: Duration = .milliseconds(33)

        public init() {}
    }

    /// Everything that touches TCC, the keychain or hardware, injectable for tests.
    public struct Dependencies: Sendable {
        public var identity: DeviceIdentity
        public var permissions: PermissionChecker
        /// Creates the frame source for the selected display (nil only if no display is known).
        public var makeVideoSource: @Sendable (DisplayInfo?, CaptureConfig) throws -> any VideoSource
        /// Creates the input sink for a capture area in global display points.
        public var makeInputSink: @Sendable (CGRect) -> any InputSink
        /// Opt-in password access (keychain-backed in production). nil: the feature does not exist for this session.
        public var accessPassword: HostAccessPassword?
        /// The pasteboard clipboard sharing reads and writes (0.1.5): `NSPasteboard.general` by default.
        public var makePasteboard: @MainActor @Sendable () -> any PasteboardAccess
        /// Where the pointer shape is read (0.1.6): `NSCursor.currentSystem` by default.
        public var makeCursorSource: @MainActor @Sendable () -> any CursorSource

        public init(identity: DeviceIdentity, permissions: PermissionChecker,
                    makeVideoSource: @escaping @Sendable (DisplayInfo?, CaptureConfig) throws -> any VideoSource,
                    makeInputSink: @escaping @Sendable (CGRect) -> any InputSink,
                    accessPassword: HostAccessPassword? = nil,
                    makePasteboard: @escaping @MainActor @Sendable () -> any PasteboardAccess = { SystemPasteboard() },
                    makeCursorSource: @escaping @MainActor @Sendable () -> any CursorSource = { SystemCursorSource() }) {
            self.identity = identity
            self.permissions = permissions
            self.makeVideoSource = makeVideoSource
            self.makeInputSink = makeInputSink
            self.accessPassword = accessPassword
            self.makePasteboard = makePasteboard
            self.makeCursorSource = makeCursorSource
        }

        /// Production wiring: ScreenCaptureKit capture and CGEvent injection with the real permission checks.
        public static func system(identity: DeviceIdentity) -> Dependencies {
            Dependencies(
                identity: identity,
                permissions: .system,
                makeVideoSource: { display, config in
                    guard let display else { throw HostSessionError.noDisplay }
                    return ScreenCapturer(display: display, config: config)
                },
                makeInputSink: { frame in HostInputInjector(displayFrame: frame) },
                accessPassword: HostAccessPassword())
        }
    }

    // MARK: Observable state

    public private(set) var state: State = .idle
    /// ≈2 Hz while a session is active; reset when it ends.
    public private(set) var metrics = MetricsSnapshot()
    public private(set) var displays: [DisplayInfo] = []
    public var selectedDisplayID: CGDirectDisplayID?
    /// Sharp (native resolution up to 1920×1080) or Balanced (up to 1280×720). Applies to the next session, like
    /// `selectedDisplayID`; AppModel persists it.
    public var streamQuality: StreamQuality = .sharp
    public private(set) var localAddresses: [InterfaceAddress] = []
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    /// The active session cannot inject input (Accessibility missing or revoked).
    public private(set) var isViewOnly = false
    /// Last listener/pipeline error, for the UI.
    public private(set) var lastError: String?
    /// Why the previous session (or request) ended, e.g. "Viewer disconnected".
    public private(set) var lastEndReason: String?
    /// Connections that passed mutual TLS but have not identified themselves (HELLO + AUTH) yet. They hold no
    /// session slot; `dropPendingConnections()` closes them.
    public private(set) var pendingConnectionCount = 0
    /// A password is set and password access is on.
    public private(set) var passwordAccessEnabled = false
    /// A password is set (it may be switched off).
    public private(set) var passwordAccessConfigured = false
    /// Wrong passwords since SwiftDesk started (shown on the Host so guessing is never silent).
    public private(set) var passwordFailureCount = 0
    /// The latest wrong-password attempt, e.g. "Wrong password from 192.168.1.20 (Mac mini)".
    public private(set) var lastPasswordFailure: String?
    /// True if password access can exist at all (a password store is configured).
    public var supportsPasswordAccess: Bool { dependencies.accessPassword != nil }
    /// Let a Viewer whose allowed session dropped come back without a new prompt (`ReconnectGrace`); on by default,
    /// AppModel persists it. Switching it off forgets any pending grace and stops announcing `sessionResume`.
    public var allowsReconnectWithoutPrompt = true {
        didSet {
            guard allowsReconnectWithoutPrompt != oldValue else { return }
            if !allowsReconnectWithoutPrompt { forgetReconnectGrace() }
        }
    }
    /// A dropped session whose Viewer may still come back without a prompt, until `expiresAt`.
    public private(set) var reconnectGrace: ReconnectGraceInfo?
    /// Set when the active session resumed without a prompt; cleared when it ends or on `dismissReconnectedNotice()`.
    public private(set) var reconnectedNotice: ReconnectedNotice?
    /// The active session's Viewer has sent nothing for `inputReleaseAfterSilence` (held input was released).
    public private(set) var isPeerSilent = false
    /// "Allow clipboard sharing" (0.1.5, default on; AppModel persists it). Live: switching it during a session tells
    /// the Viewer at once and stops (or resumes) syncing in both directions.
    public var allowsClipboardSharing = true {
        didSet {
            guard allowsClipboardSharing != oldValue else { return }
            clipboard?.setLocalEnabled(allowsClipboardSharing)
            if clipboard == nil, isSharing {
                clipboardStatus.localEnabled = allowsClipboardSharing
            }
        }
    }
    /// Clipboard sharing in the active session (`.inactive` when none).
    public private(set) var clipboardStatus = ClipboardSyncStatus.inactive
    /// How macOS treats SwiftDesk reading this Mac's clipboard (for the hint in settings); `refreshPasteboardAccess()`.
    public private(set) var pasteboardAccess = PasteboardAccessBehavior.unrestricted
    /// "Show my pointer shape to the Viewer" (0.1.6, default on; AppModel persists it). Live: switched off during a
    /// session, sampling stops and the Viewer falls back to its arrow at once.
    public var sharesPointerShape = true {
        didSet {
            guard sharesPointerShape != oldValue else { return }
            cursorChannel?.setEnabled(sharesPointerShape)
            if cursorChannel == nil, isSharing { cursorShapeStatus.enabled = sharesPointerShape }
        }
    }
    /// Pointer-shape sharing in the active session (`.inactive` when none).
    public private(set) var cursorShapeStatus = CursorShapeStatus.inactive

    public let deviceName: String
    public let fingerprintDisplay: String
    public let fingerprintDisplayFull: String

    public var pendingRequest: ConnectionRequest? {
        if case .awaitingApproval(let request) = state { request } else { nil }
    }

    /// True while a Viewer is connected and approved (drives the menu-bar sharing indicator).
    public var isSharing: Bool {
        if case .active = state { true } else { false }
    }

    public var activePeer: HostPeer? {
        if case .active(let peer) = state { peer } else { nil }
    }

    public var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID } ?? displays.first
    }

    /// The size the next session starts streaming at for the selected display and quality, e.g. 1600×900 for a
    /// 1600×900 display on Sharp; nil when no display is known.
    public var expectedStreamSize: (width: Int, height: Int)? {
        guard let display = selectedDisplay else { return nil }
        return streamQuality.streamSize(displayPixelWidth: display.pixelWidth, displayPixelHeight: display.pixelHeight,
                                        base: configuration.adaptation)
    }

    /// The adaptation configuration a session started now would use.
    public var sessionAdaptation: AdaptationController.Configuration {
        streamQuality.adaptation(base: configuration.adaptation)
    }

    // MARK: Private

    @ObservationIgnored public let configuration: Configuration
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var listener: HostListener?
    @ObservationIgnored private var listenerPort: UInt16?
    @ObservationIgnored private var current: HostConnectionRouter?
    @ObservationIgnored private var handshake: HostHandshake?
    @ObservationIgnored private var pipeline: HostMediaPipeline?
    @ObservationIgnored private var inputSink: (any InputSink)?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var stoppingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var metricsTicks: UInt64 = 0
    @ObservationIgnored private var pendingHandshakes: [UUID: PendingHandshake] = [:]
    @ObservationIgnored private var pendingOrder: UInt64 = 0
    /// Viewer fingerprint → when its last request was denied or timed out (operator decision).
    @ObservationIgnored private var deniedPeers: [Data: ContinuousClock.Instant] = [:]
    /// Viewer fingerprint → when the operator revoked its password session while it was away (Require Approval,
    /// Stop Sharing, Stop Listening, Deny). Its next password login within `passwordReturnPromptWindow` is prompted
    /// instead (one-shot), so a Viewer's automatic reconnect cannot undo the decision by replaying the password.
    @ObservationIgnored private var promptedPasswordReturns: [Data: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var passwordLimiter: PasswordAttemptLimiter
    @ObservationIgnored private var grace: ReconnectGrace
    @ObservationIgnored private var graceExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var clipboard: ClipboardChannel?
    @ObservationIgnored private var cursorChannel: CursorShapeChannel?

    /// A connection between mutual TLS and a verified HELLO + AUTH. Promoted to `current` (the exclusive session
    /// slot) only when it asks for approval.
    private struct PendingHandshake {
        let router: HostConnectionRouter
        var handshake: HostHandshake
        var timeoutTask: Task<Void, Never>?
        let order: UInt64
    }

    /// Bound on remembered denied fingerprints (oldest forgotten first).
    private static let maxDeniedPeers = 64

    public init(configuration: Configuration = Configuration(), dependencies: Dependencies) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.deviceName = configuration.deviceName
        self.fingerprintDisplay = dependencies.identity.fingerprintDisplay
        self.fingerprintDisplayFull = DeviceIdentity.displayFull(dependencies.identity.fingerprint)
        self.passwordLimiter = PasswordAttemptLimiter(configuration: configuration.passwordAttempts)
        self.grace = ReconnectGrace(window: configuration.reconnectGraceWindow)
        refreshPermissions()
        refreshNetworkInfo()
        refreshPasswordState()
        refreshPasteboardAccess()
    }

    /// Re-reads how macOS treats programmatic clipboard reads (no prompt; metadata only).
    public func refreshPasteboardAccess() {
        pasteboardAccess = dependencies.makePasteboard().accessBehavior
    }

    /// Production instance: loads (or creates) the keychain device identity.
    public static func makeDefault(configuration: Configuration = Configuration()) throws -> HostSession {
        let identity = try DeviceIdentity.loadOrCreate()
        let session = HostSession(configuration: configuration, dependencies: .system(identity: identity))
        session.refreshDisplays()
        return session
    }

    // MARK: Environment

    public func refreshPermissions() {
        screenRecordingGranted = dependencies.permissions.screenRecordingGranted()
        accessibilityGranted = dependencies.permissions.accessibilityGranted()
    }

    public func refreshNetworkInfo() {
        localAddresses = NetworkInfo.localAddresses()
    }

    /// Reloads the display list (CoreGraphics; no Screen Recording permission needed).
    public func refreshDisplays() {
        displays = DisplayInfo.activeDisplays()
        if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id
        }
    }

    /// Shows the system Screen Recording prompt (first time) and refreshes the status.
    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        let granted = ScreenCapturePermission.request()
        refreshPermissions()
        return granted
    }

    public func openScreenRecordingSettings() { ScreenCapturePermission.openSettings() }

    /// Shows the system Accessibility prompt (first time) and refreshes the status.
    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        let trusted = AccessibilityPermission.isTrusted(prompt: true)
        refreshPermissions()
        return trusted
    }

    public func openAccessibilitySettings() { AccessibilityPermission.openSettings() }

    // MARK: Password access

    public func refreshPasswordState() {
        passwordAccessConfigured = dependencies.accessPassword?.isConfigured ?? false
        passwordAccessEnabled = dependencies.accessPassword?.isEnabled ?? false
    }

    /// Sets (or replaces) the access password. The first password turns password access on; replacing one keeps the
    /// current on/off switch. PBKDF2 runs off the main actor.
    /// Throws `AccessPassword.Failure.tooShort` below `AccessPassword.minimumLength` characters.
    public func setAccessPassword(_ password: String) async throws {
        guard let access = dependencies.accessPassword else { return }
        guard AccessPassword.isAcceptable(password) else {
            throw AccessPassword.Failure.tooShort(minimum: AccessPassword.minimumLength)
        }
        try await Task.detached(priority: .userInitiated) { try access.set(password: password) }.value
        refreshPasswordState()
        revokePasswordGrace()
        Log.session.notice("Access password set")
    }

    /// Turns password access on or off, keeping the password. Turning it on needs a password.
    public func setPasswordAccessEnabled(_ enabled: Bool) throws {
        defer { refreshPasswordState() }
        try dependencies.accessPassword?.setEnabled(enabled)
        if !enabled { revokePasswordGrace() }
    }

    /// Forgets the access password; every later connection needs the operator again.
    public func clearAccessPassword() {
        dependencies.accessPassword?.clear()
        refreshPasswordState()
        revokePasswordGrace()
        Log.session.notice("Access password removed")
    }

    /// What password access allows for this connection (AUTH time): off, locked out, or a fresh challenge.
    private func passwordGate(for router: HostConnectionRouter) -> HostHandshake.PasswordGate {
        guard let access = dependencies.accessPassword, let params = access.challengeParameters() else { return .disabled }
        let fingerprint = router.connection.peerFingerprint ?? Data()
        if takePasswordReturnPrompt(for: fingerprint) {
            Log.session.notice("Operator revoked this Viewer's password session; prompting instead")
            return .disabled
        }
        let address = SessionSupport.hostPart(of: router.connection.remoteAddress)
        switch passwordLimiter.check(fingerprint: fingerprint, address: address, nowNanos: MonotonicClock.nowNanos()) {
        case .lockedOut:
            Log.session.notice("Viewer locked out of password attempts; prompting instead")
            return .lockedOut
        case .passwordDisabled:
            Log.session.notice("Password access paused after too many failures; prompting instead")
            return .disabled
        case .allowed:
            guard let nonce = try? SecureRandom.bytes(PasswordChallenge.nonceSize) else { return .disabled }
            return .available(PasswordChallenge(salt: params.salt, iterations: params.iterations, nonce: nonce))
        }
    }

    /// Proof check bound to this connection's TLS identities. No password store: the challenge cannot be valid.
    private func proofVerifier(for router: HostConnectionRouter) -> (Data, PasswordChallenge) -> HostAccessPassword.ProofResult {
        let access = dependencies.accessPassword
        let hostFingerprint = dependencies.identity.fingerprint
        let viewerFingerprint = router.connection.peerFingerprint ?? Data()
        return { proof, challenge in
            access?.check(proof: proof, challenge: challenge, hostFingerprint: hostFingerprint,
                          viewerFingerprint: viewerFingerprint) ?? .stale
        }
    }

    private func handshakeEffect(_ handshake: inout HostHandshake, message: ControlMessage,
                                 router: HostConnectionRouter) -> HostHandshake.Effect? {
        var gate = HostHandshake.PasswordGate.disabled
        var resume = false
        if case .auth(let auth) = message {
            resume = resumeAllowed(for: router, capabilities: auth.capabilities)
            if !resume { gate = passwordGate(for: router) }
        }
        return handshake.receive(message, screenRecordingGranted: dependencies.permissions.screenRecordingGranted(),
                                 password: gate, resume: resume, verifyProof: proofVerifier(for: router))
    }

    // MARK: Reconnect without a prompt

    /// The operator's "Require Approval" (also Stop Sharing, Stop Listening, Deny): forgets the dropped session's
    /// grace, and if that session came from the access password, the Viewer's next password login is prompted too —
    /// otherwise its automatic reconnect would log straight back in with the password it still holds.
    public func revokeReconnectGrace() {
        if let entry = grace.entry, entry.viaPassword { promptPasswordReturn(of: entry.fingerprint) }
        forgetReconnectGrace()
    }

    /// Forgets the dropped session's grace (expiry, the setting switched off, password access changed): its Viewer
    /// needs the prompt or the password again.
    private func forgetReconnectGrace() {
        grace.revoke()
        graceExpiryTask?.cancel()
        graceExpiryTask = nil
        reconnectGrace = nil
    }

    public func dismissReconnectedNotice() {
        reconnectedNotice = nil
    }

    /// AUTH time: may this connection resume without a prompt? Either the grace entry of a dropped session matches,
    /// or it replaces the active session of the same identity (whose drop the Host has not noticed yet).
    private func resumeAllowed(for router: HostConnectionRouter, capabilities: PeerCapabilities) -> Bool {
        guard allowsReconnectWithoutPrompt, capabilities.contains(.sessionResume),
              let fingerprint = router.connection.peerFingerprint, !fingerprint.isEmpty else { return false }
        let passwordOn = dependencies.accessPassword?.isEnabled ?? false
        if let current, current !== router {
            guard current.isActive, current.connection.peerFingerprint == fingerprint,
                  case .active(let peer) = state else { return false }
            return !peer.viaPassword || passwordOn
        }
        return grace.allowsResume(fingerprint: fingerprint, capabilities: capabilities, enabled: true,
                                  passwordAccessEnabled: passwordOn, nowNanos: MonotonicClock.nowNanos())
    }

    /// An allowed session lost its connection: its Viewer may come back without a prompt for the grace window.
    private func openGrace(for peer: HostPeer, fingerprint: Data) {
        guard allowsReconnectWithoutPrompt, !fingerprint.isEmpty, configuration.reconnectGraceWindow > .zero else { return }
        grace.sessionDropped(ReconnectGrace.Entry(fingerprint: fingerprint, peerName: peer.name,
                                                  viaPassword: peer.viaPassword, sessionStartedAt: peer.startedAt,
                                                  droppedAtNanos: MonotonicClock.nowNanos()))
        let window = configuration.reconnectGraceWindow
        let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        let info = ReconnectGraceInfo(peerName: peer.name, expiresAt: Date().addingTimeInterval(seconds),
                                      viaPassword: peer.viaPassword)
        reconnectGrace = info
        graceExpiryTask?.cancel()
        graceExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self, self.reconnectGrace == info else { return }
            self.forgetReconnectGrace()
            Log.session.notice("Reconnect grace expired")
        }
        Log.session.notice("Viewer connection lost; reconnect without a prompt allowed for the grace window")
    }

    /// Password access switched off, removed or changed: a dropped password session needs the password again.
    private func revokePasswordGrace() {
        if reconnectGrace?.viaPassword == true || grace.entry?.viaPassword == true { forgetReconnectGrace() }
    }

    /// Window for `promptedPasswordReturns`: at least the Viewer's reconnect budget (60 s by default).
    private var passwordReturnPromptWindow: Duration { max(configuration.reconnectGraceWindow, .seconds(120)) }

    private func promptPasswordReturn(of fingerprint: Data) {
        guard !fingerprint.isEmpty else { return }
        promptedPasswordReturns[fingerprint] = ContinuousClock.now
        if promptedPasswordReturns.count > Self.maxDeniedPeers,
           let oldest = promptedPasswordReturns.min(by: { $0.value < $1.value })?.key {
            promptedPasswordReturns[oldest] = nil
        }
        Log.session.notice("Next password login from that Viewer will ask the operator")
    }

    /// Consumes the one-shot "prompt instead of the password" mark for this Viewer, if it is still in its window.
    private func takePasswordReturnPrompt(for fingerprint: Data) -> Bool {
        let now = ContinuousClock.now
        let window = passwordReturnPromptWindow
        promptedPasswordReturns = promptedPasswordReturns.filter { now - $0.value < window }
        return promptedPasswordReturns.removeValue(forKey: fingerprint) != nil
    }

    /// Stop Sharing / Stop Listening on a password session whose Viewer has gone silent: the DISCONNECT probably
    /// cannot reach it, so it will try to reconnect; that reconnect is prompted, not a password login.
    private func promptPasswordReturnIfViewerAway() {
        guard let current, current.isActive, isPeerSilent, case .active(let peer) = state, peer.viaPassword,
              let fingerprint = current.connection.peerFingerprint else { return }
        promptPasswordReturn(of: fingerprint)
    }

    /// May a connection that arrives while a session is active go on to identify itself? Only the active Viewer's
    /// own identity, coming back (its old connection is dead on its side) — it still needs HELLO + AUTH and the
    /// grace rules before it replaces anything.
    private func mayReplaceActiveSession(with connection: PeerConnection) -> Bool {
        guard allowsReconnectWithoutPrompt, let current, current.isActive,
              let fingerprint = connection.peerFingerprint, !fingerprint.isEmpty else { return false }
        return current.connection.peerFingerprint == fingerprint
    }

    // MARK: Listening

    public func startListening() {
        guard listener == nil else { return }
        lastError = nil
        let listener = HostListener(port: configuration.port, identity: dependencies.identity,
                                    deviceName: deviceName, advertiseBonjour: configuration.advertiseBonjour,
                                    rateLimiter: configuration.rateLimiter)
        listener.onStateChange = { [weak self, weak listener] state in
            onMain { [weak self, weak listener] in
                guard let self, let listener else { return }
                self.listenerStateChanged(listener, state)
            }
        }
        listener.onIncoming = { [weak self, weak listener] connection in
            onMain { [weak self, weak listener] in
                guard let self, let listener, listener === self.listener else {
                    connection.close(reason: .hostStopped)
                    return
                }
                self.incoming(connection)
            }
        }
        self.listener = listener
        state = .starting
        listener.start()
        Log.session.notice("Host listening requested")
    }

    /// Ends any session (DISCONNECT hostStopped) and stops accepting connections.
    public func stopListening() {
        revokeReconnectGrace()
        promptPasswordReturnIfViewerAway()
        if let current { end(current, close: .hostStopped, message: "Sharing stopped") }
        dropPendingConnections()
        listener?.stop()
        listener = nil
        listenerPort = nil
        state = .idle
        Log.session.notice("Host stopped listening")
    }

    // MARK: Operator decisions

    /// Grants the pending request: ACCEPT + CONFIG, starts capture and (unless view-only) input injection.
    public func approve() {
        guard let current, var handshake, handshake.isAwaitingApproval else { return }
        let effect = handshake.decide(approved: true)
        self.handshake = handshake
        if let effect { execute(effect, for: current) }
    }

    public func deny() {
        guard let current, var handshake, handshake.isAwaitingApproval else { return }
        revokeReconnectGrace()
        let effect = handshake.decide(approved: false)
        self.handshake = handshake
        if let effect { execute(effect, for: current) }
    }

    /// Closes every connection that has not identified itself yet (HELLO + AUTH). Does not affect a pending
    /// approval or the active session.
    public func dropPendingConnections() {
        for id in Array(pendingHandshakes.keys) { removePending(id, close: .hostStopped) }
    }

    /// Ends the active session immediately (DISCONNECT hostStopped) and keeps listening.
    public func stopSharing() {
        revokeReconnectGrace()
        promptPasswordReturnIfViewerAway()
        guard let current, current.isActive else { return }
        end(current, close: .hostStopped, message: "You stopped sharing")
    }

    // MARK: Listener events

    private func listenerStateChanged(_ listener: HostListener, _ newState: ListenerState) {
        guard listener === self.listener else { return }
        switch newState {
        case .ready(let port):
            listenerPort = port
            if state == .starting { state = .listening(port: port) }
        case .failed(let message):
            lastError = "Could not listen for connections: \(message)"
            if let current { end(current, close: .hostStopped, message: "Listener failed") }
            dropPendingConnections()
            self.listener = nil
            listenerPort = nil
            state = .idle
        case .starting, .stopped:
            break
        }
    }

    private func incoming(_ connection: PeerConnection) {
        guard current == nil || mayReplaceActiveSession(with: connection) else {
            Log.session.notice("Rejecting connection: busy")
            HostConnectionRouter.rejectBusy(connection)
            return
        }
        if pendingHandshakes.count >= max(1, configuration.maxPendingHandshakes) {
            evictPendingHandshake(forNewcomerAt: connection.remoteAddress)
        }
        let router = HostConnectionRouter(connection: connection,
                                          silenceThresholdNanos: Self.nanos(configuration.inputReleaseAfterSilence)) {
            [weak self] event in
            onMain { [weak self] in self?.routerEvent(event, from: connection) }
        }
        pendingOrder &+= 1
        pendingHandshakes[router.id] = PendingHandshake(
            router: router,
            handshake: HostHandshake(hostFingerprint: dependencies.identity.fingerprint,
                                     peerFingerprint: connection.peerFingerprint),
            timeoutTask: nil, order: pendingOrder)
        pendingConnectionCount = pendingHandshakes.count
        router.attach()
        schedulePendingTimeout(configuration.preHelloTimeout, for: router.id)
        Log.session.notice("Incoming authenticated connection; waiting for HELLO")
    }

    private func routerEvent(_ event: HostConnectionRouter.Event, from connection: PeerConnection) {
        if let current, current.connection === connection {
            currentRouterEvent(event, current)
        } else if let id = pendingHandshakes.first(where: { $0.value.router.connection === connection })?.key {
            pendingRouterEvent(event, id: id)
        }
    }

    private func currentRouterEvent(_ event: HostConnectionRouter.Event, _ current: HostConnectionRouter) {
        switch event {
        case .handshake(let message):
            guard var handshake else { return }
            let effect = handshakeEffect(&handshake, message: message, router: current)
            self.handshake = handshake
            if let effect { execute(effect, for: current) }
        case .peerDisconnected:
            end(current, close: nil, message: current.isActive ? "The Viewer disconnected" : "The Viewer cancelled the request")
        case .transportEnded:
            // A dropped connection (not a decision by either side): the Viewer may come back without a prompt.
            if current.isActive, case .active(let peer) = state {
                openGrace(for: peer, fingerprint: current.connection.peerFingerprint ?? Data())
            }
            end(current, close: nil, message: "Connection to the Viewer was lost")
        case .peerSilence(let silent):
            guard current.isActive else { return }
            isPeerSilent = silent
            if silent {
                Log.session.notice("Viewer silent; held input released")
            } else {
                Log.session.notice("Viewer heard again")
            }
        case .clipboardState(let clipboardState):
            guard current.isActive else { return }
            clipboard?.peerStateChanged(clipboardState)
        case .clipboard(let content):
            guard current.isActive else { return }
            clipboard?.received(content)
        case .sideStreamReady:
            guard current.isActive else { return }
            clipboard?.sideStreamReady()
            cursorChannel?.sideStreamReady()
        }
    }

    // MARK: Pre-AUTH connections

    private func pendingRouterEvent(_ event: HostConnectionRouter.Event, id: UUID) {
        guard var entry = pendingHandshakes[id] else { return }
        switch event {
        case .handshake(let message):
            let wasAwaitingHello = entry.handshake.phase == .awaitingHello
            let effect = handshakeEffect(&entry.handshake, message: message, router: entry.router)
            pendingHandshakes[id]?.handshake = entry.handshake
            if wasAwaitingHello, case .awaitingAuth = entry.handshake.phase {
                schedulePendingTimeout(configuration.handshakeTimeout, for: id)
            }
            if let effect { executePending(effect, id: id) }
        case .peerDisconnected, .transportEnded:
            removePending(id, close: nil)
        case .peerSilence, .clipboardState, .clipboard, .sideStreamReady:
            break
        }
    }

    private func executePending(_ effect: HostHandshake.Effect, id: UUID) {
        guard let entry = pendingHandshakes[id] else { return }
        let router = entry.router
        switch effect {
        case .requestApproval(let hello):
            pendingHandshakes[id] = nil
            pendingConnectionCount = pendingHandshakes.count
            entry.timeoutTask?.cancel()
            let fingerprint = router.connection.peerFingerprint ?? Data()
            guard current == nil else {
                Log.session.notice("Rejecting identified connection: busy")
                _ = router.deactivate()
                HostConnectionRouter.reject(router.connection, reason: .busy, message: "Another session is in progress")
                return
            }
            if isCoolingDown(fingerprint) {
                Log.session.notice("Rejecting request from a recently denied Viewer")
                _ = router.deactivate()
                HostConnectionRouter.reject(router.connection, reason: .rateLimited,
                                            message: "This Mac declined a request from you moments ago; try again later")
                return
            }
            // Identity bound: this connection now takes the single session slot and the operator is asked.
            current = router
            handshake = entry.handshake
            execute(.requestApproval(hello), for: router)
        case .sendChallenge(let challenge):
            pendingHandshakes[id] = nil
            pendingConnectionCount = pendingHandshakes.count
            entry.timeoutTask?.cancel()
            guard current == nil else {
                Log.session.notice("Rejecting identified connection: busy")
                _ = router.deactivate()
                HostConnectionRouter.reject(router.connection, reason: .busy, message: "Another session is in progress")
                return
            }
            // Identity bound: the slot is taken while the password is checked (no prompt yet). The operator-deny
            // cooldown is not applied here: the password limiter guards this path, and a fallback to the prompt
            // checks the cooldown then.
            current = router
            handshake = entry.handshake
            execute(.sendChallenge(challenge), for: router)
        case .resumeAccepted(let hello):
            pendingHandshakes[id] = nil
            pendingConnectionCount = pendingHandshakes.count
            entry.timeoutTask?.cancel()
            let fingerprint = router.connection.peerFingerprint ?? Data()
            if let current {
                // The Viewer's new connection replaces the session whose drop the Host has not noticed yet: hand its
                // grace to the new connection and end the old one (it is dead on the Viewer's side).
                guard current.isActive, current.connection.peerFingerprint == fingerprint,
                      case .active(let peer) = state else {
                    Log.session.notice("Rejecting identified connection: busy")
                    _ = router.deactivate()
                    HostConnectionRouter.reject(router.connection, reason: .busy, message: "Another session is in progress")
                    return
                }
                grace.sessionDropped(ReconnectGrace.Entry(fingerprint: fingerprint, peerName: peer.name,
                                                          viaPassword: peer.viaPassword,
                                                          sessionStartedAt: peer.startedAt,
                                                          droppedAtNanos: MonotonicClock.nowNanos()))
                end(current, close: .timeout, message: "Connection to the Viewer was lost")
            }
            self.current = router
            handshake = entry.handshake
            execute(.resumeAccepted(hello), for: router)
        case .accept, .passwordAccepted, .fallbackToPrompt:
            // Unreachable: approval and password checks happen only for `current`.
            removePending(id, close: .protocolError)
        case .deny(let reason, let message):
            Log.session.notice("Denying connection: \(String(describing: reason), privacy: .public)")
            removePending(id, deny: (reason, message))
        case .close(let reason):
            Log.session.notice("Closing connection: protocol violation")
            removePending(id, close: reason)
        }
    }

    /// Forgets a pre-AUTH connection and closes it (DENY first when `deny` is given; `close: nil` for a connection
    /// that is already gone).
    private func removePending(_ id: UUID, close reason: DisconnectReason? = nil, deny: (DenyReason, String)? = nil) {
        guard let entry = pendingHandshakes.removeValue(forKey: id) else { return }
        pendingConnectionCount = pendingHandshakes.count
        entry.timeoutTask?.cancel()
        _ = entry.router.deactivate()
        if let deny {
            HostConnectionRouter.reject(entry.router.connection, reason: deny.0, message: deny.1)
        } else {
            entry.router.connection.close(reason: reason)
        }
    }

    /// Makes room for a newcomer: the oldest pending connection from the same address (a peer reconnecting, or one
    /// flooding), else the oldest overall.
    private func evictPendingHandshake(forNewcomerAt remoteAddress: String) {
        let host = SessionSupport.hostPart(of: remoteAddress)
        let byAge = pendingHandshakes.values.sorted { $0.order < $1.order }
        let victim = byAge.first { SessionSupport.hostPart(of: $0.router.connection.remoteAddress) == host } ?? byAge.first
        guard let victim else { return }
        Log.session.notice("Too many unidentified connections; dropping the oldest")
        removePending(victim.router.id, deny: (.busy, "Too many connections are waiting to identify"))
    }

    private func schedulePendingTimeout(_ duration: Duration, for id: UUID) {
        pendingHandshakes[id]?.timeoutTask?.cancel()
        pendingHandshakes[id]?.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, var handshake = self.pendingHandshakes[id]?.handshake else { return }
            let effect = handshake.handshakeTimedOut()
            self.pendingHandshakes[id]?.handshake = handshake
            if let effect { self.executePending(effect, id: id) }
        }
    }

    private func isCoolingDown(_ fingerprint: Data) -> Bool {
        let now = ContinuousClock.now
        deniedPeers = deniedPeers.filter { now - $0.value < configuration.deniedPeerCooldown }
        return deniedPeers[fingerprint] != nil
    }

    private func rememberDenied(_ fingerprint: Data) {
        guard !fingerprint.isEmpty, configuration.deniedPeerCooldown > .zero else { return }
        deniedPeers[fingerprint] = ContinuousClock.now
        if deniedPeers.count > Self.maxDeniedPeers, let oldest = deniedPeers.min(by: { $0.value < $1.value })?.key {
            deniedPeers[oldest] = nil
        }
    }

    private func execute(_ effect: HostHandshake.Effect, for router: HostConnectionRouter) {
        guard router === current else { return }
        switch effect {
        case .requestApproval(let hello):
            let fingerprint = router.connection.peerFingerprint ?? Data()
            if isCoolingDown(fingerprint) {
                // Fallback from the password check for a Viewer the operator declined moments ago.
                Log.session.notice("Rejecting request from a recently denied Viewer")
                end(router, deny: (.rateLimited, "This Mac declined a request from you moments ago; try again later"),
                    message: "A recently declined Viewer asked again")
                return
            }
            refreshPermissions()
            // HELLO strings are peer-controlled: sanitized so they cannot add lines or reorder text in the prompt.
            let request = ConnectionRequest(peerName: SessionSupport.displayName(hello.deviceName),
                                            appVersion: SessionSupport.displayName(hello.appVersion, maxLength: 32,
                                                                                   fallback: "unknown"),
                                            fingerprint: fingerprint,
                                            fingerprintDisplay: DeviceIdentity.display(fingerprint),
                                            remoteAddress: router.connection.remoteAddress,
                                            accessibilityGranted: accessibilityGranted)
            state = .awaitingApproval(request)
            scheduleTimeout(configuration.approvalTimeout, for: router) { $0.approvalTimedOut() }
            Log.session.notice("Connection request awaiting operator approval")
        case .accept(let hello):
            startSession(router, hello: hello)
        case .fallbackToPrompt(let hello):
            // Tell the Viewer its password is not being used (a proof may still be in flight and will be ignored),
            // so it shows "waiting for approval" and never treats the operator's Allow as a password login.
            router.connection.sendControl(.passwordResponse(.none))
            Log.session.notice("Password check ended without the password; prompting")
            execute(.requestApproval(hello), for: router)
        case .sendChallenge(let challenge):
            router.connection.sendControl(.passwordChallenge(challenge))
            scheduleTimeout(configuration.passwordTimeout, for: router) { $0.passwordTimedOut() }
            Log.session.notice("Password challenge sent")
        case .passwordAccepted(let hello):
            passwordLimiter.recordSuccess(fingerprint: router.connection.peerFingerprint ?? Data(),
                                          nowNanos: MonotonicClock.nowNanos())
            Log.session.notice("Password accepted")
            startSession(router, hello: hello, viaPassword: true)
        case .resumeAccepted(let hello):
            let fingerprint = router.connection.peerFingerprint ?? Data()
            guard let resumed = grace.consume(), resumed.fingerprint == fingerprint else {
                // Revoked between AUTH and now: busy makes the Viewer retry, and the retry is prompted.
                end(router, deny: (.busy, "The previous session can no longer be resumed"), message: nil)
                return
            }
            graceExpiryTask?.cancel()
            graceExpiryTask = nil
            reconnectGrace = nil
            Log.session.notice("Viewer reconnected within the grace window; resuming without a prompt")
            startSession(router, hello: hello, viaPassword: resumed.viaPassword, resuming: resumed)
            if isSharing {
                reconnectedNotice = ReconnectedNotice(peerName: SessionSupport.displayName(hello.deviceName))
            }
        case .deny(.authFailed, let message):
            recordPasswordFailure(router)
            Log.session.notice("Denying connection: wrong password")
            end(router, deny: (.authFailed, message), message: lastPasswordFailure)
        case .deny(let reason, let message):
            Log.session.notice("Denying connection: \(String(describing: reason), privacy: .public)")
            // An operator Deny or an unanswered prompt starts the cooldown for this identity.
            if case .awaitingApproval(let request) = state, reason == .userDenied || reason == .timeout {
                rememberDenied(request.fingerprint)
            }
            end(router, deny: (reason, message), message: message)
        case .close(let reason):
            Log.session.notice("Closing connection: protocol violation")
            end(router, close: reason, message: "The Viewer violated the protocol")
        }
    }

    private func recordPasswordFailure(_ router: HostConnectionRouter) {
        let address = SessionSupport.hostPart(of: router.connection.remoteAddress)
        passwordLimiter.recordFailure(fingerprint: router.connection.peerFingerprint ?? Data(), address: address,
                                      nowNanos: MonotonicClock.nowNanos())
        passwordFailureCount += 1
        let name = handshake?.hello.map { SessionSupport.displayName($0.deviceName) } ?? "Unknown Mac"
        lastPasswordFailure = "Wrong password from \(address) (\(name))"
    }

    // MARK: Session

    private func startSession(_ router: HostConnectionRouter, hello: Hello, viaPassword: Bool = false,
                              resuming: ReconnectGrace.Entry? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        // The arrangement, main display or scaled resolution may have changed since the list was read; capture and
        // input mapping must both start from the current CoreGraphics geometry.
        refreshDisplays()
        let sessionId: UInt32
        let token: Data
        let pipeline: HostMediaPipeline
        let sink: any InputSink
        let source: any VideoSource
        do {
            sessionId = try SecureRandom.sessionId()
            // The token carries this Host's capabilities (see `PeerCapabilities`); still 88 random bits.
            var capabilities: PeerCapabilities = []
            if allowsReconnectWithoutPrompt { capabilities.insert(.sessionResume) }
            if configuration.clipboardSharing { capabilities.insert(.clipboard) }
            if configuration.cursorShapes { capabilities.insert(.cursorShape) }
            token = Accept.sessionToken(capabilities: capabilities, random: try SecureRandom.sessionToken())
            let adaptation = sessionAdaptation
            let captureConfig = HostMediaPipeline.initialCaptureConfig(base: configuration.capture,
                                                                       adaptation: adaptation)
            source = try dependencies.makeVideoSource(selectedDisplay, captureConfig)
            var pipelineConfig = HostMediaPipeline.Configuration(sessionId: sessionId, baseCapture: configuration.capture,
                                                                 adaptation: adaptation,
                                                                 adaptationEnabled: configuration.adaptationEnabled,
                                                                 displayPointSize: source.displayFrame.size)
            pipelineConfig.duplicateKeyframePackets = configuration.duplicateKeyframePackets
            pipelineConfig.fec = configuration.forwardErrorCorrection
            pipelineConfig.sendQueueBudgetMillis = configuration.sendQueueBudgetMillis
            pipeline = try HostMediaPipeline(configuration: pipelineConfig, source: source, transport: router.connection)
            sink = dependencies.makeInputSink(source.displayFrame)
        } catch {
            lastError = "Could not start sharing: \(error)"
            end(router, deny: (.permissionsMissing, "The Host could not start screen sharing"), message: lastError)
            return
        }

        refreshPermissions()
        let viewOnly = !accessibilityGranted
        router.connection.sendControl(.accept(Accept(sessionId: sessionId, sessionToken: token, hostName: deviceName)))
        sink.updateDisplayFrame(source.displayFrame)
        sink.setAuthorized(!viewOnly)
        router.activate(pipeline: pipeline, sink: sink)
        self.pipeline = pipeline
        self.inputSink = sink
        isViewOnly = viewOnly
        metricsTicks = 0

        let remote = router.connection.remoteAddress
        let path = SessionSupport.pathLabel(forHost: SessionSupport.hostPart(of: remote))
        pipeline.onMetrics = { [weak self] snapshot in
            onMain { [weak self] in self?.metricsArrived(snapshot, from: router, path: path) }
        }
        pipeline.onSourceStopped = { [weak self] error in
            let permissionDenied = error.map(CaptureError.isPermissionDenied) ?? false
            onMain { [weak self] in self?.sourceStopped(router, permissionDenied: permissionDenied) }
        }
        let peer = HostPeer(name: SessionSupport.displayName(hello.deviceName), fingerprintDisplay: DeviceIdentity.display(router.connection.peerFingerprint ?? Data()),
                            remoteAddress: remote, sessionId: sessionId, startedAt: resuming?.sessionStartedAt ?? Date(),
                            isViewOnly: viewOnly, viaPassword: viaPassword, resumed: resuming != nil)
        state = .active(peer)
        isPeerSilent = false
        startClipboard(router)
        startCursorShape(router)
        observeScreenChanges(router)
        Log.session.notice("Session started (view-only: \(viewOnly, privacy: .public), via password: \(viaPassword, privacy: .public))")

        Task { [weak self] in
            do {
                try await pipeline.start()
            } catch {
                let permissionDenied = CaptureError.isPermissionDenied(error)
                let description = String(describing: error)
                self?.pipelineFailed(router, permissionDenied: permissionDenied, description: description)
            }
        }
    }

    /// Starts clipboard sharing for the new session if both sides speak it (after ACCEPT went out, so the Viewer reads
    /// CLIPBOARD_STATE in a streaming session).
    private func startClipboard(_ router: HostConnectionRouter) {
        clipboard?.stop()
        clipboard = nil
        refreshPasteboardAccess()
        guard configuration.clipboardSharing, router.peerCapabilities.contains(.clipboard) else {
            clipboardStatus = ClipboardSyncStatus(peerSupports: false, localEnabled: allowsClipboardSharing)
            return
        }
        let channel = ClipboardChannel(pasteboard: dependencies.makePasteboard(), transport: router.connection,
                                       localEnabled: allowsClipboardSharing, baselineAtStart: true,
                                       pollInterval: configuration.clipboardPollInterval) { [weak self, weak router] status in
            guard let self, let router, router === self.current else { return }
            self.clipboardStatus = status
            if status.accessDenied { self.refreshPasteboardAccess() }
        }
        clipboard = channel
        channel.start()
        if router.connection.isSideStreamOpen { channel.sideStreamReady() }
    }

    /// Starts pointer-shape sharing for the new session if the Viewer speaks it (after ACCEPT, like the clipboard).
    private func startCursorShape(_ router: HostConnectionRouter) {
        cursorChannel?.stop()
        cursorChannel = nil
        guard configuration.cursorShapes, router.peerCapabilities.contains(.cursorShape) else {
            cursorShapeStatus = CursorShapeStatus(peerSupports: false, enabled: sharesPointerShape)
            return
        }
        let channel = CursorShapeChannel(source: dependencies.makeCursorSource(), transport: router.connection,
                                         enabled: sharesPointerShape,
                                         pollInterval: configuration.cursorPollInterval) { [weak self, weak router] status in
            guard let self, let router, router === self.current else { return }
            self.cursorShapeStatus = status
        }
        cursorChannel = channel
        if router.connection.isSideStreamOpen { channel.sideStreamReady() }
        channel.start()
    }

    /// Display reconfiguration during a session (resolution, arrangement, main display): input must follow the
    /// display's new bounds, as capture does. AppKit posts the notification on the main thread.
    private func observeScreenChanges(_ router: HostConnectionRouter) {
        stopObservingScreenChanges()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self, weak router] _ in
            MainActor.assumeIsolated {
                guard let self, let router else { return }
                self.screenParametersChanged(router)
            }
        }
    }

    private func stopObservingScreenChanges() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func screenParametersChanged(_ router: HostConnectionRouter) {
        guard router === current, router.isActive else { return }
        refreshDisplays()
        guard let pipeline else { return }
        // Capture keeps its configured size until told; re-fit the stream (and CONFIG's display size) to the display.
        pipeline.displayChanged()
        let frame = pipeline.source.displayFrame
        guard !frame.isEmpty else { return }
        inputSink?.updateDisplayFrame(frame)
        Log.session.info("Display parameters changed; input mapping and stream updated")
    }

    private func metricsArrived(_ snapshot: MetricsSnapshot, from router: HostConnectionRouter, path: String) {
        guard router === current, router.isActive else { return }
        var m = snapshot
        m.pathDescription = path
        metrics = m
        metricsTicks &+= 1
        // Accessibility can be revoked mid-session; re-check every ~2 s and drop to view-only (releasing keys).
        if metricsTicks % 4 == 0, !isViewOnly, !dependencies.permissions.accessibilityGranted() {
            isViewOnly = true
            accessibilityGranted = false
            inputSink?.setAuthorized(false)
            if case .active(var peer) = state {
                peer.isViewOnly = true
                state = .active(peer)
            }
            Log.session.notice("Accessibility revoked; session is now view-only")
        }
    }

    private func sourceStopped(_ router: HostConnectionRouter, permissionDenied: Bool) {
        guard router === current else { return }
        let revoked = permissionDenied || !dependencies.permissions.screenRecordingGranted()
        if revoked { screenRecordingGranted = false }
        end(router, close: revoked ? .permissionRevoked : .hostStopped,
            message: revoked ? "Screen Recording permission was revoked" : "Screen capture stopped")
    }

    private func pipelineFailed(_ router: HostConnectionRouter, permissionDenied: Bool, description: String) {
        guard router === current else { return }
        lastError = "Screen capture failed: \(description)"
        let revoked = permissionDenied || !dependencies.permissions.screenRecordingGranted()
        end(router, close: revoked ? .permissionRevoked : .hostStopped, message: lastError)
    }

    /// The single teardown path: stop routing, deauthorize input (releases held keys/buttons), DENY or DISCONNECT,
    /// stop capture/encode in the background, back to listening.
    private func end(_ router: HostConnectionRouter, close reason: DisconnectReason? = nil,
                     deny: (DenyReason, String)? = nil, message: String?) {
        guard router === current else { return }
        current = nil
        handshake = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        stopObservingScreenChanges()
        clipboard?.stop()
        clipboard = nil
        clipboardStatus = .inactive
        cursorChannel?.stop()
        cursorChannel = nil
        cursorShapeStatus = .inactive

        let (activePipeline, activeSink) = router.deactivate()
        activeSink?.setAuthorized(false)
        if let deny {
            HostConnectionRouter.reject(router.connection, reason: deny.0, message: deny.1)
        } else {
            router.connection.close(reason: reason)
        }
        if let activePipeline {
            let id = UUID()
            stoppingTasks[id] = Task { [weak self] in
                await activePipeline.stop()
                self?.stoppingTasks[id] = nil
            }
        }
        pipeline = nil
        inputSink = nil
        isViewOnly = false
        isPeerSilent = false
        reconnectedNotice = nil
        metrics = MetricsSnapshot()
        lastEndReason = message
        if listener != nil {
            state = listenerPort.map { .listening(port: $0) } ?? .starting
        } else {
            state = .idle
        }
        Log.session.notice("Session ended")
    }

    /// Waits until capture/encode of ended sessions has fully stopped (tests, app termination).
    public func waitForTeardown() async {
        while let task = stoppingTasks.values.first {
            await task.value
        }
    }

    private func scheduleTimeout(_ duration: Duration, for router: HostConnectionRouter,
                                 _ fire: @escaping @MainActor (inout HostHandshake) -> HostHandshake.Effect?) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, router === self.current, var handshake = self.handshake else { return }
            let effect = fire(&handshake)
            self.handshake = handshake
            if let effect { self.execute(effect, for: router) }
        }
    }
}

extension HostSession {
    static func nanos(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        let value = Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9
        return value <= 0 ? 0 : UInt64(min(value, 1e18))
    }
}

public enum HostSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDisplay

    public var description: String {
        switch self {
        case .noDisplay: "No display is available to share"
        }
    }
}
