import AppKit
import Foundation
import RenderCore
import Testing
import WireProtocol
@testable import SessionCore

/// 0.1.6 remote pointer shape: fingerprinting, the Host's definition cache and change detection, the Viewer's state,
/// PNG encode/decode, and the Host channel against a scripted pointer and a recording transport.
@Suite("Remote pointer shape")
struct CursorShapeTests {
    private static let fakePNG = CursorImage.pngSignature + Data([1, 2, 3, 4])

    /// Tracker step with a fake encoder; records definitions.
    private func step(_ tracker: inout CursorShapeTracker, _ observation: CursorObservation,
                      defined: inout [CursorImage], canDefine: Bool = true, sendSucceeds: Bool = true,
                      png: Data? = CursorShapeTests.fakePNG) -> CursorShape? {
        var local: [CursorImage] = []
        let result = tracker.observe(observation, encodePNG: { _ in png },
                                     define: canDefine ? { image in local.append(image); return sendSucceeds } : nil)
        defined.append(contentsOf: local)
        return result
    }

    // MARK: Snapshot

    @Test func fingerprintCoversPixelsAndGeometry() {
        let base = CursorSnapshot.solid()
        #expect(base.fingerprint == CursorSnapshot.solid().fingerprint)
        #expect(base.fingerprint != CursorSnapshot.solid(rgba: (0, 0, 0, 254)).fingerprint)
        #expect(base.fingerprint != CursorSnapshot.solid(hotSpot: CGPoint(x: 2, y: 1)).fingerprint)
        var resized = base
        resized.pointSize = CGSize(width: 8, height: 8)
        #expect(base.fingerprint != resized.fingerprint, "same pixels at another point size (Retina vs. 1×)")
        #expect(base.fingerprint != CursorSnapshot.solid(width: 16, height: 4).fingerprint)
    }

    @Test func transparencyDetection() {
        #expect(CursorSnapshot.solid(rgba: (0, 0, 0, 0)).isFullyTransparent)
        #expect(!CursorSnapshot.solid(rgba: (0, 0, 0, 1)).isFullyTransparent)
        var onePixel = CursorSnapshot.solid(rgba: (0, 0, 0, 0))
        onePixel.rgba[onePixel.rgba.count - 1] = 255
        #expect(!onePixel.isFullyTransparent)
    }

    // MARK: Host tracker

    @Test func firstSightingDefinesThenOnlyTheIdIsSent() {
        var tracker = CursorShapeTracker()
        var defined: [CursorImage] = []
        let arrow = CursorSnapshot.solid(rgba: (0, 0, 0, 255))
        let beam = CursorSnapshot.solid(width: 4, height: 16, rgba: (9, 9, 9, 255))

        #expect(step(&tracker, .image(arrow), defined: &defined) == .image(id: 1))
        #expect(defined.map(\.id) == [1])
        #expect(defined.first?.pointWidth == 4 && defined.first?.pixelWidth == 8, "point size and pixels both travel")
        #expect(step(&tracker, .image(arrow), defined: &defined) == nil, "unchanged: nothing sent")
        #expect(step(&tracker, .image(beam), defined: &defined) == .image(id: 2))
        #expect(step(&tracker, .image(arrow), defined: &defined) == .image(id: 1), "seen before: id only")
        #expect(step(&tracker, .image(beam), defined: &defined) == .image(id: 2))
        #expect(defined.map(\.id) == [1, 2], "each shape defined once")
    }

    @Test func hiddenAndUnavailableStates() {
        var tracker = CursorShapeTracker()
        var defined: [CursorImage] = []
        #expect(step(&tracker, .hidden, defined: &defined) == .hidden)
        #expect(step(&tracker, .hidden, defined: &defined) == nil)
        #expect(step(&tracker, .image(.solid(rgba: (0, 0, 0, 0))), defined: &defined) == nil, "transparent image = hidden")
        #expect(step(&tracker, .unavailable, defined: &defined) == .unavailable)
        #expect(defined.isEmpty, "a transparent cursor is never sent as an image")
    }

    @Test func cacheEvictsOldestDefinitionFirst() {
        var tracker = CursorShapeTracker(capacity: 3)
        var defined: [CursorImage] = []
        let shapes = (0..<4).map { CursorSnapshot.solid(rgba: (UInt8($0), 0, 0, 255)) }
        for shape in shapes { _ = step(&tracker, .image(shape), defined: &defined) }
        #expect(tracker.definedCount == 3)
        #expect(defined.map(\.id) == [1, 2, 3, 4])
        // Shape 0 was forgotten: it is defined again under a new id; shape 3 is still known.
        #expect(step(&tracker, .image(shapes[0]), defined: &defined) == .image(id: 5))
        #expect(step(&tracker, .image(shapes[3]), defined: &defined) == .image(id: 4))
        #expect(defined.map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test func withoutSideStreamNewShapesWaitAndAreDefinedLater() {
        var tracker = CursorShapeTracker()
        var defined: [CursorImage] = []
        let arrow = CursorSnapshot.solid()
        #expect(step(&tracker, .image(arrow), defined: &defined, canDefine: false) == .unavailable)
        #expect(step(&tracker, .image(arrow), defined: &defined, canDefine: false) == nil)
        #expect(defined.isEmpty)
        #expect(step(&tracker, .image(arrow), defined: &defined) == .image(id: 1), "defined once the stream opened")
    }

    @Test func failedSendOrEncodingIsNotCached() {
        var tracker = CursorShapeTracker()
        var defined: [CursorImage] = []
        let arrow = CursorSnapshot.solid()
        #expect(step(&tracker, .image(arrow), defined: &defined, sendSucceeds: false) == .unavailable)
        #expect(tracker.definedCount == 0)
        #expect(step(&tracker, .image(arrow), defined: &defined) == .image(id: 1),
                "retried; the Viewer never got the failed definition, so its id is free")

        var encodeFails = CursorShapeTracker()
        var encodes = 0
        let other = CursorSnapshot.solid(rgba: (1, 2, 3, 255))
        for _ in 0..<5 {
            _ = encodeFails.observe(.image(other), encodePNG: { _ in encodes += 1; return nil }, define: { _ in true })
        }
        #expect(encodes == 1, "an unencodable shape is not re-encoded on every sample")
        #expect(encodeFails.lastSent == .unavailable)
    }

    @Test func oversizedSnapshotsAreNotDefined() {
        var tracker = CursorShapeTracker()
        var defined: [CursorImage] = []
        let huge = CursorSnapshot(pixelWidth: 300, pixelHeight: 10, rgba: Data(repeating: 255, count: 300 * 10 * 4),
                                  pointSize: CGSize(width: 150, height: 5), hotSpot: .zero)
        #expect(step(&tracker, .image(huge), defined: &defined) == .unavailable)
        #expect(defined.isEmpty)
    }

    @Test func hotSpotIsClampedIntoThePointSize() throws {
        let image = try #require(CursorShapeTracker.image(.solid(hotSpot: CGPoint(x: 99, y: -3)), id: 1,
                                                          png: Self.fakePNG))
        #expect(image.hotSpotX == image.pointWidth)
        #expect(image.hotSpotY == 0)
        #expect(image.isWellFormed)
    }

    @Test func switchOffAndBackOn() {
        var tracker = CursorShapeTracker()
        var defined: [CursorImage] = []
        let arrow = CursorSnapshot.solid()
        _ = step(&tracker, .image(arrow), defined: &defined)
        let off = tracker.switchedOff()
        #expect(off == .off)
        let again = tracker.switchedOff()
        #expect(again == nil)
        tracker.forgetLastSent()
        #expect(step(&tracker, .image(arrow), defined: &defined) == .image(id: 1), "re-announced, still cached")
        #expect(defined.count == 1)
    }

    // MARK: Viewer state

    @Test func viewerFollowsShapesAndDefinitions() {
        var state = RemoteCursorState<String>()
        #expect(state.shape == nil)
        guard case .standard = state.appearance else { Issue.record("arrow before the first message"); return }
        var changed = state.define(id: 1, image: "arrow")
        #expect(!changed, "defined but not current")
        changed = state.apply(.image(id: 1))
        #expect(changed)
        guard case .image(1, "arrow") = state.appearance else { Issue.record("\(state.appearance)"); return }
        changed = state.apply(.hidden)
        #expect(changed)
        changed = state.apply(.hidden)
        #expect(!changed)
        changed = state.apply(.off)
        #expect(changed)
        guard case .standard = state.appearance else { Issue.record("off = arrow"); return }
        changed = state.apply(.unavailable)
        #expect(!changed, "unavailable is the arrow too")
    }

    @Test func viewerKeepsPreviousPointerUntilDefinitionArrives() {
        var state = RemoteCursorState<String>()
        state.define(id: 1, image: "arrow")
        state.apply(.image(id: 1))
        // CURSOR_SHAPE (control stream) overtook its CURSOR_IMAGE (side stream).
        var changed = state.apply(.image(id: 2))
        #expect(!changed)
        #expect(state.isWaitingForDefinition)
        guard case .image(1, _) = state.appearance else { Issue.record("kept the previous pointer"); return }
        changed = state.define(id: 2, image: "beam")
        #expect(changed)
        #expect(!state.isWaitingForDefinition)
        guard case .image(2, "beam") = state.appearance else { Issue.record("\(state.appearance)"); return }
    }

    @Test func viewerCacheIsBoundedAndAtLeastTwiceTheHosts() {
        #expect(CursorImage.viewerCacheSize >= 2 * CursorImage.hostCacheSize)
        var state = RemoteCursorState<Int>(capacity: 2)
        state.define(id: 1, image: 1)
        state.define(id: 2, image: 2)
        state.define(id: 3, image: 3)
        #expect(state.definedCount == 2)
        state.apply(.image(id: 1))
        #expect(state.isWaitingForDefinition, "the oldest definition was dropped")
        state.apply(.image(id: 3))
        guard case .image(3, 3) = state.appearance else { Issue.record("\(state.appearance)"); return }
    }

    // MARK: Rendering

    /// A 1× (red) and a 2× (blue) bitmap representation of a 10 × 16 pt image, like a system cursor's.
    @MainActor
    private func retinaImage() throws -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 16))
        for (scale, color) in [(1, NSColor.red), (2, NSColor.blue)] {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10 * scale, pixelsHigh: 16 * scale,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = NSSize(width: 10, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            NSRect(x: 0, y: 0, width: 10 * scale, height: 16 * scale).fill()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }

    @Test @MainActor func renderingEncodesAndDecodesARetinaCursor() throws {
        let snapshot = try #require(CursorRendering.snapshot(image: try retinaImage(), hotSpot: NSPoint(x: 4, y: 7)))
        #expect(snapshot.pointSize == CGSize(width: 10, height: 16))
        #expect(snapshot.pixelWidth == 20 && snapshot.pixelHeight == 32, "rendered at 2×")
        #expect(snapshot.rgba[2] > 200 && snapshot.rgba[0] < 50, "drawn from the 2× (blue) representation")
        #expect(!snapshot.isFullyTransparent)
        let png = try #require(CursorRendering.png(snapshot))
        #expect(png.starts(with: CursorImage.pngSignature))
        let image = try #require(CursorShapeTracker.image(snapshot, id: 9, png: png))
        let pointer = try #require(CursorRendering.pointerImage(image))
        #expect(pointer.id == 9)
        #expect(pointer.image.width == 20 && pointer.image.height == 32)
        #expect(pointer.pointSize == CGSize(width: 10, height: 16))
        #expect(pointer.hotSpot == CGPoint(x: 4, y: 7))
    }

    @Test @MainActor func renderingCapsLargeCursorsAt256Pixels() throws {
        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let snapshot = try #require(CursorRendering.snapshot(image: image, hotSpot: .zero))
        #expect(snapshot.pixelWidth == 256 && snapshot.pixelHeight == 128)
        #expect(snapshot.pointSize == CGSize(width: 200, height: 100))
        #expect(CursorRendering.snapshot(image: NSImage(size: .zero), hotSpot: .zero) == nil)
    }

    @Test func decodingRejectsAMismatchedOrBrokenPNG() throws {
        let snapshot = CursorSnapshot.solid(width: 6, height: 6)
        let png = try #require(CursorRendering.png(snapshot))
        let mismatched = CursorImage(id: 1, pixelWidth: 7, pixelHeight: 6, pointWidth: 3, pointHeight: 3,
                                     hotSpotX: 0, hotSpotY: 0, png: png)
        #expect(CursorRendering.pointerImage(mismatched) == nil, "announced size must match the PNG")
        let broken = CursorImage(id: 1, pixelWidth: 6, pixelHeight: 6, pointWidth: 3, pointHeight: 3,
                                 hotSpotX: 0, hotSpotY: 0, png: Self.fakePNG)
        #expect(CursorRendering.pointerImage(broken) == nil)
    }

    // MARK: Host channel

    @MainActor
    final class StatusBox {
        var value = CursorShapeStatus.inactive
    }

    @MainActor
    private func channel(_ source: FakeCursorSource, _ transport: FakeClipboardTransport, enabled: Bool = true,
                         status: StatusBox = StatusBox()) -> CursorShapeChannel {
        CursorShapeChannel(source: source, transport: transport, enabled: enabled, pollInterval: .seconds(3600),
                           encodePNG: { _ in CursorShapeTests.fakePNG }) { status.value = $0 }
    }

    private func shapes(_ transport: FakeClipboardTransport) -> [CursorShape] {
        transport.controls.compactMap { if case .cursorShape(let s) = $0 { s } else { nil } }
    }

    private func definitions(_ transport: FakeClipboardTransport) -> [UInt32] {
        transport.sides.compactMap { if case .cursorImage(let i) = $0 { i.id } else { nil } }
    }

    @Test @MainActor func channelAnnouncesSamplesAndDefinesOnTheSideStream() {
        let source = FakeCursorSource()
        source.observation = .image(.solid())
        let transport = FakeClipboardTransport()
        let status = StatusBox()
        let c = channel(source, transport, status: status)
        c.start()
        #expect(status.value == CursorShapeStatus(peerSupports: true, enabled: true))
        #expect(shapes(transport) == [.unavailable], "side stream not open yet")
        c.sideStreamReady()
        #expect(definitions(transport) == [1])
        #expect(shapes(transport) == [.unavailable, .image(id: 1)])
        c.sample()
        #expect(shapes(transport).count == 2, "unchanged pointer: nothing sent")
        source.observation = .hidden
        c.sample()
        #expect(shapes(transport).last == .hidden)
        #expect(transport.controls.allSatisfy { !$0.type.isSideStream }, "images never on the control stream")
        c.stop()
        let reads = source.reads
        c.sample()
        #expect(source.reads == reads, "no sampling after the session ended")
    }

    @Test @MainActor func channelSwitchIsLive() {
        let source = FakeCursorSource()
        source.observation = .image(.solid())
        let transport = FakeClipboardTransport()
        let c = channel(source, transport, enabled: false)
        c.sideStreamReady()
        c.start()
        #expect(shapes(transport) == [.off])
        #expect(source.reads == 0, "switched off: the pointer is never read")
        c.setEnabled(true)
        #expect(shapes(transport) == [.off, .image(id: 1)])
        c.setEnabled(false)
        #expect(shapes(transport).last == .off)
        let reads = source.reads
        c.sample()
        #expect(source.reads == reads)
    }

    @Test @MainActor func channelPollsWhileEnabled() async {
        let source = FakeCursorSource()
        let transport = FakeClipboardTransport()
        let c = CursorShapeChannel(source: source, transport: transport, enabled: true, pollInterval: .milliseconds(5),
                                   encodePNG: { _ in CursorShapeTests.fakePNG }) { _ in }
        c.sideStreamReady()
        c.start()
        source.observation = .hidden
        #expect(await eventually(timeout: 5) { self.shapes(transport).last == .hidden })
        c.stop()
    }
}
