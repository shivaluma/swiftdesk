import Foundation
@preconcurrency import Network
import Synchronization
import DiagnosticsCore
import WireProtocol

public enum PeerConnectionState: Sendable, Equatable {
    case connecting
    case ready
    case failed(String)
    case closed

    var isTerminal: Bool {
        switch self {
        case .failed, .closed: return true
        case .connecting, .ready: return false
        }
    }
}

/// Lifetime counters for diagnostics. Datagram counts are per datagram, backpressure drops per batch.
public struct PeerConnectionStats: Sendable, Equatable {
    public var datagramsSent: UInt64 = 0
    public var datagramsReceived: UInt64 = 0
    public var datagramBytesReceived: UInt64 = 0
    /// Whole `sendDatagrams` batches refused because the send backlog exceeded `maxBacklogBytes`.
    public var datagramBatchesDroppedBackpressure: UInt64 = 0
    /// Datagrams discarded by `simulatedDatagramLossPercent` (debug only).
    public var datagramsDroppedSimulated: UInt64 = 0
    public var controlMessagesSent: UInt64 = 0
    public var controlMessagesReceived: UInt64 = 0
    public init() {}
}

/// One authenticated QUIC session between Viewer and Host: a reliable, ordered control stream plus an unreliable
/// datagram flow, multiplexed on a single QUIC connection (`NWConnectionGroup` over `NWMultiplexGroup`) — and, since
/// 0.1.5, an optional second reliable stream for bulk payloads (the **side stream**, `openSideStream()`).
///
/// Why one connection: control (input, keyframe requests) and video share congestion state and the TLS identity
/// check happens once; control messages travel on their own stream so they never wait behind video, and video
/// uses DATAGRAM frames so a lost fragment is never retransmitted late (PRD §6 rules 3 and 5).
///
/// Threading: every Network.framework handler and every callback runs on one private serial transport queue.
/// `sendDatagrams` and `sendControl` are called directly from the producer's queue (no hop): Network.framework
/// connections are thread-safe for sends, and the only shared state they touch is behind a `Mutex` (flow
/// references, published state) or `Atomic`s (backlog accounting, counters). Queue-confined state is marked.
public final class PeerConnection: @unchecked Sendable {
    enum Role: Sendable { case viewer, host }

    /// Handshake + flow setup budget. A viewer whose pinned fingerprint is rejected never sees the group fail
    /// (the group retries silently), so this also bounds that case when the verify block cannot report it.
    static let defaultEstablishmentTimeout: TimeInterval = 10
    /// Bound on control messages queued before the control stream exists (they are flushed in order).
    static let maxPendingControlMessages = 256

    // MARK: Immutable

    let role: Role
    let queue: DispatchQueue
    private let verifyQueue: DispatchQueue
    private let group: NWConnectionGroup
    /// The exact options object `group` was created with (see `QUICConfiguration.datagramFlowOptions(from:)`).
    private let groupOptions: NWProtocolQUIC.Options
    private let pinnedHostFingerprint: Data?
    private let establishmentTimeout: TimeInterval

    // MARK: Callbacks (Mutex: may be set from any thread; read on the transport queue)

    private struct Callbacks {
        var onStateChange: (@Sendable (PeerConnectionState) -> Void)?
        var onControlMessage: (@Sendable (ControlMessage) -> Void)?
        var onDatagram: (@Sendable (Data) -> Void)?
        var onProtocolError: (@Sendable (WireError) -> Void)?
        var onSideMessage: (@Sendable (ControlMessage) -> Void)?
        var onSideStreamReady: (@Sendable () -> Void)?
        var internalStateObserver: (@Sendable (PeerConnection, PeerConnectionState) -> Void)?
    }
    private let callbacks = Mutex(Callbacks())

    public var onStateChange: (@Sendable (PeerConnectionState) -> Void)? {
        get { callbacks.withLock { $0.onStateChange } }
        set { callbacks.withLock { $0.onStateChange = newValue } }
    }
    /// In order, on the transport queue.
    public var onControlMessage: (@Sendable (ControlMessage) -> Void)? {
        get { callbacks.withLock { $0.onControlMessage } }
        set { callbacks.withLock { $0.onControlMessage = newValue } }
    }
    /// On the transport queue; must return fast (hand off to the reassembly queue).
    public var onDatagram: (@Sendable (Data) -> Void)? {
        get { callbacks.withLock { $0.onDatagram } }
        set { callbacks.withLock { $0.onDatagram = newValue } }
    }
    /// Malformed control stream: the connection is closed right after this fires.
    public var onProtocolError: (@Sendable (WireError) -> Void)? {
        get { callbacks.withLock { $0.onProtocolError } }
        set { callbacks.withLock { $0.onProtocolError = newValue } }
    }
    /// 0.1.5: messages from the side stream (only `ControlMessageType.isSideStream` types), in order, on the
    /// transport queue. Anything else on that stream is a protocol error and closes the connection.
    public var onSideMessage: (@Sendable (ControlMessage) -> Void)? {
        get { callbacks.withLock { $0.onSideMessage } }
        set { callbacks.withLock { $0.onSideMessage = newValue } }
    }
    /// 0.1.5: the side stream is usable for `sendSide` (Viewer: it opened; Host: the Viewer's preamble arrived).
    /// On the transport queue, at most once per connection.
    public var onSideStreamReady: (@Sendable () -> Void)? {
        get { callbacks.withLock { $0.onSideStreamReady } }
        set { callbacks.withLock { $0.onSideStreamReady = newValue } }
    }
    /// HostListener's private observer; called before `onStateChange` and also before `start()`.
    var internalStateObserver: (@Sendable (PeerConnection, PeerConnectionState) -> Void)? {
        get { callbacks.withLock { $0.internalStateObserver } }
        set { callbacks.withLock { $0.internalStateObserver = newValue } }
    }

    // MARK: Shared state (Mutex)

    private struct Shared {
        var state: PeerConnectionState = .connecting
        var peerFingerprint: Data?
        var remoteAddress: String
        var maxDatagramSize = WireConstants.defaultMaxDatagramSize
        var datagramFlow: NWConnection?
        var control: NWConnection?
        var side: NWConnection?
        var pendingControl: [Data] = []
        var closing = false
        var pinMismatch = false
        var stats = PeerConnectionStats()
    }
    private let shared: Mutex<Shared>

    // MARK: Hot-path atomics

    private let pendingBytes = Atomic<Int>(0)
    private let backlogLimit = Atomic<Int>(PeerConnection.defaultMaxBacklogBytes)
    private let lossPercentBits = Atomic<UInt64>(0.0.bitPattern)
    private let datagramsSent = Atomic<UInt64>(0)
    private let datagramsReceived = Atomic<UInt64>(0)
    private let datagramBytesReceived = Atomic<UInt64>(0)
    private let batchesDropped = Atomic<UInt64>(0)
    private let simulatedDrops = Atomic<UInt64>(0)

    // MARK: Transport-queue-confined state

    private var started = false
    private var delivering = false              // data callbacks only after start()
    private var terminated = false
    private var callbacksSuppressed = false     // set when close() starts: no data callbacks after .closed
    private var lastDeliveredState: PeerConnectionState?
    private var decoder = ControlStreamDecoder()
    private var controlStream: NWConnection?    // viewer: opened by us; host: the stream that sent the preamble
    private var controlStreamReady = false
    private var peerPreambleReceived = false
    private var preambleBuffers: [ObjectIdentifier: Data] = [:]
    private var stashedControlBytes = Data()    // control bytes received before start() / before .ready
    private var controlPaused = false           // host: receive loop parked until start()
    private var datagramFlowLocal: NWConnection?
    private var datagramReady = false
    private var armedDatagramFlows: Set<ObjectIdentifier> = []
    private var extraDatagramFlows: [NWConnection] = []
    private var streamCandidates: [NWConnection] = []
    private var receivedDisconnect = false
    private var timeoutItem: DispatchWorkItem?
    /// 0.1.5 side stream: viewer: the one it opened; host: the stream whose side preamble arrived. At most one.
    private var sideStream: NWConnection?
    private var sideDecoder = ControlStreamDecoder(maxMessageSize: WireConstants.maxSideStreamMessageSize)
    /// Host: set by `allowSideStream()` once the session is authorized. Until then extra streams are parked unread.
    private var sideStreamAllowed = false
    /// Host: extra streams that sent data before `allowSideStream()`, with their first received bytes (≤ 64 KiB
    /// each, at most `maxParkedStreams`). Not read further, so QUIC flow control holds the rest back.
    private var parkedStreams: [(stream: NWConnection, data: Data)] = []
    private static let maxParkedStreams = 2

    // MARK: Init

    private init(role: Role, group: NWConnectionGroup, groupOptions: NWProtocolQUIC.Options, remoteAddress: String,
                 pinnedHostFingerprint: Data?, verifyQueue: DispatchQueue, establishmentTimeout: TimeInterval) {
        self.role = role
        self.group = group
        self.groupOptions = groupOptions
        self.pinnedHostFingerprint = pinnedHostFingerprint
        self.verifyQueue = verifyQueue
        self.establishmentTimeout = establishmentTimeout
        self.queue = DispatchQueue(label: "com.swiftdesk.transport.\(role == .viewer ? "viewer" : "host")",
                                   qos: .userInteractive)
        self.shared = Mutex(Shared(remoteAddress: remoteAddress))
    }

    deinit {
        group.cancel()
    }

    /// Viewer side. If `pinnedHostFingerprint` is non-nil the TLS handshake fails unless the host leaf cert matches.
    /// If nil, the handshake succeeds and the session layer must get explicit user trust before sending HELLO.
    public static func connect(host: String, port: UInt16, identity: DeviceIdentity,
                               pinnedHostFingerprint: Data?) -> PeerConnection {
        connect(host: host, port: port, identity: identity, pinnedHostFingerprint: pinnedHostFingerprint,
                establishmentTimeout: defaultEstablishmentTimeout)
    }

    /// Same as `connect(host:port:identity:pinnedHostFingerprint:)` with a custom handshake + flow setup budget.
    public static func connect(host: String, port: UInt16, identity: DeviceIdentity, pinnedHostFingerprint: Data?,
                               establishmentTimeout: TimeInterval) -> PeerConnection {
        let verifyQueue = DispatchQueue(label: "com.swiftdesk.transport.verify")
        let mismatch = MismatchRelay()
        let pin = pinnedHostFingerprint
        let options = QUICConfiguration.groupOptions(identity: identity, role: .viewer, verifyQueue: verifyQueue) { fp in
            guard let fp else { return false }
            if let pin, fp != pin {
                mismatch.fire()
                return false
            }
            return true
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: QUICConfiguration.parameters(options))
        let connection = PeerConnection(role: .viewer, group: group, groupOptions: options,
                                        remoteAddress: QUICConfiguration.describe(endpoint),
                                        pinnedHostFingerprint: pinnedHostFingerprint, verifyQueue: verifyQueue,
                                        establishmentTimeout: establishmentTimeout)
        mismatch.target = connection
        return connection
    }

    /// Host side: wraps a group handed out by the listener's `newConnectionGroupHandler`. The handshake starts
    /// immediately (`beginHostHandshake`); callbacks are delivered only after the owner calls `start()`.
    /// `groupOptions` must be the options object the listener was created with.
    static func accepted(group: NWConnectionGroup, groupOptions: NWProtocolQUIC.Options, verifyQueue: DispatchQueue,
                         establishmentTimeout: TimeInterval = defaultEstablishmentTimeout) -> PeerConnection {
        let remote = (group.descriptor as? NWMultiplexGroup)?.members.first.map(QUICConfiguration.describe) ?? "unknown"
        return PeerConnection(role: .host, group: group, groupOptions: groupOptions, remoteAddress: remote,
                              pinnedHostFingerprint: nil,
                              verifyQueue: verifyQueue, establishmentTimeout: establishmentTimeout)
    }

    // MARK: Public API

    public var state: PeerConnectionState { shared.withLock { $0.state } }
    /// SHA-256 of the peer leaf certificate, known once ready.
    public var peerFingerprint: Data? { shared.withLock { $0.peerFingerprint } }
    /// "ip:port" (IPv6 bracketed) or "hostname:port" as dialed.
    public var remoteAddress: String { shared.withLock { $0.remoteAddress } }
    /// min(usable QUIC datagram size, `WireConstants.defaultMaxDatagramSize`).
    public var maxDatagramSize: Int { shared.withLock { $0.maxDatagramSize } }

    /// Default `maxBacklogBytes`: 1 MiB ≈ 0.7 s at the 12 Mbps top of the Host's bitrate range. This is only the
    /// absolute safety cap; the Host bounds every batch in *time* (`sendDatagrams(_:maxQueuedAheadBytes:)`), which is
    /// what keeps the queue fresh at every bitrate. The previous 256 KiB was below the Host's own allowance for a
    /// duplicated native-resolution keyframe above ~6 Mbps, so it refused the P-frames behind every such keyframe.
    public static let defaultMaxBacklogBytes = 1024 * 1024

    /// Send backlog bound (absolute). Beyond it, queued video is stale at any bitrate SwiftDesk uses.
    public var maxBacklogBytes: Int {
        get { backlogLimit.load(ordering: .relaxed) }
        set { backlogLimit.store(max(0, newValue), ordering: .relaxed) }
    }

    /// Bytes handed to Network.framework whose send completion has not fired.
    public var pendingDatagramBytes: Int { pendingBytes.load(ordering: .relaxed) }

    /// Debug only (Milestone B loss testing): percentage of outgoing datagrams discarded at random before they
    /// reach the network. 0 disables it and keeps the send path free of random-number generation.
    public var simulatedDatagramLossPercent: Double {
        get { Double(bitPattern: lossPercentBits.load(ordering: .relaxed)) }
        set {
            let clamped = newValue.isFinite ? min(max(newValue, 0), 100) : 0
            lossPercentBits.store(clamped.bitPattern, ordering: .relaxed)
        }
    }

    public var stats: PeerConnectionStats {
        var s = shared.withLock { $0.stats }
        s.datagramsSent = datagramsSent.load(ordering: .relaxed)
        s.datagramsReceived = datagramsReceived.load(ordering: .relaxed)
        s.datagramBytesReceived = datagramBytesReceived.load(ordering: .relaxed)
        s.datagramBatchesDroppedBackpressure = batchesDropped.load(ordering: .relaxed)
        s.datagramsDroppedSimulated = simulatedDrops.load(ordering: .relaxed)
        return s
    }

    /// Set callbacks first. Viewer: begins connecting. Host: begins delivering callbacks for an already
    /// established connection (the current state is reported once).
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            delivering = true
            switch role {
            case .viewer:
                startGroup()
            case .host:
                armDatagramReceives()
                resumeControlIfPaused()
            }
            deliverCurrentState()
        }
    }

    /// Reliable and ordered. Messages sent before the control stream exists are queued (bounded) and flushed in order.
    /// Side-stream types (`ControlMessageType.isSideStream`) are refused: they belong on `sendSide`.
    public func sendControl(_ message: ControlMessage) {
        guard !message.type.isSideStream else {
            Log.transport.error("Refusing a side-stream message on the control stream")
            return
        }
        let frame = ControlFraming.frame(message)
        shared.withLock { s in
            guard !s.closing, !s.state.isTerminal else { return }
            if let control = s.control {
                s.stats.controlMessagesSent &+= 1
                control.send(content: frame, completion: .contentProcessed { error in
                    if let error { Log.transport.error("Control send failed: \(String(describing: error), privacy: .public)") }
                })
            } else if s.pendingControl.count < Self.maxPendingControlMessages {
                s.pendingControl.append(frame)
            } else {
                Log.transport.error("Control queue full before stream ready; dropping message")
            }
        }
    }

    /// Unreliable. Returns false (and drops the whole batch) if the send backlog exceeds `maxBacklogBytes` or the
    /// connection is not ready — the caller counts it as backpressure and should skip to the next keyframe.
    /// A batch is always admitted when nothing is pending, so a keyframe larger than the limit is never starved.
    @discardableResult
    public func sendDatagrams(_ datagrams: [Data]) -> Bool {
        sendDatagrams(datagrams, maxQueuedAheadBytes: .max)
    }

    /// As `sendDatagrams(_:)`, and also refuses the batch when more than `maxQueuedAheadBytes` are already queued
    /// ahead of it. Lets a real-time sender bound the queue in *time* (bytes at its current bitrate) per batch, which a
    /// fixed byte cap cannot do across bitrates. Nothing pending still always admits.
    @discardableResult
    public func sendDatagrams(_ datagrams: [Data], maxQueuedAheadBytes: Int) -> Bool {
        guard !datagrams.isEmpty else { return true }
        guard let flow = shared.withLock({ $0.state == .ready && !$0.closing ? $0.datagramFlow : nil }) else {
            return false
        }
        var total = 0
        for d in datagrams { total &+= d.count }
        let pending = pendingBytes.load(ordering: .relaxed)
        if pending > 0 && (pending &+ total > backlogLimit.load(ordering: .relaxed) || pending > maxQueuedAheadBytes) {
            batchesDropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        pendingBytes.wrappingAdd(total, ordering: .relaxed)

        let loss = simulatedDatagramLossPercent
        // One completion per batch: sends on a flow are processed in order, so the last datagram's completion
        // means the whole batch left the app's queue. Earlier sends use `.idempotent` (no closure allocation).
        let batchBytes = total
        let complete = NWConnection.SendCompletion.contentProcessed { [weak self] _ in
            self?.pendingBytes.wrappingSubtract(batchBytes, ordering: .relaxed)
        }
        if loss <= 0 {
            let last = datagrams.count - 1
            flow.batch {
                for i in 0..<last { flow.send(content: datagrams[i], completion: .idempotent) }
                flow.send(content: datagrams[last], completion: complete)
            }
            datagramsSent.wrappingAdd(UInt64(datagrams.count), ordering: .relaxed)
        } else {
            var keep = [Bool](repeating: true, count: datagrams.count)
            var lastKept = -1
            for i in 0..<datagrams.count {
                if Double.random(in: 0..<100) < loss { keep[i] = false } else { lastKept = i }
            }
            let dropped = keep.count - keep.lazy.filter { $0 }.count
            simulatedDrops.wrappingAdd(UInt64(dropped), ordering: .relaxed)
            guard lastKept >= 0 else {
                pendingBytes.wrappingSubtract(total, ordering: .relaxed)
                return true
            }
            flow.batch {
                for i in 0...lastKept where keep[i] {
                    flow.send(content: datagrams[i], completion: i == lastKept ? complete : .idempotent)
                }
            }
            datagramsSent.wrappingAdd(UInt64(datagrams.count - dropped), ordering: .relaxed)
        }
        return true
    }

    // MARK: Side stream (0.1.5)

    /// Viewer only: opens the side stream, a second reliable QUIC stream in the same connection for bulk payloads
    /// (clipboard data), so they never queue in front of input on the control stream. Its first bytes are the side
    /// preamble (`TransportPreamble.Kind.side`); the Host does not answer it. Call it only after both sides announced
    /// a feature that uses it: an older Host would leave the stream unread. Idempotent; no-op on the Host, which
    /// learns of the stream when its preamble arrives. `onSideStreamReady` fires once it is usable.
    public func openSideStream() {
        queue.async { [self] in
            guard role == .viewer, !terminated, state == .ready, sideStream == nil else { return }
            guard let stream = NWConnection(from: group) else {
                Log.transport.error("Could not open the side stream")
                return
            }
            sideStream = stream
            stream.stateUpdateHandler = { [weak self, weak stream] streamState in
                guard let self, let stream, !self.terminated, stream === self.sideStream else { return }
                switch streamState {
                case .ready:
                    let installed = self.shared.withLock { s -> Bool in
                        guard s.side == nil, !s.closing else { return false }
                        // The preamble must be the first bytes; sending under the lock `sendSide` takes means
                        // nothing can overtake it.
                        stream.send(content: TransportPreamble.encode(role: .viewer, kind: .side),
                                    completion: .contentProcessed { _ in })
                        s.side = stream
                        return true
                    }
                    guard installed else { return }
                    self.receiveSide(on: stream)
                    self.callbacks.withLock { $0.onSideStreamReady }?()
                case .failed(let error):
                    Log.transport.notice("Side stream failed: \(error.debugDescription, privacy: .public)")
                    self.sideStreamEnded(stream)
                default:
                    break
                }
            }
            stream.start(queue: queue)
        }
    }

    /// The side stream is open and accepts `sendSide`.
    public var isSideStreamOpen: Bool { shared.withLock { $0.side != nil } }

    /// Reliable, ordered on the side stream, independent of the control stream. Only side-stream types
    /// (`ControlMessageType.isSideStream`). Returns false (nothing sent) when the side stream is not open or the
    /// connection is closing. `completion` (transport queue) reports whether Network.framework took the bytes —
    /// callers keep at most one message in flight so a slow link never accumulates stale payloads.
    @discardableResult
    public func sendSide(_ message: ControlMessage, completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        guard message.type.isSideStream, isSideStreamOpen else { return false }
        let frame = ControlFraming.frame(message)
        return shared.withLock { s in
            guard !s.closing, s.state == .ready, let side = s.side else { return false }
            side.send(content: frame, completion: .contentProcessed { error in completion?(error == nil) })
            return true
        }
    }

    /// Host only: the session authorized this connection (operator approval, password or trusted Viewer), so a side
    /// stream may now be identified and read. Until this is called no side-stream byte past the first receive is
    /// read, and none is decoded: an unauthenticated peer cannot make the Host buffer ~19 MiB messages. Streams that
    /// arrived earlier are picked up here. Idempotent; no-op on the Viewer.
    public func allowSideStream() {
        queue.async { [self] in
            guard role == .host, !sideStreamAllowed else { return }
            sideStreamAllowed = true
            let parked = parkedStreams
            parkedStreams.removeAll()
            for (stream, data) in parked {
                guard !terminated, !callbacksSuppressed else { return }
                if identifySideStream(data, from: stream) { receiveControl(on: stream) }
            }
        }
    }

    /// Host: a data-bearing stream after the control stream. A valid side preamble makes it the side stream (once);
    /// anything else is left unread, as before 0.1.5. Before `allowSideStream()` the stream is parked instead.
    /// Returns false: `receiveControl` stops reading it.
    private func identifySideStream(_ data: Data, from stream: NWConnection) -> Bool {
        guard role == .host, sideStream == nil, delivering, state == .ready else { return false }
        guard sideStreamAllowed else {
            if parkedStreams.count < Self.maxParkedStreams { parkedStreams.append((stream, data)) }
            return false
        }
        let key = ObjectIdentifier(stream)
        var buffer = preambleBuffers[key] ?? Data()
        buffer.append(data)
        guard buffer.count >= TransportPreamble.size else {
            preambleBuffers[key] = buffer
            return true
        }
        preambleBuffers[key] = nil
        guard TransportPreamble.viewerKind(buffer.prefix(TransportPreamble.size)) == .side else {
            Log.transport.notice("Ignoring an unidentified extra stream")
            return false
        }
        sideStream = stream
        shared.withLock { $0.side = stream }
        Log.transport.notice("Side stream opened by the viewer")
        callbacks.withLock { $0.onSideStreamReady }?()
        let rest = buffer.dropFirst(TransportPreamble.size)
        if !rest.isEmpty { handleSideBytes(Data(rest)) }
        if !terminated { receiveSide(on: stream) }
        return false
    }

    private func receiveSide(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.terminated, !self.callbacksSuppressed, stream === self.sideStream else { return }
            if let data, !data.isEmpty {
                self.handleSideBytes(data)
                guard !self.terminated, !self.callbacksSuppressed else { return }
            }
            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                self.sideStreamEnded(stream)
                return
            }
            self.receiveSide(on: stream)
        }
    }

    private func handleSideBytes(_ data: Data) {
        let messages: [ControlMessage]
        do {
            messages = try sideDecoder.append(data)
        } catch {
            sideProtocolError(error as? WireError ?? .malformed("\(error)"))
            return
        }
        guard !messages.isEmpty else { return }
        if let wrong = messages.first(where: { !$0.type.isSideStream }) {
            sideProtocolError(.malformed("message type \(wrong.type.rawValue) on the side stream"))
            return
        }
        // Drop the decoder's buffer capacity (up to ~19 MiB after a large clipboard) between messages.
        if sideDecoder.bufferedByteCount == 0 {
            sideDecoder = ControlStreamDecoder(maxMessageSize: WireConstants.maxSideStreamMessageSize)
        }
        let handler = callbacks.withLock { $0.onSideMessage }
        for message in messages { handler?(message) }
    }

    private func sideProtocolError(_ error: WireError) {
        Log.transport.error("Malformed side stream; closing")
        callbacks.withLock { $0.onProtocolError }?(error)
        close(reason: .protocolError)
    }

    /// The side stream closed or failed: the session continues without it (a later `openSideStream()` may reopen).
    private func sideStreamEnded(_ stream: NWConnection) {
        guard stream === sideStream else { return }
        sideStream = nil
        sideDecoder = ControlStreamDecoder(maxMessageSize: WireConstants.maxSideStreamMessageSize)
        shared.withLock { s in if s.side === stream { s.side = nil } }
        stream.cancel()
        if !isClosing { Log.transport.notice("Side stream ended") }
    }

    /// Sends DISCONNECT (if ready and a reason is given), then cancels. Idempotent.
    public func close(reason: DisconnectReason?) {
        let snapshot = shared.withLock { s -> (wasReady: Bool, control: NWConnection?)? in
            guard !s.closing else { return nil }
            s.closing = true
            return (s.state == .ready, s.control)
        }
        guard let snapshot else { return }
        queue.async { [self] in
            callbacksSuppressed = true
            if let reason, snapshot.wasReady, let control = snapshot.control {
                shared.withLock { $0.stats.controlMessagesSent &+= 1 }
                // Give the DISCONNECT a brief chance to leave before the connection is torn down; teardown is
                // idempotent, so whichever of the two fires first wins. Strong captures on purpose: the caller may
                // drop its last reference right after close(), and deinit would cancel before the message leaves.
                control.send(content: ControlFraming.frame(.disconnect(reason)), completion: .contentProcessed { _ in
                    self.queue.asyncAfter(deadline: .now() + 0.05) { self.teardown(final: .closed) }
                })
                queue.asyncAfter(deadline: .now() + 0.3) { self.teardown(final: .closed) }
                transition(.closed)
            } else {
                teardown(final: .closed)
            }
        }
    }

    /// Test hook: writes raw bytes to the control stream, bypassing framing (used to verify that a malformed
    /// stream is detected and closed by the peer).
    func sendRawControlBytesForTesting(_ bytes: Data) {
        shared.withLock { s in s.control?.send(content: bytes, completion: .contentProcessed { _ in }) }
    }

    // MARK: Host-side entry (HostListener)

    func beginHostHandshake() {
        queue.async { [self] in startGroup() }
    }

    // MARK: Group lifecycle (transport queue)

    private func startGroup() {
        group.stateUpdateHandler = { [weak self] state in self?.groupStateChanged(state) }
        if role == .host {
            group.newConnectionHandler = { [weak self] connection in self?.incomingFlow(connection) }
        } else {
            // Required even though a viewer never accepts host-initiated streams: without a newConnectionHandler
            // the client group never leaves .setup (observed in QUICSpike).
            group.newConnectionHandler = { connection in connection.cancel() }
        }
        group.start(queue: queue)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.terminated, self.state == .connecting else { return }
            let mismatch = self.shared.withLock { $0.pinMismatch }
            self.fail(mismatch ? Self.pinMismatchMessage : "Connection timed out")
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + establishmentTimeout, execute: item)
    }

    /// `PeerConnectionState.failed` message when the Host certificate does not match `pinnedHostFingerprint`.
    public static let pinMismatchMessage = "Host identity does not match the pinned fingerprint"

    fileprivate func pinMismatchDetected() {
        shared.withLock { $0.pinMismatch = true }
        queue.async { [self] in
            guard !terminated else { return }
            Log.transport.error("Pinned host fingerprint mismatch; aborting handshake")
            fail(Self.pinMismatchMessage)
        }
    }

    private var isClosing: Bool { shared.withLock { $0.closing } }

    private func groupStateChanged(_ state: NWConnectionGroup.State) {
        guard !terminated else { return }
        switch state {
        case .ready:
            groupReady()
        case .waiting(let error):
            // Transient (observed on loopback right before .ready). The establishment timeout bounds it.
            Log.transport.debug("QUIC group waiting: \(String(describing: error), privacy: .public)")
        case .failed(let error):
            if shared.withLock({ $0.pinMismatch }) {
                fail(Self.pinMismatchMessage)
            } else if receivedDisconnect || isClosing {
                teardown(final: .closed)
            } else {
                fail("QUIC connection failed: \(error.debugDescription)")
            }
        case .cancelled:
            teardown(final: receivedDisconnect || isClosing ? .closed : .failed("Connection cancelled"))
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func groupReady() {
        guard let metadata = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
              let fingerprint = QUICConfiguration.peerFingerprint(metadata.securityProtocolMetadata) else {
            fail("Peer presented no certificate")
            return
        }
        if let pin = pinnedHostFingerprint, pin != fingerprint {
            fail(Self.pinMismatchMessage)
            return
        }
        metadata.keepAlive = .seconds(QUICConfiguration.keepAliveSeconds)
        shared.withLock { $0.peerFingerprint = fingerprint }

        if role == .viewer {
            guard let control = NWConnection(from: group) else {
                fail("Could not open control stream")
                return
            }
            controlStream = control
            control.stateUpdateHandler = { [weak self, weak control] state in
                guard let self, let control, !self.terminated else { return }
                switch state {
                case .ready:
                    guard !self.controlStreamReady else { return }
                    self.controlStreamReady = true
                    // First bytes on the stream; makes it visible to the host and asks for the host's reply.
                    control.send(content: TransportPreamble.encode(role: .viewer), completion: .contentProcessed { _ in })
                    self.receiveControl(on: control)
                case .failed(let error):
                    self.flowFailed("Control stream", error)
                default:
                    break
                }
            }
            control.start(queue: queue)
            openDatagramFlow(NWConnection(from: group, to: nil,
                                          using: QUICConfiguration.datagramFlowOptions(from: groupOptions)))
        } else {
            // Validated in QUICSpike: the host must extract its own datagram flow right away; if it waits for the
            // flow to appear in newConnectionHandler, datagrams that arrive before then are lost.
            openDatagramFlow(group.extract(connectionTo: nil,
                                           using: QUICConfiguration.datagramFlowOptions(from: groupOptions)))
        }
    }

    private func openDatagramFlow(_ flow: NWConnection?) {
        guard let flow else {
            fail("Could not open QUIC datagram flow")
            return
        }
        datagramFlowLocal = flow
        flow.stateUpdateHandler = { [weak self] state in
            guard let self, !self.terminated else { return }
            switch state {
            case .ready:
                self.datagramReady = true
                self.checkEstablished()
            case .failed(let error):
                self.flowFailed("Datagram flow", error)
            default:
                break
            }
        }
        flow.start(queue: queue)
    }

    private func flowFailed(_ what: String, _ error: NWError) {
        if isClosing || receivedDisconnect {
            teardown(final: .closed)
        } else {
            fail("\(what) failed: \(error.debugDescription)")
        }
    }

    /// Ready = TLS done + datagram flow up + control stream identified + peer preamble received.
    private func checkEstablished() {
        guard state == .connecting, datagramReady, peerPreambleReceived, let control = controlStream else { return }
        var usable = 0
        if let flow = datagramFlowLocal,
           let m = flow.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
            usable = m.usableDatagramFrameSize
        }
        let maxSize = usable > 0 ? min(usable, WireConstants.defaultMaxDatagramSize) : WireConstants.defaultMaxDatagramSize
        let flow = datagramFlowLocal
        let isHost = role == .host
        shared.withLock { s in
            s.maxDatagramSize = maxSize
            s.datagramFlow = flow
            if isHost {
                // The reply must be the first bytes the host writes; sending under the lock that sendControl
                // takes guarantees nothing can overtake it.
                control.send(content: TransportPreamble.encode(role: .host), completion: .contentProcessed { _ in })
            }
            Self.installControl(control, in: &s)
        }
        timeoutItem?.cancel()
        timeoutItem = nil
        Log.transport.notice("QUIC session ready (\(isHost ? "host" : "viewer", privacy: .public)) usableDatagram=\(usable) maxDatagram=\(maxSize)")
        transition(.ready)
        armDatagramReceives()
        flushStashedControl()
    }

    /// Publishes the control stream and flushes messages queued before it existed, in order, under the same lock
    /// `sendControl` takes, so no later message can overtake them.
    private static func installControl(_ control: NWConnection, in s: inout Shared) {
        s.control = control
        for frame in s.pendingControl {
            s.stats.controlMessagesSent &+= 1
            control.send(content: frame, completion: .contentProcessed { _ in })
        }
        s.pendingControl.removeAll()
    }

    // MARK: Host: incoming flows

    private func incomingFlow(_ connection: NWConnection) {
        guard !terminated else {
            connection.cancel()
            return
        }
        streamCandidates.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.terminated else { return }
            switch state {
            case .ready:
                self.classifyIncoming(connection)
            case .failed:
                if connection === self.controlStream, !self.isClosing, !self.receivedDisconnect {
                    self.fail("Control stream failed")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// A flow with a usable datagram size is a datagram flow the peer created implicitly (seen in QUICSpike when
    /// the host does not extract its own); anything else is a stream that may carry the viewer's preamble. The
    /// client group also surfaces one idle stream that never carries data; it is simply left unread.
    private func classifyIncoming(_ connection: NWConnection) {
        let usable = (connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata)?
            .usableDatagramFrameSize ?? 0
        if usable > 0 {
            extraDatagramFlows.append(connection)
            armDatagramReceives()
        } else {
            receiveControl(on: connection)
        }
    }

    // MARK: Receive loops (transport queue)

    private func armDatagramReceives() {
        guard delivering, !terminated, state == .ready else { return }
        for flow in [datagramFlowLocal].compactMap({ $0 }) + extraDatagramFlows
        where !armedDatagramFlows.contains(ObjectIdentifier(flow)) {
            armedDatagramFlows.insert(ObjectIdentifier(flow))
            receiveDatagram(on: flow)
        }
    }

    private func receiveDatagram(on flow: NWConnection) {
        flow.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.terminated, !self.callbacksSuppressed else { return }
            if error == nil { self.receiveDatagram(on: flow) }   // re-arm before doing any work
            if let data, !data.isEmpty {
                self.datagramsReceived.wrappingAdd(1, ordering: .relaxed)
                self.datagramBytesReceived.wrappingAdd(UInt64(data.count), ordering: .relaxed)
                if let handler = self.callbacks.withLock({ $0.onDatagram }) { handler(data) }
            }
            if let error, !self.isClosing {
                Log.transport.debug("Datagram receive ended: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func receiveControl(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.terminated, !self.callbacksSuppressed else { return }
            if let data, !data.isEmpty {
                guard self.consume(data, from: stream), !self.terminated, !self.callbacksSuppressed else { return }
            }
            let isControl = stream === self.controlStream
            if let error {
                if isControl, !self.isClosing, !self.receivedDisconnect {
                    self.fail("Control stream error: \(error.debugDescription)")
                }
                return
            }
            if isComplete && (data?.isEmpty ?? true) {
                if isControl {
                    let graceful = self.receivedDisconnect || self.isClosing
                    self.teardown(final: graceful ? .closed : .failed("Peer closed the control stream"))
                }
                return
            }
            if isControl, !self.delivering {
                self.controlPaused = true   // host before start(): leave further bytes in QUIC flow control
                return
            }
            self.receiveControl(on: stream)
        }
    }

    /// Returns false when this stream should not be read any further.
    private func consume(_ data: Data, from stream: NWConnection) -> Bool {
        if peerPreambleReceived {
            // A second data-bearing stream: the side stream (0.1.5) if it says so, otherwise ignored.
            guard stream === controlStream else { return identifySideStream(data, from: stream) }
            if delivering && state == .ready {
                handleControlBytes(data)
            } else {
                stashedControlBytes.append(data)
            }
            return true
        }
        if role == .viewer && stream !== controlStream { return false }

        let key = ObjectIdentifier(stream)
        var buffer = preambleBuffers[key] ?? Data()
        buffer.append(data)
        guard buffer.count >= TransportPreamble.size else {
            preambleBuffers[key] = buffer
            return true
        }
        preambleBuffers.removeAll()
        do {
            try TransportPreamble.validate(buffer.prefix(TransportPreamble.size),
                                           expectedRole: role == .host ? .viewer : .host)
        } catch {
            Log.transport.error("Invalid transport preamble; closing")
            fail("Peer is not a compatible SwiftDesk endpoint")
            return false
        }
        peerPreambleReceived = true
        if role == .host { controlStream = stream }
        stashedControlBytes.append(buffer.dropFirst(TransportPreamble.size))
        checkEstablished()
        return true
    }

    private func flushStashedControl() {
        guard delivering, state == .ready, !stashedControlBytes.isEmpty else { return }
        let bytes = stashedControlBytes
        stashedControlBytes = Data()
        handleControlBytes(bytes)
    }

    private func resumeControlIfPaused() {
        flushStashedControl()
        guard controlPaused, !terminated, let control = controlStream else { return }
        controlPaused = false
        receiveControl(on: control)
    }

    private func handleControlBytes(_ data: Data) {
        let messages: [ControlMessage]
        do {
            messages = try decoder.append(data)
        } catch {
            let wireError = error as? WireError ?? .malformed("\(error)")
            Log.transport.error("Malformed control stream; closing")
            callbacks.withLock { $0.onProtocolError }?(wireError)
            close(reason: .protocolError)
            return
        }
        guard !messages.isEmpty else { return }
        if let wrong = messages.first(where: { $0.type.isSideStream }) {
            Log.transport.error("Side-stream message on the control stream; closing")
            callbacks.withLock { $0.onProtocolError }?(.malformed("message type \(wrong.type.rawValue) on the control stream"))
            close(reason: .protocolError)
            return
        }
        shared.withLock { $0.stats.controlMessagesReceived &+= UInt64(messages.count) }
        let handler = callbacks.withLock { $0.onControlMessage }
        for message in messages {
            if case .disconnect = message { receivedDisconnect = true }
            handler?(message)
        }
    }

    // MARK: State (transport queue)

    private func transition(_ new: PeerConnectionState) {
        let changed = shared.withLock { s -> Bool in
            guard s.state != new, !s.state.isTerminal else { return false }
            s.state = new
            return true
        }
        guard changed else { return }
        callbacks.withLock { $0.internalStateObserver }?(self, new)
        if started { deliver(new) }
    }

    private func deliverCurrentState() {
        deliver(state)
    }

    private func deliver(_ state: PeerConnectionState) {
        guard lastDeliveredState != state else { return }
        lastDeliveredState = state
        callbacks.withLock { $0.onStateChange }?(state)
    }

    private func fail(_ message: String) {
        teardown(final: .failed(message))
    }

    private func teardown(final: PeerConnectionState) {
        transition(final)
        guard !terminated else { return }
        terminated = true
        timeoutItem?.cancel()
        timeoutItem = nil
        shared.withLock { s in
            s.closing = true
            s.datagramFlow = nil
            s.control = nil
            s.side = nil
            s.pendingControl.removeAll()
        }
        for flow in streamCandidates + extraDatagramFlows + [controlStream, sideStream, datagramFlowLocal].compactMap({ $0 }) {
            flow.cancel()
        }
        streamCandidates.removeAll()
        extraDatagramFlows.removeAll()
        parkedStreams.removeAll()
        stashedControlBytes = Data()
        group.cancel()
        if case .failed(let reason) = final {
            Log.transport.notice("QUIC session failed: \(reason, privacy: .public)")
        }
    }
}

/// Lets the viewer's TLS verify block (created before the connection object exists) report a pin mismatch.
private final class MismatchRelay: @unchecked Sendable {
    private let target_ = Mutex<PeerConnectionWeakBox?>(nil)
    var target: PeerConnection? {
        get { target_.withLock { $0?.value } }
        set { target_.withLock { $0 = PeerConnectionWeakBox(value: newValue) } }
    }
    func fire() { target?.pinMismatchDetected() }
}

private struct PeerConnectionWeakBox: @unchecked Sendable {
    weak var value: PeerConnection?
}
