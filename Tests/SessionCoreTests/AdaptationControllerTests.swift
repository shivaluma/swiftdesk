import Testing
@testable import SessionCore

@Suite struct AdaptationControllerTests {
    private static let second: UInt64 = 1_000_000_000

    /// Drives `ticks` one-second ticks with the same inputs, starting at `start` seconds.
    @discardableResult
    private func run(_ c: inout AdaptationController, from start: Int, ticks: Int,
                     _ make: (UInt64) -> AdaptationController.Inputs) -> [AdaptationController.Decision] {
        (0..<ticks).map { i in c.update(make(UInt64(start + i) * Self.second)) }
    }

    private func clean(_ now: UInt64) -> AdaptationController.Inputs {
        .init(nowNanos: now, lossPercent: 0, rttMillis: 5, minRTTMillis: 4, sendBacklogBytes: 0,
              viewerFPS: 60, hostSentFPS: 60)
    }

    private func lossy(_ percent: Double) -> (UInt64) -> AdaptationController.Inputs {
        { now in .init(nowNanos: now, lossPercent: percent, rttMillis: 5, minRTTMillis: 4) }
    }

    @Test func startsAtDefaults() {
        // Sharp (default): top rung bounds 1920×1080; 60 % of its 12 000 kbps ceiling would be 7200, but a native
        // rung starts at most at 4000 kbps and probes up (the link may be lossy).
        let c = AdaptationController()
        #expect(c.rungIndex == 0)
        #expect(c.rung.width == 1920 && c.rung.height == 1080 && c.rung.fps == 60)
        #expect(c.currentCeilingKbps == 12000)
        #expect(c.bitrateKbps == 4000)
        #expect(AdaptationController.defaultLadder.map(\.description)
                == ["1920×1080@60", "1280×720@60", "960×540@60", "960×540@30"])
        // Balanced is exactly the pre-0.1.3 ladder and range.
        let b = AdaptationController(configuration: .balanced)
        #expect(b.bitrateKbps == 3000)
        #expect(b.rung == AdaptationController.Rung(width: 1280, height: 720, fps: 60))
        #expect(b.currentCeilingKbps == 5000)
        #expect(b.currentFloorKbps == 1000)
        #expect(AdaptationController.balancedLadder.map(\.description) == ["1280×720@60", "960×540@60", "960×540@30"])
    }

    // MARK: Balanced (the pre-0.1.3 behavior, unchanged)

    @Test func cleanNetworkProbesUpSlowlyAndCapsAtMax() {
        var c = AdaptationController(configuration: .balanced)
        let decisions = run(&c, from: 0, ticks: 3, clean)
        // Clean since t=0; first +250 only after 2 s of clean time.
        #expect(decisions.map(\.bitrateKbps) == [3000, 3000, 3250])
        #expect(decisions.map(\.condition) == [.clean, .clean, .clean])
        run(&c, from: 3, ticks: 40, clean)
        #expect(c.bitrateKbps == 5000)
        #expect(c.rungIndex == 0)
    }

    @Test func increaseIsOncePerTwoSeconds() {
        var c = AdaptationController(configuration: .balanced)
        let decisions = run(&c, from: 0, ticks: 7, clean)
        #expect(decisions.map(\.bitrateKbps) == [3000, 3000, 3250, 3250, 3500, 3500, 3750])
    }

    @Test func congestionCutsFastByThirtyPercent() {
        var c = AdaptationController(configuration: .balanced)
        let d = c.update(lossy(10)(0))
        #expect(d.bitrateChanged)
        #expect(d.bitrateKbps == 2100)
        #expect(d.condition == .congested)
        #expect(d.signals.contains(.loss))
        #expect(c.update(lossy(10)(Self.second)).bitrateKbps == 1470)
        #expect(c.update(lossy(10)(2 * Self.second)).bitrateKbps == 1029)
        #expect(c.update(lossy(10)(3 * Self.second)).bitrateKbps == 1000)   // floor
    }

    @Test func decreaseCooldownPreventsDoubleCutWithinASecond() {
        var c = AdaptationController(configuration: .balanced)
        #expect(c.update(lossy(10)(0)).bitrateKbps == 2100)
        #expect(c.update(lossy(10)(Self.second / 2)).bitrateKbps == 2100)
        #expect(c.update(lossy(10)(Self.second)).bitrateKbps == 1470)
    }

    @Test func moderateRandomLossHoldsInsteadOfBackingOff() {
        // Milestone B: 1–3 % artificial loss must not drive the bitrate down (it is not congestion).
        var c = AdaptationController(configuration: .balanced)
        let decisions = run(&c, from: 0, ticks: 10, lossy(2.5))
        #expect(decisions.allSatisfy { $0.condition == .neutral })
        #expect(c.bitrateKbps == 3000)
        #expect(c.rungIndex == 0)
    }

    @Test func neutralResetsTheCleanTimer() {
        var c = AdaptationController(configuration: .balanced)
        run(&c, from: 0, ticks: 1, clean)          // clean since 0
        run(&c, from: 1, ticks: 1, lossy(2))       // neutral: timer reset
        let d = run(&c, from: 2, ticks: 2, clean)  // clean since 2 → no increase until t=4
        #expect(d.map(\.bitrateKbps) == [3000, 3000])
        #expect(c.update(clean(4 * Self.second)).bitrateKbps == 3250)
    }

    @Test func sustainedCongestionAtMinimumStepsDownTheLadderOneRungAtATime() {
        var c = AdaptationController(configuration: .balanced)
        // 3000 → 2100 → 1470 → 1029 → 1000 (t=3); at min since t=3; step down at t=6.
        let d = run(&c, from: 0, ticks: 7, lossy(20))
        #expect(d[3].bitrateKbps == 1000)
        #expect(d[5].rungIndex == 0)
        #expect(d[6].rungChanged)
        #expect(d[6].rung == AdaptationController.Rung(width: 960, height: 540, fps: 60))
        // Another 3 s at minimum (measured from the tick after the step) → frame rate goes next.
        let later = run(&c, from: 7, ticks: 4, lossy(20))
        #expect(later[2].rungIndex == 1)
        #expect(later.last?.rung == AdaptationController.Rung(width: 960, height: 540, fps: 30))
        // Bottom of the ladder: never beyond.
        run(&c, from: 10, ticks: 20, lossy(20))
        #expect(c.rungIndex == 2)
        #expect(c.bitrateKbps == 1000)
    }

    @Test func stepsBackUpOnlyAfterLongCleanPeriodAndRecoveredBitrate() {
        var c = AdaptationController(configuration: .balanced)
        run(&c, from: 0, ticks: 7, lossy(20))
        #expect(c.rungIndex == 1)
        // Clean from t=7: bitrate climbs 250 per 2 s from 1000; needs ≥ 3000 (8 increases = 16 s) and ≥ 10 s clean.
        var steppedUpAt: Int?
        for t in 7..<40 {
            let d = c.update(clean(UInt64(t) * Self.second))
            if d.rungChanged {
                steppedUpAt = t
                #expect(d.rungIndex == 0)
                #expect(d.bitrateKbps >= 3000)
                break
            }
        }
        #expect(steppedUpAt != nil, "never stepped back up")
        #expect((steppedUpAt ?? 0) - 7 >= 10)
    }

    @Test func noStepUpWhileNeutral() {
        var c = AdaptationController(configuration: .balanced, initialRungIndex: 1)
        run(&c, from: 0, ticks: 30, lossy(2))
        #expect(c.rungIndex == 1)
    }

    @Test func rttInflationRelativeToMinimumIsCongestion() {
        var c = AdaptationController(configuration: .balanced)
        // min 20 ms → congested when inflation > max(50, 20) = 50 ms.
        let ok = c.update(.init(nowNanos: 0, lossPercent: 0, rttMillis: 60, minRTTMillis: 20))
        #expect(ok.condition == .neutral)   // 40 ms inflation: not clean (≥ 20), not congested
        let bad = c.update(.init(nowNanos: Self.second, lossPercent: 0, rttMillis: 75, minRTTMillis: 20))
        #expect(bad.signals.contains(.rttInflation))
        #expect(bad.bitrateKbps == 2100)
        // Long-haul path: min 120 ms → threshold 120 ms of inflation.
        var wan = AdaptationController(configuration: .balanced)
        #expect(wan.update(.init(nowNanos: 0, lossPercent: 0, rttMillis: 230, minRTTMillis: 120)).condition != .congested)
        #expect(wan.update(.init(nowNanos: Self.second, lossPercent: 0, rttMillis: 250, minRTTMillis: 120)).condition == .congested)
    }

    @Test func sendBacklogAndBackpressureAreCongestion() {
        var c = AdaptationController(configuration: .balanced)
        let backlog = c.update(.init(nowNanos: 0, sendBacklogBytes: 200 * 1024))
        #expect(backlog.signals == [.backlog])
        var d = AdaptationController(configuration: .balanced)
        let drops = d.update(.init(nowNanos: 0, sendBackpressureDrops: 1))
        #expect(drops.signals == [.sendBackpressure])
        #expect(drops.bitrateKbps == 2100)
    }

    /// The backlog signal is in milliseconds of video at the current bitrate, so the same byte count is congestion at
    /// the 1000 kbps floor but not at 3000 kbps (review finding latency-3).
    @Test func sendBacklogThresholdScalesWithBitrate() {
        var atDefault = AdaptationController(configuration: .balanced)   // 3000 kbps: 64 KiB ≈ 175 ms
        #expect(!atDefault.update(.init(nowNanos: 0, sendBacklogBytes: 64 * 1024)).signals.contains(.backlog))
        var config = AdaptationController.Configuration.balanced
        config.initialBitrateKbps = 1000
        var atFloor = AdaptationController(configuration: config)   // 1000 kbps: 64 KiB ≈ 524 ms
        #expect(atFloor.update(.init(nowNanos: 0, sendBacklogBytes: 64 * 1024)).signals.contains(.backlog))
    }

    @Test func viewerFallingBehindIsCongestion() {
        var c = AdaptationController(configuration: .balanced)
        let d = c.update(.init(nowNanos: 0, lossPercent: 0, viewerFPS: 25, hostSentFPS: 60))
        #expect(d.signals.contains(.viewerSlow))
        // Static desktop: the host itself sends few frames → no judgement.
        var quiet = AdaptationController(configuration: .balanced)
        #expect(quiet.update(.init(nowNanos: 0, lossPercent: 0, viewerFPS: 2, hostSentFPS: 3)).signals.isEmpty)
    }

    @Test func encoderOverloadStepsDownWithoutCuttingBitrate() {
        var c = AdaptationController(configuration: .balanced)
        // 60 fps × 15 % = 9 drops/s threshold.
        let overloaded = { (now: UInt64) in AdaptationController.Inputs(nowNanos: now, lossPercent: 0,
                                                                       encoderBackpressureDrops: 20) }
        let d = run(&c, from: 0, ticks: 4, overloaded)
        #expect(d.allSatisfy { $0.signals.contains(.encoderOverload) })
        #expect(d.allSatisfy { $0.bitrateKbps == 3000 })
        #expect(d[3].rungChanged)
        #expect(c.rungIndex == 1)
        // A few drops (below threshold) are tolerated.
        var light = AdaptationController(configuration: .balanced)
        #expect(light.update(.init(nowNanos: 0, lossPercent: 0, encoderBackpressureDrops: 3)).signals.isEmpty)
    }

    @Test func missingReportsAreTreatedAsNoSignal() {
        var c = AdaptationController(configuration: .balanced)
        let d = c.update(.init(nowNanos: 0))
        #expect(d.condition == .clean)
        #expect(!d.bitrateChanged)
    }

    @Test func customConfigurationIsClamped() {
        var config = AdaptationController.Configuration.balanced
        config.initialBitrateKbps = 9000
        let c = AdaptationController(configuration: config, initialRungIndex: 7)
        #expect(c.bitrateKbps == 5000)
        #expect(c.rungIndex == 2)
    }

    // MARK: Sharp: bitrate scaled to the encoded picture

    @Test func ceilingFollowsEncodedPixelRate() {
        #expect(AdaptationController.bitrateCeilingKbps(width: 1280, height: 720, fps: 60) == 5000)
        #expect(AdaptationController.bitrateCeilingKbps(width: 1600, height: 900, fps: 60) == 8250)
        #expect(AdaptationController.bitrateCeilingKbps(width: 1920, height: 1080, fps: 60) == 12250)
        #expect(AdaptationController.bitrateCeilingKbps(width: 960, height: 540, fps: 60) == 2750)
        #expect(AdaptationController.bitrateCeilingKbps(width: 960, height: 540, fps: 30) == 1250)
        #expect(AdaptationController.bitrateFloorKbps(ceilingKbps: 8250) == 3250)
    }

    /// The reported setup: a 1600×900 non-HiDPI display. The top rung encodes exactly 1600×900 and gets a 1600×900
    /// ceiling (not the 1080p bound's), and the old 720p rung stays as the first fallback.
    @Test func resolvedFor1600x900UsesTheEncodedSize() {
        let config = AdaptationController.Configuration().resolved(sourceWidth: 1600, sourceHeight: 900)
        #expect(config.ladder.map(\.description) == ["1920×1080@60", "1280×720@60", "960×540@60", "960×540@30"])
        #expect(config.ladder.map(\.maxBitrateKbps) == [8250, 5000, 2750, 1250])
        #expect(config.ladder.map(\.minBitrateKbps) == [3250, 2000, 1000, nil])
        let c = AdaptationController(configuration: config)
        #expect(c.currentCeilingKbps == 8250)
        #expect(c.bitrateKbps == 4000)   // 60 % of the ceiling (4950), capped at the 4000 kbps start
    }

    @Test func resolvedDropsRungsThatCollapseToTheSameSize() {
        // A 1280×720 display: the 1920×1080 bound and the 1280×720 bound both encode 1280×720.
        let small = AdaptationController.Configuration().resolved(sourceWidth: 1280, sourceHeight: 720)
        #expect(small.ladder.map(\.description) == ["1920×1080@60", "960×540@60", "960×540@30"])
        #expect(small.ladder.map(\.maxBitrateKbps) == [5000, 2750, 1250])
        #expect(AdaptationController(configuration: small).bitrateKbps == 3000)
        // A tiny display: everything but the frame-rate step collapses.
        let tiny = AdaptationController.Configuration().resolved(sourceWidth: 800, sourceHeight: 450)
        #expect(tiny.ladder.map(\.description) == ["1920×1080@60", "960×540@30"])
        #expect(tiny.ladder.last?.minBitrateKbps == nil)
        // Balanced keeps one shared range, but still drops collapsed rungs.
        let balanced = AdaptationController.Configuration.balanced.resolved(sourceWidth: 960, sourceHeight: 540)
        #expect(balanced.ladder.map(\.description) == ["1280×720@60", "960×540@30"])
        #expect(balanced.ladder.allSatisfy { $0.maxBitrateKbps == nil && $0.minBitrateKbps == nil })
        // Unknown size: unchanged.
        #expect(AdaptationController.Configuration().resolved(sourceWidth: 0, sourceHeight: 0) == .init())
    }

    @Test func hidpiDisplayResolvesAgainstPixels() {
        // 2880×1800 backing pixels: the top rung encodes 1728×1080, the next 1152×720.
        let config = AdaptationController.Configuration().resolved(sourceWidth: 2880, sourceHeight: 1800)
        #expect(config.ladder.count == 4)
        #expect(config.ladder[0].maxBitrateKbps == AdaptationController.bitrateCeilingKbps(width: 1728, height: 1080, fps: 60))
        #expect(config.ladder[1].maxBitrateKbps == AdaptationController.bitrateCeilingKbps(width: 1152, height: 720, fps: 60))
    }

    @Test func sharpProbesUpFasterToItsOwnCeiling() {
        var c = AdaptationController(configuration: .init().resolved(sourceWidth: 1600, sourceHeight: 900))
        let d = run(&c, from: 0, ticks: 5, clean)
        // 5 % of 8250 = 412 kbps per 2 s.
        #expect(d.map(\.bitrateKbps) == [4000, 4000, 4412, 4412, 4824])
        run(&c, from: 5, ticks: 30, clean)
        #expect(c.bitrateKbps == 8250)
        #expect(c.rungIndex == 0)
    }

    /// On a lossy link the native rung's floor arms the step-down but never holds the bitrate up: cuts continue to
    /// the global floor (as the 720p ladder's did), and the step down comes 3 s after reaching the rung floor.
    @Test func sharpStepsDownCleanlyAtTheRungFloor() {
        var c = AdaptationController(configuration: .init().resolved(sourceWidth: 1600, sourceHeight: 900))
        // 4000 → 2800 (below the 3250 floor at t=0) → 1959 → 1371 → 1000; step down at t=3.
        let d = run(&c, from: 0, ticks: 6, lossy(20))
        #expect(Array(d.map(\.bitrateKbps).prefix(3)) == [2800, 1959, 1371])
        #expect(d[2].rungIndex == 0)
        #expect(d[3].rungChanged && d[3].rung.width == 1280)
        #expect(c.bitrateKbps <= 5000)
        // Down to the bottom; never below the global floor.
        run(&c, from: 6, ticks: 40, lossy(20))
        #expect(c.rungIndex == 3)
        #expect(c.bitrateKbps == 1000)
    }

    /// Bursty congestion (1–2 s bursts with clean ticks between them) must still step down: a clean tick between
    /// bursts does not forget the congestion, and the bitrate keeps falling below the rung floor meanwhile.
    @Test func burstyCongestionStillStepsDown() {
        var c = AdaptationController(configuration: .init().resolved(sourceWidth: 1600, sourceHeight: 900))
        var t = 0
        var steppedAt: Int?
        // Pattern: 2 s of 30 % loss, 1 s clean, repeated.
        while t < 30 && steppedAt == nil {
            let d = c.update(t % 3 == 2 ? clean(UInt64(t) * Self.second) : lossy(30)(UInt64(t) * Self.second))
            if d.rungChanged { steppedAt = t }
            t += 1
        }
        #expect(steppedAt != nil, "never stepped down under bursty congestion")
        #expect((steppedAt ?? 99) <= 6)
        #expect(c.rung.width == 1280)
        // The bitrate was never held at the 3250 floor: the cuts went below it.
        #expect(c.bitrateKbps < 3250)

        // A long quiet period forgets congestion: one congested tick after it does not step down.
        var q = AdaptationController(configuration: .init().resolved(sourceWidth: 1600, sourceHeight: 900))
        run(&q, from: 0, ticks: 2, lossy(30))           // 4000 → 2800 → 1960, below the floor
        run(&q, from: 2, ticks: 6, clean)               // > 5 s without congestion
        let after = run(&q, from: 8, ticks: 2, lossy(30))
        #expect(after.allSatisfy { !$0.rungChanged })
        #expect(q.rungIndex == 0)
    }

    /// A Host whose encoder cannot keep up with the native rung must not cycle up and down every ~13 s: each
    /// overload step-down doubles the clean time needed to return, and the third blocks the rung for the session.
    @Test func encoderOverloadBacksOffAndThenBlocksTheRung() {
        var c = AdaptationController(configuration: .init().resolved(sourceWidth: 1920, sourceHeight: 1080))
        let overloaded = { (now: UInt64) in AdaptationController.Inputs(nowNanos: now, lossPercent: 0, rttMillis: 5,
                                                                       minRTTMillis: 4, encoderBackpressureDrops: 20) }
        var t = 0
        var stepUpDelays: [Int] = []
        for _ in 0..<3 {
            // Overloaded on the native rung until it steps down.
            while c.rungIndex == 0 && t < 1000 {
                _ = c.update(overloaded(UInt64(t) * Self.second))
                t += 1
            }
            #expect(c.rungIndex == 1)
            // Clean on 720p (the encoder keeps up there): how long until it tries native again?
            let downAt = t
            while c.rungIndex == 1 && t - downAt < 200 {
                _ = c.update(clean(UInt64(t) * Self.second))
                t += 1
            }
            stepUpDelays.append(c.rungIndex == 0 ? t - downAt : -1)
        }
        // 1st return after ≥ 20 s, 2nd after ≥ 40 s, and after the 3rd overload the rung is never tried again.
        #expect(stepUpDelays.count == 3)
        #expect(stepUpDelays[0] >= 20 && stepUpDelays[0] < 40, "\(stepUpDelays)")
        #expect(stepUpDelays[1] >= 40 && stepUpDelays[1] < 80, "\(stepUpDelays)")
        #expect(stepUpDelays[2] == -1, "\(stepUpDelays)")
        #expect(c.stepUpCleanNanos == nil)
        // Network-caused step-downs are not remembered this way.
        var n = AdaptationController(configuration: .init().resolved(sourceWidth: 1920, sourceHeight: 1080))
        run(&n, from: 0, ticks: 5, lossy(20))
        #expect(n.rungIndex == 1)
        #expect(n.stepUpCleanNanos == 10 * Self.second)
    }

    @Test func overloadStepDownClampsToTheSmallerRungCeiling() {
        var config = AdaptationController.Configuration().resolved(sourceWidth: 1600, sourceHeight: 900)
        config.initialBitrateKbps = 8000
        var c = AdaptationController(configuration: config)
        let overloaded = { (now: UInt64) in AdaptationController.Inputs(nowNanos: now, lossPercent: 0,
                                                                       encoderBackpressureDrops: 20) }
        let d = run(&c, from: 0, ticks: 4, overloaded)
        #expect(d[3].rungChanged)
        #expect(c.rungIndex == 1)
        #expect(c.bitrateKbps == 5000)
    }

    /// After a bad patch the stream must find its way back to the native rung on a clean link.
    @Test func stepUpBackToTheNativeRungIsReachable() {
        var c = AdaptationController(configuration: .init().resolved(sourceWidth: 1600, sourceHeight: 900))
        run(&c, from: 0, ticks: 60, lossy(20))
        #expect(c.rungIndex == 3)
        var t = 60
        while t < 300 && c.rungIndex > 0 {
            _ = c.update(clean(UInt64(t) * Self.second))
            t += 1
        }
        #expect(c.rungIndex == 0, "stuck at rung \(c.rungIndex)")
        #expect(t - 60 <= 120, "took \(t - 60) s")
        run(&c, from: t, ticks: 40, clean)
        #expect(c.bitrateKbps == 8250)
    }

    @Test func stepUpGateIsRelativeToTheTargetCeiling() {
        let config = AdaptationController.Configuration().resolved(sourceWidth: 1600, sourceHeight: 900)
        // 720p → native: 60 % of 8250 = 4950, below the 5000 the 720p rung can reach.
        #expect(AdaptationController(configuration: config, initialRungIndex: 1).stepUpGateKbps == 4950)
        // 540p30 (1250 ceiling) → 540p60 (2750): the whole current ceiling, since 60 % of 2750 is out of reach.
        #expect(AdaptationController(configuration: config, initialRungIndex: 3).stepUpGateKbps == 1250)
        #expect(AdaptationController(configuration: config).stepUpGateKbps == .max)
        // Balanced: the previous fixed 3000 kbps gate.
        #expect(AdaptationController(configuration: .balanced, initialRungIndex: 1).stepUpGateKbps == 3000)
    }

    @Test func qualityMapsToTheRightProfile() {
        var base = AdaptationController.Configuration()
        base.stepDownAfterNanos = 0   // tuned timing survives the quality choice
        #expect(StreamQuality.sharp.adaptation(base: base) == base)
        let balanced = StreamQuality.balanced.adaptation(base: base)
        #expect(balanced.ladder == AdaptationController.balancedLadder)
        #expect(balanced.maxBitrateKbps == 5000 && balanced.minBitrateKbps == 1000)
        #expect(!balanced.scalesBitrateToPicture)
        #expect(balanced.stepDownAfterNanos == 0)
        #expect(StreamQuality.sharp.streamSize(displayPixelWidth: 1600, displayPixelHeight: 900)! == (1600, 900))
        #expect(StreamQuality.balanced.streamSize(displayPixelWidth: 1600, displayPixelHeight: 900)! == (1280, 720))
        #expect(StreamQuality.sharp.streamSize(displayPixelWidth: 2880, displayPixelHeight: 1800)! == (1728, 1080))
        #expect(StreamQuality.sharp.streamSize(displayPixelWidth: 0, displayPixelHeight: 0) == nil)
        #expect(StreamQuality.sharp.label == "Sharp — native resolution, up to 1920×1080")
        #expect(StreamQuality.balanced.label == "Balanced — up to 1280×720")
    }
}

@Suite struct KeyframeRequestLimiterTests {
    @Test func honorsAtMostOncePerInterval() {
        var l = KeyframeRequestLimiter()
        #expect(l.shouldHonor(nowNanos: 1_000_000_000) == true)
        #expect(l.shouldHonor(nowNanos: 1_050_000_000) == false)
        #expect(l.shouldHonor(nowNanos: 1_099_000_000) == false)
        #expect(l.shouldHonor(nowNanos: 1_100_000_000) == true)
        #expect(l.honored == 2)
        #expect(l.ignored == 2)
    }

    @Test func suppressesRequestsRightAfterAKeyframeWasSent() {
        var l = KeyframeRequestLimiter(minIntervalNanos: 100_000_000, suppressAfterKeyframeNanos: 150_000_000)
        l.keyframeSent(atNanos: 1_000_000_000)
        #expect(l.shouldHonor(nowNanos: 1_100_000_000) == false)
        #expect(l.shouldHonor(nowNanos: 1_150_000_000) == true)
    }

    @Test func clockGoingBackwardsDoesNotWrap() {
        var l = KeyframeRequestLimiter()
        #expect(l.shouldHonor(nowNanos: 5_000_000_000) == true)
        #expect(l.shouldHonor(nowNanos: 4_000_000_000) == false)
    }
}

@Suite struct SecureRandomTests {
    @Test func producesRequestedSizesAndDistinctValues() throws {
        #expect(try SecureRandom.bytes(0).isEmpty)
        let a = try SecureRandom.sessionToken()
        let b = try SecureRandom.sessionToken()
        #expect(a.count == 16)
        #expect(a != b)
        var ids = Set<UInt32>()
        for _ in 0..<200 {
            let id = try SecureRandom.sessionId()
            #expect(id != 0)
            ids.insert(id)
        }
        #expect(ids.count > 195)
    }
}
