import Foundation
@testable import WireProtocol

/// Deterministic SplitMix64 so every randomized test is reproducible from its seed.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> Data {
        var d = Data(count: count)
        for i in 0..<count { d[i] = UInt8.random(in: 0...255, using: &self) }
        return d
    }

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}

/// One instance of every control message case, with non-trivial field values.
let sampleMessages: [ControlMessage] = [
    .hello(Hello(protocolVersion: 1, deviceName: "Isabella’s MacBook Pro 🖥", appVersion: "1.0 (42)")),
    .auth(Auth(viewerFingerprint: Data((0..<32).map { UInt8($0) }),
               hostFingerprint: Data((0..<32).map { UInt8(255 - $0) }),
               nonce: Data((0..<16).map { UInt8($0 * 7 & 0xFF) }))),
    .accept(Accept(sessionId: 0xDEAD_BEEF, sessionToken: Data(repeating: 0xA5, count: 16), hostName: "studio")),
    .deny(Deny(reason: .identityMismatch, message: "fingerprint changed")),
    .config(StreamConfig(width: 1280, height: 720, fps: 60, bitrateKbps: 3000,
                         displayPointWidth: 1512, displayPointHeight: 982, codec: 1)),
    .ping(Ping(id: 7, sentAtNanos: 0x0102_0304_0506_0708)),
    .pong(Ping(id: 0xFFFF_FFFF, sentAtNanos: .max)),
    .keyDown(KeyEvent(seq: 1, keyCode: 0x24, modifiers: 0x0010_0000, isRepeat: false)),
    .keyUp(KeyEvent(seq: 2, keyCode: 0x7E, modifiers: 0, isRepeat: true)),
    .mouseDown(MouseButtonEvent(seq: 3, button: .left, x: 0.25, y: 0.75, clickCount: 2, modifiers: 0x0002_0000)),
    .mouseUp(MouseButtonEvent(seq: 4, button: .other, x: 1, y: 0, clickCount: 1, modifiers: 0)),
    .mouseMove(PointerState(seq: 5, x: 0.5, y: 0.125, buttonsMask: 0b101)),
    .scroll(ScrollEvent(seq: 6, deltaX: -3.5, deltaY: 12.25, isPrecise: true, phase: 1, momentumPhase: 4)),
    .requestKeyframe(reason: 3),
    .disconnect(.permissionRevoked),
    .stats(ViewerStats(windowMillis: 1000, packetsReceived: 3600, packetsLost: 36, framesCompleted: 59,
                       framesLost: 1, framesPresented: 58, decodeMicrosAvg: 1800, decodeToPresentMicrosAvg: 6000)),
    .passwordChallenge(PasswordChallenge(salt: Data((0..<16).map { UInt8($0 + 1) }), iterations: 1_000_000,
                                         nonce: Data((0..<32).map { UInt8(200 - $0) }))),
    .passwordResponse(.proof(Data((0..<32).map { UInt8($0 * 5 & 0xFF) }))),
    .clipboardState(ClipboardState(enabled: true)),
    .clipboard(ClipboardContent(items: [
        .init(kind: .url, data: Data("https://example.com/ä".utf8)),
        .init(kind: .plainText, data: Data("Copied text 📋".utf8)),
    ])),
    .cursorImage(CursorImage(id: 3, pixelWidth: 34, pixelHeight: 48, pointWidth: 17, pointHeight: 24,
                             hotSpotX: 8.5, hotSpotY: 12, png: ClipboardContent.pngSignature + Data([0, 0, 0, 13]))),
    .cursorShape(.image(id: 3)),
]

/// Concatenated wire framing for `sampleMessages`.
func framedSampleStream() -> Data {
    sampleMessages.reduce(into: Data()) { $0.append(ControlFraming.frame($1)) }
}

/// Builds a framed control message by hand: `[u32 length][type][payload]`.
func rawFrame(type: UInt8, payload: [UInt8]) -> Data {
    var w = ByteWriter()
    w.u32(UInt32(1 + payload.count))
    w.u8(type)
    w.bytes(Data(payload))
    return w.data
}

/// Deterministic frame content so reassembled bytes can be compared exactly.
func frameBytes(id: UInt32, count: Int) -> Data {
    var d = Data(count: count)
    var x = id &* 2_654_435_761
    for i in 0..<count {
        x = x &* 1_103_515_245 &+ 12345
        d[i] = UInt8(truncatingIfNeeded: x >> 16)
    }
    return d
}

/// Packetizes a frame and parses every datagram back into (header, payload) the way the receive path does.
func fragments(sessionId: UInt32 = 42, frameId: UInt32, size: Int, flags: VideoFlags = [],
               captureNanos: UInt64 = 1_000, maxDatagramSize: Int = WireConstants.defaultMaxDatagramSize)
    -> [(header: VideoPacketHeader, payload: Data)] {
    let p = VideoPacketizer(sessionId: sessionId, maxDatagramSize: maxDatagramSize)
    let datagrams = try! p.packetize(frameId: frameId, frame: frameBytes(id: frameId, count: size), flags: flags,
                                     captureTimestampNanos: captureNanos, hostPipelineMicros: 500)
    return datagrams.map { d in
        guard case .video(let h, let payload) = try! Datagram.parse(d) else { fatalError("not video") }
        return (h, payload)
    }
}

extension Array where Element == ReassemblyEvent {
    var completedFrames: [EncodedFrame] {
        compactMap { if case .frameComplete(let f) = $0 { f } else { nil } }
    }
    var lostCount: Int {
        reduce(0) { if case .framesLost(let n) = $1 { $0 + n } else { $0 } }
    }
}
