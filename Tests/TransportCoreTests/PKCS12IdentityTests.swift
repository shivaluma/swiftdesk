import Foundation
import Testing
import WireProtocol
@testable import TransportCore

/// In-memory identities from PKCS#12 (`DeviceIdentity.importPKCS12`): no keychain involved, so these also run where
/// the login keychain is locked (SSH sessions, CI).
@Suite("PKCS#12 in-memory identity", .serialized, .timeLimit(.minutes(1)))
struct PKCS12IdentityTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "p12", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func importYieldsIdentityWithStableFingerprint() throws {
        let data = try Self.fixture("netbench")
        let a = try DeviceIdentity.importPKCS12(data, password: "netbench", label: "a")
        let b = try DeviceIdentity.importPKCS12(data, password: "netbench", label: "b")
        #expect(a.fingerprint.count == 32)
        #expect(a.fingerprint == DeviceIdentity.fingerprint(ofCertificate: a.certificateDER))
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.commonName == "netbench")
        #expect(a.label == "a")
    }

    @Test func wrongPasswordOrGarbageThrows() throws {
        let data = try Self.fixture("netbench")
        #expect(throws: DeviceIdentityError.self) { try DeviceIdentity.importPKCS12(data, password: "nope") }
        #expect(throws: DeviceIdentityError.self) { try DeviceIdentity.importPKCS12(Data([1, 2, 3]), password: "x") }
    }

    @Test func importedIdentitiesCompletePinnedLoopbackHandshake() async throws {
        let hostId = try DeviceIdentity.importPKCS12(try Self.fixture("netbench"), password: "netbench")
        let viewerId = try DeviceIdentity.importPKCS12(try Self.fixture("netbench-peer"), password: "netbench")
        #expect(hostId.fingerprint != viewerId.fingerprint)

        let host = TestHost(identity: hostId)
        try await host.start()
        defer { host.listener.stop() }

        let viewer = PeerConnection.connect(host: "127.0.0.1", port: host.boundPort, identity: viewerId,
                                            pinnedHostFingerprint: hostId.fingerprint)
        let rec = Recorder()
        rec.attach(viewer)
        viewer.start()
        defer { viewer.close(reason: nil) }
        #expect(await eventually { viewer.state == .ready })
        #expect(viewer.peerFingerprint == hostId.fingerprint)
        #expect(await eventually { host.connections.count == 1 })
        #expect(host.connections.first?.peerFingerprint == viewerId.fingerprint)

        viewer.sendControl(.ping(Ping(id: 7, sentAtNanos: 1)))
        #expect(await eventually { rec.messages.withLock { $0 }.contains(.pong(Ping(id: 7, sentAtNanos: 1))) })
        #expect(viewer.sendDatagrams([Data(repeating: 0x56, count: 64)]))
        #expect(await eventually { host.recorder.datagrams.load(ordering: .relaxed) > 0 })
    }
}
