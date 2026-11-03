import Foundation
import Synchronization
import TransportCore
import WireProtocol

// QUICSpike — Milestone B transport validation on loopback.
//
//   QUICSpike            end-to-end through the real TransportCore API (HostListener + PeerConnection)
//   QUICSpike --raw      raw Network.framework exploration (step 1), see RawSpike.swift
//
// Options: --skip-idle (skip the 15 s keepalive test), --host <ip> (default 127.0.0.1).

setvbuf(stdout, nil, _IOLBF, 0)

let spikeStart = DispatchTime.now().uptimeNanoseconds
func spikeLog(_ message: String) {
    let t = Double(DispatchTime.now().uptimeNanoseconds - spikeStart) / 1e9
    print(String(format: "[%7.3f] ", t) + message)
}

func summarize(_ samples: [Double]) -> String {
    guard !samples.isEmpty else { return "n=0" }
    let s = samples.sorted()
    func p(_ q: Double) -> Double { s[min(s.count - 1, max(0, Int((q * Double(s.count)).rounded(.up)) - 1))] }
    let mean = s.reduce(0, +) / Double(s.count)
    return String(format: "n=%d mean=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f ms", s.count, mean, p(0.5), p(0.95), p(0.99), s.last!)
}

let arguments = CommandLine.arguments
if arguments.contains("--raw") {
    do { try RawSpike(arguments: arguments).run() } catch { spikeLog("raw spike error: \(error)") }
    exit(0)
}

// MARK: - API spike

/// Shared counters/state between the host callbacks and the driver.
final class Probe: @unchecked Sendable {
    let hostDatagrams = Atomic<Int>(0)
    let viewerDatagrams = Atomic<Int>(0)
    let hostControl = Atomic<Int>(0)
    let lastHostConnection = Mutex<PeerConnection?>(nil)
    let hostStates = Mutex<[PeerConnectionState]>([])
    let hostSawDisconnect = Atomic<Bool>(false)
    let pong = DispatchSemaphore(value: 0)
    let pongRTT = Mutex<Double>(0)
}

nonisolated(unsafe) var failures: [String] = []
func check(_ condition: Bool, _ what: String) {
    spikeLog((condition ? "PASS " : "FAIL ") + what)
    if !condition { failures.append(what) }
}

let host = arguments.firstIndex(of: "--host").map { arguments[$0 + 1] } ?? "127.0.0.1"
let suffix = String(UUID().uuidString.prefix(8))
let hostLabel = "SwiftDesk QUICSpike Host \(suffix)"
let viewerLabel = "SwiftDesk QUICSpike Viewer \(suffix)"
let hostIdentity: DeviceIdentity
let viewerIdentity: DeviceIdentity
do {
    let t0 = DispatchTime.now().uptimeNanoseconds
    hostIdentity = try DeviceIdentity.loadOrCreate(label: hostLabel)
    viewerIdentity = try DeviceIdentity.loadOrCreate(label: viewerLabel)
    spikeLog(String(format: "identities created in %.1f ms", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
    let reloaded = try DeviceIdentity.loadOrCreate(label: hostLabel)
    check(reloaded.fingerprint == hostIdentity.fingerprint, "loadOrCreate reloads the same identity from the keychain")
} catch {
    spikeLog("identity error: \(error)")
    exit(2)
}
func cleanupIdentities() {
    try? DeviceIdentity.delete(label: hostLabel)
    try? DeviceIdentity.delete(label: viewerLabel)
}
spikeLog("host   \(hostIdentity.commonName)  \(hostIdentity.fingerprintDisplay)")
spikeLog("viewer \(viewerIdentity.commonName)  \(viewerIdentity.fingerprintDisplay)")

let probe = Probe()
let listener = HostListener(port: 0, identity: hostIdentity, deviceName: "SwiftDesk QUICSpike \(suffix)",
                            advertiseBonjour: true,
                            rateLimiter: ConnectionRateLimiter(perAddressPerMinute: 5, globalPerMinute: 30))
let listenerReady = DispatchSemaphore(value: 0)
let listenPort = Mutex<UInt16>(0)
listener.onStateChange = { state in
    spikeLog("listener \(state)")
    if case .ready(let port) = state {
        listenPort.withLock { $0 = port }
        listenerReady.signal()
    }
}
listener.onIncoming = { connection in
    probe.lastHostConnection.withLock { $0 = connection }
    let peer = connection.peerFingerprint.map(DeviceIdentity.display) ?? "nil"
    spikeLog("host: incoming from \(connection.remoteAddress) peer=\(peer) maxDatagram=\(connection.maxDatagramSize)")
    probe.hostStates.withLock { $0.removeAll() }
    connection.onStateChange = { state in probe.hostStates.withLock { $0.append(state) } }
    connection.onControlMessage = { [weak connection] message in
        probe.hostControl.wrappingAdd(1, ordering: .relaxed)
        switch message {
        case .ping(let p): connection?.sendControl(.pong(p))
        case .disconnect: probe.hostSawDisconnect.store(true, ordering: .relaxed)
        default: break
        }
    }
    connection.onDatagram = { _ in probe.hostDatagrams.wrappingAdd(1, ordering: .relaxed) }
    connection.start()
}
listener.start()
guard listenerReady.wait(timeout: .now() + 5) == .success else {
    spikeLog("listener did not become ready")
    cleanupIdentities()
    exit(3)
}
let port = listenPort.withLock { $0 }

/// Connects and waits for a terminal or ready state; returns (connection, final state, elapsed ms).
func connectAndWait(pin: Data?, timeout: TimeInterval = 10) -> (PeerConnection, PeerConnectionState, Double) {
    let connection = PeerConnection.connect(host: host, port: port, identity: viewerIdentity,
                                            pinnedHostFingerprint: pin, establishmentTimeout: timeout)
    let done = DispatchSemaphore(value: 0)
    let final = Mutex<PeerConnectionState>(.connecting)
    connection.onStateChange = { state in
        guard state != .connecting else { return }
        let first = final.withLock { f -> Bool in
            guard f == .connecting else { return false }
            f = state
            return true
        }
        if first { done.signal() }
    }
    connection.onControlMessage = { message in
        if case .pong(let p) = message {
            let now = DispatchTime.now().uptimeNanoseconds
            probe.pongRTT.withLock { $0 = Double(now &- p.sentAtNanos) / 1e6 }
            probe.pong.signal()
        }
    }
    connection.onDatagram = { _ in probe.viewerDatagrams.wrappingAdd(1, ordering: .relaxed) }
    let t0 = DispatchTime.now().uptimeNanoseconds
    connection.start()
    _ = done.wait(timeout: .now() + timeout + 2)
    return (connection, final.withLock { $0 }, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
}

func waitForHostConnection() -> PeerConnection? {
    for _ in 0..<100 {
        if let c = probe.lastHostConnection.withLock({ $0 }) { return c }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
}

/// Sends `count` datagrams in frame-sized batches (`perBatch`) and returns how many arrived.
func blast(from sender: PeerConnection, count: Int, perBatch: Int, counter: borrowing Atomic<Int>, size: Int) -> (sent: Int, refused: Int, arrived: Int) {
    counter.store(0, ordering: .relaxed)
    var refusedBatches = 0
    var sent = 0
    var batch: [Data] = []
    batch.reserveCapacity(perBatch)
    var index = 0
    while index < count {
        batch.removeAll(keepingCapacity: true)
        for _ in 0..<min(perBatch, count - index) {
            var d = Data(count: size)
            d[0] = WireConstants.videoMagic
            batch.append(d)
        }
        if sender.sendDatagrams(batch) { sent += batch.count } else { refusedBatches += 1 }
        index += batch.count
        Thread.sleep(forTimeInterval: 0.002)   // paced: ~500 batches/s
    }
    Thread.sleep(forTimeInterval: 0.5)
    return (sent, refusedBatches, counter.load(ordering: .relaxed))
}

// 1. Pinned, correct fingerprint.
spikeLog("--- case 1: viewer pins the correct host fingerprint")
let (viewer, state1, connectMs) = connectAndWait(pin: hostIdentity.fingerprint)
check(state1 == .ready, "pinned connect reaches .ready (\(state1)) in \(String(format: "%.1f", connectMs)) ms")
check(viewer.peerFingerprint == hostIdentity.fingerprint, "viewer.peerFingerprint == host fingerprint")
let hostSide = waitForHostConnection()
check(hostSide != nil, "HostListener.onIncoming delivered the connection")
check(hostSide?.peerFingerprint == viewerIdentity.fingerprint, "host-side peerFingerprint == viewer fingerprint")
spikeLog("viewer maxDatagramSize=\(viewer.maxDatagramSize) remote=\(viewer.remoteAddress)")

// Control round trip: 1000 sequential PING/PONG through WireProtocol framing.
var rtts: [Double] = []
for i in 0..<1000 {
    viewer.sendControl(.ping(Ping(id: UInt32(i), sentAtNanos: DispatchTime.now().uptimeNanoseconds)))
    guard probe.pong.wait(timeout: .now() + 2) == .success else { break }
    rtts.append(probe.pongRTT.withLock { $0 })
}
check(rtts.count == 1000, "1000 PING/PONG control round trips completed (\(rtts.count))")
spikeLog("control RTT (PING->PONG over QUIC stream, loopback): \(summarize(rtts))")

// Datagrams viewer -> host and host -> viewer at 0 % and 3 % simulated loss.
let size = viewer.maxDatagramSize
for loss in [0.0, 3.0] {
    viewer.simulatedDatagramLossPercent = loss
    let r = blast(from: viewer, count: 2000, perBatch: 4, counter: probe.hostDatagrams, size: size)
    let pct = 100.0 * Double(2000 - r.arrived) / 2000
    spikeLog(String(format: "viewer->host simulated loss=%.0f%%: handed %d, refused batches %d, arrived %d/2000 (%.2f%% missing)",
                    loss, r.sent, r.refused, r.arrived, pct))
    if loss == 0 {
        check(r.arrived == 2000, "2000/2000 datagrams arrive at 0 % simulated loss")
    } else {
        check(pct > 1 && pct < 6, "about 3 % missing at 3 % simulated loss (\(String(format: "%.2f", pct)) %)")
    }
}
viewer.simulatedDatagramLossPercent = 0
if let hostSide {
    let r = blast(from: hostSide, count: 2000, perBatch: 4, counter: probe.viewerDatagrams, size: hostSide.maxDatagramSize)
    spikeLog("host->viewer simulated loss=0%: handed \(r.sent), refused batches \(r.refused), arrived \(r.arrived)/2000")
    check(r.arrived == 2000, "2000/2000 host->viewer datagrams arrive")
}

// Backpressure: one unpaced burst of ~64 KiB batches against a 128 KiB backlog limit.
viewer.maxBacklogBytes = 128 * 1024
var refused = 0
var peakPending = 0
let burst = (0..<56).map { _ in Data(count: size) }
for _ in 0..<200 {
    if !viewer.sendDatagrams(burst) { refused += 1 }
    peakPending = max(peakPending, viewer.pendingDatagramBytes)
}
Thread.sleep(forTimeInterval: 0.5)
spikeLog("backpressure burst: 200 batches x \(burst.count * size) B unpaced, refused \(refused), peak pending \(peakPending) B, pending after drain \(viewer.pendingDatagramBytes) B")
check(viewer.pendingDatagramBytes == 0, "pendingDatagramBytes drains back to 0")
viewer.maxBacklogBytes = 256 * 1024
spikeLog("viewer stats: \(viewer.stats)")

// Keepalive: stay idle longer than the 10 s idle timeout.
if !arguments.contains("--skip-idle") {
    spikeLog("idle for 15 s (QUIC idle timeout 10 s, keepalive every 3 s)...")
    Thread.sleep(forTimeInterval: 15)
    check(viewer.state == .ready && hostSide?.state == .ready, "connection survives 15 s idle (keepalive)")
    viewer.sendControl(.ping(Ping(id: 9999, sentAtNanos: DispatchTime.now().uptimeNanoseconds)))
    check(probe.pong.wait(timeout: .now() + 2) == .success, "control still works after idle")
}

// Graceful close: host receives DISCONNECT and reaches .closed.
viewer.close(reason: .userInitiated)
Thread.sleep(forTimeInterval: 0.6)
check(probe.hostSawDisconnect.load(ordering: .relaxed), "host received DISCONNECT")
check(probe.hostStates.withLock { $0.last } == .closed, "host-side connection reports .closed (\(probe.hostStates.withLock { $0 }))")
check(viewer.state == .closed, "viewer reports .closed")

// 2. Wrong pin.
spikeLog("--- case 2: viewer pins a WRONG fingerprint")
probe.lastHostConnection.withLock { $0 = nil }
let (wrong, state2, wrongMs) = connectAndWait(pin: Data(repeating: 0xAB, count: 32))
check(state2 == .failed("Host identity does not match the pinned fingerprint"),
      "wrong pin fails: \(state2) after \(String(format: "%.1f", wrongMs)) ms")
Thread.sleep(forTimeInterval: 0.3)
check(probe.lastHostConnection.withLock { $0 } == nil, "host never hands out the wrong-pin connection")
withExtendedLifetime(wrong) {}

// 3. No pin (first contact): handshake succeeds, fingerprint recorded for the trust prompt.
spikeLog("--- case 3: no pin (trust decision is the session layer's job)")
let (unpinned, state3, _) = connectAndWait(pin: nil)
check(state3 == .ready && unpinned.peerFingerprint == hostIdentity.fingerprint,
      "unpinned connect is ready and records the host fingerprint")
unpinned.close(reason: .userInitiated)

// 4. Rate limiter: a dedicated listener allowing 2 attempts/min per address; three back-to-back attempts.
spikeLog("--- case 4: rate limiter (dedicated listener, 2/min per address)")
let limited = HostListener(port: 0, identity: hostIdentity, deviceName: "SwiftDesk QUICSpike RL \(suffix)",
                           advertiseBonjour: false,
                           rateLimiter: ConnectionRateLimiter(perAddressPerMinute: 2, globalPerMinute: 30))
let limitedReady = DispatchSemaphore(value: 0)
let limitedPort = Mutex<UInt16>(0)
limited.onStateChange = { state in
    if case .ready(let p) = state { limitedPort.withLock { $0 = p }; limitedReady.signal() }
}
limited.onIncoming = { connection in connection.start() }
limited.start()
_ = limitedReady.wait(timeout: .now() + 5)
var limitedStates: [PeerConnectionState] = []
var limitedTimes: [Double] = []
for _ in 0..<3 {
    let c = PeerConnection.connect(host: host, port: limitedPort.withLock { $0 }, identity: viewerIdentity,
                                   pinnedHostFingerprint: hostIdentity.fingerprint, establishmentTimeout: 3)
    let done = DispatchSemaphore(value: 0)
    let final = Mutex<PeerConnectionState>(.connecting)
    c.onStateChange = { st in
        guard st != .connecting else { return }
        if final.withLock({ f -> Bool in defer { if f == .connecting { f = st } }; return f == .connecting }) { done.signal() }
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    c.start()
    _ = done.wait(timeout: .now() + 5)
    limitedTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    limitedStates.append(final.withLock { $0 })
    c.close(reason: .userInitiated)
}
spikeLog("rate-limited attempts: \(zip(limitedStates, limitedTimes).map { "\($0.0) (\(String(format: "%.0f", $0.1)) ms)" })")
check(limitedStates[0] == .ready && limitedStates[1] == .ready, "attempts 1 and 2 (within limit) succeed")
check(limitedStates[2] != .ready, "attempt 3 is refused by the per-address limiter before TLS completes on the host")
limited.stop()

// 5. Bonjour discovery of the advertised listener.
spikeLog("--- case 5: Bonjour")
let browser = BonjourBrowser()
let found = DispatchSemaphore(value: 0)
let foundResult = Mutex<BonjourBrowser.Result?>(nil)
let serviceName = "SwiftDesk QUICSpike \(suffix)"
browser.onResults = { results in
    if let r = results.first(where: { $0.name == serviceName }) {
        foundResult.withLock { $0 = r }
        found.signal()
    }
}
browser.start()
if found.wait(timeout: .now() + 5) == .success, let r = foundResult.withLock({ $0 }) {
    let resolved = Mutex<(host: String, port: UInt16)?>(nil)
    let resolvedSignal = DispatchSemaphore(value: 0)
    Task.detached {
        let value = await browser.resolve(r)
        resolved.withLock { $0 = value }
        resolvedSignal.signal()
    }
    _ = resolvedSignal.wait(timeout: .now() + 12)
    let value = resolved.withLock { $0 }
    spikeLog("bonjour resolved '\(r.name)' -> \(value.map { "\($0.host):\($0.port)" } ?? "nil")")
    check(value?.port == port, "Bonjour result resolves to the listener port")
} else {
    check(false, "Bonjour browser found the advertised listener")
}
browser.stop()

// 6. Interfaces and Tailscale path (informational; no addresses printed).
let addresses = NetworkInfo.localAddresses()
spikeLog("local addresses: \(addresses.count) (tailscale: \(addresses.filter(\.isTailscale).count))")
if let tailnet = addresses.first(where: { $0.isTailscale && !$0.isIPv6 }) {
    let selfPath = Mutex<TailscalePeerPath?>(nil)
    let probed = DispatchSemaphore(value: 0)
    Task.detached {
        let value = await TailscaleProbe.path(to: tailnet.address)
        selfPath.withLock { $0 = value }
        probed.signal()
    }
    _ = probed.wait(timeout: .now() + 5)
    spikeLog("TailscaleProbe for own tailnet address: \(selfPath.withLock { $0 }.map(\.summary) ?? "nil (self is not a peer — expected)")")
}

listener.stop()
Thread.sleep(forTimeInterval: 0.3)
cleanupIdentities()
spikeLog(failures.isEmpty ? "ALL CHECKS PASSED" : "FAILURES: \(failures.count)\n  " + failures.joined(separator: "\n  "))
exit(failures.isEmpty ? 0 : 1)
