import CoreMedia
import CoreVideo
import DiagnosticsCore
import Foundation
import Synchronization
import VideoToolbox

/// Hardware H.264 encoder tuned for interactive latency rather than quality.
///
/// Design:
/// - **One frame in flight, latest frame wins.** At most one frame is inside VideoToolbox at any time. A frame
///   arriving while another is in flight is never queued behind it: `encode` returns false (counted in
///   `droppedForBackpressure`) and the frame only takes the single latest-frame slot, replacing any older frame
///   there. In a live stream the next capture supersedes it, exactly as a plain drop would; but if no newer capture
///   arrives (the screen went static — ScreenCaptureKit sends nothing for unchanged content), it is submitted after a
///   quiet period, so a dropped *last* change still reaches the Viewer.
/// - **Refresh on a static screen.** The newest frame stays retained after it is submitted. If a keyframe is
///   requested (loss recovery), VideoToolbox drops the newest frame (rate control after a large IDR) or a frame is
///   waiting in the latest-frame slot, and no newer capture arrives within ~1.5 frame intervals, that frame is
///   submitted (again) — as an IDR when one is pending. Otherwise recovery would wait for the Host screen to change
///   on its own. Gating on the quiet period means a live stream's encode sequence is unchanged (extra encodes there
///   would perturb VideoToolbox's rate control). Retaining the frame pins one capture surface, which is why
///   `CaptureConfig.queueDepth` defaults to 4.
/// - **Session generations.** `reconfigure` rebuilds the session while `encode` keeps running on the capture queue;
///   a frame admitted before the rebuild completed carries the old generation and is dropped on the encode queue
///   instead of being encoded back to back behind the rebuild (it is still the newest frame, so the refresh
///   resubmits it on the new session if nothing newer arrives).
/// - **Never blocks the caller.** `encode` does an atomic compare-exchange and hands the buffer to a
///   private serial queue; `VTCompressionSessionEncodeFrame` (which may block until the frame is emitted
///   when `MaxFrameDelayCount = 0`) runs there, never on the ScreenCaptureKit callback queue.
/// - **Low-latency rate control first.** The session is created with
///   `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` and a hardware requirement, falling back
///   progressively; what was actually obtained is exposed for diagnostics.
/// - **Keyframes on demand.** Low-latency mode uses an infinite GOP, so `requestKeyframe()`
///   (`kVTEncodeFrameOptionKey_ForceKeyFrame`) is the loss-recovery mechanism.
///
/// Synchronization: VideoToolbox session state is confined to `queue`. State read by the output callback
/// lives in `EncoderOutputContext` (atomics + `Mutex`). Diagnostics (`appliedProperties` etc.) are behind
/// a `Mutex`. Do not call `reconfigure` or `invalidate` from inside `onEncodedFrame` (they wait for the
/// session to flush, which waits for the callback).
public final class H264Encoder: @unchecked Sendable {
    /// Called on a VideoToolbox thread for every successfully encoded frame, in encode order. Must return
    /// quickly: the next frame cannot enter the encoder until this returns.
    public var onEncodedFrame: (@Sendable (EncodedVideoFrame) -> Void)? {
        get { context.handler.withLock { $0.callback } }
        set { context.handler.withLock { $0.callback = newValue } }
    }

    /// An in-flight frame older than this is presumed lost by VideoToolbox, so the pipeline cannot wedge.
    static let stallTimeoutNanos: UInt64 = 1_000_000_000

    private let queue = DispatchQueue(label: "com.swiftdesk.codec.encode", qos: .userInteractive)
    private let context = EncoderOutputContext()
    private let invalidatedFlag = Atomic<Bool>(false)
    /// Bumped by every session (re)creation, just before it frees the in-flight slot. A frame carries the value read
    /// right after it took the slot; a mismatch on the encode queue means a rebuild happened in between.
    private let generation = Atomic<UInt64>(0)
    /// Packed `width << 32 | height` of the current session, for frames that are (re)submitted later.
    private let sessionSize = Atomic<UInt64>(0)
    /// The newest frame handed to `encode` (the latest-frame slot when not yet submitted). Every acquisition of the
    /// in-flight slot happens under this lock, so "waiting frame" and "slot free" can never both be observed stale.
    private let mailbox = Mutex(Mailbox())
    private let refreshArmed = Atomic<Bool>(false)
    private let info = Mutex(SessionInfo())
    /// Immutable `{ForceKeyFrame: true}` frame-properties dictionary, built once.
    private let forceKeyframeProperties: CFDictionary

    // Confined to `queue` (or to init/deinit, which are exclusive).
    private var session: VTCompressionSession?
    private var sessionRefCon: Unmanaged<EncoderOutputContext>?
    private var config: EncoderConfig
    private var tokenCounter: UInt64 = 0
    private var lastPresentationTime = CMTime.invalid
    /// Refresh submissions since the last fresh capture (bounded so a frame VideoToolbox keeps dropping cannot loop).
    private var refreshAttempts = 0

    /// Upper bound on consecutive refreshes of the same content (~1 s at 60 fps with the 1.5-interval delay).
    static let maxRefreshAttempts = 40

    public init(config: EncoderConfig) throws {
        try Self.validate(config)
        self.config = config
        self.forceKeyframeProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        try createSession(config)
        context.releaseHook.withLock { hook in
            hook.callback = { [weak self] produced in self?.slotReleased(produced: produced) }
        }
    }

    deinit {
        // Pending queue work captures `self` strongly, so nothing else can touch the session here.
        teardownSession()
    }

    // MARK: Hot path

    /// Non-blocking. Returns true if the frame was submitted now. While another frame is in flight it returns false
    /// (counted in `droppedForBackpressure`) and the frame only waits in the latest-frame slot: a newer capture
    /// replaces it, and if none arrives within the quiet period it is submitted then (static screen).
    @discardableResult
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureNanos: UInt64, sequence: UInt64) -> Bool {
        guard !invalidatedFlag.load(ordering: .acquiring) else { return false }
        let box = PixelBufferBox(pixelBuffer)
        let now = MonotonicClock.nowNanos()
        let admitted = mailbox.withLock { m -> (frame: RetainedFrame, generation: UInt64)? in
            m.nextID &+= 1
            var frame = RetainedFrame(box: box, presentationTime: presentationTime, captureNanos: captureNanos,
                                      sequence: sequence, id: m.nextID, arrivalNanos: now, submitted: false)
            guard context.tryAcquireSlot(now: now) else {
                m.frame = frame   // replaces any older waiting frame
                return nil
            }
            frame.submitted = true
            m.frame = frame
            // Read only after the slot is ours: a rebuild that bumps the generation later will drop this frame.
            return (frame, generation.load(ordering: .acquiring))
        }
        guard let admitted else {
            context.droppedForBackpressure.add(1, ordering: .relaxed)
            return false
        }
        queue.async { [self] in submit(admitted.frame, generation: admitted.generation, refresh: false) }
        return true
    }

    /// The next submitted frame is encoded as an IDR (with SPS/PPS prepended). If no new capture arrives soon (static
    /// screen), the newest frame is submitted again as that IDR.
    public func requestKeyframe() {
        context.forceKeyframe.store(true, ordering: .releasing)
        armRefresh()
    }

    /// Live bitrate change; applied on the encode queue between frames.
    public func setBitrate(kbps: Int) {
        let kbps = max(kbps, 1)
        queue.async { [self] in
            config.bitrateKbps = kbps
            guard let session else { return }
            let applied = applyBitrate(session, kbps: kbps)
            info.withLock { info in
                for (k, v) in applied { info.applied[k] = v }
                info.config = config
            }
        }
    }

    /// Recreates the session (resolution / fps change). The first frame of the new session is a keyframe.
    public func reconfigure(_ config: EncoderConfig) throws {
        try Self.validate(config)
        guard !invalidatedFlag.load(ordering: .acquiring) else { throw CodecError.invalidated }
        try queue.sync {
            teardownSession()
            self.config = config
            try createSession(config)
        }
    }

    /// Flushes any in-flight frame (its output callback still fires) and tears the session down.
    /// Idempotent; afterwards `encode` returns false without counting backpressure.
    public func invalidate() {
        guard !invalidatedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        queue.sync { teardownSession() }
        mailbox.withLock { $0.frame = nil }   // gives the retained capture surface back
        Log.media.info("H264Encoder invalidated")
    }

    /// Test seam: runs `work` on the encode queue (e.g. to hold it while a reconfigure queues up behind it).
    func enqueueOnEncodeQueueForTesting(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    // MARK: Diagnostics

    /// Whether the encoder is hardware accelerated: the `UsingHardwareAcceleratedVideoEncoder` property when
    /// readable, otherwise `true` if the session was created with the hardware requirement; nil if unknown.
    public var isHardwareAccelerated: Bool? { info.withLock { $0.isHardwareAccelerated } }
    /// True if the session was created with `EnableLowLatencyRateControl`.
    public var lowLatencyRateControl: Bool { info.withLock { $0.lowLatency } }
    /// True if the session was created with `RequireHardwareAcceleratedVideoEncoder`.
    public var requiredHardwareEncoder: Bool { info.withLock { $0.requireHardware } }
    /// Property name (VideoToolbox key string, e.g. "RealTime") → whether the session accepted it.
    public var appliedProperties: [String: Bool] { info.withLock { $0.applied } }
    /// The `kVTProfileLevel_*` value accepted by the session, if any.
    public var profileLevel: String? { info.withLock { $0.profileLevel } }
    /// Current configuration (reflects live bitrate changes).
    public var currentConfig: EncoderConfig { info.withLock { $0.config } }
    public var droppedForBackpressure: UInt64 { context.droppedForBackpressure.load(ordering: .relaxed) }
    /// True while a frame occupies the single in-flight slot (until its `onEncodedFrame` returns).
    public var isEncodeInFlight: Bool { context.inFlight.load(ordering: .acquiring) != 0 }
    /// True while a frame waits in the latest-frame slot for the in-flight one to finish.
    public var hasWaitingFrame: Bool { mailbox.withLock { $0.frame.map { !$0.submitted } ?? false } }
    /// Retained frames submitted again because nothing newer arrived (keyframe request or dropped newest frame).
    public var refreshesSubmitted: UInt64 { context.refreshes.load(ordering: .relaxed) }
    /// Frames that waited in the latest-frame slot and were submitted after the quiet period because nothing newer
    /// arrived (they are also counted in `droppedForBackpressure`, since `encode` returned false for them).
    public var waitingFramesSubmitted: UInt64 { context.waitingFramesSubmitted.load(ordering: .relaxed) }
    /// Frames VideoToolbox dropped or failed to encode.
    public var encoderDroppedFrames: UInt64 { context.encoderDropped.load(ordering: .relaxed) }
    public var framesEncoded: UInt64 { context.framesEncoded.load(ordering: .relaxed) }
    /// Times the in-flight slot was reclaimed because VideoToolbox never answered (should stay 0).
    public var stalledEncodeResets: UInt64 { context.stallResets.load(ordering: .relaxed) }

    // MARK: Encode queue

    private func submit(_ frame: RetainedFrame, generation frameGeneration: UInt64, refresh: Bool) {
        guard frameGeneration == generation.load(ordering: .acquiring) else {
            // Took the slot before a session rebuild finished. The rebuild's final `releaseSlot` already cleared that
            // claim, so the slot must not be touched here (it may belong to a newer frame by now).
            context.droppedForBackpressure.add(1, ordering: .relaxed)
            armRefresh()   // it may be the newest content: resubmit it on the new session if nothing newer comes
            return
        }
        guard let session else {
            context.releaseSlot()
            context.encoderDropped.add(1, ordering: .relaxed)
            return
        }
        if refresh {
            context.refreshes.add(1, ordering: .relaxed)
        } else {
            refreshAttempts = 0
        }
        let pixelBuffer = frame.box.buffer
        let sequence = frame.sequence
        let captureNanos = frame.captureNanos
        // VideoToolbox requires strictly increasing timestamps; a capture restart must not wedge the encoder.
        var pts = frame.presentationTime
        let submitNanos = MonotonicClock.nowNanos()
        if refresh, lastPresentationTime.isValid {
            // Half a frame interval after the previous frame: far enough apart that rate control does not see an IDR
            // squeezed into a microsecond, and still before the next capture's timestamp (captures are at least one
            // interval apart, whether the source stamps host time or frame numbers).
            pts = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: CMTimeScale(clamping: max(1, config.fps) * 2)))
        } else if lastPresentationTime.isValid, !(pts.isValid && CMTimeCompare(pts, lastPresentationTime) > 0) {
            pts = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 1_000_000))
        }
        lastPresentationTime = pts

        tokenCounter &+= 1
        if tokenCounter == 0 { tokenCounter = 1 }
        let token = tokenCounter
        let forced = context.forceKeyframe.exchange(false, ordering: .acquiringAndReleasing)
        context.record(FrameMeta(token: token, sequence: sequence, captureNanos: captureNanos,
                                 submitNanos: submitNanos, forcedKeyframe: forced, completed: false, frameID: frame.id))

        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: forced ? forceKeyframeProperties : nil,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(token)), infoFlagsOut: &flags)
        guard status != noErr else { return }

        context.completeWithoutOutput(token: token)
        if status == kVTInvalidSessionErr {
            // GPU reset / sleep-wake can invalidate the session. Rebuild once; the next frame will be an IDR.
            Log.media.error("H264Encoder session invalid; recreating")
            teardownSession()
            do { try createSession(config) } catch {
                Log.media.error("H264Encoder recreate failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Latest-frame slot and refresh

    /// The in-flight slot was just released (VideoToolbox thread, or the encode queue on an encode error). If a frame
    /// is waiting in the latest-frame slot, the finished frame produced nothing, or a keyframe is still pending, a
    /// refresh is armed in case no newer capture arrives.
    private func slotReleased(produced: Bool) {
        guard !invalidatedFlag.load(ordering: .acquiring) else { return }
        let waiting = mailbox.withLock { $0.frame.map { !$0.submitted } ?? false }
        if waiting || !produced || context.forceKeyframe.load(ordering: .acquiring) { armRefresh() }
    }

    /// Quiet period before a refresh: ~1.5 frame intervals without a new capture. A live stream always delivers the
    /// next capture sooner, so refreshes only ever happen on a static screen and never add encodes to a live stream
    /// (where they would compete with VideoToolbox's own rate-control drops).
    private func quietNanos() -> UInt64 {
        UInt64(1_500_000_000 / max(1, info.withLock { $0.config.fps }))
    }

    /// One pending refresh check at a time.
    private func armRefresh(afterNanos delay: UInt64? = nil) {
        guard !invalidatedFlag.load(ordering: .acquiring),
              !refreshArmed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let wait = delay ?? quietNanos()
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: wait))) { [weak self] in
            self?.refreshIfNeeded()
        }
    }

    /// Encode queue. Submits the newest frame (again) when a keyframe is pending or that frame never produced output
    /// (VideoToolbox dropped it, or it is still waiting in the latest-frame slot), no
    /// capture arrived for the quiet period, the slot is free and the frame matches the session size. Too soon after
    /// a capture: check again when the quiet period ends. A busy slot needs no retry: the in-flight frame's completion
    /// calls `slotReleased`, which re-arms if still needed.
    private func refreshIfNeeded() {
        refreshArmed.store(false, ordering: .releasing)
        guard !invalidatedFlag.load(ordering: .acquiring), session != nil,
              refreshAttempts < Self.maxRefreshAttempts else { return }
        let wantKeyframe = context.forceKeyframe.load(ordering: .acquiring)
        let delivered = context.lastDeliveredFrameID.load(ordering: .acquiring)
        let size = sessionSize.load(ordering: .acquiring)
        let quiet = quietNanos()
        let now = MonotonicClock.nowNanos()
        enum Step { case none, wait(UInt64), submit(RetainedFrame, UInt64, wasWaiting: Bool) }
        let step = mailbox.withLock { m -> Step in
            guard var frame = m.frame, wantKeyframe || frame.id != delivered,
                  Self.packedSize(of: frame.box.buffer) == size else { return .none }
            let age = now >= frame.arrivalNanos ? now - frame.arrivalNanos : 0
            if age < quiet { return .wait(quiet - age) }
            guard context.tryAcquireSlot(now: now) else { return .none }
            let wasWaiting = !frame.submitted
            frame.submitted = true
            m.frame = frame
            return .submit(frame, generation.load(ordering: .acquiring), wasWaiting: wasWaiting)
        }
        let next: (frame: RetainedFrame, generation: UInt64)
        switch step {
        case .none: return
        case .wait(let remaining):
            armRefresh(afterNanos: remaining)
            return
        case .submit(let frame, let gen, let wasWaiting):
            if wasWaiting {
                // A capture that arrived while another frame was in flight and was never superseded: a fresh frame.
                context.waitingFramesSubmitted.add(1, ordering: .relaxed)
                submit(frame, generation: gen, refresh: false)
                return
            }
            next = (frame, gen)
        }
        refreshAttempts += 1
        // The screen has not changed since this frame was captured, so it *is* the current content.
        var frame = next.frame
        frame.captureNanos = now
        submit(frame, generation: next.generation, refresh: true)
    }

    private static func packedSize(of buffer: CVPixelBuffer) -> UInt64 {
        packSize(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    }

    private static func packSize(_ width: Int, _ height: Int) -> UInt64 {
        UInt64(UInt32(clamping: width)) << 32 | UInt64(UInt32(clamping: height))
    }

    // MARK: Session lifecycle (queue-confined)

    private static func validate(_ config: EncoderConfig) throws {
        guard config.width > 0, config.height > 0, config.width % 2 == 0, config.height % 2 == 0 else {
            throw CodecError.invalidConfiguration("dimensions must be positive and even (got \(config.width)x\(config.height))")
        }
        guard config.fps > 0, config.fps <= 240 else { throw CodecError.invalidConfiguration("fps out of range: \(config.fps)") }
        guard config.bitrateKbps > 0 else { throw CodecError.invalidConfiguration("bitrate must be positive") }
        guard config.keyframeIntervalSeconds >= 0, config.keyframeIntervalSeconds.isFinite else {
            throw CodecError.invalidConfiguration("keyframe interval must be >= 0")
        }
    }

    private func createSession(_ config: EncoderConfig) throws {
        // Ordered from most to least desirable. Requiring hardware first means a software fallback is an
        // explicit, recorded decision rather than something VideoToolbox does silently.
        let attempts: [(lowLatency: Bool, requireHardware: Bool)] = [(true, true), (true, false), (false, false)]
        let sourceAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: NSNumber(value: config.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: config.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ] as CFDictionary

        var lastStatus: OSStatus = noErr
        for attempt in attempts {
            var spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
            if attempt.lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true }
            if attempt.requireHardware { spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true }

            let refCon = Unmanaged.passRetained(context)
            var newSession: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(config.width), height: Int32(config.height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: sourceAttributes, compressedDataAllocator: nil,
                outputCallback: h264EncoderOutputCallback, refcon: refCon.toOpaque(),
                compressionSessionOut: &newSession)
            guard status == noErr, let newSession else {
                refCon.release()
                lastStatus = status
                Log.media.info("VTCompressionSessionCreate lowLatency=\(attempt.lowLatency) requireHW=\(attempt.requireHardware) failed: \(status)")
                continue
            }

            var applied: [String: Bool] = [:]
            let profile = configure(newSession, config: config, applied: &applied)
            // Low-latency sessions report UsingHardwareAcceleratedVideoEncoder as unsupported (-12900, measured).
            // RequireHardwareAcceleratedVideoEncoder is documented to fail creation without hardware, so a
            // session created with it is hardware by construction.
            let queried = copyBool(newSession, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
            let hardware = queried ?? (attempt.requireHardware ? true : nil)
            let prepare = VTCompressionSessionPrepareToEncodeFrames(newSession)
            applied["PrepareToEncodeFrames"] = prepare == noErr

            session = newSession
            sessionRefCon = refCon
            lastPresentationTime = .invalid
            sessionSize.store(Self.packSize(config.width, config.height), ordering: .releasing)
            // Generation first, release last: a frame that took the slot during this rebuild holds the old
            // generation and is dropped in `submit`, and this release clears its claim.
            generation.add(1, ordering: .releasing)
            context.releaseSlot()
            info.withLock { info in
                info = SessionInfo(isHardwareAccelerated: hardware, lowLatency: attempt.lowLatency,
                                   requireHardware: attempt.requireHardware, applied: applied,
                                   profileLevel: profile, config: config)
            }
            Log.media.info("H264Encoder session \(config.width)x\(config.height)@\(config.fps) lowLatency=\(attempt.lowLatency) requireHW=\(attempt.requireHardware) hw=\(String(describing: hardware), privacy: .public) profile=\(profile ?? "default", privacy: .public)")
            return
        }
        throw CodecError.sessionCreationFailed(lastStatus)
    }

    /// Applies every tuning property individually so one rejected optional key cannot prevent the rest.
    /// Returns the accepted profile level.
    private func configure(_ session: VTCompressionSession, config: EncoderConfig, applied: inout [String: Bool]) -> String? {
        func set(_ key: CFString, _ value: CFTypeRef) {
            applied[key as String] = VTSessionSetProperty(session, key: key, value: value) == noErr
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Latency first. Measured on Apple silicon: low-latency rate-control sessions reject this key (it is already
        // their behavior), so it only applies to the software / non-low-latency fallback sessions, where it matters.
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: config.fps))
        set(kVTCompressionPropertyKey_MaximumRealTimeFrameRate, NSNumber(value: config.fps))
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        if config.keyframeIntervalSeconds > 0 {
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: config.keyframeIntervalSeconds))
            let frames = max(1, Int((config.keyframeIntervalSeconds * Double(config.fps)).rounded()))
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frames))
        }
        for (k, v) in applyBitrate(session, kbps: config.bitrateKbps) { applied[k] = v }

        // Constrained High first: CABAC and the 8×8 transform keep small desktop text noticeably sharper per bit
        // than Baseline, while "constrained" still means no B-frames / no reordering (and AllowFrameReordering is
        // off anyway), so it adds no latency; both ends are Apple hardware codecs. AutoLevel picks the level from
        // size × rate: 1920×1080@60 needs Level 4.2 (489 600 of 522 240 MB/s), which the hardware encoder supports.
        // Constrained Baseline (cheapest decode) is the fallback, then the classic profiles.
        let profiles: [CFString] = [
            kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
            kVTProfileLevel_H264_Main_AutoLevel,
            kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTProfileLevel_H264_High_AutoLevel,
        ]
        for profile in profiles
        where VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile) == noErr {
            applied[kVTCompressionPropertyKey_ProfileLevel as String] = true
            return profile as String
        }
        applied[kVTCompressionPropertyKey_ProfileLevel as String] = false
        return nil
    }

    /// AverageBitRate is the soft target; DataRateLimits adds a hard 1-second cap at 1.5x so a burst
    /// (e.g. a full-screen change) cannot flood the network path and inflate queueing delay.
    private func applyBitrate(_ session: VTCompressionSession, kbps: Int) -> [String: Bool] {
        let bps = min(kbps, Int(Int32.max / 1000)) * 1000
        let average = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                           value: NSNumber(value: Int32(bps)))
        let capBytesPerSecond = Double(bps) * 1.5 / 8
        let limits = [NSNumber(value: capBytesPerSecond), NSNumber(value: 1.0)] as CFArray
        let cap = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        return [kVTCompressionPropertyKey_AverageBitRate as String: average == noErr,
                kVTCompressionPropertyKey_DataRateLimits as String: cap == noErr]
    }

    private func copyBool(_ session: VTCompressionSession, _ key: CFString) -> Bool? {
        var out: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &out) { VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: $0) }
        guard status == noErr, let value = out?.takeRetainedValue(), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private func teardownSession() {
        guard let session else { return }
        // Emits (or drops) the in-flight frame through the callback before invalidation.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        sessionRefCon?.release()
        sessionRefCon = nil
        context.releaseSlot()
    }
}

// MARK: - Callback plumbing

struct SessionInfo {
    var isHardwareAccelerated: Bool?
    var lowLatency = false
    var requireHardware = false
    var applied: [String: Bool] = [:]
    var profileLevel: String?
    var config = EncoderConfig(width: 0, height: 0)
}

struct FrameMeta {
    var token: UInt64
    var sequence: UInt64
    var captureNanos: UInt64
    var submitNanos: UInt64
    var forcedKeyframe: Bool
    var completed: Bool
    /// `RetainedFrame.id` of the submitted frame (0 for none).
    var frameID: UInt64 = 0
}

/// A captured frame kept by the encoder: the newest one handed to `encode`. Holding it retains its surface.
struct RetainedFrame {
    var box: PixelBufferBox
    var presentationTime: CMTime
    var captureNanos: UInt64
    var sequence: UInt64
    /// Increasing per `encode` call (encoder-local, never 0).
    var id: UInt64
    /// When `encode` received it (refreshes wait until the screen has been quiet for a while after this).
    var arrivalNanos: UInt64
    /// False while it waits in the latest-frame slot.
    var submitted: Bool
}

struct Mailbox {
    var frame: RetainedFrame?
    var nextID: UInt64 = 0
}

/// Moves a `CVPixelBuffer` onto the encode queue. The capturer hands over the buffer and does not
/// mutate it afterwards; VideoToolbox retains it for as long as it needs.
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// State shared between the encode queue and VideoToolbox's output thread. Retained by each
/// compression session through its refcon, so it outlives every callback.
final class EncoderOutputContext: Sendable {
    static let ringSize = 4

    /// 0 = idle, 1 = a frame is inside VideoToolbox.
    let inFlight = Atomic<Int>(0)
    let inFlightSinceNanos = Atomic<UInt64>(0)
    let forceKeyframe = Atomic<Bool>(false)
    let droppedForBackpressure = Atomic<UInt64>(0)
    let encoderDropped = Atomic<UInt64>(0)
    let framesEncoded = Atomic<UInt64>(0)
    let stallResets = Atomic<UInt64>(0)
    let refreshes = Atomic<UInt64>(0)
    let waitingFramesSubmitted = Atomic<UInt64>(0)
    /// `FrameMeta.frameID` of the last frame that produced output.
    let lastDeliveredFrameID = Atomic<UInt64>(0)
    /// Told after every slot release from a completed frame (`produced` = it emitted output). Same struct-field
    /// pattern as `HandlerSlot`.
    struct ReleaseHook { var callback: (@Sendable (_ produced: Bool) -> Void)? }
    let releaseHook = Mutex(ReleaseHook())
    /// The closure lives in a struct field, not directly as `Mutex<Closure?>`: reading a bare optional closure
    /// out of a `Mutex` with `withLock { $0 }` re-wraps it in a reabstraction thunk on every read, so after
    /// ~1M frames calling it overflowed the stack (reproduced in isolation; see CaptureCore's callback boxes).
    struct HandlerSlot { var callback: (@Sendable (EncodedVideoFrame) -> Void)? }
    let handler = Mutex(HandlerSlot())
    /// Small ring keyed by submit token, so a late callback can never be matched to a newer frame.
    private let metas = Mutex([FrameMeta](repeating: FrameMeta(token: 0, sequence: 0, captureNanos: 0, submitNanos: 0,
                                                               forcedKeyframe: false, completed: true),
                                         count: EncoderOutputContext.ringSize))

    func tryAcquireSlot(now: UInt64) -> Bool {
        if inFlight.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing).exchanged {
            inFlightSinceNanos.store(now, ordering: .relaxed)
            return true
        }
        let since = inFlightSinceNanos.load(ordering: .relaxed)
        guard now > since, now - since > H264Encoder.stallTimeoutNanos else { return false }
        // VideoToolbox never answered; reclaim the slot rather than drop frames forever. Only one caller
        // wins the timestamp exchange; the abandoned frame is marked complete so its late callback is ignored.
        guard inFlightSinceNanos.compareExchange(expected: since, desired: now, ordering: .relaxed).exchanged else { return false }
        metas.withLock { ring in
            for i in ring.indices { ring[i].completed = true }
        }
        stallResets.add(1, ordering: .relaxed)
        inFlight.store(1, ordering: .releasing)
        return true
    }

    @inline(__always) func releaseSlot() { inFlight.store(0, ordering: .releasing) }

    func record(_ meta: FrameMeta) {
        metas.withLock { $0[Int(meta.token % UInt64(Self.ringSize))] = meta }
    }

    /// Marks `token` complete; returns its metadata only the first time (dedupes error-return + callback).
    func complete(token: UInt64) -> FrameMeta? {
        metas.withLock { ring -> FrameMeta? in
            let i = Int(token % UInt64(Self.ringSize))
            guard ring[i].token == token, !ring[i].completed else { return nil }
            ring[i].completed = true
            return ring[i]
        }
    }

    func completeWithoutOutput(token: UInt64) {
        guard let meta = complete(token: token) else { return }
        encoderDropped.add(1, ordering: .relaxed)
        if meta.forcedKeyframe { forceKeyframe.store(true, ordering: .releasing) }
        releaseSlot()
        notifyReleased(produced: false)
    }

    private func notifyReleased(produced: Bool) {
        let hook = releaseHook.withLock { $0.callback }
        hook?(produced)
    }

    func handleOutput(token: UInt64, status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        let doneNanos = MonotonicClock.nowNanos()
        guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer,
              let data = AVCCWriter.accessUnit(from: sampleBuffer)
        else {
            completeWithoutOutput(token: token)
            return
        }
        guard let meta = complete(token: token) else { return }  // stale (slot already reclaimed)
        let isKeyframe = data.isKeyframe
        let frame = EncodedVideoFrame(data: data.bytes, isKeyframe: isKeyframe, captureNanos: meta.captureNanos,
                                      encodeDoneNanos: doneNanos, sequence: meta.sequence, encodeSubmitNanos: meta.submitNanos)
        framesEncoded.add(1, ordering: .relaxed)
        lastDeliveredFrameID.store(meta.frameID, ordering: .releasing)
        if meta.forcedKeyframe && !isKeyframe { forceKeyframe.store(true, ordering: .releasing) }
        PipelineSignpost.encoded(frame: meta.sequence, bytes: frame.data.count, keyframe: isKeyframe)
        let callback = handler.withLock { $0.callback }
        callback?(frame)
        // Released after delivery so frames reach the packetizer strictly in order.
        releaseSlot()
        notifyReleased(produced: true)
    }
}

/// VideoToolbox output callback. A plain C function (no per-frame block allocation); the refcon is the
/// `EncoderOutputContext` retained by the session, and the per-frame refcon carries the submit token.
private func h264EncoderOutputCallback(_ outputRefCon: UnsafeMutableRawPointer?, _ sourceFrameRefCon: UnsafeMutableRawPointer?,
                                       _ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sampleBuffer: CMSampleBuffer?) {
    guard let outputRefCon else { return }
    let context = Unmanaged<EncoderOutputContext>.fromOpaque(outputRefCon).takeUnretainedValue()
    let token = UInt64(UInt(bitPattern: sourceFrameRefCon))
    context.handleOutput(token: token, status: status, flags: flags, sampleBuffer: sampleBuffer)
}

/// Converts VideoToolbox output (`CMSampleBuffer`) into a wire-ready AVCC access unit.
enum AVCCWriter {
    struct AccessUnit {
        var bytes: Data
        var isKeyframe: Bool
    }

    /// A sample is a sync sample (IDR) when `kCMSampleAttachmentKey_NotSync` is absent or false.
    /// Reads the attachment dictionary directly to avoid bridging allocations.
    static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let rawDict = CFArrayGetValueAtIndex(attachments, 0)
        else { return true }
        let dict = unsafeBitCast(rawDict, to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let value = CFDictionaryGetValue(dict, key) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    /// Builds `[SPS][PPS]` (keyframes only) followed by the slice NAL units, all with 4-byte lengths.
    /// Exactly one allocation for the common 4-byte-length case (adopted by `Data` without copying).
    static func accessUnit(from sampleBuffer: CMSampleBuffer) -> AccessUnit? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let isKeyframe = isSyncSample(sampleBuffer)
        let blockLength = CMBlockBufferGetDataLength(block)
        guard blockLength > 0 else { return nil }

        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: &nalHeaderLength) == noErr
        else { return nil }
        let lengthSize = Int(nalHeaderLength)
        guard lengthSize == 1 || lengthSize == 2 || lengthSize == 4 else { return nil }

        // Parameter sets (keyframes only).
        var prefixLength = 0
        if isKeyframe {
            for i in 0..<parameterSetCount {
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: nil, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr
                else { return nil }
                prefixLength += AVCC.lengthHeaderSize + size
            }
        }

        if lengthSize == AVCC.lengthHeaderSize {
            let total = prefixLength + blockLength
            guard let out = malloc(total) else { return nil }
            guard writeParameterSets(format, count: isKeyframe ? parameterSetCount : 0, into: out),
                  CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: blockLength,
                                             destination: out + prefixLength) == kCMBlockBufferNoErr
            else { free(out); return nil }
            return AccessUnit(bytes: Data(bytesNoCopy: out, count: total, deallocator: .free), isKeyframe: isKeyframe)
        }

        // Rare path: the encoder used 1- or 2-byte lengths; re-frame every NAL with a 4-byte length.
        var source = Data(count: blockLength)
        let copied = source.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: blockLength, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        return source.withUnsafeBytes { raw -> AccessUnit? in
            var nalBytes = 0
            var nalCount = 0
            do {
                try AVCC.forEachNAL(in: raw, lengthSize: lengthSize) { range in
                    nalBytes += range.count
                    nalCount += 1
                }
            } catch { return nil }
            let total = prefixLength + nalBytes + nalCount * AVCC.lengthHeaderSize
            guard let out = malloc(total) else { return nil }
            guard writeParameterSets(format, count: isKeyframe ? parameterSetCount : 0, into: out) else { free(out); return nil }
            var offset = prefixLength
            try? AVCC.forEachNAL(in: raw, lengthSize: lengthSize) { range in
                AVCC.storeLength(range.count, at: out + offset)
                (out + offset + AVCC.lengthHeaderSize).copyMemory(from: raw.baseAddress! + range.lowerBound, byteCount: range.count)
                offset += AVCC.lengthHeaderSize + range.count
            }
            return AccessUnit(bytes: Data(bytesNoCopy: out, count: total, deallocator: .free), isKeyframe: isKeyframe)
        }
    }

    private static func writeParameterSets(_ format: CMFormatDescription, count: Int, into out: UnsafeMutableRawPointer) -> Bool {
        var offset = 0
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer
            else { return false }
            AVCC.storeLength(size, at: out + offset)
            (out + offset + AVCC.lengthHeaderSize).copyMemory(from: pointer, byteCount: size)
            offset += AVCC.lengthHeaderSize + size
        }
        return true
    }
}
