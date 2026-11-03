import Foundation
import ImageIO
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// The address book over real QUIC on 127.0.0.1: a successful connection is recorded, the last frame becomes the
/// entry's thumbnail when the session ends, and the "Save thumbnails" switch and Clear History are honoured.
extension EndToEndTests {
    /// Verify → (optionally remember) → approve → streaming with ≥ 5 decoded frames.
    private func streamingSession(_ h: Harness, port: UInt16, addressBook: AddressBookStore,
                                  remember: Bool = false) async throws -> ViewerSession {
        let viewer = h.makeViewer(addressBook: addressBook)
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        // An unpinned address stops for verification; a pinned one goes straight to the Host's approval.
        #expect(await eventually {
            switch viewer.state {
            case .verifyingHost, .awaitingApproval: true
            default: false
            }
        }, "\(viewer.state)")
        if case .verifyingHost = viewer.state { viewer.trustHost(remember: remember) }
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        let before = h.frames.count
        #expect(await eventually(timeout: 15) { h.frames.count >= before + 5 })
        return viewer
    }

    @Test func successfulConnectionIsRecordedWithAThumbnail() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let book = AddressBookStore(directory: folder.url)
        let h = try Harness()
        let port = try await h.startHost()

        // Nothing is recorded before the Host accepted.
        let viewer = h.makeViewer(addressBook: book)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } })
        #expect(viewer.savedHosts.isEmpty)
        viewer.rejectHost()
        #expect(book.list().isEmpty, "a rejected Host is not saved")

        let session = try await streamingSession(h, port: port, addressBook: book, remember: true)
        let entry = try #require(session.savedHosts.first)
        #expect(session.savedHosts.count == 1)
        #expect(entry.hostName == "Test Host")
        #expect(entry.addresses == [SavedHostAddress(host: "127.0.0.1", port: port)])
        #expect(entry.fingerprint == h.ids.host.fingerprint, "the TLS-observed identity")
        #expect(entry.lastConnectedAt != nil)
        #expect(!entry.hasThumbnail, "the thumbnail is taken when the session ends")
        #expect(session.pinState(of: entry) == .pinned, "remembered: linked to the trusted-host pin")

        session.disconnect()
        await session.waitForPendingThumbnail()
        let saved = try #require(book.entry(id: entry.id))
        #expect(saved.hasThumbnail)
        #expect(session.savedHosts.first?.hasThumbnail == true)
        let jpeg = try #require(book.thumbnailData(for: saved))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 180, "1280×720 stream → 320×180")

        // Connecting again (pinned, from the saved address) updates the same entry.
        let again = try await streamingSession(h, port: port, addressBook: book)
        #expect(again.savedHosts.map(\.id) == [entry.id])
        #expect((again.savedHosts.first?.lastConnectedAt ?? .distantPast) > (entry.lastConnectedAt ?? .distantFuture))

        // With the switch off: the existing thumbnail is deleted and the session end saves none.
        again.savesThumbnails = false
        #expect(book.entry(id: entry.id)?.hasThumbnail == false)
        again.disconnect()
        await again.waitForPendingThumbnail()
        #expect(book.entry(id: entry.id)?.hasThumbnail == false)
        #expect(book.list().count == 1)
        await h.close()
    }

    @Test func hostEndingTheSessionAlsoSavesTheThumbnailAndClearHistoryRemovesIt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.cleanUp() }
        let book = AddressBookStore(directory: folder.url)
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await streamingSession(h, port: port, addressBook: book)
        let id = try #require(viewer.savedHosts.first?.id)

        h.host.stopSharing()
        #expect(await eventually { if case .disconnected = viewer.state { true } else { false } }, "\(viewer.state)")
        await viewer.waitForPendingThumbnail()
        #expect(book.entry(id: id)?.hasThumbnail == true)

        viewer.renameSavedHost(id: id, to: "Studio")
        #expect(viewer.savedHosts.first?.displayName == "Studio")
        viewer.clearHistory()
        #expect(viewer.savedHosts.isEmpty)
        #expect(book.list().isEmpty)
        await h.close()
    }

    @Test func viewerWithoutAnAddressBookKeepsNoHistory() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = h.makeViewer()
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } })
        viewer.trustHost(remember: false)
        #expect(await eventually { h.host.pendingRequest != nil })
        h.host.approve()
        #expect(await eventually { viewer.isStreaming })
        #expect(viewer.savedHosts.isEmpty)
        #expect(viewer.addressBook == nil)
        viewer.disconnect()
        await viewer.waitForPendingThumbnail()
        await h.close()
    }
}
