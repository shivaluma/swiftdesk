import Foundation

/// Where frames come from.
///
/// `synthetic` isolates the codec + wire path from ScreenCaptureKit (no permission, deterministic content), so its
/// numbers are the floor the real pipeline can reach. `capture` adds the real compositor/SCK path on top.
enum BenchMode: String, Sendable, Equatable, CaseIterable {
    case synthetic
    case capture
}

/// Forward error correction on the simulated wire (`WireProtocol.FECLayout`).
enum BenchFEC: Sendable, Equatable {
    /// No parity datagrams (the behaviour of every run before FEC existed).
    case off
    /// `FECPolicy` adapts K from the viewer's 1 s loss estimate, as the production Host does.
    case adaptive
    /// Always this K (1...255).
    case fixed(Int)

    /// RESULT-line value: `off`, `auto` or `k<N>`.
    var label: String {
        switch self {
        case .off: "off"
        case .adaptive: "auto"
        case .fixed(let k): "k\(k)"
        }
    }
}

/// Command-line configuration for one bench run.
///
/// Parsing is pure (no I/O) so the defaults and validation rules are checkable by `--self-test`; invalid values are
/// rejected up front rather than clamped, because a silently clamped bench run produces numbers for a configuration
/// nobody asked for.
struct BenchOptions: Sendable, Equatable {
    var seconds: Double = 10
    var mode: BenchMode = .synthetic
    var bitrateKbps: Int = 3000
    /// Independent per-datagram drop probability, in percent.
    var lossPercent: Double = 0
    var width: Int = 1280
    var height: Int = 720
    var fps: Int = 60
    /// Seed for the loss simulator, so a lossy run is reproducible packet-for-packet.
    var seed: UInt64 = 0x5D_E5C0_FFEE
    /// Whole datagram size including the 32-byte header (Tailscale-safe default from the contract).
    var maxDatagramSize: Int = 1150
    /// Send every keyframe datagram twice, as SessionCore's `HostMediaPipeline` does in production
    /// (`duplicateKeyframePackets`). Off by default so results stay comparable with earlier runs.
    var duplicateKeyframes = false
    /// Parity datagrams; off by default so results stay comparable with earlier runs.
    var fec: BenchFEC = .off
    var selfTest = false
    var help = false

    static let usage = """
    usage: PipelineBench [--seconds N] [--mode synthetic|capture] [--bitrate KBPS] [--loss PERCENT]
                         [--width W] [--height H] [--fps FPS] [--seed N] [--mtu BYTES] [--dup-keyframes]
                         [--fec | --fec-k K]
           PipelineBench --self-test
           PipelineBench --help

    Headless Milestone A loopback: source -> H.264 encode (VideoToolbox) -> packetize -> simulated loss ->
    reassemble -> recovery gate -> H.264 decode. Reports per-stage latency, FPS, bitrate and recovery.

      --seconds N     run duration in seconds (default 10)
      --mode M        synthetic (default): generated 420v frames; capture: main display via ScreenCaptureKit
                      (requires Screen Recording permission; never prompts, exits 2 if missing)
      --bitrate KBPS  encoder target bitrate (default 3000)
      --loss PERCENT  random datagram loss, 0-100 (default 0)
      --width/--height  encode size, even numbers (default 1280x720; capture mode fits the display inside it)
      --fps FPS       source/encoder frame rate (default 60)
      --seed N        loss simulator seed (default fixed, so runs are reproducible)
      --mtu BYTES     max datagram size incl. 32-byte header (default 1150)
      --dup-keyframes send keyframe datagrams twice, like the production Host pipeline (default off)
      --fec           XOR parity datagrams with K adapted to the measured loss, like the production Host
      --fec-k K       XOR parity datagrams with a fixed group size K (1-255)
      --self-test     run the built-in checks and exit (0 = all passed)
    """

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case invalidValue(String, String)
        case unknownArgument(String)

        var description: String {
            switch self {
            case .missingValue(let flag): "missing value for \(flag)"
            case .invalidValue(let flag, let value): "invalid value '\(value)' for \(flag)"
            case .unknownArgument(let arg): "unknown argument '\(arg)'"
            }
        }
    }

    /// Parses arguments (without the executable name). Accepts `--flag value` and `--flag=value`.
    static func parse(_ arguments: [String]) throws(ParseError) -> BenchOptions {
        var options = BenchOptions()
        var index = 0
        while index < arguments.count {
            var flag = arguments[index]
            var inlineValue: String?
            if flag.hasPrefix("--"), let eq = flag.firstIndex(of: "=") {
                inlineValue = String(flag[flag.index(after: eq)...])
                flag = String(flag[..<eq])
            }
            index += 1

            func value() throws(ParseError) -> String {
                if let inlineValue { return inlineValue }
                guard index < arguments.count else { throw .missingValue(flag) }
                defer { index += 1 }
                return arguments[index]
            }
            func int(in range: ClosedRange<Int>) throws(ParseError) -> Int {
                let raw = try value()
                guard let v = Int(raw), range.contains(v) else { throw .invalidValue(flag, raw) }
                return v
            }
            func double(in range: ClosedRange<Double>) throws(ParseError) -> Double {
                let raw = try value()
                guard let v = Double(raw), v.isFinite, range.contains(v) else { throw .invalidValue(flag, raw) }
                return v
            }

            switch flag {
            case "--seconds":
                options.seconds = try double(in: 0.5...3600)
            case "--mode":
                let raw = try value()
                guard let mode = BenchMode(rawValue: raw) else { throw .invalidValue(flag, raw) }
                options.mode = mode
            case "--bitrate":
                options.bitrateKbps = try int(in: 100...500_000)
            case "--loss":
                options.lossPercent = try double(in: 0...100)
            case "--width":
                options.width = try int(in: 16...8192)
                guard options.width % 2 == 0 else { throw .invalidValue(flag, String(options.width)) }
            case "--height":
                options.height = try int(in: 16...8192)
                guard options.height % 2 == 0 else { throw .invalidValue(flag, String(options.height)) }
            case "--fps":
                options.fps = try int(in: 1...240)
            case "--seed":
                let raw = try value()
                guard let v = UInt64(raw) else { throw .invalidValue(flag, raw) }
                options.seed = v
            case "--mtu":
                // Header (32) + at least one payload byte; u16 payloadLength bounds the top.
                options.maxDatagramSize = try int(in: 64...65_535)
            case "--dup-keyframes":
                options.duplicateKeyframes = true
            case "--fec":
                options.fec = .adaptive
            case "--fec-k":
                options.fec = .fixed(try int(in: 1...255))
            case "--self-test":
                options.selfTest = true
            case "--help", "-h":
                options.help = true
            default:
                throw .unknownArgument(flag)
            }
        }
        return options
    }
}
