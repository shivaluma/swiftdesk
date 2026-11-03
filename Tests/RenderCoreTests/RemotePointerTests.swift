import AppKit
import CoreVideo
import Testing
@testable import RenderCore

/// 0.1.6: the Host pointer's shape drawn as the local cursor over the video.
@Suite("Remote pointer cursor (windowless)")
@MainActor
struct RemotePointerTests {
    private func pointerImage(id: UInt32 = 1, pixels: Int = 20, points: CGFloat = 10,
                              hotSpot: CGPoint = CGPoint(x: 2, y: 3)) throws -> RemotePointerImage {
        let context = try #require(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return RemotePointerImage(id: id, image: try #require(context.makeImage()),
                                  pointSize: CGSize(width: points, height: points), hotSpot: hotSpot)
    }

    /// Identity comparison outside `#expect` (its operator capture traps on `===` with AppKit objects here).
    private func isSame(_ a: NSCursor, _ b: NSCursor) -> Bool { a === b }

    /// 400 × 400 pt view showing a 1280 × 720 stream: video rect 400 × 225 pt at y 87.5 … 312.5.
    private func makeView() throws -> RemoteDisplayView {
        let view = RemoteDisplayView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.metalLayer.contentsScale = 2
        let buffer = try YCbCrPipelineTests.makePixelBuffer(width: 1280, height: 720) { _, _ in (126, 128, 128) }
        view.enqueue(TestFrame(pixelBuffer: buffer, frameId: 1, decodeDoneNanos: 0))
        return view
    }

    @Test func scaleFollowsTheVideoMagnification() {
        let video = CGRect(x: 0, y: 0, width: 1440, height: 810)
        #expect(RemotePointerCursor.scale(videoRect: video, hostPointSize: nil) == 1)
        #expect(RemotePointerCursor.scale(videoRect: video, hostPointSize: CGSize(width: 1440, height: 810)) == 1)
        #expect(RemotePointerCursor.scale(videoRect: video, hostPointSize: CGSize(width: 1920, height: 1080)) == 0.75)
        #expect(RemotePointerCursor.scale(videoRect: video, hostPointSize: CGSize(width: 5120, height: 2880)) == 0.75,
                "clamped: a tiny window keeps a usable pointer")
        #expect(RemotePointerCursor.scale(videoRect: video, hostPointSize: CGSize(width: 480, height: 270)) == 2)
        #expect(RemotePointerCursor.scale(videoRect: video, hostPointSize: CGSize(width: 1512, height: 982)) == 0.8,
                "5 % steps (0.825 by height → 0.8)")
        #expect(RemotePointerCursor.scale(videoRect: .zero, hostPointSize: CGSize(width: 10, height: 10)) == 1)
    }

    @Test func cursorKeepsPixelsAndScalesPointSizeAndHotSpot() throws {
        let pointer = try pointerImage(pixels: 20, points: 10, hotSpot: CGPoint(x: 2, y: 3))
        let cursor = RemotePointerCursor.cursor(for: pointer, scale: 1.5)
        #expect(cursor.image.size == NSSize(width: 15, height: 15))
        #expect(cursor.hotSpot == NSPoint(x: 3, y: 4.5))
        #expect(cursor.image.representations.first?.pixelsWide == 20, "the 2× rendition is kept")
        let edge = RemotePointerCursor.cursor(for: try pointerImage(hotSpot: CGPoint(x: 10, y: 10)), scale: 1)
        #expect(edge.hotSpot.x < 10 && edge.hotSpot.y < 10, "hot spot stays inside the image")
        let hidden = RemotePointerCursor.hidden
        #expect(hidden.image.size == NSSize(width: 16, height: 16))
    }

    @Test func viewUsesTheHostShapeOnlyWhileCapturingAndOverTheVideo() throws {
        let view = try makeView()
        let inside = CGPoint(x: 200, y: 200)
        let letterbox = CGPoint(x: 200, y: 20)
        #expect(isSame(view.cursor(at: inside), .arrow), "arrow before any shape")

        view.remotePointer = .image(try pointerImage())
        #expect(isSame(view.cursor(at: inside), .arrow), "not capturing: arrow")
        view.isCapturingInput = true
        let remote = view.cursor(at: inside)
        #expect(!isSame(remote, .arrow))
        #expect(isSame(view.cursor(at: inside), remote), "built once, reused")
        #expect(isSame(view.cursor(at: letterbox), .arrow), "letterbox bars keep the arrow")

        view.remotePointer = .hidden
        #expect(isSame(view.cursor(at: inside), RemotePointerCursor.hidden))
        view.remotePointer = .standard
        #expect(isSame(view.cursor(at: inside), .arrow))
        view.remotePointer = .hidden
        view.isCapturingInput = false
        #expect(isSame(view.cursor(at: inside), .arrow), "releasing capture brings the arrow back")
    }

    @Test func viewRebuildsTheCursorWhenTheMagnificationChanges() throws {
        let view = try makeView()
        view.isCapturingInput = true
        view.remotePointer = .image(try pointerImage(points: 10))
        #expect(view.remoteCursor?.image.size == NSSize(width: 10, height: 10), "unknown Host size: 1×")
        view.remoteDisplayPointSize = CGSize(width: 200, height: 112.5)   // video shows it at 2×
        #expect(view.remoteCursor?.image.size == NSSize(width: 20, height: 20))
        view.remoteDisplayPointSize = CGSize(width: 500, height: 281.25)  // at 0.8×
        #expect(view.remoteCursor?.image.size == NSSize(width: 8, height: 8))
        view.remoteDisplayPointSize = CGSize(width: 1600, height: 900)    // at 0.25×, clamped to 0.75×
        #expect(view.remoteCursor?.image.size == NSSize(width: 7.5, height: 7.5))
        view.remotePointer = .image(try pointerImage(id: 2, points: 20))
        #expect(view.remoteCursor?.image.size == NSSize(width: 15, height: 15), "a new shape is rebuilt")
    }
}
