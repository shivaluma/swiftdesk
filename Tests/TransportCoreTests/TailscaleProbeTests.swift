import Foundation
import Testing
@testable import TransportCore

@Suite("TailscaleProbe parsing")
struct TailscaleProbeTests {
    /// Trimmed `tailscale status --json` with synthetic data in the real field layout.
    static let fixture = Data("""
    {
      "Version": "1.90.0",
      "BackendState": "Running",
      "TailscaleIPs": ["100.101.1.1", "fd7a:115c:a1e0::1"],
      "Self": {
        "HostName": "self-mac", "DNSName": "self-mac.tail1234.ts.net.",
        "TailscaleIPs": ["100.101.1.1", "fd7a:115c:a1e0::1"], "CurAddr": "", "Relay": "fra"
      },
      "Peer": {
        "nodekey:aaa": {
          "HostName": "Studio", "DNSName": "studio.tail1234.ts.net.", "OS": "macOS",
          "TailscaleIPs": ["100.101.2.2", "fd7a:115c:a1e0::2"],
          "CurAddr": "192.168.1.20:41641", "Relay": "fra", "PeerRelay": "", "Online": true
        },
        "nodekey:bbb": {
          "HostName": "travel-air", "DNSName": "travel-air.tail1234.ts.net.", "OS": "macOS",
          "TailscaleIPs": ["100.101.3.3", "fd7a:115c:a1e0::3"],
          "CurAddr": "", "Relay": "nyc", "PeerRelay": "", "Online": true
        },
        "nodekey:ccc": {
          "HostName": "office", "DNSName": "office.tail1234.ts.net.", "OS": "macOS",
          "TailscaleIPs": ["100.101.4.4"],
          "CurAddr": "", "Relay": "lhr", "PeerRelay": "100.101.9.9:7777", "Online": true
        },
        "nodekey:ddd": {
          "HostName": "old", "DNSName": "", "TailscaleIPs": ["100.101.5.5"]
        }
      }
    }
    """.utf8)

    @Test func directPeerByIPv4() throws {
        let path = try #require(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "100.101.2.2"))
        #expect(path == TailscalePeerPath(peerAddress: "100.101.2.2", direct: true, relay: "fra",
                                          currentAddress: "192.168.1.20:41641"))
        #expect(path.summary == "Tailscale (direct)")
    }

    @Test func directPeerByIPv6WithBrackets() throws {
        let path = try #require(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "[FD7A:115C:A1E0::2]"))
        #expect(path.direct)
    }

    @Test func relayedPeerReportsDERPRegion() throws {
        let path = try #require(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "100.101.3.3"))
        #expect(!path.direct)
        #expect(path.relay == "nyc")
        #expect(path.currentAddress == nil)
        #expect(path.summary == "Tailscale (relay: nyc)")
    }

    @Test func peerRelayTakesPrecedenceOverDERP() throws {
        let path = try #require(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "100.101.4.4"))
        #expect(!path.direct)
        #expect(path.relay == "100.101.9.9:7777")
    }

    @Test func peerWithMissingFieldsIsRelayedWithoutName() throws {
        let path = try #require(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "100.101.5.5"))
        #expect(!path.direct)
        #expect(path.relay == nil)
        #expect(path.summary == "Tailscale (relay)")
    }

    @Test(arguments: ["studio", "Studio", "studio.tail1234.ts.net", "studio.tail1234.ts.net.", " STUDIO "])
    func matchesHostNameAndMagicDNS(name: String) throws {
        let path = try #require(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: name))
        #expect(path.direct)
        #expect(path.peerAddress == name)
    }

    @Test func unknownAddressAndSelfAreNotPeers() {
        #expect(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "100.101.200.200") == nil)
        #expect(TailscaleProbe.parse(statusJSON: Self.fixture, peerAddress: "100.101.1.1") == nil)
    }

    @Test func malformedInputYieldsNil() {
        #expect(TailscaleProbe.parse(statusJSON: Data("not json".utf8), peerAddress: "100.101.2.2") == nil)
        #expect(TailscaleProbe.parse(statusJSON: Data("[]".utf8), peerAddress: "100.101.2.2") == nil)
        #expect(TailscaleProbe.parse(statusJSON: Data(#"{"Peer": null}"#.utf8), peerAddress: "100.101.2.2") == nil)
        #expect(TailscaleProbe.parse(statusJSON: Data(#"{"Peer": {"x": 5}}"#.utf8), peerAddress: "100.101.2.2") == nil)
    }

    @Test func runReturnsNilForMissingExecutableAndHonorsTimeout() {
        #expect(TailscaleProbe.run(URL(fileURLWithPath: "/nonexistent/tailscale"), arguments: [], timeout: 1) == nil)
        let start = Date()
        #expect(TailscaleProbe.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
        // Spawning a real child is unreliable on hosted CI virtual machines (it fails there, never on real Macs), so
        // the success path is only checked locally.
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }
        let echo = TailscaleProbe.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["{}"], timeout: 10)
        #expect(echo.map { String(decoding: $0, as: UTF8.self) } == "{}\n")
    }
}
