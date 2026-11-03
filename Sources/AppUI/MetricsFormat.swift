import DiagnosticsCore
import Foundation

/// Pure, locale-stable formatting for the diagnostics the UI shows (PRD goal 6 and the "Troubleshooter" persona).
///
/// Numbers are rendered with a fixed `.` decimal separator and no grouping so screenshots taken for latency reports
/// read the same on every machine. An empty sample window renders as an em dash rather than `0 ms`, because "no data"
/// and "zero latency" mean very different things when diagnosing lag.
public enum MetricsFormat {
    /// Placeholder for values that have not been measured yet.
    public static let placeholder = "—"

    /// `12.3 ms` below 100 ms, `123 ms` above. Negative, NaN or infinite input renders the placeholder.
    public static func millis(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return placeholder }
        return value < 100 ? "\(fixed(value, digits: 1)) ms" : "\(fixed(value, digits: 0)) ms"
    }

    /// Smoothed RTT (falls back to the latest sample); the placeholder until the first PONG.
    public static func rtt(_ value: RTTEstimator.Value) -> String {
        guard value != .none else { return placeholder }
        let shown = value.smoothedMillis > 0 ? value.smoothedMillis : value.latestMillis
        return millis(shown)
    }

    /// Whole frames per second, one decimal below 10 fps so a stalled stream is visible as `0.4 fps`, not `0 fps`.
    public static func fps(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return placeholder }
        return value < 10 && value > 0 ? fixed(value, digits: 1) : fixed(value, digits: 0)
    }

    /// `850 kb/s` below 1 Mb/s, otherwise `2.95 Mb/s`.
    public static func bitrate(kbps: Double) -> String {
        guard kbps.isFinite, kbps >= 0 else { return placeholder }
        if kbps < 1000 { return "\(fixed(kbps, digits: 0)) kb/s" }
        return "\(fixed(kbps / 1000, digits: 2)) Mb/s"
    }

    /// `0.25 %` below 10 %, `12.5 %` above.
    public static func percent(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return placeholder }
        return value < 10 ? "\(fixed(value, digits: 2)) %" : "\(fixed(value, digits: 1)) %"
    }

    /// `1280×720`, or the placeholder before the first CONFIG.
    public static func resolution(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return placeholder }
        return "\(width)×\(height)"
    }

    /// `1280×720 @ 60 fps`.
    public static func resolution(width: Int, height: Int, fps: Int) -> String {
        let size = resolution(width: width, height: height)
        guard size != placeholder, fps > 0 else { return size }
        return "\(size) @ \(fps) fps"
    }

    /// `p50 4.1 ms · p95 7.9 ms`, or the placeholder when the window is empty.
    public static func summary(_ summary: RollingStats.Summary) -> String {
        guard summary.count > 0 else { return placeholder }
        return "p50 \(millis(summary.p50)) · p95 \(millis(summary.p95))"
    }

    /// Tri-state capability flags (`nil` = not reported yet).
    public static func flag(_ value: Bool?) -> String {
        switch value {
        case .some(true): "Yes"
        case .some(false): "No"
        case .none: placeholder
        }
    }

    /// `128 KiB`, `1.5 MiB`, `512 B`.
    public static func bytes(_ value: Int) -> String {
        guard value >= 0 else { return placeholder }
        if value < 1024 { return "\(value) B" }
        if value < 1024 * 1024 { return "\(fixed(Double(value) / 1024, digits: 0)) KiB" }
        return "\(fixed(Double(value) / (1024 * 1024), digits: 1)) MiB"
    }

    /// Plain counter without grouping separators.
    public static func count(_ value: UInt64) -> String { String(value) }

    /// Fixed-point rendering independent of the user's locale.
    static func fixed(_ value: Double, digits: Int) -> String {
        String(format: "%.\(max(0, digits))f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// One labelled line of the Diagnostics panel.
public struct DiagnosticsRow: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled group of diagnostics rows.
public struct DiagnosticsSection: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public var title: String
    public var rows: [DiagnosticsRow]
}

/// Which side produced a `MetricsSnapshot`; several fields only exist on one side.
public enum MetricsRole: Sendable, Equatable {
    case host
    case viewer
}

/// Turns a full `MetricsSnapshot` into the rows of the Diagnostics disclosure, so the panel shows every field and
/// the mapping is unit-testable without rendering SwiftUI.
public enum DiagnosticsRows {
    public static func sections(for m: MetricsSnapshot, role: MetricsRole) -> [DiagnosticsSection] {
        var network: [DiagnosticsRow] = [
            DiagnosticsRow("Path", m.pathDescription.isEmpty ? MetricsFormat.placeholder : m.pathDescription),
            DiagnosticsRow("RTT (smoothed)", MetricsFormat.rtt(m.rtt)),
            DiagnosticsRow("RTT (latest)", m.rtt == .none ? MetricsFormat.placeholder : MetricsFormat.millis(m.rtt.latestMillis)),
            DiagnosticsRow("RTT (min)", m.rtt == .none ? MetricsFormat.placeholder : MetricsFormat.millis(m.rtt.minMillis)),
            DiagnosticsRow("RTT variance", m.rtt == .none ? MetricsFormat.placeholder : MetricsFormat.millis(m.rtt.varianceMillis)),
            DiagnosticsRow("Packet loss", MetricsFormat.percent(m.packetLossPercent)),
        ]
        if role == .host {
            network.append(DiagnosticsRow("Send backlog", MetricsFormat.bytes(m.sendBacklogBytes)))
        }

        var video: [DiagnosticsRow] = [
            DiagnosticsRow("Encoded resolution", MetricsFormat.resolution(width: m.width, height: m.height, fps: m.configuredFPS)),
            DiagnosticsRow(role == .host ? "Sent FPS" : "On-glass FPS", MetricsFormat.fps(m.fps)),
        ]
        video.append(DiagnosticsRow(role == .host ? "Viewer completed FPS" : "Received FPS",
                                    MetricsFormat.fps(m.receivedFPS)))
        video += [
            DiagnosticsRow("Bitrate", MetricsFormat.bitrate(kbps: m.bitrateKbps)),
            DiagnosticsRow("Target bitrate", m.targetBitrateKbps > 0 ? MetricsFormat.bitrate(kbps: m.targetBitrateKbps) : MetricsFormat.placeholder),
        ]
        if role == .host {
            video += [
                DiagnosticsRow("Hardware encoder", MetricsFormat.flag(m.hardwareEncoder)),
                DiagnosticsRow("Low-latency rate control", MetricsFormat.flag(m.lowLatencyRateControl)),
            ]
        }

        var latency: [DiagnosticsRow] = []
        switch role {
        case .host:
            latency = [
                DiagnosticsRow("Capture → encode done", MetricsFormat.summary(m.captureToEncodeDone)),
                DiagnosticsRow("Capture → sent (host pipeline)", MetricsFormat.summary(m.hostPipeline)),
            ]
        case .viewer:
            latency = [
                DiagnosticsRow("Network → decode done", MetricsFormat.summary(m.networkToDecodeDone)),
                DiagnosticsRow("Decode → present", MetricsFormat.summary(m.decodeToPresent)),
                DiagnosticsRow("Host pipeline (reported)", MetricsFormat.summary(m.hostPipeline)),
            ]
        }

        var counters: [DiagnosticsRow] = [
            DiagnosticsRow("Frames lost", MetricsFormat.count(m.framesLost)),
            DiagnosticsRow("Keyframe requests", MetricsFormat.count(m.keyframeRequests)),
        ]
        switch role {
        case .host:
            counters.append(DiagnosticsRow("Dropped (backpressure)", MetricsFormat.count(m.framesDroppedBackpressure)))
        case .viewer:
            counters.append(DiagnosticsRow("Replaced before display", MetricsFormat.count(m.framesReplacedBeforeDisplay)))
        }

        return [
            DiagnosticsSection(title: "Network", rows: network),
            DiagnosticsSection(title: "Video", rows: video),
            DiagnosticsSection(title: "Latency", rows: latency),
            DiagnosticsSection(title: "Counters", rows: counters),
        ]
    }
}
