import CaptureCore
import CodecCore
import CoreGraphics
import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization
import WireProtocol

/// The Host's hot path for one session: `VideoSource → H264Encoder → VideoPacketizer → SessionTransport`.
///
/// Threading (PRD §6 rules 6–7) — no main actor, no `Task`, no extra hop per frame:
/// - **Source queue** (`onFrame`): a size check and `encoder.encode`, which is a compare-exchange plus an async
///   hand-off. A frame arriving while one is in flight is dropped by the encoder (one-pending-frame rule).
/// - **VideoToolbox callback thread** (`onEncodedFrame`): packetize and `sendDatagrams` inline. Both are
///   non-blocking (Network.framework queues internally), and the encoder's in-flight slot guarantees these calls are
///   serialized and in frame order.
/// - **Control queue** (`controlQueue`): ~2 Hz timer for PING, adaptation (1 Hz), metrics; encoder reconfiguration
///   (which blocks until the encoder flushes, so it must never run on the capture or VideoToolbox threads).
/// - **Transport queue** (caller of `keyframeRequested` / `pong` / `viewerStats`): only atomics and short locks.
///
/// Send queue bound: a frame is refused when more than `sendQueueBudgetMillis` (80 ms) of video at the current
/// target bitrate is already queued ahead of it in the transport, plus whatever part of the last keyframe batch the
/// link cannot have sent yet at that bitrate (`allowedBacklogAhead`). A time bound, unlike a fixed byte cap, means the
/// same staleness at 1000 and 12000 kbps; the keyframe allowance keeps P-frames that follow a large keyframe from being
/// refused (each refusal costs another keyframe).
///
/// Loss handling on the send side: when the transport refuses a frame (backlog over its limit) the frame id is still
/// consumed, so the Viewer sees a gap and gates its decoder; the Host asks the encoder for a keyframe and stops sending
/// P-frames until that keyframe has been sent — they would be undecodable and only deepen the backlog. If that recovery
/// keyframe is refused too (a blackout: nothing drains), the next one is asked for by the control timer at most every
/// 500 ms rather than for every captured frame, so a dead link costs ~2 keyframe encodes per second, not 60, and the
/// link coming back meets one keyframe (plus the Viewer's single request, `RecoveryGate`).
///
/// Forward error correction: every frame is sent with XOR parity datagrams (`WireProtocol.FECLayout`) appended after
/// its data fragments, so a single lost datagram per group is rebuilt by the Viewer without a keyframe round trip and
/// without any retransmission wait. The group size K follows the Viewer's STATS loss report (`FECPolicy`): more loss,
/// more parity. Parity goes out in the same `sendDatagrams` batch, after the data, so at no loss it costs bandwidth
/// but no latency.
///
/// Synchronization: `sender` (packetizer, frame ids, keyframe gate, FEC policy) is a `Mutex` touched only by the
/// serialized encoder callback, briefly by the send-failure path, and by the STATS handler (FEC policy update); counters are atomics or the thread-safe DiagnosticsCore types;
/// adaptation state is confined to `controlQueue`.
final class HostMediaPipeline: @unchecked Sendable {
    struct Configuration: Sendable {
        var sessionId: UInt32
        /// Capture settings other than size/fps (cursor, queue depth); the ladder rung supplies size and fps.
        var baseCapture = CaptureConfig()
        var adaptation = AdaptationController.Configuration()
        var adaptationEnabled = true
        var keyframeIntervalSeconds: Double = 4
        /// Host display size in points at session start, reported in CONFIG (the Viewer sizes its window by it).
        /// `displayChanged()` replaces it with the live size.
        var displayPointSize: CGSize
        var metricsIntervalNanos: UInt64 = 500_000_000
        /// Send every keyframe datagram twice. A 720p keyframe is ~50–100 datagrams (a native 1600×900 or 1080p one
        /// ~1.5–2.5× that), so at 3 % random loss only ~(0.97)^80 ≈ 9 % of 720p keyframes — and far fewer larger ones
        /// — would arrive whole and recovery would stall; duplicates make per-packet loss p² (0.09 %) for the rare,
        /// on-demand keyframes, while P-frames are unchanged. The cost is a keyframe burst twice as long, which the
        /// keyframe term of `allowedBacklogAhead` (and `PeerConnection`'s 1 MiB absolute cap) leaves room for. The
        /// reassembler already counts and ignores duplicate fragments.
        var duplicateKeyframePackets = true
        /// XOR parity datagrams; adaptive K from the Viewer's loss reports by default. `.off` sends none.
        var fec = FECPolicy.Configuration()
        /// Most video (in ms at the target bitrate) that may wait in the transport ahead of a new frame, beyond the
        /// undrained part of the last keyframe. See `allowedBacklogAhead`.
        var sendQueueBudgetMillis = 80
    }

    private struct SenderState {
        var packetizer: VideoPacketizer
        var fec: FECPolicy
        var nextFrameId: UInt32 = 1
        var awaitingKeyframe = false
        var recoveryRequested = false
        var framesSkippedAwaitingKeyframe: UInt64 = 0
        /// Size (all datagrams, duplicates and parity included) and send time of the most recent keyframe batch.
        var lastKeyframeBatchBytes = 0
        var lastKeyframeSentNanos: UInt64 = 0
        /// A recovery keyframe was refused; the control timer asks the encoder for the next one.
        var keyframeRetryDue = false
    }

    private struct Callbacks {
        var onMetrics: (@Sendable (MetricsSnapshot) -> Void)?
        var onSourceStopped: (@Sendable ((any Error)?) -> Void)?
    }

    private struct ViewerReport {
        var lossPercent: Double?
        var completedFPS: Double?
        var receivedAtNanos: UInt64
    }

    let configuration: Configuration
    let source: any VideoSource
    let encoder: H264Encoder
    private let transport: any SessionTransport
    private let controlQueue = DispatchQueue(label: "com.swiftdesk.session.host.control", qos: .userInitiated)

    private let callbacks = Mutex(Callbacks())
    private let sender: Mutex<SenderState>
    private let keyframeLimiter = Mutex(KeyframeRequestLimiter())
    /// Packed `width << 32 | height` of the encoder session; frames of any other size are not submitted.
    private let encoderSize = Atomic<UInt64>(0)
    private let reconfigureScheduled = Atomic<Bool>(false)
    private let stopped = Atomic<Bool>(false)
    /// Target bitrate, mirrored for the encoder callback thread (adaptation itself is confined to `controlQueue`).
    private let targetBitrateKbps = Atomic<Int>(0)

    let rtt = RTTEstimator()
    private let sentFrames = RateCounter()
    private let sentBytes = RateCounter()
    private let captureToEncodeDone = RollingStats()
    private let hostPipeline = RollingStats()
    private let sendDrops = Atomic<UInt64>(0)
    private let keyframeRequestsReceived = Atomic<UInt64>(0)
    private let viewerFramesLost = Atomic<UInt64>(0)
    private let keyframesSent = Atomic<UInt64>(0)

    // Confined to `controlQueue`.
    private var adaptation: AdaptationController
    private var currentFPS: Int
    private var timer: (any DispatchSourceTimer)?
    private var tickCount: UInt64 = 0
    private var pingId: UInt32 = 0
    private var latestReport: ViewerReport?
    private var lastEncoderDrops: UInt64 = 0
    private var lastSendDrops: UInt64 = 0
    private var lastFailedReconfigure: (size: UInt64, atNanos: UInt64)?
    /// Display size in points as last reported in CONFIG (follows `displayChanged()`).
    private var displayPointSize: CGSize
    /// Size rung 0 encodes on the display; the ladder is resolved against it (see `displayChanged()`).
    private var nativeSize: (width: Int, height: Int)
    /// Signals of the latest adaptation decision (diagnostics only).
    private var lastSignals: AdaptationController.Signals = []

    init(configuration: Configuration, source: any VideoSource, transport: any SessionTransport) throws {
        self.configuration = configuration
        self.source = source
        self.transport = transport
        // Fit the ladder to what this source really produces: rung bitrate ranges follow the encoded size (a
        // 1600×900 display gets a 1600×900 ceiling, not a 1080p one) and rungs that collapse to the same size are
        // dropped. The source was created with rung 0's bounds, and capture never upscales, so fitting the lower rungs
        // against its output gives the same sizes as fitting them against the display.
        let predicted = source.outputSize
        let adaptation = AdaptationController(
            configuration: configuration.adaptation.resolved(sourceWidth: predicted.width, sourceHeight: predicted.height))
        self.adaptation = adaptation
        self.nativeSize = predicted
        self.displayPointSize = configuration.displayPointSize
        self.currentFPS = adaptation.rung.fps
        self.sender = Mutex(SenderState(packetizer: VideoPacketizer(sessionId: configuration.sessionId,
                                                                    maxDatagramSize: transport.maxDatagramSize),
                                        fec: FECPolicy(configuration: configuration.fec)))
        let size = Self.evenSize(source.outputSize)
        self.encoder = try H264Encoder(config: EncoderConfig(width: size.width, height: size.height,
                                                             fps: adaptation.rung.fps,
                                                             bitrateKbps: adaptation.bitrateKbps,
                                                             keyframeIntervalSeconds: configuration.keyframeIntervalSeconds))
        encoderSize.store(Self.pack(size.width, size.height), ordering: .releasing)
        targetBitrateKbps.store(adaptation.bitrateKbps, ordering: .relaxed)
    }

    /// 2 Hz metrics, delivered on the control queue.
    var onMetrics: (@Sendable (MetricsSnapshot) -> Void)? {
        get { callbacks.withLock { $0.onMetrics } }
        set { callbacks.withLock { $0.onMetrics = newValue } }
    }

    /// The source was stopped by the system (e.g. Screen Recording revoked). Delivered on the source's queue.
    var onSourceStopped: (@Sendable ((any Error)?) -> Void)? {
        get { callbacks.withLock { $0.onSourceStopped } }
        set { callbacks.withLock { $0.onSourceStopped = newValue } }
    }

    /// The capture configuration a source for this pipeline should be created with (first ladder rung).
    static func initialCaptureConfig(base: CaptureConfig, adaptation: AdaptationController.Configuration) -> CaptureConfig {
        let rung = AdaptationController(configuration: adaptation).rung
        var config = base
        config.maxWidth = rung.width
        config.maxHeight = rung.height
        config.fps = rung.fps
        return config
    }

    // MARK: Lifecycle

    /// Wires callbacks, starts the source, aligns the encoder with the real output size and sends CONFIG.
    func start() async throws {
        encoder.onEncodedFrame = { [weak self] frame in self?.encoded(frame) }
        source.onFrame = { [weak self] frame in self?.captured(frame) }
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
        await onControlQueue { [self] in
            reconfigureEncoder(to: Self.evenSize(source.outputSize), force: false)
            sendConfig()
            startTimer()
        }
    }

    /// Stops the source (no frame is delivered after this returns), the timer and the encoder. Idempotent.
    func stop() async {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        await onControlQueue { [self] in
            timer?.cancel()
            timer = nil
        }
        await source.stop()
        source.onFrame = nil
        source.onStopped = nil
        // `invalidate` waits for an in-flight frame to flush; keep that wait off the caller's executor.
        await onControlQueue { [self] in encoder.invalidate() }
        encoder.onEncodedFrame = nil
        onMetrics = nil
        onSourceStopped = nil
    }

    // MARK: Transport-queue entry points

    /// REQUEST_KEYFRAME from the Viewer, rate-limited (≥ 100 ms apart, and not right after a keyframe went out).
    func keyframeRequested() {
        keyframeRequestsReceived.add(1, ordering: .relaxed)
        let honor = keyframeLimiter.withLock { $0.shouldHonor(nowNanos: MonotonicClock.nowNanos()) }
        guard honor else { return }
        sender.withLock { $0.recoveryRequested = true }
        encoder.requestKeyframe()
    }

    /// PONG for one of our PINGs (the Viewer echoes the struct, so `sentAtNanos` is on our clock).
    func pong(_ ping: Ping) {
        let now = MonotonicClock.nowNanos()
        guard now >= ping.sentAtNanos else { return }
        rtt.add(sampleMillis: MonotonicClock.millis(now - ping.sentAtNanos))
    }

    func viewerStats(_ stats: ViewerStats) {
        let now = MonotonicClock.nowNanos()
        let total = UInt64(stats.packetsReceived) + UInt64(stats.packetsLost)
        let loss: Double? = total > 0 ? Double(stats.packetsLost) * 100 / Double(total) : nil
        let fps: Double? = stats.windowMillis > 0 ? Double(stats.framesCompleted) * 1000 / Double(stats.windowMillis) : nil
        viewerFramesLost.add(UInt64(stats.framesLost), ordering: .relaxed)
        if total > 0 { sender.withLock { _ = $0.fec.update(lossPercent: loss) } }
        controlQueue.async { [self] in
            latestReport = ViewerReport(lossPercent: loss, completedFPS: fps, receivedAtNanos: now)
        }
    }

    /// The Host's display changed (resolution, scaling, arrangement). ScreenCaptureKit keeps its configured output
    /// size and scales, so nothing would change until some later ladder step re-read the mode — at an arbitrary
    /// moment, against a ladder fitted to the old display, with the old display size in CONFIG. Instead: re-fit the
    /// ladder to the new native size (keeping the current rung and bitrate), re-apply the current rung, and send
    /// CONFIG with the live display size so the Viewer can resize its window. Cheap no-op if nothing relevant changed.
    func displayChanged() {
        controlQueue.async { [self] in handleDisplayChange() }
    }

    // MARK: Source queue

    private func captured(_ frame: CapturedFrame) {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let packed = Self.pack(width, height)
        guard packed == encoderSize.load(ordering: .acquiring) else {
            // Resolution changed (ladder step, display change). Only follow the source's *declared* size, so frames
            // still in flight from before an update cannot bounce the encoder back and forth.
            let declared = Self.evenSize(source.outputSize)
            if Self.pack(declared.width, declared.height) == packed,
               !reconfigureScheduled.exchange(true, ordering: .acquiringAndReleasing) {
                controlQueue.async { [self] in
                    reconfigureEncoder(to: (width, height), force: false)
                    reconfigureScheduled.store(false, ordering: .releasing)
                }
            }
            return
        }
        encoder.encode(frame.pixelBuffer, presentationTime: frame.presentationTime,
                       captureNanos: frame.captureNanos, sequence: frame.sequence)
    }

    // MARK: VideoToolbox callback thread

    private func encoded(_ frame: EncodedVideoFrame) {
        guard !stopped.load(ordering: .relaxed) else { return }
        if frame.encodeDoneNanos >= frame.captureNanos {
            captureToEncodeDone.add(MonotonicClock.millis(frame.encodeDoneNanos - frame.captureNanos))
        }
        let now = MonotonicClock.nowNanos()
        let pipelineMicros = now >= frame.captureNanos ? UInt32(clamping: (now - frame.captureNanos) / 1_000) : 0

        let budgetMillis = configuration.sendQueueBudgetMillis
        let bitrate = targetBitrateKbps.load(ordering: .relaxed)
        let prepared = sender.withLock { s -> (packets: [Data], frameId: UInt32, allowedAhead: Int, wasAwaiting: Bool)? in
            let wasAwaiting = s.awaitingKeyframe
            if s.awaitingKeyframe && !frame.isKeyframe {
                s.framesSkippedAwaitingKeyframe &+= 1
                return nil
            }
            var flags: VideoFlags = []
            if frame.isKeyframe {
                flags.insert(.keyframe)
                if s.recoveryRequested || s.awaitingKeyframe { flags.insert(.recovery) }
                s.awaitingKeyframe = false
                s.recoveryRequested = false
            }
            let frameId = s.nextFrameId
            s.nextFrameId &+= 1
            let sinceKeyframe = now >= s.lastKeyframeSentNanos ? now - s.lastKeyframeSentNanos : 0
            let allowedAhead = Self.allowedBacklogAhead(bitrateKbps: bitrate, budgetMillis: budgetMillis,
                                                        keyframeBatchBytes: s.lastKeyframeBatchBytes,
                                                        sinceKeyframeNanos: sinceKeyframe)
            do {
                let packets = try s.packetizer.packetize(frameId: frameId, frame: frame.data, flags: flags,
                                                         captureTimestampNanos: frame.captureNanos,
                                                         hostPipelineMicros: pipelineMicros,
                                                         fecGroupSize: s.fec.groupSize)
                return (packets, frameId, allowedAhead, wasAwaiting)
            } catch {
                // Oversized or empty access unit: skip it like a lost frame and recover with a keyframe.
                s.awaitingKeyframe = true
                return ([], frameId, allowedAhead, wasAwaiting)
            }
        }
        guard let prepared else { return }
        var packets = prepared.packets
        if frame.isKeyframe && configuration.duplicateKeyframePackets { packets.append(contentsOf: prepared.packets) }
        guard !packets.isEmpty, transport.sendDatagrams(packets, maxQueuedAheadBytes: prepared.allowedAhead) else {
            sendDrops.add(1, ordering: .relaxed)
            // First refusal: ask for a keyframe now. A refused recovery keyframe means the link is not draining
            // (blackout): let the control timer ask again instead of turning every captured frame into a keyframe.
            let retryLater = frame.isKeyframe && prepared.wasAwaiting
            sender.withLock { s in
                s.awaitingKeyframe = true
                if retryLater { s.keyframeRetryDue = true }
            }
            if !retryLater { encoder.requestKeyframe() }
            return
        }
        let doneNanos = MonotonicClock.nowNanos()
        sentFrames.record(1, now: doneNanos)
        sentBytes.record(UInt64(frame.data.count), now: doneNanos)
        if doneNanos >= frame.captureNanos {
            hostPipeline.add(MonotonicClock.millis(doneNanos - frame.captureNanos))
        }
        if frame.isKeyframe {
            keyframesSent.add(1, ordering: .relaxed)
            keyframeLimiter.withLock { $0.keyframeSent(atNanos: doneNanos) }
            var batchBytes = 0
            for packet in packets { batchBytes &+= packet.count }
            sender.withLock {
                $0.lastKeyframeBatchBytes = batchBytes
                $0.lastKeyframeSentNanos = doneNanos
            }
        }
        PipelineSignpost.sent(frame: UInt64(prepared.frameId), packets: packets.count)
    }

    // MARK: Control queue

    /// Upper bound of `KeyframeRequestLimiter.suppressAfterKeyframeNanos` (below `RecoveryGate`'s 500 ms re-request).
    static let maxKeyframeSuppressNanos: UInt64 = 400_000_000

    private func startTimer() {
        guard timer == nil, !stopped.load(ordering: .acquiring) else { return }
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        let interval = Int(configuration.metricsIntervalNanos)
        t.schedule(deadline: .now() + .nanoseconds(interval), repeating: .nanoseconds(interval),
                   leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard !stopped.load(ordering: .relaxed) else { return }
        tickCount &+= 1
        let now = MonotonicClock.nowNanos()
        pingId &+= 1
        transport.sendControl(.ping(Ping(id: pingId, sentAtNanos: now)))

        // Suppress keyframe re-requests for about one RTT after a keyframe went out (it is probably in flight).
        // Capped below the Viewer's 500 ms re-request interval: after a blackout the smoothed RTT carries the
        // seconds-old PINGs that waited out the outage, and an uncapped window would then ignore the Viewer's genuine
        // re-request for a lost recovery keyframe for seconds.
        let srtt = rtt.value.smoothedMillis
        let suppress = min(Self.maxKeyframeSuppressNanos, max(100_000_000, UInt64(max(0, srtt) * 1_000_000)))
        keyframeLimiter.withLock { $0.suppressAfterKeyframeNanos = suppress }
        let retryKeyframe = sender.withLock { s -> Bool in
            defer { s.keyframeRetryDue = false }
            return s.keyframeRetryDue && s.awaitingKeyframe
        }
        if retryKeyframe { encoder.requestKeyframe() }

        let ticksPerSecond = max(1, 1_000_000_000 / max(configuration.metricsIntervalNanos, 1))
        if tickCount % ticksPerSecond == 0 { adapt(now: now) }
        callbacks.withLock { $0.onMetrics }?(snapshot(now: now))
    }

    private func adapt(now: UInt64) {
        let encoderDrops = encoder.droppedForBackpressure
        let drops = sendDrops.load(ordering: .relaxed)
        defer {
            lastEncoderDrops = encoderDrops
            lastSendDrops = drops
        }
        let report = latestReport.flatMap { r -> ViewerReport? in
            now >= r.receivedAtNanos && now - r.receivedAtNanos < 2_500_000_000 ? r : nil
        }
        let r = rtt.value
        let inputs = AdaptationController.Inputs(
            nowNanos: now,
            lossPercent: report?.lossPercent,
            rttMillis: r.smoothedMillis > 0 ? r.smoothedMillis : nil,
            minRTTMillis: r.smoothedMillis > 0 ? r.minMillis : nil,
            sendBacklogBytes: transport.pendingDatagramBytes,
            encoderBackpressureDrops: encoderDrops &- lastEncoderDrops,
            sendBackpressureDrops: drops &- lastSendDrops,
            viewerFPS: report?.completedFPS,
            hostSentFPS: sentFrames.ratePerSecond(now: now))
        let decision = adaptation.update(inputs)
        lastSignals = decision.signals
        guard configuration.adaptationEnabled else { return }
        targetBitrateKbps.store(decision.bitrateKbps, ordering: .relaxed)
        if decision.rungChanged {
            Log.session.info("Adaptation: \(decision.rung.description, privacy: .public) at \(decision.bitrateKbps) kbps")
            apply(rung: decision.rung)
        } else if decision.bitrateChanged {
            encoder.setBitrate(kbps: decision.bitrateKbps)
            sendConfig()
        }
    }

    /// Ladder change: new capture bounds/fps on the source, then an encoder session for the new size/fps, then
    /// CONFIG. The encoder follows the source's declared output size (see `captured`), so frames of the old size
    /// that are still in flight are dropped rather than encoded at the wrong size. A rung that encodes the size and
    /// frame rate the encoder already has (possible right after a display change) only changes the bitrate: no
    /// encoder rebuild and no keyframe.
    private func apply(rung: AdaptationController.Rung) {
        currentFPS = rung.fps
        let config = captureConfig(for: rung)
        let source = self.source
        Task.detached { [weak self] in
            do {
                try await source.update(config: config)
            } catch {
                Log.session.error("Capture reconfiguration failed: \(String(describing: error), privacy: .public)")
            }
            guard let self else { return }
            self.controlQueue.async {
                guard !self.stopped.load(ordering: .relaxed) else { return }
                if !self.reconfigureEncoder(to: Self.evenSize(source.outputSize), force: false) {
                    self.encoder.setBitrate(kbps: self.adaptation.bitrateKbps)
                    self.sendConfig()
                }
            }
        }
    }

    private func handleDisplayChange() {
        guard !stopped.load(ordering: .relaxed) else { return }
        var changed = false
        let points = source.displayFrame.size
        if points.width > 0, points.height > 0, points != displayPointSize {
            displayPointSize = points
            changed = true
        }
        let ladder = configuration.adaptation.ladder
        if let top = ladder.first {
            let native = source.predictedOutputSize(for: captureConfig(for: top))
            if native.width > 0, native.height > 0, native != nativeSize {
                nativeSize = native
                let current = adaptation.rung
                let originalIndex = ladder.firstIndex { Self.sameBounds($0, current) } ?? 0
                var resolved = configuration.adaptation.resolved(sourceWidth: native.width, sourceHeight: native.height)
                // Rungs pruned for this display encode the same size as the kept rung above them: map onto that one.
                let index = resolved.ladder.lastIndex { kept in
                    (ladder.firstIndex { Self.sameBounds($0, kept) } ?? 0) <= originalIndex
                } ?? 0
                resolved.initialBitrateKbps = adaptation.bitrateKbps
                adaptation = AdaptationController(configuration: resolved, initialRungIndex: index)
                targetBitrateKbps.store(adaptation.bitrateKbps, ordering: .relaxed)
                Log.session.info("Display changed: native \(native.width)x\(native.height), ladder re-fitted at \(self.adaptation.rung.description, privacy: .public)")
                changed = true
            }
        }
        guard changed else { return }
        let rung = adaptation.rung
        let wanted = Self.evenSize(source.predictedOutputSize(for: captureConfig(for: rung)))
        let encoded = Self.unpack(encoderSize.load(ordering: .acquiring))
        if wanted != Self.evenSize(source.outputSize) || wanted != encoded || rung.fps != currentFPS {
            apply(rung: rung)   // sends CONFIG once the source and encoder follow
        } else {
            encoder.setBitrate(kbps: adaptation.bitrateKbps)
            sendConfig()
        }
    }

    private static func sameBounds(_ a: AdaptationController.Rung, _ b: AdaptationController.Rung) -> Bool {
        a.width == b.width && a.height == b.height && a.fps == b.fps
    }

    /// Recreates the encoder session for `size` at the current fps/bitrate (and sends CONFIG). Without `force` it is a
    /// no-op when the encoder already has that size and fps. Returns true if the encoder was recreated.
    @discardableResult
    private func reconfigureEncoder(to size: (width: Int, height: Int), force: Bool) -> Bool {
        guard !stopped.load(ordering: .relaxed), size.width > 0, size.height > 0 else { return false }
        let packed = Self.pack(size.width, size.height)
        let current = encoder.currentConfig
        if !force, packed == encoderSize.load(ordering: .acquiring), current.fps == currentFPS { return false }
        let now = MonotonicClock.nowNanos()
        if let failed = lastFailedReconfigure, failed.size == packed, now - failed.atNanos < 1_000_000_000 { return false }
        let config = EncoderConfig(width: size.width, height: size.height, fps: currentFPS,
                                   bitrateKbps: adaptation.bitrateKbps,
                                   keyframeIntervalSeconds: configuration.keyframeIntervalSeconds)
        do {
            try encoder.reconfigure(config)
            encoderSize.store(packed, ordering: .releasing)
            lastFailedReconfigure = nil
            Log.media.info("Encoder reconfigured to \(size.width)x\(size.height)@\(self.currentFPS)")
            sendConfig()
            return true
        } catch {
            lastFailedReconfigure = (packed, now)
            Log.media.error("Encoder reconfigure failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func sendConfig() {
        let size = Self.unpack(encoderSize.load(ordering: .acquiring))
        let config = StreamConfig(width: UInt16(clamping: size.width), height: UInt16(clamping: size.height),
                                  fps: UInt8(clamping: currentFPS), bitrateKbps: UInt32(clamping: adaptation.bitrateKbps),
                                  displayPointWidth: Float(displayPointSize.width),
                                  displayPointHeight: Float(displayPointSize.height),
                                  codec: StreamConfig.codecH264)
        transport.sendControl(.config(config))
    }

    private func captureConfig(for rung: AdaptationController.Rung) -> CaptureConfig {
        var config = configuration.baseCapture
        config.maxWidth = rung.width
        config.maxHeight = rung.height
        config.fps = rung.fps
        return config
    }

    /// Bytes that may already be queued in the transport ahead of a new frame: `budgetMillis` of video at the target
    /// bitrate, plus the part of the most recent keyframe batch that the link cannot have sent yet at that bitrate.
    ///
    /// The keyframe term matters: a duplicated 720p IDR is ~100 KB (a native 1600×900 / 1080p one, at its higher
    /// bitrate, ~150–300 KB), several hundred ms of video at the target bitrate, so a plain 80 ms bound would refuse
    /// every P-frame behind it, and each refusal requests another keyframe. Both terms scale with the bitrate, so the
    /// bound means the same staleness on every rung. If the link is
    /// slower than the bitrate, the allowance runs out before the keyframe drains and frames are refused — the queue
    /// is then genuinely stale, and adaptation sees the refusals.
    static func allowedBacklogAhead(bitrateKbps: Int, budgetMillis: Int, keyframeBatchBytes: Int,
                                    sinceKeyframeNanos: UInt64) -> Int {
        let bytesPerSecond = Double(max(1, bitrateKbps)) * 125
        let base = bytesPerSecond * Double(max(0, budgetMillis)) / 1000
        let drained = bytesPerSecond * Double(sinceKeyframeNanos) / 1_000_000_000
        let keyframeRemainder = max(0, Double(keyframeBatchBytes) - drained)
        return Int(min(base + keyframeRemainder, Double(Int.max / 2)))
    }

    /// FEC group size K the next frame will be sent with; 0 = no parity (tests / diagnostics).
    var fecGroupSize: Int { sender.withLock { $0.fec.groupSize } }

    /// Adaptation state (tests / diagnostics).
    var adaptationState: AdaptationController { controlQueue.sync { adaptation } }

    private func snapshot(now: UInt64) -> MetricsSnapshot {
        var m = MetricsSnapshot()
        m.rtt = rtt.value
        m.fps = sentFrames.ratePerSecond(now: now)
        m.bitrateKbps = sentBytes.ratePerSecond(now: now) * 8 / 1000
        m.targetBitrateKbps = Double(adaptation.bitrateKbps)
        if let report = latestReport, now - report.receivedAtNanos < 2_500_000_000 {
            m.packetLossPercent = report.lossPercent ?? 0
            m.receivedFPS = report.completedFPS ?? 0
        }
        m.framesLost = viewerFramesLost.load(ordering: .relaxed)
        m.framesDroppedBackpressure = encoder.droppedForBackpressure &+ sendDrops.load(ordering: .relaxed)
        m.keyframeRequests = keyframeRequestsReceived.load(ordering: .relaxed)
        m.captureToEncodeDone = captureToEncodeDone.summary()
        m.hostPipeline = hostPipeline.summary()
        let size = Self.unpack(encoderSize.load(ordering: .acquiring))
        m.width = size.width
        m.height = size.height
        m.configuredFPS = currentFPS
        m.hardwareEncoder = encoder.isHardwareAccelerated
        m.lowLatencyRateControl = encoder.lowLatencyRateControl
        m.sendBacklogBytes = transport.pendingDatagramBytes
        m.adaptationSignals = lastSignals.names
        m.sendBatchesRefused = sendDrops.load(ordering: .relaxed)
        m.encoderBackpressureDrops = encoder.droppedForBackpressure
        m.keyframes = keyframesSent.load(ordering: .relaxed)
        m.fecGroupSize = sender.withLock { $0.fec.groupSize }
        return m
    }

    // MARK: Helpers

    private func onControlQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                body()
                continuation.resume()
            }
        }
    }

    static func pack(_ width: Int, _ height: Int) -> UInt64 {
        UInt64(UInt32(clamping: width)) << 32 | UInt64(UInt32(clamping: height))
    }

    static func unpack(_ packed: UInt64) -> (width: Int, height: Int) {
        (Int(packed >> 32), Int(packed & 0xFFFF_FFFF))
    }

    /// Encoder dimensions must be even and positive; captures already are, this only guards odd inputs.
    static func evenSize(_ size: (width: Int, height: Int)) -> (width: Int, height: Int) {
        (max(2, size.width & ~1), max(2, size.height & ~1))
    }
}
