import CommonCrypto
import CryptoKit
import Foundation
import WireProtocol

/// The password-access construction shared by Host and Viewer (opt-in unattended access).
///
/// - `key = PBKDF2-HMAC-SHA256(UTF-8(NFC(password)), salt, iterations)`, 32 bytes (CommonCrypto).
/// - `proof = HMAC-SHA256(key, "swiftdesk-password-v1" ‖ nonce ‖ hostFingerprint ‖ viewerFingerprint)` (CryptoKit).
///
/// The Host stores only `{salt, iterations, key}`, never the password, and verifies a proof with one HMAC (no
/// PBKDF2 per attempt, so failed attempts cost the Host nothing). The fingerprints are the SHA-256 certificate
/// fingerprints both sides observed in mutual TLS, so a proof is bound to this channel and both identities and
/// cannot be relayed to another Host or replayed with another nonce. Unicode NFC normalization makes "é" typed as
/// one scalar or as "e" + combining accent the same password.
public enum AccessPassword {
    /// Shortest password the UI and `HostAccessPassword.set(password:)` accept, in Characters.
    public static let minimumLength = 8
    /// PBKDF2 rounds for new passwords: ≈146 ms on an Apple M4 Pro (measured 2026-11-03, best of 5), so an offline
    /// guess against a stolen key costs as much as an online one for the Viewer.
    public static let defaultIterations: UInt32 = 1_000_000
    /// Rounds a Viewer accepts in a challenge. The floor is `defaultIterations`, the cost every real SwiftDesk Host
    /// uses: a lower floor would only let a hostile Host (one the user trusted without comparing the fingerprint)
    /// harvest a proof that is cheaper to crack offline than one for the real Host. Above the ceiling a hostile Host
    /// could make the Viewer burn CPU (5 000 000 ≈ 0.75 s on M4 Pro).
    public static let acceptedIterations: ClosedRange<UInt32> = defaultIterations...5_000_000
    public static let saltSize = PasswordChallenge.saltSize
    public static let keySize = 32
    /// Domain-separation prefix of the proof MAC.
    public static let proofContext = Data("swiftdesk-password-v1".utf8)

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case tooShort(minimum: Int)
        case derivationFailed(Int32)
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .tooShort(let minimum): "The password must have at least \(minimum) characters"
            case .derivationFailed(let status): "Password key derivation failed (\(status))"
            case .keychain(let status): "The keychain refused the password (\(status))"
            }
        }
    }

    /// UTF-8 bytes of the NFC-normalized password.
    public static func normalizedBytes(_ password: String) -> Data {
        Data(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// PBKDF2-HMAC-SHA256 → 32-byte key. CPU-bound (~150 ms at the default rounds): never call on the main actor.
    public static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> Data {
        let secret = normalizedBytes(password)
        var key = Data(count: keySize)
        let status: Int32 = key.withUnsafeMutableBytes { keyRaw in
            secret.withUnsafeBytes { secretRaw in
                salt.withUnsafeBytes { saltRaw in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secretRaw.baseAddress?.assumingMemoryBound(to: CChar.self), secretRaw.count,
                                         saltRaw.baseAddress?.assumingMemoryBound(to: UInt8.self), saltRaw.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         keyRaw.baseAddress?.assumingMemoryBound(to: UInt8.self), keySize)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw Failure.derivationFailed(status) }
        return key
    }

    /// The bytes the proof authenticates.
    static func proofMessage(nonce: Data, hostFingerprint: Data, viewerFingerprint: Data) -> Data {
        var message = proofContext
        message.append(nonce)
        message.append(hostFingerprint)
        message.append(viewerFingerprint)
        return message
    }

    /// HMAC-SHA256 proof for one challenge.
    public static func proof(key: Data, nonce: Data, hostFingerprint: Data, viewerFingerprint: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: proofMessage(nonce: nonce, hostFingerprint: hostFingerprint, viewerFingerprint: viewerFingerprint),
            using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Constant-time check (CryptoKit `isValidAuthenticationCode`). Wrong-sized proofs are rejected.
    public static func verify(proof: Data, key: Data, nonce: Data, hostFingerprint: Data, viewerFingerprint: Data) -> Bool {
        guard proof.count == PasswordResponse.proofSize, key.count == keySize else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: proofMessage(nonce: nonce, hostFingerprint: hostFingerprint, viewerFingerprint: viewerFingerprint),
            using: SymmetricKey(data: key))
    }

    /// Viewer side: the proof for `challenge`, or nil if its rounds are outside `acceptedIterations`.
    /// Runs PBKDF2: call off the main actor.
    public static func answer(_ challenge: PasswordChallenge, password: String, hostFingerprint: Data,
                              viewerFingerprint: Data) throws -> Data? {
        guard acceptedIterations.contains(challenge.iterations) else { return nil }
        let key = try deriveKey(password: password, salt: challenge.salt, iterations: challenge.iterations)
        return proof(key: key, nonce: challenge.nonce, hostFingerprint: hostFingerprint,
                     viewerFingerprint: viewerFingerprint)
    }

    /// True if `password` meets the minimum length.
    public static func isAcceptable(_ password: String) -> Bool {
        password.count >= minimumLength
    }
}

// MARK: - Keychain storage

/// A small generic-password keychain wrapper (one service, items keyed by account). Thread-safe: every call is a
/// single Security framework operation.
///
/// Uses the default (login) keychain like `DeviceIdentity`, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so an unattended Host can read it after a reboot and the item never syncs or migrates to another Mac.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AccessPassword.Failure.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = service
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccessPassword.Failure.keychain(status) }
    }

    public func delete(account: String) {
        _ = SecItemDelete(query(account) as CFDictionary)
    }

    /// Deletes every item of this service (tests, "forget all").
    public func deleteAll() {
        _ = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
    }
}

/// Where password material lives. Production: `KeychainSecretStore`; tests may use `InMemorySecretStore`.
public protocol SecretStore: AnyObject, Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String)
}

/// Non-persistent `SecretStore` for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(account: String) -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) { lock.withLock { items[account] = nil } }
}

// MARK: - Host

/// The Host's access password: `{salt, iterations, key}` plus an enabled flag in one keychain item
/// (service `com.swiftdesk.access-password`). The password itself is never stored, and nothing goes to UserDefaults.
///
/// Thread safety: the cached record sits behind `lock`; the keychain is the source of truth at init.
public final class HostAccessPassword: @unchecked Sendable {
    public static let keychainService = "com.swiftdesk.access-password"
    static let account = "host"

    /// What the keychain item holds. Layout: u8 version (1), u8 enabled, u32 iterations, 16 salt, 32 key.
    public struct Record: Sendable, Equatable {
        public var salt: Data
        public var iterations: UInt32
        public var key: Data
        public var enabled: Bool

        static let version: UInt8 = 1
        static let encodedSize = 2 + 4 + AccessPassword.saltSize + AccessPassword.keySize

        func encoded() -> Data {
            var w = ByteWriter(capacity: Self.encodedSize)
            w.u8(Self.version)
            w.bool(enabled)
            w.u32(iterations)
            w.fixedBytes(salt, count: AccessPassword.saltSize)
            w.fixedBytes(key, count: AccessPassword.keySize)
            return w.data
        }

        static func decode(_ data: Data) -> Record? {
            var r = ByteReader(data)
            guard data.count == encodedSize, (try? r.u8()) == version,
                  let enabled = try? r.bool(), let iterations = try? r.u32(),
                  let salt = try? r.bytes(count: AccessPassword.saltSize),
                  let key = try? r.bytes(count: AccessPassword.keySize) else { return nil }
            return Record(salt: salt, iterations: iterations, key: key, enabled: enabled)
        }
    }

    private let store: any SecretStore
    private let iterations: UInt32
    private let lock = NSLock()
    private var record: Record?

    /// - Parameter iterations: PBKDF2 rounds for new passwords (tests use fewer).
    public init(store: any SecretStore = KeychainSecretStore(service: HostAccessPassword.keychainService),
                iterations: UInt32 = AccessPassword.defaultIterations) {
        self.store = store
        self.iterations = iterations
        self.record = store.read(account: Self.account).flatMap(Record.decode)
    }

    /// A password is set (enabled or not).
    public var isConfigured: Bool { lock.withLock { record != nil } }

    /// Password access is on: a password is set and enabled.
    public var isEnabled: Bool { lock.withLock { record?.enabled ?? false } }

    /// Sets a new password (fresh random salt). The first password turns password access on; replacing a password
    /// keeps the current on/off switch, so changing a password that was switched off never turns unattended access
    /// back on. Runs PBKDF2: call off the main actor.
    public func set(password: String) throws {
        guard AccessPassword.isAcceptable(password) else { throw AccessPassword.Failure.tooShort(minimum: AccessPassword.minimumLength) }
        let salt = try SecureRandom.bytes(AccessPassword.saltSize)
        let key = try AccessPassword.deriveKey(password: password, salt: salt, iterations: iterations)
        let enabled = lock.withLock { record?.enabled } ?? true
        try save(Record(salt: salt, iterations: iterations, key: key, enabled: enabled))
    }

    /// Turns password access on or off without forgetting the password. No-op without a password.
    public func setEnabled(_ enabled: Bool) throws {
        guard var current = lock.withLock({ record }), current.enabled != enabled else { return }
        current.enabled = enabled
        try save(current)
    }

    /// Forgets the password (deletes the keychain item).
    public func clear() {
        store.delete(account: Self.account)
        lock.withLock { record = nil }
    }

    /// Salt and rounds for a new challenge, nil unless enabled.
    public func challengeParameters() -> (salt: Data, iterations: UInt32)? {
        lock.withLock {
            guard let record, record.enabled else { return nil }
            return (record.salt, record.iterations)
        }
    }

    /// Outcome of checking a proof against the current record.
    public enum ProofResult: Sendable, Equatable {
        /// The proof matches: the Viewer knows the password.
        case valid
        /// The proof does not match the password this challenge was issued for: a wrong password.
        case invalid
        /// The challenge is no longer valid: password access was switched off or removed, or the password changed,
        /// since it was issued. Says nothing about the Viewer's password, so it must not count as a failure.
        case stale
    }

    /// Constant-time proof check against the current record, telling a wrong password apart from a challenge that
    /// went stale (disabled, removed, or another salt/rounds) while the Viewer was answering.
    public func check(proof: Data, challenge: PasswordChallenge, hostFingerprint: Data, viewerFingerprint: Data) -> ProofResult {
        guard let record = lock.withLock({ record }), record.enabled,
              record.salt == challenge.salt, record.iterations == challenge.iterations else { return .stale }
        return AccessPassword.verify(proof: proof, key: record.key, nonce: challenge.nonce,
                                     hostFingerprint: hostFingerprint, viewerFingerprint: viewerFingerprint)
            ? .valid : .invalid
    }

    /// True only for a `.valid` proof (see `check`). False when disabled, or when the challenge was issued for
    /// another salt/rounds (the password changed in between).
    public func verify(proof: Data, challenge: PasswordChallenge, hostFingerprint: Data, viewerFingerprint: Data) -> Bool {
        check(proof: proof, challenge: challenge, hostFingerprint: hostFingerprint, viewerFingerprint: viewerFingerprint) == .valid
    }

    /// Convenience overload matching the design API.
    public func verify(proof: Data, nonce: Data, hostFP: Data, viewerFP: Data) -> Bool {
        guard let params = challengeParameters() else { return false }
        return verify(proof: proof, challenge: PasswordChallenge(salt: params.salt, iterations: params.iterations, nonce: nonce),
                      hostFingerprint: hostFP, viewerFingerprint: viewerFP)
    }

    private func save(_ new: Record) throws {
        try store.write(new.encoded(), account: Self.account)
        lock.withLock { record = new }
    }
}

// MARK: - Viewer

/// Passwords the Viewer remembers for trusted Hosts: keychain generic passwords, service
/// `com.swiftdesk.host-password`, account = the Host's certificate fingerprint (lowercase hex). Saved only for a
/// pinned Host after a successful password login, so a saved password can only ever be offered to the identity it
/// was saved for.
public final class SavedHostPasswords: @unchecked Sendable {
    public static let keychainService = "com.swiftdesk.host-password"

    private let store: any SecretStore

    public init(store: any SecretStore = KeychainSecretStore(service: SavedHostPasswords.keychainService)) {
        self.store = store
    }

    public func password(forFingerprint fingerprint: Data) -> String? {
        store.read(account: TrustedHostStore.hex(fingerprint)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func hasPassword(fingerprintHex: String) -> Bool {
        store.read(account: fingerprintHex.lowercased()) != nil
    }

    public func save(_ password: String, forFingerprint fingerprint: Data) throws {
        try store.write(Data(password.utf8), account: TrustedHostStore.hex(fingerprint))
    }

    public func remove(fingerprintHex: String) {
        store.delete(account: fingerprintHex.lowercased())
    }
}
