import CryptoKit
import Foundation
@preconcurrency import Network
import Security
import Synchronization
import WireProtocol

/// Builds the QUIC/TLS options both roles use. Every value here was validated empirically by `QUICSpike`
/// (see docs/TRANSPORT.md); change them only together with a re-run of the spike.
enum QUICConfiguration {
    /// QUIC idle timeout. 0.1.4: 30 s (was 10 s) so a Wi-Fi blackout of a few seconds — measured: bursts of 3–10 s
    /// with nothing delivered — no longer kills the session. Prompt reactions to a silent peer no longer depend on
    /// it: the session layer releases held input after 1 s without traffic and shows "Poor connection" on the Viewer
    /// (`LinkSilenceDetector`), and the Viewer reconnects on its own if the connection does fail. QUIC uses the
    /// smaller of both endpoints' values, so with a 0.1.3-or-older peer it stays 10 s. Keepalives (set on the
    /// connection metadata once ready) keep a quiet-but-alive session open.
    static let idleTimeoutMillis = 30_000
    /// Upper bound we *accept* for DATAGRAM frames. The usable size is still limited by the path MTU and is read
    /// back from `NWProtocolQUIC.Metadata.usableDatagramFrameSize`; senders additionally cap at
    /// `WireConstants.defaultMaxDatagramSize` so fragments survive Tailscale's 1280-byte MTU.
    static let maxDatagramFrameSize = 65_535
    /// Seconds between QUIC keepalive PINGs; must stay well below `idleTimeoutMillis`.
    static let keepAliveSeconds = 3

    enum Role { case host, viewer }

    /// Group-level QUIC options with mTLS. `verify` runs on `verifyQueue` with the SHA-256 of the peer leaf
    /// (nil if the peer presented no parseable certificate) and returns whether to accept.
    static func groupOptions(identity: DeviceIdentity, role: Role, verifyQueue: DispatchQueue,
                             verify: @escaping @Sendable (Data?) -> Bool) -> NWProtocolQUIC.Options {
        let options = NWProtocolQUIC.Options(alpn: [WireConstants.alpn])
        options.idleTimeout = idleTimeoutMillis
        options.maxDatagramFrameSize = maxDatagramFrameSize
        options.direction = .bidirectional
        let sec = options.securityProtocolOptions
        if let localIdentity = sec_identity_create(identity.secIdentity) {
            sec_protocol_options_set_local_identity(sec, localIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        if role == .host {
            // The host must see a client certificate: its fingerprint is what the operator approves and what the
            // AUTH message is bound to. Without this a client could connect anonymously.
            sec_protocol_options_set_peer_authentication_required(sec, true)
        }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            complete(verify(leafFingerprint(trust)))
        }, verifyQueue)
        return options
    }

    /// Options for extracting the unreliable datagram flow from an established group: the group's *own* options
    /// object with `isDatagram` switched on. Network.framework joins the new flow to the existing QUIC protocol
    /// instance only if the options compare equal to the group's. macOS 26 compares by identity (a fresh
    /// `NWProtocolQUIC.Options`, even one configured identically, fails with "could not find protocol to join in
    /// existing protocol stack" → ENETDOWN). macOS 27 also accepts a fresh object. Reusing the group's object works on
    /// both (verified on 26.3 and 27, loopback and Tailscale, including back-to-back connections on one listener).
    /// Setting `isDatagram` on an established group's options does not change the group or later listener accepts.
    static func datagramFlowOptions(from groupOptions: NWProtocolQUIC.Options) -> NWProtocolQUIC.Options {
        // The host's object is shared by every connection its listener accepts; serialize the (idempotent) write.
        datagramOptionsLock.withLock { _ in
            if !groupOptions.isDatagram { groupOptions.isDatagram = true }
        }
        return groupOptions
    }

    private static let datagramOptionsLock = Mutex(())

    static func parameters(_ options: NWProtocolQUIC.Options) -> NWParameters {
        let parameters = NWParameters(quic: options)
        // Marks packets for the Wi-Fi video access category / DSCP; the whole session is latency-sensitive.
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    /// SHA-256 of the leaf certificate presented in a TLS handshake.
    static func leafFingerprint(_ trust: sec_trust_t) -> Data? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return DeviceIdentity.fingerprint(ofCertificate: SecCertificateCopyData(leaf) as Data)
    }

    /// SHA-256 of the peer leaf certificate from an established connection's security metadata.
    static func peerFingerprint(_ metadata: sec_protocol_metadata_t) -> Data? {
        let result = Mutex<Data?>(nil)
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            result.withLock { current in
                guard current == nil else { return }   // first certificate is the leaf
                let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
                current = DeviceIdentity.fingerprint(ofCertificate: SecCertificateCopyData(ref) as Data)
            }
        }
        return result.withLock { $0 }
    }

    /// "ip:port", with IPv6 literals bracketed.
    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            let h = describe(host)
            return h.contains(":") ? "[\(h)]:\(port.rawValue)" : "\(h):\(port.rawValue)"
        default:
            return "\(endpoint)"
        }
    }

    static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let a):
            // An interface scope ("%en0") is meaningless for IPv4 routing and confuses users; only IPv6
            // link-local addresses need one.
            let text = "\(a)"
            return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        case .ipv6(let a): return "\(a)"
        @unknown default: return "\(host)"
        }
    }

    static func hostString(_ endpoint: NWEndpoint) -> String? {
        if case .hostPort(let host, _) = endpoint { return describe(host) }
        return nil
    }
}
