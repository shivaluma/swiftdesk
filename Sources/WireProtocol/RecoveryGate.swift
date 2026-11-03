import Foundation

/// Decoder-side recovery: after loss, drop non-keyframes until a keyframe arrives; rate-limit keyframe requests.
///
/// Decoding P-frames whose references were lost produces corrupted video (smearing) for the rest of the GOP, and
/// in low-latency rate-control mode the GOP may be effectively infinite. So after any loss the Viewer stops
/// decoding and asks for a keyframe. Requests are rate-limited (a keyframe is large; asking repeatedly under
/// loss only adds congestion) and re-sent if no keyframe shows up, since the request or the keyframe itself
/// may be lost.
///
/// Timing: a loss is requested immediately unless a request went out less than `minRequestInterval` ago, in
/// which case `tick` sends it once the interval has passed. While still awaiting after a request, `tick`
/// re-requests every `rerequestAfter`. In the initial state (session start) no loss has happened yet: the Host
/// sends a keyframe first, so `tick` only asks after a grace period of `rerequestAfter` from its first call.
///
/// Dropouts (0.1.4): REQUEST_KEYFRAME travels on the reliable control stream, so while the link is dead every
/// re-request just queues behind the previous one and all of them arrive together when it comes back — one keyframe
/// per request in the worst case. With `maxSilentRerequestIntervalNanos` set, the owner reports received datagrams
/// with `noteTraffic()`, and while nothing arrives the re-request interval doubles (1 s, 2 s, then the 4 s cap)
/// instead of staying at 500 ms: a 10 s outage queues 4 requests instead of 20. The first datagram after the outage
/// restores the normal interval, so recovery asks once, right away. nil (the default) keeps the plain fixed interval.
public struct RecoveryGate: Sendable {
    public let minRequestIntervalNanos: UInt64
    public let rerequestAfterNanos: UInt64
    /// Cap of the doubling re-request interval while no traffic arrives; nil disables the back-off.
    public let maxSilentRerequestIntervalNanos: UInt64?

    /// Initially true (need the first keyframe).
    public private(set) var awaitingKeyframe: Bool = true
    /// Viewer-clock time of the last request this gate asked for, if any.
    public private(set) var lastRequestAtNanos: UInt64?

    private var requestedThisEpisode = false
    private var isInitialEpisode = true
    private var episodeStartNanos: UInt64?
    /// Something arrived since the last request (only tracked with the silent back-off).
    private var trafficSinceRequest = true
    /// Consecutive re-requests with no traffic in between.
    private var silentRerequests = 0

    public init(minRequestIntervalNanos: UInt64 = 200_000_000, rerequestAfterNanos: UInt64 = 500_000_000,
                maxSilentRerequestIntervalNanos: UInt64? = nil) {
        self.minRequestIntervalNanos = minRequestIntervalNanos
        self.rerequestAfterNanos = rerequestAfterNanos
        self.maxSilentRerequestIntervalNanos = maxSilentRerequestIntervalNanos
    }

    /// Datagrams arrived (call at most once per receive batch). Only matters with the silent back-off.
    public mutating func noteTraffic() {
        trafficSinceRequest = true
        silentRerequests = 0
    }

    /// The interval `tick` waits after the last request before asking again.
    public var currentRerequestIntervalNanos: UInt64 {
        guard let cap = maxSilentRerequestIntervalNanos, !trafficSinceRequest else { return rerequestAfterNanos }
        let shift = UInt64(min(silentRerequests + 1, 16))
        let doubled = rerequestAfterNanos.multipliedReportingOverflow(by: 1 << shift)
        return doubled.overflow ? max(cap, rerequestAfterNanos) : max(min(doubled.partialValue, cap), rerequestAfterNanos)
    }

    /// Returns true if a REQUEST_KEYFRAME should be sent now.
    public mutating func onLoss(nowNanos: UInt64) -> Bool {
        beginEpisode(now: nowNanos)
        return requestIfAllowed(now: nowNanos)
    }

    /// Same policy as a loss: the decoder state is unusable until the next keyframe.
    public mutating func onDecodeError(nowNanos: UInt64) -> Bool {
        onLoss(nowNanos: nowNanos)
    }

    /// False => drop the frame without decoding. A keyframe always passes and clears the awaiting state.
    public mutating func admit(flags: VideoFlags) -> Bool {
        if flags.contains(.keyframe) {
            awaitingKeyframe = false
            requestedThisEpisode = false
            isInitialEpisode = false
            episodeStartNanos = nil
            return true
        }
        return !awaitingKeyframe
    }

    /// True => send (or re-send) REQUEST_KEYFRAME now. Call periodically (e.g. with `FrameReassembler.expire`).
    public mutating func tick(nowNanos: UInt64) -> Bool {
        guard awaitingKeyframe else { return false }
        if requestedThisEpisode {
            guard let last = lastRequestAtNanos, elapsed(since: last, now: nowNanos) >= currentRerequestIntervalNanos else {
                return false
            }
            if maxSilentRerequestIntervalNanos != nil {
                if !trafficSinceRequest { silentRerequests += 1 }
                trafficSinceRequest = false
            }
            lastRequestAtNanos = nowNanos
            return true
        }
        if isInitialEpisode {
            guard let start = episodeStartNanos else {
                episodeStartNanos = nowNanos
                return false
            }
            guard elapsed(since: start, now: nowNanos) >= rerequestAfterNanos else { return false }
        }
        return requestIfAllowed(now: nowNanos)
    }

    private mutating func beginEpisode(now: UInt64) {
        if !awaitingKeyframe {
            awaitingKeyframe = true
            requestedThisEpisode = false
            episodeStartNanos = now
        }
        isInitialEpisode = false
    }

    private mutating func requestIfAllowed(now: UInt64) -> Bool {
        if let last = lastRequestAtNanos, elapsed(since: last, now: now) < minRequestIntervalNanos {
            return false
        }
        lastRequestAtNanos = now
        requestedThisEpisode = true
        if maxSilentRerequestIntervalNanos != nil { trafficSinceRequest = false }
        return true
    }

    private func elapsed(since start: UInt64, now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }
}
