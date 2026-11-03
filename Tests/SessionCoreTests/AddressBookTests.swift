import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import SessionCore

/// A unique folder under the temporary directory, deleted by `cleanUp()`.
final class TemporaryFolder: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDesk.AddressBookTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Address book store")
struct AddressBookTests {
    private static func fingerprint(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data(repeating: 0x42, count: 64)

    @Test func recordCreatesAnEntryAndPersists() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        #expect(store.list().isEmpty)

        let entry = store.recordConnection(host: " Studio.local ", port: 47800, fingerprint: Self.fingerprint(1),
                                           hostName: "Studio\nMac", now: Self.t0)
        #expect(entry.hostName == "Studio Mac", "peer-supplied names are sanitized")
        #expect(entry.displayName == "Studio Mac")
        #expect(entry.addresses == [SavedHostAddress(host: "Studio.local", port: 47800)])
        #expect(entry.fingerprint == Self.fingerprint(1))
        #expect(entry.lastConnectedAt == Self.t0)
        #expect(!entry.isFavorite && !entry.hasThumbnail)

        // A second store over the same folder reads exactly what was written.
        let reopened = AddressBookStore(directory: folder.url)
        #expect(reopened.list() == [entry])
        #expect(reopened.entry(fingerprint: Self.fingerprint(1))?.id == entry.id)
        #expect(reopened.entry(host: "studio.local.", port: 47800)?.id == entry.id, "same key as TrustedHostStore")
        #expect(reopened.entry(host: "studio.local", port: 47801) == nil)
    }

    @Test func renameFavoriteAndRemoveRoundTrip() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        let entry = store.recordConnection(host: "10.0.0.2", port: 47800, fingerprint: Self.fingerprint(2),
                                           hostName: "Mac mini", now: Self.t0)

        store.rename(id: entry.id, to: "  Office  ")
        store.setFavorite(id: entry.id, true)
        var reopened = AddressBookStore(directory: folder.url)
        var stored = try #require(reopened.entry(id: entry.id))
        #expect(stored.displayName == "Office")
        #expect(stored.hostName == "Mac mini")
        #expect(stored.isFavorite)
        #expect(reopened.sections().favorites.map(\.id) == [entry.id])
        #expect(reopened.sections().recent.isEmpty)

        // A new connection updates the Host's name but keeps the user's.
        store.recordConnection(host: "10.0.0.2", port: 47800, fingerprint: Self.fingerprint(2), hostName: "Mac mini M4",
                               now: Self.t0.addingTimeInterval(60))
        stored = try #require(store.entry(id: entry.id))
        #expect(stored.displayName == "Office" && stored.hostName == "Mac mini M4")

        // An empty name goes back to the Host's name.
        store.rename(id: entry.id, to: "   ")
        #expect(store.entry(id: entry.id)?.displayName == "Mac mini M4")

        store.setFavorite(id: entry.id, false)
        #expect(store.sections().recent.map(\.id) == [entry.id])

        #expect(store.saveThumbnail(Self.jpeg, for: entry.id, now: Self.t0))
        let withThumbnail = try #require(store.entry(id: entry.id))
        let url = try #require(store.thumbnailURL(for: withThumbnail))
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.remove(id: entry.id)
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path), "Remove also deletes the thumbnail")
        reopened = AddressBookStore(directory: folder.url)
        #expect(reopened.list().isEmpty)
    }

    @Test func sameIdentityAtAnotherAddressIsOneEntry() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        let lan = store.recordConnection(host: "192.168.1.20", port: 47800, fingerprint: Self.fingerprint(3),
                                         hostName: "Studio", now: Self.t0)
        let tailnet = store.recordConnection(host: "studio.tail1234.ts.net", port: 47800,
                                             fingerprint: Self.fingerprint(3), hostName: "Studio",
                                             now: Self.t0.addingTimeInterval(10))
        #expect(lan.id == tailnet.id)
        #expect(store.list().count == 1)
        #expect(tailnet.addresses.map(\.host) == ["studio.tail1234.ts.net", "192.168.1.20"], "most recent first")
        // Using the LAN address again moves it back to the front, without a duplicate.
        let again = store.recordConnection(host: "192.168.1.20", port: 47800, fingerprint: Self.fingerprint(3),
                                           hostName: "Studio", now: Self.t0.addingTimeInterval(20))
        #expect(again.addresses.map(\.host) == ["192.168.1.20", "studio.tail1234.ts.net"])
    }

    @Test func aDifferentIdentityAtAKnownAddressTakesTheAddress() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        let old = store.recordConnection(host: "10.0.0.5", port: 47800, fingerprint: Self.fingerprint(4),
                                         hostName: "Old Mac", now: Self.t0)
        store.recordConnection(host: "old.local", port: 47800, fingerprint: Self.fingerprint(4), hostName: "Old Mac",
                               now: Self.t0.addingTimeInterval(1))
        #expect(store.saveThumbnail(Self.jpeg, for: old.id))

        // The Mac at 10.0.0.5 was reinstalled (new certificate): the address moves to the new identity.
        let new = store.recordConnection(host: "10.0.0.5", port: 47800, fingerprint: Self.fingerprint(5),
                                         hostName: "New Mac", now: Self.t0.addingTimeInterval(2))
        #expect(new.id != old.id)
        #expect(store.entry(id: old.id)?.addresses.map(\.host) == ["old.local"])
        #expect(store.entry(host: "10.0.0.5", port: 47800)?.id == new.id)

        // Losing its last address removes the old entry together with its thumbnail.
        let thumbnail = store.thumbnailURL(id: old.id)
        store.recordConnection(host: "old.local", port: 47800, fingerprint: Self.fingerprint(5), hostName: "New Mac",
                               now: Self.t0.addingTimeInterval(3))
        #expect(store.entry(id: old.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(store.list().count == 1)
    }

    @Test func recentListIsCappedButFavoritesAreKept() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url, recentLimit: 3)
        let favorite = store.recordConnection(host: "fav.local", port: 47800, fingerprint: Self.fingerprint(100),
                                              hostName: "Favorite", now: Self.t0)
        store.setFavorite(id: favorite.id, true)
        var ids: [UUID] = []
        for i in 0..<5 {
            let entry = store.recordConnection(host: "10.0.0.\(i + 1)", port: 47800,
                                               fingerprint: Self.fingerprint(UInt8(i + 1)), hostName: "Mac \(i)",
                                               now: Self.t0.addingTimeInterval(Double(i + 1)))
            store.saveThumbnail(Self.jpeg, for: entry.id)
            ids.append(entry.id)
        }
        let sections = store.sections()
        #expect(sections.recent.map(\.id) == Array(ids.suffix(3).reversed()), "newest first, oldest evicted")
        #expect(sections.favorites.map(\.id) == [favorite.id], "the favorite is older than all of them and stays")
        // Evicted entries lose their thumbnails too.
        #expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(id: ids[0]).path))
        #expect(FileManager.default.fileExists(atPath: store.thumbnailURL(id: ids[4]).path))

        // Unfavoriting the (oldest) favorite makes it the one that goes.
        store.setFavorite(id: favorite.id, false)
        #expect(store.entry(id: favorite.id) == nil)
        #expect(store.list().count == 3)
        #expect(AddressBookStore(directory: folder.url).list().count == 3)
    }

    @Test func clearHistoryKeepsFavoritesOnly() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        let favorite = store.recordConnection(host: "fav.local", port: 47800, fingerprint: Self.fingerprint(1),
                                              hostName: "Favorite", now: Self.t0)
        store.setFavorite(id: favorite.id, true)
        let recent = store.recordConnection(host: "recent.local", port: 47800, fingerprint: Self.fingerprint(2),
                                            hostName: "Recent", now: Self.t0)
        store.saveThumbnail(Self.jpeg, for: favorite.id)
        store.saveThumbnail(Self.jpeg, for: recent.id)

        store.clearHistory()
        let reopened = AddressBookStore(directory: folder.url)
        let remaining = reopened.list()
        #expect(remaining.map(\.id) == [favorite.id])
        #expect(remaining.first?.lastConnectedAt == nil)
        #expect(remaining.first?.hasThumbnail == false)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: store.thumbnailDirectory.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func removeAllThumbnailsKeepsEntries() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        let entry = store.recordConnection(host: "a.local", port: 47800, fingerprint: Self.fingerprint(1),
                                           hostName: "A", now: Self.t0)
        #expect(store.saveThumbnail(Self.jpeg, for: entry.id))
        let stored = try #require(store.entry(id: entry.id))
        #expect(store.thumbnailData(for: stored) == Self.jpeg)
        store.removeAllThumbnails()
        #expect(store.entry(id: entry.id)?.hasThumbnail == false)
        #expect(store.list().count == 1)
        #expect(!store.saveThumbnail(Self.jpeg, for: UUID()), "no thumbnail without an entry")
    }

    @Test func filesAreProtectedAndHoldNoSecrets() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url.appendingPathComponent("SwiftDesk"))
        let entry = store.recordConnection(host: "a.local", port: 47800, fingerprint: Self.fingerprint(0xAB),
                                           hostName: "A", now: Self.t0)
        store.saveThumbnail(Self.jpeg, for: entry.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let thumbAttributes = try FileManager.default.attributesOfItem(atPath: store.thumbnailURL(id: entry.id).path)
        #expect((thumbAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let protection = try store.fileURL.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        #expect(protection == .completeUntilFirstUserAuthentication)
        // The JSON holds names, addresses, the public certificate hash and dates; no file paths or passwords.
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains(String(repeating: "ab", count: 32)))
        #expect(!json.contains(".jpg") && !json.lowercased().contains("password"))
    }

    @Test func corruptOrTamperedFilesFailClosed() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.list().isEmpty)

        // Bad fingerprints, duplicate identities and address-less entries are dropped; a stray file in Thumbnails
        // (no entry) is removed; a missing thumbnail file clears the flag.
        let good = SavedHost(hostName: "Good", addresses: [SavedHostAddress(host: "g.local", port: 47800)],
                             fingerprintHex: String(repeating: "CD", count: 32), addedAt: Self.t0,
                             lastConnectedAt: Self.t0, thumbnailUpdatedAt: Self.t0)
        let duplicate = SavedHost(hostName: "Dup", addresses: [SavedHostAddress(host: "d.local", port: 47800)],
                                  fingerprintHex: String(repeating: "cd", count: 32), addedAt: Self.t0,
                                  lastConnectedAt: Self.t0)
        let badFingerprint = SavedHost(hostName: "Bad", addresses: [SavedHostAddress(host: "b.local", port: 47800)],
                                       fingerprintHex: "zz", addedAt: Self.t0, lastConnectedAt: Self.t0)
        let noAddress = SavedHost(hostName: "None", addresses: [], fingerprintHex: String(repeating: "ee", count: 32),
                                  addedAt: Self.t0, lastConnectedAt: Self.t0)
        struct File: Encodable { var version: Int; var hosts: [SavedHost] }
        try JSONEncoder().encode(File(version: 1, hosts: [good, duplicate, badFingerprint, noAddress]))
            .write(to: store.fileURL)
        try FileManager.default.createDirectory(at: store.thumbnailDirectory, withIntermediateDirectories: true)
        let stray = store.thumbnailDirectory.appendingPathComponent("stray.jpg")
        try Self.jpeg.write(to: stray)

        let reopened = AddressBookStore(directory: folder.url)
        let list = reopened.list()
        #expect(list.map(\.id) == [good.id])
        #expect(list.first?.fingerprintHex == String(repeating: "cd", count: 32), "normalized to lowercase")
        #expect(list.first?.hasThumbnail == false)
        #expect(!FileManager.default.fileExists(atPath: stray.path))

        // A future format version is not misread.
        try JSONEncoder().encode(File(version: 2, hosts: [good])).write(to: store.fileURL)
        #expect(AddressBookStore(directory: folder.url).list().isEmpty)
    }

    /// Review 0.2.0: a damaged or newer file is never silently replaced, one bad entry costs only that entry, and
    /// thumbnails are not deleted as orphans while entries could not be read.
    @Test func damagedOrNewerFilesAreNeverOverwrittenSilently() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let store = AddressBookStore(directory: folder.url)
        let favorite = SavedHost(customName: "Studio", hostName: "S", addresses: [SavedHostAddress(host: "s.local", port: 47800)],
                                 fingerprintHex: String(repeating: "aa", count: 32), addedAt: Self.t0,
                                 lastConnectedAt: Self.t0, isFavorite: true)
        let goodJSON = String(decoding: try JSONEncoder().encode(favorite), as: UTF8.self)
        let lostID = UUID()
        // The second entry lacks `addresses` (a required field): it alone cannot be decoded.
        let damaged = #"{"version": 1, "hosts": [\#(goodJSON), {"id": "\#(lostID.uuidString)", "hostName": "Lost"}]}"#
        try Data(damaged.utf8).write(to: store.fileURL)
        try FileManager.default.createDirectory(at: store.thumbnailDirectory, withIntermediateDirectories: true)
        let lostThumbnail = store.thumbnailURL(id: lostID)
        try Self.jpeg.write(to: lostThumbnail)

        #expect(store.list().map(\.id) == [favorite.id], "the readable entry survives")
        #expect(FileManager.default.fileExists(atPath: lostThumbnail.path), "not cleaned up as an orphan")
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == damaged, "untouched until a change")

        // The first change keeps the original aside, then writes the book it can read.
        store.recordConnection(host: "n.local", port: 47800, fingerprint: Self.fingerprint(2), hostName: "N", now: Self.t0)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasPrefix("AddressBook.unreadable-") && $0.hasSuffix(".json") }
        #expect(aside.count == 1)
        let kept = try String(contentsOf: folder.url.appendingPathComponent(try #require(aside.first)), encoding: .utf8)
        #expect(kept == damaged)
        #expect(FileManager.default.fileExists(atPath: lostThumbnail.path))
        // The rewritten file is authoritative again: a clean load removes the thumbnail nothing refers to.
        let reopened = AddressBookStore(directory: folder.url)
        #expect(Set(reopened.list().map(\.displayName)) == ["Studio", "N"])
        #expect(reopened.list().first(where: { $0.id == favorite.id })?.isFavorite == true)

        // Not JSON at all: the same.
        try Data("not json".utf8).write(to: store.fileURL)
        let garbage = AddressBookStore(directory: folder.url)
        #expect(garbage.list().isEmpty)
        garbage.recordConnection(host: "g.local", port: 47800, fingerprint: Self.fingerprint(3), hostName: "G", now: Self.t0)
        let asideAfter = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasPrefix("AddressBook.unreadable-") }
        #expect(asideAfter.count == 2)

        // A newer format (after a downgrade): shown empty, never overwritten, thumbnails kept.
        let newer = #"{"version": 2, "hosts": [], "somethingNew": true}"#
        try Data(newer.utf8).write(to: store.fileURL)
        try Self.jpeg.write(to: lostThumbnail)
        let downgraded = AddressBookStore(directory: folder.url)
        #expect(downgraded.list().isEmpty)
        downgraded.recordConnection(host: "d.local", port: 47800, fingerprint: Self.fingerprint(4), hostName: "D", now: Self.t0)
        #expect(downgraded.list().count == 1, "kept in memory for this run")
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == newer)
        #expect(FileManager.default.fileExists(atPath: lostThumbnail.path))
    }

    @Test func pinStateFollowsTheTrustedHostStore() throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let defaults = TestDefaults()
        defer { defaults.cleanUp() }
        let trust = TrustedHostStore(defaults: defaults.defaults)
        let store = AddressBookStore(directory: folder.url)
        store.recordConnection(host: "studio.local", port: 47800, fingerprint: Self.fingerprint(7), hostName: "Studio",
                               now: Self.t0)
        let entry = store.recordConnection(host: "100.64.0.7", port: 47800, fingerprint: Self.fingerprint(7),
                                           hostName: "Studio", now: Self.t0.addingTimeInterval(1))
        let tailnet = entry.addresses[0]
        let lan = entry.addresses[1]
        #expect(entry.pinState(of: tailnet, trusted: trust.list()) == .unpinned)

        // "Remember this Host" pins the LAN address (as TrustedHostStore keys it, spelling-insensitive).
        trust.add(host: "Studio.local.", port: 47800, fingerprint: Self.fingerprint(7), name: "Studio")
        #expect(entry.pinState(of: lan, trusted: trust.list()) == .pinned)
        #expect(entry.pinState(of: tailnet, trusted: trust.list()) == .unpinned)

        // A pin to another certificate at that address means the entry's Mac will be refused there.
        trust.add(host: "100.64.0.7", port: 47800, fingerprint: Self.fingerprint(8), name: "Other")
        #expect(entry.pinState(of: tailnet, trusted: trust.list()) == .pinnedToOtherIdentity)

        // Forgetting the pin does not touch the address book, and vice versa.
        trust.remove(host: "studio.local", port: 47800)
        #expect(store.entry(id: entry.id)?.addresses.count == 2)
        store.remove(id: entry.id)
        #expect(trust.entry(host: "100.64.0.7", port: 47800) != nil)
    }

    @Test func thumbnailsAreSmallJPEGs() throws {
        #expect(SessionThumbnail.scaledSize(width: 1920, height: 1080, maxPixels: 320) == (320, 180))
        #expect(SessionThumbnail.scaledSize(width: 900, height: 1600, maxPixels: 320) == (180, 320))
        #expect(SessionThumbnail.scaledSize(width: 200, height: 100, maxPixels: 320) == (200, 100), "never upscaled")
        #expect(SessionThumbnail.scaledSize(width: 0, height: 100, maxPixels: 320) == (0, 0))

        // A real 420v IOSurface buffer, as the decoder produces.
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        #expect(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            memset(base, plane == 0 ? 120 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let jpeg = try #require(SessionThumbnail.jpeg(from: pixelBuffer))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(jpeg.count < 40_000)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 180)
    }
}
