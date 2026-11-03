import AppKit
import CoreVideo
import Dispatch
import Metal
import QuartzCore
import Synchronization
import Testing
@testable import RenderCore

struct TestFrame: RenderableFrame, @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let frameId: UInt32
    let decodeDoneNanos: UInt64
}

private func makeFrame(id: UInt32, width: Int = 64, height: Int = 36) throws -> TestFrame {
    let buffer = try YCbCrPipelineTests.makePixelBuffer(width: width, height: height) { _, _ in (126, 128, 128) }
    return TestFrame(pixelBuffer: buffer, frameId: id, decodeDoneNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
}

/// Polls `condition` for up to `timeout` seconds without blocking the main actor's executor.
@MainActor
private func waitUntil(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@Suite("MetalVideoView (windowless)")
@MainActor
struct MetalVideoViewTests {
    @Test func layerIsConfiguredForLowLatency() throws {
        let view = MetalVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer === view.metalLayer)
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(layer.framebufferOnly)
        #expect(layer.maximumDrawableCount == 2)
        #expect(layer.displaySyncEnabled)
        #expect(!layer.presentsWithTransaction)
        #expect(layer.isOpaque)
        #expect(view.isOpaque)
        #expect(view.layerContentsRedrawPolicy == .never)
    }

    @Test func videoRectIsZeroBeforeFirstFrameAndAspectFitAfter() throws {
        let view = MetalVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(view.videoRect == .zero)
        view.enqueue(try makeFrame(id: 1, width: 1280, height: 720))
        #expect(view.contentSize == CGSize(width: 1280, height: 720))
        // Whole drawable pixels, exactly the renderer's viewport (87 px from the top of a 400 px drawable).
        #expect(view.videoRect == CGRect(x: 0, y: 88, width: 400, height: 225))
        view.clear()
        #expect(view.videoRect == .zero)
    }

    @Test func pendingFramesAreReplacedNewestWins() throws {
        // No window => rendering is suspended, so every frame but the newest is replaced before display.
        let view = MetalVideoView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(view.framesReplacedBeforeDisplay == 0)
        for id in 1...5 { view.enqueue(try makeFrame(id: UInt32(id))) }
        #expect(view.framesReplacedBeforeDisplay == 4)
        #expect(view.renderStats.framesReplacedBeforeDisplay == 4)
        #expect(view.renderStats.framesRendered == 0)
        view.clear()   // drops the pending frame without counting it as replaced
        view.enqueue(try makeFrame(id: 6))
        #expect(view.framesReplacedBeforeDisplay == 4)
    }

    @Test func enqueueIsThreadSafe() throws {
        let view = MetalVideoView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let frames = try (0..<8).map { try makeFrame(id: UInt32($0)) }
        nonisolated(unsafe) let unsafeView = view
        let iterations = 2_000
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            unsafeView.enqueue(frames[i % frames.count])
            _ = unsafeView.framesReplacedBeforeDisplay
        }
        #expect(view.framesReplacedBeforeDisplay == UInt64(iterations - 1))
    }

    @Test func zeroSizedViewIsHarmless() throws {
        let view = MetalVideoView(frame: .zero)
        view.enqueue(try makeFrame(id: 1))
        #expect(view.videoRect == .zero)
        view.setFrameSize(NSSize(width: 0, height: 0))
        view.layout()
        view.clear()
        #expect(view.framesReplacedBeforeDisplay == 0)
    }

    @Test func onPresentedCanBeSetAndCleared() {
        let view = MetalVideoView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.onPresented = { _ in }
        #expect(view.onPresented != nil)
        view.onPresented = nil
        #expect(view.onPresented == nil)
    }
}

/// Drives `FrameRenderer` against a detached `CAMetalLayer` (no window): exercises the render queue, drawable
/// acquisition, texture mapping and command-buffer submission end to end.
/// Records which thread ran its deinitialization (the base class's `isolated deinit` decides that).
private final class DeinitProbeView: MetalVideoView {
    nonisolated(unsafe) var onDeinit: (@Sendable (Bool) -> Void)?
    isolated deinit { onDeinit?(Thread.isMainThread) }
}

private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T) { self.value = value }
}

@Suite("MetalVideoView deinitialization")
@MainActor
struct MetalVideoViewDeinitTests {
    /// The decode queue can hold the last (temporary) strong reference when the window releases the view; AppKit
    /// teardown must still happen on the main thread (review finding concurrency-2).
    @Test func lastReleaseOffMainDeinitializesOnMain() async throws {
        let ranOnMain = Mutex<Bool?>(nil)
        var view: DeinitProbeView? = DeinitProbeView(frame: CGRect(x: 0, y: 0, width: 64, height: 36))
        view?.onDeinit = { onMain in ranOnMain.withLock { $0 = onMain } }
        let box = UncheckedBox(view!)
        view = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                box.value = nil   // final release on a background thread
                done.resume()
            }
        }
        #expect(await waitUntil { ranOnMain.withLock { $0 } != nil })
        #expect(ranOnMain.withLock { $0 } == true)
    }
}

@Suite("FrameRenderer (detached layer)")
struct FrameRendererTests {
    @Test(.enabled(if: YCbCrPipelineTests.hasMetal)) func rendersNewestFrameOnRenderQueue() async throws {
        let device = try #require(YCbCrPipelineTests.device)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = FrameRenderer.maximumDrawableCount
        layer.drawableSize = CGSize(width: 128, height: 72)
        let renderer = FrameRenderer(layer: layer, device: device)

        renderer.enqueue(try makeFrame(id: 1))
        #expect(renderer.hasPendingFrame)
        renderer.setRenderable(true, redraw: false)

        let rendered = await waitUntil {
            let s = renderer.stats
            return s.framesRendered + s.drawableUnavailable >= 1
        }
        #expect(rendered)
        let stats = renderer.stats
        #expect(stats.framesUnsupported == 0)
        #expect(stats.framesRendered == 1, "drawableUnavailable=\(stats.drawableUnavailable)")
        #expect(!renderer.hasPendingFrame)

        // A redraw request (resize) re-renders the last frame but does not count as a new frame.
        renderer.setRenderable(true, redraw: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(renderer.stats.framesRendered == 1)

        // Unsupported pixel formats are counted and dropped, never crash.
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        renderer.enqueue(TestFrame(pixelBuffer: try #require(out), frameId: 2, decodeDoneNanos: 0))
        #expect(await waitUntil { renderer.stats.framesUnsupported == 1 })

        renderer.clear()
        #expect(await waitUntil { !renderer.hasPendingFrame })
        #expect(renderer.contentSize == .zero)
    }

    @Test func suspendedRendererKeepsOnlyNewestFrame() throws {
        let layer = CAMetalLayer()
        let renderer = FrameRenderer(layer: layer, device: nil)
        renderer.setRenderable(false, redraw: false)
        for id in 1...3 { renderer.enqueue(try makeFrame(id: UInt32(id))) }
        #expect(renderer.framesReplacedBeforeDisplay == 2)
        #expect(renderer.hasPendingFrame)
    }
}

@Suite("RemoteDisplayView input forwarding (windowless)")
@MainActor
struct RemoteDisplayViewTests {
    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func keyEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "w",
                                      charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    }

    private func makeView() throws -> RemoteDisplayView {
        let view = RemoteDisplayView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        // Retina backing: the 800×800 px drawable puts the 800×450 px viewport 175 px from the top, i.e. the video
        // rect (whole device pixels, like the renderer's viewport) is y 87.5 ... 312.5 pt.
        view.metalLayer.contentsScale = 2
        view.enqueue(try makeFrame(id: 1, width: 1280, height: 720))
        return view
    }

    @Test func acceptsFirstResponder() {
        #expect(RemoteDisplayView(frame: .zero).acceptsFirstResponder)
    }

    @Test func mouseEventsForwardNormalizedPointWhileCapturing() throws {
        let view = try makeView()
        var received: [(NSEvent.EventType, CGPoint?)] = []
        view.onMouse = { event, point in received.append((event.type, point)) }
        view.isCapturingInput = true

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 0, y: 312.5)))
        view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: CGPoint(x: 400, y: 87.5)))
        view.otherMouseDown(with: try mouseEvent(.otherMouseDown, at: CGPoint(x: 200, y: 20)))   // letterbox bar
        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 200)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 300, y: 200)))

        #expect(received.count == 6)
        #expect(received[0].0 == .leftMouseDown)
        #expect(received[0].1 == CGPoint(x: 0.5, y: 0.5))
        #expect(received[1].1 == CGPoint(x: 0, y: 0))          // top-left of the video (unflipped view)
        #expect(received[2].1 == CGPoint(x: 1, y: 1))          // bottom-right
        #expect(received[3].1 == nil)                           // outside the video rect
        #expect(received[4].1 == CGPoint(x: 0.25, y: 0.5))
        #expect(received[5].0 == .leftMouseDragged)
    }

    /// Moves, drags and button-ups outside the video (letterbox bars, or past the view while dragging) are clamped
    /// onto the video's edge so the Host cursor reaches the screen edge; a button-down there is still not forwarded
    /// (review finding input-3).
    @Test func movesDragsAndUpsOutsideTheVideoAreClampedToItsEdge() throws {
        let view = try makeView()   // video rect: y 87.5 ... 312.5
        var received: [(NSEvent.EventType, CGPoint?)] = []
        view.onMouse = { event, point in received.append((event.type, point)) }
        view.isCapturingInput = true

        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 20)))          // bottom bar
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 500, y: 390))) // past the top-right
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: -30, y: 200)))           // past the left
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 20)))        // bar: not a click

        try #require(received.count == 4)
        #expect(received[0].1 == CGPoint(x: 0.25, y: 1))
        #expect(received[1].1 == CGPoint(x: 1, y: 0))
        #expect(received[2].1 == CGPoint(x: 0, y: 0.5))
        #expect(received[3].1 == nil)
    }

    /// Leaving the view while capturing reports the exit point, clamped, as a final move.
    @Test func mouseExitIsForwardedAsAClampedMove() throws {
        let view = try makeView()
        var received: [(NSEvent.EventType, CGPoint?)] = []
        view.onMouse = { event, point in received.append((event.type, point)) }
        view.isCapturingInput = true
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: CGPoint(x: 200, y: 401),
                                                        modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, trackingNumber: 0,
                                                        userData: nil))
        view.mouseExited(with: exit)
        try #require(received.count == 1)
        #expect(received[0].0 == .mouseMoved)
        #expect(received[0].1 == CGPoint(x: 0.5, y: 0))
        view.isCapturingInput = false
        view.mouseExited(with: exit)
        #expect(received.count == 1)
    }

    @Test func nothingIsForwardedWhenNotCapturing() throws {
        let view = try makeView()
        var mouseCount = 0, keyCount = 0, scrollCount = 0
        view.onMouse = { _, _ in mouseCount += 1 }
        view.onKey = { _ in keyCount += 1 }
        view.onScroll = { _ in scrollCount += 1 }
        view.isCapturingInput = false

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: CGPoint(x: 200, y: 200)))
        #expect(!view.performKeyEquivalent(with: try keyEvent(.keyDown, modifiers: .command)))
        #expect(mouseCount == 0 && keyCount == 0 && scrollCount == 0)
    }

    @Test func keysAndKeyEquivalentsForwardWhileCapturing() throws {
        let view = try makeView()
        var types: [NSEvent.EventType] = []
        view.onKey = { types.append($0.type) }
        view.isCapturingInput = true

        view.keyDown(with: try keyEvent(.keyDown))
        view.keyUp(with: try keyEvent(.keyUp))
        // ⌘W while captured goes to the remote and is reported as handled, so the local menu never sees it.
        #expect(view.performKeyEquivalent(with: try keyEvent(.keyDown, modifiers: .command)))
        // performKeyEquivalent only claims key-down events.
        #expect(!view.performKeyEquivalent(with: try keyEvent(.keyUp, modifiers: .command)))
        #expect(types == [.keyDown, .keyUp, .keyDown])

        view.isCapturingInput = false
        #expect(!view.performKeyEquivalent(with: try keyEvent(.keyDown, modifiers: .command)))
        #expect(types.count == 3)
    }

    /// 0.2.0: ⌘Q is forwarded only with "Send system shortcuts" on; otherwise it reaches SwiftDesk's Quit (which asks
    /// first during a session). ⌃⌘Q and ⇧⌘Q are not ⌘Q.
    @Test func commandQIsForwardedOnlyWhenSystemShortcutsAreSent() throws {
        func q(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "q",
                                          charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        }
        let view = try makeView()
        var forwarded = 0
        view.onKey = { _ in forwarded += 1 }
        view.isCapturingInput = true
        #expect(!view.forwardsQuitShortcut, "off by default")
        #expect(RemoteDisplayView.isQuitShortcut(try q(.command)))
        #expect(RemoteDisplayView.isQuitShortcut(try q([.command, .capsLock])))
        #expect(!RemoteDisplayView.isQuitShortcut(try q([.command, .control])))
        #expect(!RemoteDisplayView.isQuitShortcut(try q([.command, .shift])))

        #expect(!view.performKeyEquivalent(with: try q(.command)), "left to the main menu")
        #expect(forwarded == 0)
        #expect(view.performKeyEquivalent(with: try q([.command, .control])), "Lock Screen still goes to the Host")
        #expect(view.performKeyEquivalent(with: try keyEvent(.keyDown, modifiers: .command)), "⌘W still goes")
        #expect(forwarded == 2)

        view.forwardsQuitShortcut = true
        #expect(view.performKeyEquivalent(with: try q(.command)))
        #expect(forwarded == 3)
    }

    @Test func rightClickMenuSuppressedWhileCapturing() throws {
        let view = try makeView()
        view.menu = NSMenu(title: "local")
        let event = try mouseEvent(.rightMouseDown, at: CGPoint(x: 200, y: 200))
        view.isCapturingInput = true
        #expect(view.menu(for: event) == nil)
        view.isCapturingInput = false
        #expect(view.menu(for: event) != nil)
    }

    @Test func normalizedPointUsesVideoRect() throws {
        let view = try makeView()
        let p = view.normalizedPoint(for: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 143.75)))
        let q = try #require(p)
        #expect(abs(q.x - 0.25) < 1e-9)
        #expect(abs(q.y - 0.75) < 1e-9)
    }
}
