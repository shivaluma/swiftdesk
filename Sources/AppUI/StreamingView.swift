import AppKit
import DiagnosticsCore
import InputCore
import RenderCore
import SessionCore
import SwiftUI

/// The live remote desktop: a compact status toolbar over a window-filling, aspect-fit Metal view.
///
/// Input capture model (PRD §4 Viewer step 5): nothing is forwarded until the user clicks into the video. That
/// first click only starts capture (it is not sent to the Host, so "click to focus" never presses something
/// remotely). The release shortcut (⌃⌥⎋), the toolbar toggle, or losing focus (another window/app, ⌘-Tab) stop
/// capture, and stopping capture releases every key and button held on the Host.
///
/// Sharpness: the window is sized to a whole magnification of the native stream (1:1, or 2:1 pixel doubling) when that
/// fits and is not tiny on the screen, else as large as fits (`ViewerWindowSizer`); the video view sits on whole device
/// pixels, and the renderer samples without filtering whenever the view is exactly a whole multiple of the stream size.
/// View › Actual Size (⌘0) or the toolbar's 1:1 button snaps to strict 1:1.
///
/// Dropouts (0.1.4): the view stays up through them instead of going black. After 1 s with nothing from the Host the
/// last frame is dimmed slightly under a "Poor connection" badge; if the connection fails, the session reconnects and
/// this same view (same Metal layer, so the last frame is kept) shows the reconnect card with progress and Cancel.
/// A short "Reconnected" note confirms the recovery.
///
/// Clipboard (0.1.5): the toolbar's clipboard toggle is the live "Share clipboard" switch (persisted); its tooltip says
/// whether the Host shares too. A copy that could not be shared (too large, files, blocked by macOS) shows a small
/// note over the video for a few seconds.
///
/// Pointer shape (0.1.6): while controlling, the local pointer over the video takes the Host pointer's shape
/// (`RemoteDisplayView.remotePointer`, set by the session). The toolbar's pointer toggle is the live, persisted
/// "Show the Host's pointer shape" switch; its tooltip says what the Host reports.
///
/// System shortcuts (0.1.7): the toolbar's ⌘ menu ("Send Keys") presses ⌘Tab, Spotlight, Mission Control, screenshots,
/// Force Quit, Lock Screen … on the Host, and holds the live, persisted "Send system shortcuts to <Host>" switch. While
/// that switch captures (controlling, focused, Accessibility granted) the ⌘ button is tinted and a short note says so.
/// When it is on but cannot capture (no Accessibility, or the tap refused), a note with Allow… / Open Settings… says
/// so for a few seconds (0.2.0), since the connect form's hint is hidden while streaming.
struct StreamingView: View {
    let viewer: ViewerSession
    let info: ViewerSession.StreamInfo
    /// "Share clipboard" (AppModel, persisted in UserDefaults).
    @Binding var sharesClipboard: Bool
    /// "Show the Host's pointer shape" (AppModel, persisted in UserDefaults).
    @Binding var showsRemotePointer: Bool
    /// "Send system shortcuts to the remote Mac" (AppModel, persisted in UserDefaults).
    @Binding var sendsSystemShortcuts: Bool
    /// A Send Keys item (AppModel: asks first for Lock Screen).
    let sendShortcut: (SystemShortcut) -> Void
    @State private var showDiagnostics = false
    @State private var showShortcutsNote = false
    @State private var showShortcutPermissionNote = false
    @State private var sizer = ViewerWindowSizer()
    @State private var showReconnected = false
    @State private var clipboardNotice: ClipboardNotice?

    /// "Send system shortcuts" is on in a live stream, but Accessibility is missing or the tap was refused.
    private var shortcutCaptureBlocked: Bool {
        sendsSystemShortcuts && viewer.isStreaming && ShortcutPresentation.streamNote(viewer.systemShortcutStatus) != nil
    }

    /// The note's text while it is shown.
    private var shortcutPermissionNote: String? {
        showShortcutPermissionNote ? ShortcutPresentation.streamNote(viewer.systemShortcutStatus) : nil
    }

    /// The CONFIG fields that matter for window sizing.
    private var sizeKey: ViewerWindowSizer.StreamKey? {
        viewer.streamConfig.map { ViewerWindowSizer.StreamKey($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            StreamToolbar(viewer: viewer, info: info, sharesClipboard: $sharesClipboard,
                          showsRemotePointer: $showsRemotePointer, sendsSystemShortcuts: $sendsSystemShortcuts,
                          sendShortcut: sendShortcut, showDiagnostics: $showDiagnostics,
                          actualSize: { sizer.snapToActualSize(animate: true) })
            Divider()
            ZStack {
                Color.black
                RemoteDisplayRepresentable(viewer: viewer, isCapturing: viewer.isCapturingInput, sizer: sizer)
                if case .reconnecting(let status) = viewer.state {
                    ReconnectOverlay(status: status, usingPassword: viewer.isUsingPassword,
                                     tryNow: viewer.reconnectNow, cancel: viewer.disconnect)
                } else {
                    if viewer.streamConfig == nil {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text("Waiting for the first frame…").foregroundStyle(.white.opacity(0.8))
                        }
                        .allowsHitTesting(false)
                    }
                    if !viewer.isCapturingInput {
                        ClickToControlOverlay(hostName: info.hostName) {
                            viewer.isCapturingInput = true
                        }
                    }
                    if viewer.isLinkStalled {
                        PoorConnectionOverlay(hostName: info.hostName)
                    } else if showReconnected || clipboardNotice != nil || showShortcutsNote
                                || shortcutPermissionNote != nil {
                        VStack(spacing: 8) {
                            if showReconnected {
                                StatusCapsule(symbol: Symbols.granted, text: "Reconnected", tint: .green)
                                    .allowsHitTesting(false)
                            }
                            if showShortcutsNote {
                                StatusCapsule(symbol: Symbols.sendKeys,
                                              text: "System shortcuts go to \(info.hostName) · \(ViewerSession.releaseShortcutDescription) to release",
                                              tint: .accentColor)
                                    .allowsHitTesting(false)
                            }
                            if let shortcutPermissionNote {
                                ShortcutPermissionCapsule(text: shortcutPermissionNote,
                                                          allow: viewer.requestShortcutPermission,
                                                          openSettings: viewer.openShortcutPermissionSettings,
                                                          dismiss: { showShortcutPermissionNote = false })
                            }
                            if let clipboardNotice {
                                StatusCapsule(symbol: Symbols.clipboard,
                                              text: ClipboardPresentation.notice(clipboardNotice), tint: .orange)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewer.isLinkStalled)
            .animation(.easeInOut(duration: 0.2), value: viewer.isReconnecting)
            .animation(.easeInOut(duration: 0.3), value: showReconnected)
            .animation(.easeInOut(duration: 0.3), value: clipboardNotice?.id)
            .animation(.easeInOut(duration: 0.3), value: showShortcutsNote)
            .animation(.easeInOut(duration: 0.3), value: shortcutPermissionNote)
        }
        .task(id: shortcutCaptureBlocked) {
            // The switch is on during a stream but cannot take shortcuts: say so (it never prompts by itself).
            guard shortcutCaptureBlocked else {
                showShortcutPermissionNote = false
                return
            }
            showShortcutPermissionNote = true
            try? await Task.sleep(for: .seconds(10))
            showShortcutPermissionNote = false
        }
        .task(id: viewer.systemShortcutStatus == .active) {
            // A short note each time capture starts taking system shortcuts, so ⌘Tab not switching apps here is
            // never a surprise.
            guard viewer.systemShortcutStatus == .active else {
                showShortcutsNote = false
                return
            }
            showShortcutsNote = true
            try? await Task.sleep(for: .seconds(3))
            showShortcutsNote = false
        }
        .task(id: viewer.clipboardStatus.notice?.id) {
            guard let notice = viewer.clipboardStatus.notice else { return }
            clipboardNotice = notice
            try? await Task.sleep(for: .seconds(4))
            if clipboardNotice?.id == notice.id { clipboardNotice = nil }
        }
        .task(id: viewer.lastReconnectedAt) {
            guard viewer.lastReconnectedAt != nil else { return }
            showReconnected = true
            try? await Task.sleep(for: .seconds(3))
            showReconnected = false
        }
        .onChange(of: sizeKey, initial: true) { _, key in
            if let key { sizer.streamChanged(key) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ViewerWindowSizer.actualSizeNotification)) { _ in
            sizer.snapToActualSize(animate: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeBackingPropertiesNotification)) { note in
            sizer.backingPropertiesChanged(window: note.object as? NSWindow)
        }
    }
}

/// Nothing has arrived from the Host for a second: the last frame stays, slightly dimmed, under a badge. Input
/// capture is unaffected (the Host releases held keys on its side after the same second).
private struct PoorConnectionOverlay: View {
    let hostName: String

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
            StatusCapsule(symbol: Symbols.poorConnection, text: "Poor connection — waiting for \(hostName)…",
                          tint: .orange, showsProgress: true)
                .padding(.top, 14)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Poor connection. Waiting for \(hostName).")
    }
}

/// Small material capsule over the video (status notes).
private struct StatusCapsule: View {
    let symbol: String
    let text: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

/// "Send system shortcuts" cannot work right now: what to do, with Allow… (the macOS prompt), Open Settings… and a
/// close button. The only interactive note over the video.
struct ShortcutPermissionCapsule: View {
    let text: String
    let allow: () -> Void
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbols.warning).foregroundStyle(.orange)
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Button("Allow…", action: allow)
            Button("Open Settings…", action: openSettings)
            Button(action: dismiss) {
                Image(systemName: Symbols.dismiss)
            }
            .buttonStyle(.borderless)
            .help("Hide")
            .accessibilityLabel("Hide")
        }
        .font(.callout.weight(.medium))
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: 640)
    }
}

/// The connection failed and the session is redialing: the last frame, dimmed, under a card with what is happening,
/// a countdown to the next attempt, Try Now and Cancel.
private struct ReconnectOverlay: View {
    let status: ViewerSession.ReconnectStatus
    let usingPassword: Bool
    let tryNow: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Reconnecting to \(status.stream.hostName)…")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ReconnectPresentation.detail(status, usingPassword: usingPassword, now: context.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = status.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button("Cancel", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                    if case .waiting = status.phase {
                        Button("Try Now", action: tryNow)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                .padding(.top, 2)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 12)
            .padding(24)
        }
        .transition(.opacity)
    }
}

/// Transparent layer over the video while input is not captured: takes the first click and shows the hint.
private struct ClickToControlOverlay: View {
    let hostName: String
    let start: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: start)
            Label {
                Text("Click to control \(hostName) · press \(ViewerSession.releaseShortcutDescription) to release")
            } icon: {
                Image(systemName: Symbols.cursorClick)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 18)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Start controlling \(hostName)")
        .accessibilityAction(.default, start)
    }
}

/// Live numbers the PRD asks for (RTT, FPS, bitrate, loss, decode→present, resolution, path), the capture
/// toggle with its release shortcut, the full diagnostics popover, and Disconnect.
///
/// Adapts to the window width (review 0.2.0): the full row needs ≈ 1100 pt, more than the 1:1 window of a 1600×900
/// Host on a Retina Viewer (800 pt), so `ViewThatFits` falls back to fewer metrics, then to icons only with every
/// number in the diagnostics popover. The narrowest row fits `RootView.streamingMinimum` (480 pt), so the toolbar
/// never raises the window's minimum width and `ViewerWindowSizer` can always make a 1:1 window.
struct StreamToolbar: View {
    enum Density: CaseIterable {
        /// Every metric, the release shortcut, labelled buttons.
        case full
        /// RTT, FPS and bitrate only; no release-shortcut text.
        case compact
        /// No metrics (they are in the diagnostics popover), icon-only buttons, tighter spacing.
        case minimal
    }

    let viewer: ViewerSession
    let info: ViewerSession.StreamInfo
    @Binding var sharesClipboard: Bool
    @Binding var showsRemotePointer: Bool
    @Binding var sendsSystemShortcuts: Bool
    let sendShortcut: (SystemShortcut) -> Void
    @Binding var showDiagnostics: Bool
    let actualSize: () -> Void
    /// Tests: sample metrics instead of the session's (realistic widths without a live stream).
    var metricsOverride: MetricsSnapshot?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Density.allCases, id: \.self) { density in
                row(density)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    /// One toolbar row at `density`.
    func row(_ density: Density) -> some View {
        let m = metricsOverride ?? viewer.metrics
        return HStack(spacing: density == .minimal ? 6 : (density == .compact ? 11 : 14)) {
            HStack(spacing: 6) {
                Image(systemName: info.isTrusted ? Symbols.trusted : Symbols.lock)
                    .foregroundStyle(info.isTrusted ? Color.green : Color.secondary)
                    .help(info.isTrusted ? "Trusted Host (fingerprint pinned)" : "Verified for this session only")
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.hostName).font(.headline).lineLimit(1)
                    Group {
                        if viewer.isReconnecting {
                            Text("Reconnecting… · \(info.remoteAddress)")
                        } else if viewer.isLinkStalled {
                            Text("Poor connection · \(info.remoteAddress)")
                        } else {
                            Text(viewer.pathDescription.isEmpty ? info.remoteAddress : "\(viewer.pathDescription) · \(info.remoteAddress)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            // A long name or path truncates rather than pushing the row to a narrower density.
            .frame(maxWidth: density == .full ? 300 : (density == .compact ? 220 : 160), alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: density == .minimal ? 4 : 8)

            if density != .minimal {
                ToolbarMetric(symbol: Symbols.rtt, value: MetricsFormat.rtt(m.rtt), help: "Round-trip time (smoothed)")
                ToolbarMetric(symbol: Symbols.fps, value: "\(MetricsFormat.fps(m.fps)) fps", help: "Frames presented per second")
                ToolbarMetric(symbol: Symbols.bitrate, value: MetricsFormat.bitrate(kbps: m.bitrateKbps), help: "Received video bitrate")
            }
            if density == .full {
                ToolbarMetric(symbol: Symbols.loss, value: MetricsFormat.percent(m.packetLossPercent), help: "Estimated packet loss")
                ToolbarMetric(symbol: Symbols.latency,
                              value: m.decodeToPresent.count > 0 ? MetricsFormat.millis(m.decodeToPresent.p50) : MetricsFormat.placeholder,
                              help: "Decode → present latency (p50)")
                ToolbarMetric(symbol: Symbols.resolution, value: MetricsFormat.resolution(width: m.width, height: m.height),
                              help: "Encoded stream resolution (what the Host's encoder produces)")
            }

            Button(action: actualSize) {
                Image(systemName: Symbols.actualSize)
            }
            .help("Actual Size (⌘0): one stream pixel per screen pixel, the sharpest picture")
            .accessibilityLabel("Actual Size")

            Divider().frame(height: 22)

            Toggle(isOn: Binding(get: { viewer.isCapturingInput }, set: { viewer.isCapturingInput = $0 })) {
                Label(viewer.isCapturingInput ? "Controlling" : "Control", systemImage: Symbols.keyboard)
                    .labelStyle(ToolbarLabelStyle(iconOnly: density == .minimal))
            }
            .toggleStyle(.button)
            .tint(viewer.isCapturingInput ? .accentColor : nil)
            .disabled(!viewer.isStreaming)
            .help("Forward keyboard and mouse to the Host. Release with \(ViewerSession.releaseShortcutDescription).")

            if density == .full {
                Text(ViewerSession.releaseShortcutDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Release shortcut: Control-Option-Escape")
            }

            ClipboardToggle(status: viewer.clipboardStatus, hostName: info.hostName, isOn: $sharesClipboard,
                            streaming: viewer.isStreaming)
            PointerToggle(status: viewer.remotePointerStatus, hostName: info.hostName, isOn: $showsRemotePointer)
            SendKeysMenu(status: viewer.systemShortcutStatus, hostName: info.hostName,
                         sendsSystemShortcuts: $sendsSystemShortcuts, streaming: viewer.isStreaming,
                         send: sendShortcut, allow: viewer.requestShortcutPermission)

            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: Symbols.diagnostics)
            }
            .help("Diagnostics")
            .accessibilityLabel("Diagnostics")
            .popover(isPresented: $showDiagnostics, arrowEdge: .bottom) {
                ScrollView {
                    DiagnosticsGrid(metrics: m, role: .viewer)
                        .padding(16)
                }
                .frame(width: 380, height: 460)
            }

            Button(role: .destructive) {
                viewer.disconnect()
            } label: {
                Label("Disconnect", systemImage: Symbols.disconnect)
                    .labelStyle(ToolbarLabelStyle(iconOnly: density == .minimal))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help(viewer.isReconnecting ? "Stop reconnecting (⇧⌘D)" : "End the session (⇧⌘D)")
        }
    }
}

/// Title and icon, or the icon alone (the title stays the accessibility label).
private struct ToolbarLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

/// The live "Share clipboard" switch. Filled while clipboards are actually synced; the tooltip says why not otherwise
/// (off here, off on the Host, or an older Host).
private struct ClipboardToggle: View {
    let status: ClipboardSyncStatus
    let hostName: String
    @Binding var isOn: Bool
    let streaming: Bool

    var body: some View {
        let description = streaming ? ClipboardPresentation.status(status, peerName: hostName) : "Share clipboard"
        Toggle(isOn: $isOn) {
            Image(systemName: isOn ? Symbols.clipboard : Symbols.clipboardOff)
                .symbolVariant(status.isActive ? .fill : .none)
        }
        .toggleStyle(.button)
        .tint(status.isActive ? .accentColor : nil)
        .disabled(streaming && !status.peerSupports)
        .help("\(description). Copy here, click into the remote screen, then paste.")
        .accessibilityLabel("Share clipboard")
        .accessibilityValue(description)
    }
}

/// The live "Show the Host's pointer shape" switch. Filled while the Host's shape is in use; the tooltip says what the
/// Host reports otherwise (an older Host, off there, unavailable).
private struct PointerToggle: View {
    let status: RemotePointerStatus
    let hostName: String
    @Binding var isOn: Bool

    var body: some View {
        let description = PointerPresentation.viewerStatus(status, enabled: isOn, hostName: hostName)
        let active = isOn && status == .active
        Toggle(isOn: $isOn) {
            Image(systemName: Symbols.pointer)
                .symbolVariant(active ? .fill : .none)
        }
        .toggleStyle(.button)
        .tint(active ? .accentColor : nil)
        .disabled(status == .unsupported)
        .help("\(description). Your pointer is always drawn on this Mac, so it moves instantly.")
        .accessibilityLabel("Show the Host's pointer shape")
        .accessibilityValue(description)
    }
}

/// "Send Keys" (0.1.7): presses a macOS system shortcut on the Host, and holds the "Send system shortcuts" switch.
/// Tinted while the keyboard tap takes system shortcuts; the tooltip says where they go right now.
private struct SendKeysMenu: View {
    let status: SystemShortcutCaptureStatus
    let hostName: String
    @Binding var sendsSystemShortcuts: Bool
    let streaming: Bool
    let send: (SystemShortcut) -> Void
    let allow: () -> Void

    var body: some View {
        let description = ShortcutPresentation.status(status, hostName: hostName)
        Menu {
            Section("Send to \(hostName)") {
                SendKeysMenuItems(send: send)
            }
            Divider()
            Toggle("Send System Shortcuts While Controlling", isOn: $sendsSystemShortcuts)
            if status == .needsPermission || status == .unavailable {
                Button("Allow SwiftDesk Under Accessibility…", action: allow)
            }
        } label: {
            Image(systemName: Symbols.sendKeys)
                .symbolVariant(status == .active ? .square.fill : .none)
                .foregroundStyle(status == .active ? Color.accentColor : Color.primary)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!streaming)
        .help("Send Keys: press ⌘Tab, Spotlight, Mission Control, screenshots … on \(hostName). \(description).")
        .accessibilityLabel("Send Keys")
        .accessibilityValue(description)
    }
}

private struct ToolbarMetric: View {
    let symbol: String
    let value: String
    let help: String

    var body: some View {
        Label {
            Text(value).monospacedDigit().lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize()
        .help(help)
        .accessibilityLabel("\(help): \(value)")
    }
}

/// Hosts RenderCore's `RemoteDisplayView` (Metal, aspect-fit, input capture) inside SwiftUI.
///
/// The session holds the view weakly and wires its input callbacks in `attach(renderView:)`; this wrapper adds two
/// UI policies on top: losing focus also turns capture off (so input never keeps flowing to a window the user
/// left), and turning capture on makes the view first responder so keystrokes reach it immediately.
struct RemoteDisplayRepresentable: NSViewRepresentable {
    let viewer: ViewerSession
    let isCapturing: Bool
    var sizer: ViewerWindowSizer?

    func makeCoordinator() -> RenderAttachment {
        RenderAttachment(owner: viewer) { [weak viewer] in
            viewer?.isCapturingInput = false
            viewer?.attach(renderView: nil)
        }
    }

    func makeNSView(context: Context) -> PixelAlignedContainer {
        let view = RemoteDisplayView(frame: .zero)
        viewer.attach(renderView: view)
        view.onFocusChange = { [weak viewer] focused in
            guard let viewer else { return }
            viewer.focusChanged(focused)
            if !focused { viewer.isCapturingInput = false }
        }
        context.coordinator.attached(view)
        sizer?.view = view
        return PixelAlignedContainer(content: view)
    }

    func updateNSView(_ container: PixelAlignedContainer, context: Context) {
        let view = container.content
        guard isCapturing, let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    static func dismantleNSView(_ container: PixelAlignedContainer, coordinator: RenderAttachment) {
        coordinator.detachIfCurrent(container.content)
    }
}

/// Holds the render view on whole device pixels. SwiftUI may give the video area a fractional size or origin (e.g. a
/// 44.5 pt toolbar on a 1× screen); a Metal layer there is stretched or shifted by a fraction of a pixel by the
/// compositor, which softens the whole picture even when the stream itself is drawn 1:1.
@MainActor
final class PixelAlignedContainer: NSView {
    let content: RemoteDisplayView

    init(content: RemoteDisplayView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        alignContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        alignContent()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        alignContent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        alignContent()
    }

    private func alignContent() {
        // Inward, so the video never overhangs the area SwiftUI gave it; without a window there is no backing grid.
        let aligned = window == nil ? bounds : backingAlignedRect(bounds, options: .alignAllEdgesInward)
        if content.frame != aligned { content.frame = aligned }
    }
}

/// Remembers which view is attached to a session, so tearing down an old SwiftUI view never detaches the newer
/// one that replaced it (SwiftUI may build the replacement before dismantling the old view).
@MainActor
final class RenderAttachment {
    private struct WeakView {
        weak var view: NSView?
    }

    private static var current: [ObjectIdentifier: WeakView] = [:]

    private let ownerID: ObjectIdentifier
    private let detach: @MainActor () -> Void

    init(owner: AnyObject, detach: @escaping @MainActor () -> Void) {
        self.ownerID = ObjectIdentifier(owner)
        self.detach = detach
    }

    func attached(_ view: NSView) {
        Self.current[ownerID] = WeakView(view: view)
    }

    /// Runs `detach` unless another view has been attached to the same owner since `view`.
    func detachIfCurrent(_ view: NSView) {
        if let current = Self.current[ownerID]?.view, current !== view { return }
        Self.current[ownerID] = nil
        detach()
    }
}
