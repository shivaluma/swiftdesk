import Foundation
import Synchronization

public struct TailscalePeerPath: Sendable, Equatable {
    /// The address that was asked about.
    public var peerAddress: String
    /// True when Tailscale reports a current direct UDP endpoint (`CurAddr`) for the peer.
    public var direct: Bool
    /// Relay the traffic uses when not direct: the peer relay (`PeerRelay`) if Tailscale reports one, otherwise
    /// the peer's home DERP region code (`Relay`, e.g. "fra"). Informational when `direct` is true.
    public var relay: String?
    /// Current direct endpoint ("ip:port") when direct.
    public var currentAddress: String?

    public init(peerAddress: String, direct: Bool, relay: String?, currentAddress: String?) {
        self.peerAddress = peerAddress
        self.direct = direct
        self.relay = relay
        self.currentAddress = currentAddress
    }

    /// e.g. "Tailscale (direct)" or "Tailscale (relay: fra)" — matches `MetricsSnapshot.pathDescription`.
    public var summary: String {
        if direct { return "Tailscale (direct)" }
        if let relay { return "Tailscale (relay: \(relay))" }
        return "Tailscale (relay)"
    }
}

/// Reports whether the Tailscale path to a peer is direct or relayed (PRD Milestone E: "detect/report relay
/// rather than promising direct P2P"). Best effort and off the hot path: it shells out to the Tailscale CLI,
/// which is the only supported way to read this without the Tailscale local API socket.
public enum TailscaleProbe {
    static let timeoutSeconds: TimeInterval = 3

    static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// Best-effort: runs the Tailscale CLI (`tailscale status --json`, app bundle or PATH) off the main thread;
    /// nil if unavailable, not running, timed out, or the address is not a known peer.
    public static func path(to peerAddress: String) async -> TailscalePeerPath? {
        guard let executable = locateCLI() else { return nil }
        let output: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable, arguments: ["status", "--json"], timeout: timeoutSeconds))
            }
        }
        guard let output else { return nil }
        return parse(statusJSON: output, peerAddress: peerAddress)
    }

    static func locateCLI() -> URL? {
        var candidates = candidatePaths
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/tailscale" }
        }
        let fm = FileManager.default
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// Runs a process with a hard timeout; nil on launch failure, timeout or non-zero exit.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let buffer = Mutex(Data())
        let readDone = DispatchSemaphore(value: 0)
        // Drain stdout concurrently so a large status document cannot fill the pipe and deadlock the child.
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            buffer.withLock { $0 = data }
            readDone.signal()
        }
        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForWriting.close()
            return nil
        }
        try? stdout.fileHandleForWriting.close()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if !process.isRunning { exited.signal() }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = readDone.wait(timeout: .now() + 1)
            return nil
        }
        guard readDone.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
        return buffer.withLock { $0 }
    }

    /// Parses `tailscale status --json`. Matches the peer by any of its `TailscaleIPs`, or by `HostName` /
    /// MagicDNS `DNSName` (case-insensitive, trailing dot ignored) so hostnames typed by the user work too.
    static func parse(statusJSON: Data, peerAddress: String) -> TailscalePeerPath? {
        guard let root = try? JSONSerialization.jsonObject(with: statusJSON) as? [String: Any],
              let peers = root["Peer"] as? [String: Any] else { return nil }
        let wanted = normalize(peerAddress)
        for case let peer as [String: Any] in peers.values {
            let ips = (peer["TailscaleIPs"] as? [String]) ?? []
            let names = [peer["HostName"] as? String, peer["DNSName"] as? String].compactMap { $0 }.map(normalize)
            let dnsShort = (peer["DNSName"] as? String).map(normalize)?.split(separator: ".").first.map(String.init)
            guard ips.map(normalize).contains(wanted) || names.contains(wanted) || dnsShort == wanted else { continue }
            let curAddr = (peer["CurAddr"] as? String) ?? ""
            let derp = (peer["Relay"] as? String) ?? ""
            let peerRelay = (peer["PeerRelay"] as? String) ?? ""
            let relay = !peerRelay.isEmpty ? peerRelay : (derp.isEmpty ? nil : derp)
            return TailscalePeerPath(peerAddress: peerAddress, direct: !curAddr.isEmpty, relay: relay,
                                     currentAddress: curAddr.isEmpty ? nil : curAddr)
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces).lowercased()
        if v.hasPrefix("[") && v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        while v.hasSuffix(".") { v.removeLast() }
        return v
    }
}
