import Testing
@testable import TransportCore

@Suite("NetworkInfo")
struct NetworkInfoTests {
    @Test(arguments: [
        ("100.64.0.0", true),
        ("100.64.0.1", true),
        ("100.100.100.100", true),
        ("100.127.255.255", true),
        ("100.63.255.255", false),
        ("100.128.0.0", false),
        ("100.0.0.1", false),
        ("10.0.0.1", false),
        ("192.168.1.10", false),
        ("fd7a:115c:a1e0::1", true),
        ("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240", true),
        ("FD7A:115C:A1E0::53", true),
        ("fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff", true),
        ("fd7a:115c:a1e1::1", false),
        ("fd7a:115c:a1df:ffff::1", false),
        ("fd7a:115c::1", false),
        ("fe80::1", false),
        ("::1", false),
        ("not an address", false),
        ("", false),
        ("100.64.0", false),
    ])
    func tailscaleClassification(address: String, expected: Bool) {
        #expect(NetworkInfo.isTailscale(address: address) == expected)
    }

    @Test(arguments: [
        ("169.254.10.20", true),
        ("169.253.1.1", false),
        ("fe80::1", true),
        ("fe80::1%en0", true),
        ("febf::1", true),
        ("fec0::1", false),
        ("192.168.0.1", false),
    ])
    func linkLocalClassification(address: String, expected: Bool) {
        #expect(NetworkInfo.isLinkLocal(address) == expected)
    }

    @Test func localAddressesExcludeLoopbackAndLinkLocal() {
        let addresses = NetworkInfo.localAddresses()
        for a in addresses {
            #expect(a.address != "127.0.0.1" && a.address != "::1")
            #expect(!NetworkInfo.isLinkLocal(a.address))
            #expect(!a.address.contains("%"))
            #expect(a.isTailscale == NetworkInfo.isTailscale(address: a.address))
            #expect(a.isIPv6 == a.address.contains(":"))
        }
        // IPv4 entries come first.
        if let firstV6 = addresses.firstIndex(where: \.isIPv6) {
            #expect(!addresses[firstV6...].contains { !$0.isIPv6 })
        }
        #expect(Set(addresses).count == addresses.count)
    }
}
