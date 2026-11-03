import CaptureCore
import Foundation

/// Host-side bitrate / resolution / frame-rate adaptation (PRD §5 "adapt down first; do not overprotect sharpness").
///
/// Policy, in order of preference — responsiveness first, picture quality last:
/// 1. **Bitrate, fast down / slow up.** Any congestion signal cuts the target by `decreaseFactor` (×0.7), at most once
///    per `decreaseCooldownNanos` so the encoder and network get time to react. A clean network adds
///    `max(increaseStepKbps, increaseStepFractionOfCeiling × rung ceiling)` (+250 at a 5000 kbps ceiling) per
///    `increaseIntervalNanos` (2 s) of continuous clean time. AIMD-style, so a queue that is building drains quickly
///    while probing back up stays gentle.
///    Cuts always continue down to the global floor: a rung's floor never holds the bitrate up during congestion.
/// 2. **Ladder down after sustained trouble.** If congestion keeps recurring at or below the current rung's bitrate
///    floor for `stepDownAfterNanos` — at least `stepDownMinCongestedTicks` congested ticks, none more than
///    `congestionMemoryNanos` apart, so bursty loss with short clean gaps still counts — or the encoder itself is
///    overloaded for that long, step down one rung (Sharp: up to 1920×1080@60 → 1280×720@60 → 960×540@60 →
///    960×540@30). Resolution goes before frame rate because frame rate is what makes remote control feel responsive.
/// 3. **Ladder up only after a long clean period.** `stepUpAfterNanos` (10 s) of continuous clean time *and* a bitrate
///    of at least `min(current rung ceiling, stepUpMinFractionOfTargetCeiling × target rung ceiling)` are both
///    required, so the controller does not oscillate and the step back up to a larger rung is always reachable.
///    A rung the *encoder* could not keep up with is remembered: each overload step-down from it doubles the clean
///    time needed to return (up to `overloadBackoffMaxDoublings`), and after `overloadStepDownsToBlockRung` it is not
///    tried again this session — otherwise a Host that cannot encode its native size cycles up and down every ~13 s.
///
/// Bitrate is scaled to the picture: each rung may carry its own ceiling and floor (`Rung.maxBitrateKbps` /
/// `minBitrateKbps`). `Configuration.resolved(sourceWidth:sourceHeight:)` derives them from the size the rung
/// *actually* encodes on a given display (rungs are bounds and capture never upscales), so a 1600×900 display gets a
/// 1600×900 ceiling, not a 1080p one, and rungs that collapse to the same size are dropped.
///
/// Hysteresis: thresholds come in pairs. Above the *congested* threshold we back off; below the *clean* threshold
/// we probe up; in between ("neutral") we hold, and the clean timer restarts. Random loss of 1–3 % (Milestone B) is
/// below the congestion threshold on purpose: it costs keyframes, not bandwidth, and backing off would not cure it.
///
/// Pure value type: the caller passes the clock in `Inputs.nowNanos`; nothing here reads time or touches I/O.
public struct AdaptationController: Sendable, Equatable {
    /// One step of the resolution / frame-rate ladder. Width and height are *bounds*: the capture keeps the display's
    /// aspect ratio inside them and never upscales (see `CaptureGeometry.fit`).
    public struct Rung: Sendable, Equatable, Hashable, CustomStringConvertible {
        public var width: Int
        public var height: Int
        public var fps: Int
        /// Highest target bitrate on this rung; nil = `Configuration.maxBitrateKbps`.
        public var maxBitrateKbps: Int?
        /// Sustained congestion at or below this bitrate steps down a rung; nil = `Configuration.minBitrateKbps`.
        public var minBitrateKbps: Int?

        public init(width: Int, height: Int, fps: Int, maxBitrateKbps: Int? = nil, minBitrateKbps: Int? = nil) {
            self.width = width
            self.height = height
            self.fps = fps
            self.maxBitrateKbps = maxBitrateKbps
            self.minBitrateKbps = minBitrateKbps
        }

        public var description: String { "\(width)×\(height)@\(fps)" }
    }

    /// Bitrate ceiling (kbps) for an encoded picture: 5000 kbps at 1280×720@60 (the PRD's starting point), scaled by
    /// pixel rate to the power 1.1 — a little more than linear because desktop text at higher resolutions has more
    /// fine detail per pixel, not less. Rounded to 250 kbps. 1600×900@60 ≈ 8250, 1920×1080@60 ≈ 12250 (capped by
    /// `Configuration.maxBitrateKbps`), 960×540@60 ≈ 2750, 960×540@30 ≈ 1250.
    public static func bitrateCeilingKbps(width: Int, height: Int, fps: Int) -> Int {
        guard width > 0, height > 0, fps > 0 else { return referenceCeilingKbps }
        let ratio = Double(width) * Double(height) * Double(fps) / referencePixelRate
        return roundToStep(Double(referenceCeilingKbps) * pow(ratio, 1.1))
    }

    /// Floor of a non-bottom rung: 40 % of its ceiling. Below that a smaller picture at a healthier bitrate looks
    /// better than a starved large one, so congestion that keeps recurring at or below it steps the ladder down.
    /// It never holds the bitrate up: congestion cuts continue to the global floor meanwhile.
    public static func bitrateFloorKbps(ceilingKbps: Int) -> Int {
        roundToStep(Double(ceilingKbps) * 0.4)
    }

    /// A rung whose bitrate range follows its bounds (used by the static ladder before a display is known).
    static func scaledRung(width: Int, height: Int, fps: Int, isBottom: Bool) -> Rung {
        let ceiling = bitrateCeilingKbps(width: width, height: height, fps: fps)
        return Rung(width: width, height: height, fps: fps, maxBitrateKbps: ceiling,
                    minBitrateKbps: isBottom ? nil : bitrateFloorKbps(ceilingKbps: ceiling))
    }

    private static let referencePixelRate = 1280.0 * 720.0 * 60.0
    private static let referenceCeilingKbps = 5000

    private static func roundToStep(_ kbps: Double) -> Int {
        guard kbps.isFinite, kbps > 0 else { return 0 }
        return Int((kbps / 250).rounded()) * 250
    }

    /// "Sharp": native resolution up to 1920×1080 (a 1600×900 display streams at exactly 1600×900), with a bitrate
    /// range per rung. The 1280×720 rung below it is the previous, known-good top rung, so a lossy link first falls
    /// back to exactly what earlier versions streamed.
    public static let defaultLadder: [Rung] = [
        scaledRung(width: 1920, height: 1080, fps: 60, isBottom: false),
        scaledRung(width: 1280, height: 720, fps: 60, isBottom: false),
        scaledRung(width: 960, height: 540, fps: 60, isBottom: false),
        scaledRung(width: 960, height: 540, fps: 30, isBottom: true),
    ]

    /// "Balanced" (and every version before 0.1.3): 1280×720 at most, one shared 1000–5000 kbps range.
    public static let balancedLadder: [Rung] = [
        Rung(width: 1280, height: 720, fps: 60),
        Rung(width: 960, height: 540, fps: 60),
        Rung(width: 960, height: 540, fps: 30),
    ]

    public struct Configuration: Sendable, Equatable {
        public var ladder: [Rung] = AdaptationController.defaultLadder
        /// Global bounds; a rung's own range (if any) is clamped into them.
        public var minBitrateKbps = 1000
        public var maxBitrateKbps = 12000
        /// Starting bitrate; nil = `initialBitrateFractionOfCeiling` of the first rung's ceiling, at most
        /// `initialBitrateMaxKbps` (3000 kbps at a 5000 kbps ceiling, 4000 for a 1600×900 or 1080p display). The
        /// link may be lossy, so a native rung starts near what 720p used to and probes up (5 % of its ceiling per
        /// 2 s clean) rather than flooding the link with large frames before the first cut.
        public var initialBitrateKbps: Int?
        public var initialBitrateFractionOfCeiling = 0.6
        public var initialBitrateMaxKbps = 4000
        /// When true, `resolved(sourceWidth:sourceHeight:)` replaces each rung's range with one derived from the size
        /// it really encodes (`bitrateCeilingKbps`). False keeps the ladder's own ranges (Balanced: none).
        public var scalesBitrateToPicture = true

        public var decreaseFactor = 0.7
        public var decreaseCooldownNanos: UInt64 = 1_000_000_000
        /// Clean-network probe step: the larger of this and `increaseStepFractionOfCeiling` × the rung ceiling, so
        /// climbing back to a 8–12 Mbps ceiling takes about as long as climbing to 5 Mbps did.
        public var increaseStepKbps = 250
        public var increaseStepFractionOfCeiling = 0.05
        public var increaseIntervalNanos: UInt64 = 2_000_000_000

        /// Viewer-reported packet loss at or above this is congestion.
        public var congestedLossPercent = 5.0
        /// Loss below this counts as clean.
        public var cleanLossPercent = 1.0
        /// RTT above `minRtt + max(floor, minRtt × factor)` is congestion (a queue is building somewhere).
        public var congestedRTTInflationFloorMillis = 50.0
        public var congestedRTTInflationFactor = 1.0
        /// RTT below `minRtt + max(floor, minRtt × factor)` counts as clean.
        public var cleanRTTInflationFloorMillis = 20.0
        public var cleanRTTInflationFactor = 0.5
        /// Transport send backlog, in milliseconds of video at the current target bitrate (bytes × 8 / kbps), so the
        /// signal means the same thing across the whole 1000–12000 kbps range. 350 / 85 ms are the previous fixed
        /// 128 KiB / 32 KiB thresholds at 3000 kbps; at the 1000 kbps floor a fixed 128 KiB was over a second of
        /// queued video.
        public var congestedBacklogMillis = 350.0
        public var cleanBacklogMillis = 85.0
        /// Encoder overload: more than this fraction of the rung's frames dropped by the one-in-flight rule.
        public var encoderOverloadFraction = 0.15
        /// Viewer presenting fewer than this fraction of the frames the host sent (with enough frames to judge).
        public var viewerSlowFraction = 0.6
        public var viewerSlowMinimumSentFPS = 20.0

        public var stepDownAfterNanos: UInt64 = 3_000_000_000
        /// Congested ticks at or below the rung floor needed (over at least `stepDownAfterNanos`) to step down.
        public var stepDownMinCongestedTicks = 3
        /// A gap without congestion longer than this forgets the congestion counted toward a step-down. Shorter gaps
        /// (between loss bursts) do not: bursty congestion is still congestion.
        public var congestionMemoryNanos: UInt64 = 5_000_000_000
        public var stepUpAfterNanos: UInt64 = 10_000_000_000
        /// Each encoder-overload step-down from a rung doubles the clean time needed to step back up to it, at most
        /// this many times (10 s → 20 → 40 → 80 s).
        public var overloadBackoffMaxDoublings = 3
        /// After this many encoder-overload step-downs from a rung it is not stepped up to again this session.
        public var overloadStepDownsToBlockRung = 3
        /// Step-up gate: the bitrate must reach this fraction of the *target* rung's ceiling (3000 of 5000 kbps for
        /// Balanced), or the current rung's whole ceiling if that is lower — so stepping up is always reachable.
        public var stepUpMinFractionOfTargetCeiling = 0.6

        public init() {}

        /// Sharp (the default): native resolution up to 1920×1080, bitrate scaled to the picture.
        public static var sharp: Configuration { Configuration() }

        /// Balanced: today's 1280×720 ladder and one 1000–5000 kbps range, for weak Wi-Fi.
        public static var balanced: Configuration {
            var c = Configuration()
            c.ladder = AdaptationController.balancedLadder
            c.maxBitrateKbps = 5000
            c.scalesBitrateToPicture = false
            return c
        }

        /// This configuration fitted to a source (display) of `sourceWidth × sourceHeight` pixels: rungs whose fitted
        /// size and frame rate equal the rung above are dropped (a step down to them would change nothing but still
        /// cost an encoder rebuild and a keyframe), and, with `scalesBitrateToPicture`, each rung's bitrate range is
        /// derived from its fitted size. The first rung is always kept, so the capture bounds do not change.
        public func resolved(sourceWidth: Int, sourceHeight: Int) -> Configuration {
            guard sourceWidth > 0, sourceHeight > 0, !ladder.isEmpty else { return self }
            var kept: [(rung: Rung, width: Int, height: Int)] = []
            for rung in ladder {
                let size = CaptureGeometry.fit(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                               maxWidth: rung.width, maxHeight: rung.height)
                if let last = kept.last, last.width == size.width, last.height == size.height, last.rung.fps == rung.fps {
                    continue
                }
                kept.append((rung, size.width, size.height))
            }
            var out = self
            out.ladder = kept.enumerated().map { index, entry in
                var rung = entry.rung
                if scalesBitrateToPicture {
                    let ceiling = AdaptationController.bitrateCeilingKbps(width: entry.width, height: entry.height,
                                                                          fps: rung.fps)
                    rung.maxBitrateKbps = ceiling
                    rung.minBitrateKbps = index == kept.count - 1
                        ? nil : AdaptationController.bitrateFloorKbps(ceilingKbps: ceiling)
                }
                return rung
            }
            return out
        }
    }

    /// One observation window (the host feeds one per ~1 s tick).
    public struct Inputs: Sendable, Equatable {
        public var nowNanos: UInt64
        /// Viewer-reported packet loss over its last STATS window; nil if no report arrived.
        public var lossPercent: Double?
        public var rttMillis: Double?
        public var minRTTMillis: Double?
        public var sendBacklogBytes: Int
        /// Frames the encoder refused since the previous tick (one-in-flight rule).
        public var encoderBackpressureDrops: UInt64
        /// Datagram batches the transport refused since the previous tick.
        public var sendBackpressureDrops: UInt64
        /// Frames per second the Viewer reports presenting; nil if unknown.
        public var viewerFPS: Double?
        /// Frames per second the host actually sent over the same period; nil if unknown.
        public var hostSentFPS: Double?

        public init(nowNanos: UInt64, lossPercent: Double? = nil, rttMillis: Double? = nil, minRTTMillis: Double? = nil,
                    sendBacklogBytes: Int = 0, encoderBackpressureDrops: UInt64 = 0, sendBackpressureDrops: UInt64 = 0,
                    viewerFPS: Double? = nil, hostSentFPS: Double? = nil) {
            self.nowNanos = nowNanos
            self.lossPercent = lossPercent
            self.rttMillis = rttMillis
            self.minRTTMillis = minRTTMillis
            self.sendBacklogBytes = sendBacklogBytes
            self.encoderBackpressureDrops = encoderBackpressureDrops
            self.sendBackpressureDrops = sendBackpressureDrops
            self.viewerFPS = viewerFPS
            self.hostSentFPS = hostSentFPS
        }
    }

    /// Which signals fired in a tick (diagnostics; never content).
    public struct Signals: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let loss = Signals(rawValue: 1 << 0)
        public static let rttInflation = Signals(rawValue: 1 << 1)
        public static let backlog = Signals(rawValue: 1 << 2)
        public static let sendBackpressure = Signals(rawValue: 1 << 3)
        public static let viewerSlow = Signals(rawValue: 1 << 4)
        public static let encoderOverload = Signals(rawValue: 1 << 5)

        /// Comma-separated names of the signals that are set, e.g. "loss,backlog" (diagnostics).
        public var names: String {
            let all: [(Signals, String)] = [(.loss, "loss"), (.rttInflation, "rtt"), (.backlog, "backlog"),
                                            (.sendBackpressure, "sendRefused"), (.viewerSlow, "viewerSlow"),
                                            (.encoderOverload, "encoderOverload")]
            return all.filter { contains($0.0) }.map(\.1).joined(separator: ",")
        }
    }

    public enum Condition: Sendable, Equatable {
        case congested, neutral, clean
    }

    public struct Decision: Sendable, Equatable {
        public var bitrateKbps: Int
        public var rung: Rung
        public var rungIndex: Int
        public var bitrateChanged: Bool
        public var rungChanged: Bool
        public var condition: Condition
        public var signals: Signals
    }

    public let configuration: Configuration
    public private(set) var bitrateKbps: Int
    public private(set) var rungIndex: Int

    private var lastTickNanos: UInt64?
    private var lastDecreaseNanos: UInt64?
    private var lastIncreaseNanos: UInt64?
    private var lastRungChangeNanos: UInt64?
    private var cleanSinceNanos: UInt64?
    private var congestedAtMinSinceNanos: UInt64?
    private var lastCongestedAtMinNanos: UInt64?
    private var congestedAtMinTicks = 0
    private var overloadedSinceNanos: UInt64?
    /// Encoder-overload step-downs *from* each rung (indexed like the ladder).
    private var overloadStepDowns: [Int]

    public init(configuration: Configuration = Configuration(), initialRungIndex: Int = 0) {
        precondition(!configuration.ladder.isEmpty, "ladder must not be empty")
        precondition(configuration.minBitrateKbps > 0 && configuration.minBitrateKbps <= configuration.maxBitrateKbps)
        self.configuration = configuration
        let index = min(max(initialRungIndex, 0), configuration.ladder.count - 1)
        self.rungIndex = index
        let ceiling = Self.ceiling(of: configuration.ladder[index], configuration)
        let initial = configuration.initialBitrateKbps
            ?? min(configuration.initialBitrateMaxKbps,
                   Int((Double(ceiling) * configuration.initialBitrateFractionOfCeiling).rounded()))
        self.bitrateKbps = min(max(initial, configuration.minBitrateKbps), ceiling)
        self.overloadStepDowns = Array(repeating: 0, count: configuration.ladder.count)
    }

    public var rung: Rung { configuration.ladder[rungIndex] }

    /// Highest bitrate the current rung allows (its own ceiling clamped into the global range).
    public var currentCeilingKbps: Int { Self.ceiling(of: rung, configuration) }

    /// Bitrate at or below which sustained congestion steps down from the current rung.
    public var currentFloorKbps: Int { Self.floor(of: rung, configuration) }

    /// Feeds one observation window and returns the (possibly unchanged) target.
    public mutating func update(_ inputs: Inputs) -> Decision {
        let c = configuration
        let now = inputs.nowNanos
        let interval = lastTickNanos.map { Self.elapsed($0, now) } ?? 1_000_000_000
        lastTickNanos = now

        let (signals, allClean) = classify(inputs, intervalNanos: interval)
        let networkCongested = !signals.subtracting(.encoderOverload).isEmpty
        let overloaded = signals.contains(.encoderOverload)
        let condition: Condition = networkCongested || overloaded ? .congested : (allClean ? .clean : .neutral)

        let startBitrate = bitrateKbps
        let startRung = rungIndex

        // Congestion counted toward a step-down is forgotten only after a real quiet period, not one clean tick
        // between loss bursts.
        if let last = lastCongestedAtMinNanos, Self.elapsed(last, now) > c.congestionMemoryNanos {
            resetCongestionAtMin()
        }

        if networkCongested {
            cleanSinceNanos = nil
            let floor = currentFloorKbps
            if lastDecreaseNanos.map({ Self.elapsed($0, now) >= c.decreaseCooldownNanos }) ?? true {
                // Cuts go all the way to the global floor; the rung floor only arms the step-down below.
                let reduced = Int((Double(bitrateKbps) * c.decreaseFactor).rounded(.down))
                bitrateKbps = max(c.minBitrateKbps, reduced)
                if bitrateKbps != startBitrate { lastDecreaseNanos = now }
            }
            if bitrateKbps <= floor {
                let since = congestedAtMinSinceNanos ?? now
                congestedAtMinSinceNanos = since
                lastCongestedAtMinNanos = now
                congestedAtMinTicks += 1
                if Self.elapsed(since, now) >= c.stepDownAfterNanos, congestedAtMinTicks >= c.stepDownMinCongestedTicks,
                   stepDown(now: now) {
                    resetCongestionAtMin()
                }
            }
        }

        if overloaded {
            cleanSinceNanos = nil
            let since = overloadedSinceNanos ?? now
            overloadedSinceNanos = since
            let from = rungIndex
            if Self.elapsed(since, now) >= c.stepDownAfterNanos, stepDown(now: now) {
                overloadedSinceNanos = nil
                overloadStepDowns[from] += 1
            }
        } else {
            overloadedSinceNanos = nil
        }

        if condition == .clean {
            let since = cleanSinceNanos ?? now
            cleanSinceNanos = since
            let ceiling = currentCeilingKbps
            let increaseFrom = max(since, lastIncreaseNanos ?? 0, lastDecreaseNanos ?? 0)
            if Self.elapsed(increaseFrom, now) >= c.increaseIntervalNanos, bitrateKbps < ceiling {
                let step = max(c.increaseStepKbps, Int(Double(ceiling) * c.increaseStepFractionOfCeiling))
                bitrateKbps = min(ceiling, bitrateKbps + step)
                lastIncreaseNanos = now
            }
            let stepUpFrom = max(since, lastRungChangeNanos ?? 0)
            if let required = stepUpCleanNanos, bitrateKbps >= stepUpGateKbps,
               Self.elapsed(stepUpFrom, now) >= required {
                rungIndex -= 1
                lastRungChangeNanos = now
                bitrateKbps = min(bitrateKbps, currentCeilingKbps)
            }
        } else if condition == .neutral {
            cleanSinceNanos = nil
        }

        return Decision(bitrateKbps: bitrateKbps, rung: rung, rungIndex: rungIndex,
                        bitrateChanged: bitrateKbps != startBitrate, rungChanged: rungIndex != startRung,
                        condition: condition, signals: signals)
    }

    /// Bitrate needed (with a long clean period) to step up from the current rung; `Int.max` on the top rung.
    public var stepUpGateKbps: Int {
        guard rungIndex > 0 else { return .max }
        let target = Self.ceiling(of: configuration.ladder[rungIndex - 1], configuration)
        let fraction = Int((Double(target) * configuration.stepUpMinFractionOfTargetCeiling).rounded())
        return min(currentCeilingKbps, fraction)
    }

    /// Continuous clean time needed to step up from the current rung: `stepUpAfterNanos`, doubled for every
    /// encoder-overload step-down from the target rung; nil on the top rung or when the target rung is blocked.
    public var stepUpCleanNanos: UInt64? {
        guard rungIndex > 0 else { return nil }
        let c = configuration
        let overloads = overloadStepDowns[rungIndex - 1]
        if c.overloadStepDownsToBlockRung > 0, overloads >= c.overloadStepDownsToBlockRung { return nil }
        let doublings = min(overloads, max(0, min(c.overloadBackoffMaxDoublings, 16)))
        let (scaled, overflow) = c.stepUpAfterNanos.multipliedReportingOverflow(by: UInt64(1) << UInt64(doublings))
        return overflow ? .max : scaled
    }

    // MARK: Private

    private mutating func resetCongestionAtMin() {
        congestedAtMinSinceNanos = nil
        lastCongestedAtMinNanos = nil
        congestedAtMinTicks = 0
    }

    private mutating func stepDown(now: UInt64) -> Bool {
        guard rungIndex < configuration.ladder.count - 1 else { return false }
        rungIndex += 1
        lastRungChangeNanos = now
        // An encoder-overload step keeps the bitrate; never carry a larger rung's bitrate onto a smaller picture.
        bitrateKbps = min(bitrateKbps, currentCeilingKbps)
        return true
    }

    private static func ceiling(of rung: Rung, _ c: Configuration) -> Int {
        max(c.minBitrateKbps, min(c.maxBitrateKbps, rung.maxBitrateKbps ?? c.maxBitrateKbps))
    }

    private static func floor(of rung: Rung, _ c: Configuration) -> Int {
        min(ceiling(of: rung, c), max(c.minBitrateKbps, rung.minBitrateKbps ?? c.minBitrateKbps))
    }

    /// Returns the congestion signals that fired and whether every metric is inside its *clean* band.
    private func classify(_ i: Inputs, intervalNanos: UInt64) -> (Signals, Bool) {
        let c = configuration
        var signals: Signals = []
        var clean = true

        if let loss = i.lossPercent, loss.isFinite {
            if loss >= c.congestedLossPercent { signals.insert(.loss) }
            if loss >= c.cleanLossPercent { clean = false }
        }

        if let rtt = i.rttMillis, let minRTT = i.minRTTMillis, rtt.isFinite, minRTT.isFinite, minRTT >= 0 {
            let inflation = max(0, rtt - minRTT)
            let congestedAt = max(c.congestedRTTInflationFloorMillis, minRTT * c.congestedRTTInflationFactor)
            let cleanBelow = max(c.cleanRTTInflationFloorMillis, minRTT * c.cleanRTTInflationFactor)
            if inflation > congestedAt { signals.insert(.rttInflation) }
            if inflation >= cleanBelow { clean = false }
        }

        let backlogMillis = Double(max(0, i.sendBacklogBytes)) * 8 / Double(max(1, bitrateKbps))
        if backlogMillis > c.congestedBacklogMillis { signals.insert(.backlog) }
        if backlogMillis > c.cleanBacklogMillis { clean = false }

        if i.sendBackpressureDrops > 0 {
            signals.insert(.sendBackpressure)
            clean = false
        }

        if let viewer = i.viewerFPS, let sent = i.hostSentFPS, viewer.isFinite, sent.isFinite,
           sent >= c.viewerSlowMinimumSentFPS {
            if viewer < sent * c.viewerSlowFraction { signals.insert(.viewerSlow) }
            if viewer < sent * 0.9 { clean = false }
        }

        let expectedFrames = Double(rung.fps) * Double(intervalNanos) / 1_000_000_000
        let overloadThreshold = max(1.0, expectedFrames * c.encoderOverloadFraction)
        if Double(i.encoderBackpressureDrops) > overloadThreshold {
            signals.insert(.encoderOverload)
        }
        if i.encoderBackpressureDrops > 0 && Double(i.encoderBackpressureDrops) > overloadThreshold / 2 {
            clean = false
        }

        return (signals, clean && signals.isEmpty)
    }

    private static func elapsed(_ start: UInt64, _ now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }
}
