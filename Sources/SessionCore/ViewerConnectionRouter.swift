import DiagnosticsCore
import Foundation
import InputCore
import RenderCore
import Synchronization
import TransportCore
import WireProtocol

/// Routes the Viewer connection's transport callbacks; the Viewer-side twin of `HostConnectionRouter`.
///
/// Datagrams go straight into the media pipeline's inbox and PING/PONG are answered on the transport queue, so video
/// and RTT never depend on the main actor. ACCEPT creates and starts the media pipeline *here*, in stream order, so
/// video datagrams that arrive right behind ACCEPT are not dropped while the main actor catches up — but only after the
/// session has sent HELLO/AUTH, so a Host cannot start a stream before the user trusted it.
///
/// Every receive (control message or datagram) stamps `activity`, which the media pipeline's timer turns into the
/// "Poor connection" state (0.1.4): the Host pings every 500 ms, so 1 s of silence means the link stalled even when the
/// Host's screen is static and no video is due.
///
/// Synchronization: flags are `Atomic`s; the pipeline reference sits behind a `Mutex`.
final class ViewerConnectionRouter: @unchecked Sendable {
    enum Event: Sendable {
        case stateChanged(PeerConnectionState)
        case message(ControlMessage)
        /// 0.1.5 clipboard sharing, while streaming only: the Host's switch, its clipboard (side stream), and the side
        /// stream becoming usable. Kept apart from `message` so the handshake reducer never sees them.
        case clipboardState(ClipboardState)
        case clipboard(ClipboardContent)
        case sideStreamReady
        /// 0.1.6 remote pointer shape, while streaming only: CURSOR_SHAPE (control stream) and CURSOR_IMAGE (side
        /// stream).
        case cursorShape(CursorShape)
        case cursorImage(CursorImage)
    }

    let connection: PeerConnection
    /// Side-stream features this Viewer announced (`PeerCapabilities.sideStreamFeatures`): the side stream is opened
    /// at an ACCEPT that announces at least one of them too.
    private let sideStreamFeatures: PeerCapabilities
    private let sinkSlot: FrameSinkSlot
    private let events: @Sendable (Event) -> Void
    private let pipeline = Mutex<ViewerMediaPipeline?>(nil)
    private let handshakeSent = Atomic<Bool>(false)
    private let streaming = Atomic<Bool>(false)
    private let closed = Atomic<Bool>(false)
    /// When the Host was last heard from.
    let activity = LinkActivity()

    init(connection: PeerConnection, sinkSlot: FrameSinkSlot, announced: PeerCapabilities = [],
         events: @escaping @Sendable (Event) -> Void) {
        self.connection = connection
        self.sideStreamFeatures = announced.intersection(.sideStreamFeatures)
        self.sinkSlot = sinkSlot
        self.events = events
    }

    func attach() {
        connection.onControlMessage = { [weak self] message in self?.control(message) }
        connection.onDatagram = { [weak self] datagram in self?.datagram(datagram) }
        connection.onStateChange = { [weak self] state in self?.stateChanged(state) }
        connection.onSideMessage = { [weak self] message in self?.sideMessage(message) }
        connection.onSideStreamReady = { [weak self] in
            guard let self, self.streaming.load(ordering: .acquiring) else { return }
            self.events(.sideStreamReady)
        }
        connection.start()
    }

    /// Called by the session right before it sends HELLO + AUTH.
    func markHandshakeSent() {
        handshakeSent.store(true, ordering: .releasing)
    }

    var mediaPipeline: ViewerMediaPipeline? { pipeline.withLock { $0 } }
    var isStreaming: Bool { streaming.load(ordering: .acquiring) }

    /// Viewer input → wire. Reliable messages on the control stream, pointer state as one datagram.
    func send(_ input: OutgoingInput) {
        guard streaming.load(ordering: .acquiring) else { return }
        switch input {
        case .reliable(let message):
            if let seq = message.inputSequence { PipelineSignpost.input(seq: seq) }
            connection.sendControl(message)
        case .pointer(let pointer):
            PipelineSignpost.input(seq: pointer.seq)
            connection.sendDatagrams([Datagram.encodePointer(pointer)])
        }
    }

    func notePresented(_ info: PresentedFrameInfo) {
        pipeline.withLock { $0 }?.notePresented(info)
    }

    /// Stops routing and the media pipeline. The connection itself is closed by the caller.
    func stop() {
        closed.store(true, ordering: .releasing)
        streaming.store(false, ordering: .releasing)
        let p = pipeline.withLock { p -> ViewerMediaPipeline? in
            defer { p = nil }
            return p
        }
        p?.stop()
    }

    // MARK: Transport queue

    private func control(_ message: ControlMessage) {
        guard !closed.load(ordering: .acquiring) else { return }
        activity.noteReceived()
        switch message {
        case .ping(let ping):
            connection.sendControl(.pong(ping))
        case .pong(let ping):
            pipeline.withLock { $0 }?.pong(ping)
        case .accept(let accept):
            if handshakeSent.load(ordering: .acquiring) {
                let created = pipeline.withLock { p -> ViewerMediaPipeline? in
                    guard p == nil else { return nil }
                    let newPipeline = ViewerMediaPipeline(sessionId: accept.sessionId, transport: connection,
                                                          sinkSlot: sinkSlot, activity: activity)
                    p = newPipeline
                    return newPipeline
                }
                created?.start()
                streaming.store(true, ordering: .releasing)
                // Both sides speak a side-stream feature (clipboard, pointer shape): open the side stream now, so the
                // Host can send as soon as it wants.
                if created != nil, !sideStreamFeatures.intersection(accept.capabilities).isEmpty {
                    connection.openSideStream()
                }
            }
            events(.message(message))
        case .config(let config):
            pipeline.withLock { $0 }?.configure(config)
            events(.message(message))
        case .deny, .disconnect:
            streaming.store(false, ordering: .releasing)
            events(.message(message))
        case .clipboardState(let state):
            guard streaming.load(ordering: .acquiring) else { return }
            events(.clipboardState(state))
        case .cursorShape(let shape):
            guard streaming.load(ordering: .acquiring) else { return }
            events(.cursorShape(shape))
        case .clipboard, .cursorImage:
            // Side stream only; TransportCore already closed a control stream that carried it.
            return
        case .passwordChallenge, .passwordResponse:
            // The handshake reducer only answers a challenge after the user trusted the Host (HELLO/AUTH sent).
            // PASSWORD_RESPONSE(none) Host → Viewer: the Host fell back to its prompt without using the password.
            events(.message(message))
        case .hello, .auth, .keyDown, .keyUp, .mouseDown, .mouseUp, .mouseMove, .scroll, .requestKeyframe, .stats:
            // Viewer-to-Host messages; ignored if a Host sends them.
            return
        }
    }

    /// Side stream (0.1.5): clipboard data and (0.1.6) pointer-shape definitions, only while streaming.
    private func sideMessage(_ message: ControlMessage) {
        guard !closed.load(ordering: .acquiring) else { return }
        activity.noteReceived()
        guard streaming.load(ordering: .acquiring) else { return }
        switch message {
        case .clipboard(let content): events(.clipboard(content))
        case .cursorImage(let image): events(.cursorImage(image))
        default: return
        }
    }

    private func datagram(_ data: Data) {
        activity.noteReceived()
        // Video fragments and their FEC parity; anything else (a pointer datagram from a confused Host) is dropped.
        guard data.first == WireConstants.videoMagic || data.first == WireConstants.parityMagic else { return }
        pipeline.withLock { $0 }?.ingest(data)
    }

    private func stateChanged(_ state: PeerConnectionState) {
        guard !closed.load(ordering: .acquiring) else { return }
        if case .failed = state { streaming.store(false, ordering: .releasing) }
        if case .closed = state { streaming.store(false, ordering: .releasing) }
        events(.stateChanged(state))
    }
}

/// Lets main-actor input callbacks and the Metal presented handler reach the current router without capturing
/// main-actor state in `@Sendable` closures.
final class ViewerRouterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var router: ViewerConnectionRouter?

    var current: ViewerConnectionRouter? {
        get { lock.withLock { router } }
        set { lock.withLock { router = newValue } }
    }
}
