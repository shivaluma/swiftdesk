// NetBench: measures a real SwiftDesk Host ⇄ Viewer session between two machines (or on loopback), headless.
//
//   NetBench host   --p12 <file> --password <pw> [--port 47801] [--seconds 40] [--source 1920x1080]
//                   [--no-adaptation] [--no-dup-keyframes] [--fec off|auto] [--budget-ms N]
//   NetBench viewer --p12 <file> --password <pw> --host <ip> [--port 47801] [--seconds 40]
//
// The Host runs the production `HostSession` (listener, handshake, approval, `HostMediaPipeline`, adaptation, FEC)
// with a synthetic moving source instead of ScreenCaptureKit and auto-approves the first request. The Viewer runs
// the production `ViewerSession` (trusts the Host without a pin) and decodes with VideoToolbox into a counting sink
// instead of Metal. Identities come from PKCS#12 files in memory, so nothing touches the keychain (works over SSH).
// Each side prints one line per second and a summary.

import CoreGraphics
import DiagnosticsCore
import Foundation
import RenderCore
import SessionCore
import Synchronization
import TransportCore
import WireProtocol

struct Options {
    var mode = ""
    var p12 = ""
    var password = ""
    var host = ""
    var port: UInt16 = 47801
    var seconds = 40
    var sourceWidth = 1920
    var sourceHeight = 1080
    var adaptation = true
    var duplicateKeyframes = true
    var fec = "auto"
    var budgetMillis: Int?

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func value() -> String {
            i += 1
            guard i < args.count else { fail("missing value for \(args[i - 1])") }
            return args[i]
        }
        if args.count > 1 { o.mode = args[1]; i = 2 }
        while i < args.count {
            switch args[i] {
            case "--p12": o.p12 = value()
            case "--password": o.password = value()
            case "--host": o.host = value()
            case "--port": o.port = UInt16(value()) ?? 47801
            case "--seconds": o.seconds = Int(value()) ?? 40
            case "--source":
                let parts = value().split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { o.sourceWidth = parts[0]; o.sourceHeight = parts[1] }
            case "--no-adaptation": o.adaptation = false
            case "--no-dup-keyframes": o.duplicateKeyframes = false
            case "--fec": o.fec = value()
            case "--budget-ms": o.budgetMillis = Int(value())
            default: fail("unknown argument \(args[i])")
            }
            i += 1
        }
        guard o.mode == "host" || o.mode == "viewer", !o.p12.isEmpty else {
            fail("usage: NetBench host|viewer --p12 <file> --password <pw> [--host <ip>] [--port N] [--seconds N] ...")
        }
        if o.mode == "viewer" && o.host.isEmpty { fail("viewer needs --host") }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("NetBench: \(message)\n".utf8))
    exit(2)
}

func out(_ line: String) {
    print(line)
    fflush(stdout)
}

func f1(_ v: Double) -> String { String(format: "%.1f", v) }

/// Accepts everything, injects nothing.
final class NullInputSink: InputSink, @unchecked Sendable {
    func handle(_ message: ControlMessage) {}
    func handlePointer(_ state: PointerState) {}
    func setAuthorized(_ authorized: Bool) {}
    func updateDisplayFrame(_ frame: CGRect) {}
    func releaseAll() {}
    var canInject: Bool { false }
}

/// Counts decoded frames and tracks the longest gap between consecutive frames (overall and per window).
final class CountingSink: VideoFrameSink, @unchecked Sendable {
    private struct State {
        var count: UInt64 = 0
        var last: UInt64 = 0
        var windowMaxGap: UInt64 = 0
        var maxGap: UInt64 = 0
    }
    private let state = Mutex(State())

    func enqueue(_ frame: any RenderableFrame) {
        let now = MonotonicClock.nowNanos()
        state.withLock { s in
            if s.last != 0 {
                let gap = now - s.last
                s.windowMaxGap = max(s.windowMaxGap, gap)
                s.maxGap = max(s.maxGap, gap)
            }
            s.last = now
            s.count &+= 1
        }
    }

    /// (frames so far, longest gap in this window incl. the open gap up to now, longest gap overall) in ms.
    func window(now: UInt64) -> (count: UInt64, windowGapMillis: Double, maxGapMillis: Double) {
        state.withLock { s in
            let open = s.last != 0 ? now - s.last : 0
            let w = max(s.windowMaxGap, open)
            s.windowMaxGap = 0
            return (s.count, Double(w) / 1e6, Double(max(s.maxGap, open)) / 1e6)
        }
    }
}

@MainActor
func runHost(_ o: Options, identity: DeviceIdentity) async {
    var config = HostSession.Configuration()
    config.port = o.port
    config.advertiseBonjour = false
    config.deviceName = "NetBench Host"
    config.rateLimiter = ConnectionRateLimiter(perAddressPerMinute: 100, globalPerMinute: 100)
    config.adaptationEnabled = o.adaptation
    config.duplicateKeyframePackets = o.duplicateKeyframes
    if o.fec == "off" { config.forwardErrorCorrection = .off }
    if let budget = o.budgetMillis { config.sendQueueBudgetMillis = budget }
    config.clipboardSharing = false   // a bench never touches the clipboard
    config.cursorShapes = false       // …or reads the pointer
    let width = o.sourceWidth, height = o.sourceHeight
    let deps = HostSession.Dependencies(
        identity: identity,
        permissions: PermissionChecker(screenRecordingGranted: { true }, accessibilityGranted: { true }),
        makeVideoSource: { _, capture in
            SyntheticVideoSource(sourceWidth: width, sourceHeight: height, config: capture,
                                 displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 810))
        },
        makeInputSink: { _ in NullInputSink() })
    let host = HostSession(configuration: config, dependencies: deps)
    host.startListening()
    out("host: fingerprint \(identity.fingerprintDisplay); adaptation=\(o.adaptation) dupKeyframes=\(o.duplicateKeyframes) "
        + "fec=\(o.fec) budgetMs=\(o.budgetMillis.map(String.init) ?? "80") source=\(width)x\(height)")

    // Wait (up to 120 s) for a viewer; approve the first request.
    var waited = 0
    while waited < 1200 {
        switch host.state {
        case .listening(let port) where waited % 50 == 0: out("host: listening on UDP \(port)")
        case .awaitingApproval(let request):
            out("host: approving \(request.peerName) from \(request.remoteAddress)")
            host.approve()
        case .active: waited = .max - 1
        default: break
        }
        if waited == .max - 1 { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 1
    }
    guard case .active(let peer) = host.state else {
        out("host: no viewer connected (\(host.state)); last error: \(host.lastError ?? "-")")
        return
    }
    out("host: active, session \(peer.sessionId), peer \(peer.remoteAddress)")
    out("   t  rung          tgtKbps  outKbps  fps  backlogB  refused  encDrop  kf  K  vLoss%  vFPS  rtt/min ms  signals")
    var last = MetricsSnapshot()
    var fpsSum = 0.0, refusedTotal: UInt64 = 0
    for t in 1...o.seconds {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard case .active = host.state else {
            out("host: session ended at t=\(t): \(host.lastEndReason ?? "-")")
            break
        }
        let m = host.metrics
        let refused = m.sendBatchesRefused &- last.sendBatchesRefused
        refusedTotal &+= refused
        fpsSum += m.fps
        let rung = "\(m.width)x\(m.height)@\(m.configuredFPS)".padding(toLength: 13, withPad: " ", startingAt: 0)
        out(String(format: "%4d  %@ %7.0f  %7.0f  %4.0f  %8d  %7llu  %7llu  %2llu %2d  %6.1f  %4.0f  %5.1f/%-5.1f  %@",
                   t, rung, m.targetBitrateKbps, m.bitrateKbps, m.fps, m.sendBacklogBytes, refused,
                   m.encoderBackpressureDrops &- last.encoderBackpressureDrops, m.keyframes &- last.keyframes,
                   m.fecGroupSize, m.packetLossPercent, m.receivedFPS, m.rtt.smoothedMillis, m.rtt.minMillis,
                   m.adaptationSignals.isEmpty ? "-" : m.adaptationSignals))
        last = m
    }
    out("host: summary meanSentFPS=\(f1(fpsSum / Double(o.seconds))) refusedBatches=\(refusedTotal) "
        + "keyframes=\(last.keyframes) keyframeRequests=\(last.keyframeRequests) viewerFramesLost=\(last.framesLost)")
    host.stopListening()
    await host.waitForTeardown()
}

@MainActor
func runViewer(_ o: Options, identity: DeviceIdentity) async {
    var config = ViewerSession.Configuration()
    config.deviceName = "NetBench Viewer"
    config.establishmentTimeout = 10
    config.clipboardSharing = false
    config.cursorShapes = false
    let suite = "netbench.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defer { defaults.removePersistentDomain(forName: suite) }
    let viewer = ViewerSession(identity: identity, trustStore: TrustedHostStore(defaults: defaults), configuration: config)
    let sink = CountingSink()
    viewer.attach(frameSink: sink)
    out("viewer: connecting to \(o.host):\(o.port)")
    viewer.connect(host: o.host, port: o.port)

    var waited = 0
    while waited < 900 {
        switch viewer.state {
        case .verifyingHost(let v):
            out("viewer: trusting host \(v.fingerprintDisplay)")
            viewer.trustHost(remember: false)
        case .streaming: waited = .max - 1
        case .disconnected(let reason):
            out("viewer: disconnected: \(reason)")
            return
        default: break
        }
        if waited == .max - 1 { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 1
    }
    guard case .streaming(let info) = viewer.state else {
        out("viewer: not streaming (\(viewer.state))")
        return
    }
    out("viewer: streaming from \(info.hostName) at \(info.remoteAddress)")
    out("   t  decFPS  rxFPS  maxGapMs  lost  recov  kf  kfReq  loss%  rtt/min ms  stream")
    var last = MetricsSnapshot()
    var lastCount: UInt64 = 0
    var perSecond: [Double] = []
    var lastNow = MonotonicClock.nowNanos()
    _ = sink.window(now: lastNow)
    for t in 1...o.seconds {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard case .streaming = viewer.state else {
            out("viewer: ended at t=\(t): \(viewer.state)")
            break
        }
        let now = MonotonicClock.nowNanos()
        let w = sink.window(now: now)
        let fps = Double(w.count &- lastCount) * 1e9 / Double(now - lastNow)
        perSecond.append(fps)
        lastCount = w.count
        lastNow = now
        let m = viewer.metrics
        out(String(format: "%4d  %6.1f  %5.1f  %8.0f  %4llu  %5llu  %2llu  %5llu  %5.1f  %5.1f/%-5.1f  %dx%d@%d %.0fkbps",
                   t, fps, m.receivedFPS, w.windowGapMillis, m.framesLost &- last.framesLost,
                   m.fragmentsRecovered &- last.fragmentsRecovered, m.keyframes &- last.keyframes,
                   m.keyframeRequests &- last.keyframeRequests, m.packetLossPercent, m.rtt.smoothedMillis,
                   m.rtt.minMillis, m.width, m.height, m.configuredFPS, m.bitrateKbps))
        last = m
    }
    let mean = perSecond.isEmpty ? 0 : perSecond.reduce(0, +) / Double(perSecond.count)
    let below30 = perSecond.filter { $0 < 30 }.count
    let zero = perSecond.filter { $0 < 1 }.count
    let final = sink.window(now: MonotonicClock.nowNanos())
    out("viewer: summary meanFPS=\(f1(mean)) minFPS=\(f1(perSecond.min() ?? 0)) secondsBelow30=\(below30) "
        + "secondsAt0=\(zero) longestStallMs=\(Int(final.maxGapMillis)) framesLost=\(last.framesLost) "
        + "fragmentsRecovered=\(last.fragmentsRecovered) keyframes=\(last.keyframes) keyframeRequests=\(last.keyframeRequests)")
    viewer.disconnect()
}

let options = Options.parse(CommandLine.arguments)
let identity: DeviceIdentity
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: options.p12))
    identity = try DeviceIdentity.importPKCS12(data, password: options.password, label: "netbench-\(options.mode)")
} catch {
    fail("could not load identity: \(error)")
}

Task { @MainActor in
    if options.mode == "host" {
        await runHost(options, identity: identity)
    } else {
        await runViewer(options, identity: identity)
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    exit(0)
}
dispatchMain()
