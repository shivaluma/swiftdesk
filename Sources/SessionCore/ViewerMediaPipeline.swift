import CodecCore
import DiagnosticsCore
import Foundation
import RenderCore
import Synchronization
import WireProtocol

/// The Viewer's hot path for one session: datagram → `Datagram.parse` → `FrameReassembler` → `RecoveryGate` →
/// `H264Decoder` → frame sink (Metal view), all on one dedicated serial receive queue.
///
/// Why one queue: the reassembler and gate are single-queue types, and decoding synchronously right after reassembly
/// keeps ordering trivial and adds no second hand-off (PRD §6 rule 7). The transport queue only appends each datagram
/// to a lock-protected inbox and schedules a drain when the inbox goes from empty to non-empty — no closure allocation
/// per datagram, and a burst (a keyframe's ~100 packets) is processed in one drain. The inbox is bounded, so a stalled
/// decoder sheds input instead of growing memory.
///
/// A 15 ms timer on the same queue expires stale partial frames, re-sends keyframe requests (`RecoveryGate.tick`),
/// sends PING every 500 ms, STATS every 1 s and publishes metrics at 2 Hz.
///
/// FEC: parity datagrams go to the same reassembler, which rebuilds a single lost fragment per group immediately, so
/// such a loss never reaches the gate. STATS report the loss the reassembler saw (rebuilt fragments + frames that
/// still failed), which drives the Host's choice of parity overhead.
///
/// Recovery: any loss or decode failure gates the decoder until the next keyframe and asks the Host for one
/// (rate-limited by the gate). A loss reported in the same batch right before a keyframe does not trigger a request,
/// because that keyframe already repairs it. While no datagram arrives the gate backs its re-requests off (1, 2, 4 s)
/// instead of queueing one every 500 ms behind a dead link, so a blackout ends with one request, not dozens.
///
/// Stalls (0.1.4): the same timer watches `activity` (every control message or datagram from the Host). After 1 s of
/// silence it reports `onLinkStall(true)` — the UI dims the last frame and shows "Poor connection" — and
/// `onLinkStall(false)` once anything arrives again. The Host pings every 500 ms, so a static screen is not a stall.
final class ViewerMediaPipeline: @unchecked Sendable {
    static let timerIntervalNanos: UInt64 = 15_000_000
    static let maxInboxDatagrams = 4096

    private struct Inbox {
        var items: [Data] = []
        var scheduled = false
        var closed = false
        var dropped: UInt64 = 0
    }

    private struct PresentWindow {
        var count: UInt32 = 0
        var sumMicros: UInt64 = 0
    }

    private struct Callbacks {
        var onMetrics: (@Sendable (MetricsSnapshot) -> Void)?
        var onLinkStall: (@Sendable (Bool) -> Void)?
    }

    /// Silence after which the link counts as stalled.
    static let stallThresholdNanos: UInt64 = 1_000_000_000
    /// Cap of the keyframe re-request interval while nothing arrives.
    static let maxSilentRerequestNanos: UInt64 = 4_000_000_000

    let sessionId: UInt32
    let queue = DispatchQueue(label: "com.swiftdesk.session.viewer.receive", qos: .userInteractive)
    private let transport: any SessionTransport
    private let sinkSlot: FrameSinkSlot
    private let activity: LinkActivity

    private let inbox = Mutex(Inbox())
    private let callbacks = Mutex(Callbacks())
    private let presentWindow = Mutex(PresentWindow())
    private let streamConfig = Mutex<StreamConfig?>(nil)

    let rtt = RTTEstimator()
    private let receivedFrames = RateCounter()
    private let decodedFrames = RateCounter()
    private let presentedFrames = RateCounter()
    private let receivedBytes = RateCounter()
    private let networkToDecodeDone = RollingStats()
    private let decodeToPresent = RollingStats()
    private let hostPipeline = RollingStats()
    private let keyframeRequestsSent = Atomic<UInt64>(0)
    private let framesDecodedTotal = Atomic<UInt64>(0)
    private let framesPresentedTotal = Atomic<UInt64>(0)
    private let keyframesReceived = Atomic<UInt64>(0)
    private let lossPercentBits = Atomic<UInt64>(0.0.bitPattern)

    // Confined to `queue`.
    private let reassembler: FrameReassembler
    private var gate = RecoveryGate(maxSilentRerequestIntervalNanos: ViewerMediaPipeline.maxSilentRerequestNanos)
    private var stall = LinkSilenceDetector(thresholdNanos: ViewerMediaPipeline.stallThresholdNanos)
    private let decoder = H264Decoder()
    private var drainBuffer: [Data] = []
    private var timer: (any DispatchSourceTimer)?
    private var lastDecodeDoneNanos: UInt64 = 0
    private var decodeWindowSumMicros: UInt64 = 0
    private var decodeWindowCount: UInt32 = 0
    private var lastStatsNanos: UInt64 = 0
    private var lastStats = FrameReassembler.Stats()
    private var lastPingNanos: UInt64 = 0
    private var lastMetricsNanos: UInt64 = 0
    private var pingId: UInt32 = 0
    private var malformedDatagrams: UInt64 = 0
    private var framesGated: UInt64 = 0
    private var running = false

    init(sessionId: UInt32, transport: any SessionTransport, sinkSlot: FrameSinkSlot,
         activity: LinkActivity = LinkActivity()) {
        self.sessionId = sessionId
        self.transport = transport
        self.sinkSlot = sinkSlot
        self.activity = activity
        self.reassembler = FrameReassembler(config: FrameReassembler.Config(sessionId: sessionId))
        drainBuffer.reserveCapacity(256)
        decoder.onDecodedFrame = { [weak self] frame in self?.decoded(frame) }
    }

    /// 2 Hz metrics, delivered on the receive queue.
    var onMetrics: (@Sendable (MetricsSnapshot) -> Void)? {
        get { callbacks.withLock { $0.onMetrics } }
        set { callbacks.withLock { $0.onMetrics = newValue } }
    }

    /// Stall transitions (true: nothing from the Host for 1 s; false: heard again), on the receive queue.
    var onLinkStall: (@Sendable (Bool) -> Void)? {
        get { callbacks.withLock { $0.onLinkStall } }
        set { callbacks.withLock { $0.onLinkStall = newValue } }
    }

    func start() {
        queue.async { [self] in
            guard !running, !inbox.withLock({ $0.closed }) else { return }
            running = true
            let now = MonotonicClock.nowNanos()
            lastStatsNanos = now
            lastPingNanos = now
            lastMetricsNanos = now
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now() + .nanoseconds(Int(Self.timerIntervalNanos)),
                       repeating: .nanoseconds(Int(Self.timerIntervalNanos)), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    /// Stops processing. Pending datagrams are discarded and no frame is delivered to the sink afterwards.
    func stop() {
        inbox.withLock { b in
            b.closed = true
            b.items.removeAll()
        }
        onMetrics = nil
        onLinkStall = nil
        queue.async { [self] in
            running = false
            timer?.cancel()
            timer = nil
            reassembler.reset()
            decoder.reset()
            decoder.onDecodedFrame = nil
        }
    }

    // MARK: Transport-queue entry points

    /// Called for every received datagram. O(1): append and, if needed, schedule one drain.
    func ingest(_ datagram: Data) {
        let schedule = inbox.withLock { b -> Bool in
            guard !b.closed else { return false }
            guard b.items.count < Self.maxInboxDatagrams else {
                b.dropped &+= 1
                return false
            }
            b.items.append(datagram)
            guard !b.scheduled else { return false }
            b.scheduled = true
            return true
        }
        if schedule {
            queue.async { [self] in drain() }
        }
    }

    func pong(_ ping: Ping) {
        let now = MonotonicClock.nowNanos()
        guard now >= ping.sentAtNanos else { return }
        rtt.add(sampleMillis: MonotonicClock.millis(now - ping.sentAtNanos))
    }

    func configure(_ config: StreamConfig) {
        streamConfig.withLock { $0 = config }
    }

    /// From the Metal presented handler (any thread).
    func notePresented(_ info: PresentedFrameInfo) {
        let now = MonotonicClock.nowNanos()
        presentedFrames.record(1, now: now)
        framesPresentedTotal.add(1, ordering: .relaxed)
        decodeToPresent.add(MonotonicClock.millis(info.decodeToPresentNanos))
        presentWindow.withLock { w in
            w.count &+= 1
            w.sumMicros &+= info.decodeToPresentNanos / 1_000
        }
    }

    var framesDecoded: UInt64 { framesDecodedTotal.load(ordering: .relaxed) }

    /// Receive-path health counters, read on the receive queue (diagnostics and tests; never per frame).
    struct HealthCounters: Sendable, Equatable {
        var malformedDatagrams: UInt64
        var inboxDropped: UInt64
        var inboxQueued: Int
        var framesGated: UInt64
        var reassembly: FrameReassembler.Stats
    }

    /// Blocks until every datagram queued so far has been processed, then snapshots the counters.
    func healthCounters() -> HealthCounters {
        queue.sync {
            let box = inbox.withLock { (dropped: $0.dropped, queued: $0.items.count) }
            return HealthCounters(malformedDatagrams: malformedDatagrams, inboxDropped: box.dropped,
                                  inboxQueued: box.queued, framesGated: framesGated, reassembly: reassembler.stats)
        }
    }

    // MARK: Receive queue

    private func drain() {
        inbox.withLock { b in
            swap(&b.items, &drainBuffer)
            b.scheduled = false
        }
        guard running else {
            drainBuffer.removeAll(keepingCapacity: true)
            return
        }
        if !drainBuffer.isEmpty { gate.noteTraffic() }
        var bytes: UInt64 = 0
        for datagram in drainBuffer {
            bytes &+= UInt64(datagram.count)
            guard let parsed = try? Datagram.parse(datagram) else {
                malformedDatagrams &+= 1
                continue
            }
            let events: [ReassemblyEvent]
            switch parsed {
            case .video(let header, let payload):
                events = reassembler.ingest(header: header, payload: payload, nowNanos: MonotonicClock.nowNanos())
            case .parity(let header, let payload):
                events = reassembler.ingestParity(header: header, payload: payload, nowNanos: MonotonicClock.nowNanos())
            case .pointer:
                continue
            }
            if !events.isEmpty { handle(events) }
        }
        drainBuffer.removeAll(keepingCapacity: true)
        if bytes > 0 { receivedBytes.record(bytes) }
    }

    private func handle(_ events: [ReassemblyEvent]) {
        for (index, event) in events.enumerated() {
            switch event {
            case .framesLost:
                let now = MonotonicClock.nowNanos()
                let shouldRequest = gate.onLoss(nowNanos: now)
                var repairedByNext = false
                if index + 1 < events.count, case .frameComplete(let next) = events[index + 1],
                   next.flags.contains(.keyframe) {
                    repairedByNext = true
                }
                if shouldRequest && !repairedByNext { requestKeyframe(.frameLoss) }
            case .frameComplete(let frame):
                deliver(frame)
            }
        }
    }

    private func deliver(_ frame: EncodedFrame) {
        receivedFrames.record(1, now: frame.completedAtNanos)
        hostPipeline.add(Double(frame.hostPipelineMicros) / 1_000)
        PipelineSignpost.received(frame: UInt64(frame.frameId), bytes: frame.data.count)
        if frame.flags.contains(.keyframe) { keyframesReceived.add(1, ordering: .relaxed) }
        guard gate.admit(flags: frame.flags) else {
            framesGated &+= 1
            return
        }
        let ok = decoder.decode(frame.data, frameId: frame.frameId, captureNanos: frame.captureTimestampNanos,
                                receivedNanos: frame.firstPacketAtNanos)
        if ok {
            if lastDecodeDoneNanos >= frame.completedAtNanos {
                decodeWindowSumMicros &+= (lastDecodeDoneNanos - frame.completedAtNanos) / 1_000
                decodeWindowCount &+= 1
            }
        } else if gate.onDecodeError(nowNanos: MonotonicClock.nowNanos()) {
            requestKeyframe(.decodeError)
        }
    }

    /// Synchronous decoder output (still on the receive queue).
    private func decoded(_ frame: DecodedFrame) {
        lastDecodeDoneNanos = frame.decodeDoneNanos
        framesDecodedTotal.add(1, ordering: .relaxed)
        decodedFrames.record(1, now: frame.decodeDoneNanos)
        if frame.decodeDoneNanos >= frame.receivedNanos {
            networkToDecodeDone.add(MonotonicClock.millis(frame.decodeDoneNanos - frame.receivedNanos))
        }
        sinkSlot.deliver(SessionRenderFrame(pixelBuffer: frame.pixelBuffer, frameId: frame.frameId,
                                            decodeDoneNanos: frame.decodeDoneNanos))
    }

    private func requestKeyframe(_ reason: KeyframeRequestReason) {
        keyframeRequestsSent.add(1, ordering: .relaxed)
        transport.sendControl(.requestKeyframe(reason: reason.rawValue))
    }

    private func tick() {
        guard running else { return }
        let now = MonotonicClock.nowNanos()
        let expired = reassembler.expire(nowNanos: now)
        if !expired.isEmpty { handle(expired) }
        if gate.tick(nowNanos: now) { requestKeyframe(.stillWaiting) }
        if let change = stall.update(lastHeardNanos: activity.lastHeardNanos, nowNanos: now) {
            callbacks.withLock { $0.onLinkStall }?(change == .silent)
        }

        if now - lastPingNanos >= 500_000_000 {
            lastPingNanos = now
            pingId &+= 1
            transport.sendControl(.ping(Ping(id: pingId, sentAtNanos: now)))
        }
        if now - lastStatsNanos >= 1_000_000_000 {
            sendStats(now: now)
        }
        if now - lastMetricsNanos >= 500_000_000 {
            lastMetricsNanos = now
            callbacks.withLock { $0.onMetrics }?(snapshot(now: now))
        }
    }

    private func sendStats(now: UInt64) {
        let s = reassembler.stats
        let completed = s.framesCompleted &- lastStats.framesCompleted
        let lost = s.framesLost &- lastStats.framesLost
        // Datagram loss = fragments rebuilt from parity (each one exactly one lost datagram) + frames that never
        // completed × the average datagrams per frame in this window (`FrameReassembler.Stats.lossEstimate`).
        let estimate = s.lossEstimate(since: lastStats)
        let packets = estimate.received
        let estimatedLostPackets = estimate.lost
        let window = (now - lastStatsNanos) / 1_000_000
        let presented = presentWindow.withLock { w -> PresentWindow in
            defer { w = PresentWindow() }
            return w
        }
        let stats = ViewerStats(
            windowMillis: UInt32(clamping: window),
            packetsReceived: UInt32(clamping: packets),
            packetsLost: UInt32(clamping: estimatedLostPackets),
            framesCompleted: UInt32(clamping: completed),
            framesLost: UInt32(clamping: lost),
            framesPresented: presented.count,
            decodeMicrosAvg: decodeWindowCount > 0 ? UInt32(clamping: decodeWindowSumMicros / UInt64(decodeWindowCount)) : 0,
            decodeToPresentMicrosAvg: presented.count > 0 ? UInt32(clamping: presented.sumMicros / UInt64(presented.count)) : 0)
        transport.sendControl(.stats(stats))
        let total = packets + estimatedLostPackets
        let loss = total > 0 ? Double(estimatedLostPackets) * 100 / Double(total) : 0
        lossPercentBits.store(loss.bitPattern, ordering: .relaxed)
        lastStats = s
        lastStatsNanos = now
        decodeWindowSumMicros = 0
        decodeWindowCount = 0
    }

    private func snapshot(now: UInt64) -> MetricsSnapshot {
        var m = MetricsSnapshot()
        m.rtt = rtt.value
        // On-glass rate when a Metal view reports presents; otherwise (headless sink) the decoded rate.
        m.fps = framesPresentedTotal.load(ordering: .relaxed) > 0
            ? presentedFrames.ratePerSecond(now: now) : decodedFrames.ratePerSecond(now: now)
        m.receivedFPS = receivedFrames.ratePerSecond(now: now)
        m.bitrateKbps = receivedBytes.ratePerSecond(now: now) * 8 / 1_000
        m.packetLossPercent = Double(bitPattern: lossPercentBits.load(ordering: .relaxed))
        m.framesLost = reassembler.stats.framesLost
        m.keyframeRequests = keyframeRequestsSent.load(ordering: .relaxed)
        m.keyframes = keyframesReceived.load(ordering: .relaxed)
        m.fragmentsRecovered = reassembler.stats.fragmentsRecovered
        m.networkToDecodeDone = networkToDecodeDone.summary()
        m.decodeToPresent = decodeToPresent.summary()
        m.hostPipeline = hostPipeline.summary()
        if let config = streamConfig.withLock({ $0 }) {
            m.width = Int(config.width)
            m.height = Int(config.height)
            m.configuredFPS = Int(config.fps)
            m.targetBitrateKbps = Double(config.bitrateKbps)
        }
        m.hardwareEncoder = nil
        return m
    }
}
