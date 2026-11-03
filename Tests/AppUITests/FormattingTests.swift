import DiagnosticsCore
import Foundation
import Testing
@testable import AppUI

@Suite("MetricsFormat")
struct MetricsFormatTests {
    @Test func millisecondsSwitchPrecisionAt100() {
        #expect(MetricsFormat.millis(0) == "0.0 ms")
        #expect(MetricsFormat.millis(4.26) == "4.3 ms")
        #expect(MetricsFormat.millis(99.94) == "99.9 ms")
        #expect(MetricsFormat.millis(100) == "100 ms")
        #expect(MetricsFormat.millis(1234.6) == "1235 ms")
    }

    @Test func invalidNumbersRenderPlaceholder() {
        #expect(MetricsFormat.millis(-1) == MetricsFormat.placeholder)
        #expect(MetricsFormat.millis(.nan) == MetricsFormat.placeholder)
        #expect(MetricsFormat.millis(.infinity) == MetricsFormat.placeholder)
        #expect(MetricsFormat.fps(.nan) == MetricsFormat.placeholder)
        #expect(MetricsFormat.bitrate(kbps: -5) == MetricsFormat.placeholder)
        #expect(MetricsFormat.percent(.infinity) == MetricsFormat.placeholder)
        #expect(MetricsFormat.bytes(-1) == MetricsFormat.placeholder)
    }

    @Test func rttUsesSmoothedValueAndPlaceholderBeforeFirstSample() {
        #expect(MetricsFormat.rtt(.none) == MetricsFormat.placeholder)
        let estimator = RTTEstimator()
        estimator.add(sampleMillis: 12)
        #expect(MetricsFormat.rtt(estimator.value) == "12.0 ms")
        estimator.add(sampleMillis: 4)   // EWMA: 0.875 × 12 + 0.125 × 4 = 11
        #expect(MetricsFormat.rtt(estimator.value) == "11.0 ms")
    }

    @Test func fpsShowsDecimalOnlyForSlowStreams() {
        #expect(MetricsFormat.fps(0) == "0")
        #expect(MetricsFormat.fps(0.4) == "0.4")
        #expect(MetricsFormat.fps(9.94) == "9.9")
        #expect(MetricsFormat.fps(59.6) == "60")
    }

    @Test func bitrateUnits() {
        #expect(MetricsFormat.bitrate(kbps: 0) == "0 kb/s")
        #expect(MetricsFormat.bitrate(kbps: 850.4) == "850 kb/s")
        #expect(MetricsFormat.bitrate(kbps: 1000) == "1.00 Mb/s")
        #expect(MetricsFormat.bitrate(kbps: 2954.2) == "2.95 Mb/s")
    }

    @Test func percentPrecision() {
        #expect(MetricsFormat.percent(0) == "0.00 %")
        #expect(MetricsFormat.percent(0.256) == "0.26 %")
        #expect(MetricsFormat.percent(12.54) == "12.5 %")
    }

    @Test func resolutionNeedsBothDimensions() {
        #expect(MetricsFormat.resolution(width: 1280, height: 720) == "1280×720")
        #expect(MetricsFormat.resolution(width: 0, height: 720) == MetricsFormat.placeholder)
        #expect(MetricsFormat.resolution(width: 960, height: 540, fps: 30) == "960×540 @ 30 fps")
        #expect(MetricsFormat.resolution(width: 960, height: 540, fps: 0) == "960×540")
        #expect(MetricsFormat.resolution(width: 0, height: 0, fps: 60) == MetricsFormat.placeholder)
    }

    @Test func summaryShowsP50AndP95() {
        #expect(MetricsFormat.summary(.empty) == MetricsFormat.placeholder)
        let s = RollingStats.summarize([4.12, 4.12, 4.12, 7.95])
        #expect(MetricsFormat.summary(s) == "p50 \(MetricsFormat.millis(s.p50)) · p95 \(MetricsFormat.millis(s.p95))")
        #expect(MetricsFormat.summary(s).hasPrefix("p50 4.1 ms"))
        #expect(MetricsFormat.summary(s).hasSuffix("p95 8.0 ms"))
    }

    @Test func flagsAndBytes() {
        #expect(MetricsFormat.flag(true) == "Yes")
        #expect(MetricsFormat.flag(false) == "No")
        #expect(MetricsFormat.flag(nil) == MetricsFormat.placeholder)
        #expect(MetricsFormat.bytes(512) == "512 B")
        #expect(MetricsFormat.bytes(128 * 1024) == "128 KiB")
        #expect(MetricsFormat.bytes(3 * 1024 * 1024 / 2) == "1.5 MiB")
        #expect(MetricsFormat.count(18_446_744_073_709_551_615) == "18446744073709551615")
    }

    @Test func formattingIgnoresUserLocale() {
        // A comma-decimal locale must not leak into latency reports.
        #expect(MetricsFormat.fixed(1.5, digits: 1) == "1.5")
        #expect(!MetricsFormat.bitrate(kbps: 2500).contains(","))
    }
}

@Suite("Diagnostics rows")
struct DiagnosticsRowsTests {
    private func sample() -> MetricsSnapshot {
        var m = MetricsSnapshot()
        let rtt = RTTEstimator()
        rtt.add(sampleMillis: 6)
        m.rtt = rtt.value
        m.fps = 58
        m.receivedFPS = 59
        m.bitrateKbps = 2900
        m.targetBitrateKbps = 3000
        m.packetLossPercent = 0.5
        m.framesLost = 3
        m.framesDroppedBackpressure = 4
        m.framesReplacedBeforeDisplay = 5
        m.keyframeRequests = 6
        m.captureToEncodeDone = RollingStats.summarize([5, 5, 6])
        m.hostPipeline = RollingStats.summarize([6, 6, 7])
        m.networkToDecodeDone = RollingStats.summarize([2, 2, 3])
        m.decodeToPresent = RollingStats.summarize([8, 8, 9])
        m.width = 1280
        m.height = 720
        m.configuredFPS = 60
        m.hardwareEncoder = true
        m.lowLatencyRateControl = false
        m.pathDescription = "LAN"
        m.sendBacklogBytes = 2048
        return m
    }

    private func value(_ label: String, in sections: [DiagnosticsSection]) -> String? {
        sections.flatMap(\.rows).first { $0.label == label }?.value
    }

    @Test func hostRowsCoverHostOnlyFields() {
        let sections = DiagnosticsRows.sections(for: sample(), role: .host)
        #expect(sections.map(\.title) == ["Network", "Video", "Latency", "Counters"])
        #expect(value("Send backlog", in: sections) == "2 KiB")
        #expect(value("Hardware encoder", in: sections) == "Yes")
        #expect(value("Low-latency rate control", in: sections) == "No")
        #expect(value("Capture → encode done", in: sections) == "p50 5.0 ms · p95 6.0 ms")
        #expect(value("Dropped (backpressure)", in: sections) == "4")
        #expect(value("Sent FPS", in: sections) == "58")
        #expect(value("Viewer completed FPS", in: sections) == "59")
        #expect(value("Replaced before display", in: sections) == nil)
        #expect(value("Decode → present", in: sections) == nil)
    }

    @Test func viewerRowsCoverViewerOnlyFields() {
        let sections = DiagnosticsRows.sections(for: sample(), role: .viewer)
        #expect(value("On-glass FPS", in: sections) == "58")
        #expect(value("Received FPS", in: sections) == "59")
        #expect(value("Decode → present", in: sections) == "p50 8.0 ms · p95 9.0 ms")
        #expect(value("Network → decode done", in: sections) == "p50 2.0 ms · p95 3.0 ms")
        #expect(value("Replaced before display", in: sections) == "5")
        #expect(value("Send backlog", in: sections) == nil)
        #expect(value("Hardware encoder", in: sections) == nil)
    }

    @Test func sharedRowsAreFormatted() {
        for role in [MetricsRole.host, .viewer] {
            let sections = DiagnosticsRows.sections(for: sample(), role: role)
            #expect(value("Path", in: sections) == "LAN")
            #expect(value("RTT (smoothed)", in: sections) == "6.0 ms")
            #expect(value("RTT (min)", in: sections) == "6.0 ms")
            #expect(value("Packet loss", in: sections) == "0.50 %")
            #expect(value("Encoded resolution", in: sections) == "1280×720 @ 60 fps")
            #expect(value("Bitrate", in: sections) == "2.90 Mb/s")
            #expect(value("Target bitrate", in: sections) == "3.00 Mb/s")
            #expect(value("Frames lost", in: sections) == "3")
            #expect(value("Keyframe requests", in: sections) == "6")
        }
    }

    @Test func emptySnapshotShowsPlaceholdersNotZeroLatency() {
        let sections = DiagnosticsRows.sections(for: MetricsSnapshot(), role: .viewer)
        #expect(value("Path", in: sections) == MetricsFormat.placeholder)
        #expect(value("RTT (smoothed)", in: sections) == MetricsFormat.placeholder)
        #expect(value("RTT (latest)", in: sections) == MetricsFormat.placeholder)
        #expect(value("Decode → present", in: sections) == MetricsFormat.placeholder)
        #expect(value("Encoded resolution", in: sections) == MetricsFormat.placeholder)
        #expect(value("Target bitrate", in: sections) == MetricsFormat.placeholder)
    }

    @Test func rowLabelsAreUniqueWithinARole() {
        for role in [MetricsRole.host, .viewer] {
            let labels = DiagnosticsRows.sections(for: sample(), role: role).flatMap(\.rows).map(\.label)
            #expect(Set(labels).count == labels.count, "duplicate labels for \(role)")
        }
    }
}
