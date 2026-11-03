import AppKit
import CaptureCore
import Foundation
import InputCore
import SessionCore
import SwiftUI
import Synchronization
import Testing
import TransportCore
import WireProtocol
@testable import AppUI

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// `InputSink` that only counts; the Host never needs Accessibility in tests.
final class CountingInputSink: InputSink, @unchecked Sendable {
    private let state = Mutex<(messages: Int, authorized: Bool)>((0, false))
    func handle(_ message: ControlMessage) { state.withLock { $0.messages += 1 } }
    func handlePointer(_ state: PointerState) {}
    func setAuthorized(_ authorized: Bool) { state.withLock { $0.authorized = authorized } }
    func updateDisplayFrame(_ frame: CGRect) {}
    func releaseAll() {}
    var canInject: Bool { state.withLock { $0.authorized } }
}

/// Keyboard tap stand-in: UI tests never take the real keyboard or ask for Accessibility (0.1.7).
@MainActor
final class InertShortcutTap: SystemShortcutTapping {
    private(set) var isInstalled = false
    func install() -> Bool {
        isInstalled = true
        return true
    }
    func remove() { isInstalled = false }
}

/// Keychain identities with unique labels plus a private defaults suite, removed by `cleanUp()`.
final class TestEnvironment: @unchecked Sendable {
    let host: DeviceIdentity
    let viewer: DeviceIdentity
    let suiteName = "SwiftDesk.AppUITests.\(UUID().uuidString)"
    let defaults: UserDefaults
    private let labels: [String]

    init() throws {
        let suffix = UUID().uuidString
        labels = ["SwiftDesk AppUITest Host \(suffix)", "SwiftDesk AppUITest Viewer \(suffix)"]
        host = try DeviceIdentity.loadOrCreate(label: labels[0])
        viewer = try DeviceIdentity.loadOrCreate(label: labels[1])
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        for label in labels { try? DeviceIdentity.delete(label: label) }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: addressBookFolder)
    }

    @MainActor
    func makeHost(accessPassword: HostAccessPassword? = nil) -> HostSession {
        var config = HostSession.Configuration()
        config.port = 0
        config.advertiseBonjour = false
        config.deviceName = "UI Test Host"
        config.rateLimiter = ConnectionRateLimiter(perAddressPerMinute: 1000, globalPerMinute: 1000)
        let deps = HostSession.Dependencies(
            identity: host,
            permissions: PermissionChecker(screenRecordingGranted: { true }, accessibilityGranted: { true }),
            makeVideoSource: { _, capture in SyntheticVideoSource(sourceWidth: 1280, sourceHeight: 720, config: capture) },
            makeInputSink: { _ in CountingInputSink() },
            accessPassword: accessPassword)
        return HostSession(configuration: config, dependencies: deps)
    }

    /// A temporary folder for an address book (0.1.8), removed by `cleanUp()`; never Application Support.
    lazy var addressBookFolder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftDesk.AppUITests.\(UUID().uuidString)", isDirectory: true)

    @MainActor
    func makeViewer(addressBook: AddressBookStore? = nil) -> ViewerSession {
        var config = ViewerSession.Configuration()
        config.deviceName = "UI Test Viewer"
        config.establishmentTimeout = 8
        return ViewerSession(identity: viewer, trustStore: TrustedHostStore(defaults: defaults),
                             savedPasswords: SavedHostPasswords(store: InMemorySecretStore()),
                             addressBook: addressBook, configuration: config,
                             shortcutPermission: { _ in true }, makeShortcutTap: { _, _ in InertShortcutTap() })
    }
}

struct SetupFailure: Error, CustomStringConvertible {
    var description: String { "keychain locked" }
}

@MainActor
@Suite("AppModel", .serialized)
struct AppModelTests {
    @Test func sessionsAreCreatedLazilyPerRole() throws {
        let created = Mutex<[String]>([])
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let model = AppModel(makeHost: { created.withLock { $0.append("host") }; return env.makeHost() },
                             makeViewer: { created.withLock { $0.append("viewer") }; return env.makeViewer() })
        #expect(model.host == nil)
        #expect(model.viewer == nil)
        model.prepare(.loopback)
        #expect(created.withLock { $0 }.isEmpty)
        model.prepare(.host)
        model.prepare(.host)
        #expect(created.withLock { $0 } == ["host"])
        model.prepare(.viewer)
        #expect(created.withLock { $0 } == ["host", "viewer"])
        #expect(model.host != nil && model.viewer != nil)
    }

    @Test func setupFailureIsReportedAndRetryable() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let shouldFail = Mutex(true)
        let model = AppModel(makeHost: {
            if shouldFail.withLock({ $0 }) { throw SetupFailure() }
            return env.makeHost()
        })
        model.prepare(.host)
        #expect(model.host == nil)
        #expect(model.hostSetupError?.contains("keychain locked") == true)
        shouldFail.withLock { $0 = false }
        model.retrySetup(.host)
        #expect(model.host != nil)
        #expect(model.hostSetupError == nil)
    }

    @Test func idleModelHasNoLiveSessionsAndNoAssertion() {
        let model = AppModel(makeHost: { throw SetupFailure() }, makeViewer: { throw SetupFailure() })
        #expect(!model.hasLiveSessions)
        #expect(!model.isHostSharing && !model.isViewerStreaming && !model.isLoopbackRunning)
        #expect(model.menuBarStatus.title == "Not sharing")
        #expect(model.heldActivityOptions == nil)
    }

    @Test func listeningHostCountsAsLiveAndShutdownStopsIt() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() })
        let host = try #require(model.ensureHost())
        host.startListening()
        #expect(await eventually { if case .listening = host.state { true } else { false } })
        #expect(model.hasLiveSessions)
        #expect(model.menuBarStatus.symbol == Symbols.listening)
        await model.shutdown(timeout: .seconds(2))
        #expect(host.state == .idle)
        #expect(!model.hasLiveSessions)
    }

    @Test func waitAtMostReturnsAfterTimeoutEvenIfWorkHangs() async {
        let start = ContinuousClock.now
        await AppModel.waitAtMost(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(30))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func waitAtMostReturnsAsSoonAsWorkFinishes() async {
        let start = ContinuousClock.now
        await AppModel.waitAtMost(.seconds(30)) {}
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// Full Host ↔ Viewer session over QUIC on 127.0.0.1 (synthetic video, counting input sink), driven through the
    /// same AppModel the app uses: request → attention → approve → sharing indicator + power assertion → shutdown.
    @Test(.timeLimit(.minutes(2)))
    func activeSessionDrivesIndicatorAssertionAndShutdown() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() })
        let host = try #require(model.ensureHost())
        let viewer = try #require(model.ensureViewer())

        host.startListening()
        #expect(await eventually { if case .listening = host.state { true } else { false } })
        guard case .listening(let port) = host.state else { return }

        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "viewer: \(viewer.state)")
        guard case .verifyingHost(let verification) = viewer.state else { await model.shutdown(); return }
        // What the Viewer's user is asked to compare is exactly what the Host screen shows.
        #expect(verification.fingerprintDisplay == host.fingerprintDisplay)
        #expect(ViewerPhase.make(viewer.state) == .verifying(verification))
        #expect(HostIdentityPrompt(verification).fingerprintDisplay == host.fingerprintDisplay)

        viewer.trustHost(remember: false)
        #expect(await eventually { host.pendingRequest != nil }, "host: \(host.state)")
        #expect(model.menuBarStatus.tone == .attention)
        // A request selects the Host screen so the approval sheet is visible.
        #expect(await eventually { model.selectedRole == .host })

        host.approve()
        #expect(await eventually { viewer.isStreaming && host.isSharing }, "viewer: \(viewer.state) host: \(host.state)")
        #expect(model.isHostSharing && model.isViewerStreaming)
        if case .streaming(let info) = viewer.state {
            #expect(ViewerPhase.make(viewer.state) == .streaming(info))
            #expect(info.hostName == "UI Test Host")
        }
        #expect(model.menuBarStatus.tone == .sharing)
        #expect(model.menuBarStatus.title == "Sharing this Mac with UI Test Viewer")

        // Send Keys (0.1.7): ordinary items go straight to the Host; Lock Screen waits for confirmation.
        model.send(.spotlight)
        #expect(model.pendingShortcut == nil)
        model.send(.lockScreen)
        #expect(model.pendingShortcut == .lockScreen)
        model.pendingShortcut = nil
        model.confirmPendingShortcut()
        model.send(.lockScreen)
        model.confirmPendingShortcut()
        #expect(model.pendingShortcut == nil)
        #expect(await eventually { model.heldActivityOptions?.contains(.idleDisplaySleepDisabled) == true })
        #expect(model.hasLiveSessions)

        await model.shutdown(timeout: .seconds(3))
        #expect(host.state == .idle)
        if case .disconnected = viewer.state {} else { Issue.record("viewer not disconnected: \(viewer.state)") }
        #expect(!model.hasLiveSessions)
        #expect(await eventually { model.heldActivityOptions == nil })
    }

    /// 0.1.7 "Send system shortcuts": off by default, persisted, pushed to the Viewer session (live).
    @Test func systemShortcutSettingIsPersistedAndApplied() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(!first.viewerSendsSystemShortcuts)
        let viewer = try #require(first.ensureViewer())
        #expect(!viewer.sendsSystemShortcuts)
        #expect(viewer.systemShortcutStatus == .off)

        first.viewerSendsSystemShortcuts = true
        #expect(viewer.sendsSystemShortcuts)
        #expect(viewer.systemShortcutStatus == .standby, "allowed, but not controlling a session")
        #expect(env.defaults.object(forKey: AppModel.viewerSendSystemShortcutsKey) as? Bool == true)
        #expect(AppModel.viewerSendSystemShortcutsKey == "SwiftDesk.viewer.sendSystemShortcuts")
        // Outside a session Send Keys does nothing and asks nothing.
        first.send(.lockScreen)
        #expect(first.pendingShortcut == nil)

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(relaunched.viewerSendsSystemShortcuts)
        #expect(relaunched.ensureViewer()?.sendsSystemShortcuts == true)
    }

    /// Viewer › Connection › "Save thumbnails of remote screens" (0.1.8): on by default, persisted, pushed to the
    /// Viewer session; switching it off deletes saved thumbnails.
    @Test func saveThumbnailsIsPersistedAndApplied() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let book = AddressBookStore(directory: env.addressBookFolder)
        let entry = book.recordConnection(host: "studio.local", port: 47800, fingerprint: Data(repeating: 1, count: 32),
                                          hostName: "Studio")
        #expect(book.saveThumbnail(Data([0xFF, 0xD8, 0xFF]), for: entry.id))
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer(addressBook: book) },
                             defaults: env.defaults)
        #expect(first.viewerSavesThumbnails)
        let viewer = try #require(first.ensureViewer())
        #expect(viewer.savesThumbnails)
        #expect(viewer.savedHosts.first?.hasThumbnail == true)

        first.viewerSavesThumbnails = false
        #expect(!viewer.savesThumbnails)
        #expect(viewer.savedHosts.first?.hasThumbnail == false, "turning it off deletes the pictures")
        #expect(viewer.savedHosts.count == 1, "the entries stay")
        #expect(env.defaults.object(forKey: AppModel.viewerSaveThumbnailsKey) as? Bool == false)
        #expect(AppModel.viewerSaveThumbnailsKey == "SwiftDesk.viewer.saveThumbnails")

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer(addressBook: book) },
                                  defaults: env.defaults)
        #expect(!relaunched.viewerSavesThumbnails)
        #expect(relaunched.ensureViewer()?.savesThumbnails == false)
    }

    /// Address book quick connect (0.1.8): the Session menu / menu-bar list and `connect(to:)`.
    @Test func quickConnectDialsASavedHost() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let book = AddressBookStore(directory: env.addressBookFolder)
        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer(addressBook: book) },
                             defaults: env.defaults, addressBook: book)
        #expect(!model.canQuickConnect, "an empty address book")
        #expect(model.quickConnectHosts().favorites.isEmpty)

        // A Host session on loopback to dial; the entry points at it.
        let host = try #require(model.ensureHost())
        host.startListening()
        #expect(await eventually { if case .listening = host.state { true } else { false } })
        guard case .listening(let port) = host.state else { return }
        let favorite = book.recordConnection(host: "127.0.0.1", port: port, fingerprint: env.host.fingerprint,
                                             hostName: "UI Test Host")
        book.setFavorite(id: favorite.id, true)
        book.recordConnection(host: "old.local", port: 47800, fingerprint: Data(repeating: 9, count: 32),
                              hostName: "Old Mac")
        // Offered before "Control a Mac" was ever shown: no Viewer session (and no keychain access) yet.
        #expect(model.viewer == nil)
        #expect(model.canQuickConnect)
        let hosts = model.quickConnectHosts()
        #expect(hosts.favorites.map(\.id) == [favorite.id])
        #expect(hosts.recent.map(\.displayName) == ["Old Mac"])

        model.selectedRole = .host
        #expect(model.connect(to: favorite))
        let viewer = try #require(model.viewer, "created on demand")
        #expect(model.selectedRole == .viewer)
        #expect(viewer.state == .connecting(host: "127.0.0.1", port: port))
        #expect(!model.canQuickConnect, "busy while connecting")
        #expect(!model.connect(to: favorite), "never interrupts an attempt")
        // Not pinned: the user still verifies the Host's fingerprint, exactly like a typed address.
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "\(viewer.state)")
        viewer.rejectHost()
        host.stopListening()
        await host.waitForTeardown()
    }

    /// Host › Display › Quality: Sharp by default, persisted, and pushed to the Host session (now and when created).
    @Test func hostStreamQualityIsPersistedAndApplied() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(first.hostStreamQuality == .sharp)
        let host = try #require(first.ensureHost())
        #expect(host.streamQuality == .sharp)
        #expect(host.sessionAdaptation.ladder == AdaptationController.defaultLadder)
        first.hostStreamQuality = .balanced
        #expect(host.streamQuality == .balanced)
        #expect(host.sessionAdaptation.ladder == AdaptationController.balancedLadder)
        #expect(host.sessionAdaptation.maxBitrateKbps == 5000)
        #expect(env.defaults.string(forKey: AppModel.hostStreamQualityKey) == "balanced")

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(relaunched.hostStreamQuality == .balanced)
        #expect(relaunched.ensureHost()?.streamQuality == .balanced)

        env.defaults.set("ultra", forKey: AppModel.hostStreamQualityKey)
        let unknown = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(unknown.hostStreamQuality == .sharp)
    }

    /// "Start listening when SwiftDesk opens": off by default, persisted, and applied at launch.
    @Test func reconnectSettingsArePersistedAndApplied() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        // Both default to on.
        #expect(first.hostAllowsReconnectWithoutPrompt && first.viewerAutoReconnect)
        let host = try #require(first.ensureHost())
        let viewer = try #require(first.ensureViewer())
        #expect(host.allowsReconnectWithoutPrompt && viewer.autoReconnect)

        first.hostAllowsReconnectWithoutPrompt = false
        first.viewerAutoReconnect = false
        #expect(!host.allowsReconnectWithoutPrompt && !viewer.autoReconnect)
        #expect(env.defaults.object(forKey: AppModel.hostReconnectWithoutPromptKey) as? Bool == false)
        #expect(env.defaults.object(forKey: AppModel.viewerAutoReconnectKey) as? Bool == false)

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(!relaunched.hostAllowsReconnectWithoutPrompt && !relaunched.viewerAutoReconnect)
        #expect(relaunched.ensureHost()?.allowsReconnectWithoutPrompt == false)
        #expect(relaunched.ensureViewer()?.autoReconnect == false)
    }

    /// 0.1.5 clipboard switches: on by default, persisted, pushed to the sessions (live during a session).
    @Test func clipboardSettingsArePersistedAndApplied() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(first.hostAllowsClipboardSharing && first.viewerSharesClipboard)
        let host = try #require(first.ensureHost())
        let viewer = try #require(first.ensureViewer())
        #expect(host.allowsClipboardSharing && viewer.sharesClipboard)

        first.hostAllowsClipboardSharing = false
        first.viewerSharesClipboard = false
        #expect(!host.allowsClipboardSharing && !viewer.sharesClipboard)
        #expect(env.defaults.object(forKey: AppModel.hostAllowClipboardSharingKey) as? Bool == false)
        #expect(env.defaults.object(forKey: AppModel.viewerShareClipboardKey) as? Bool == false)
        #expect(AppModel.hostAllowClipboardSharingKey == "SwiftDesk.host.allowClipboardSharing")
        #expect(AppModel.viewerShareClipboardKey == "SwiftDesk.viewer.shareClipboard")

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(!relaunched.hostAllowsClipboardSharing && !relaunched.viewerSharesClipboard)
        #expect(relaunched.ensureHost()?.allowsClipboardSharing == false)
        #expect(relaunched.ensureViewer()?.sharesClipboard == false)
    }

    /// 0.1.6 pointer-shape switches: on by default, persisted, pushed to the sessions (live during a session).
    @Test func pointerShapeSettingsArePersistedAndApplied() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(first.hostSharesPointerShape && first.viewerShowsRemotePointer)
        let host = try #require(first.ensureHost())
        let viewer = try #require(first.ensureViewer())
        #expect(host.sharesPointerShape && viewer.showsRemotePointer)

        first.hostSharesPointerShape = false
        first.viewerShowsRemotePointer = false
        #expect(!host.sharesPointerShape && !viewer.showsRemotePointer)
        #expect(env.defaults.object(forKey: AppModel.hostSharePointerShapeKey) as? Bool == false)
        #expect(env.defaults.object(forKey: AppModel.viewerShowRemotePointerKey) as? Bool == false)
        #expect(AppModel.hostSharePointerShapeKey == "SwiftDesk.host.sharePointerShape")
        #expect(AppModel.viewerShowRemotePointerKey == "SwiftDesk.viewer.showRemotePointer")

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(!relaunched.hostSharesPointerShape && !relaunched.viewerShowsRemotePointer)
        #expect(relaunched.ensureHost()?.sharesPointerShape == false)
        #expect(relaunched.ensureViewer()?.showsRemotePointer == false)
    }

    @Test func startListeningAtLaunchIsPersistedAndApplied() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let first = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(!first.startListeningAtLaunch)
        first.applyLaunchPreferences()
        #expect(first.host == nil, "off: no session (and no keychain access) at launch")
        first.startListeningAtLaunch = true
        #expect(env.defaults.bool(forKey: AppModel.startListeningAtLaunchKey))

        let relaunched = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() }, defaults: env.defaults)
        #expect(relaunched.startListeningAtLaunch)
        relaunched.applyLaunchPreferences()
        let host = try #require(relaunched.host)
        #expect(await eventually { if case .listening = host.state { true } else { false } }, "host: \(host.state)")
        #expect(relaunched.selectedRole == .host)
        await relaunched.shutdown(timeout: .seconds(3))
    }

    /// A password session needs no click on the Host, so the model surfaces it: Host screen selected, menu bar
    /// "Controlled via password by …", `passwordSessionID` set (opens the window).
    @Test func passwordSessionIsSurfaced() async throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        // Production rounds: the Viewer refuses challenges below `AccessPassword.defaultIterations`.
        let access = HostAccessPassword(store: InMemorySecretStore())
        try access.set(password: "unattended 1")
        let model = AppModel(makeHost: { env.makeHost(accessPassword: access) }, makeViewer: { env.makeViewer() },
                             defaults: env.defaults)
        let host = try #require(model.ensureHost())
        let viewer = try #require(model.ensureViewer())
        host.startListening()
        #expect(await eventually { if case .listening = host.state { true } else { false } })
        guard case .listening(let port) = host.state else { return }
        viewer.trustStore.add(host: "127.0.0.1", port: port, fingerprint: env.host.fingerprint, name: "Host")
        viewer.connect(host: "127.0.0.1", port: port, password: "unattended 1")
        #expect(await eventually { viewer.isStreaming && host.isSharing }, "viewer: \(viewer.state) host: \(host.state)")
        #expect(host.pendingRequest == nil)
        #expect(model.passwordSessionID == host.activePeer?.sessionId)
        #expect(model.menuBarStatus.title == "Controlled via password by UI Test Viewer")
        #expect(model.menuBarStatus.tone == .sharing)
        await model.shutdown(timeout: .seconds(3))
        #expect(model.passwordSessionID == nil)
    }
}
