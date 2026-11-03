import Foundation

/// A Host the user explicitly chose to trust, pinned by its certificate fingerprint.
public struct TrustedHost: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// `TrustedHostStore.key(host:port:)`, e.g. "192.168.1.20:47800" or "[fe80::1]:47800".
    public var key: String
    /// SHA-256 of the Host's leaf certificate, lowercase hex (64 characters).
    public var fingerprintHex: String
    /// Host name as reported in ACCEPT (display only; never used for trust decisions).
    public var name: String
    public var addedAt: Date

    public var id: String { key }

    public init(key: String, fingerprintHex: String, name: String, addedAt: Date) {
        self.key = key
        self.fingerprintHex = fingerprintHex
        self.name = name
        self.addedAt = addedAt
    }

    /// Decoded fingerprint, or nil if the stored hex is not 32 bytes.
    public var fingerprint: Data? {
        guard let data = TrustedHostStore.data(fromHex: fingerprintHex), data.count == 32 else { return nil }
        return data
    }
}

/// Persists which Host certificates the user trusts, keyed by the address they dialed.
///
/// Why address-keyed pins: the Viewer passes the stored fingerprint to `PeerConnection.connect`, so TLS itself refuses
/// a different certificate at that address and the session layer never "silently re-pins" — a changed Host identity
/// surfaces as an explicit error that the user resolves by removing the entry. The fingerprint (not the name) is the
/// identity; names are display-only.
///
/// Storage: one property-list `Data` blob under `storageKey` in an injectable `UserDefaults` (tests use a private
/// suite). Not on any hot path. Thread safety: `UserDefaults` is documented thread-safe and every mutation is a
/// read-modify-write under `lock`, so the class can be shared freely.
public final class TrustedHostStore: @unchecked Sendable {
    public static let defaultStorageKey = "SwiftDesk.TrustedHosts.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, storageKey: String = TrustedHostStore.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Canonical "host:port" key. Hostnames are lowercased and a trailing dot is dropped so "Mac.local." and
    /// "mac.local" pin the same entry; IPv6 literals are bracketed.
    public static func key(host: String, port: UInt16) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h.contains(":") ? "[\(h)]:\(port)" : "\(h):\(port)"
    }

    /// All entries, newest first.
    public func list() -> [TrustedHost] {
        lock.withLock { load().values.sorted { $0.addedAt > $1.addedAt } }
    }

    public func entry(host: String, port: UInt16) -> TrustedHost? {
        let key = Self.key(host: host, port: port)
        return lock.withLock { load()[key] }
    }

    /// The fingerprint to pin when dialing `host:port`, if the user trusted it.
    public func pinnedFingerprint(host: String, port: UInt16) -> Data? {
        entry(host: host, port: port)?.fingerprint
    }

    /// True if any entry (at any address) pins this fingerprint — e.g. the same Mac reached over Tailscale after
    /// being trusted on the LAN. The UI can then say "known device" instead of "first connection".
    public func contains(fingerprint: Data) -> Bool {
        let hex = Self.hex(fingerprint)
        return lock.withLock { load().values.contains { $0.fingerprintHex == hex } }
    }

    /// Adds or replaces the pin for `host:port`. Replacing is an explicit user action (the Viewer only calls this from
    /// `trustHost(remember: true)` after the user saw the fingerprint), never an automatic re-pin.
    @discardableResult
    public func add(host: String, port: UInt16, fingerprint: Data, name: String, now: Date = Date()) -> TrustedHost {
        let entry = TrustedHost(key: Self.key(host: host, port: port), fingerprintHex: Self.hex(fingerprint),
                                name: name, addedAt: now)
        lock.withLock {
            var all = load()
            all[entry.key] = entry
            save(all)
        }
        return entry
    }

    /// Updates the display name of an existing entry (e.g. once ACCEPT reports the Host's name).
    public func rename(key: String, to name: String) {
        lock.withLock {
            var all = load()
            guard var entry = all[key], entry.name != name else { return }
            entry.name = name
            all[key] = entry
            save(all)
        }
    }

    public func remove(key: String) {
        lock.withLock {
            var all = load()
            guard all.removeValue(forKey: key) != nil else { return }
            save(all)
        }
    }

    public func remove(host: String, port: UInt16) {
        remove(key: Self.key(host: host, port: port))
    }

    public func removeAll() {
        lock.withLock { defaults.removeObject(forKey: storageKey) }
    }

    // MARK: Hex

    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func data(fromHex hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: Storage (call with `lock` held)

    private func load() -> [String: TrustedHost] {
        guard let blob = defaults.data(forKey: storageKey) else { return [:] }
        // A corrupt blob is treated as "no trusted hosts": failing closed means the user re-verifies fingerprints,
        // which is safe; trusting garbage would not be.
        guard let entries = try? PropertyListDecoder().decode([TrustedHost].self, from: blob) else { return [:] }
        var map: [String: TrustedHost] = [:]
        for entry in entries where entry.fingerprint != nil { map[entry.key] = entry }
        return map
    }

    private func save(_ map: [String: TrustedHost]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let blob = try? encoder.encode(Array(map.values)) else { return }
        defaults.set(blob, forKey: storageKey)
    }
}
