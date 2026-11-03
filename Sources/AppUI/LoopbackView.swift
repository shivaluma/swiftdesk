import AppKit
import CaptureCore
import DiagnosticsCore
import RenderCore
import SessionCore
import SwiftUI

/// Milestone A diagnostics (PRD §8 A): ScreenCaptureKit (or a synthetic source) → hardware H.264 encode → hardware
/// decode → Metal on this Mac, with per-stage p50/p95 latency, per-stage FPS and the encoder's hardware /
/// low-latency flags. Optional packetization with simulated loss exercises the real wire format and recovery path
/// (Milestone B: "video remains live under artificial 1–3 % packet loss").
struct LoopbackView: View {
    let loopback: LoopbackSession

    @State private var sourceKind: SourceKind = .screen
    @State private var displays: [DisplayInfo] = []
    @State private var displayID: CGDirectDisplayID?
    @State private var packetize = false
    @State private var lossPercent = 1.0
    @State private var bitrateKbps = 3000
    @State private var screenRecordingGranted = ScreenCapturePermission.isGranted()

    enum SourceKind: String, CaseIterable, Identifiable {
        case screen = "Screen"
        case synthetic = "Synthetic"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            Form {
                Section("Source") {
                    Picker("Source", selection: $sourceKind) {
                        ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if sourceKind == .screen {
                        Picker("Display", selection: $displayID) {
                            ForEach(displays) { display in
                                Text(verbatim: "\(display.name) — \(display.pixelWidth)×\(display.pixelHeight)")
                                    .tag(Optional(display.id))
                            }
                        }
                        if !screenRecordingGranted {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Screen Recording is not allowed for SwiftDesk.", systemImage: Symbols.warning)
                                    .foregroundStyle(.orange)
                                HStack {
                                    Button("Request Access…") {
                                        screenRecordingGranted = ScreenCapturePermission.request()
                                    }
                                    Button("Open System Settings") { ScreenCapturePermission.openSettings() }
                                }
                                .controlSize(.small)
                                Text("Or use the Synthetic source, which needs no permission.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Generated 1280×720 test frames at the capture frame rate (no permission needed).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Encoder") {
                    Picker("Bitrate", selection: $bitrateKbps) {
                        ForEach([1000, 2000, 3000, 5000, 8000], id: \.self) { kbps in
                            Text(MetricsFormat.bitrate(kbps: Double(kbps))).tag(kbps)
                        }
                    }
                    Toggle("Packetize and reassemble (wire format)", isOn: $packetize)
                    LabeledContent("Simulated datagram loss") {
                        HStack {
                            Slider(value: $lossPercent, in: 0...10, step: 0.5)
                                .frame(minWidth: 120)
                            Text(MetricsFormat.percent(lossPercent))
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    .disabled(!packetize)
                }
                .disabled(isActive)

                Section {
                    HStack {
                        stateLabel
                        Spacer()
                        if isActive {
                            Button {
                                Task { await loopback.stop() }
                            } label: {
                                Label("Stop", systemImage: Symbols.stop)
                            }
                            .controlSize(.large)
                        } else {
                            Button {
                                Task { await loopback.start(options: options) }
                            } label: {
                                Label("Start", systemImage: Symbols.play)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(sourceKind == .screen && displays.isEmpty)
                        }
                    }
                }

                LoopbackMetricsSections(metrics: loopback.metrics, packetize: loopback.options.packetize)
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, idealWidth: 440)

            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    MetalPreview(loopback: loopback)
                    if !isActive {
                        Text("Preview appears here while the loopback runs")
                            .foregroundStyle(.white.opacity(0.6))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(minWidth: 360, minHeight: 240)
        }
        .onAppear(perform: refreshEnvironment)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshEnvironment()
        }
    }

    private var isActive: Bool {
        switch loopback.state {
        case .starting, .running: true
        case .idle, .failed: false
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch loopback.state {
        case .idle:
            Label("Idle", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
        case .running:
            Label("Running", systemImage: "circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: Symbols.warning)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: LoopbackSession.Options {
        let source: LoopbackSession.Source = switch sourceKind {
        case .screen: .screen(displayID: displayID)
        case .synthetic: .synthetic(width: 1280, height: 720)
        }
        return LoopbackSession.Options(source: source, capture: CaptureConfig(), bitrateKbps: bitrateKbps,
                                       packetize: packetize, simulatedLossPercent: packetize ? lossPercent : 0)
    }

    private func refreshEnvironment() {
        displays = DisplayInfo.activeDisplays()
        if displayID == nil || !displays.contains(where: { $0.id == displayID }) {
            displayID = displays.first?.id
        }
        screenRecordingGranted = ScreenCapturePermission.isGranted()
    }
}

/// Per-stage latency table, FPS per stage, counters and codec flags.
private struct LoopbackMetricsSections: View {
    let metrics: LoopbackMetrics
    let packetize: Bool

    var body: some View {
        Section("Latency per stage") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Stage")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    Text("p50")
                    Text("p95")
                    Text("max")
                    Text("n")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(LoopbackStageRow.rows(metrics)) { row in
                    GridRow {
                        Text(row.stage).gridColumnAlignment(.leading)
                        Text(row.p50)
                        Text(row.p95)
                        Text(row.max)
                        Text(row.count).foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }

        Section("Throughput") {
            LabeledContent("Captured", value: "\(MetricsFormat.fps(metrics.capturedFPS)) fps")
            LabeledContent("Encoded", value: "\(MetricsFormat.fps(metrics.encodedFPS)) fps")
            LabeledContent("Decoded", value: "\(MetricsFormat.fps(metrics.decodedFPS)) fps")
            LabeledContent("Presented", value: "\(MetricsFormat.fps(metrics.presentedFPS)) fps")
            LabeledContent("Bitrate", value: MetricsFormat.bitrate(kbps: metrics.bitrateKbps))
            LabeledContent("Resolution", value: MetricsFormat.resolution(width: metrics.width, height: metrics.height))
        }

        Section("Codec") {
            LabeledContent("Hardware encoder", value: MetricsFormat.flag(metrics.hardwareEncoder))
            LabeledContent("Low-latency rate control", value: MetricsFormat.flag(metrics.lowLatencyRateControl))
            LabeledContent("Hardware decoder", value: MetricsFormat.flag(metrics.hardwareDecoder))
        }

        Section("Counters") {
            LabeledContent("Frames captured / encoded / decoded",
                           value: "\(metrics.framesCaptured) / \(metrics.framesEncoded) / \(metrics.framesDecoded)")
            LabeledContent("Encoder backpressure drops", value: MetricsFormat.count(metrics.encoderBackpressureDrops))
            LabeledContent("Replaced before display", value: MetricsFormat.count(metrics.framesReplacedBeforeDisplay))
            LabeledContent("Decode failures", value: MetricsFormat.count(metrics.decodeFailures))
            if packetize {
                LabeledContent("Simulated datagrams dropped", value: MetricsFormat.count(metrics.simulatedPacketsDropped))
                LabeledContent("Frames lost", value: MetricsFormat.count(metrics.framesLost))
                LabeledContent("Keyframe requests", value: MetricsFormat.count(metrics.keyframeRequests))
            }
        }
    }
}

/// One line of the loopback latency table (pure; unit-tested).
public struct LoopbackStageRow: Sendable, Equatable, Identifiable {
    public var id: String { stage }
    public var stage: String
    public var p50: String
    public var p95: String
    public var max: String
    public var count: String

    public static func rows(_ m: LoopbackMetrics) -> [LoopbackStageRow] {
        [
            row("Capture → encoded", m.captureToEncodeDone),
            row("Encoded → decoded", m.encodeDoneToDecodeDone),
            row("Decoded → on glass", m.decodeToPresent),
            row("Capture → on glass", m.captureToPresent),
        ]
    }

    static func row(_ stage: String, _ s: RollingStats.Summary) -> LoopbackStageRow {
        guard s.count > 0 else {
            let p = MetricsFormat.placeholder
            return LoopbackStageRow(stage: stage, p50: p, p95: p, max: p, count: "0")
        }
        return LoopbackStageRow(stage: stage, p50: MetricsFormat.millis(s.p50), p95: MetricsFormat.millis(s.p95),
                                max: MetricsFormat.millis(s.max), count: String(s.count))
    }
}

/// Plain `MetalVideoView` preview for the loopback (no input capture).
private struct MetalPreview: NSViewRepresentable {
    let loopback: LoopbackSession

    func makeCoordinator() -> RenderAttachment {
        RenderAttachment(owner: loopback) { [weak loopback] in loopback?.attach(renderView: nil) }
    }

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(frame: .zero)
        loopback.attach(renderView: view)
        context.coordinator.attached(view)
        return view
    }

    func updateNSView(_ view: MetalVideoView, context: Context) {}

    static func dismantleNSView(_ view: MetalVideoView, coordinator: RenderAttachment) {
        coordinator.detachIfCurrent(view)
    }
}
