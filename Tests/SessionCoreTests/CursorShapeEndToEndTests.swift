import Foundation
import RenderCore
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Remote pointer shape over real QUIC on 127.0.0.1 (CURSOR_SHAPE on the control stream, CURSOR_IMAGE on the side
/// stream, capability bit 3), with a scripted Host pointer.
extension EndToEndTests {
    private func approvedPointerSession(_ h: Harness, port: UInt16,
                                        configure: (inout ViewerSession.Configuration) -> Void = { _ in })
        async throws -> ViewerSession {
        let viewer = h.makeViewer(configure: configure)
        viewer.attach(frameSink: h.frames)
        viewer.connect(host: "127.0.0.1", port: port)
        #expect(await eventually { if case .verifyingHost = viewer.state { true } else { false } }, "\(viewer.state)")
        viewer.trustHost(remember: false)
        #expect(await eventually { h.host.pendingRequest != nil }, "host: \(h.host.state)")
        // The Host's pointer is not read before the operator allowed the session.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.hostCursor.reads == 0)
        h.host.approve()
        #expect(await eventually { viewer.isStreaming }, "viewer: \(viewer.state)")
        return viewer
    }

    private func pointerID(_ viewer: ViewerSession) -> UInt32? {
        if case .image(let image) = viewer.remotePointer { image.id } else { nil }
    }

    @Test func pointerShapeFollowsTheHost() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        let arrow = CursorSnapshot.solid(width: 20, height: 32, rgba: (0, 0, 0, 255), hotSpot: CGPoint(x: 2, y: 3))
        let beam = CursorSnapshot.solid(width: 8, height: 36, rgba: (40, 40, 40, 255), hotSpot: CGPoint(x: 2, y: 9))
        h.hostCursor.observation = .image(arrow)
        let viewer = try await approvedPointerSession(h, port: port)
        #expect(await eventually { h.host.cursorShapeStatus.isActive }, "\(h.host.cursorShapeStatus)")

        #expect(await eventually { viewer.remotePointerStatus == .active && pointerID(viewer) != nil },
                "\(viewer.remotePointerStatus) \(viewer.remotePointer)")
        guard case .image(let first) = viewer.remotePointer else { await h.close(); return }
        #expect(first.pointSize == CGSize(width: 10, height: 16), "point size travels with the 2× pixels")
        #expect(first.hotSpot == CGPoint(x: 2, y: 3))
        #expect(first.image.width == 20 && first.image.height == 32)

        h.hostCursor.observation = .image(beam)
        #expect(await eventually { pointerID(viewer) != nil && pointerID(viewer) != first.id })
        h.hostCursor.observation = .hidden
        #expect(await eventually { viewer.remotePointer == .hidden })
        h.hostCursor.observation = .image(arrow)
        #expect(await eventually { pointerID(viewer) == first.id }, "a shape seen before comes back by id")

        // The Viewer's own switch is local and live.
        viewer.showsRemotePointer = false
        #expect(viewer.remotePointer == .standard)
        viewer.showsRemotePointer = true
        #expect(pointerID(viewer) == first.id)

        // The Host operator switches it off: the Viewer falls back to its arrow and the pointer is no longer read.
        h.host.sharesPointerShape = false
        #expect(await eventually { viewer.remotePointerStatus == .offOnHost && viewer.remotePointer == .standard })
        let reads = h.hostCursor.reads
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.hostCursor.reads == reads)
        h.host.sharesPointerShape = true
        #expect(await eventually { pointerID(viewer) == first.id })

        viewer.disconnect()
        #expect(viewer.remotePointer == .standard)
        #expect(viewer.remotePointerStatus == .inactive)
        #expect(await eventually { h.host.cursorShapeStatus == .inactive })
        let readsAfter = h.hostCursor.reads
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.hostCursor.reads == readsAfter, "sampling stops with the session")
        await h.close()
    }

    @Test func olderViewerNeverGetsPointerShapes() async throws {
        let h = try Harness()
        let port = try await h.startHost()
        h.hostCursor.observation = .image(.solid())
        let viewer = try await approvedPointerSession(h, port: port) {
            $0.cursorShapes = false
            $0.clipboardSharing = false   // like a 0.1.4 Viewer: no side-stream feature at all
        }
        #expect(await eventually { h.host.isSharing })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!h.host.cursorShapeStatus.peerSupports)
        #expect(h.hostCursor.reads == 0, "a Viewer without the bit: the Host never reads its pointer")
        #expect(viewer.remotePointerStatus == .unsupported)
        #expect(viewer.remotePointer == .standard)
        #expect(viewer.isStreaming, "nothing unknown was sent to it")
        await h.close()
    }

    @Test func olderHostLeavesTheArrow() async throws {
        let h = try Harness { $0.cursorShapes = false }
        let port = try await h.startHost()
        h.hostCursor.observation = .image(.solid())
        let viewer = try await approvedPointerSession(h, port: port)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(viewer.remotePointerStatus == .unsupported)
        #expect(viewer.remotePointer == .standard)
        #expect(h.hostCursor.reads == 0)
        #expect(viewer.isStreaming)
        await h.close()
    }
}
