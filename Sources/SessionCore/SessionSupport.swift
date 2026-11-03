import Foundation
import SystemConfiguration
import TransportCore

/// Small helpers shared by the Host and Viewer sessions.
public enum SessionSupport {
    /// The user-visible computer name ("Isabella's MacBook Pro"). `SCDynamicStoreCopyComputerName` is a local
    /// configuration read; `NSHost.currentHost` can block on DNS, so it is avoided.
    public static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    /// CFBundleShortVersionString, or "dev" for unbundled builds (tests, `swift run`).
    public static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Longest peer-supplied name shown in the UI, in Characters.
    public static let maxDisplayNameLength = 64

    /// A peer-supplied string (HELLO device name, ACCEPT host name, app version) made safe to show in a consent
    /// prompt or status line: control, format (bidi overrides U+202A–U+202E, isolates U+2066–U+2069, zero-width
    /// characters) and line/paragraph separator scalars become spaces, whitespace runs collapse to one space, and
    /// the result is trimmed and capped at `maxLength` Characters with an ellipsis. Empty → `fallback`.
    ///
    /// The wire decoder only checks length and UTF-8 validity; without this a peer could put line breaks or a
    /// right-to-left override in its name and fake extra lines ("✓ Fingerprint verified") in the approval sheet.
    public static func displayName(_ raw: String, maxLength: Int = maxDisplayNameLength,
                                   fallback: String = "Unknown Mac") -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true   // drops leading whitespace
        for scalar in raw.unicodeScalars {
            let blank: Bool
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: blank = true
            default: blank = scalar.properties.isWhitespace
            }
            if blank {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var name = String(scalars)
        while name.last == " " { name.removeLast() }
        guard !name.isEmpty else { return fallback }
        let limit = max(1, maxLength)
        if name.count > limit {
            name = String(name.prefix(limit - 1))
            while name.last == " " { name.removeLast() }
            name.append("…")
        }
        return name
    }

    /// The host part of TransportCore's "ip:port", "[v6]:port" or "name:port".
    public static func hostPart(of remoteAddress: String) -> String {
        if remoteAddress.hasPrefix("["), let close = remoteAddress.firstIndex(of: "]") {
            return String(remoteAddress[remoteAddress.index(after: remoteAddress.startIndex)..<close])
        }
        let colons = remoteAddress.filter { $0 == ":" }.count
        if colons == 1, let colon = remoteAddress.lastIndex(of: ":") {
            return String(remoteAddress[..<colon])
        }
        return remoteAddress
    }

    /// Coarse path label shown before (or instead of) a Tailscale probe: "Loopback", "Tailscale" or "LAN".
    public static func pathLabel(forHost host: String) -> String {
        let h = host.lowercased()
        if h == "127.0.0.1" || h == "::1" || h == "localhost" || h.hasPrefix("127.") { return "Loopback" }
        if NetworkInfo.isTailscale(address: h) || h.hasSuffix(".ts.net") { return "Tailscale" }
        return "LAN"
    }

    /// True if a Tailscale CLI probe can say more about this peer (direct vs relayed): only for tailnet IPs.
    public static func shouldProbeTailscale(host: String) -> Bool {
        NetworkInfo.isTailscale(address: host.lowercased())
    }
}
