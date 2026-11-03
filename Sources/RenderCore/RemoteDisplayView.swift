import AppKit

/// `MetalVideoView` subclass that captures input while focused and forwards it. Keeps a local pointer visible (local
/// pointer feedback; the host cursor is hidden from capture): the system arrow, or — 0.1.6, while capturing and over
/// the video — the Host pointer's shape (`remotePointer`), drawn by AppKit as this app's cursor so it still moves with
/// zero latency.
///
/// Why the extra machinery beyond plain `keyDown`/`keyUp` overrides:
/// - Key equivalents (⌘W, ⌘S …) reach `performKeyEquivalent(with:)` *before* the main menu.
///   While capturing we forward them and return true, so the shortcut acts on the remote Mac, not on SwiftDesk.
///   ⌘Q is the exception (0.2.0): it is forwarded only with `forwardsQuitShortcut` ("Send system shortcuts" on);
///   otherwise it reaches SwiftDesk's Quit, which asks first during a session.
/// - AppKit does not reliably deliver `keyUp` to views for ⌘-modified keys (the menu machinery swallows them),
///   which would leave keys stuck down on the host. A local `.keyUp` monitor, installed only while capturing,
///   forwards every key-up aimed at this view and consumes it (returns nil) — the consumed event is never
///   dispatched to `keyUp(with:)`, so nothing is delivered twice.
/// - Focus loss (first responder, window key status, app deactivation) is reported once per transition so the
///   caller can release every held key/button on the host (no stuck modifiers after ⌘-Tab).
///
/// System-reserved shortcuts (⌘Tab, Mission Control, ⌃⌥⎋-style global hotkeys) never reach the app and are
/// therefore not forwarded from here; since 0.1.7 the session's optional keyboard tap (InputCore
/// `SystemShortcutTap`, "Send system shortcuts") takes them, and every other key, before AppKit sees them while
/// capturing, so this view then receives only the release shortcut. Callbacks run on the main thread. Event
/// *content* is never logged here.
@MainActor public final class RemoteDisplayView: MetalVideoView {
    /// Mouse buttons, drags and moves with the normalized video point. Button-downs outside the video rect (letterbox
    /// bars) report nil so they are not forwarded; moves, drags and button-ups outside it report the point clamped
    /// onto the video's edge, so the Host cursor can reach the screen edges. Leaving the view while capturing is
    /// reported as a `.mouseMoved` at the clamped exit point.
    public var onMouse: ((NSEvent, CGPoint?) -> Void)?
    public var onScroll: ((NSEvent) -> Void)?
    /// keyDown / keyUp / flagsChanged, including key equivalents while captured.
    public var onKey: ((NSEvent) -> Void)?
    /// Became/resigned effective focus (first responder of the key window of the active app).
    public var onFocusChange: ((Bool) -> Void)?

    /// When false, events are not forwarded and take the normal AppKit path (`super`).
    public var isCapturingInput: Bool = false {
        didSet {
            guard isCapturingInput != oldValue else { return }
            updateKeyUpMonitor()
            pointerAppearanceChanged()
        }
    }

    /// ⌘Q while capturing goes to the Host only when true (the session mirrors "Send system shortcuts"); when false it
    /// is left to the main menu (SwiftDesk's Quit), like every key equivalent while not capturing.
    public var forwardsQuitShortcut = false

    /// Plain ⌘Q (Caps Lock / fn ignored), matched by character like the menu's key equivalent. ⌃⌘Q (Lock Screen) and
    /// ⇧⌘Q (Log Out) are not it.
    public static func isQuitShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "q" else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return event.modifierFlags.intersection(relevant) == .command
    }

    /// 0.1.6: the Host pointer's shape, shown instead of the arrow while capturing input and over the video rect
    /// (`.standard`: always the arrow). Drawn at the Host's point size times the video magnification
    /// (`RemotePointerCursor.scale`).
    public var remotePointer: RemotePointer = .standard {
        didSet {
            guard remotePointer != oldValue else { return }
            pointerAppearanceChanged()
        }
    }

    /// The Host display's size in points (StreamConfig), for scaling `remotePointer`; nil scales by 1.
    public var remoteDisplayPointSize: CGSize? {
        didSet {
            guard remoteDisplayPointSize != oldValue else { return }
            pointerAppearanceChanged()
        }
    }

    /// Effective focus as last reported through `onFocusChange`.
    public private(set) var hasInputFocus = false

    private var isFirstResponderNow = false
    private var keyUpMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private weak var focusWindow: NSWindow?
    /// The last built remote cursor, reused while the shape and scale stay the same.
    private var remoteCursorCache: (id: UInt32, scale: CGFloat, cursor: NSCursor)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUpInput()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpInput()
    }

    private func setUpInput() {
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    isolated deinit {
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }

    // MARK: Responder / focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isFirstResponderNow = true
            refreshFocus()
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isFirstResponderNow = false
            refreshFocus()
        }
        return accepted
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let old = focusWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: old)
            focusWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            focusWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStatusChanged(_:)),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStatusChanged(_:)),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        } else {
            isFirstResponderNow = false
        }
        refreshFocus()
    }

    @objc private func windowKeyStatusChanged(_ note: Notification) { refreshFocus() }
    @objc private func applicationDidResignActive(_ note: Notification) { refreshFocus() }
    @objc private func applicationDidBecomeActive(_ note: Notification) { refreshFocus() }

    private func refreshFocus() {
        let appActive = NSApp?.isActive ?? false
        let focused = isFirstResponderNow && (window?.isKeyWindow ?? false) && appActive
        guard focused != hasInputFocus else { return }
        hasInputFocus = focused
        onFocusChange?(focused)
    }

    // MARK: Cursor

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
                                            .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func resetCursorRects() {
        // While the Host's shape is shown the cursor is set from cursorUpdate / mouse moves instead: a cursor rect
        // would put the arrow back on every entry.
        guard !showsRemotePointer else { return }
        addCursorRect(bounds, cursor: .arrow)
    }

    public override func cursorUpdate(with event: NSEvent) {
        // Local pointer = immediate feedback; the host cursor is excluded from the captured video.
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// The Host's shape is in use (capturing, and a shape other than the arrow).
    var showsRemotePointer: Bool { isCapturingInput && remotePointer != .standard }

    /// The cursor for a point in view coordinates: the Host's shape over the video while capturing, else the arrow.
    func cursor(at point: CGPoint) -> NSCursor {
        guard showsRemotePointer, videoRect.contains(point), let remote = remoteCursor else { return .arrow }
        return remote
    }

    /// The `NSCursor` for `remotePointer` at the current magnification (nil for `.standard`).
    var remoteCursor: NSCursor? {
        switch remotePointer {
        case .standard:
            return nil
        case .hidden:
            return RemotePointerCursor.hidden
        case .image(let pointer):
            let scale = RemotePointerCursor.scale(videoRect: videoRect, hostPointSize: remoteDisplayPointSize)
            if let cached = remoteCursorCache, cached.id == pointer.id, cached.scale == scale { return cached.cursor }
            let cursor = RemotePointerCursor.cursor(for: pointer, scale: scale)
            remoteCursorCache = (pointer.id, scale, cursor)
            return cursor
        }
    }

    /// Shape, capture or scale changed: re-evaluate the cursor rects and, if the mouse is over this view in the key
    /// window, switch the cursor now rather than at the next mouse move.
    private func pointerAppearanceChanged() {
        if case .image(let pointer) = remotePointer, remoteCursorCache?.id != pointer.id { remoteCursorCache = nil }
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        guard window.isKeyWindow, NSApp?.isActive ?? false else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        cursor(at: point).set()
    }

    /// Keeps the cursor right while the mouse moves over the video and letterbox (no cursor rects then).
    private func updatePointer(for event: NSEvent) {
        guard showsRemotePointer else { return }   // plain arrow: the cursor rect handles it, as before 0.1.6
        let cursor = cursor(at: convert(event.locationInWindow, from: nil))
        if NSCursor.current !== cursor { cursor.set() }
    }

    // MARK: Mouse

    func normalizedPoint(for event: NSEvent) -> CGPoint? {
        let local = convert(event.locationInWindow, from: nil)
        return VideoGeometry.normalizedPoint(viewPoint: local, videoRect: videoRect, viewIsFlipped: isFlipped)
    }

    /// Clamped onto the video's edge when outside it (see `onMouse`).
    func clampedNormalizedPoint(for event: NSEvent) -> CGPoint? {
        let local = convert(event.locationInWindow, from: nil)
        return VideoGeometry.clampedNormalizedPoint(viewPoint: local, videoRect: videoRect, viewIsFlipped: isFlipped)
    }

    private func forwardMouse(_ event: NSEvent) -> Bool {
        guard isCapturingInput, let onMouse else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouse(event, normalizedPoint(for: event))
        default:
            onMouse(event, clampedNormalizedPoint(for: event))
            updatePointer(for: event)
        }
        return true
    }

    /// A fast move out of an un-letterboxed edge leaves the last in-view sample short of the edge and no further
    /// `mouseMoved` arrives (`.inVisibleRect`); report the exit point, clamped, as a final move.
    public override func mouseExited(with event: NSEvent) {
        // A hidden or custom Host shape must not follow the pointer onto the toolbar or another window.
        if showsRemotePointer { NSCursor.arrow.set() }
        guard isCapturingInput, let onMouse,
              let move = NSEvent.mouseEvent(with: .mouseMoved, location: event.locationInWindow,
                                            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                            windowNumber: event.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 0, pressure: 0)
        else { return super.mouseExited(with: event) }
        onMouse(move, clampedNormalizedPoint(for: move))
    }

    public override func mouseDown(with event: NSEvent) {
        if !forwardMouse(event) { super.mouseDown(with: event) }
    }
    public override func mouseUp(with event: NSEvent) {
        if !forwardMouse(event) { super.mouseUp(with: event) }
    }
    public override func mouseDragged(with event: NSEvent) {
        if !forwardMouse(event) { super.mouseDragged(with: event) }
    }
    public override func mouseMoved(with event: NSEvent) {
        if !forwardMouse(event) { super.mouseMoved(with: event) }
    }
    public override func rightMouseDown(with event: NSEvent) {
        if !forwardMouse(event) { super.rightMouseDown(with: event) }
    }
    public override func rightMouseUp(with event: NSEvent) {
        if !forwardMouse(event) { super.rightMouseUp(with: event) }
    }
    public override func rightMouseDragged(with event: NSEvent) {
        if !forwardMouse(event) { super.rightMouseDragged(with: event) }
    }
    public override func otherMouseDown(with event: NSEvent) {
        if !forwardMouse(event) { super.otherMouseDown(with: event) }
    }
    public override func otherMouseUp(with event: NSEvent) {
        if !forwardMouse(event) { super.otherMouseUp(with: event) }
    }
    public override func otherMouseDragged(with event: NSEvent) {
        if !forwardMouse(event) { super.otherMouseDragged(with: event) }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isCapturingInput, let onScroll else { return super.scrollWheel(with: event) }
        onScroll(event)
    }

    /// While capturing, a right click must go to the host rather than open a local context menu.
    public override func menu(for event: NSEvent) -> NSMenu? {
        isCapturingInput ? nil : super.menu(for: event)
    }

    // MARK: Keyboard

    private func forwardKey(_ event: NSEvent) -> Bool {
        guard isCapturingInput, let onKey else { return false }
        onKey(event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        if !forwardKey(event) { super.keyDown(with: event) }
    }

    public override func keyUp(with event: NSEvent) {
        if !forwardKey(event) { super.keyUp(with: event) }
    }

    public override func flagsChanged(with event: NSEvent) {
        if !forwardKey(event) { super.flagsChanged(with: event) }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // performKeyEquivalent is offered to every view in the window; only claim it when we hold keyboard focus.
        // ⌘Q stays local unless system shortcuts are sent (its stray key-up is dropped: nothing went down remotely).
        guard event.type == .keyDown, isCapturingInput, isKeyboardTarget(for: event),
              forwardsQuitShortcut || !Self.isQuitShortcut(event), forwardKey(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// True when keyboard events for `event` are meant for this view (first responder of the event's window).
    /// Without a window (unit tests, detached views) the view is considered its own target.
    func isKeyboardTarget(for event: NSEvent) -> Bool {
        guard let window else { return true }
        if let eventWindow = event.window, eventWindow !== window { return false }
        return window.firstResponder === self
    }

    private func updateKeyUpMonitor() {
        if isCapturingInput {
            guard keyUpMonitor == nil else { return }
            keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, self.isCapturingInput, self.window != nil,
                      self.isKeyboardTarget(for: event), self.forwardKey(event) else { return event }
                return nil   // consumed: AppKit will not also dispatch it to keyUp(with:)
            }
        } else if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
    }
}
