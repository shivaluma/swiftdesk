import AppKit
import CaptureCore
import CoreGraphics
import DiagnosticsCore
import Foundation
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Real `HostSession` and `ViewerSession` talking QUIC over 127.0.0.1 (TransportCore, mTLS, datagrams), with a
/// synthetic video source, a recording input sink and a recording frame sink in place of TCC-gated hardware.
@MainActor
@Suite("End-to-end loopback sessions", .serialized, .timeLimit(.minutes(3)))
struct EndToEndTests {
    /// Host + Viewer wired for one test, torn down by `close()`.
    @MainActor
    final class Harness {
        let ids: TestIdentities
        let defaults = TestDefaults()
        let sources = SourceRecorder()
        let sinks = SinkRecorder()
        let permissions = PermissionFlags()
        let host: HostSession
        let store: TrustedHostStore
        let frames = RecordingFrameSink()
        /// In-memory clipboards (never the real one): the Host's, and the one every Viewer of this harness uses.
        let hostPasteboard = FakePasteboard()
        let viewerPasteboard = FakePasteboard()
        /// The Host's pointer (never the real one).
        let hostCursor = FakeCursorSource()
        private(set) var viewers: [ViewerSession] = []

        init(accessPassword: HostAccessPassword? = nil,
             hostConfiguration: (inout HostSession.Configuration) -> Void = { _ in }) throws {
            ids = try TestIdentities()
            var config = HostSession.Configuration()
            config.port = 0
            config.advertiseBonjour = false
            config.deviceName = "Test Host"
            config.rateLimiter = ConnectionRateLimiter(perAddressPerMinute: 1000, globalPerMinute: 1000)
            config.clipboardPollInterval = .milliseconds(50)
            config.cursorPollInterval = .milliseconds(20)
            hostConfiguration(&config)
            let sources = self.sources
            let sinks = self.sinks
            let pasteboard = hostPasteboard
            let cursor = hostCursor
            let deps = HostSession.Dependencies(
                identity: ids.host,
                permissions: .dynamic(permissions),
                makeVideoSource: { _, capture in sources.make(config: capture) },
                makeInputSink: { _ in sinks.make() },
                accessPassword: accessPassword,
                makePasteboard: { pasteboard },
                makeCursorSource: { cursor })
            host = HostSession(configuration: config, dependencies: deps)
            store = TrustedHostStore(defaults: defaults.defaults)
        }

        func makeViewer(identity: DeviceIdentity? = nil, deviceName: String = "Test Viewer",
                        savedPasswords: SavedHostPasswords = SavedHostPasswords(store: InMemorySecretStore()),
                        addressBook: AddressBookStore? = nil,
                        shortcutPermission: (@MainActor (Bool) -> Bool)? = nil,
                        makeShortcutTap: SystemShortcutTapFactory? = nil,
                        configure: (inout ViewerSession.Configuration) -> Void = { _ in }) -> ViewerSession {
            var config = ViewerSession.Configuration()
            config.deviceName = deviceName
            config.establishmentTimeout = 8
            config.clipboardPollInterval = .milliseconds(50)
            configure(&config)
            let pasteboard = viewerPasteboard
            // Never the real Accessibility check or keyboard tap: a test must not prompt or take the keyboard.
            let viewer = ViewerSession(identity: identity ?? ids.viewer, trustStore: store, savedPasswords: savedPasswords,
                                       addressBook: addressBook, configuration: config, makePasteboard: { pasteboard },
                                       shortcutPermission: shortcutPermission ?? { _ in false },
                                       makeShortcutTap: makeShortcutTap ?? { _, _ in FakeShortcutTap() })
            viewers.append(viewer)
            return viewer
        }

        func startHost() async throws -> UInt16 {
            host.startListening()
            let ok = await eventually { if case .listening = self.host.state { true } else { false } }
            try #require(ok, "host did not start listening: \(host.state)")
            guard case .listening(let port) = host.state else { throw CancellationError() }
            #expect(port != 0)
            return port
        }

        func close() async {
            for viewer in viewers { viewer.disconnect() }
            host.stopListening()
            await host.waitForTeardown()
            try? await Task.sleep(nanoseconds: 100_000_000)
            ids.cleanUp()
            defaults.cleanUp()
        }
    }

    final class SinkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [RecordingInputSink] = []
        func make() -> RecordingInputSink {
            let sink = RecordingInputSink()
            lock.withLock { created.append(sink) }
            return sink
        }
        var last: RecordingInputSink? { lock.withLock { created.last } }
        var count: Int { lock.withLock { created.count } }
    }

    private func isStreaming(_ v: ViewerSession) -> Bool { v.isStreaming }

    private func disconnectedReason(_ v: ViewerSession) -> String? {
        if case .disconnected(let reason) = v.state { reason } else { nil }
    }

    /// First connection to an unpinned host: verify → trust (remembered) → approve → stream → input → disconnect.
    @Test func fullSessionStreamsVideoAndForwardsInput() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = h.makeViewer()
        viewer.attach(frameSink: h.frames)

        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "state: \(viewer.state)")
        guard case .verifyingHost(let verification) = viewer.state else { await h.close(); return }
        #expect(verification.fingerprint == h.ids.host.fingerprint)
        #expect(verification.fingerprintDisplay == h.host.fingerprintDisplay)
        #expect(verification.firstTime)
        // Nothing was sent before trust: the host is still listening, not prompting.
        #expect(h.host.pendingRequest == nil)

        viewer.trustHost(remember: true)
        #expect(h.store.pinnedFingerprint(host: "127.0.0.1", port: port) == h.ids.host.fingerprint)
        #expect(viewer.state == .awaitingApproval)

        #expect(await eventually { h.host.pendingRequest != nil }, "host state: \(h.host.state)")
        let request = try #require(h.host.pendingRequest)
        #expect(request.peerName == "Test Viewer")
        #expect(request.fingerprint == h.ids.viewer.fingerprint)
        #expect(request.fingerprintDisplay == viewer.fingerprintDisplay)
        #expect(request.accessibilityGranted)
        #expect(request.remoteAddress.hasPrefix("127.0.0.1:"))
        // No input sink exists before approval: nothing can be injected without consent.
        #expect(h.sinks.count == 0)

        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer state: \(viewer.state)")
        #expect(h.host.isSharing)
        #expect(h.host.activePeer?.name == "Test Viewer")
        #expect(h.host.isViewOnly == false)
        let sink = try #require(h.sinks.last)
        #expect(sink.authorizations == [true])
        #expect(sink.displayFrames == [CGRect(x: 0, y: 0, width: 1440, height: 810)])

        // Video: ≥ 30 decoded frames, strictly increasing ids.
        #expect(await eventually(timeout: 15) { h.frames.count >= 30 }, "decoded \(h.frames.count) frames")
        #expect(h.frames.nonIncreasing == 0)
        #expect(h.frames.lastSize == (1280, 720))
        #expect(await eventually { viewer.streamConfig?.width == 1280 })
        if case .streaming(let info) = viewer.state {
            #expect(info.hostName == "Test Host")
            #expect(info.isTrusted)
        }

        // Input: a click and a key press arrive at the host's sink, in order.
        viewer.isCapturingInput = true
        viewer.handleMouse(try Events.mouse(.leftMouseDown), normalized: CGPoint(x: 0.25, y: 0.75))
        viewer.handleMouse(try Events.mouse(.leftMouseUp), normalized: CGPoint(x: 0.25, y: 0.75))
        #expect(viewer.handleKey(try Events.key(.keyDown, 0)))
        #expect(viewer.handleKey(try Events.key(.keyUp, 0)))
        #expect(await eventually { sink.messages.count >= 4 }, "host received \(sink.messages)")
        let received = sink.messages
        #expect(received.count == 4)
        if received.count == 4 {
            #expect(received[0].isMouseDown && received[1].isMouseUp && received[2].isKeyDown && received[3].isKeyUp)
            if case .mouseDown(let down) = received[0] {
                #expect(down.button == .left)
                #expect(abs(down.x - 0.25) < 0.0001 && abs(down.y - 0.75) < 0.0001)
            }
            if case .keyDown(let key) = received[2] { #expect(key.keyCode == 0) }
        }

        // Metrics flow on both sides (≈2 Hz).
        #expect(await eventually { viewer.metrics.rtt.smoothedMillis > 0 && viewer.metrics.receivedFPS > 0 })
        #expect(await eventually { h.host.metrics.fps > 0 && h.host.metrics.rtt.smoothedMillis > 0 })
        #expect(viewer.metrics.pathDescription == "Loopback")
        #expect(h.host.metrics.pathDescription == "Loopback")

        // A key held at disconnect is released on the viewer side first (key-up reaches the host).
        #expect(viewer.handleKey(try Events.key(.keyDown, 1)))
        #expect(await eventually { sink.messages.count == 5 })
        let source = try #require(h.sources.last)
        #expect(source.isRunning)
        viewer.disconnect()
        #expect(disconnectedReason(viewer) == "Disconnected")
        #expect(await eventually { if case .listening = h.host.state { true } else { false } }, "host: \(h.host.state)")
        #expect(h.host.lastEndReason == "The Viewer disconnected")
        #expect(sink.authorizations == [true, false], "disconnect must deauthorize (release) host input")
        await h.host.waitForTeardown()
        #expect(!source.isRunning, "capture must stop when the session ends")
        let afterRelease = sink.messages
        if afterRelease.count >= 6 {
            #expect(afterRelease[5].isKeyUp, "held key must be released before DISCONNECT")
        } else {
            Issue.record("expected key-up for the held key before disconnect, got \(afterRelease.count) messages")
        }
        #expect(h.host.metrics == MetricsSnapshot())

        // Second connection to the same address is pinned: no verification step, straight to approval; deny it.
        let again = h.makeViewer()
        again.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil }, "viewer: \(again.state)")
        #expect(again.state == .awaitingApproval)
        h.host.deny()
        #expect(await eventually { self.disconnectedReason(again) != nil })
        #expect(disconnectedReason(again)?.contains("declined") == true, "\(again.state)")
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        #expect(h.sinks.count == 1, "a denied request never creates an input sink")

        await h.close()
    }

    @Test func wrongPinnedFingerprintFailsWithIdentityChanged() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        // Trust a different certificate for this address (e.g. the Host regenerated its identity, or an impostor).
        h.store.add(host: "127.0.0.1", port: port, fingerprint: Data(repeating: 0x5A, count: 32), name: "Old Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually(timeout: 15) { self.disconnectedReason(viewer) != nil }, "state: \(viewer.state)")
        #expect(disconnectedReason(viewer) == ViewerHandshake.identityChangedMessage)
        // Never silently re-pinned.
        #expect(h.store.pinnedFingerprint(host: "127.0.0.1", port: port) == Data(repeating: 0x5A, count: 32))
        #expect(h.host.pendingRequest == nil)
        #expect(h.sinks.count == 0)
        await h.close()
    }

    @Test func secondViewerIsBusyWhileARequestIsPending() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let first = h.makeViewer()
        first.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })

        let second = h.makeViewer(identity: try h.ids.extra("Viewer2"))
        second.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { self.disconnectedReason(second) != nil }, "state: \(second.state)")
        #expect(disconnectedReason(second)?.contains("busy") == true, "\(second.state)")
        // The first request is untouched.
        #expect(h.host.pendingRequest?.peerName == "Test Viewer")
        #expect(first.state == .awaitingApproval)
        await h.close()
    }

    /// A peer that completes mutual TLS and then sends nothing does not hold the session slot: another Viewer still
    /// reaches the approval prompt, and the operator can drop the silent one (review finding security-1).
    @Test func silentUnidentifiedPeerDoesNotBlockAnotherViewer() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let silent = h.makeViewer(identity: try h.ids.extra("Silent"))
        silent.connect(host: "127.0.0.1", port: port)   // unpinned: waits for its user, sends no HELLO
        #expect(await eventually { if case .verifyingHost = silent.state { true } else { false } })
        #expect(await eventually { h.host.pendingConnectionCount == 1 })
        #expect(h.host.pendingRequest == nil)

        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil }, "viewer: \(viewer.state)")
        #expect(h.host.pendingRequest?.fingerprint == h.ids.viewer.fingerprint)
        #expect(viewer.state == .awaitingApproval)
        if case .verifyingHost = silent.state {} else { Issue.record("silent peer was disturbed: \(silent.state)") }

        h.host.dropPendingConnections()
        #expect(await eventually { self.disconnectedReason(silent) != nil }, "silent: \(silent.state)")
        #expect(h.host.pendingConnectionCount == 0)
        #expect(h.host.pendingRequest != nil, "dropping unidentified connections leaves the prompt alone")
        await h.close()
    }

    /// The pool of unidentified connections is bounded; a newcomer replaces the oldest one from its own address.
    @Test func fullUnidentifiedPoolEvictsTheOldestFromTheSameAddress() async throws {
        let h = try Harness { $0.maxPendingHandshakes = 1 }
        let port = try await h.startHost()
        let silent = h.makeViewer(identity: try h.ids.extra("Silent"))
        silent.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingConnectionCount == 1 })

        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil }, "viewer: \(viewer.state)")
        #expect(await eventually { self.disconnectedReason(silent) != nil }, "silent: \(silent.state)")
        await h.close()
    }

    /// After the operator denies a request, the same identity is refused without a new prompt for the cooldown;
    /// another identity is still asked about (review finding security-1, prompt fatigue).
    @Test func deniedViewerIsRateLimitedWithoutANewPrompt() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let first = h.makeViewer()
        first.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.deny()
        #expect(await eventually { self.disconnectedReason(first) != nil })

        let again = h.makeViewer()
        again.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { self.disconnectedReason(again) != nil }, "state: \(again.state)")
        #expect(disconnectedReason(again)?.contains("Too many connection attempts") == true, "\(again.state)")
        #expect(h.host.pendingRequest == nil)

        let other = h.makeViewer(identity: try h.ids.extra("Other"))
        other.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil }, "other: \(other.state)")
        await h.close()
    }

    /// A peer-chosen device name with line breaks and a right-to-left override is shown as one plain line
    /// (review finding security-2).
    @Test func hostileDeviceNameIsSanitizedInTheRequest() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer(deviceName: "Alice\u{2019}s Mac\u{201D} to control this Mac?\n\u{2713} Fingerprint verified\u{202E}cam")
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        let name = try #require(h.host.pendingRequest?.peerName)
        #expect(!name.contains("\n"))
        #expect(!name.unicodeScalars.contains { $0.value == 0x202E })
        #expect(name == "Alice\u{2019}s Mac\u{201D} to control this Mac? \u{2713} Fingerprint verified cam")
        h.host.approve()
        #expect(await eventually { h.host.activePeer != nil })
        #expect(h.host.activePeer?.name == name)
        await h.close()
    }

    /// A display reconfiguration during a session re-maps input onto the display's current bounds
    /// (review finding input-1).
    @Test func screenParameterChangeUpdatesTheInputMapping() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.approve()
        #expect(await eventually { h.host.isSharing })
        let sink = try #require(h.sinks.last)
        #expect(sink.displayFrames.count == 1)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(await eventually { sink.displayFrames.count == 2 }, "frames: \(sink.displayFrames)")
        #expect(sink.displayFrames.last == CGRect(x: 0, y: 0, width: 1440, height: 810))
        await h.close()
        // No longer observed once the session ended.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sink.displayFrames.count == 2)
    }

    @Test func missingScreenRecordingIsDenied() async throws {
        let h = try Harness()
        h.permissions.screen = false
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { self.disconnectedReason(viewer) != nil }, "state: \(viewer.state)")
        #expect(disconnectedReason(viewer)?.contains("Screen Recording") == true, "\(viewer.state)")
        #expect(h.host.pendingRequest == nil)
        await h.close()
    }

    @Test func missingAccessibilityMeansViewOnly() async throws {
        let h = try Harness()
        h.permissions.accessibility = false
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        #expect(h.host.pendingRequest?.accessibilityGranted == false)
        h.host.approve()
        #expect(await eventually { viewer.isStreaming })
        #expect(h.host.isViewOnly)
        #expect(h.host.activePeer?.isViewOnly == true)
        let sink = try #require(h.sinks.last)
        #expect(sink.authorizations == [false], "view-only sessions never authorize injection")
        viewer.handleMouse(try Events.mouse(.leftMouseDown), normalized: CGPoint(x: 0.5, y: 0.5))
        #expect(await eventually(timeout: 15) { h.frames.count >= 10 })
        #expect(sink.messages.isEmpty)
        await h.close()
    }

    @Test func hostStopSharingEndsTheViewerSession() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.approve()
        #expect(await eventually { viewer.isStreaming })
        h.host.stopSharing()
        #expect(h.host.lastEndReason == "You stopped sharing")
        #expect(await eventually { self.disconnectedReason(viewer) != nil })
        #expect(disconnectedReason(viewer) == "The Host stopped sharing", "\(viewer.state)")
        #expect(h.sinks.last?.authorizations == [true, false])
        await h.close()
    }

    @Test func captureRevokedBySystemDisconnectsWithPermissionRevoked() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.approve()
        #expect(await eventually { viewer.isStreaming })
        #expect(await eventually { h.sources.last?.isRunning == true })

        h.permissions.screen = false
        h.sources.last?.simulateSystemStop()
        #expect(await eventually { self.disconnectedReason(viewer) != nil })
        #expect(disconnectedReason(viewer) == "The Host revoked screen sharing permission", "\(viewer.state)")
        #expect(h.host.lastEndReason == "Screen Recording permission was revoked")
        #expect(h.host.screenRecordingGranted == false)
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        await h.close()
    }

    @Test func approvalTimeoutDeniesTheViewer() async throws {
        let h = try Harness { $0.approvalTimeout = .milliseconds(500) }
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        #expect(await eventually { self.disconnectedReason(viewer) != nil })
        #expect(disconnectedReason(viewer)?.contains("timed out") == true, "\(viewer.state)")
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        await h.close()
    }

    @Test func viewerRejectingTheHostClosesWithoutHello() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } })
        viewer.rejectHost()
        #expect(disconnectedReason(viewer) == "You did not trust the Host's identity")
        #expect(h.store.list().isEmpty)
        #expect(h.host.pendingRequest == nil)
        // The host returns to listening once the silent connection goes away.
        #expect(await eventually { if case .listening = h.host.state { true } else { false } })
        await h.close()
    }

    @Test func accessibilityRevokedMidSessionDropsToViewOnly() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.store.add(host: "127.0.0.1", port: port, fingerprint: h.ids.host.fingerprint, name: "Host")
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.approve()
        #expect(await eventually { viewer.isStreaming })
        let sink = try #require(h.sinks.last)
        #expect(sink.authorizations == [true])

        h.permissions.accessibility = false
        #expect(await eventually(timeout: 10) { h.host.isViewOnly }, "host must notice the revoked permission")
        #expect(h.host.activePeer?.isViewOnly == true)
        #expect(sink.authorizations == [true, false], "revocation must deauthorize (and release) input")
        #expect(viewer.isStreaming, "video continues view-only")
        await h.close()
    }

    @Test func hostTimesOutAViewerThatNeverSendsHello() async throws {
        let h = try Harness { $0.preHelloTimeout = .milliseconds(500) }
        let port = try await h.startHost()
        let viewer = h.makeViewer()
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } })
        // The user does not decide; the host gives up and tells the viewer.
        #expect(await eventually { self.disconnectedReason(viewer) != nil }, "state: \(viewer.state)")
        #expect(disconnectedReason(viewer)?.contains("timed out") == true, "\(viewer.state)")
        await h.close()
    }

    @Test func stopListeningReturnsToIdle() async throws {
        let h = try Harness()
        _ = try await h.startHost()
        h.host.stopListening()
        #expect(h.host.state == .idle)
        await h.close()
    }
}
