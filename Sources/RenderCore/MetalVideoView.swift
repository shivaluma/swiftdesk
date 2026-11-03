import AppKit
import Metal
import QuartzCore

/// Layer-backed `NSView` that shows decoded remote video with the lowest latency AppKit allows.
///
/// Design choices (PRD §6, "never render stale frames"):
/// - Backed directly by a `CAMetalLayer` (not `MTKView`) so nothing in AppKit's display cycle can delay or
///   duplicate a present; the layer is configured with `framebufferOnly`, `displaySyncEnabled` (no tearing),
///   `presentsWithTransaction = false` (presents are not tied to main-thread CA commits) and two drawables.
/// - Frames are rendered as soon as they arrive on a dedicated render queue (see `FrameRenderer` for why this
///   beats a display link), newest frame wins, and nothing is re-rendered unless the size changes.
/// - Decoder output is mapped zero-copy via `CVMetalTextureCache` (Y as `r8Unorm`, CbCr as `rg8Unorm`) and
///   converted BT.709 → RGB in the fragment shader.
/// - The main thread only maintains geometry (`contentsScale`, `drawableSize`, visibility); while the view has no
///   window, is hidden, occluded or zero-sized, rendering is suspended and frames are simply replaced.
@MainActor public class MetalVideoView: NSView {
    let metalLayer: CAMetalLayer
    nonisolated let renderer: FrameRenderer
    private weak var observedWindow: NSWindow?

    public override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        metalLayer = Self.makeMetalLayer(device: device)
        renderer = FrameRenderer(layer: metalLayer, device: device)
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        let device = MTLCreateSystemDefaultDevice()
        metalLayer = Self.makeMetalLayer(device: device)
        renderer = FrameRenderer(layer: metalLayer, device: device)
        super.init(coder: coder)
        commonInit()
    }

    private static func makeMetalLayer(device: MTLDevice?) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = FrameRenderer.maximumDrawableCount
        layer.displaySyncEnabled = true
        layer.presentsWithTransaction = false
        // Keep the 1 s timeout so a stuck compositor can never wedge the render queue forever.
        layer.allowsNextDrawableTimeout = true
        // Captured frames are BT.709/sRGB primaries; let the compositor colour-match them to the actual display.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        layer.drawableSize = .zero
        return layer
    }

    /// The decode queue reaches this view through a weak reference (`FrameSinkSlot`), and loading a weak reference
    /// yields a temporary strong one on that queue. If the window drops its reference meanwhile, the decode queue
    /// performs the final release; `isolated` moves the whole deinitialization (NSView/CAMetalLayer teardown included)
    /// to the main actor, as AppKit requires.
    isolated deinit {}

    private func commonInit() {
        wantsLayer = true
        // All content comes from Metal presents; AppKit must never redraw (and so never delay) this layer.
        layerContentsRedrawPolicy = .never
    }

    public override func makeBackingLayer() -> CALayer { metalLayer }

    public override var isOpaque: Bool { true }

    // MARK: Public API

    /// Thread-safe; callable from the decode queue. Replaces any not-yet-displayed frame (counts replacements).
    nonisolated public func enqueue(_ frame: any RenderableFrame) {
        renderer.enqueue(frame)
    }

    /// Called once per frame that reached the screen, on a Metal-owned thread. Keep it cheap (record a sample).
    public var onPresented: (@Sendable (PresentedFrameInfo) -> Void)? {
        didSet { renderer.setOnPresented(onPresented) }
    }

    /// Current aspect-fit rectangle of the video in view coordinates; `.zero` until the first frame arrives.
    /// Exactly the renderer's viewport (whole drawable pixels, 1:1 snap included) converted back to points, so input is
    /// normalized against the rectangle the video is really drawn in.
    public var videoRect: CGRect {
        VideoGeometry.videoRect(content: renderer.contentSize, bounds: bounds, scale: metalLayer.contentsScale,
                                viewIsFlipped: isFlipped)
    }

    nonisolated public var framesReplacedBeforeDisplay: UInt64 { renderer.framesReplacedBeforeDisplay }

    /// All renderer counters (rendered, presented, replaced, dropped, GPU errors).
    nonisolated public var renderStats: RenderStats { renderer.stats }

    /// Pixel size of the most recently enqueued frame (`.zero` when none / after `clear()`).
    nonisolated public var contentSize: CGSize { renderer.contentSize }

    /// Discards pending and displayed frames and presents black (e.g. on disconnect).
    public func clear() {
        renderer.clear()
    }

    // MARK: Geometry tracking

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRenderTarget()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateRenderTarget()
    }

    public override func layout() {
        super.layout()
        updateRenderTarget()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderTarget()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateRenderTarget()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRenderTarget()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let old = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                      object: old)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification,
                                                      object: old)
            observedWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            observedWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)),
                                                   name: NSWindow.didChangeScreenNotification, object: window)
        }
        updateRenderTarget()
    }

    @objc private func windowGeometryChanged(_ note: Notification) {
        updateRenderTarget()
    }

    /// Pushes the backing scale, drawable size and visibility to the layer/renderer. Cheap; main thread only.
    func updateRenderTarget() {
        guard let window else {
            renderer.setRenderable(false, redraw: false)
            return
        }
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }

        // Physical pixels: the drawable is the view's size on this screen, so the compositor never rescales it (a
        // 1:1 stream stays 1:1). The hosting container keeps this view on whole device pixels.
        let drawable = VideoGeometry.drawableSize(bounds: bounds, scale: scale)
        let visible = window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
        let canRender = visible && drawable.width >= 1 && drawable.height >= 1

        var sizeChanged = false
        if canRender {
            let size = CGSize(width: drawable.width, height: drawable.height)
            if metalLayer.drawableSize != size {
                metalLayer.drawableSize = size
                sizeChanged = true
            }
        }
        renderer.setRenderable(canRender, redraw: sizeChanged)
    }
}
