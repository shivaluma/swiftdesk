import Foundation
import TransportCore
import WireProtocol

/// A host/port pair typed by the user on the Viewer screen.
///
/// Parsing is strict on purpose: the address is also the key of the pinned fingerprint in `TrustedHostStore`, so
/// `mac.local`, `mac.local:47800` and ` mac.local ` must all resolve to the same normalized target, and an invalid
/// port must be rejected in the form instead of silently dialing the default one.
public struct ConnectTarget: Sendable, Equatable, Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case emptyHost
        case invalidHost
        case invalidPort(String)

        public var description: String {
            switch self {
            case .emptyHost: "Enter a host name or IP address."
            case .invalidHost: "The host name contains characters that are not allowed."
            case .invalidPort(let text): "“\(text)” is not a valid port (1–65535)."
            }
        }
    }

    /// Parses the host field plus the separate port field.
    ///
    /// Accepted host forms: `name`, `name:port`, `1.2.3.4`, `1.2.3.4:port`, bare IPv6 (`fd7a::1`), `[v6]` and
    /// `[v6]:port`. A port inside the host field wins over `portText`; an empty `portText` means the default port.
    public static func parse(host hostText: String, port portText: String = "",
                             defaultPort: UInt16 = WireConstants.defaultPort) -> Result<ConnectTarget, ParseError> {
        let raw = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(.emptyHost) }
        // URL syntax ("https://…", "host/path") is never a SwiftDesk address; say so instead of misreading the port.
        guard !raw.contains("/") else { return .failure(.invalidHost) }

        var host = raw
        var embeddedPort: Substring?
        if raw.hasPrefix("[") {
            guard let close = raw.firstIndex(of: "]") else { return .failure(.invalidHost) }
            host = String(raw[raw.index(after: raw.startIndex)..<close])
            let rest = raw[raw.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return .failure(.invalidHost) }
                embeddedPort = rest.dropFirst()
            }
        } else if raw.filter({ $0 == ":" }).count == 1, let colon = raw.firstIndex(of: ":") {
            host = String(raw[..<colon])
            embeddedPort = raw[raw.index(after: colon)...]
        }

        guard isValidHost(host) else { return .failure(host.isEmpty ? .emptyHost : .invalidHost) }

        let port: UInt16
        if let embeddedPort {
            guard let value = parsePort(String(embeddedPort)) else { return .failure(.invalidPort(String(embeddedPort))) }
            port = value
        } else {
            let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                port = defaultPort
            } else {
                guard let value = parsePort(trimmed) else { return .failure(.invalidPort(trimmed)) }
                port = value
            }
        }
        return .success(ConnectTarget(host: host, port: port))
    }

    /// 1...65535, digits only.
    public static func parsePort(_ text: String) -> UInt16? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }

    /// DNS names (letters, digits, `-`, `.`, `_`), IPv4 or IPv6 literals. Rejects whitespace and URL syntax so a
    /// pasted `https://…` fails loudly instead of being dialed as a hostname.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:%")
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `host:port`, with IPv6 literals bracketed (`[fd7a::1]:47800`) — the form people paste into the host field.
    public var displayString: String { Self.endpointString(host: host, port: port) }

    public static func endpointString(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// How the Host screen lists this Mac's addresses: what to tell the Viewer to type.
public enum AddressPresentation {
    public struct Row: Sendable, Equatable, Hashable, Identifiable {
        public var id: String { "\(interface)/\(address)" }
        public var address: String
        public var interface: String
        public var isTailscale: Bool
        public var isIPv6: Bool
        /// `address:port`, bracketed for IPv6.
        public var endpoint: String
        /// "Tailscale", "Wi-Fi / Ethernet (en0)" style label.
        public var kindLabel: String
    }

    /// LAN addresses first (what a Viewer on the same network should use), then Tailscale; IPv4 before IPv6
    /// within each group because IPv4 is easier to read aloud and type.
    public static func rows(_ addresses: [InterfaceAddress], port: UInt16) -> [Row] {
        addresses
            .filter { !NetworkInfo.isLinkLocal($0.address) }
            .sorted { a, b in
                if a.isTailscale != b.isTailscale { return !a.isTailscale }
                if a.isIPv6 != b.isIPv6 { return !a.isIPv6 }
                if a.interface != b.interface { return a.interface < b.interface }
                return a.address < b.address
            }
            .map { a in
                Row(address: a.address, interface: a.interface, isTailscale: a.isTailscale, isIPv6: a.isIPv6,
                    endpoint: ConnectTarget.endpointString(host: a.address, port: port),
                    kindLabel: a.isTailscale ? "Tailscale" : "Local network (\(a.interface))")
            }
    }
}
