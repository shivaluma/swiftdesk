import Foundation
import Security
import Testing
import WireProtocol
@testable import SessionCore

/// The password-access construction (PBKDF2-HMAC-SHA256 key, HMAC-SHA256 proof) and its storage.
@Suite("Access password crypto and storage")
struct AccessPasswordTests {
    // Known-answer vector computed independently with Python 3 hashlib/hmac:
    //   pw    = unicodedata.normalize("NFC", "passwörd-café")          # "passwörd-café"
    //   key   = hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes(range(16)), 100000, 32)
    //   nonce = bytes((i * 3) & 0xff for i in range(32)); hfp = b"\xaa" * 32; vfp = b"\xbb" * 32
    //   proof = hmac.new(key, b"swiftdesk-password-v1" + nonce + hfp + vfp, hashlib.sha256).digest()
    static let katKey = "4221a4cb839192a63194fa19cdd22a1276d93010640de6ddbce8ad28ad910ba3"
    static let katProof = "6edb67a0d65c7b1492bfc2c387f2fdc351985a07fa928851e114476850dae954"
    static let katSalt = Data((0..<16).map { UInt8($0) })
    static let katNonce = Data((0..<32).map { UInt8(($0 * 3) & 0xFF) })
    static let hostFP = Data(repeating: 0xAA, count: 32)
    static let viewerFP = Data(repeating: 0xBB, count: 32)

    @Test func knownAnswerVector() throws {
        // Decomposed input: NFC normalization must turn it into the precomposed bytes Python hashed.
        let decomposed = "passwo\u{0308}rd-cafe\u{0301}"
        let key = try AccessPassword.deriveKey(password: decomposed, salt: Self.katSalt, iterations: 100_000)
        #expect(TrustedHostStore.hex(key) == Self.katKey)
        let proof = AccessPassword.proof(key: key, nonce: Self.katNonce, hostFingerprint: Self.hostFP,
                                         viewerFingerprint: Self.viewerFP)
        #expect(TrustedHostStore.hex(proof) == Self.katProof)

        let precomposed = "passw\u{00F6}rd-caf\u{00E9}"
        #expect(try AccessPassword.deriveKey(password: precomposed, salt: Self.katSalt, iterations: 100_000) == key)
        #expect(AccessPassword.normalizedBytes(decomposed) == Data("passwörd-café".utf8))
    }

    @Test func pbkdf2MatchesRFCStyleVector() throws {
        // hashlib.pbkdf2_hmac("sha256", b"passwd", b"salt", 1, 32): first half of the RFC 7914 §11 64-byte vector.
        let key = try AccessPassword.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1)
        #expect(TrustedHostStore.hex(key) == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    @Test func verifyAcceptsOnlyTheExactBinding() throws {
        let key = try #require(TrustedHostStore.data(fromHex: Self.katKey))
        let proof = try #require(TrustedHostStore.data(fromHex: Self.katProof))
        func ok(_ p: Data, nonce: Data = Self.katNonce, host: Data = Self.hostFP, viewer: Data = Self.viewerFP, k: Data? = nil) -> Bool {
            AccessPassword.verify(proof: p, key: k ?? key, nonce: nonce, hostFingerprint: host, viewerFingerprint: viewer)
        }
        #expect(ok(proof))
        var flipped = proof
        flipped[31] ^= 1
        #expect(!ok(flipped))
        #expect(!ok(proof, nonce: Data(repeating: 0, count: 32)), "another nonce (replay)")
        #expect(!ok(proof, host: Self.viewerFP, viewer: Self.hostFP), "swapped identities")
        #expect(!ok(proof, host: Data(repeating: 0xCC, count: 32)), "relayed to another Host")
        #expect(!ok(proof, viewer: Data(repeating: 0xCC, count: 32)), "another Viewer identity")
        #expect(!ok(proof.prefix(31)), "short proof")
        #expect(!ok(Data(count: 32)))
        #expect(!ok(proof, k: Data(repeating: 1, count: 32)), "another password")
        #expect(!ok(proof, k: key.prefix(16)), "mis-sized key")
    }

    /// A hostile Host cannot lower the work factor below what every real Host uses (review finding security-3), nor
    /// make the Viewer burn CPU.
    @Test func viewerRefusesOutOfRangeIterations() throws {
        for rounds: UInt32 in [0, 1, 99_999, 100_000, 600_000, AccessPassword.defaultIterations - 1, 5_000_001, .max] {
            let challenge = PasswordChallenge(salt: Self.katSalt, iterations: rounds, nonce: Self.katNonce)
            #expect(try AccessPassword.answer(challenge, password: "whatever1", hostFingerprint: Self.hostFP,
                                              viewerFingerprint: Self.viewerFP) == nil, "rounds \(rounds)")
        }
        #expect(AccessPassword.acceptedIterations.lowerBound == AccessPassword.defaultIterations)
        #expect(AccessPassword.acceptedIterations.contains(AccessPassword.defaultIterations))
        // At the default rounds `answer` is exactly PBKDF2 + HMAC (the construction the KAT pins down).
        let challenge = PasswordChallenge(salt: Self.katSalt, iterations: AccessPassword.defaultIterations, nonce: Self.katNonce)
        let proof = try AccessPassword.answer(challenge, password: "passwörd-café", hostFingerprint: Self.hostFP,
                                              viewerFingerprint: Self.viewerFP)
        let key = try AccessPassword.deriveKey(password: "passwörd-café", salt: Self.katSalt,
                                               iterations: AccessPassword.defaultIterations)
        #expect(proof == AccessPassword.proof(key: key, nonce: Self.katNonce, hostFingerprint: Self.hostFP,
                                              viewerFingerprint: Self.viewerFP))
    }

    /// Records the derivation time at the default rounds (design target ≈100–200 ms on Apple silicon).
    @Test func defaultIterationsCostIsMeasured() throws {
        let start = ContinuousClock.now
        _ = try AccessPassword.deriveKey(password: "correct horse battery", salt: Self.katSalt,
                                         iterations: AccessPassword.defaultIterations)
        let elapsed = ContinuousClock.now - start
        // Loose bounds: the point is that it is neither trivial nor unusable (debug builds, loaded CI machines).
        #expect(elapsed > .milliseconds(20) && elapsed < .seconds(5), "PBKDF2 took \(elapsed)")
    }

    @Test func minimumLength() {
        #expect(!AccessPassword.isAcceptable("1234567"))
        #expect(AccessPassword.isAcceptable("12345678"))
        #expect(AccessPassword.isAcceptable("🔑🔑🔑🔑🔑🔑🔑🔑"), "Characters, not bytes")
    }

    // MARK: HostAccessPassword

    private static let fastRounds: UInt32 = 100_000

    private func challenge(for host: HostAccessPassword, nonce: Data = Data(repeating: 5, count: 32)) throws -> PasswordChallenge {
        let params = try #require(host.challengeParameters())
        return PasswordChallenge(salt: params.salt, iterations: params.iterations, nonce: nonce)
    }

    /// The Viewer's proof for `challenge`, bypassing its rounds floor (these Host-storage tests use fewer rounds).
    private func proof(_ challenge: PasswordChallenge, _ password: String) throws -> Data {
        let key = try AccessPassword.deriveKey(password: password, salt: challenge.salt, iterations: challenge.iterations)
        return AccessPassword.proof(key: key, nonce: challenge.nonce, hostFingerprint: Self.hostFP,
                                    viewerFingerprint: Self.viewerFP)
    }

    @Test func hostSetVerifyDisableClear() throws {
        let store = InMemorySecretStore()
        let host = HostAccessPassword(store: store, iterations: Self.fastRounds)
        #expect(!host.isConfigured && !host.isEnabled && host.challengeParameters() == nil)
        #expect(throws: AccessPassword.Failure.tooShort(minimum: 8)) { try host.set(password: "short") }

        try host.set(password: "open sesame")
        #expect(host.isConfigured && host.isEnabled)
        let c = try challenge(for: host)
        #expect(c.salt.count == 16 && c.iterations == Self.fastRounds)
        let good = try proof(c, "open sesame")
        let bad = try proof(c, "open sesamE")
        #expect(host.verify(proof: good, challenge: c, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP))
        #expect(host.verify(proof: good, nonce: c.nonce, hostFP: Self.hostFP, viewerFP: Self.viewerFP))
        #expect(!host.verify(proof: bad, challenge: c, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP))

        // The stored blob holds no password bytes, only version/flag/rounds/salt/key.
        let blob = try #require(store.read(account: "host"))
        #expect(blob.count == 54)
        #expect(blob.range(of: Data("open sesame".utf8)) == nil)

        // A reloaded instance (same store) sees the same record.
        let reloaded = HostAccessPassword(store: store, iterations: Self.fastRounds)
        #expect(reloaded.isEnabled)
        #expect(reloaded.verify(proof: good, challenge: c, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP))

        try host.setEnabled(false)
        #expect(host.isConfigured && !host.isEnabled && host.challengeParameters() == nil)
        #expect(!host.verify(proof: good, challenge: c, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP))
        #expect(!HostAccessPassword(store: store).isEnabled, "the flag is persisted")
        try host.setEnabled(true)
        #expect(host.isEnabled)

        // A new password gets a new salt: proofs for the old challenge fail.
        try host.set(password: "open sesame")
        #expect(!host.verify(proof: good, challenge: c, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP))

        host.clear()
        #expect(!host.isConfigured && store.read(account: "host") == nil)
        try host.setEnabled(true)
        #expect(!host.isEnabled, "enabling without a password does nothing")
    }

    /// "Change Password…" while password access is switched off must not switch it back on (review finding ux-1).
    @Test func changingThePasswordKeepsTheSwitch() throws {
        let store = InMemorySecretStore()
        let host = HostAccessPassword(store: store, iterations: Self.fastRounds)
        try host.set(password: "first password")
        #expect(host.isEnabled, "the first password turns password access on")
        try host.setEnabled(false)
        try host.set(password: "second password")
        #expect(host.isConfigured && !host.isEnabled, "replacing the password keeps it switched off")
        #expect(!HostAccessPassword(store: store).isEnabled, "and that is what is persisted")
        try host.setEnabled(true)
        try host.set(password: "third password")
        #expect(host.isEnabled, "replacing it while on keeps it on")
        host.clear()
        try host.set(password: "fresh password")
        #expect(host.isEnabled, "a password set after Remove turns access on again")
    }

    /// A challenge that went stale (switched off, removed, password changed) is not a wrong password
    /// (review finding protocol-2).
    @Test func checkTellsStaleFromInvalid() throws {
        let host = HostAccessPassword(store: InMemorySecretStore(), iterations: Self.fastRounds)
        try host.set(password: "open sesame")
        let c = try challenge(for: host)
        let good = try proof(c, "open sesame")
        let bad = try proof(c, "open sesamE")
        func check(_ p: Data, _ ch: PasswordChallenge = c) -> HostAccessPassword.ProofResult {
            host.check(proof: p, challenge: ch, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP)
        }
        #expect(check(good) == .valid)
        #expect(check(bad) == .invalid)
        let otherRounds = PasswordChallenge(salt: c.salt, iterations: c.iterations + 1, nonce: c.nonce)
        #expect(check(good, otherRounds) == .stale)
        try host.setEnabled(false)
        #expect(check(good) == .stale && check(bad) == .stale)
        try host.setEnabled(true)
        #expect(check(good) == .valid)
        try host.set(password: "open sesame")      // same password, new salt
        #expect(check(good) == .stale)
        host.clear()
        #expect(check(good) == .stale)
    }

    @Test func corruptRecordIsIgnored() throws {
        let store = InMemorySecretStore()
        try store.write(Data([9, 9, 9]), account: "host")
        #expect(!HostAccessPassword(store: store).isConfigured)
        var wrongVersion = Data(count: 54)
        wrongVersion[0] = 2
        try store.write(wrongVersion, account: "host")
        #expect(!HostAccessPassword(store: store).isConfigured)
    }

    /// A fresh instance reading `service`, retried briefly: while other tests in this process create and delete
    /// keychain identities, the file-based login keychain occasionally answers errSecItemNotFound for an item added
    /// moments earlier (seen about once in five full-suite runs).
    private func reload(_ service: String, until condition: (HostAccessPassword) -> Bool) async -> HostAccessPassword {
        var instance = HostAccessPassword(store: KeychainSecretStore(service: service))
        for _ in 0..<40 where !condition(instance) {
            try? await Task.sleep(for: .milliseconds(50))
            instance = HostAccessPassword(store: KeychainSecretStore(service: service))
        }
        return instance
    }

    /// Real keychain, unique service, cleaned up.
    @Test func keychainStoreRoundTrip() async throws {
        let service = "com.swiftdesk.tests.access-password.\(UUID().uuidString)"
        let keychain = KeychainSecretStore(service: service)
        defer { keychain.deleteAll() }

        let host = HostAccessPassword(store: keychain, iterations: Self.fastRounds)
        try host.set(password: "keychain pass")
        let c = try challenge(for: host)
        let proof = try self.proof(c, "keychain pass")
        let reloaded = await reload(service) { $0.isEnabled }
        #expect(reloaded.isEnabled)
        #expect(reloaded.verify(proof: proof, challenge: c, hostFingerprint: Self.hostFP, viewerFingerprint: Self.viewerFP))
        try reloaded.setEnabled(false)
        let disabled = await reload(service) { $0.isConfigured && !$0.isEnabled }
        #expect(disabled.isConfigured && !disabled.isEnabled)
        reloaded.clear()
        #expect(keychain.read(account: "host") == nil)
    }

    @Test func savedHostPasswordsInKeychain() async throws {
        let service = "com.swiftdesk.tests.host-password.\(UUID().uuidString)"
        let keychain = KeychainSecretStore(service: service)
        defer { keychain.deleteAll() }
        let saved = SavedHostPasswords(store: keychain)
        let fp = Data((0..<32).map { UInt8($0) })
        let hex = TrustedHostStore.hex(fp)
        #expect(saved.password(forFingerprint: fp) == nil && !saved.hasPassword(fingerprintHex: hex))
        // Read back with a short retry: the login keychain occasionally misses an item added moments earlier while
        // other tests create and delete identities (see `reload`).
        func readBack(_ expected: String) async -> String? {
            for _ in 0..<40 where saved.password(forFingerprint: fp) != expected {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return saved.password(forFingerprint: fp)
        }
        try saved.save("pässwörd 1", forFingerprint: fp)
        #expect(await readBack("pässwörd 1") == "pässwörd 1")
        #expect(saved.hasPassword(fingerprintHex: hex.uppercased()))
        try saved.save("second one", forFingerprint: fp)   // update in place
        #expect(await readBack("second one") == "second one")
        #expect(keychain.read(account: hex) == Data("second one".utf8))
        saved.remove(fingerprintHex: hex)
        #expect(saved.password(forFingerprint: fp) == nil)
    }
}
