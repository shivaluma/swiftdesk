import CaptureCore
import CodecCore
import CoreVideo
import DiagnosticsCore
import Foundation
import RenderCore
import Synchronization
import WireProtocol

/// Per-stage numbers for the Milestone A loopback (PRD §8 A: "measure stage latency; check hardware encoder use and
/// dropped frames"). All latencies are on one machine's monotonic clock, so they are directly comparable.
public struct LoopbackMetrics: Sendable, Equatable {
    public var capturedFPS: Double = 0
    public var encodedFPS: Double = 0
    public var decodedFPS: Double = 0
    /// On-glass frame rate (Metal presented handler); 0 without an attached view.
    public var presentedFPS: Double = 0
    public var bitrateKbps: Double = 0

    /// Capture callback → encoder output.
    public var captureToEncodeDone: RollingStats.Summary = .empty
    /// Encoder output → decoder output (includes packetize/reassemble when enabled).
    public var encodeDoneToDecodeDone: RollingStats.Summary = .empty
    /// Decoder output → on glass.
    public var decodeToPresent: RollingStats.Summary = .empty
    /// Capture callback → on glass (the local "glass-to-glass minus display scan-out" figure).
    public var captureToPresent: RollingStats.Summary = .empty

    public var framesCaptured: UInt64 = 0
    public var framesEncoded: UInt64 = 0
    public var framesDecoded: UInt64 = 0
    /// Frames the encoder refused because one was already in flight (one-pending-frame rule).
    public var encoderBackpressureDrops: UInt64 = 0
    public var framesLost: UInt64 = 0
    public var keyframeRequests: UInt64 = 0
    public var decodeFailures: UInt64 = 0
    public var framesReplacedBeforeDisplay: UInt64 = 0
    public var simulatedPacketsDropped: UInt64 = 0
    /// Data fragments rebuilt from FEC parity (packetize mode).
    public var fecFragmentsRecovered: UInt64 = 0
    /// FEC group size K currently used (0 = no parity, or packetize off).
    public var fecGroupSize = 0

    public var width = 0
    public var height = 0
    public var hardwareEncoder: Bool?
    public var lowLatencyRateControl: Bool?
    public var hardwareDecoder: Bool?

    public init() {}
}

/// Capture → encode → (optional packetize / lossy channel / reassemble) → decode → sink, on one Mac.
///
/// Mirrors the real Host and Viewer hot paths without a network: the encoder callback hands each access unit to a
/// dedicated decode queue (standing in for the network hop), where it is optionally split into the same 32-byte-header
/// datagrams, randomly thinned to simulate loss, reassembled and gated exactly like the Viewer does, then decoded and
/// enqueued to the renderer. Keyframe requests go straight to the encoder. With packetize on, frames carry the same FEC
/// parity datagrams as a real session (`Options.fec`), and K adapts once per second to the loss the reassembler saw.
///
/// Synchronization: decode-side state (reassembler, gate, decoder, RNG) is confined to `decodeQueue`; counters are
/// atomics or DiagnosticsCore's thread-safe types; the capture-time ring is a `Mutex`.
final class LoopbackPipeline: @unchecked Sendable {
    struct Options: Sendable {
        var packetize = false
        var simulatedLossPercent = 0.0
        var maxDatagramSize = WireConstants.defaultMaxDatagramSize
        var bitrateKbps = 3000
        var fps = 60
        /// Parity datagrams in packetize mode; adaptive like `HostMediaPipeline` by default.
        var fec = FECPolicy.Configuration()
    }

    private struct Callbacks {
        var onMetrics: (@Sendable (LoopbackMetrics) -> Void)?
        var onSourceStopped: (@Sendable ((any Error)?) -> Void)?
    }

    private static let ringSize = 128

    let source: any VideoSource
    let encoder: H264Encoder
    let options: Options
    private let sinkSlot: FrameSinkSlot
    private let decodeQueue = DispatchQueue(label: "com.swiftdesk.session.loopback.decode", qos: .userInteractive)
    private let callbacks = Mutex(Callbacks())
    private let stopped = Atomic<Bool>(false)
    private let encoderSize = Atomic<UInt64>(0)
    private let reconfigureScheduled = Atomic<Bool>(false)

    private let captured = RateCounter()
    private let encodedRate = RateCounter()
    private let decodedRate = RateCounter()
    private let presentedRate = RateCounter()
    private let encodedBytes = RateCounter()
    private let presentedAny = Atomic<Bool>(false)
    private let captureToEncode = RollingStats()
    private let encodeToDecode = RollingStats()
    private let decodeToPresent = RollingStats()
    private let captureToPresent = RollingStats()
    private let framesCaptured = Atomic<UInt64>(0)
    private let keyframeRequests = Atomic<UInt64>(0)
    private let decodeFailures = Atomic<UInt64>(0)
    private let simulatedDrops = Atomic<UInt64>(0)
    /// frameId → capture time, so the presented handler can compute capture → present.
    private let captureTimes = Mutex([UInt64](repeating: 0, count: LoopbackPipeline.ringSize))

    // Confined to `decodeQueue`.
    private let decoder = H264Decoder()
    private let packetizer: VideoPacketizer
    private let reassembler: FrameReassembler
    private var gate = RecoveryGate()
    private var fecPolicy: FECPolicy
    private var lastLossStats = FrameReassembler.Stats()
    private var lastLossReportNanos: UInt64 = 0
    private let fecGroupSizeNow = Atomic<Int>(0)
    private var nextFrameId: UInt32 = 1
    private var rng = SystemRandomNumberGenerator()
    private var timer: (any DispatchSourceTimer)?
    private var timerTicks: UInt64 = 0
    private var pendingEncodeDoneNanos: UInt64 = 0

    init(source: any VideoSource, options: Options, sinkSlot: FrameSinkSlot) throws {
        self.source = source
        self.options = options
        self.sinkSlot = sinkSlot
        self.packetizer = VideoPacketizer(sessionId: 1, maxDatagramSize: options.maxDatagramSize)
        self.reassembler = FrameReassembler(config: FrameReassembler.Config(sessionId: 1))
        self.fecPolicy = FECPolicy(configuration: options.packetize ? options.fec : .off)
        fecGroupSizeNow.store(fecPolicy.groupSize, ordering: .relaxed)
        let size = HostMediaPipeline.evenSize(source.outputSize)
        encoder = try H264Encoder(config: EncoderConfig(width: size.width, height: size.height, fps: options.fps,
                                                        bitrateKbps: options.bitrateKbps))
        encoderSize.store(HostMediaPipeline.pack(size.width, size.height), ordering: .releasing)
    }

    var onMetrics: (@Sendable (LoopbackMetrics) -> Void)? {
        get { callbacks.withLock { $0.onMetrics } }
        set { callbacks.withLock { $0.onMetrics = newValue } }
    }

    var onSourceStopped: (@Sendable ((any Error)?) -> Void)? {
        get { callbacks.withLock { $0.onSourceStopped } }
        set { callbacks.withLock { $0.onSourceStopped = newValue } }
    }

    func start() async throws {
        decoder.onDecodedFrame = { [weak self] frame in self?.decoded(frame) }
        encoder.onEncodedFrame = { [weak self] frame in self?.encoded(frame) }
        source.onFrame = { [weak self] frame in self?.capturedFrame(frame) }
        source.onStopped = { [weak self] error in
            guard let self, !self.stopped.load(ordering: .acquiring) else { return }
            self.callbacks.withLock { $0.onSourceStopped }?(error)
        }
        try await source.start()
        // `stop()` may have run while the source was starting; it could not stop a source that was not yet running.
        if stopped.load(ordering: .acquiring) {
            await source.stop()
            return
        }
        decodeQueue.async { [self] in startTimer() }
    }

    func stop() async {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        await source.stop()
        source.onFrame = nil
        source.onStopped = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            decodeQueue.async { [self] in
                timer?.cancel()
                timer = nil
                encoder.invalidate()
                decoder.reset()
                decoder.onDecodedFrame = nil
                c.resume()
            }
        }
        encoder.onEncodedFrame = nil
        onMetrics = nil
        onSourceStopped = nil
    }

    /// Metal presented handler (any thread).
    func notePresented(_ info: PresentedFrameInfo) {
        let now = MonotonicClock.nowNanos()
        presentedAny.store(true, ordering: .relaxed)
        presentedRate.record(1, now: now)
        decodeToPresent.add(MonotonicClock.millis(info.decodeToPresentNanos))
        let capture = captureTimes.withLock { $0[Int(info.frameId) % Self.ringSize] }
        if capture > 0, now >= capture {
            captureToPresent.add(MonotonicClock.millis(now - capture))
        }
    }

    // MARK: Source queue

    private func capturedFrame(_ frame: CapturedFrame) {
        captured.record()
        framesCaptured.add(1, ordering: .relaxed)
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let packed = HostMediaPipeline.pack(width, height)
        guard packed == encoderSize.load(ordering: .acquiring) else {
            if !reconfigureScheduled.exchange(true, ordering: .acquiringAndReleasing) {
                decodeQueue.async { [self] in
                    let current = encoder.currentConfig
                    let config = EncoderConfig(width: width & ~1, height: height & ~1, fps: current.fps,
                                               bitrateKbps: current.bitrateKbps)
                    if (try? encoder.reconfigure(config)) != nil { encoderSize.store(packed, ordering: .releasing) }
                    reconfigureScheduled.store(false, ordering: .releasing)
                }
            }
            return
        }
        encoder.encode(frame.pixelBuffer, presentationTime: frame.presentationTime, captureNanos: frame.captureNanos,
                       sequence: frame.sequence)
    }

    // MARK: VideoToolbox thread

    private func encoded(_ frame: EncodedVideoFrame) {
        guard !stopped.load(ordering: .relaxed) else { return }
        encodedRate.record(1, now: frame.encodeDoneNanos)
        encodedBytes.record(UInt64(frame.data.count), now: frame.encodeDoneNanos)
        if frame.encodeDoneNanos >= frame.captureNanos {
            captureToEncode.add(MonotonicClock.millis(frame.encodeDoneNanos - frame.captureNanos))
        }
        decodeQueue.async { [self] in transmit(frame) }
    }

    // MARK: Decode queue

    private func transmit(_ frame: EncodedVideoFrame) {
        guard !stopped.load(ordering: .relaxed) else { return }
        let frameId = nextFrameId
        nextFrameId &+= 1
        captureTimes.withLock { $0[Int(frameId) % Self.ringSize] = frame.captureNanos }
        let flags: VideoFlags = frame.isKeyframe ? .keyframe : []
        guard options.packetize else {
            let now = MonotonicClock.nowNanos()
            deliver(EncodedFrame(frameId: frameId, flags: flags, data: frame.data,
                                 captureTimestampNanos: frame.captureNanos, hostPipelineMicros: 0,
                                 firstPacketAtNanos: now, completedAtNanos: now),
                    encodeDoneNanos: frame.encodeDoneNanos)
            return
        }
        guard let packets = try? packetizer.packetize(frameId: frameId, frame: frame.data, flags: flags,
                                                      captureTimestampNanos: frame.captureNanos,
                                                      hostPipelineMicros: 0,
                                                      fecGroupSize: fecPolicy.groupSize) else { return }
        for packet in packets {
            if options.simulatedLossPercent > 0, Double.random(in: 0..<100, using: &rng) < options.simulatedLossPercent {
                simulatedDrops.add(1, ordering: .relaxed)
                continue
            }
            guard let parsed = try? Datagram.parse(packet) else { continue }
            let events = reassembler.ingest(parsed, nowNanos: MonotonicClock.nowNanos())
            handle(events, encodeDoneNanos: frame.encodeDoneNanos)
        }
    }

    private func handle(_ events: [ReassemblyEvent], encodeDoneNanos: UInt64) {
        for event in events {
            switch event {
            case .framesLost:
                if gate.onLoss(nowNanos: MonotonicClock.nowNanos()) { requestKeyframe() }
            case .frameComplete(let frame):
                deliver(frame, encodeDoneNanos: encodeDoneNanos)
            }
        }
    }

    private func deliver(_ frame: EncodedFrame, encodeDoneNanos: UInt64) {
        guard gate.admit(flags: frame.flags) else { return }
        pendingEncodeDoneNanos = encodeDoneNanos
        if !decoder.decode(frame.data, frameId: frame.frameId, captureNanos: frame.captureTimestampNanos,
                           receivedNanos: frame.firstPacketAtNanos) {
            decodeFailures.add(1, ordering: .relaxed)
            if gate.onDecodeError(nowNanos: MonotonicClock.nowNanos()) { requestKeyframe() }
        }
    }

    private func decoded(_ frame: DecodedFrame) {
        decodedRate.record(1, now: frame.decodeDoneNanos)
        if frame.decodeDoneNanos >= pendingEncodeDoneNanos {
            encodeToDecode.add(MonotonicClock.millis(frame.decodeDoneNanos - pendingEncodeDoneNanos))
        }
        sinkSlot.sink?.enqueue(SessionRenderFrame(pixelBuffer: frame.pixelBuffer, frameId: frame.frameId,
                                                  decodeDoneNanos: frame.decodeDoneNanos))
    }

    private func requestKeyframe() {
        keyframeRequests.add(1, ordering: .relaxed)
        encoder.requestKeyframe()
    }

    private func startTimer() {
        guard timer == nil, !stopped.load(ordering: .relaxed) else { return }
        let t = DispatchSource.makeTimerSource(queue: decodeQueue)
        t.schedule(deadline: .now() + .milliseconds(15), repeating: .milliseconds(15), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard !stopped.load(ordering: .relaxed) else { return }
        let now = MonotonicClock.nowNanos()
        let expired = reassembler.expire(nowNanos: now)
        if !expired.isEmpty { handle(expired, encodeDoneNanos: now) }
        if options.packetize, gate.tick(nowNanos: now) { requestKeyframe() }
        if options.packetize { reportLoss(now: now) }
        timerTicks &+= 1
        // ≈2 Hz (33 × 15 ms).
        if timerTicks % 33 == 0 { callbacks.withLock { $0.onMetrics }?(snapshot(now: now)) }
    }

    /// Once per second: the loss estimate a Viewer would put in STATS drives the FEC group size (decode queue).
    private func reportLoss(now: UInt64) {
        if lastLossReportNanos == 0 { lastLossReportNanos = now }
        guard now - lastLossReportNanos >= 1_000_000_000 else { return }
        let stats = reassembler.stats
        let estimate = stats.lossEstimate(since: lastLossStats)
        let total = estimate.received + estimate.lost
        if total > 0 {
            fecPolicy.update(lossPercent: Double(estimate.lost) * 100 / Double(total))
            fecGroupSizeNow.store(fecPolicy.groupSize, ordering: .relaxed)
        }
        lastLossStats = stats
        lastLossReportNanos = now
    }

    private func snapshot(now: UInt64) -> LoopbackMetrics {
        var m = LoopbackMetrics()
        m.capturedFPS = captured.ratePerSecond(now: now)
        m.encodedFPS = encodedRate.ratePerSecond(now: now)
        m.decodedFPS = decodedRate.ratePerSecond(now: now)
        m.presentedFPS = presentedAny.load(ordering: .relaxed) ? presentedRate.ratePerSecond(now: now) : 0
        m.bitrateKbps = encodedBytes.ratePerSecond(now: now) * 8 / 1_000
        m.captureToEncodeDone = captureToEncode.summary()
        m.encodeDoneToDecodeDone = encodeToDecode.summary()
        m.decodeToPresent = decodeToPresent.summary()
        m.captureToPresent = captureToPresent.summary()
        m.framesCaptured = framesCaptured.load(ordering: .relaxed)
        m.framesEncoded = encoder.framesEncoded
        m.framesDecoded = decoder.framesDecoded
        m.encoderBackpressureDrops = encoder.droppedForBackpressure
        m.framesLost = reassembler.stats.framesLost
        m.keyframeRequests = keyframeRequests.load(ordering: .relaxed)
        m.decodeFailures = decodeFailures.load(ordering: .relaxed)
        m.simulatedPacketsDropped = simulatedDrops.load(ordering: .relaxed)
        m.fecFragmentsRecovered = reassembler.stats.fragmentsRecovered
        m.fecGroupSize = fecGroupSizeNow.load(ordering: .relaxed)
        let size = HostMediaPipeline.unpack(encoderSize.load(ordering: .acquiring))
        m.width = size.width
        m.height = size.height
        m.hardwareEncoder = encoder.isHardwareAccelerated
        m.lowLatencyRateControl = encoder.lowLatencyRateControl
        m.hardwareDecoder = decoder.isHardwareAccelerated
        return m
    }
}
