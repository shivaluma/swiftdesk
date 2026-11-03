import CryptoKit
import Foundation
import Security
import Synchronization
import DiagnosticsCore

/// Errors raised while loading or creating the device identity.
public enum DeviceIdentityError: Error, Equatable, Sendable, CustomStringConvertible {
    case keychain(operation: String, status: OSStatus)
    case keyGeneration(String)
    case signing(String)
    case invalidCertificate
    case identityUnavailable(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let op, let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain \(op) failed (\(status)): \(message)"
        case .keyGeneration(let m): return "Key generation failed: \(m)"
        case .signing(let m): return "Certificate signing failed: \(m)"
        case .invalidCertificate: return "Generated certificate was rejected by Security.framework"
        case .identityUnavailable(let status): return "Could not form a SecIdentity (\(status))"
        }
    }
}

/// This device's long-lived TLS identity: a self-signed P-256 certificate plus its private key, both stored in
/// the user's login keychain.
///
/// Why self-signed: there is no CA in a peer-to-peer tool, so trust is anchored in the SHA-256 fingerprint of the
/// certificate, which the user compares/pins (PRD §5 "encryption alone is not identity"). The fingerprint must be
/// stable across launches, hence the persistent keychain storage; `regenerate` exists so a user can deliberately
/// rotate it (every peer that pinned the old fingerprint will then refuse the connection, by design).
///
/// Keychain choice: the file-based login keychain is used because the data-protection keychain requires a
/// keychain-access-groups entitlement (a provisioned, signed app) that development builds do not have.
///
/// Immutable after initialization, hence safe to share across queues.
public final class DeviceIdentity: @unchecked Sendable {
    public static let defaultLabel = "SwiftDesk Device Identity"

    public let secIdentity: SecIdentity
    public let certificateDER: Data
    /// SHA-256 of `certificateDER`, 32 bytes.
    public let fingerprint: Data
    /// Keychain label the identity is stored under.
    public let label: String
    /// Subject common name, e.g. "SwiftDesk Mac-mini".
    public let commonName: String

    public var fingerprintDisplay: String { Self.display(fingerprint) }

    init(secIdentity: SecIdentity, certificateDER: Data, label: String, commonName: String) {
        self.secIdentity = secIdentity
        self.certificateDER = certificateDER
        self.fingerprint = Self.fingerprint(ofCertificate: certificateDER)
        self.label = label
        self.commonName = commonName
    }

    /// SHA-256 over a DER certificate: the value peers pin and exchange in AUTH.
    public static func fingerprint(ofCertificate der: Data) -> Data {
        Data(SHA256.hash(data: der))
    }

    /// Short human-comparable form: the first 16 bytes as 8 groups of 4 uppercase hex digits, e.g.
    /// `"3F2A 9C01 77DE 0B44 91AA 5C3E 0F12 D8B7"`. 128 bits is ample for out-of-band visual comparison.
    public static func display(_ fingerprint: Data) -> String {
        groupedHex(fingerprint.prefix(16))
    }

    /// Full 32-byte fingerprint as 16 groups of 4 uppercase hex digits, for diagnostics/export.
    public static func displayFull(_ fingerprint: Data) -> String {
        groupedHex(fingerprint)
    }

    private static func groupedHex(_ bytes: Data) -> String {
        let digits = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(bytes.count * 2 + bytes.count / 2)
        for (i, b) in bytes.enumerated() {
            if i > 0 && i % 2 == 0 { out.append(" ") }
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return out
    }

    // MARK: - Keychain lifecycle

    /// Serializes keychain mutations so two concurrent `loadOrCreate` calls cannot create two identities.
    private static let keychainLock = Mutex(())

    /// Loads the identity stored under `label`, or creates (and stores) a new one if none exists or the stored
    /// key/certificate pair is incomplete or mismatched.
    public static func loadOrCreate(label: String = DeviceIdentity.defaultLabel) throws -> DeviceIdentity {
        try keychainLock.withLock { _ in
            if let existing = try load(label: label) { return existing }
            try deleteItems(label: label)
            return try create(label: label, commonName: defaultCommonName())
        }
    }

    /// Deletes any stored identity under `label` and creates a fresh one (new key, new fingerprint).
    public static func regenerate(label: String = DeviceIdentity.defaultLabel) throws -> DeviceIdentity {
        try keychainLock.withLock { _ in
            try deleteItems(label: label)
            return try create(label: label, commonName: defaultCommonName())
        }
    }

    /// An identity held in process memory only, imported from a PKCS#12 blob (`kSecImportToMemoryOnly`): no keychain
    /// read or write. For headless tools (NetBench over SSH, where the login keychain is not writable) and tests;
    /// the app itself uses `loadOrCreate`.
    public static func importPKCS12(_ data: Data, password: String, label: String = "ephemeral") throws -> DeviceIdentity {
        let options: [CFString: Any] = [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identityObject = first[kSecImportItemIdentity as String] as CFTypeRef?,
              CFGetTypeID(identityObject) == SecIdentityGetTypeID() else {
            throw DeviceIdentityError.identityUnavailable(status == errSecSuccess ? errSecItemNotFound : status)
        }
        let identity = identityObject as! SecIdentity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certStatus == errSecSuccess, let certificate else {
            throw DeviceIdentityError.identityUnavailable(certStatus)
        }
        let der = SecCertificateCopyData(certificate) as Data
        let cn = (SecCertificateCopySubjectSummary(certificate) as String?) ?? label
        return DeviceIdentity(secIdentity: identity, certificateDER: der, label: label, commonName: cn)
    }

    /// Removes the key and certificate stored under `label`. Missing items are not an error.
    public static func delete(label: String) throws {
        try keychainLock.withLock { _ in try deleteItems(label: label) }
    }

    static func applicationTag(for label: String) -> Data {
        Data("com.swiftdesk.identity.\(label)".utf8)
    }

    static func defaultCommonName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        var host = "Mac"
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let raw = String(decoding: bytes, as: UTF8.self)
            let trimmed = raw.hasSuffix(".local") ? String(raw.dropLast(6)) : raw
            if !trimmed.isEmpty { host = trimmed }
        }
        return "SwiftDesk \(host)"
    }

    /// The stored private key for `label` and its keychain application label (SHA-1 of the public key), which
    /// is how the file-based keychain links a key to its certificate (`kSecAttrPublicKeyHash`).
    private static func storedKey(label: String) throws -> (key: SecKey, publicKeyHash: Data)? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: applicationTag(for: label),
            kSecReturnRef: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let keyObject = attributes[kSecValueRef as String] as CFTypeRef?,
              CFGetTypeID(keyObject) == SecKeyGetTypeID(),
              let hash = attributes[kSecAttrApplicationLabel as String] as? Data else {
            throw DeviceIdentityError.keychain(operation: "load key", status: status)
        }
        return (keyObject as! SecKey, hash)
    }

    private static func load(label: String) throws -> DeviceIdentity? {
        guard let (privateKey, publicKeyHash) = try storedKey(label: label) else { return nil }
        // The keychain ignores kSecAttrLabel for certificates (it stores the subject CN), so the certificate is
        // found through the public key hash it shares with the private key.
        let certQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrPublicKeyHash: publicKeyHash,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var certRef: CFTypeRef?
        let certStatus = SecItemCopyMatching(certQuery as CFDictionary, &certRef)
        if certStatus == errSecItemNotFound { return nil }
        guard certStatus == errSecSuccess, let certObject = certRef, CFGetTypeID(certObject) == SecCertificateGetTypeID() else {
            throw DeviceIdentityError.keychain(operation: "load certificate", status: certStatus)
        }
        let certificate = certObject as! SecCertificate

        // A key/certificate pair that no longer matches is treated as absent (and regenerated by the caller).
        guard publicKeysMatch(privateKey: privateKey, certificate: certificate) else {
            Log.transport.notice("Stored identity key/certificate mismatch; regenerating")
            return nil
        }
        let identity = try makeIdentity(certificate: certificate, privateKey: privateKey)
        let der = SecCertificateCopyData(certificate) as Data
        let cn = (SecCertificateCopySubjectSummary(certificate) as String?) ?? defaultCommonName()
        return DeviceIdentity(secIdentity: identity, certificateDER: der, label: label, commonName: cn)
    }

    private static func create(label: String, commonName: String) throws -> DeviceIdentity {
        let tag = applicationTag(for: label)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: tag,
                kSecAttrLabel: label,
            ] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw DeviceIdentityError.keyGeneration(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        do {
            let der = try makeCertificateDER(privateKey: privateKey, commonName: commonName)
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw DeviceIdentityError.invalidCertificate
            }
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DeviceIdentityError.keychain(operation: "add certificate", status: addStatus)
            }
            let identity = try makeIdentity(certificate: certificate, privateKey: privateKey)
            Log.transport.notice("Created device identity '\(label, privacy: .public)'")
            return DeviceIdentity(secIdentity: identity, certificateDER: der, label: label, commonName: commonName)
        } catch {
            try? deleteItems(label: label)
            throw error
        }
    }

    /// Builds and signs the certificate DER for `privateKey`. Internal so tests can exercise it with an
    /// ephemeral (non-keychain) key.
    static func makeCertificateDER(privateKey: SecKey, commonName: String, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DeviceIdentityError.keyGeneration("no public key")
        }
        var error: Unmanaged<CFError>?
        guard let x963 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw DeviceIdentityError.keyGeneration(error.map { "\($0.takeRetainedValue())" } ?? "export failed")
        }
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw DeviceIdentityError.keyGeneration("random serial")
        }
        serial[0] = (serial[0] & 0x7F) | 0x40   // positive and exactly 16 octets
        let template = SelfSignedCertificate.Template(
            commonName: commonName,
            serial: serial,
            notBefore: now.addingTimeInterval(-86_400),          // tolerate a day of peer clock skew
            notAfter: now.addingTimeInterval(10 * 365.25 * 86_400),
            publicKeyX963: Array(x963),
            subjectKeyIdentifier: Array(Insecure.SHA1.hash(data: x963)))
        let tbs = SelfSignedCertificate.tbsCertificate(template)
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                                    Data(tbs) as CFData, &error) as Data? else {
            throw DeviceIdentityError.signing(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        return Data(SelfSignedCertificate.certificate(tbs: tbs, signature: Array(signature)))
    }

    static func publicKeysMatch(privateKey: SecKey, certificate: SecCertificate) -> Bool {
        guard let a = SecKeyCopyPublicKey(privateKey), let b = SecCertificateCopyKey(certificate),
              let ra = SecKeyCopyExternalRepresentation(a, nil) as Data?,
              let rb = SecKeyCopyExternalRepresentation(b, nil) as Data? else { return false }
        return ra == rb
    }

    private static func makeIdentity(certificate: SecCertificate, privateKey: SecKey) throws -> SecIdentity {
        if let identity = SecIdentityCreate(nil, certificate, privateKey) { return identity }
        // Fallback: let Security pair the certificate with its private key from the keychain search list.
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw DeviceIdentityError.identityUnavailable(status) }
        return identity
    }

    private static func deleteItems(label: String) throws {
        // Certificate first: it is only reachable through its key's public key hash. Loop in case an earlier crash
        // left more than one key under the same tag.
        for _ in 0..<16 {
            guard let (_, publicKeyHash) = try storedKey(label: label) else { break }
            try deleteAll([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: publicKeyHash])
            try deleteAll([kSecClass: kSecClassKey, kSecAttrApplicationLabel: publicKeyHash,
                           kSecAttrApplicationTag: applicationTag(for: label)])
        }
        try deleteAll([kSecClass: kSecClassKey, kSecAttrApplicationTag: applicationTag(for: label)])
    }

    private static func deleteAll(_ query: [CFString: Any]) throws {
        // The file-based keychain may delete only one match per call; loop until nothing is left.
        for _ in 0..<16 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else {
                throw DeviceIdentityError.keychain(operation: "delete", status: status)
            }
        }
    }
}
