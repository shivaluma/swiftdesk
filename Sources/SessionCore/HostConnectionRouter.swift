import DiagnosticsCore
import Foundation
import Synchronization
import TransportCore
import WireProtocol

/// Routes one Host-side connection's transport callbacks without touching the main actor on the hot path.
///
/// Input, pointer datagrams, keyframe requests, STATS and PING/PONG are handled right on the transport queue (atomics
/// and one short lock); only rare session events — HELLO/AUTH, DISCONNECT, transport end — are forwarded to the
/// session, which hops them to the main actor. Before the session activates the router (operator approval), input is
/// dropped here: nothing reaches the injector until consent.
///
/// Input safety across dropouts (0.1.4): every receive stamps `activity`; while the session is active a 200 ms
/// watchdog releases every held key, modifier and mouse button once the Viewer has been silent for
/// `silenceThresholdNanos` (1 s — the Viewer pings every 500 ms, so a live link is never that quiet), and reports
/// `.peerSilence`. The session itself is not ended for that: the QUIC idle timeout (30 s) decides when the
/// connection is gone.
///
/// Synchronization: `phase` is an `Atomic`; the active pipeline/sink pair sits behind a `Mutex`; the watchdog's
/// detector and timer behind another, touched only by the timer and by activate/deactivate.
final class HostConnectionRouter: @unchecked Sendable {
    enum Event: Sendable {
        case handshake(ControlMessage)
        case peerDisconnected(DisconnectReason)
        case transportEnded(PeerConnectionState)
        /// true: the Viewer has been silent past the threshold (held input was just released); false: heard again.
        case peerSilence(Bool)
        /// 0.1.5 clipboard sharing, active sessions only: the Viewer's switch, its clipboard (side stream), and the
        /// side stream becoming usable.
        case clipboardState(ClipboardState)
        case clipboard(ClipboardContent)
        case sideStreamReady
    }

    private struct Watchdog {
        var detector: LinkSilenceDetector
        var timer: (any DispatchSourceTimer)?
    }

    static let watchdogIntervalNanos: UInt64 = 200_000_000
    private static let watchdogQueue = DispatchQueue(label: "com.swiftdesk.session.host.watchdog", qos: .userInitiated)

    private enum Phase: UInt8 {
        case handshake = 0, active = 1, closed = 2
    }

    private struct Active {
        var pipeline: HostMediaPipeline?
        var sink: (any InputSink)?
    }

    let connection: PeerConnection
    let id = UUID()
    private let events: @Sendable (Event) -> Void
    private let phase = Atomic<UInt8>(Phase.handshake.rawValue)
    private let active = Mutex(Active())
    /// When the Viewer was last heard from (control message or datagram).
    let activity = LinkActivity()
    private let watchdog: Mutex<Watchdog>
    private let announced = Mutex<PeerCapabilities>([])

    init(connection: PeerConnection, silenceThresholdNanos: UInt64 = 1_000_000_000,
         events: @escaping @Sendable (Event) -> Void) {
        self.connection = connection
        self.events = events
        self.watchdog = Mutex(Watchdog(detector: LinkSilenceDetector(thresholdNanos: silenceThresholdNanos)))
    }

    /// Installs callbacks and starts delivery (the connection is already established).
    func attach() {
        connection.onControlMessage = { [weak self] message in self?.control(message) }
        connection.onDatagram = { [weak self] datagram in self?.datagram(datagram) }
        connection.onStateChange = { [weak self] state in self?.stateChanged(state) }
        connection.onSideMessage = { [weak self] message in self?.sideMessage(message) }
        connection.onSideStreamReady = { [weak self] in self?.events(.sideStreamReady) }
        connection.start()
    }

    /// Capabilities the Viewer announced in its AUTH (empty before AUTH or for older Viewers).
    var peerCapabilities: PeerCapabilities { announced.withLock { $0 } }

    func activate(pipeline: HostMediaPipeline, sink: any InputSink) {
        active.withLock { $0 = Active(pipeline: pipeline, sink: sink) }
        phase.store(Phase.active.rawValue, ordering: .releasing)
        connection.allowSideStream()   // no side-stream byte is read or decoded before authorization
        startWatchdog()
    }

    /// Stops routing and hands back what was active, for teardown. Idempotent.
    func deactivate() -> (pipeline: HostMediaPipeline?, sink: (any InputSink)?) {
        phase.store(Phase.closed.rawValue, ordering: .releasing)
        watchdog.withLock { w in
            w.timer?.cancel()
            w.timer = nil
        }
        let taken = active.withLock { a -> Active in
            defer { a = Active() }
            return a
        }
        return (taken.pipeline, taken.sink)
    }

    var isActive: Bool { phase.load(ordering: .acquiring) == Phase.active.rawValue }

    // MARK: Silence watchdog

    private func startWatchdog() {
        activity.noteReceived()
        let interval = Int(Self.watchdogIntervalNanos)
        let timer = DispatchSource.makeTimerSource(queue: Self.watchdogQueue)
        timer.schedule(deadline: .now() + .nanoseconds(interval), repeating: .nanoseconds(interval),
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        let previous = watchdog.withLock { w -> (any DispatchSourceTimer)? in
            defer { w.timer = timer }
            return w.timer
        }
        previous?.cancel()
        timer.resume()
    }

    private func watchdogTick() {
        guard isActive else { return }
        let lastHeard = activity.lastHeardNanos
        let change = watchdog.withLock { $0.detector.update(lastHeardNanos: lastHeard, nowNanos: MonotonicClock.nowNanos()) }
        switch change {
        case .silent?:
            // Nothing stays pressed on the Host while the Viewer cannot send the key-up / button-up.
            active.withLock { $0.sink }?.releaseAll()
            events(.peerSilence(true))
        case .resumed?:
            events(.peerSilence(false))
        case nil:
            break
        }
    }

    // MARK: Transport queue

    private func control(_ message: ControlMessage) {
        activity.noteReceived()
        switch message {
        case .ping(let ping):
            connection.sendControl(.pong(ping))
        case .pong(let ping):
            active.withLock { $0.pipeline }?.pong(ping)
        case .hello, .auth, .passwordResponse:
            guard phase.load(ordering: .acquiring) == Phase.handshake.rawValue else { return }
            if case .auth(let auth) = message { announced.withLock { $0 = auth.capabilities } }
            events(.handshake(message))
        case .keyDown, .keyUp, .mouseDown, .mouseUp, .mouseMove, .scroll:
            guard isActive else { return }
            if let seq = message.inputSequence { PipelineSignpost.input(seq: seq) }
            active.withLock { $0.sink }?.handle(message)
        case .requestKeyframe:
            guard isActive else { return }
            active.withLock { $0.pipeline }?.keyframeRequested()
        case .stats(let stats):
            guard isActive else { return }
            active.withLock { $0.pipeline }?.viewerStats(stats)
        case .disconnect(let reason):
            guard phase.load(ordering: .acquiring) != Phase.closed.rawValue else { return }
            events(.peerDisconnected(reason))
        case .clipboardState(let state):
            guard isActive else { return }
            events(.clipboardState(state))
        case .clipboard:
            // Side stream only; TransportCore already closed a control stream that carried it.
            return
        case .accept, .deny, .config, .passwordChallenge, .cursorImage, .cursorShape:
            // Host-to-Viewer messages; a Viewer sending them is ignored rather than trusted.
            return
        }
    }

    /// Side stream (0.1.5): only clipboard data, only while the session is active (never before consent). A
    /// CURSOR_IMAGE (Host → Viewer) from a Viewer is ignored.
    private func sideMessage(_ message: ControlMessage) {
        activity.noteReceived()
        guard isActive, case .clipboard(let content) = message else { return }
        events(.clipboard(content))
    }

    private func datagram(_ data: Data) {
        activity.noteReceived()
        guard isActive, data.first == WireConstants.pointerMagic,
              case .pointer(let pointer)? = try? Datagram.parse(data) else { return }
        PipelineSignpost.input(seq: pointer.seq)
        active.withLock { $0.sink }?.handlePointer(pointer)
    }

    private func stateChanged(_ state: PeerConnectionState) {
        switch state {
        case .failed, .closed:
            guard phase.load(ordering: .acquiring) != Phase.closed.rawValue else { return }
            events(.transportEnded(state))
        case .connecting, .ready:
            return
        }
    }

    // MARK: Rejections

    /// DENY then close. The DISCONNECT that `close(reason:)` appends travels after the DENY on the same ordered
    /// stream, and `close` keeps the connection alive until it was sent.
    static func reject(_ connection: PeerConnection, reason: DenyReason, message: String) {
        connection.sendControl(.deny(Deny(reason: reason, message: message)))
        connection.close(reason: closeReason(forDeny: reason))
    }

    /// Answers a connection that arrives while another one is pending or active.
    static func rejectBusy(_ connection: PeerConnection) {
        connection.onControlMessage = nil
        connection.onDatagram = nil
        connection.onStateChange = nil
        connection.start()
        reject(connection, reason: .busy, message: "Another session is in progress")
    }

    static func closeReason(forDeny reason: DenyReason) -> DisconnectReason {
        switch reason {
        case .timeout: .timeout
        case .versionMismatch, .identityMismatch: .protocolError
        case .userDenied, .busy, .rateLimited, .permissionsMissing, .authFailed: .hostStopped
        }
    }
}
