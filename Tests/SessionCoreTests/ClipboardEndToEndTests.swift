import Foundation
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Clipboard sharing over real QUIC on 127.0.0.1 (side stream, CLIPBOARD_STATE, capability bit), with in-memory
/// pasteboards on both sides.
extension EndToEndTests {
    private func approvedClipboardSession(_ h: Harness, port: UInt16,
                                          configure: (inout ViewerSession.Configuration) -> Void = { _ in })
        async throws -> ViewerSession {
        let viewer = h.makeViewer(configure: configure)
        viewer.clipboardWindowIsKeyOverride = true
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "\(viewer.state)")
        viewer.trustHost(remember: false)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        // Nothing is read or sent before the operator allowed the session.
        h.hostPasteboard.copy(text: "copied on the Host while the request waits")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.hostPasteboard.reads == 0 && h.viewerPasteboard.writes == 0)
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        return viewer
    }

    @Test func clipboardFlowsBothWaysWithoutEchoes() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.viewerPasteboard.copy(text: "copied on the Viewer before connecting")
        let viewer = try await approvedClipboardSession(h, port: port)
        #expect(await eventually { viewer.clipboardStatus.isActive && h.host.clipboardStatus.isActive },
                "viewer: \(viewer.clipboardStatus), host: \(h.host.clipboardStatus)")

        // Viewer → Host: what the Viewer had copied goes over once the stream window is key (copy, focus, paste).
        #expect(await eventually { h.hostPasteboard.text == "copied on the Viewer before connecting" })
        #expect(h.host.clipboardStatus.lastTransfer?.direction == .received)
        // …but what the Host had copied before the session never goes to the Viewer.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.viewerPasteboard.writes == 0, "no echo and nothing from before the session")

        // Host → Viewer, including an image.
        let png = ClipboardContent.pngSignature + Data(repeating: 7, count: 2 << 20)
        h.hostPasteboard.copy([ClipboardPolicy.plainTextType: Data("from the Host".utf8), ClipboardPolicy.pngType: png])
        #expect(await eventually { h.viewerPasteboard.text == "from the Host" })
        #expect(h.viewerPasteboard.contents[ClipboardPolicy.pngType] == png)
        #expect(viewer.clipboardStatus.lastTransfer?.direction == .received)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.hostPasteboard.writes == 1, "the Viewer did not send the Host's clipboard back")

        // A password manager's copy on the Viewer stays there.
        h.viewerPasteboard.copy([ClipboardPolicy.plainTextType: Data("hunter2".utf8),
                                 ClipboardPolicy.concealedType: Data()])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.hostPasteboard.text == "from the Host")
        #expect(h.hostPasteboard.writes == 1)
        #expect(h.host.isSharing)
        await h.close()
    }

    @Test func clipboardSwitchesApplyLiveInBothDirections() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await approvedClipboardSession(h, port: port)
        #expect(await eventually { viewer.clipboardStatus.isActive })

        // The Host operator switches it off: the Viewer learns at once and nothing flows either way.
        h.host.allowsClipboardSharing = false
        #expect(await eventually { !viewer.clipboardStatus.peerEnabled })
        h.viewerPasteboard.copy(text: "viewer copy while the Host said no")
        h.hostPasteboard.copy(text: "host copy while sharing is off")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(h.hostPasteboard.writes == 0 && h.viewerPasteboard.writes == 0)
        #expect(h.hostPasteboard.reads == 0, "the Host does not even read its clipboard while off")

        // Back on: the Viewer's pending copy goes; the Host's copy made while off does not.
        h.host.allowsClipboardSharing = true
        #expect(await eventually { h.hostPasteboard.text == "viewer copy while the Host said no" })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.viewerPasteboard.writes == 0)

        // The Viewer switches it off: the Host stops sending.
        viewer.sharesClipboard = false
        #expect(await eventually { !h.host.clipboardStatus.peerEnabled })
        h.hostPasteboard.copy(text: "host copy while the Viewer said no")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.viewerPasteboard.writes == 0)
        viewer.sharesClipboard = true
        // Switching on, the Viewer offers its current clipboard again (by design: about to paste remotely). Copy on
        // the Host only after that landed: if it arrives after the copy, it overwrites the Host's pasteboard before
        // the 50 ms poll saw the copy, and the copy is (correctly) never sent. That race made this test flaky.
        #expect(await eventually { h.host.clipboardStatus.peerEnabled && h.hostPasteboard.writes >= 2 })
        h.hostPasteboard.copy(text: "both on again")
        #expect(await eventually { h.viewerPasteboard.text == "both on again" })
        await h.close()
    }

    @Test func backgroundStreamWindowNeverReadsTheViewerClipboard() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let viewer = try await approvedClipboardSession(h, port: port)
        viewer.clipboardWindowIsKeyOverride = false
        #expect(await eventually { viewer.clipboardStatus.isActive })
        let readsBefore = h.viewerPasteboard.reads
        h.viewerPasteboard.copy(text: "copied in another app")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(h.viewerPasteboard.reads == readsBefore)
        #expect(h.hostPasteboard.writes == 0)
        // Focusing the stream window brings it over.
        viewer.clipboardWindowIsKeyOverride = true
        viewer.syncClipboardNow()
        #expect(await eventually { h.hostPasteboard.text == "copied in another app" })
        await h.close()
    }

    @Test func olderViewerGetsNoClipboardTraffic() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        // A Viewer that does not announce the clipboard bit stands in for a 0.1.4 one.
        let viewer = try await approvedClipboardSession(h, port: port) { $0.clipboardSharing = false }
        #expect(await eventually { h.host.isSharing })
        #expect(!h.host.clipboardStatus.peerSupports)
        h.hostPasteboard.copy(text: "not for an old Viewer")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.hostPasteboard.reads == 0)
        #expect(viewer.isStreaming, "no unknown message type reached it")
        #expect(viewer.clipboardStatus == .inactive || !viewer.clipboardStatus.peerSupports)
        await h.close()
    }

    @Test func olderHostGetsNoSideStream() async throws {
        let h = try Harness { $0.clipboardSharing = false }
        let port = try await h.startHost()
        let viewer = try await approvedClipboardSession(h, port: port)
        #expect(!viewer.clipboardStatus.peerSupports)
        h.viewerPasteboard.copy(text: "not for an old Host")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.viewerPasteboard.reads == 0)
        #expect(h.hostPasteboard.writes == 0)
        #expect(viewer.isStreaming && h.host.isSharing)
        await h.close()
    }
}
