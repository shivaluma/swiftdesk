import ApplicationServices
import CoreGraphics
import Dispatch
import os
import Synchronization
import WireProtocol

/// Host side. Posts CGEvents only while authorized; serial queue; releases held state on revoke.
///
/// Synchronization: every piece of injection state (`engine`, `authorized`) is touched only on `queue`, a
/// dedicated `.userInteractive` serial queue, so events are applied strictly in arrival order without locks and the
/// transport queue never blocks on `CGEventPost`. The only cross-thread state is `canInject` and the counters,
/// which are `Atomic`s readable from any thread.
public final class HostInputInjector: @unchecked Sendable {
    /// Counters for diagnostics (never event contents).
    public struct Stats: Sendable, Equatable {
        public var eventsPosted: UInt64
        public var droppedUnauthorized: UInt64
        public var droppedStalePointer: UInt64
    }

    private static let log = Logger(subsystem: "com.swiftdesk.app", category: "input")

    private let queue = DispatchQueue(label: "com.swiftdesk.input.inject", qos: .userInteractive)
    private let poster: any EventPoster
    private let trustCheck: @Sendable () -> Bool

    // Queue-confined.
    private var engine: HostInjectionEngine
    private var authorized = false

    private let canInjectFlag = Atomic<Bool>(false)
    private let posted = Atomic<UInt64>(0)
    private let droppedUnauthorized = Atomic<UInt64>(0)
    private let droppedStale = Atomic<UInt64>(0)

    public convenience init(displayFrame: CGRect) {
        self.init(displayFrame: displayFrame, poster: CGEventPoster(), trustCheck: { AXIsProcessTrusted() })
    }

    init(displayFrame: CGRect, poster: any EventPoster, trustCheck: @escaping @Sendable () -> Bool) {
        self.engine = HostInjectionEngine(displayFrame: displayFrame)
        self.poster = poster
        self.trustCheck = trustCheck
    }

    /// True while the session is authorized *and* the process had Accessibility trust when it was authorized.
    /// Updated synchronously by `setAuthorized`, so callers can surface "Accessibility missing" immediately.
    public var canInject: Bool { canInjectFlag.load(ordering: .acquiring) }

    public var stats: Stats {
        Stats(eventsPosted: posted.load(ordering: .relaxed),
              droppedUnauthorized: droppedUnauthorized.load(ordering: .relaxed),
              droppedStalePointer: droppedStale.load(ordering: .relaxed))
    }

    /// `true` checks Accessibility trust once (without prompting) and enables injection only if trusted.
    /// `false` releases every held key/button first, then rejects everything.
    public func setAuthorized(_ authorized: Bool) {
        let trusted = authorized && trustCheck()
        canInjectFlag.store(trusted, ordering: .releasing)
        if authorized && !trusted {
            Self.log.error("Input injection authorized but Accessibility permission is missing; events will be ignored")
        } else {
            Self.log.info("Input injection \(trusted ? "enabled" : "disabled", privacy: .public)")
        }
        queue.async { [self] in
            if trusted {
                engine.resetSession()
            } else {
                releaseAllOnQueue()
            }
            self.authorized = trusted
        }
    }

    public func updateDisplayFrame(_ frame: CGRect) {
        queue.async { [self] in engine.displayFrame = frame }
    }

    /// Key/mouse/scroll/mouseMove messages; ignores others.
    public func handle(_ message: ControlMessage) {
        switch message {
        case .keyDown, .keyUp, .mouseDown, .mouseUp, .mouseMove, .scroll: break
        default: return
        }
        guard canInject else {
            droppedUnauthorized.add(1, ordering: .relaxed)
            return
        }
        queue.async { [self] in
            guard authorized else {
                droppedUnauthorized.add(1, ordering: .relaxed)
                return
            }
            let staleBefore = engine.stalePointerDrops
            engine.handle(message) { post($0) }
            noteStale(since: staleBefore)
        }
    }

    /// Datagram path; drops seq <= last applied.
    public func handlePointer(_ state: PointerState) {
        guard canInject else {
            droppedUnauthorized.add(1, ordering: .relaxed)
            return
        }
        queue.async { [self] in
            guard authorized else {
                droppedUnauthorized.add(1, ordering: .relaxed)
                return
            }
            let staleBefore = engine.stalePointerDrops
            engine.pointer(state) { post($0) }
            noteStale(since: staleBefore)
        }
    }

    /// Key-up for every held key and button-up for every held button. Safe to call at any time.
    public func releaseAll() {
        queue.async { [self] in releaseAllOnQueue() }
    }

    /// Blocks until every previously submitted call has been applied (tests, orderly teardown).
    func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Queue-confined

    private func releaseAllOnQueue() {
        // Only events this engine actually posted are tracked, so this is a no-op when nothing is held.
        guard !engine.heldKeys.isEmpty || !engine.heldButtons.isEmpty else { return }
        let fallback = engine.cursor == nil ? poster.cursorLocation() : nil
        engine.releaseAll(fallbackCursor: fallback) { post($0) }
    }

    private func post(_ event: PostedEvent) {
        poster.post(event)
        posted.add(1, ordering: .relaxed)
    }

    private func noteStale(since before: UInt64) {
        let delta = engine.stalePointerDrops &- before
        if delta > 0 { droppedStale.add(delta, ordering: .relaxed) }
    }
}
