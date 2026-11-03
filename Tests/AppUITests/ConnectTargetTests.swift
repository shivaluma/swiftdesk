import Foundation
import Testing
import SessionCore
import TransportCore
@testable import AppUI

@Suite("ConnectTarget parsing")
struct ConnectTargetTests {
    private func parse(_ host: String, _ port: String = "") -> Result<ConnectTarget, ConnectTarget.ParseError> {
        ConnectTarget.parse(host: host, port: port, defaultPort: 47800)
    }

    @Test(arguments: [
        ("studio.local", "", "studio.local", UInt16(47800)),
        ("  studio.local \n", "", "studio.local", 47800),
        ("studio.local", "5000", "studio.local", 5000),
        ("studio.local:6000", "5000", "studio.local", 6000),
        ("192.168.1.20", "", "192.168.1.20", 47800),
        ("192.168.1.20:47801", "", "192.168.1.20", 47801),
        ("100.101.102.103", " 47802 ", "100.101.102.103", 47802),
        ("fd7a:115c:a1e0::1", "", "fd7a:115c:a1e0::1", 47800),
        ("[fd7a:115c:a1e0::1]", "", "fd7a:115c:a1e0::1", 47800),
        ("[fd7a:115c:a1e0::1]:9000", "", "fd7a:115c:a1e0::1", 9000),
        ("mac-mini.tailnet-1234.ts.net", "", "mac-mini.tailnet-1234.ts.net", 47800),
    ])
    func validInputs(host: String, port: String, expectedHost: String, expectedPort: UInt16) throws {
        let target = try parse(host, port).get()
        #expect(target == ConnectTarget(host: expectedHost, port: expectedPort))
    }

    @Test func emptyHostIsRejected() {
        #expect(parse("") == .failure(.emptyHost))
        #expect(parse("   ") == .failure(.emptyHost))
        #expect(parse(":47800") == .failure(.emptyHost))
        #expect(parse("[]:47800") == .failure(.emptyHost))
    }

    @Test func badPortsAreRejectedNotDefaulted() {
        #expect(parse("mac.local", "0") == .failure(.invalidPort("0")))
        #expect(parse("mac.local", "65536") == .failure(.invalidPort("65536")))
        #expect(parse("mac.local", "-1") == .failure(.invalidPort("-1")))
        #expect(parse("mac.local", "80a") == .failure(.invalidPort("80a")))
        #expect(parse("mac.local:abc") == .failure(.invalidPort("abc")))
        #expect(parse("mac.local:") == .failure(.invalidPort("")))
        #expect(parse("[::1]:99999") == .failure(.invalidPort("99999")))
    }

    @Test func urlsAndWhitespaceInsideHostAreRejected() {
        #expect(parse("https://mac.local") == .failure(.invalidHost))
        #expect(parse("mac local") == .failure(.invalidHost))
        #expect(parse("[::1") == .failure(.invalidHost))
        #expect(parse("[::1]x") == .failure(.invalidHost))
        #expect(parse("mäc.local") == .failure(.invalidHost))
    }

    @Test func parsePortBoundaries() {
        #expect(ConnectTarget.parsePort("1") == 1)
        #expect(ConnectTarget.parsePort("65535") == 65535)
        #expect(ConnectTarget.parsePort("") == nil)
        #expect(ConnectTarget.parsePort("000001") == nil)   // more than 5 digits
        #expect(ConnectTarget.parsePort("٣") == nil)        // non-ASCII digit
    }

    @Test func endpointStringBracketsIPv6() {
        #expect(ConnectTarget(host: "10.0.0.2", port: 47800).displayString == "10.0.0.2:47800")
        #expect(ConnectTarget(host: "fd7a::1", port: 47800).displayString == "[fd7a::1]:47800")
    }

    @Test func trustedHostKeysRoundTrip() throws {
        // Saved trusted-host keys must parse back to the same address (the list's Connect button relies on it).
        for (host, port) in [("mac.local", UInt16(47800)), ("10.1.2.3", 5000), ("fd7a:115c:a1e0::5", 47800)] {
            let key = TrustedHostStore.key(host: host, port: port)
            let target = try ConnectTarget.parse(host: key).get()
            #expect(target == ConnectTarget(host: host, port: port), "key \(key)")
        }
    }

    @Test func errorDescriptionsAreHumanReadable() {
        #expect(ConnectTarget.ParseError.emptyHost.description.contains("host name"))
        #expect(ConnectTarget.ParseError.invalidPort("x").description.contains("1–65535"))
    }
}

@Suite("Address presentation")
struct AddressPresentationTests {
    @Test func lanBeforeTailscaleAndIPv4BeforeIPv6() {
        let input = [
            InterfaceAddress(interface: "utun4", address: "100.88.1.2", isIPv6: false, isTailscale: true),
            InterfaceAddress(interface: "en0", address: "2001:db8::5", isIPv6: true, isTailscale: false),
            InterfaceAddress(interface: "utun4", address: "fd7a:115c:a1e0::2", isIPv6: true, isTailscale: true),
            InterfaceAddress(interface: "en0", address: "192.168.1.20", isIPv6: false, isTailscale: false),
        ]
        let rows = AddressPresentation.rows(input, port: 47800)
        #expect(rows.map(\.address) == ["192.168.1.20", "2001:db8::5", "100.88.1.2", "fd7a:115c:a1e0::2"])
        #expect(rows.map(\.isTailscale) == [false, false, true, true])
        #expect(rows[0].endpoint == "192.168.1.20:47800")
        #expect(rows[1].endpoint == "[2001:db8::5]:47800")
        #expect(rows[2].kindLabel == "Tailscale")
        #expect(rows[0].kindLabel == "Local network (en0)")
    }

    @Test func linkLocalAddressesAreHidden() {
        let input = [
            InterfaceAddress(interface: "en0", address: "169.254.10.1", isIPv6: false, isTailscale: false),
            InterfaceAddress(interface: "en0", address: "fe80::1", isIPv6: true, isTailscale: false),
            InterfaceAddress(interface: "en0", address: "10.0.0.4", isIPv6: false, isTailscale: false),
        ]
        #expect(AddressPresentation.rows(input, port: 1).map(\.address) == ["10.0.0.4"])
    }

    @Test func rowIdentifiersAreUnique() {
        let input = [
            InterfaceAddress(interface: "en0", address: "10.0.0.4", isIPv6: false, isTailscale: false),
            InterfaceAddress(interface: "en1", address: "10.0.0.4", isIPv6: false, isTailscale: false),
        ]
        let ids = AddressPresentation.rows(input, port: 1).map(\.id)
        #expect(Set(ids).count == 2)
    }
}
