import CaptureCore
import CoreGraphics
import DiagnosticsCore
import Foundation
import Observation
import RenderCore
import WireProtocol

/// Milestone A: capture → hardware encode → hardware decode → Metal on one Mac, with per-stage latency and FPS.
///
/// This is the highest-risk spike of the PRD (§8 A) packaged for the app's Loopback screen: it proves the pipeline
/// and its latency budget before any network is involved. Optional packetize/reassemble with simulated loss exercises
/// the exact wire format and recovery path of a real session (Milestone B exit criterion: "video remains live under
/// artificial 1–3 % packet loss").
///
/// Threading: main actor for state; frames never touch it (see `LoopbackPipeline`).
@MainActor
@Observable
public final class LoopbackSession {
    public enum Source: Sendable, Equatable {
        /// ScreenCaptureKit on a display (nil: the main display). Needs Screen Recording permission.
        case screen(displayID: CGDirectDisplayID?)
        /// Generated frames; no permission needed.
        case synthetic(width: Int, height: Int)
    }

    public struct Options: Sendable, Equatable {
        public var source: Source = .screen(displayID: nil)
        public var capture = CaptureConfig()
        public var bitrateKbps = 3000
        /// Split into datagrams and reassemble, like a real session.
        public var packetize = false
        /// Percentage of datagrams dropped at random (only with `packetize`).
        public var simulatedLossPercent = 0.0
        /// XOR parity datagrams with adaptive K, like a real session (only with `packetize`).
        public var forwardErrorCorrection = true

        public init(source: Source = .screen(displayID: nil), capture: CaptureConfig = CaptureConfig(),
                    bitrateKbps: Int = 3000, packetize: Bool = false, simulatedLossPercent: Double = 0,
                    forwardErrorCorrection: Bool = true) {
            self.source = source
            self.capture = capture
            self.bitrateKbps = bitrateKbps
            self.packetize = packetize
            self.simulatedLossPercent = simulatedLossPercent
            self.forwardErrorCorrection = forwardErrorCorrection
        }
    }

    public enum State: Sendable, Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var metrics = LoopbackMetrics()
    public private(set) var options = Options()

    @ObservationIgnored private let sinkSlot = FrameSinkSlot()
    @ObservationIgnored private let presentRelay = LoopbackPresentRelay()
    @ObservationIgnored private weak var renderView: MetalVideoView?
    @ObservationIgnored private var pipeline: LoopbackPipeline?
    @ObservationIgnored private let makeSource: @Sendable (Source, CaptureConfig) throws -> any VideoSource

    /// - Parameter makeSource: injectable for tests; the default builds a `ScreenCapturer` or `SyntheticVideoSource`.
    public init(makeSource: (@Sendable (Source, CaptureConfig) throws -> any VideoSource)? = nil) {
        self.makeSource = makeSource ?? { source, config in
            switch source {
            case .synthetic(let width, let height):
                return SyntheticVideoSource(sourceWidth: width, sourceHeight: height, config: config)
            case .screen(let displayID):
                let displays = DisplayInfo.activeDisplayIDs()
                guard let id = displayID ?? displays.first, let display = DisplayInfo.make(id: id, name: nil) else {
                    throw HostSessionError.noDisplay
                }
                return ScreenCapturer(display: display, config: config)
            }
        }
    }

    public func attach(renderView view: MetalVideoView?) {
        renderView?.onPresented = nil
        renderView = view
        sinkSlot.sink = view
        let relay = presentRelay
        view?.onPresented = { info in relay.pipeline?.notePresented(info) }
    }

    public func attach(frameSink: (any VideoFrameSink)?) {
        sinkSlot.sink = frameSink
    }

    public func start(options: Options) async {
        switch state {
        case .idle, .failed: break
        default: return
        }
        self.options = options
        state = .starting
        metrics = LoopbackMetrics()
        do {
            let source = try makeSource(options.source, options.capture)
            var pipelineOptions = LoopbackPipeline.Options()
            pipelineOptions.packetize = options.packetize
            pipelineOptions.simulatedLossPercent = options.packetize ? max(0, min(100, options.simulatedLossPercent)) : 0
            pipelineOptions.fec = options.forwardErrorCorrection ? FECPolicy.Configuration() : .off
            pipelineOptions.bitrateKbps = options.bitrateKbps
            pipelineOptions.fps = options.capture.sanitized.fps
            let pipeline = try LoopbackPipeline(source: source, options: pipelineOptions, sinkSlot: sinkSlot)
            pipeline.onMetrics = { [weak self] m in
                onMain { [weak self] in self?.metricsArrived(m, from: pipeline) }
            }
            pipeline.onSourceStopped = { [weak self] _ in
                onMain { [weak self] in
                    guard let self, self.pipeline === pipeline else { return }
                    Task { await self.stop(failure: "Capture was stopped by the system") }
                }
            }
            self.pipeline = pipeline
            presentRelay.pipeline = pipeline
            try await pipeline.start()
            if state == .starting { state = .running }
            Log.session.notice("Loopback started")
        } catch {
            await stop(failure: CaptureError.isPermissionDenied(error)
                       ? "Screen Recording permission is required" : "Could not start loopback: \(error)")
        }
    }

    public func stop() async {
        await stop(failure: nil)
    }

    private func stop(failure: String?) async {
        let pipeline = self.pipeline
        self.pipeline = nil
        presentRelay.pipeline = nil
        await pipeline?.stop()
        renderView?.clear()
        state = failure.map(State.failed) ?? .idle
    }

    private func metricsArrived(_ m: LoopbackMetrics, from pipeline: LoopbackPipeline) {
        guard pipeline === self.pipeline else { return }
        var m = m
        m.framesReplacedBeforeDisplay = renderView?.framesReplacedBeforeDisplay ?? 0
        metrics = m
    }
}

/// Lets the Metal presented handler reach the current loopback pipeline from any thread.
final class LoopbackPresentRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoopbackPipeline?

    var pipeline: LoopbackPipeline? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
