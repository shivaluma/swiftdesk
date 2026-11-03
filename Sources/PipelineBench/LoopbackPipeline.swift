import CodecCore
import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization
import WireProtocol

/// Host and Viewer halves of a SwiftDesk session wired back-to-back in one process, minus the network.
///
/// Stage layout (each arrow is the *only* hand-off, and the queues are the ones the real app uses):
///
///     source queue ── encode() ──▶ VideoToolbox ──▶ encoder callback ──async──▶ sender queue
///         (packetize, simulated loss) ──async──▶ viewer queue (parse, reassemble, gate, decode, expire timer)
///
/// Why this shape: it measures exactly the work the Host and Viewer do per frame, with the same one-in-flight encoder
/// rule, the same 32-byte datagram framing at the transport MTU, and the same loss → `REQUEST_KEYFRAME` → IDR
/// recovery loop, so its numbers are the pipeline's floor before network RTT and display refresh are added. The
/// encoder callback only stamps timings and hops to the sender queue, because the encoder slot is released only
/// after the callback returns — doing packetize/decode inline would turn codec-adjacent work into backpressure drops.
///
/// Synchronization: per-stage state is confined to its queue (sender: frame ids, packetizer, loss RNG; viewer:
/// reassembler, gate, recovery episode). Cross-queue communication is the `async` hand-offs plus atomics
/// (`recoveryPending`, counters). Latency series are `Mutex`-guarded and read only after `finish()`.
final class LoopbackPipeline: @unchecked Sendable {
    struct Config: Sendable {
        var width: Int
        var height: Int
        var fps: Int
        var bitrateKbps: Int
        var lossPercent: Double
        var seed: UInt64
        var maxDatagramSize: Int
        var expectedFrames: Int
        /// Mirror of SessionCore's `duplicateKeyframePackets`: every keyframe datagram is offered to the loss
        /// simulator twice, so a keyframe fragment is lost only if both copies are.
        var duplicateKeyframes = false
        /// Parity datagrams (`FECLayout`); `.enabled == false` sends none.
        var fec = FECPolicy.Configuration.off
        var sessionId: UInt32 = 0x5D1A_B00C
    }

    /// Everything measured during a run; latency series are in milliseconds.
    final class Metrics: Sendable {
        let framesSubmitted = Counter()
        let framesSizeMismatch = Counter()
        let framesEncoded = Counter()
        let keyframesEncoded = Counter()
        let recoveryKeyframes = Counter()
        let encodedBytes = Counter()
        let packetizeErrors = Counter()
        let datagramsSent = Counter()
        let datagramBytes = Counter()
        let datagramsDropped = Counter()
        let datagramParseErrors = Counter()
        let framesReassembled = Counter()
        let framesLost = Counter()
        let lossEvents = Counter()
        let framesGated = Counter()
        let framesDecoded = Counter()
        let decodeFailures = Counter()
        let decodeErrorCallbacks = Counter()
        let keyframeRequests = Counter()
        let keyframeRerequests = Counter()
        let parityDatagrams = Counter()
        /// Sum of the K used per sent frame (0 for frames without parity), for the mean.
        let fecGroupSizeSum = Counter()
        let framesWithParity = Counter()

        let sourceToEncodeDone: SampleSeries
        let encodeSubmitToDone: SampleSeries
        let encodeDoneToPacketized: SampleSeries
        let packetizedToReassembled: SampleSeries
        let reassembledToDecodeDone: SampleSeries
        let sourceToDecodeDone: SampleSeries
        let recoveryTime: SampleSeries

        init(expectedFrames n: Int) {
            sourceToEncodeDone = SampleSeries(expected: n)
            encodeSubmitToDone = SampleSeries(expected: n)
            encodeDoneToPacketized = SampleSeries(expected: n)
            packetizedToReassembled = SampleSeries(expected: n)
            reassembledToDecodeDone = SampleSeries(expected: n)
            sourceToDecodeDone = SampleSeries(expected: n)
            recoveryTime = SampleSeries(expected: 256)
        }
    }

    let config: Config
    let encoder: H264Encoder
    let decoder = H264Decoder()
    let metrics: Metrics

    private let senderQueue = DispatchQueue(label: "com.swiftdesk.bench.sender", qos: .userInteractive)
    private let viewerQueue = DispatchQueue(label: "com.swiftdesk.bench.viewer", qos: .userInteractive)
    /// Set when the viewer asks for a keyframe; the next IDR the sender sees is tagged `.recovery`.
    private let recoveryPending = Atomic<Bool>(false)
    /// Viewer → sender loss feedback (stands in for STATS): percent as `Double` bits, and a report counter.
    private let reportedLossBits = Atomic<UInt64>(0)
    private let lossReports = Atomic<UInt64>(0)
    private let expiryTimer: any DispatchSourceTimer

    // Sender-queue confined.
    private let packetizer: VideoPacketizer
    private var nextFrameId: UInt32 = 0
    private var loss: LossSimulator
    private var fecPolicy: FECPolicy
    private var lossReportsSeen: UInt64 = 0

    // Viewer-queue confined.
    private let reassembler: FrameReassembler
    private var gate = RecoveryGate()
    /// Viewer time at which the current loss episode started (first loss while decoding normally), nil when healthy.
    private var episodeStartNanos: UInt64?
    /// Set by the (synchronous) decode callback so the caller can attribute recovery to the decoded keyframe.
    private var lastDecodeDoneNanos: UInt64 = 0
    private var lastLossReportNanos: UInt64 = 0
    private var lastLossStats = FrameReassembler.Stats()

    init(config: Config) throws {
        self.config = config
        metrics = Metrics(expectedFrames: config.expectedFrames)
        encoder = try H264Encoder(config: EncoderConfig(width: config.width, height: config.height, fps: config.fps,
                                                        bitrateKbps: config.bitrateKbps))
        packetizer = VideoPacketizer(sessionId: config.sessionId, maxDatagramSize: config.maxDatagramSize)
        loss = LossSimulator(lossPercent: config.lossPercent, seed: config.seed)
        fecPolicy = FECPolicy(configuration: config.fec)
        reassembler = FrameReassembler(config: FrameReassembler.Config(sessionId: config.sessionId))
        expiryTimer = DispatchSource.makeTimerSource(flags: [], queue: viewerQueue)

        let metrics = self.metrics
        encoder.onEncodedFrame = { [weak self] frame in
            metrics.sourceToEncodeDone.add(from: frame.captureNanos, to: frame.encodeDoneNanos)
            if frame.encodeSubmitNanos > 0 {
                metrics.encodeSubmitToDone.add(from: frame.encodeSubmitNanos, to: frame.encodeDoneNanos)
            }
            metrics.framesEncoded.add()
            metrics.encodedBytes.add(UInt64(frame.data.count))
            if frame.isKeyframe { metrics.keyframesEncoded.add() }
            guard let self else { return }
            self.senderQueue.async { self.send(frame) }
        }
        decoder.onDecodedFrame = { [weak self] frame in
            // Runs synchronously inside `decode` on the viewer queue.
            metrics.framesDecoded.add()
            metrics.reassembledToDecodeDone.add(from: frame.receivedNanos, to: frame.decodeDoneNanos)
            metrics.sourceToDecodeDone.add(from: frame.captureNanos, to: frame.decodeDoneNanos)
            self?.lastDecodeDoneNanos = frame.decodeDoneNanos
        }
        decoder.onError = { _ in metrics.decodeErrorCallbacks.add() }

        // FrameReassembler.expire / RecoveryGate.tick cadence recommended by the contract (10–20 ms).
        expiryTimer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        expiryTimer.setEventHandler { [weak self] in self?.periodic() }
        expiryTimer.resume()
    }

    // MARK: Source side (source / capture queue)

    /// Non-blocking hand-off from the frame source. Drops (and counts) frames whose size does not match the encoder
    /// session, which can happen transiently in capture mode around a display mode change.
    @inline(__always)
    func submit(_ buffer: CVPixelBuffer, presentationTime: CMTime, captureNanos: UInt64, sequence: UInt64) {
        guard CVPixelBufferGetWidth(buffer) == config.width, CVPixelBufferGetHeight(buffer) == config.height else {
            metrics.framesSizeMismatch.add()
            return
        }
        if encoder.encode(buffer, presentationTime: presentationTime, captureNanos: captureNanos, sequence: sequence) {
            metrics.framesSubmitted.add()
        }
    }

    // MARK: Sender queue

    private func send(_ frame: EncodedVideoFrame) {
        nextFrameId &+= 1
        var flags: VideoFlags = frame.isKeyframe ? .keyframe : []
        if frame.isKeyframe, recoveryPending.exchange(false, ordering: .acquiringAndReleasing) {
            flags.insert(.recovery)
            metrics.recoveryKeyframes.add()
        }
        let reports = lossReports.load(ordering: .acquiring)
        if reports != lossReportsSeen {
            lossReportsSeen = reports
            fecPolicy.update(lossPercent: Double(bitPattern: reportedLossBits.load(ordering: .relaxed)))
        }
        let k = fecPolicy.groupSize
        let start = MonotonicClock.nowNanos()
        let hostMicros = UInt32(clamping: (start &- frame.captureNanos) / 1_000)
        let datagrams: [Data]
        do {
            datagrams = try packetizer.packetize(frameId: nextFrameId, frame: frame.data, flags: flags,
                                                 captureTimestampNanos: frame.captureNanos, hostPipelineMicros: hostMicros,
                                                 fecGroupSize: k)
        } catch {
            metrics.packetizeErrors.add()
            return
        }
        let packetized = MonotonicClock.nowNanos()
        metrics.encodeDoneToPacketized.add(from: frame.encodeDoneNanos, to: packetized)
        if k > 0 {
            metrics.framesWithParity.add()
            metrics.fecGroupSizeSum.add(UInt64(k))
            metrics.parityDatagrams.add(UInt64(packetizer.parityCount(forFrameBytes: frame.data.count, fecGroupSize: k)))
        }

        let copies = config.duplicateKeyframes && frame.isKeyframe ? 2 : 1
        var delivered = datagrams
        if loss.probability > 0 || copies > 1 {
            delivered = []
            delivered.reserveCapacity(datagrams.count * copies)
            for _ in 0..<copies {
                for datagram in datagrams {
                    if loss.shouldDrop() { metrics.datagramsDropped.add() } else { delivered.append(datagram) }
                }
            }
        }
        metrics.datagramsSent.add(UInt64(datagrams.count * copies))
        var bytes = 0
        for datagram in datagrams { bytes &+= datagram.count }
        metrics.datagramBytes.add(UInt64(bytes * copies))

        guard !delivered.isEmpty else { return }
        let frameId = nextFrameId
        let batch = delivered
        viewerQueue.async { self.receive(batch, frameId: frameId, packetizedNanos: packetized) }
    }

    // MARK: Viewer queue

    private func receive(_ datagrams: [Data], frameId: UInt32, packetizedNanos: UInt64) {
        for datagram in datagrams {
            // Parse like the real receive path (zero-copy payload slice), rather than trusting sender-side structs.
            guard let parsed = try? Datagram.parse(datagram) else {
                metrics.datagramParseErrors.add()
                continue
            }
            let now = MonotonicClock.nowNanos()
            let events = reassembler.ingest(parsed, nowNanos: now)
            if !events.isEmpty { handle(events, batchFrameId: frameId, packetizedNanos: packetizedNanos) }
        }
    }

    private func periodic() {
        let now = MonotonicClock.nowNanos()
        let events = reassembler.expire(nowNanos: now)
        if !events.isEmpty { handle(events, batchFrameId: 0, packetizedNanos: 0) }
        if gate.tick(nowNanos: now) {
            metrics.keyframeRerequests.add()
            requestKeyframe()
        }
        // Loss feedback once per second, computed exactly like the Viewer's STATS (`lossEstimate`).
        if lastLossReportNanos == 0 { lastLossReportNanos = now }
        if now - lastLossReportNanos >= 1_000_000_000 {
            let stats = reassembler.stats
            let estimate = stats.lossEstimate(since: lastLossStats)
            let total = estimate.received + estimate.lost
            let percent = total > 0 ? Double(estimate.lost) * 100 / Double(total) : 0
            reportedLossBits.store(percent.bitPattern, ordering: .relaxed)
            lossReports.add(1, ordering: .releasing)
            lastLossStats = stats
            lastLossReportNanos = now
        }
    }

    private func handle(_ events: [ReassemblyEvent], batchFrameId: UInt32, packetizedNanos: UInt64) {
        for event in events {
            switch event {
            case .framesLost(let count):
                metrics.framesLost.add(UInt64(count))
                metrics.lossEvents.add()
                beginRecovery(now: MonotonicClock.nowNanos(), decodeError: false)
            case .frameComplete(let frame):
                metrics.framesReassembled.add()
                if frame.frameId == batchFrameId, packetizedNanos > 0 {
                    metrics.packetizedToReassembled.add(from: packetizedNanos, to: frame.completedAtNanos)
                }
                decode(frame)
            }
        }
    }

    private func decode(_ frame: EncodedFrame) {
        guard gate.admit(flags: frame.flags) else {
            metrics.framesGated.add()
            return
        }
        lastDecodeDoneNanos = 0
        let ok = decoder.decode(frame.data, frameId: frame.frameId, captureNanos: frame.captureTimestampNanos,
                                receivedNanos: frame.completedAtNanos)
        guard ok else {
            // Covers both VideoToolbox errors (onError fired) and rejected input: either way the reference chain is
            // unusable until the next IDR.
            metrics.decodeFailures.add()
            beginRecovery(now: MonotonicClock.nowNanos(), decodeError: true)
            return
        }
        if frame.flags.contains(.keyframe), let start = episodeStartNanos, lastDecodeDoneNanos != 0 {
            metrics.recoveryTime.add(from: start, to: lastDecodeDoneNanos)
            episodeStartNanos = nil
        }
    }

    private func beginRecovery(now: UInt64, decodeError: Bool) {
        if episodeStartNanos == nil { episodeStartNanos = now }
        let send = decodeError ? gate.onDecodeError(nowNanos: now) : gate.onLoss(nowNanos: now)
        if send { requestKeyframe() }
    }

    /// Simulated REQUEST_KEYFRAME: zero network delay, straight to the encoder.
    private func requestKeyframe() {
        metrics.keyframeRequests.add()
        recoveryPending.store(true, ordering: .releasing)
        encoder.requestKeyframe()
    }

    // MARK: Shutdown

    /// Call after the source has stopped. Flushes the in-flight encode, drains both queues, stops the expiry timer.
    /// Afterwards every metric is final.
    func finish() {
        encoder.invalidate()         // emits the in-flight frame through the callback first
        senderQueue.sync {}          // all encoded frames packetized and handed to the viewer
        viewerQueue.sync {}          // all datagrams ingested and decoded
        expiryTimer.cancel()
        viewerQueue.sync {}
        encoder.onEncodedFrame = nil // break the encoder → closure → pipeline cycle
        decoder.onDecodedFrame = nil
        decoder.onError = nil
    }

    /// Viewer-side reassembly counters (read after `finish`).
    var reassemblyStats: FrameReassembler.Stats { viewerQueue.sync { reassembler.stats } }
    /// K the sender would use for the next frame (read after `finish`).
    var finalFECGroupSize: Int { senderQueue.sync { fecPolicy.groupSize } }
    /// True if the run ended in the middle of a loss episode (no keyframe decoded since the last loss).
    var endedAwaitingKeyframe: Bool { viewerQueue.sync { gate.awaitingKeyframe } }
}
