import AppKit
import DiagnosticsCore
import Foundation
import InputCore
import SessionCore
import SwiftUI
import Testing
@testable import AppUI

/// Builds each screen in an `NSHostingView` (no window: RenderCore's test rule) and forces layout, so every view
/// body runs at least once against real session objects. Catches runtime traps in view code that type checking
/// cannot (bad ranges, force unwraps, invalid grid layouts).
@MainActor
@Suite("View smoke tests", .serialized)
struct ViewSmokeTests {
    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 1100, height: 760)) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        return hosting
    }

    @Test func rootViewRendersEveryRole() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() })
        for role in [nil] + AppRole.allCases.map(Optional.some) {
            model.selectedRole = role
            if let role { model.prepare(role) }
            let hosting = render(RootView(model: model))
            #expect(hosting.fittingSize.width > 0, "role \(String(describing: role))")
        }
    }

    @Test func rootViewShowsSetupErrors() {
        let model = AppModel(makeHost: { throw SetupFailure() }, makeViewer: { throw SetupFailure() })
        model.selectedRole = .host
        model.prepare(.host)
        _ = render(RootView(model: model))
        #expect(model.hostSetupError != nil)
    }

    @Test func approvalSheetRendersWithAndWithoutAccessibility() {
        for accessibility in [true, false] {
            let request = ConnectionRequest(peerName: "Viewer", appVersion: "1.0", fingerprint: Data(count: 32),
                                            fingerprintDisplay: "0000 0000", remoteAddress: "10.0.0.3:5000",
                                            accessibilityGranted: accessibility)
            let hosting = render(ApprovalSheet(request: request, timeout: .seconds(60), approve: {}, deny: {},
                                               openAccessibilitySettings: {}),
                                 size: CGSize(width: 500, height: 520))
            #expect(hosting.fittingSize.height > 0)
        }
    }

    @Test func verificationSheetRenders() {
        for firstTime in [true, false] {
            let prompt = HostIdentityPrompt(host: "fd7a::1", port: 47800, fingerprintDisplay: "0000 0000 0000 0000",
                                            fingerprintDisplayFull: String(repeating: "00", count: 32),
                                            firstTime: firstTime)
            let hosting = render(HostVerificationSheet(prompt: prompt, trust: { _ in }, cancel: {}),
                                 size: CGSize(width: 520, height: 460))
            #expect(hosting.fittingSize.height > 0)
        }
    }

    @Test func activeBannerAndStripRender() {
        let peer = HostPeer(name: "Viewer", fingerprintDisplay: "0000", remoteAddress: "10.0.0.3:5000", sessionId: 1,
                            startedAt: Date(), isViewOnly: true)
        _ = render(ActiveSharingBanner(peer: peer, stop: {}), size: CGSize(width: 700, height: 90))
        _ = render(SharingStrip(peer: peer, stop: {}, show: {}), size: CGSize(width: 700, height: 40))
        var viaPassword = peer
        viaPassword.viaPassword = true
        _ = render(ActiveSharingBanner(peer: viaPassword, stop: {}), size: CGSize(width: 700, height: 90))
        _ = render(SharingStrip(peer: viaPassword, stop: {}, show: {}), size: CGSize(width: 700, height: 40))
    }

    @Test func hostViewRendersThePasswordSection() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let access = HostAccessPassword(store: InMemorySecretStore(), iterations: 100_000)
        for configured in [false, true] {
            if configured { try access.set(password: "smoke test 1") }
            let host = env.makeHost(accessPassword: access)
            #expect(host.supportsPasswordAccess)
            #expect(host.passwordAccessEnabled == configured)
            let hosting = render(HostView(host: host, startListeningAtLaunch: .constant(configured),
                                          streamQuality: .constant(configured ? .balanced : .sharp),
                                          allowsReconnectWithoutPrompt: .constant(!configured),
                                          allowsClipboardSharing: .constant(configured),
                                          sharesPointerShape: .constant(!configured),
                                          loginItem: LoginItemController(service: FakeLoginItemService(),
                                                                         defaults: env.defaults)),
                                 size: CGSize(width: 900, height: 1600))
            #expect(hosting.fittingSize.height > 0)
        }
    }

    /// Host › Startup (0.1.9) in every Login Items state, with the approval row and each kind of note.
    @Test func hostViewRendersTheStartupSection() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let host = env.makeHost()
        let cases: [(LoginItemStatus, String, Bool)] = [
            (.notRegistered, "/Applications/SwiftDesk.app", false),
            (.enabled, "/Applications/SwiftDesk.app", true),
            (.requiresApproval, "/Applications/SwiftDesk.app", true),
            (.notFound, "/Users/tester/code/.build/debug", false),
            (.enabled, NSHomeDirectory() + "/Downloads/SwiftDesk.app", true),
        ]
        for (status, path, listens) in cases {
            let service = FakeLoginItemService(status: status, bundleURL: URL(fileURLWithPath: path))
            let controller = LoginItemController(service: service, defaults: env.defaults)
            let hosting = render(HostView(host: host, startListeningAtLaunch: .constant(listens),
                                          streamQuality: .constant(.sharp),
                                          allowsReconnectWithoutPrompt: .constant(true),
                                          allowsClipboardSharing: .constant(true),
                                          sharesPointerShape: .constant(true),
                                          loginItem: controller),
                                 size: CGSize(width: 900, height: 1800))
            #expect(hosting.fittingSize.height > 0, "\(status)")
        }
        _ = render(LoginItemApprovalRow(open: {}), size: CGSize(width: 700, height: 60))
        for tone in [LoginItemPresentation.NoteTone.info, .warning] {
            _ = render(LoginItemNoteRow(note: "SwiftDesk is running from ~/Downloads.", tone: tone),
                       size: CGSize(width: 700, height: 40))
        }
    }

    @Test func clipboardRowsRenderInEveryState() {
        let notice = ClipboardNotice(kind: .tooLarge(bytes: 20 << 20, limit: 16 << 20))
        let states = [
            ClipboardSyncStatus.inactive,
            ClipboardSyncStatus(peerSupports: true, peerEnabled: true, localEnabled: true),
            ClipboardSyncStatus(peerSupports: true, peerEnabled: false, localEnabled: true, notice: notice),
            ClipboardSyncStatus(peerSupports: true, peerEnabled: true, localEnabled: true, accessDenied: true,
                                notice: ClipboardNotice(kind: .accessDenied)),
        ]
        for status in states {
            _ = render(ClipboardSessionRow(status: status, peerName: "Viewer Mac", isOn: .constant(status.localEnabled)),
                       size: CGSize(width: 700, height: 60))
        }
        for behavior in [PasteboardAccessBehavior.ask, .alwaysDeny] {
            let hint = ClipboardPresentation.accessHint(behavior, denied: false) ?? ""
            _ = render(PasteboardAccessHint(message: hint, blocked: behavior == .alwaysDeny),
                       size: CGSize(width: 700, height: 60))
        }
    }

    @Test func sendKeysMenuAndPermissionHintRender() {
        let items = render(Menu("Send Keys") { SendKeysMenuItems(send: { _ in }) }, size: CGSize(width: 200, height: 40))
        #expect(items.fittingSize.width > 0)
        for status in [SystemShortcutCaptureStatus.needsPermission, .unavailable] {
            let hint = ShortcutPresentation.permissionHint(status) ?? ""
            _ = render(ShortcutPermissionHint(message: hint, request: {}, openSettings: {}),
                       size: CGSize(width: 700, height: 60))
            _ = render(ShortcutPermissionCapsule(text: ShortcutPresentation.streamNote(status) ?? "", allow: {},
                                                 openSettings: {}, dismiss: {}),
                       size: CGSize(width: 700, height: 60))
        }
    }

    @Test func diagnosticsAndMetricsRenderForBothRoles() {
        var metrics = MetricsSnapshot()
        metrics.width = 1280
        metrics.height = 720
        metrics.decodeToPresent = RollingStats.summarize([2, 3, 4, 5])
        for role in [MetricsRole.host, .viewer] {
            _ = render(DiagnosticsGrid(metrics: metrics, role: role), size: CGSize(width: 400, height: 600))
            _ = render(LiveMetricsGrid(metrics: metrics, role: role), size: CGSize(width: 700, height: 200))
        }
    }

    /// Address book (0.1.8): the connect screen with Favorites and Recent, every card state, and the menus.
    @Test func addressBookRendersOnTheConnectScreen() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let book = AddressBookStore(directory: env.addressBookFolder)
        let favorite = book.recordConnection(host: "studio.local", port: 47800, fingerprint: Data(repeating: 1, count: 32),
                                             hostName: "Studio")
        book.recordConnection(host: "100.64.0.1", port: 47800, fingerprint: Data(repeating: 1, count: 32),
                              hostName: "Studio")
        book.setFavorite(id: favorite.id, true)
        let recent = book.recordConnection(host: "fd7a::2", port: 5000, fingerprint: Data(repeating: 2, count: 32),
                                           hostName: "Mac mini")
        // A real (tiny) JPEG thumbnail.
        let image = NSImage(size: NSSize(width: 32, height: 20), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let jpeg = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        #expect(book.saveThumbnail(jpeg, for: recent.id))

        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer(addressBook: book) },
                             defaults: env.defaults)
        model.selectedRole = .viewer
        model.prepare(.viewer)
        #expect(model.viewer?.savedHosts.count == 2)
        let hosting = render(RootView(model: model), size: CGSize(width: 1100, height: 1800))
        #expect(hosting.fittingSize.height > 0)

        let entries = try #require(model.viewer?.savedHosts)
        for entry in entries {
            for pin in [SavedHostPinState.pinned, .unpinned, .pinnedToOtherIdentity] {
                _ = render(SavedHostCard(entry: entry, thumbnailURL: book.thumbnailURL(for: entry), pinState: pin,
                                         now: Date(), connect: { _ in }, rename: {}, toggleFavorite: {}, remove: {}),
                           size: CGSize(width: 220, height: 200))
            }
        }
        _ = render(Menu("Connect To") { QuickConnectMenuItems(model: model) }, size: CGSize(width: 200, height: 40))
        _ = render(SharingMenuContent(model: model), size: CGSize(width: 300, height: 260))
    }

    /// Review 0.2.0: the stream toolbar adapts to the window, so it fits the 800 pt 1:1 window of a 1600×900 Host on
    /// a Retina Viewer and the 480 pt streaming minimum, with a long Host name and the widest realistic numbers.
    @Test func streamToolbarFitsNarrowWindows() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let viewer = env.makeViewer()
        let info = ViewerSession.StreamInfo(hostName: "Isabella's MacBook Pro (Studio, 3rd floor)",
                                            remoteAddress: "[fd7a:115c:a1e0::1234:5678]:47800", sessionId: 1,
                                            hostFingerprintDisplay: "AB:CD", isTrusted: true)
        var metrics = MetricsSnapshot()
        metrics.fps = 120
        metrics.bitrateKbps = 12_345
        metrics.packetLossPercent = 12.5
        metrics.width = 3456
        metrics.height = 2234
        metrics.decodeToPresent = RollingStats.summarize([12, 13, 14, 15])
        var clipboard = true, pointer = true, shortcuts = false, diagnostics = false
        let toolbar = StreamToolbar(viewer: viewer, info: info,
                                    sharesClipboard: Binding(get: { clipboard }, set: { clipboard = $0 }),
                                    showsRemotePointer: Binding(get: { pointer }, set: { pointer = $0 }),
                                    sendsSystemShortcuts: Binding(get: { shortcuts }, set: { shortcuts = $0 }),
                                    sendShortcut: { _ in },
                                    showDiagnostics: Binding(get: { diagnostics }, set: { diagnostics = $0 }),
                                    actualSize: {}, metricsOverride: metrics)
        let controller = NSHostingController(rootView: toolbar)
        for width in [1600.0, 1100, 800, 640, 480] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 200))
            #expect(size.width <= width, "toolbar needs \(size.width) pt at \(width) pt")
            _ = render(toolbar, size: CGSize(width: width, height: 52))
        }
        // The narrowest row alone, measured at its smallest: it is what sets the window's minimum width.
        let minimal = NSHostingController(rootView: toolbar.row(.minimal).padding(.horizontal, 12))
        let smallest = minimal.sizeThatFits(in: CGSize(width: 1, height: 200))
        #expect(smallest.width <= 480, "minimal row needs \(smallest.width) pt")
    }

    @Test func menuBarContentRenders() throws {
        let env = try TestEnvironment()
        defer { env.cleanUp() }
        let model = AppModel(makeHost: { env.makeHost() }, makeViewer: { env.makeViewer() })
        model.prepare(.host)
        _ = render(SharingMenuContent(model: model), size: CGSize(width: 300, height: 260))
    }
}
