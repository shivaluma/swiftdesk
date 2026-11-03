import DiagnosticsCore
import Foundation
import Synchronization
import TransportCore
import WireProtocol

// Dropout resilience (0.1.4, deliberate addition; docs/PRD_COMPLIANCE.md §13). The measured Wi-Fi of the product
// owner delivers nothing at all for 3–10 s at a time. The pieces here keep a session through that and recover when
// it does end, as pure value types so every rule is unit-testable without sockets or clocks:
// - `LinkActivity` + `LinkSilenceDetector`: "nothing received for 1 s". Host: release held keys/buttons (never end the
//   session for it). Viewer: dim the last frame with a "Poor connection" badge. Both peers send PING every 500 ms, so
//   a healthy link is never silent for 1 s even on a static screen with no video.
// - `ReconnectBackoff`: the Viewer's retry schedule after a connection really failed.
// - `ReconnectGrace`: the Host's rule for letting that Viewer back in without a new prompt.

/// When the peer was last heard from (any control message or datagram), as one atomic: written on the transport
/// queue for every receive, read by a timer. No lock, no allocation.
final class LinkActivity: Sendable {
    private let lastHeard: Atomic<UInt64>

    init(nowNanos: UInt64 = MonotonicClock.nowNanos()) {
        lastHeard = Atomic(nowNanos)
    }

    func noteReceived(nowNanos: UInt64 = MonotonicClock.nowNanos()) {
        lastHeard.store(nowNanos, ordering: .relaxed)
    }

    var lastHeardNanos: UInt64 { lastHeard.load(ordering: .relaxed) }
}

/// Edge detector for "nothing received for `thresholdNanos`". Reports each transition once: `.silent` when the gap
/// first reaches the threshold, `.resumed` when traffic is seen again.
public struct LinkSilenceDetector: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case silent
        case resumed
    }

    public let thresholdNanos: UInt64
    public private(set) var isSilent = false

    public init(thresholdNanos: UInt64 = 1_000_000_000) {
        self.thresholdNanos = thresholdNanos
    }

    /// Call periodically (every 100–250 ms) with the time of the last receive.
    public mutating func update(lastHeardNanos: UInt64, nowNanos: UInt64) -> Change? {
        let gap = nowNanos >= lastHeardNanos ? nowNanos - lastHeardNanos : 0
        let silentNow = gap >= thresholdNanos
        guard silentNow != isSilent else { return nil }
        isSilent = silentNow
        return silentNow ? .silent : .resumed
    }
}

/// The Viewer's retry schedule after a session's connection failed: waits of 0.5, 1, 2, 4, 8, 8, … s before each
/// attempt (doubling, capped at `maxDelay`), and no new attempt once `budget` (60 s) has passed since the drop.
/// Pure: the caller supplies elapsed time.
public struct ReconnectBackoff: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        public var initialDelay: Duration = .milliseconds(500)
        public var maxDelay: Duration = .seconds(8)
        /// No attempt starts later than this after the connection dropped.
        public var budget: Duration = .seconds(60)

        public init() {}
    }

    public let configuration: Configuration
    /// Attempts handed out so far.
    public private(set) var attempts = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Wait before the next attempt, or nil when the budget is spent (give up). `elapsed` is the time since the
    /// connection dropped. The last wait is shortened so that no attempt starts after the budget.
    public mutating func nextDelay(elapsed: Duration) -> Duration? {
        guard elapsed < configuration.budget else { return nil }
        var delay = configuration.initialDelay
        for _ in 0..<min(attempts, 30) where delay < configuration.maxDelay { delay *= 2 }
        delay = min(delay, configuration.maxDelay)
        delay = min(delay, configuration.budget - elapsed)
        attempts += 1
        return delay
    }

    /// The full schedule from a drop at elapsed 0, assuming each attempt fails instantly (docs and tests).
    public static func schedule(_ configuration: Configuration = Configuration()) -> [Duration] {
        var backoff = ReconnectBackoff(configuration: configuration)
        var elapsed: Duration = .zero
        var delays: [Duration] = []
        while let delay = backoff.nextDelay(elapsed: elapsed) {
            delays.append(delay)
            elapsed += delay
            if delay == .zero { break }
        }
        return delays
    }
}

/// Which endings of a Viewer connection are worth retrying automatically.
public enum ReconnectPolicy {
    /// A transport failure is retried, except a certificate that no longer matches the Host the session was talking
    /// to (possible impersonation: never retried, never re-pinned).
    public static func shouldRetry(after state: PeerConnectionState) -> Bool {
        switch state {
        case .failed(let reason): reason != PeerConnection.pinMismatchMessage
        case .closed: true
        case .connecting, .ready: false
        }
    }

    /// DENY(busy) means the Host still holds the dead session (an older Host, or reconnect without a prompt switched
    /// off) until its own idle timeout ends it, so it is retried. Every other DENY is the Host's decision.
    public static func shouldRetry(after deny: DenyReason) -> Bool {
        deny == .busy
    }
}

/// The Host's rule for skipping the Allow prompt when a Viewer comes back after its connection dropped.
///
/// A Viewer may resume without a prompt only if all of these hold:
/// - the Host's setting allows it (`HostSession.allowsReconnectWithoutPrompt`, on by default);
/// - it presents the same device identity (certificate fingerprint, proven by mutual TLS and bound by AUTH) as a
///   session the operator allowed or that started with the access password (or as a session started that way);
/// - that session ended by losing its connection — not because the Viewer disconnected, the operator pressed Stop
///   Sharing or stopped listening, or capture/permissions ended it — at most `window` (2 min) ago, or it is still
///   the active session (the Host has not noticed the drop yet: the Viewer's new connection replaces it);
/// - nothing revoked it since: an operator Deny, Stop Sharing, Stop Listening, switching the setting off, and for a
///   password session switching password access off or changing the password;
/// - the Viewer announced `PeerCapabilities.sessionResume` (an older Viewer is always prompted).
///
/// Only one entry exists (one session at a time); resuming consumes it.
public struct ReconnectGrace: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var fingerprint: Data
        public var peerName: String
        public var viaPassword: Bool
        /// When the original session started (a resumed session keeps it).
        public var sessionStartedAt: Date
        public var droppedAtNanos: UInt64

        public init(fingerprint: Data, peerName: String, viaPassword: Bool, sessionStartedAt: Date,
                    droppedAtNanos: UInt64) {
            self.fingerprint = fingerprint
            self.peerName = peerName
            self.viaPassword = viaPassword
            self.sessionStartedAt = sessionStartedAt
            self.droppedAtNanos = droppedAtNanos
        }
    }

    public let windowNanos: UInt64
    public private(set) var entry: Entry?

    public init(window: Duration = .seconds(120)) {
        let parts = window.components
        let nanos = Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9
        windowNanos = nanos <= 0 ? 0 : UInt64(min(nanos, Double(UInt64.max / 2)))
    }

    /// An allowed session lost its connection: its Viewer may come back within the window.
    public mutating func sessionDropped(_ entry: Entry) {
        guard !entry.fingerprint.isEmpty, windowNanos > 0 else { return }
        self.entry = entry
    }

    /// Stop Sharing, Stop Listening, an operator Deny, the setting switched off, … Nothing resumes afterwards.
    public mutating func revoke() {
        entry = nil
    }

    /// The live entry, or nil once the window has passed (forgets it then).
    public mutating func current(nowNanos: UInt64) -> Entry? {
        guard let entry else { return nil }
        let age = nowNanos >= entry.droppedAtNanos ? nowNanos - entry.droppedAtNanos : 0
        guard age <= windowNanos else {
            self.entry = nil
            return nil
        }
        return entry
    }

    /// Whether a Viewer with this identity and capabilities may resume now (does not consume the entry).
    /// - Parameter passwordAccessEnabled: for an entry from a password session, password access must still be on.
    public mutating func allowsResume(fingerprint: Data, capabilities: PeerCapabilities, enabled: Bool,
                                      passwordAccessEnabled: Bool, nowNanos: UInt64) -> Bool {
        guard enabled, capabilities.contains(.sessionResume), !fingerprint.isEmpty,
              let entry = current(nowNanos: nowNanos), entry.fingerprint == fingerprint else { return false }
        return !entry.viaPassword || passwordAccessEnabled
    }

    /// Resumed: the entry is used up (a later drop of the resumed session opens a new one).
    public mutating func consume() -> Entry? {
        defer { entry = nil }
        return entry
    }
}
