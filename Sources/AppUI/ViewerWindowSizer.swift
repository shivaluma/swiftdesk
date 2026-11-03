import AppKit
import RenderCore
import WireProtocol

/// Sizes the Viewer window to the remote picture so the renderer resamples as little as possible
/// (`VideoGeometry.pixelViewport` snaps to whole multiples of the stream and samples them without filtering).
///
/// Policy:
/// - **Session start** (first CONFIG): `.automatic` sizing — the largest whole magnification that fits (1:1, or 2:1
///   pixel doubling for a 1× Host on a large Retina screen), unless that leaves the picture much smaller than the
///   screen (a 1× Host's 1600×900 at 1:1 on a Retina laptop is 800×450 pt); then as large as fits.
/// - **Size by the native stream, not the current rung**: the window is sized for the largest stream seen on the
///   current Host display, so an adaptation step down (smaller encode for a few seconds on a weak link) never shrinks
///   it, and a snap (or ⌘0) during one does not leave a too-small window once the stream steps back up. A stream
///   larger than any seen on this display re-snaps while the window still has the size this sizer gave it.
/// - **Host display change** (its point size in CONFIG, or a different aspect ratio): re-snap, again only while the
///   window still has the size this sizer gave it — a user who resized the window keeps their size.
/// - **Window moved to a screen with another backing scale**: re-snap the same way, since the right point size
///   depends on the scale.
/// - **View › Actual Size (⌘0)** / the toolbar's 1:1 button: snap to strict 1:1 unconditionally (unless in full
///   screen); later automatic re-snaps keep 1:1.
@MainActor
final class ViewerWindowSizer {
    /// Posted by the View › Actual Size menu command; the streaming screen snaps its window.
    static let actualSizeNotification = Notification.Name("SwiftDesk.viewer.actualSize")

    /// The CONFIG fields that matter for window sizing.
    struct StreamKey: Equatable {
        var width: Int
        var height: Int
        var displayPointWidth: Float
        var displayPointHeight: Float

        init(width: Int, height: Int, displayPointWidth: Float, displayPointHeight: Float) {
            self.width = width
            self.height = height
            self.displayPointWidth = displayPointWidth
            self.displayPointHeight = displayPointHeight
        }

        init(_ config: StreamConfig) {
            self.init(width: Int(config.width), height: Int(config.height),
                      displayPointWidth: config.displayPointWidth, displayPointHeight: config.displayPointHeight)
        }

        var hasSize: Bool { width > 0 && height > 0 }

        /// Same Host display: same point size, and the same picture shape (ladder rungs keep the display's aspect
        /// ratio, so a different one means the display changed even if its point size did not).
        func sameDisplay(as other: StreamKey) -> Bool {
            guard displayPointWidth == other.displayPointWidth, displayPointHeight == other.displayPointHeight else {
                return false
            }
            guard hasSize, other.hasSize else { return true }
            let a = Double(width) / Double(height), b = Double(other.width) / Double(other.height)
            return abs(a - b) <= 0.02 * max(a, b)
        }

        /// Larger than `size` in either dimension.
        func exceeds(_ size: CGSize) -> Bool { CGFloat(width) > size.width || CGFloat(height) > size.height }
    }

    /// What `streamChanged` should do (pure, unit-tested).
    enum Action: Equatable {
        case none
        case snap
    }

    /// - Parameters:
    ///   - previous: the last CONFIG seen this session (nil = first one).
    ///   - nativeBefore: the largest stream size seen on the previous CONFIG's display (what the window is sized for).
    ///   - userResized: the window no longer has the size this sizer gave it.
    nonisolated static func action(previous: StreamKey?, nativeBefore: CGSize?, next: StreamKey,
                                   userResized: Bool) -> Action {
        guard next.hasSize else { return .none }
        guard let previous, previous.hasSize else { return .snap }
        if previous.sameDisplay(as: next) {
            // Adaptation step: keep the window — unless the stream grew past what it was sized for.
            guard let nativeBefore, next.exceeds(nativeBefore) else { return .none }
            return userResized ? .none : .snap
        }
        return userResized ? .none : .snap
    }

    /// The size to show for the session's display: the largest stream seen since the display last changed.
    nonisolated static func nativePixels(previousNative: CGSize?, previous: StreamKey?, next: StreamKey) -> CGSize {
        let size = CGSize(width: next.width, height: next.height)
        guard let previous, previous.sameDisplay(as: next), let previousNative else { return size }
        return CGSize(width: max(previousNative.width, size.width), height: max(previousNative.height, size.height))
    }

    weak var view: NSView?
    private var lastKey: StreamKey?
    private var native: CGSize?
    private var sizing: VideoGeometry.WindowSizing = .automatic
    private var autoFrameSize: CGSize?
    private var autoBackingScale: CGFloat?
    private var pendingSnap: DispatchWorkItem?

    /// The stream size (pixels) the window is sized for: the native size for the current Host display.
    var streamPixels: CGSize? {
        guard let native, native.width > 0, native.height > 0 else { return nil }
        return native
    }

    func streamChanged(_ key: StreamKey) {
        let previous = lastKey
        let nativeBefore = native
        lastKey = key
        guard key.hasSize else { return }
        native = Self.nativePixels(previousNative: nativeBefore, previous: previous, next: key)
        let action = Self.action(previous: previous, nativeBefore: nativeBefore, next: key, userResized: userResized)
        guard action == .snap else { return }
        // The first CONFIG arrives while the sidebar is still collapsing (animated), which changes the window chrome;
        // size once the layout has settled.
        schedule(after: previous == nil ? 0.4 : 0.05)
    }

    /// View › Actual Size (⌘0) / the 1:1 button: one stream pixel per screen pixel (or as large as fits).
    func snapToActualSize(animate: Bool) {
        sizing = .actualSize
        snap(animate: animate)
    }

    /// The window's backing scale changed (moved to a screen with another scale). The point size the sizer chose
    /// is wrong for the new scale; re-snap unless the user sized the window themselves.
    func backingPropertiesChanged(window changed: NSWindow?) {
        guard let window = view?.window, changed == nil || changed === window, autoFrameSize != nil,
              let scale = autoBackingScale, window.backingScaleFactor != scale, !userResized else { return }
        schedule(after: 0.05)
    }

    // MARK: Private

    private func snap(animate: Bool) {
        pendingSnap?.cancel()
        pendingSnap = nil
        guard let view, let window = view.window, let pixels = streamPixels,
              !window.styleMask.contains(.fullScreen) else { return }
        window.layoutIfNeeded()
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let scale = window.backingScaleFactor
        let videoArea = view.convert(view.bounds, to: nil).size
        let minimumFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        guard let target = VideoGeometry.actualSizeWindowFrame(
            windowFrame: window.frame, videoArea: videoArea, streamPixels: pixels, backingScale: scale,
            visibleFrame: visible, minimumFrameSize: minimumFrame, sizing: sizing) else { return }
        if window.isZoomed { window.zoom(nil) }
        window.setFrame(target, display: true, animate: animate)
        autoFrameSize = target.size
        autoBackingScale = scale
    }

    private var userResized: Bool {
        guard let auto = autoFrameSize, let window = view?.window else { return false }
        let size = window.frame.size
        return abs(size.width - auto.width) > 1 || abs(size.height - auto.height) > 1
            || window.styleMask.contains(.fullScreen)
    }

    private func schedule(after delay: TimeInterval) {
        pendingSnap?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.snap(animate: false) }
        }
        pendingSnap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
