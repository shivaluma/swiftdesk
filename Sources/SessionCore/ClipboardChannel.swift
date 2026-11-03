import DiagnosticsCore
import Foundation
import TransportCore
import WireProtocol

/// Clipboard sharing state of the current session, for the UI.
public struct ClipboardSyncStatus: Sendable, Equatable {
    /// The peer announced `PeerCapabilities.clipboard` (false: it is an older SwiftDesk, or no session).
    public var peerSupports: Bool
    /// The peer's switch, from its CLIPBOARD_STATE.
    public var peerEnabled: Bool
    /// This side's switch.
    public var localEnabled: Bool
    /// macOS refused the latest read of this Mac's clipboard (Paste from Other Apps set to Deny, or "Don't Allow").
    public var accessDenied: Bool
    /// The latest thing worth a small note (too large, files, access denied); nil when there is nothing to say.
    public var notice: ClipboardNotice?
    /// The latest successful transfer in either direction.
    public var lastTransfer: ClipboardTransfer?

    public init(peerSupports: Bool = false, peerEnabled: Bool = false, localEnabled: Bool = false,
                accessDenied: Bool = false, notice: ClipboardNotice? = nil, lastTransfer: ClipboardTransfer? = nil) {
        self.peerSupports = peerSupports
        self.peerEnabled = peerEnabled
        self.localEnabled = localEnabled
        self.accessDenied = accessDenied
        self.notice = notice
        self.lastTransfer = lastTransfer
    }

    /// Clipboards are synced right now (both sides support it and have it switched on).
    public var isActive: Bool { peerSupports && peerEnabled && localEnabled }

    /// No session, or a session without clipboard support.
    public static let inactive = ClipboardSyncStatus()
}

public struct ClipboardNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Copied content was not shared: over the size limit.
        case tooLarge(bytes: Int, limit: Int)
        /// Copied files are not shared (only text, rich text, images and URLs).
        case filesNotShared
        /// macOS did not let SwiftDesk read this Mac's clipboard.
        case accessDenied
    }

    public let id: UUID
    public var kind: Kind
    public var at: Date

    public init(id: UUID = UUID(), kind: Kind, at: Date = Date()) {
        self.id = id
        self.kind = kind
        self.at = at
    }
}

public struct ClipboardTransfer: Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case sent, received }
    public var direction: Direction
    public var kinds: [ClipboardContent.Kind]
    public var bytes: Int
    public var at: Date

    public init(direction: Direction, kinds: [ClipboardContent.Kind], bytes: Int, at: Date = Date()) {
        self.direction = direction
        self.kinds = kinds
        self.bytes = bytes
        self.at = at
    }
}

/// What `ClipboardChannel` needs from the connection: CLIPBOARD_STATE on the control stream, CLIPBOARD on the side
/// stream. `PeerConnection` conforms.
public protocol ClipboardTransport: AnyObject, Sendable {
    func sendControl(_ message: ControlMessage)
    @discardableResult func sendSide(_ message: ControlMessage, completion: (@Sendable (Bool) -> Void)?) -> Bool
}

extension PeerConnection: ClipboardTransport {}

/// One session's clipboard sync, on the main actor (pasteboard access and rare events only; nothing per frame).
///
/// Created by the session once both sides announced `PeerCapabilities.clipboard` and the session is authorized
/// (Host: at ACCEPT; Viewer: when ACCEPT arrives), stopped at session end. Rules:
/// - data flows only while both switches are on (this side's setting, the peer's CLIPBOARD_STATE); a CLIPBOARD
///   received while this side is off is dropped unread;
/// - the local pasteboard's `changeCount` is polled (`pollInterval`, ≈ 4 Hz; cheap and prompt-free) and its contents
///   are read only when it changed, sharing is active and `canReadLocal()` allows it (the Viewer: its stream window
///   is key). The read happens on the main actor; TIFF → PNG conversion off it;
/// - concealed / transient / auto-generated content, copied files and SwiftDesk's own writes are never sent
///   (`ClipboardPolicy.screen`, `ClipboardEchoGuard`); oversized content is skipped with a notice;
/// - at most one CLIPBOARD in flight on the side stream; a newer copy replaces one still waiting (latest wins). A
///   copy received from the peer is newer than any local copy not sent yet: it drops a waiting one and one still
///   being converted (`receivedEpoch`), so a stale local copy never overwrites the peer's newer clipboard;
/// - contents read after the screening are discarded if `changeCount` moved meanwhile (a password manager's concealed
///   copy in between must not be sent on the strength of the previous item's types); the next check screens it;
/// - contents are never logged.
@MainActor
final class ClipboardChannel {
    private let pasteboard: any PasteboardAccess
    private let transport: any ClipboardTransport
    private let canReadLocal: @MainActor () -> Bool
    private let onStatus: @MainActor (ClipboardSyncStatus) -> Void
    private let pollInterval: Duration
    private let baselineAtStart: Bool

    private(set) var status: ClipboardSyncStatus {
        didSet { if status != oldValue { onStatus(status) } }
    }
    private var echo: ClipboardEchoGuard
    private var pollTask: Task<Void, Never>?
    private var started = false
    private var generation: UInt64 = 0
    /// Bumped by every CLIPBOARD written here: a local read started before it is stale and is dropped.
    private var receivedEpoch: UInt64 = 0
    private var reading = false
    private var sideReady = false
    private var inFlight = false
    private var pending: ClipboardContent?

    /// - Parameters:
    ///   - baselineAtStart: true (Host): the clipboard as it is now is not new; false (Viewer): it is sent on the
    ///     first check that may read it.
    init(pasteboard: any PasteboardAccess, transport: any ClipboardTransport, localEnabled: Bool,
         baselineAtStart: Bool, pollInterval: Duration = .milliseconds(250),
         canReadLocal: @escaping @MainActor () -> Bool = { true },
         onStatus: @escaping @MainActor (ClipboardSyncStatus) -> Void) {
        self.pasteboard = pasteboard
        self.transport = transport
        self.canReadLocal = canReadLocal
        self.onStatus = onStatus
        self.pollInterval = pollInterval
        self.baselineAtStart = baselineAtStart
        self.echo = ClipboardEchoGuard(baseline: baselineAtStart ? pasteboard.changeCount : nil)
        self.status = ClipboardSyncStatus(peerSupports: true, localEnabled: localEnabled)
    }

    /// Announces this side's switch and starts watching the pasteboard.
    func start() {
        guard !started else { return }
        started = true
        onStatus(status)
        transport.sendControl(.clipboardState(ClipboardState(enabled: status.localEnabled)))
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.checkLocal()
            }
        }
    }

    func stop() {
        started = false
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        pending = nil
    }

    func setLocalEnabled(_ enabled: Bool) {
        guard enabled != status.localEnabled else { return }
        status.localEnabled = enabled
        if enabled {
            // Only copies made from now on (Host), or the clipboard as it is (Viewer: about to paste remotely).
            echo.rebase(baselineAtStart ? pasteboard.changeCount : nil)
        } else {
            pending = nil
            status.notice = nil
        }
        guard started else { return }
        transport.sendControl(.clipboardState(ClipboardState(enabled: enabled)))
        if enabled { checkLocal() }
    }

    func peerStateChanged(_ state: ClipboardState) {
        status.peerEnabled = state.enabled
        if !state.enabled { pending = nil }
        if state.enabled { checkLocal() }
    }

    func sideStreamReady() {
        sideReady = true
        flush()
    }

    /// A CLIPBOARD from the peer: written to this Mac's pasteboard if sharing is on here.
    func received(_ content: ClipboardContent) {
        guard started, status.localEnabled, !content.isEmpty else { return }
        let count = pasteboard.write(ClipboardPolicy.representations(for: content))
        echo.noteWritten(changeCount: count)
        // Latest copy wins: the peer's is newer than a local one still waiting or being converted.
        pending = nil
        receivedEpoch &+= 1
        status.lastTransfer = ClipboardTransfer(direction: .received, kinds: content.kinds, bytes: content.totalBytes)
        Log.session.info("Clipboard received from the peer")
    }

    /// Looks at the local pasteboard now (poll tick, stream window became key, a switch turned on).
    func checkLocal() {
        guard started, !reading, status.isActive, canReadLocal() else { return }
        let changeCount = pasteboard.changeCount
        guard echo.shouldExamine(changeCount: changeCount) else { return }
        let types = pasteboard.types
        if let skip = ClipboardPolicy.screen(types: types) {
            if skip == .files { note(.filesNotShared) }
            return
        }
        if pasteboard.accessBehavior == .alwaysDeny {
            denied()
            return
        }
        let snapshot = ClipboardPolicy.snapshot(pasteboard, types: types)
        // Types and contents are separate cross-process reads (and a privacy prompt may sit between them): another
        // copy in between is not what was screened. Drop this one; the next check screens the new change.
        guard pasteboard.changeCount == changeCount else { return }
        guard !snapshot.isEmpty else {
            // The types promised content but nothing could be read: macOS refused (prompt answered "Don't Allow").
            denied()
            return
        }
        status.accessDenied = false
        if status.notice?.kind == .accessDenied { status.notice = nil }
        reading = true
        let generation = self.generation
        let epoch = receivedEpoch
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { ClipboardPolicy.content(from: snapshot) }.value
            guard let self, self.generation == generation else { return }
            self.reading = false
            // The peer's clipboard arrived during the conversion: it is newer than this copy.
            if self.receivedEpoch == epoch { self.readFinished(outcome) }
            // A copy made while this one was being converted is picked up now, not at the next poll.
            self.checkLocal()
        }
    }

    /// A read is being converted off the main actor (tests).
    var isReading: Bool { reading }

    // MARK: Private

    private func readFinished(_ outcome: ClipboardPolicy.ReadOutcome) {
        switch outcome {
        case .content(let content):
            guard status.isActive, content.isWellFormed else { return }
            if case .tooLarge? = status.notice?.kind { status.notice = nil }
            if case .filesNotShared? = status.notice?.kind { status.notice = nil }
            pending = content
            flush()
        case .skipped(.tooLarge(let bytes, let limit)):
            note(.tooLarge(bytes: bytes, limit: limit))
        case .skipped(.accessDenied):
            denied()
        case .skipped:
            break
        }
    }

    private func flush() {
        guard started, sideReady, !inFlight, let content = pending, status.isActive else { return }
        let generation = self.generation
        let sent = transport.sendSide(.clipboard(content)) { [weak self] _ in
            onMain { [weak self] in
                guard let self, self.generation == generation else { return }
                self.inFlight = false
                self.flush()
            }
        }
        guard sent else { return }   // side stream not open (yet): stays pending until it is
        pending = nil
        inFlight = true
        status.lastTransfer = ClipboardTransfer(direction: .sent, kinds: content.kinds, bytes: content.totalBytes)
        Log.session.info("Clipboard sent to the peer")
    }

    private func denied() {
        status.accessDenied = true
        note(.accessDenied)
        Log.session.notice("Clipboard read refused by macOS")
    }

    private func note(_ kind: ClipboardNotice.Kind) {
        status.notice = ClipboardNotice(kind: kind)
    }
}
