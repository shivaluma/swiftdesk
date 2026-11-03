import Foundation

// Payload layouts (all big-endian, no padding):
//   hello            u16 protocolVersion, str deviceName, str appVersion
//   auth             32 viewerFingerprint, 32 hostFingerprint, 16 nonce
//   accept           u32 sessionId, 16 sessionToken, str hostName
//   deny             u8 reason, str message
//   config           u16 width, u16 height, u8 fps, u32 bitrateKbps, f32 displayPointWidth, f32 displayPointHeight, u8 codec
//   ping / pong      u32 id, u64 sentAtNanos
//   keyDown / keyUp  u32 seq, u16 keyCode, u64 modifiers, bool isRepeat
//   mouseDown / Up   u32 seq, u8 button, f32 x, f32 y, u8 clickCount, u64 modifiers
//   mouseMove        u32 seq, f32 x, f32 y, u8 buttonsMask
//   scroll           u32 seq, f32 deltaX, f32 deltaY, bool isPrecise, u8 phase, u8 momentumPhase
//   requestKeyframe  u8 reason
//   disconnect       u8 reason
//   stats            8 x u32 (field order as declared in ViewerStats)
//   passwordChallenge 16 salt, u32 iterations, 32 nonce                       (52 bytes)
//   passwordResponse u8 kind (0 none, 1 proof), 32 proof (all zero for none) (33 bytes)
//   clipboardState   u8 flags (bit 0 enabled; others 0)                       (1 byte)
//   clipboard        u8 count (1…4), count × { u8 kind, u32 length, bytes }   (side stream only, see Clipboard.swift)
//   cursorImage      u32 id, u16 pixelWidth, u16 pixelHeight, f32 pointWidth, f32 pointHeight, f32 hotSpotX,
//                    f32 hotSpotY, u32 pngLength, png                         (side stream only, see Cursor.swift)
//   cursorShape      u8 kind (0 unavailable, 1 hidden, 2 image, 3 off), u32 id (≠ 0 only for image)  (5 bytes)
// str = u16 byte length + UTF-8 (<= maxStringBytes). Floats must be finite: non-finite values are written as 0
// and rejected on decode, so a NaN can never reach coordinate mapping or event injection on the peer.

extension ControlMessage {
    /// The message payload without the length prefix or type byte.
    public func encodePayload() -> Data {
        var w = ByteWriter(capacity: 96)
        encodePayload(into: &w)
        return w.data
    }

    func encodePayload(into w: inout ByteWriter) {
        switch self {
        case .hello(let m):
            w.u16(m.protocolVersion)
            w.string(m.deviceName)
            w.string(m.appVersion)
        case .auth(let m):
            w.fixedBytes(m.viewerFingerprint, count: Auth.fingerprintSize)
            w.fixedBytes(m.hostFingerprint, count: Auth.fingerprintSize)
            w.fixedBytes(m.nonce, count: Auth.nonceSize)
        case .accept(let m):
            w.u32(m.sessionId)
            w.fixedBytes(m.sessionToken, count: Accept.sessionTokenSize)
            w.string(m.hostName)
        case .deny(let m):
            w.u8(m.reason.rawValue)
            w.string(m.message)
        case .config(let m):
            w.u16(m.width)
            w.u16(m.height)
            w.u8(m.fps)
            w.u32(m.bitrateKbps)
            w.finiteF32(m.displayPointWidth)
            w.finiteF32(m.displayPointHeight)
            w.u8(m.codec)
        case .ping(let m), .pong(let m):
            w.u32(m.id)
            w.u64(m.sentAtNanos)
        case .keyDown(let m), .keyUp(let m):
            w.u32(m.seq)
            w.u16(m.keyCode)
            w.u64(m.modifiers)
            w.bool(m.isRepeat)
        case .mouseDown(let m), .mouseUp(let m):
            w.u32(m.seq)
            w.u8(m.button.rawValue)
            w.finiteF32(m.x)
            w.finiteF32(m.y)
            w.u8(m.clickCount)
            w.u64(m.modifiers)
        case .mouseMove(let m):
            w.u32(m.seq)
            w.finiteF32(m.x)
            w.finiteF32(m.y)
            w.u8(m.buttonsMask)
        case .scroll(let m):
            w.u32(m.seq)
            w.finiteF32(m.deltaX)
            w.finiteF32(m.deltaY)
            w.bool(m.isPrecise)
            w.u8(m.phase)
            w.u8(m.momentumPhase)
        case .requestKeyframe(let reason):
            w.u8(reason)
        case .disconnect(let reason):
            w.u8(reason.rawValue)
        case .stats(let m):
            w.u32(m.windowMillis)
            w.u32(m.packetsReceived)
            w.u32(m.packetsLost)
            w.u32(m.framesCompleted)
            w.u32(m.framesLost)
            w.u32(m.framesPresented)
            w.u32(m.decodeMicrosAvg)
            w.u32(m.decodeToPresentMicrosAvg)
        case .passwordChallenge(let m):
            w.fixedBytes(m.salt, count: PasswordChallenge.saltSize)
            w.u32(m.iterations)
            w.fixedBytes(m.nonce, count: PasswordChallenge.nonceSize)
        case .passwordResponse(let m):
            w.u8(m.kind.rawValue)
            w.fixedBytes(m.kind == .none ? Data() : m.proof, count: PasswordResponse.proofSize)
        case .clipboardState(let m):
            w.u8(m.flags)
        case .clipboard(let m):
            m.encode(into: &w)
        case .cursorImage(let m):
            m.encode(into: &w)
        case .cursorShape(let m):
            m.encode(into: &w)
        }
    }

    /// Decodes one payload. Strict by design: unknown types, trailing bytes, out-of-range enum values, mis-sized
    /// fixed fields, oversized or invalid-UTF-8 strings and non-finite floats are all rejected, because a
    /// lenient parser on an input-injection channel is an attack surface.
    public static func decode(type: UInt8, payload: Data) throws -> ControlMessage {
        guard let kind = ControlMessageType(rawValue: type) else { throw WireError.unknownType(type) }
        var r = ByteReader(payload)
        let message: ControlMessage
        switch kind {
        case .hello:
            message = .hello(Hello(protocolVersion: try r.u16(), deviceName: try r.string(), appVersion: try r.string()))
        case .auth:
            message = .auth(Auth(viewerFingerprint: try r.bytes(count: Auth.fingerprintSize),
                                 hostFingerprint: try r.bytes(count: Auth.fingerprintSize),
                                 nonce: try r.bytes(count: Auth.nonceSize)))
        case .accept:
            message = .accept(Accept(sessionId: try r.u32(),
                                     sessionToken: try r.bytes(count: Accept.sessionTokenSize),
                                     hostName: try r.string()))
        case .deny:
            message = .deny(Deny(reason: try r.enumValue(DenyReason.self, "deny reason"), message: try r.string()))
        case .config:
            message = .config(StreamConfig(width: try r.u16(), height: try r.u16(), fps: try r.u8(),
                                           bitrateKbps: try r.u32(),
                                           displayPointWidth: try r.finiteF32(),
                                           displayPointHeight: try r.finiteF32(),
                                           codec: try r.u8()))
        case .ping:
            message = .ping(try r.ping())
        case .pong:
            message = .pong(try r.ping())
        case .keyDown:
            message = .keyDown(try r.keyEvent())
        case .keyUp:
            message = .keyUp(try r.keyEvent())
        case .mouseDown:
            message = .mouseDown(try r.mouseButtonEvent())
        case .mouseUp:
            message = .mouseUp(try r.mouseButtonEvent())
        case .mouseMove:
            message = .mouseMove(PointerState(seq: try r.u32(), x: try r.finiteF32(), y: try r.finiteF32(),
                                              buttonsMask: try r.u8()))
        case .scroll:
            message = .scroll(ScrollEvent(seq: try r.u32(), deltaX: try r.finiteF32(), deltaY: try r.finiteF32(),
                                          isPrecise: try r.bool(), phase: try r.u8(), momentumPhase: try r.u8()))
        case .requestKeyframe:
            message = .requestKeyframe(reason: try r.u8())
        case .disconnect:
            message = .disconnect(try r.enumValue(DisconnectReason.self, "disconnect reason"))
        case .stats:
            message = .stats(ViewerStats(windowMillis: try r.u32(), packetsReceived: try r.u32(),
                                         packetsLost: try r.u32(), framesCompleted: try r.u32(),
                                         framesLost: try r.u32(), framesPresented: try r.u32(),
                                         decodeMicrosAvg: try r.u32(), decodeToPresentMicrosAvg: try r.u32()))
        case .passwordChallenge:
            message = .passwordChallenge(PasswordChallenge(salt: try r.bytes(count: PasswordChallenge.saltSize),
                                                           iterations: try r.u32(),
                                                           nonce: try r.bytes(count: PasswordChallenge.nonceSize)))
        case .passwordResponse:
            let kind = try r.enumValue(PasswordResponse.Kind.self, "password response kind")
            let proof = try r.bytes(count: PasswordResponse.proofSize)
            // Canonical form only: a "none" answer must not smuggle bytes.
            if kind == .none, proof.contains(where: { $0 != 0 }) {
                throw WireError.malformed("password response without proof carries data")
            }
            message = .passwordResponse(PasswordResponse(kind: kind, proof: proof))
        case .clipboardState:
            message = .clipboardState(try ClipboardState(flags: try r.u8()))
        case .clipboard:
            message = .clipboard(try ClipboardContent.decode(from: &r))
        case .cursorImage:
            message = .cursorImage(try CursorImage.decode(from: &r))
        case .cursorShape:
            message = .cursorShape(try CursorShape.decode(from: &r))
        }
        try r.expectEnd()
        return message
    }
}

/// Stream framing: `[u32 length][u8 type][payload]`, `length = 1 + payload.count`.
public enum ControlFraming {
    /// One complete frame ready to write to the control stream (single allocation; the length is back-patched).
    public static func frame(_ message: ControlMessage) -> Data {
        var capacity = 128
        if case .clipboard(let content) = message { capacity += content.totalBytes + 5 * content.items.count }
        if case .cursorImage(let image) = message { capacity += CursorImage.headerSize + image.png.count }
        var w = ByteWriter(capacity: capacity)
        w.u32(0)
        w.u8(message.type.rawValue)
        message.encodePayload(into: &w)
        w.patchU32(UInt32(w.count - WireConstants.controlLengthPrefixSize), at: 0)
        return w.data
    }
}

/// Incremental control-stream parser, tolerant of arbitrary chunking (QUIC may deliver a message split across
/// any number of reads, or many messages in one read).
///
/// Complete messages are parsed straight out of the incoming chunk; only a trailing partial message is copied
/// into an internal buffer, which therefore never exceeds `4 + maxMessageSize` bytes. A length is validated as
/// soon as its 4 bytes arrive, so a hostile peer cannot make the decoder wait for (or buffer) an oversized body.
/// After any error the decoder is dead and rethrows that error: the caller must close the connection, because
/// stream framing cannot be resynchronized.
public struct ControlStreamDecoder {
    private let maxMessageSize: Int
    private var pending: [UInt8] = []
    private var pendingLength = 0          // body length of the buffered message, valid once pending.count >= 4
    private var failure: WireError?

    public init(maxMessageSize: Int = WireConstants.maxControlMessageSize) {
        self.maxMessageSize = max(1, maxMessageSize)
    }

    /// Bytes currently buffered for an incomplete message.
    public var bufferedByteCount: Int { pending.count }

    /// True once a malformed frame has been seen; every later `append` throws.
    public var isFailed: Bool { failure != nil }

    /// Feeds bytes from the stream and returns every message they complete, in order.
    /// Throws on zero/oversized length, unknown type or a malformed payload; messages completed earlier in the
    /// same chunk are discarded with the error since the connection is going away.
    public mutating func append(_ chunk: Data) throws -> [ControlMessage] {
        if let failure { throw failure }
        do {
            return try process(chunk)
        } catch let error as WireError {
            fail(error)
            throw error
        } catch {
            let wrapped = WireError.malformed("\(error)")
            fail(wrapped)
            throw wrapped
        }
    }

    private mutating func fail(_ error: WireError) {
        failure = error
        pending = []
    }

    private mutating func process(_ chunk: Data) throws -> [ControlMessage] {
        var out: [ControlMessage] = []
        var pos = chunk.startIndex
        let end = chunk.endIndex
        let prefix = WireConstants.controlLengthPrefixSize

        while pos < end {
            if pending.isEmpty {
                let available = end - pos
                if available >= prefix {
                    let length = try validatedLength(Self.readU32(chunk, at: pos))
                    if available >= prefix + length {
                        let type = chunk[pos + prefix]
                        let payload = chunk[(pos + prefix + 1)..<(pos + prefix + length)]
                        out.append(try ControlMessage.decode(type: type, payload: payload))
                        pos += prefix + length
                        continue
                    }
                    pendingLength = length
                }
                // Partial message: buffer the tail (bounded by prefix + maxMessageSize).
                pending.append(contentsOf: chunk[pos..<end])
                pos = end
            } else {
                if pending.count < prefix {
                    let take = min(prefix - pending.count, end - pos)
                    pending.append(contentsOf: chunk[pos..<(pos + take)])
                    pos += take
                    if pending.count < prefix { break }
                    let raw = UInt32(pending[0]) << 24 | UInt32(pending[1]) << 16 | UInt32(pending[2]) << 8 | UInt32(pending[3])
                    pendingLength = try validatedLength(raw)
                }
                let need = prefix + pendingLength - pending.count
                let take = min(need, end - pos)
                if take > 0 {
                    pending.append(contentsOf: chunk[pos..<(pos + take)])
                    pos += take
                }
                if pending.count == prefix + pendingLength {
                    let type = pending[prefix]
                    let payload = Data(pending[(prefix + 1)...])
                    pending.removeAll(keepingCapacity: true)
                    out.append(try ControlMessage.decode(type: type, payload: payload))
                }
            }
        }
        return out
    }

    private func validatedLength(_ raw: UInt32) throws -> Int {
        if raw == 0 { throw WireError.malformed("zero-length control frame") }
        if UInt64(raw) > UInt64(maxMessageSize) { throw WireError.oversized }
        return Int(raw)
    }

    @inline(__always)
    private static func readU32(_ d: Data, at i: Data.Index) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}

// MARK: - Helpers

extension ByteWriter {
    @inline(__always)
    mutating func finiteF32(_ value: Float) {
        f32(value.isFinite ? value : 0)
    }
}

extension ByteReader {
    mutating func finiteF32() throws -> Float {
        let v = try f32()
        guard v.isFinite else { throw WireError.malformed("non-finite float") }
        return v
    }

    mutating func enumValue<E: RawRepresentable>(_: E.Type, _ what: String) throws -> E where E.RawValue == UInt8 {
        let raw = try u8()
        guard let value = E(rawValue: raw) else { throw WireError.malformed("invalid \(what) \(raw)") }
        return value
    }

    fileprivate mutating func ping() throws -> Ping {
        Ping(id: try u32(), sentAtNanos: try u64())
    }

    fileprivate mutating func keyEvent() throws -> KeyEvent {
        KeyEvent(seq: try u32(), keyCode: try u16(), modifiers: try u64(), isRepeat: try bool())
    }

    fileprivate mutating func mouseButtonEvent() throws -> MouseButtonEvent {
        MouseButtonEvent(seq: try u32(), button: try enumValue(MouseButton.self, "mouse button"),
                         x: try finiteF32(), y: try finiteF32(), clickCount: try u8(), modifiers: try u64())
    }
}
