import Darwin
import Foundation

public struct InterfaceAddress: Sendable, Equatable, Hashable {
    public var interface: String
    public var address: String
    public var isIPv6: Bool
    public var isTailscale: Bool

    public init(interface: String, address: String, isIPv6: Bool, isTailscale: Bool) {
        self.interface = interface
        self.address = address
        self.isIPv6 = isIPv6
        self.isTailscale = isTailscale
    }
}

/// Local addresses the Host shows so the operator can tell the Viewer where to connect (PRD flow step 3).
public enum NetworkInfo {
    /// Up, non-loopback, non-link-local IPv4/IPv6 addresses. IPv4 first, Tailscale addresses last within a family
    /// ordering of (family, isTailscale, interface, address) so the list is stable between refreshes.
    public static func localAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result = Set<InterfaceAddress>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = entry.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var address = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }   // drop scope id
            guard !isLinkLocal(address) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            result.insert(InterfaceAddress(interface: name, address: address, isIPv6: family == AF_INET6,
                                           isTailscale: isTailscale(address: address)))
        }
        return result.sorted { a, b in
            if a.isIPv6 != b.isIPv6 { return !a.isIPv6 }
            if a.isTailscale != b.isTailscale { return !a.isTailscale }
            if a.interface != b.interface { return a.interface < b.interface }
            return a.address < b.address
        }
    }

    /// Tailscale's CGNAT range 100.64.0.0/10 (IPv4) or its ULA prefix fd7a:115c:a1e0::/48 (IPv6).
    public static func isTailscale(address: String) -> Bool {
        if let v4 = ipv4Bytes(address) {
            return v4[0] == 100 && (v4[1] & 0xC0) == 64
        }
        if let v6 = ipv6Bytes(address) {
            return v6[0] == 0xFD && v6[1] == 0x7A && v6[2] == 0x11 && v6[3] == 0x5C && v6[4] == 0xA1 && v6[5] == 0xE0
        }
        return false
    }

    /// 169.254.0.0/16 or fe80::/10.
    public static func isLinkLocal(_ address: String) -> Bool {
        if let v4 = ipv4Bytes(address) { return v4[0] == 169 && v4[1] == 254 }
        if let v6 = ipv6Bytes(address) { return v6[0] == 0xFE && (v6[1] & 0xC0) == 0x80 }
        return false
    }

    static func ipv4Bytes(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    static func ipv6Bytes(_ s: String) -> [UInt8]? {
        let bare = s.split(separator: "%", maxSplits: 1).first.map(String.init) ?? s
        var addr = in6_addr()
        guard inet_pton(AF_INET6, bare, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }
}
