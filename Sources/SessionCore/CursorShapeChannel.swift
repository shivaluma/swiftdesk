import DiagnosticsCore
import Foundation
import WireProtocol

/// Pointer-shape sharing in the Host's active session, for the UI.
public struct CursorShapeStatus: Sendable, Equatable {
    /// The Viewer announced `PeerCapabilities.cursorShape` (false: an older SwiftDesk, or no session).
    public var peerSupports: Bool
    /// The Host's switch (`HostSession.sharesPointerShape`).
    public var enabled: Bool

    public init(peerSupports: Bool = false, enabled: Bool = false) {
        self.peerSupports = peerSupports
        self.enabled = enabled
    }

    /// The Viewer is shown this Mac's pointer shape right now.
    public var isActive: Bool { peerSupports && enabled }

    /// No session, or a session without pointer-shape support.
    public static let inactive = CursorShapeStatus()
}

/// What the Viewer is told about the Host's pointer, for its UI.
public enum RemotePointerStatus: Sendable, Equatable {
    /// Not streaming.
    case inactive
    /// The Host runs a SwiftDesk without pointer shapes: the local arrow is used.
    case unsupported
    /// The Host operator switched pointer-shape sharing off.
    case offOnHost
    /// The Host cannot read its pointer's shape (it says so with `CursorShape.unavailable`), or has not said yet.
    case unavailable
    /// The Host's shape is used (or its pointer is hidden).
    case active
}

/// One Host session's pointer-shape sharing, on the main actor (AppKit cursor reads, ≈ 30 per second, nothing per
/// video frame).
///
/// Created by the Host session at ACCEPT when the Viewer announced `PeerCapabilities.cursorShape`, stopped at teardown,
/// so the pointer is only ever read during an authorized session. While `enabled` (the operator's switch, live) it
/// samples `CursorSource` every `pollInterval` (33 ms) and sends what `CursorShapeTracker` decides: a CURSOR_SHAPE on
/// the control stream when the shape changes, preceded by a CURSOR_IMAGE on the side stream the first time a shape is
/// seen. Switched off it stops sampling and sends `CursorShape.off` once. Images are never logged.
@MainActor
final class CursorShapeChannel {
    private let source: any CursorSource
    private let transport: any ClipboardTransport
    private let pollInterval: Duration
    private let encodePNG: (CursorSnapshot) -> Data?
    private let onStatus: @MainActor (CursorShapeStatus) -> Void

    private(set) var status: CursorShapeStatus {
        didSet { if status != oldValue { onStatus(status) } }
    }
    private(set) var tracker = CursorShapeTracker()
    private var pollTask: Task<Void, Never>?
    private var started = false
    private var sideReady = false

    init(source: any CursorSource, transport: any ClipboardTransport, enabled: Bool,
         pollInterval: Duration = .milliseconds(33),
         encodePNG: @escaping (CursorSnapshot) -> Data? = CursorRendering.png,
         onStatus: @escaping @MainActor (CursorShapeStatus) -> Void) {
        self.source = source
        self.transport = transport
        self.pollInterval = pollInterval
        self.encodePNG = encodePNG
        self.onStatus = onStatus
        self.status = CursorShapeStatus(peerSupports: true, enabled: enabled)
    }

    /// Announces the current shape (or `.off`) and starts sampling if enabled.
    func start() {
        guard !started else { return }
        started = true
        onStatus(status)
        if status.enabled {
            sample()
            startPolling()
        } else {
            send(tracker.switchedOff())
        }
    }

    func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != status.enabled else { return }
        status.enabled = enabled
        guard started else { return }
        if enabled {
            tracker.forgetLastSent()
            sample()
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
            send(tracker.switchedOff())
        }
    }

    /// The side stream opened: new shapes can be defined (one waiting is sent at once).
    func sideStreamReady() {
        sideReady = true
        if started, status.enabled { sample() }
    }

    /// Reads the pointer once and sends what changed (poll tick; tests call it directly).
    func sample() {
        guard started, status.enabled else { return }
        let observation = source.observe()
        let transport = self.transport
        let define: ((CursorImage) -> Bool)? = sideReady ? { image in
            transport.sendSide(.cursorImage(image), completion: nil)
        } : nil
        send(tracker.observe(observation, encodePNG: encodePNG, define: define))
    }

    // MARK: Private

    private func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }

    private func send(_ shape: CursorShape?) {
        guard let shape else { return }
        transport.sendControl(.cursorShape(shape))
    }
}
