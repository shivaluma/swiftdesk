import Foundation
@preconcurrency import Network
import Synchronization
import DiagnosticsCore
import WireProtocol

public enum ListenerState: Sendable, Equatable {
    case starting
    case ready(port: UInt16)
    case failed(String)
    case stopped
}

/// Host-side QUIC listener.
///
/// Security ordering: the per-IP rate limiter runs when the connection group is offered — before the TLS
/// handshake is started, so a flood costs no crypto — and a `PeerConnection` is handed to the session layer only
/// after mutual TLS completed (client certificate present, fingerprint known) and its datagram flow is up. The
/// session layer then shows the fingerprint for consent; nothing here grants control.
///
/// Threading: Network.framework callbacks run on a private serial queue; the pending-connection set and limiter
/// are confined to it. `start`/`stop` may be called from any thread.
public final class HostListener: @unchecked Sendable {
    private let requestedPort: UInt16
    private let identity: DeviceIdentity
    private let deviceName: String
    private let advertiseBonjour: Bool
    private let queue = DispatchQueue(label: "com.swiftdesk.transport.listener", qos: .userInitiated)
    private let verifyQueue = DispatchQueue(label: "com.swiftdesk.transport.listener.verify")

    private struct Callbacks {
        var onStateChange: (@Sendable (ListenerState) -> Void)?
        var onIncoming: (@Sendable (PeerConnection) -> Void)?
    }
    private let callbacks = Mutex(Callbacks())
    private let currentState = Mutex<ListenerState>(.stopped)

    public var onStateChange: (@Sendable (ListenerState) -> Void)? {
        get { callbacks.withLock { $0.onStateChange } }
        set { callbacks.withLock { $0.onStateChange = newValue } }
    }
    /// Called once the QUIC/TLS handshake is complete (peerFingerprint known) and the rate limiter allowed it.
    /// The connection is established but silent: set its callbacks, then call `start()` on it.
    public var onIncoming: (@Sendable (PeerConnection) -> Void)? {
        get { callbacks.withLock { $0.onIncoming } }
        set { callbacks.withLock { $0.onIncoming = newValue } }
    }

    public var state: ListenerState { currentState.withLock { $0 } }

    // Queue-confined.
    private var listener: NWListener?
    /// Options object `listener` was created with; every accepted group derives its datagram flow from it.
    private var listenerOptions: NWProtocolQUIC.Options?
    private var limiter: ConnectionRateLimiter
    private var pending: [ObjectIdentifier: PeerConnection] = [:]
    private var rejectedByRateLimit: UInt64 = 0

    public convenience init(port: UInt16 = WireConstants.defaultPort, identity: DeviceIdentity, deviceName: String,
                            advertiseBonjour: Bool = true) {
        self.init(port: port, identity: identity, deviceName: deviceName, advertiseBonjour: advertiseBonjour,
                  rateLimiter: ConnectionRateLimiter())
    }

    /// Same as the public initializer with a custom limiter (tests, or a stricter policy).
    public init(port: UInt16, identity: DeviceIdentity, deviceName: String, advertiseBonjour: Bool,
                rateLimiter: ConnectionRateLimiter) {
        self.requestedPort = port
        self.identity = identity
        self.deviceName = deviceName
        self.advertiseBonjour = advertiseBonjour
        self.limiter = rateLimiter
    }

    deinit {
        listener?.cancel()
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            publish(.starting)
            let options = QUICConfiguration.groupOptions(identity: identity, role: .host, verifyQueue: verifyQueue) { fingerprint in
                // Accept any well-formed client certificate at the TLS layer; the fingerprint is read back from the
                // connection metadata and approved (or not) by the operator, then bound by AUTH in the session.
                fingerprint != nil
            }
            let parameters = QUICConfiguration.parameters(options)
            listenerOptions = options
            let nwListener: NWListener
            do {
                nwListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
            } catch {
                publish(.failed("Could not create listener: \(error)"))
                return
            }
            if advertiseBonjour {
                nwListener.service = NWListener.Service(name: deviceName, type: WireConstants.bonjourServiceType)
            }
            nwListener.stateUpdateHandler = { [weak self, weak nwListener] state in
                guard let self, let nwListener else { return }
                self.listenerStateChanged(nwListener, state)
            }
            // Only the group handler: setting newConnectionHandler as well makes a QUIC listener fail with EINVAL
            // (observed in QUICSpike on macOS 27).
            nwListener.newConnectionGroupHandler = { [weak self] group in self?.offered(group) }
            listener = nwListener
            nwListener.start(queue: queue)
        }
    }

    /// Stops listening and aborts connections still in their handshake. Connections already handed out via
    /// `onIncoming` belong to the session layer and are not touched.
    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for connection in pending.values { connection.close(reason: nil) }
            pending.removeAll()
            publish(.stopped)
        }
    }

    // MARK: Queue-confined

    private func listenerStateChanged(_ nwListener: NWListener, _ state: NWListener.State) {
        guard nwListener === listener else { return }
        switch state {
        case .ready:
            let port = nwListener.port?.rawValue ?? requestedPort
            Log.transport.notice("Listening on UDP port \(port) (QUIC)")
            publish(.ready(port: port))
        case .failed(let error):
            Log.transport.error("Listener failed: \(String(describing: error), privacy: .public)")
            nwListener.cancel()
            listener = nil
            publish(.failed(error.debugDescription))
        case .waiting(let error):
            Log.transport.notice("Listener waiting: \(String(describing: error), privacy: .public)")
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func offered(_ group: NWConnectionGroup) {
        let remote = (group.descriptor as? NWMultiplexGroup)?.members.first
        let address = remote.flatMap(QUICConfiguration.hostString) ?? "unknown"
        guard limiter.allow(address: address, nowNanos: MonotonicClock.nowNanos()) else {
            rejectedByRateLimit &+= 1
            Log.transport.notice("Rate-limited connection attempt")
            group.cancel()
            return
        }
        guard let options = listenerOptions else {
            group.cancel()
            return
        }
        let connection = PeerConnection.accepted(group: group, groupOptions: options, verifyQueue: verifyQueue)
        let key = ObjectIdentifier(connection)
        pending[key] = connection
        connection.internalStateObserver = { [weak self] connection, state in
            guard let self else { return }
            self.queue.async { self.pendingStateChanged(connection, state) }
        }
        connection.beginHostHandshake()
    }

    private func pendingStateChanged(_ connection: PeerConnection, _ state: PeerConnectionState) {
        let key = ObjectIdentifier(connection)
        guard pending[key] != nil else { return }
        switch state {
        case .connecting:
            return
        case .ready:
            pending[key] = nil
            connection.internalStateObserver = nil
            guard listener != nil, let handler = callbacks.withLock({ $0.onIncoming }) else {
                connection.close(reason: .hostStopped)
                return
            }
            handler(connection)
        case .failed, .closed:
            pending[key] = nil
            connection.internalStateObserver = nil
        }
    }

    private func publish(_ state: ListenerState) {
        let changed = currentState.withLock { s -> Bool in
            guard s != state else { return false }
            s = state
            return true
        }
        if changed { callbacks.withLock { $0.onStateChange }?(state) }
    }
}
