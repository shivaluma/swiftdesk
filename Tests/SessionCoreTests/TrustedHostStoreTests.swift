import Foundation
import Testing
@testable import SessionCore

@Suite struct TrustedHostStoreTests {
    private let fp1 = Data((0..<32).map { UInt8($0) })
    private let fp2 = Data((0..<32).map { UInt8(255 - $0) })

    @Test func keyNormalization() {
        #expect(TrustedHostStore.key(host: "Mac.Local.", port: 47800) == "mac.local:47800")
        #expect(TrustedHostStore.key(host: " 192.168.1.5 ", port: 1) == "192.168.1.5:1")
        #expect(TrustedHostStore.key(host: "fe80::1", port: 47800) == "[fe80::1]:47800")
        #expect(TrustedHostStore.key(host: "[FD7A:115C:A1E0::1]", port: 9) == "[fd7a:115c:a1e0::1]:9")
    }

    @Test func hexRoundTrip() {
        let hex = TrustedHostStore.hex(fp1)
        #expect(hex.count == 64)
        #expect(hex.hasPrefix("000102"))
        #expect(TrustedHostStore.data(fromHex: hex) == fp1)
        #expect(TrustedHostStore.data(fromHex: hex.uppercased()) == fp1)
        #expect(TrustedHostStore.data(fromHex: "abc") == nil)
        #expect(TrustedHostStore.data(fromHex: "zz") == nil)
    }

    @Test func addListPinRemove() {
        let d = TestDefaults()
        defer { d.cleanUp() }
        let store = TrustedHostStore(defaults: d.defaults)
        #expect(store.list().isEmpty)
        #expect(store.pinnedFingerprint(host: "10.0.0.2", port: 47800) == nil)

        store.add(host: "10.0.0.2", port: 47800, fingerprint: fp1, name: "Studio", now: Date(timeIntervalSince1970: 1))
        store.add(host: "Mac.local", port: 47800, fingerprint: fp2, name: "Laptop", now: Date(timeIntervalSince1970: 2))
        #expect(store.list().map(\.name) == ["Laptop", "Studio"])   // newest first
        #expect(store.pinnedFingerprint(host: "10.0.0.2", port: 47800) == fp1)
        #expect(store.pinnedFingerprint(host: "mac.local.", port: 47800) == fp2)
        #expect(store.pinnedFingerprint(host: "10.0.0.2", port: 1) == nil)   // port is part of the key
        #expect(store.contains(fingerprint: fp1))
        #expect(!store.contains(fingerprint: Data(repeating: 7, count: 32)))

        store.rename(key: "10.0.0.2:47800", to: "Studio Mac")
        #expect(store.entry(host: "10.0.0.2", port: 47800)?.name == "Studio Mac")

        store.remove(host: "10.0.0.2", port: 47800)
        #expect(store.pinnedFingerprint(host: "10.0.0.2", port: 47800) == nil)
        #expect(store.list().count == 1)
        store.removeAll()
        #expect(store.list().isEmpty)
    }

    @Test func replacingAPinIsExplicit() {
        let d = TestDefaults()
        defer { d.cleanUp() }
        let store = TrustedHostStore(defaults: d.defaults)
        store.add(host: "h", port: 1, fingerprint: fp1, name: "a")
        store.add(host: "h", port: 1, fingerprint: fp2, name: "a")
        #expect(store.list().count == 1)
        #expect(store.pinnedFingerprint(host: "h", port: 1) == fp2)
    }

    @Test func persistsAcrossInstancesAndIsolatesSuites() {
        let d = TestDefaults()
        let other = TestDefaults()
        defer { d.cleanUp(); other.cleanUp() }
        TrustedHostStore(defaults: d.defaults).add(host: "h", port: 2, fingerprint: fp1, name: "n")
        #expect(TrustedHostStore(defaults: d.defaults).pinnedFingerprint(host: "h", port: 2) == fp1)
        #expect(TrustedHostStore(defaults: other.defaults).list().isEmpty)
        #expect(TrustedHostStore(defaults: d.defaults, storageKey: "other").list().isEmpty)
    }

    @Test func corruptOrInvalidStorageFailsClosed() throws {
        let d = TestDefaults()
        defer { d.cleanUp() }
        d.defaults.set(Data("garbage".utf8), forKey: TrustedHostStore.defaultStorageKey)
        let store = TrustedHostStore(defaults: d.defaults)
        #expect(store.list().isEmpty)
        // An entry whose fingerprint is not 32 bytes is ignored rather than pinned.
        let bad = TrustedHost(key: "x:1", fingerprintHex: "abcd", name: "x", addedAt: Date())
        let blob = try PropertyListEncoder().encode([bad])
        d.defaults.set(blob, forKey: TrustedHostStore.defaultStorageKey)
        #expect(store.list().isEmpty)
        #expect(store.pinnedFingerprint(host: "x", port: 1) == nil)
    }

    @Test func concurrentAddsAreNotLost() async {
        let d = TestDefaults()
        defer { d.cleanUp() }
        let store = TrustedHostStore(defaults: d.defaults)
        let fp = fp1
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { store.add(host: "host\(i)", port: 1, fingerprint: fp, name: "\(i)") }
            }
        }
        #expect(store.list().count == 40)
    }
}
