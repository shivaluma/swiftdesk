import Foundation
@preconcurrency import Network
import Synchronization
import DiagnosticsCore
import WireProtocol

/// Optional LAN discovery of hosts advertising `WireConstants.bonjourServiceType` (PRD: convenience, not a
/// blocker — connecting by IP always works). Discovery reveals only the advertised device name; identity is
/// still established by the pinned fingerprint / consent flow once connected.
///
/// Threading: NWBrowser callbacks run on a private serial queue; the endpoint map is behind a `Mutex` because
/// `resolve` may be called from any task.
public final class BonjourBrowser: @unchecked Sendable {
    public struct Result: Sendable, Hashable {
        public var name: String
        public var endpointDescription: String
        public init(name: String, endpointDescription: String) {
            self.name = name
            self.endpointDescription = endpointDescription
        }
    }

    static let resolveTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.swiftdesk.transport.bonjour")
    private let serviceType: String
    /// The callback lives in a struct field rather than directly as `Mutex<Closure?>`: reading a bare optional
    /// closure out of a `Mutex` re-wraps it in a reabstraction thunk on every read (measured by CaptureCore: the
    /// chain overflows the stack after ~1M reads). A struct field does not grow.
    private struct Callbacks { var onResults: (@Sendable ([Result]) -> Void)? }
    private let callbacks = Mutex(Callbacks())
    private let endpoints = Mutex<[Result: NWEndpoint]>([:])
    private var browser: NWBrowser?      // queue-confined

    public var onResults: (@Sendable ([Result]) -> Void)? {
        get { callbacks.withLock { $0.onResults } }
        set { callbacks.withLock { $0.onResults = newValue } }
    }

    public init() {
        self.serviceType = WireConstants.bonjourServiceType
    }

    /// Browse a different service type (tests use a unique type to avoid seeing real hosts).
    public init(serviceType: String) {
        self.serviceType = serviceType
    }

    deinit { browser?.cancel() }

    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: NWParameters())
            b.browseResultsChangedHandler = { [weak self] results, _ in self?.resultsChanged(results) }
            b.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Log.transport.error("Bonjour browse failed: \(String(describing: error), privacy: .public)")
                }
            }
            browser = b
            b.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            endpoints.withLock { $0.removeAll() }
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var map: [Result: NWEndpoint] = [:]
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            map[Result(name: name, endpointDescription: "\(r.endpoint)")] = r.endpoint
        }
        endpoints.withLock { $0 = map }
        let list = map.keys.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        callbacks.withLock { $0.onResults }?(list)
    }

    /// Resolves a discovered service to an address PeerConnection can dial.
    ///
    /// Network.framework has no public "resolve only" call for a service endpoint, so this opens a throwaway
    /// UDP connection to it (no packets are sent: UDP becomes ready as soon as the name resolves) and reads the
    /// resolved `currentPath.remoteEndpoint`. IPv4 is preferred because link-local IPv6 needs a scope id.
    public func resolve(_ result: Result) async -> (host: String, port: UInt16)? {
        guard let endpoint = endpoints.withLock({ $0[result] }) else { return nil }
        if let v4 = await Self.resolve(endpoint, version: .v4) { return v4 }
        return await Self.resolve(endpoint, version: .any)
    }

    private static func resolve(_ endpoint: NWEndpoint, version: NWProtocolIP.Options.Version) async -> (host: String, port: UInt16)? {
        let parameters = NWParameters.udp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = version
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "com.swiftdesk.transport.bonjour.resolve")
        let once = Mutex(false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: (host: String, port: UInt16)?) {
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        finish((QUICConfiguration.describe(host), port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + resolveTimeout) { finish(nil) }
        }
    }
}
