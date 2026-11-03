import Foundation
import Security
import Synchronization
import Testing
import WireProtocol
@testable import TransportCore

/// Creates uniquely labelled keychain identities and removes them when the test ends.
final class IdentityPair: @unchecked Sendable {
    let host: DeviceIdentity
    let viewer: DeviceIdentity
    private let labels: [String]

    init() throws {
        let suffix = UUID().uuidString
        let hostLabel = "SwiftDesk Test Host \(suffix)"
        let viewerLabel = "SwiftDesk Test Viewer \(suffix)"
        labels = [hostLabel, viewerLabel]
        host = try DeviceIdentity.loadOrCreate(label: hostLabel)
        viewer = try DeviceIdentity.loadOrCreate(label: viewerLabel)
    }

    func cleanUp() {
        for label in labels { try? DeviceIdentity.delete(label: label) }
    }
}

/// Polls until `condition` holds or the timeout passes.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// Thread-safe recorder for callbacks.
final class Recorder: @unchecked Sendable {
    let states = Mutex<[PeerConnectionState]>([])
    let messages = Mutex<[ControlMessage]>([])
    let datagrams = Atomic<Int>(0)
    let protocolErrors = Mutex<[WireError]>([])

    func attach(_ c: PeerConnection, echoPings: Bool = false) {
        c.onStateChange = { [self] s in states.withLock { $0.append(s) } }
        c.onControlMessage = { [self, weak c] m in
            messages.withLock { $0.append(m) }
            if echoPings, case .ping(let p) = m { c?.sendControl(.pong(p)) }
        }
        c.onDatagram = { [self] _ in datagrams.wrappingAdd(1, ordering: .relaxed) }
        c.onProtocolError = { [self] e in protocolErrors.withLock { $0.append(e) } }
    }

    var lastState: PeerConnectionState? { states.withLock { $0.last } }
    var messageCount: Int { messages.withLock { $0.count } }
}

/// Copyable reference to a `Mutex`, so closures can capture it.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// A started listener on an ephemeral loopback port plus the host-side connections it hands out.
final class TestHost: @unchecked Sendable {
    let listener: HostListener
    let port = Locked<UInt16>(0)
    let incoming = Mutex<[PeerConnection]>([])
    let recorder = Recorder()

    init(identity: DeviceIdentity, limiter: ConnectionRateLimiter = ConnectionRateLimiter(perAddressPerMinute: 100, globalPerMinute: 100)) {
        listener = HostListener(port: 0, identity: identity, deviceName: "SwiftDesk Test", advertiseBonjour: false,
                                rateLimiter: limiter)
        listener.onStateChange = { [port] state in
            if case .ready(let p) = state { port.withLock { $0 = p } }
        }
        listener.onIncoming = { [self] connection in
            incoming.withLock { $0.append(connection) }
            recorder.attach(connection, echoPings: true)
            connection.start()
        }
    }

    func start() async throws {
        listener.start()
        let ready = await eventually { self.port.withLock { $0 } != 0 }
        try #require(ready, "listener did not become ready")
    }

    var boundPort: UInt16 { port.withLock { $0 } }
    var connections: [PeerConnection] { incoming.withLock { $0 } }
}

@Suite("Loopback QUIC integration", .serialized, .timeLimit(.minutes(1)))
struct LoopbackIntegrationTests {
    @Test func pinnedConnectControlRoundTripAndDatagrams() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        let rec = Recorder()
        rec.attach(viewer)
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        #expect(rec.states.withLock { $0 } == [.connecting, .ready])
        #expect(viewer.peerFingerprint == ids.host.fingerprint)
        #expect(viewer.maxDatagramSize > 0 && viewer.maxDatagramSize <= WireConstants.defaultMaxDatagramSize)
        #expect(viewer.remoteAddress == "127.0.0.1:\(host.boundPort)")

        #expect(await eventually { host.connections.count == 1 })
        let hostSide = try #require(host.connections.first)
        #expect(hostSide.peerFingerprint == ids.viewer.fingerprint)
        #expect(hostSide.state == .ready)
        #expect(host.recorder.states.withLock { $0 } == [.ready])
        #expect(hostSide.remoteAddress.hasPrefix("127.0.0.1:"))

        // Control: ordered round trips through WireProtocol framing.
        for i in 0..<50 { viewer.sendControl(.ping(Ping(id: UInt32(i), sentAtNanos: UInt64(i)))) }
        #expect(await eventually { rec.messageCount == 50 })
        let ids50 = rec.messages.withLock { $0 }.compactMap { m -> UInt32? in
            if case .pong(let p) = m { return p.id } else { return nil }
        }
        #expect(ids50 == Array(0..<50))

        // A large message near the size limit survives arbitrary QUIC chunking.
        let hello = Hello(deviceName: String(repeating: "x", count: 200), appVersion: "1.0")
        viewer.sendControl(.hello(hello))
        #expect(await eventually { host.recorder.messages.withLock { $0.contains(.hello(hello)) } })

        // Datagrams in both directions.
        let batch = (0..<10).map { _ in Data(repeating: 0x56, count: viewer.maxDatagramSize) }
        for _ in 0..<20 {
            #expect(viewer.sendDatagrams(batch))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(await eventually { host.recorder.datagrams.load(ordering: .relaxed) == 200 })
        for _ in 0..<10 { hostSide.sendDatagrams(batch) }
        #expect(await eventually { rec.datagrams.load(ordering: .relaxed) == 100 })
        #expect(await eventually { viewer.pendingDatagramBytes == 0 && hostSide.pendingDatagramBytes == 0 })
        #expect(viewer.stats.datagramsSent == 200)
        #expect(hostSide.stats.datagramsReceived == 200)

        // Graceful close: DISCONNECT reaches the host, both sides end .closed, close is idempotent.
        viewer.close(reason: .userInitiated)
        viewer.close(reason: .userInitiated)
        #expect(await eventually { host.recorder.lastState == .closed })
        #expect(host.recorder.messages.withLock { $0.last } == .disconnect(.userInitiated))
        #expect(viewer.state == .closed)
        #expect(rec.states.withLock { $0 } == [.connecting, .ready, .closed])
        #expect(!viewer.sendDatagrams(batch))
    }

    /// 0.1.5 side stream: opened by the Viewer, identified by the Host from its preamble, carries a multi-megabyte
    /// clipboard both ways while the control stream keeps answering pings.
    @Test func sideStreamCarriesLargePayloadsBesideTheControlStream() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        let hostSide = Locked<[ControlMessage]>([])
        let hostReady = Locked<Bool>(false)
        host.listener.onIncoming = { [host] connection in
            host.incoming.withLock { $0.append(connection) }
            host.recorder.attach(connection, echoPings: true)
            connection.onSideMessage = { m in hostSide.withLock { $0.append(m) } }
            connection.onSideStreamReady = { hostReady.withLock { $0 = true } }
            connection.start()
        }
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        let rec = Recorder()
        rec.attach(viewer)
        let viewerSide = Locked<[ControlMessage]>([])
        let viewerReady = Locked<Bool>(false)
        viewer.onSideMessage = { m in viewerSide.withLock { $0.append(m) } }
        viewer.onSideStreamReady = { viewerReady.withLock { $0 = true } }
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        #expect(!viewer.isSideStreamOpen)
        #expect(!viewer.sendSide(.clipboard(ClipboardContent(items: [.init(kind: .plainText, data: Data("x".utf8))]))),
                "nothing is sent before the side stream exists")
        #expect(await eventually { host.connections.count == 1 })
        let hostConnection = try #require(host.connections.first)
        #expect(!hostConnection.isSideStreamOpen)

        viewer.openSideStream()
        viewer.openSideStream()   // idempotent
        #expect(await eventually { viewerReady.withLock { $0 } })
        var image = ClipboardContent.pngSignature
        image.append(Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
        let big = ClipboardContent(items: [.init(kind: .png, data: image), .init(kind: .plainText, data: Data("caption".utf8))])
        let sent = Locked<Bool>(false)
        #expect(viewer.sendSide(.clipboard(big)) { ok in sent.withLock { $0 = ok } })
        // Before the session authorizes the connection the Host neither identifies nor decodes the side stream.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!hostReady.withLock { $0 })
        #expect(!hostConnection.isSideStreamOpen)
        #expect(hostSide.withLock { $0.isEmpty })
        hostConnection.allowSideStream()
        hostConnection.allowSideStream()   // idempotent
        // Control traffic is not held up by the transfer.
        viewer.sendControl(.ping(Ping(id: 99, sentAtNanos: 1)))
        #expect(await eventually(timeout: 15) { hostSide.withLock { $0.count } == 1 })
        #expect(hostSide.withLock { $0.first } == .clipboard(big))
        #expect(sent.withLock { $0 })
        #expect(hostReady.withLock { $0 })
        #expect(hostConnection.isSideStreamOpen)
        #expect(await eventually { rec.messages.withLock { $0.contains(.pong(Ping(id: 99, sentAtNanos: 1))) } })

        // Host → Viewer on the same stream.
        let back = ClipboardContent(items: [.init(kind: .url, data: Data("https://example.com".utf8))])
        #expect(hostConnection.sendSide(.clipboard(back)))
        #expect(await eventually { viewerSide.withLock { $0 } == [.clipboard(back)] })
        // Side-stream types are refused on the control stream (they would sit in front of input there).
        hostConnection.sendControl(.clipboard(back))
        // Control-stream types are refused on the side stream.
        #expect(!viewer.sendSide(.ping(Ping(id: 1, sentAtNanos: 1))))
        #expect(viewer.state == .ready)
        viewer.close(reason: .userInitiated)
    }

    @Test func clipboardOnTheControlStreamClosesTheConnection() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }
        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        #expect(await eventually { host.connections.count == 1 })
        let frame = ControlFraming.frame(.clipboard(ClipboardContent(items: [.init(kind: .plainText, data: Data("x".utf8))])))
        viewer.sendRawControlBytesForTesting(frame)
        #expect(await eventually { host.recorder.protocolErrors.withLock { !$0.isEmpty } })
        #expect(await eventually { viewer.state != .ready })
    }

    @Test func wrongPinFailsFastAndHostNeverSeesTheConnection() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: Data(repeating: 0x42, count: 32))
        let rec = Recorder()
        rec.attach(viewer)
        viewer.start()
        #expect(await eventually(timeout: 5) { viewer.state.isTerminal })
        #expect(viewer.state == .failed(PeerConnection.pinMismatchMessage))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(host.connections.isEmpty)
    }

    @Test func unpinnedConnectRecordsHostFingerprint() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: nil)
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        #expect(viewer.peerFingerprint == ids.host.fingerprint)
        viewer.close(reason: nil)
        #expect(await eventually { host.recorder.lastState?.isTerminal == true })
    }

    @Test func controlMessagesSentBeforeReadyAreDeliveredInOrder() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        viewer.start()
        // Queued while connecting; flushed in order right after the transport preamble.
        viewer.sendControl(.hello(Hello(deviceName: "viewer", appVersion: "1")))
        viewer.sendControl(.requestKeyframe(reason: 7))
        #expect(await eventually { host.recorder.messageCount == 2 })
        #expect(host.recorder.messages.withLock { $0 } == [.hello(Hello(deviceName: "viewer", appVersion: "1")),
                                                           .requestKeyframe(reason: 7)])
        viewer.close(reason: .userInitiated)
    }

    @Test func malformedControlStreamClosesTheConnection() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        let rec = Recorder()
        rec.attach(viewer)
        viewer.start()
        #expect(await eventually { viewer.state == .ready && host.connections.count == 1 })
        // Unknown message type 0xEE with a valid length prefix.
        viewer.sendRawControlBytesForTesting(Data([0, 0, 0, 1, 0xEE]))
        #expect(await eventually { host.recorder.protocolErrors.withLock { !$0.isEmpty } })
        #expect(host.recorder.protocolErrors.withLock { $0 } == [.unknownType(0xEE)])
        #expect(await eventually { host.recorder.lastState == .closed })
        // The host told the viewer why before closing.
        #expect(await eventually { rec.messages.withLock { $0.contains(.disconnect(.protocolError)) } })
        #expect(await eventually { viewer.state.isTerminal })
    }

    @Test func backpressureDropsWholeBatchesAndDrains() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        #expect(!viewer.sendDatagrams([Data(count: 100)]), "not ready yet")
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        viewer.maxBacklogBytes = 32 * 1024
        let batch = (0..<20).map { _ in Data(count: viewer.maxDatagramSize) }   // ~23 KB
        var refused = 0
        for _ in 0..<100 where !viewer.sendDatagrams(batch) { refused += 1 }
        #expect(refused > 0)
        #expect(viewer.stats.datagramBatchesDroppedBackpressure == UInt64(refused))
        #expect(await eventually { viewer.pendingDatagramBytes == 0 })
        #expect(viewer.sendDatagrams(batch), "accepted again once drained")
        #expect(viewer.sendDatagrams([]), "empty batch is a no-op")
        viewer.close(reason: .userInitiated)
    }

    /// The per-batch bound refuses a batch when more than `maxQueuedAheadBytes` are already queued ahead of it, and
    /// always admits when nothing is pending (review finding latency-3).
    @Test func perBatchQueueBoundRefusesBehindABacklog() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        let batch = (0..<20).map { _ in Data(count: viewer.maxDatagramSize) }   // ~23 KB
        var refused = 0
        for _ in 0..<100 {
            #expect(viewer.sendDatagrams(batch, maxQueuedAheadBytes: .max) || viewer.pendingDatagramBytes > 0)
            if !viewer.sendDatagrams([Data(count: 100)], maxQueuedAheadBytes: 1_000) { refused += 1 }
        }
        #expect(refused > 0, "a backlog ahead of the batch must refuse it")
        #expect(await eventually { viewer.pendingDatagramBytes == 0 })
        #expect(viewer.sendDatagrams(batch, maxQueuedAheadBytes: 0), "nothing pending always admits")
        viewer.close(reason: .userInitiated)
    }

    @Test func simulatedLossDropsAboutTheConfiguredFraction() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint)
        viewer.start()
        #expect(await eventually { viewer.state == .ready })
        viewer.simulatedDatagramLossPercent = 20
        #expect(viewer.simulatedDatagramLossPercent == 20)
        let batch = (0..<10).map { _ in Data(count: 200) }
        for _ in 0..<100 {
            viewer.sendDatagrams(batch)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await eventually { viewer.pendingDatagramBytes == 0 })
        try await Task.sleep(nanoseconds: 200_000_000)
        let dropped = Int(viewer.stats.datagramsDroppedSimulated)
        let arrived = host.recorder.datagrams.load(ordering: .relaxed)
        #expect(dropped > 100 && dropped < 320, "expected ~200 of 1000 dropped, got \(dropped)")
        #expect(arrived + dropped == 1000)
        viewer.simulatedDatagramLossPercent = .nan
        #expect(viewer.simulatedDatagramLossPercent == 0)
        viewer.simulatedDatagramLossPercent = 500
        #expect(viewer.simulatedDatagramLossPercent == 100)
        viewer.close(reason: .userInitiated)
    }

    @Test func rateLimitedAttemptNeverReachesTheHost() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host, limiter: ConnectionRateLimiter(perAddressPerMinute: 1, globalPerMinute: 10))
        try await host.start()
        defer { host.listener.stop() }

        let first = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                           pinnedHostFingerprint: ids.host.fingerprint, establishmentTimeout: 3)
        first.start()
        #expect(await eventually { first.state == .ready })
        let second = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: ids.viewer,
                                            pinnedHostFingerprint: ids.host.fingerprint, establishmentTimeout: 1.5)
        second.start()
        #expect(await eventually(timeout: 4) { second.state.isTerminal })
        #expect(second.state == .failed("Connection timed out"))
        #expect(host.connections.count == 1)
        first.close(reason: .userInitiated)
    }

    @Test func connectingToNothingTimesOut() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        // Port 9 (discard) on loopback: nothing answers QUIC there.
        let viewer = PeerConnection.connect(host: "127.0.0.1", port: 9, identity: ids.viewer,
                                            pinnedHostFingerprint: nil, establishmentTimeout: 1)
        viewer.start()
        #expect(await eventually(timeout: 4) { viewer.state.isTerminal })
        if case .failed = viewer.state {} else { Issue.record("expected failure, got \(viewer.state)") }
    }

    @Test func listenerReportsStoppedAndDoesNotHandOutAfterStop() async throws {
        let ids = try IdentityPair()
        defer { ids.cleanUp() }
        let host = TestHost(identity: ids.host)
        let states = Mutex<[ListenerState]>([])
        host.listener.onStateChange = { [port = host.port] s in
            states.withLock { $0.append(s) }
            if case .ready(let p) = s { port.withLock { $0 = p } }
        }
        try await host.start()
        host.listener.stop()
        #expect(await eventually { host.listener.state == .stopped })
        let recorded = states.withLock { $0 }
        #expect(recorded.first == .starting)
        #expect(recorded.last == .stopped)
        #expect(recorded.contains { if case .ready = $0 { return true } else { return false } })
    }
}

@Suite("DeviceIdentity keychain", .serialized)
struct DeviceIdentityKeychainTests {
    @Test func loadOrCreatePersistsRegenerateRotatesDeleteRemoves() throws {
        let label = "SwiftDesk Test Identity \(UUID().uuidString)"
        defer { try? DeviceIdentity.delete(label: label) }

        let first = try DeviceIdentity.loadOrCreate(label: label)
        #expect(first.fingerprint.count == 32)
        #expect(first.fingerprint == DeviceIdentity.fingerprint(ofCertificate: first.certificateDER))
        #expect(first.commonName.hasPrefix("SwiftDesk "))
        #expect(first.label == label)
        #expect(first.fingerprintDisplay == DeviceIdentity.display(first.fingerprint))

        let again = try DeviceIdentity.loadOrCreate(label: label)
        #expect(again.fingerprint == first.fingerprint, "second load must return the stored identity")
        #expect(again.certificateDER == first.certificateDER)

        let rotated = try DeviceIdentity.regenerate(label: label)
        #expect(rotated.fingerprint != first.fingerprint)
        #expect(try DeviceIdentity.loadOrCreate(label: label).fingerprint == rotated.fingerprint)

        try DeviceIdentity.delete(label: label)
        try DeviceIdentity.delete(label: label)   // deleting nothing is not an error
        let fresh = try DeviceIdentity.loadOrCreate(label: label)
        #expect(fresh.fingerprint != rotated.fingerprint)
    }

    @Test func identityCertificateMatchesItsKey() throws {
        let label = "SwiftDesk Test Identity \(UUID().uuidString)"
        defer { try? DeviceIdentity.delete(label: label) }
        let identity = try DeviceIdentity.loadOrCreate(label: label)
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity.secIdentity, &certificate) == errSecSuccess)
        #expect(certificate.map { SecCertificateCopyData($0) as Data } == identity.certificateDER)
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity.secIdentity, &key) == errSecSuccess)
        let privateKey = try #require(key)
        // The keychain key can sign, and the certificate's public key verifies it.
        let message = Data("swiftdesk".utf8)
        let signature = try #require(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?)
        let publicKey = try #require(certificate.flatMap { SecCertificateCopyKey($0) })
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, nil))
    }
}
