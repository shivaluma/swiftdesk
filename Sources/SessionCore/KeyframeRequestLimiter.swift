/// Host-side policy for honoring the Viewer's REQUEST_KEYFRAME messages.
///
/// A keyframe is 10–30× the size of a P-frame, so answering every request under loss would add exactly the
/// congestion that caused the loss. Two rules keep it bounded:
/// - at most one honored request per `minIntervalNanos` (100 ms by default);
/// - a request that arrives within `suppressAfterKeyframeNanos` of a keyframe we already sent is ignored, because
///   the Viewer most likely asked before that keyframe reached it. If that keyframe was lost too, the Viewer's
///   `RecoveryGate` re-requests after its own interval, which then falls outside the window.
///
/// Pure value type (no clock reads) so it is unit-testable; the owner confines it to one lock or queue.
public struct KeyframeRequestLimiter: Sendable, Equatable {
    public let minIntervalNanos: UInt64
    public var suppressAfterKeyframeNanos: UInt64

    public private(set) var lastHonoredAtNanos: UInt64?
    public private(set) var lastKeyframeSentAtNanos: UInt64?
    public private(set) var honored: UInt64 = 0
    public private(set) var ignored: UInt64 = 0

    public init(minIntervalNanos: UInt64 = 100_000_000, suppressAfterKeyframeNanos: UInt64 = 100_000_000) {
        self.minIntervalNanos = minIntervalNanos
        self.suppressAfterKeyframeNanos = suppressAfterKeyframeNanos
    }

    /// True if the encoder should be asked for a keyframe now.
    public mutating func shouldHonor(nowNanos: UInt64) -> Bool {
        if let last = lastHonoredAtNanos, Self.elapsed(last, nowNanos) < minIntervalNanos {
            ignored &+= 1
            return false
        }
        if let sent = lastKeyframeSentAtNanos, Self.elapsed(sent, nowNanos) < suppressAfterKeyframeNanos {
            ignored &+= 1
            return false
        }
        lastHonoredAtNanos = nowNanos
        honored &+= 1
        return true
    }

    /// Records that a keyframe actually left the host (any cause: request, reconfigure, backpressure recovery).
    public mutating func keyframeSent(atNanos nowNanos: UInt64) {
        lastKeyframeSentAtNanos = nowNanos
    }

    private static func elapsed(_ start: UInt64, _ now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }
}

/// Values carried in `REQUEST_KEYFRAME(reason:)`. Diagnostics only; the Host treats every reason the same.
public enum KeyframeRequestReason: UInt8, Sendable, CaseIterable {
    case unspecified = 0
    /// Reassembly reported lost frames (gap or expiry).
    case frameLoss = 1
    /// The decoder rejected or failed a frame.
    case decodeError = 2
    /// Still waiting for a keyframe after an earlier request (or none arrived after session start).
    case stillWaiting = 3
}
