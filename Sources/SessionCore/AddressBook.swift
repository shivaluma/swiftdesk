import DiagnosticsCore
import Foundation

/// One address a saved Host was reached at (what the user typed or Bonjour resolved), e.g. `studio.local:47800`.
public struct SavedHostAddress: Sendable, Equatable, Hashable, Codable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// `TrustedHostStore.key(host:port:)`: the same address always has the same key, whatever its spelling.
    public var key: String { TrustedHostStore.key(host: host, port: port) }

    /// `host:port`, IPv6 bracketed (`[fd7a::1]:47800`).
    public var endpoint: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// What "Copy Address" puts on the pasteboard: the bare host on the default port, else `endpoint`. Both paste
    /// into the Viewer's host field.
    public func shareable(defaultPort: UInt16) -> String {
        port == defaultPort ? host : endpoint
    }
}

/// A Host in the Viewer's address book (0.1.8): added automatically on every successful connection ("Recent"),
/// optionally marked as a favorite, renamed, given a thumbnail of the last frame seen.
///
/// The fingerprint is the identity of the entry: the same Mac reached at its LAN address and its Tailscale name is
/// one entry with two addresses. It records what TLS presented on the last successful connection and is **not** a
/// pin — pins stay in `TrustedHostStore` (address-keyed, set only by "Remember this Host"), so connecting from an
/// entry goes through exactly the same verification as typing its address. No secrets live here: saved passwords
/// stay in the keychain (`SavedHostPasswords`, keyed by the same fingerprint).
public struct SavedHost: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// The user's name for it (Rename); nil shows `hostName`.
    public var customName: String?
    /// The name the Host reported in its last ACCEPT (sanitized, display only).
    public var hostName: String
    /// Most recently used first; never empty for a stored entry.
    public var addresses: [SavedHostAddress]
    /// SHA-256 of the Host's certificate on the last successful connection, lowercase hex.
    public var fingerprintHex: String
    public var addedAt: Date
    /// Last successful connection; nil after "Clear History" for a favorite.
    public var lastConnectedAt: Date?
    public var isFavorite: Bool
    /// When the thumbnail (`<id>.jpg` in the thumbnails folder) was last written; nil = no thumbnail. The file name is
    /// derived from `id`, never stored, so an edited JSON file cannot point outside the folder.
    public var thumbnailUpdatedAt: Date?

    public init(id: UUID = UUID(), customName: String? = nil, hostName: String, addresses: [SavedHostAddress],
                fingerprintHex: String, addedAt: Date, lastConnectedAt: Date?, isFavorite: Bool = false,
                thumbnailUpdatedAt: Date? = nil) {
        self.id = id
        self.customName = customName
        self.hostName = hostName
        self.addresses = addresses
        self.fingerprintHex = fingerprintHex
        self.addedAt = addedAt
        self.lastConnectedAt = lastConnectedAt
        self.isFavorite = isFavorite
        self.thumbnailUpdatedAt = thumbnailUpdatedAt
    }

    public var displayName: String { customName ?? hostName }
    public var primaryAddress: SavedHostAddress? { addresses.first }
    public var hasThumbnail: Bool { thumbnailUpdatedAt != nil }

    /// Decoded fingerprint, or nil if the stored hex is not 32 bytes.
    public var fingerprint: Data? {
        guard let data = TrustedHostStore.data(fromHex: fingerprintHex), data.count == 32 else { return nil }
        return data
    }

    /// How `address` relates to the pins in `TrustedHostStore` (pass `TrustedHostStore.list()` or
    /// `ViewerSession.trustedHosts`).
    public func pinState(of address: SavedHostAddress, trusted: [TrustedHost]) -> SavedHostPinState {
        guard let pin = trusted.first(where: { $0.key == address.key }) else { return .unpinned }
        return pin.fingerprintHex.lowercased() == fingerprintHex.lowercased() ? .pinned : .pinnedToOtherIdentity
    }
}

/// An address book entry's address against the trusted-host pins.
public enum SavedHostPinState: Sendable, Equatable {
    /// Pinned to this entry's identity: connecting goes straight to the Host's approval.
    case pinned
    /// Not pinned: connecting asks the user to verify the fingerprint, as for a typed address.
    case unpinned
    /// Pinned to a different certificate: connecting will fail with "Host identity changed" until the pin is removed.
    case pinnedToOtherIdentity
}

/// Favorites and Recent as the connect screen lists them.
public struct SavedHostSections: Sendable, Equatable {
    /// Favorites by name.
    public var favorites: [SavedHost]
    /// Everything else, most recently connected first.
    public var recent: [SavedHost]

    public init(_ entries: [SavedHost]) {
        favorites = entries.filter(\.isFavorite).sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.addedAt < $1.addedAt : order == .orderedAscending
        }
        recent = entries.filter { !$0.isFavorite }.sorted(by: SavedHost.mostRecentFirst)
    }
}

extension SavedHost {
    static func mostRecentFirst(_ a: SavedHost, _ b: SavedHost) -> Bool {
        let ta = a.lastConnectedAt ?? a.addedAt
        let tb = b.lastConnectedAt ?? b.addedAt
        return ta == tb ? a.addedAt > b.addedAt : ta > tb
    }
}

/// The Viewer's address book: saved Hosts plus their thumbnails, local only.
///
/// Storage: `<directory>/AddressBook.json` (version 1, a list of `SavedHost`) and `<directory>/Thumbnails/<id>.jpg`,
/// where `directory` is `~/Library/Application Support/SwiftDesk` in the app (`defaultDirectory()`) and a temporary
/// folder in tests. Files are written atomically with `.completeFileProtectionUntilFirstUserAuthentication` (the
/// counterpart of the keychain's AfterFirstUnlock) and POSIX 0600 (folders 0700); thumbnails are excluded from
/// backups. Nothing secret is stored: names, addresses, the certificate fingerprint (public) and dates.
///
/// Damaged files (review 0.2.0): entries are decoded one at a time, so one malformed entry costs only that entry. A
/// file that cannot be read, or has entries that cannot be decoded, is never silently replaced: it is renamed aside
/// (`AddressBook.unreadable-<date>.json`) just before the first save, and thumbnails are not cleaned up as orphans
/// meanwhile. A file from a newer format version (a downgrade) is shown as an empty book and never overwritten:
/// changes stay in memory for this run. Entries that decode but fail validation (bad fingerprint, duplicate identity,
/// no address) are unusable and dropped as before.
///
/// Rules: `recordConnection` merges by fingerprint (a known identity at a new address gains that address); an
/// address belongs to one identity at a time (a different certificate at a known address moves the address, and an
/// entry left without addresses is removed with its thumbnail). Non-favorites are capped at `recentLimit` (oldest
/// connection evicted first); favorites are never evicted.
///
/// Thread safety: every operation runs under `lock` on an in-memory copy loaded once; the file is rewritten after each
/// change. Not on any hot path (a handful of calls per session).
public final class AddressBookStore: @unchecked Sendable {
    public static let defaultRecentLimit = 20
    /// At most this many addresses per entry (most recent kept).
    public static let maxAddressesPerHost = 8
    static let fileName = "AddressBook.json"
    static let thumbnailFolderName = "Thumbnails"
    static let formatVersion = 1

    public let directory: URL
    public let recentLimit: Int
    private let lock = NSLock()
    private var cache: [SavedHost]?
    /// What `load()` found on disk; decides how `save()` treats the existing file.
    private var fileCondition = FileCondition.clean

    private enum FileCondition {
        /// Missing, or read in full: saving replaces it.
        case clean
        /// Present but unreadable, or with entries that did not decode: renamed aside before the first save.
        case damaged
        /// Written by a newer SwiftDesk: never overwritten.
        case newer
    }

    public init(directory: URL, recentLimit: Int = AddressBookStore.defaultRecentLimit) {
        self.directory = directory
        self.recentLimit = max(1, recentLimit)
    }

    /// `~/Library/Application Support/SwiftDesk`.
    public static func defaultDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("SwiftDesk", isDirectory: true)
    }

    /// The app's store, or nil if Application Support cannot be located.
    public static func standard() -> AddressBookStore? {
        defaultDirectory().map { AddressBookStore(directory: $0) }
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var thumbnailDirectory: URL { directory.appendingPathComponent(Self.thumbnailFolderName, isDirectory: true) }

    // MARK: Reading

    /// Every entry, most recently connected first.
    public func list() -> [SavedHost] {
        lock.withLock { load().sorted(by: SavedHost.mostRecentFirst) }
    }

    public func sections() -> SavedHostSections { SavedHostSections(list()) }

    public func entry(id: UUID) -> SavedHost? {
        lock.withLock { load().first { $0.id == id } }
    }

    public func entry(fingerprint: Data) -> SavedHost? {
        let hex = TrustedHostStore.hex(fingerprint)
        return lock.withLock { load().first { $0.fingerprintHex == hex } }
    }

    /// The entry that currently owns `host:port`, if any.
    public func entry(host: String, port: UInt16) -> SavedHost? {
        let key = TrustedHostStore.key(host: host, port: port)
        return lock.withLock { load().first { $0.addresses.contains { $0.key == key } } }
    }

    /// Where the thumbnail of `entry` is (nil if it has none). The file may be read off the main actor.
    public func thumbnailURL(for entry: SavedHost) -> URL? {
        entry.hasThumbnail ? thumbnailURL(id: entry.id) : nil
    }

    public func thumbnailData(for entry: SavedHost) -> Data? {
        thumbnailURL(for: entry).flatMap { try? Data(contentsOf: $0) }
    }

    func thumbnailURL(id: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    // MARK: Changes

    /// A successful connection to `host:port` whose certificate is `fingerprint` (call after ACCEPT). Returns the
    /// entry as stored.
    @discardableResult
    public func recordConnection(host rawHost: String, port: UInt16, fingerprint: Data, hostName: String,
                                 now: Date = Date()) -> SavedHost {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = SavedHostAddress(host: host, port: port)
        let hex = TrustedHostStore.hex(fingerprint)
        let name = SessionSupport.displayName(hostName)
        return lock.withLock {
            var all = load()
            // The address now belongs to this identity: take it away from any other entry.
            var orphaned: [UUID] = []
            for index in all.indices where all[index].fingerprintHex != hex {
                all[index].addresses.removeAll { $0.key == address.key }
                if all[index].addresses.isEmpty { orphaned.append(all[index].id) }
            }
            all.removeAll { orphaned.contains($0.id) }
            orphaned.forEach(removeThumbnailFile)

            let entry: SavedHost
            if let index = all.firstIndex(where: { $0.fingerprintHex == hex }) {
                var existing = all[index]
                existing.hostName = name
                existing.addresses.removeAll { $0.key == address.key }
                existing.addresses.insert(address, at: 0)
                if existing.addresses.count > Self.maxAddressesPerHost {
                    existing.addresses.removeLast(existing.addresses.count - Self.maxAddressesPerHost)
                }
                existing.lastConnectedAt = now
                all[index] = existing
                entry = existing
            } else {
                entry = SavedHost(hostName: name, addresses: [address], fingerprintHex: hex, addedAt: now,
                                  lastConnectedAt: now)
                all.append(entry)
            }
            evictBeyondLimit(&all)
            save(all)
            return entry
        }
    }

    /// Sets the user's name for an entry; empty (or whitespace only) goes back to the Host's own name.
    public func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom: String? = trimmed.isEmpty ? nil : SessionSupport.displayName(trimmed)
        mutate(id: id) { $0.customName = custom }
    }

    /// Adds to / removes from Favorites. Removing makes it an ordinary recent entry again (subject to the cap).
    public func setFavorite(id: UUID, _ favorite: Bool) {
        lock.withLock {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].isFavorite != favorite else { return }
            all[index].isFavorite = favorite
            if !favorite { evictBeyondLimit(&all) }
            save(all)
        }
    }

    /// Removes an entry and deletes its thumbnail. Pins and saved passwords are untouched (they have their own UI).
    public func remove(id: UUID) {
        lock.withLock {
            var all = load()
            guard all.contains(where: { $0.id == id }) else { return }
            all.removeAll { $0.id == id }
            removeThumbnailFile(id)
            save(all)
        }
    }

    /// "Clear History": removes every non-favorite entry and every thumbnail, and forgets when favorites were last
    /// used. Favorites (name, addresses) stay.
    public func clearHistory() {
        lock.withLock {
            var all = load().filter(\.isFavorite)
            for index in all.indices {
                all[index].lastConnectedAt = nil
                all[index].thumbnailUpdatedAt = nil
            }
            try? FileManager.default.removeItem(at: thumbnailDirectory)
            save(all)
        }
    }

    /// Stores `jpeg` as the entry's thumbnail (replacing the previous one). False if the entry is gone or the
    /// write failed.
    @discardableResult
    public func saveThumbnail(_ jpeg: Data, for id: UUID, now: Date = Date()) -> Bool {
        lock.withLock {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
            do {
                try ensureDirectory(thumbnailDirectory, excludeFromBackup: true)
                try write(jpeg, to: thumbnailURL(id: id))
            } catch {
                Log.session.error("Could not save a Host thumbnail")
                return false
            }
            all[index].thumbnailUpdatedAt = now
            save(all)
            return true
        }
    }

    /// Deletes every thumbnail (the "Save thumbnails" switch turned off); entries stay.
    public func removeAllThumbnails() {
        lock.withLock {
            var all = load()
            let had = all.contains(where: \.hasThumbnail)
            for index in all.indices { all[index].thumbnailUpdatedAt = nil }
            try? FileManager.default.removeItem(at: thumbnailDirectory)
            if had { save(all) }
        }
    }

    /// Deletes everything (tests, reset).
    public func removeAll() {
        lock.withLock {
            try? FileManager.default.removeItem(at: thumbnailDirectory)
            try? FileManager.default.removeItem(at: fileURL)
            cache = []
            fileCondition = .clean
        }
    }

    // MARK: Private (call with `lock` held)

    private func mutate(id: UUID, _ change: (inout SavedHost) -> Void) {
        lock.withLock {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            let before = all[index]
            change(&all[index])
            if all[index] != before { save(all) }
        }
    }

    /// Drops the oldest non-favorites beyond `recentLimit`, with their thumbnails.
    private func evictBeyondLimit(_ all: inout [SavedHost]) {
        let recent = all.filter { !$0.isFavorite }.sorted(by: SavedHost.mostRecentFirst)
        guard recent.count > recentLimit else { return }
        let evicted = Set(recent[recentLimit...].map(\.id))
        all.removeAll { evicted.contains($0.id) }
        evicted.forEach(removeThumbnailFile)
    }

    private func removeThumbnailFile(_ id: UUID) {
        try? FileManager.default.removeItem(at: thumbnailURL(id: id))
    }

    private struct FileFormat: Codable {
        var version: Int
        var hosts: [SavedHost]
    }

    private struct FileHeader: Decodable {
        var version: Int
    }

    /// Version 1 read leniently: an entry that does not decode is nil instead of failing the whole file.
    private struct LenientFileFormat: Decodable {
        var hosts: [LenientEntry]
    }

    private struct LenientEntry: Decodable {
        var host: SavedHost?
        init(from decoder: any Decoder) throws { host = try? SavedHost(from: decoder) }
    }

    private func load() -> [SavedHost] {
        if let cache { return cache }
        var hosts: [SavedHost] = []
        var condition = FileCondition.clean
        var decoded: [SavedHost] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            condition = .damaged
            if let data = try? Data(contentsOf: fileURL),
               let header = try? JSONDecoder.addressBook.decode(FileHeader.self, from: data) {
                if header.version > Self.formatVersion {
                    condition = .newer
                } else if header.version == Self.formatVersion,
                          let file = try? JSONDecoder.addressBook.decode(LenientFileFormat.self, from: data) {
                    decoded = file.hosts.compactMap(\.host)
                    if decoded.count == file.hosts.count { condition = .clean }
                }
            }
        }
        switch condition {
        case .clean: break
        case .damaged: Log.session.error("Address book file is damaged; it is kept aside at the next save")
        case .newer: Log.session.notice("Address book file is from a newer SwiftDesk; it is not overwritten")
        }
        var seen = Set<String>()
        var ids = Set<UUID>()
        for var host in decoded {
            // Same validation as on write: a hand-edited or damaged file never yields an unusable entry.
            host.fingerprintHex = host.fingerprintHex.lowercased()
            guard host.fingerprint != nil, !seen.contains(host.fingerprintHex), !ids.contains(host.id) else { continue }
            host.addresses = host.addresses.filter { !$0.host.isEmpty && $0.port != 0 }
            guard !host.addresses.isEmpty else { continue }
            host.hostName = SessionSupport.displayName(host.hostName)
            host.customName = host.customName.map { SessionSupport.displayName($0) }
            if host.thumbnailUpdatedAt != nil,
               !FileManager.default.fileExists(atPath: thumbnailURL(id: host.id).path) {
                host.thumbnailUpdatedAt = nil
            }
            seen.insert(host.fingerprintHex)
            ids.insert(host.id)
            hosts.append(host)
        }
        cache = hosts
        fileCondition = condition
        // Only when every entry was read: an entry that could not be decoded may still own its thumbnail.
        if condition == .clean {
            removeOrphanedThumbnails(keeping: Set(hosts.filter(\.hasThumbnail).map(\.id)))
        }
        return hosts
    }

    /// Thumbnails whose entry is gone (e.g. the JSON was deleted by hand) are removed at load.
    private func removeOrphanedThumbnails(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: thumbnailDirectory,
                                                                       includingPropertiesForKeys: nil) else { return }
        let keep = Set(ids.map { "\($0.uuidString).jpg" })
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func save(_ hosts: [SavedHost]) {
        cache = hosts
        guard fileCondition != .newer else { return }   // kept in memory; the newer file stays as it is
        do {
            try ensureDirectory(directory, excludeFromBackup: false)
            if fileCondition == .damaged {
                try moveDamagedFileAside()
                fileCondition = .clean
            }
            let data = try JSONEncoder.addressBook.encode(FileFormat(version: Self.formatVersion, hosts: hosts))
            try write(data, to: fileURL)
        } catch {
            // Kept in memory for this run; the next change tries again.
            Log.session.error("Could not save the address book")
        }
    }

    /// `AddressBook.json` → `AddressBook.unreadable-<yyyyMMdd-HHmmss>.json` (a suffix if that exists), so a file this
    /// version could not read is never lost to the first save.
    private func moveDamagedFileAside() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var target = directory.appendingPathComponent("AddressBook.unreadable-\(stamp).json")
        if fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("AddressBook.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        }
        try fm.moveItem(at: fileURL, to: target)
        Log.session.notice("Damaged address book file kept aside")
    }

    private func ensureDirectory(_ url: URL, excludeFromBackup: Bool) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if excludeFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutable = url
                try? mutable.setResourceValues(values)
            }
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    fileprivate static var addressBook: JSONEncoder {
        let encoder = JSONEncoder()
        // Dates keep the default (seconds since 2001 as a Double), which round-trips exactly.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var addressBook: JSONDecoder { JSONDecoder() }
}
