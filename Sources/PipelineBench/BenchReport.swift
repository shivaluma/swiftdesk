import DiagnosticsCore
import Foundation
import WireProtocol

/// Host facts printed with every run, so numbers are never quoted without the machine and OS they came from.
struct MachineInfo: Sendable {
    var model: String
    var chip: String
    var osVersion: String
    var osBuild: String
    var cpuCount: Int

    static func current() -> MachineInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(model: sysctlString("hw.model") ?? "unknown",
                           chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                           osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                           osBuild: sysctlString("kern.osversion") ?? "unknown",
                           cpuCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Process CPU time (user + system), to put the pipeline's cost next to its latency.
enum ProcessCPU {
    static func seconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}

/// Final numbers of one run, independent of how they were collected, so formatting is testable.
struct BenchResult: Sendable {
    struct Stage: Sendable {
        var key: String
        var label: String
        var summary: RollingStats.Summary
        var p99: Double
    }

    var options: BenchOptions
    var machine: MachineInfo
    var sourceDescription: String
    var width: Int
    var height: Int
    var durationSeconds: Double
    var cpuSeconds: Double

    var framesGenerated: UInt64
    var framesSourceSkipped: UInt64
    var framesSizeMismatch: UInt64
    var framesSubmitted: UInt64
    var framesDroppedBackpressure: UInt64
    var framesEncoderDropped: UInt64
    /// Frames that waited in the encoder's latest-frame slot and were submitted after the in-flight one.
    var framesWaitingSubmitted: UInt64 = 0
    /// Retained frames the encoder resubmitted after a quiet period (keyframe request / dropped newest frame).
    var refreshes: UInt64 = 0
    var framesEncoded: UInt64
    var keyframes: UInt64
    var recoveryKeyframes: UInt64
    var encodedBytes: UInt64
    var datagramsSent: UInt64
    var datagramBytes: UInt64
    var datagramsDropped: UInt64
    var framesReassembled: UInt64
    var framesDecoded: UInt64
    var decodeFailures: UInt64

    var framesLost: UInt64
    var lossEvents: UInt64
    var keyframeRequests: UInt64
    var keyframeRequestsFromTick: UInt64
    var framesGated: UInt64
    var endedAwaitingKeyframe: Bool
    var recovery: RollingStats.Summary

    var stages: [Stage]
    var fill: RollingStats.Summary?

    var hardwareEncoder: Bool?
    var requiredHardware: Bool
    var lowLatency: Bool
    var profileLevel: String?
    var appliedProperties: [String: Bool]
    var hardwareDecoder: Bool?
    var decoderRealTime: Bool?
    var decoderSessions: UInt64
    var stalledEncodeResets: UInt64
    var fec: FECSummary
    var notes: [String]

    struct FECSummary: Sendable {
        var parityDatagrams: UInt64 = 0
        var framesWithParity: UInt64 = 0
        var groupSizeSum: UInt64 = 0
        var finalGroupSize = 0
        var reassembly = FrameReassembler.Stats()

        /// Mean K over frames that carried parity (0 when none did).
        var meanGroupSize: Double { framesWithParity > 0 ? Double(groupSizeSum) / Double(framesWithParity) : 0 }
    }

    var encodeFPS: Double { durationSeconds > 0 ? Double(framesEncoded) / durationSeconds : 0 }
    var decodeFPS: Double { durationSeconds > 0 ? Double(framesDecoded) / durationSeconds : 0 }
    var videoKbps: Double { durationSeconds > 0 ? Double(encodedBytes) * 8 / durationSeconds / 1000 : 0 }
    var wireKbps: Double { durationSeconds > 0 ? Double(datagramBytes) * 8 / durationSeconds / 1000 : 0 }
    var measuredLossPercent: Double { datagramsSent > 0 ? Double(datagramsDropped) * 100 / Double(datagramsSent) : 0 }
    var cpuPercent: Double { durationSeconds > 0 ? cpuSeconds * 100 / durationSeconds : 0 }

    // MARK: Formatting

    static func ms(_ v: Double) -> String { String(format: "%.3f", v) }
    static func flag(_ v: Bool?) -> String { v.map { $0 ? "true" : "false" } ?? "unknown" }

    /// Human-readable report followed by exactly one machine-readable `RESULT` line (last line of output).
    func render() -> String {
        var lines: [String] = []
        func add(_ s: String = "") { lines.append(s) }

        add("== SwiftDesk PipelineBench (Milestone A, headless loopback) ==")
        add("machine        \(machine.model)  \(machine.chip)  \(machine.cpuCount) cores")
        add("macOS          \(machine.osVersion) (\(machine.osBuild))")
        add("mode           \(options.mode.rawValue): \(sourceDescription)")
        add("resolution     \(width)x\(height) @ \(options.fps) fps target, \(options.bitrateKbps) kbps target")
        add("duration       \(String(format: "%.2f", durationSeconds)) s, datagram size \(options.maxDatagramSize) B, "
            + "loss \(options.lossPercent)% (seed \(options.seed))"
            + (options.duplicateKeyframes ? ", keyframe datagrams sent twice" : "")
            + (options.fec == .off ? "" : ", FEC \(options.fec.label)"))
        add("process CPU    \(String(format: "%.1f", cpuPercent))% of one core (includes synthetic fill / harness)")
        add()
        add("-- frames --")
        add("generated                \(framesGenerated)")
        if framesSourceSkipped > 0 { add("source skipped (pool)    \(framesSourceSkipped)") }
        if framesSizeMismatch > 0 { add("size mismatch dropped    \(framesSizeMismatch)") }
        add("submitted to encoder     \(framesSubmitted)")
        add("dropped (backpressure)   \(framesDroppedBackpressure)   one-in-flight rule (\(framesWaitingSubmitted) of them encoded next from the latest-frame slot)")
        if refreshes > 0 { add("refreshes (static)       \(refreshes)") }
        add("dropped by VideoToolbox  \(framesEncoderDropped)")
        add("encoded                  \(framesEncoded)   (\(String(format: "%.2f", encodeFPS)) fps effective)")
        add("keyframes                \(keyframes)   (\(recoveryKeyframes) in response to requests)")
        add("reassembled              \(framesReassembled)")
        add("decoded                  \(framesDecoded)   (\(String(format: "%.2f", decodeFPS)) fps)")
        if decodeFailures > 0 { add("decode failures          \(decodeFailures)") }
        add()
        add("-- bitrate --")
        add("video produced           \(String(format: "%.1f", videoKbps)) kbps (\(encodedBytes) B encoded)")
        add("on the wire              \(String(format: "%.1f", wireKbps)) kbps incl. 32 B headers (\(datagramsSent) datagrams)")
        add()
        add("-- latency (ms, whole run; nearest-rank) --")
        add("stage                              count      p50      p95      p99      max     mean")
        for stage in stages {
            let s = stage.summary
            add(stage.label.padding(toLength: 34, withPad: " ", startingAt: 0)
                + String(format: " %6d %8.3f %8.3f %8.3f %8.3f %8.3f", s.count, s.p50, s.p95, stage.p99, s.max, s.mean))
        }
        if let fill {
            add("(harness) synthetic CPU fill".padding(toLength: 34, withPad: " ", startingAt: 0)
                + String(format: " %6d %8.3f %8.3f        - %8.3f %8.3f", fill.count, fill.p50, fill.p95, fill.max, fill.mean))
        }
        add("source->decodeDone excludes network transit and render/present (no display in this bench).")
        add("max includes one-off warm-up (first IDR, decoder session creation); p99 shows the recurring tail.")
        add()
        add("-- encoder / decoder --")
        add("hardware encoder         \(Self.flag(hardwareEncoder)) (session required HW: \(requiredHardware))")
        add("low-latency rate control \(lowLatency)")
        add("profile level            \(profileLevel ?? "default")")
        add("applied properties       " + appliedProperties.keys.sorted()
            .map { "\($0)=\(appliedProperties[$0]! ? "yes" : "NO")" }.joined(separator: " "))
        add("hardware decoder         \(Self.flag(hardwareDecoder)), decoder RealTime applied \(Self.flag(decoderRealTime)), "
            + "\(decoderSessions) decoder session(s) created")
        if stalledEncodeResets > 0 { add("stalled encode resets    \(stalledEncodeResets)") }
        add()
        add("-- loss / recovery --")
        add("datagrams dropped        \(datagramsDropped) (\(String(format: "%.2f", measuredLossPercent))% measured)")
        add("frames lost              \(framesLost) in \(lossEvents) loss events")
        add("keyframe requests        \(keyframeRequests) (\(keyframeRequestsFromTick) from gate tick: deferred by rate limit or re-sent)")
        add("frames gated             \(framesGated) (complete but dropped while awaiting a keyframe)")
        if options.fec != .off {
            let r = fec.reassembly
            add("FEC                      \(options.fec.label): \(fec.parityDatagrams) parity datagrams on \(fec.framesWithParity) frames, "
                + String(format: "mean K %.2f", fec.meanGroupSize) + ", final K \(fec.finalGroupSize)")
            add("FEC at the viewer        \(r.fragmentsRecovered) fragments rebuilt, \(r.parityReceived) parity received "
                + "(\(r.parityStale) after their frame completed, \(r.parityUnused) unused, \(r.parityMalformed) malformed)")
        }
        add("recovery time            " + (recovery.count > 0
            ? String(format: "n=%d p50=%.3f p95=%.3f max=%.3f ms (loss detected -> keyframe decoded)",
                     recovery.count, recovery.p50, recovery.p95, recovery.max)
            : "n=0"))
        if endedAwaitingKeyframe { add("note: run ended while still awaiting a recovery keyframe") }
        for note in notes { add("note: \(note)") }
        add()
        add(resultLine())
        return lines.joined(separator: "\n")
    }

    /// `RESULT key=value ...` with no spaces inside values; times in ms, rates in fps/kbps.
    func resultLine() -> String {
        var kv: [(String, String)] = [
            ("mode", options.mode.rawValue),
            ("model", machine.model.replacingOccurrences(of: " ", with: "_")),
            ("macos", machine.osVersion),
            ("width", "\(width)"), ("height", "\(height)"), ("fps_target", "\(options.fps)"),
            ("bitrate_target_kbps", "\(options.bitrateKbps)"),
            ("loss_pct", String(format: "%g", options.lossPercent)),
            ("dup_keyframes", options.duplicateKeyframes ? "1" : "0"),
            ("fec", options.fec.label),
            ("seconds", String(format: "%.2f", durationSeconds)),
            ("generated", "\(framesGenerated)"), ("submitted", "\(framesSubmitted)"),
            ("dropped_backpressure", "\(framesDroppedBackpressure)"), ("encoded", "\(framesEncoded)"),
            ("decoded", "\(framesDecoded)"),
            ("encode_fps", String(format: "%.2f", encodeFPS)),
            ("video_kbps", String(format: "%.1f", videoKbps)), ("wire_kbps", String(format: "%.1f", wireKbps)),
            ("keyframes", "\(keyframes)"),
        ]
        for stage in stages {
            kv.append(("\(stage.key)_p50_ms", Self.ms(stage.summary.p50)))
            kv.append(("\(stage.key)_p95_ms", Self.ms(stage.summary.p95)))
            kv.append(("\(stage.key)_p99_ms", Self.ms(stage.p99)))
            kv.append(("\(stage.key)_max_ms", Self.ms(stage.summary.max)))
        }
        kv += [
            ("hw_encoder", Self.flag(hardwareEncoder)), ("low_latency", "\(lowLatency)"),
            ("hw_decoder", Self.flag(hardwareDecoder)), ("decoder_sessions", "\(decoderSessions)"),
            ("vt_dropped", "\(framesEncoderDropped)"),
            ("waiting_submitted", "\(framesWaitingSubmitted)"), ("refreshes", "\(refreshes)"),
            ("datagrams_dropped", "\(datagramsDropped)"),
            ("frames_lost", "\(framesLost)"), ("keyframe_requests", "\(keyframeRequests)"),
            ("frames_gated", "\(framesGated)"),
            ("recovery_count", "\(recovery.count)"),
            ("recovery_p50_ms", Self.ms(recovery.p50)),
            ("parity_datagrams", "\(fec.parityDatagrams)"),
            ("fragments_recovered", "\(fec.reassembly.fragmentsRecovered)"),
            ("fec_k_mean", String(format: "%.2f", fec.meanGroupSize)),
            ("decode_fps", String(format: "%.2f", decodeFPS)),
            ("cpu_pct", String(format: "%.1f", cpuPercent)),
        ]
        return "RESULT " + kv.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
