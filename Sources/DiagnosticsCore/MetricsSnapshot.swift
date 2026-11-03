/// Point-in-time diagnostics shown in the UI toolbar / diagnostics panel (PRD goal 6, persona "Troubleshooter").
/// Produced off the hot path (≈2 Hz) and handed to the main actor.
public struct MetricsSnapshot: Sendable, Equatable {
    public var rtt: RTTEstimator.Value = .none
    /// Frames per second actually delivered (host: encoded+sent; viewer: presented).
    public var fps: Double = 0
    /// Frames per second received complete from the network (viewer only).
    public var receivedFPS: Double = 0
    public var bitrateKbps: Double = 0
    public var targetBitrateKbps: Double = 0
    /// Percent of video packets lost (viewer-observed, or viewer-reported on the host).
    public var packetLossPercent: Double = 0
    public var framesLost: UInt64 = 0
    public var framesDroppedBackpressure: UInt64 = 0
    /// Viewer: frames decoded but replaced by a newer one before they were displayed.
    public var framesReplacedBeforeDisplay: UInt64 = 0
    public var keyframeRequests: UInt64 = 0

    public var captureToEncodeDone: RollingStats.Summary = .empty   // host
    public var hostPipeline: RollingStats.Summary = .empty          // host capture -> datagrams enqueued
    public var networkToDecodeDone: RollingStats.Summary = .empty   // viewer first packet -> decoded
    public var decodeToPresent: RollingStats.Summary = .empty       // viewer decoded -> presented on glass

    public var width: Int = 0
    public var height: Int = 0
    public var configuredFPS: Int = 0
    public var hardwareEncoder: Bool? = nil
    public var lowLatencyRateControl: Bool? = nil
    /// Human-readable path, e.g. "LAN", "Tailscale (direct)", "Tailscale (relay: fra)".
    public var pathDescription: String = ""
    public var sendBacklogBytes: Int = 0

    // Diagnostics only (NetBench, troubleshooting); nothing in the pipeline reads these back.
    /// Host: congestion signals that fired in the latest adaptation tick, e.g. "loss,backlog"; empty if none.
    public var adaptationSignals: String = ""
    /// Host: datagram batches (whole frames) the transport refused because of its send backlog bound.
    public var sendBatchesRefused: UInt64 = 0
    /// Host: frames the encoder refused under its one-in-flight rule.
    public var encoderBackpressureDrops: UInt64 = 0
    /// Keyframes sent (host) or received complete (viewer).
    public var keyframes: UInt64 = 0
    /// Host: FEC group size K in use; 0 = no parity.
    public var fecGroupSize: Int = 0
    /// Viewer: data fragments rebuilt from FEC parity.
    public var fragmentsRecovered: UInt64 = 0

    public init() {}
}
