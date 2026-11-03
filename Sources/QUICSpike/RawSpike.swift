import CryptoKit
import Foundation
@preconcurrency import Network
import Security
import Synchronization
import TransportCore

/// Step 1 of Milestone B: raw Network.framework QUIC exploration (no TransportCore networking code), kept so the
/// findings in docs/TRANSPORT.md can be reproduced. Run with `QUICSpike --raw [--wrong-pin] [--client-noid]
/// [--no-server-extract]`.
final class RawSpike: @unchecked Sendable {
    let alpn = "swiftdesk/1"
    let serverQueue = DispatchQueue(label: "spike.raw.server")
    let clientQueue = DispatchQueue(label: "spike.raw.client")
    let verifyQueue = DispatchQueue(label: "spike.raw.verify")
    let counts = Mutex<[String: Int]>([:])
    let serverFlows = Mutex<[NWConnection]>([])
    let serverDatagramFlow = Mutex<NWConnection?>(nil)
    let echoSignal = DispatchSemaphore(value: 0)

    let wrongPin: Bool
    let clientWithoutIdentity: Bool
    let serverExtract: Bool
    let noClientHandler: Bool

    init(arguments: [String]) {
        wrongPin = arguments.contains("--wrong-pin")
        clientWithoutIdentity = arguments.contains("--client-noid")
        serverExtract = !arguments.contains("--no-server-extract")
        noClientHandler = arguments.contains("--no-client-handler")
    }

    func count(_ key: String, _ n: Int = 1) { counts.withLock { $0[key, default: 0] += n } }
    func value(_ key: String) -> Int { counts.withLock { $0[key] ?? 0 } }

    static func fingerprint(_ trust: sec_trust_t) -> Data? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }

    static func metadataFingerprint(_ meta: sec_protocol_metadata_t) -> Data? {
        let out = Mutex<Data?>(nil)
        _ = sec_protocol_metadata_access_peer_certificate_chain(meta) { cert in
            out.withLock { o in
                if o == nil { o = Data(SHA256.hash(data: SecCertificateCopyData(sec_certificate_copy_ref(cert).takeRetainedValue()) as Data)) }
            }
        }
        return out.withLock { $0 }
    }

    func options(identity: DeviceIdentity?, server: Bool, pin: Data?) -> NWProtocolQUIC.Options {
        let o = NWProtocolQUIC.Options(alpn: [alpn])
        o.idleTimeout = 10_000
        o.maxDatagramFrameSize = 65_535
        let sec = o.securityProtocolOptions
        if let identity { sec_protocol_options_set_local_identity(sec, sec_identity_create(identity.secIdentity)!) }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        if server { sec_protocol_options_set_peer_authentication_required(sec, true) }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let fp = Self.fingerprint(trust)
            let ok = pin.map { fp == $0 } ?? (fp != nil)
            spikeLog("raw \(server ? "server" : "client") verify block: peer=\(fp.map(DeviceIdentity.display) ?? "nil") accept=\(ok)")
            complete(ok)
        }, verifyQueue)
        return o
    }

    func streamReceive(_ c: NWConnection, tag: String, echo: Bool) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, err in
            if let data, !data.isEmpty {
                count(tag)
                if echo { c.send(content: data, completion: .contentProcessed { _ in }) } else { echoSignal.signal() }
            }
            if err != nil || (done && (data?.isEmpty ?? true)) { return }
            streamReceive(c, tag: tag, echo: echo)
        }
    }

    func messageReceive(_ c: NWConnection, tag: String) {
        c.receiveMessage { [self] data, _, _, err in
            if let data, !data.isEmpty { count(tag) }
            if err == nil { messageReceive(c, tag: tag) }
        }
    }

    func run() throws {
        let serverID = try DeviceIdentity.regenerate(label: "SwiftDesk QUICSpike Raw Server")
        let clientID = try DeviceIdentity.regenerate(label: "SwiftDesk QUICSpike Raw Client")
        defer {
            try? DeviceIdentity.delete(label: "SwiftDesk QUICSpike Raw Server")
            try? DeviceIdentity.delete(label: "SwiftDesk QUICSpike Raw Client")
        }
        let listener = try NWListener(using: NWParameters(quic: options(identity: serverID, server: true, pin: nil)), on: .any)
        let listening = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { s in
            spikeLog("raw listener \(s)")
            if case .ready = s { listening.signal() }
        }
        // NOTE: also setting listener.newConnectionHandler makes the QUIC listener fail with EINVAL.
        listener.newConnectionGroupHandler = { [self] g in
            spikeLog("raw newConnectionGroupHandler members=\((g.descriptor as? NWMultiplexGroup)?.members ?? [])")
            g.stateUpdateHandler = { [self] s in
                spikeLog("raw server group \(s)")
                guard case .ready = s else { return }
                if let m = g.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
                    spikeLog("raw server group metadata peer=\(Self.metadataFingerprint(m.securityProtocolMetadata).map(DeviceIdentity.display) ?? "nil") alpn=\(m.negotiatedALPN ?? "-")")
                }
                if serverExtract {
                    let o = NWProtocolQUIC.Options(alpn: [alpn])
                    o.isDatagram = true
                    if let dg = g.extract(connectionTo: nil, using: o) {
                        serverDatagramFlow.withLock { $0 = dg }
                        dg.stateUpdateHandler = { s in
                            if case .ready = s, let m = dg.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
                                spikeLog("raw server extracted datagram flow ready usableDatagramFrameSize=\(m.usableDatagramFrameSize)")
                            }
                        }
                        messageReceive(dg, tag: "server.dg")
                        dg.start(queue: serverQueue)
                    }
                }
            }
            g.newConnectionHandler = { [self] c in
                serverFlows.withLock { $0.append(c) }
                c.stateUpdateHandler = { [self] s in
                    guard case .ready = s else { return }
                    let m = c.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
                    let usable = m?.usableDatagramFrameSize ?? 0
                    spikeLog("raw server incoming flow ready stream=\(m.map { String($0.streamIdentifier) } ?? "nil") usable=\(usable)")
                    if usable > 0 { messageReceive(c, tag: "server.implicitdg") }
                }
                streamReceive(c, tag: "server.stream", echo: true)
                c.start(queue: serverQueue)
            }
            g.start(queue: serverQueue)
        }
        listener.start(queue: serverQueue)
        listening.wait()
        let port = listener.port!
        spikeLog("raw listening on port \(port)")

        let pin = wrongPin ? Data(repeating: 0xAB, count: 32) : serverID.fingerprint
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: port)),
                                      using: NWParameters(quic: options(identity: clientWithoutIdentity ? nil : clientID, server: false, pin: pin)))
        let groupDone = DispatchSemaphore(value: 0)
        group.stateUpdateHandler = { s in
            spikeLog("raw client group \(s)")
            switch s { case .ready, .failed, .cancelled: groupDone.signal(); default: break }
        }
        if !noClientHandler {
            // Required: without a newConnectionHandler (or receive handler) the client group never leaves .setup.
            group.newConnectionHandler = { c in c.cancel() }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        group.start(queue: clientQueue)
        defer { group.cancel(); listener.cancel(); Thread.sleep(forTimeInterval: 0.2) }
        if groupDone.wait(timeout: .now() + 10) == .timedOut {
            spikeLog("raw RESULT client group did not reach ready/failed in 10 s (state \(group.state))")
            return
        }
        guard group.state == .ready else { spikeLog("raw RESULT client group \(group.state)"); return }
        spikeLog(String(format: "raw handshake %.2f ms", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))

        guard let control = NWConnection(from: group) else { spikeLog("raw NWConnection(from:) returned nil"); return }
        let controlReady = DispatchSemaphore(value: 0)
        control.stateUpdateHandler = { s in if case .ready = s { controlReady.signal() } }
        control.start(queue: clientQueue)
        _ = controlReady.wait(timeout: .now() + 5)
        spikeLog("raw client control stream id=\((control.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata).map { String($0.streamIdentifier) } ?? "nil")")
        streamReceive(control, tag: "client.echo", echo: false)
        var rtts: [Double] = []
        for i in 0..<1000 {
            var payload = Data(count: 16)
            payload[0] = UInt8(i & 0xFF)
            let s = DispatchTime.now().uptimeNanoseconds
            control.send(content: payload, completion: .contentProcessed { _ in })
            if echoSignal.wait(timeout: .now() + 2) == .timedOut { break }
            rtts.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
        }
        spikeLog("raw control echo RTT \(summarize(rtts))")

        let dgOptions = NWProtocolQUIC.Options(alpn: [alpn])
        dgOptions.isDatagram = true
        guard let flow = NWConnection(from: group, to: nil, using: dgOptions) else { spikeLog("raw datagram flow nil"); return }
        let flowReady = DispatchSemaphore(value: 0)
        flow.stateUpdateHandler = { s in if case .ready = s { flowReady.signal() } }
        messageReceive(flow, tag: "client.dg")
        flow.start(queue: clientQueue)
        _ = flowReady.wait(timeout: .now() + 5)
        let usable = (flow.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata)?.usableDatagramFrameSize ?? 0
        let size = min(usable, 1150)
        spikeLog("raw client datagram flow usableDatagramFrameSize=\(usable); sending 2000 x \(size) B")
        flow.batch {
            for _ in 0..<2000 { flow.send(content: Data(count: size), completion: .contentProcessed { _ in }) }
        }
        Thread.sleep(forTimeInterval: 1)
        spikeLog("raw RESULT client->server datagrams: extracted=\(value("server.dg")) implicit=\(value("server.implicitdg")) of 2000")
        if let sdg = serverDatagramFlow.withLock({ $0 }) {
            sdg.batch {
                for _ in 0..<2000 { sdg.send(content: Data(count: size), completion: .contentProcessed { _ in }) }
            }
            Thread.sleep(forTimeInterval: 1)
            spikeLog("raw RESULT server->client datagrams: \(value("client.dg")) of 2000")
        }
        spikeLog("raw server saw \(serverFlows.withLock { $0.count }) incoming flows (control stream + an idle flow that never carries data)")
        control.cancel()
        flow.cancel()
    }
}
