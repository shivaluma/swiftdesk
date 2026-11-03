import Foundation
import Testing
@testable import WireProtocol

@Suite("ControlMessage encode/decode")
struct ControlMessageTests {
    @Test func samplesCoverEveryType() {
        let covered = Set(sampleMessages.map(\.type.rawValue))
        #expect(covered == Set(ControlMessageType.allCases.map(\.rawValue)))
    }

    @Test(arguments: sampleMessages)
    func roundTrip(_ message: ControlMessage) throws {
        let decoded = try ControlMessage.decode(type: message.type.rawValue, payload: message.encodePayload())
        #expect(decoded == message)
    }

    @Test(arguments: sampleMessages)
    func roundTripFromSlice(_ message: ControlMessage) throws {
        var backing = Data([0xFF, 0xFF, 0xFF])
        backing.append(message.encodePayload())
        let decoded = try ControlMessage.decode(type: message.type.rawValue, payload: backing[3...])
        #expect(decoded == message)
    }

    @Test func fixedPayloadSizes() {
        let expected: [ControlMessageType: Int] = [
            .auth: 80, .config: 18, .ping: 12, .pong: 12, .keyDown: 15, .keyUp: 15, .mouseDown: 22, .mouseUp: 22,
            .mouseMove: 13, .scroll: 15, .requestKeyframe: 1, .disconnect: 1, .stats: 32,
            .passwordChallenge: 52, .passwordResponse: 33, .clipboardState: 1, .cursorShape: 5,
        ]
        for m in sampleMessages {
            if let size = expected[m.type] { #expect(m.encodePayload().count == size, "\(m.type)") }
        }
    }

    @Test func exactBytesForKeyDown() {
        let m = ControlMessage.keyDown(KeyEvent(seq: 0x01020304, keyCode: 0x0506, modifiers: 0x0708_090A_0B0C_0D0E, isRepeat: true))
        #expect(Array(ControlFraming.frame(m)) == [0, 0, 0, 16, 8,
                                                   1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 1])
    }

    @Test func framingLengthPrefix() {
        for m in sampleMessages {
            let framed = ControlFraming.frame(m)
            var r = ByteReader(framed)
            let length = try? r.u32()
            #expect(length == UInt32(framed.count - 4))
            #expect(framed[4] == m.type.rawValue)
            #expect(framed.dropFirst(5) == m.encodePayload())
        }
    }

    @Test(arguments: [UInt8(0), 23, 99, 255])
    func unknownType(_ type: UInt8) {
        #expect(throws: WireError.unknownType(type)) { try ControlMessage.decode(type: type, payload: Data()) }
    }

    @Test(arguments: sampleMessages)
    func everyTruncationIsRejected(_ message: ControlMessage) {
        let payload = message.encodePayload()
        for cut in 0..<payload.count {
            #expect(throws: WireError.truncated) {
                try ControlMessage.decode(type: message.type.rawValue, payload: payload.prefix(cut))
            }
        }
    }

    @Test(arguments: sampleMessages)
    func trailingBytesRejected(_ message: ControlMessage) {
        var payload = message.encodePayload()
        payload.append(0)
        #expect(throws: WireError.malformed("trailing bytes")) {
            try ControlMessage.decode(type: message.type.rawValue, payload: payload)
        }
    }

    @Test func badEnumValuesRejected() throws {
        // DenyReason valid range 1...8.
        for raw: UInt8 in [0, 9, 255] {
            #expect(throws: WireError.self) { try ControlMessage.decode(type: 4, payload: Data([raw, 0, 0])) }
        }
        // DisconnectReason valid range 1...6.
        for raw: UInt8 in [0, 7, 200] {
            #expect(throws: WireError.self) { try ControlMessage.decode(type: 15, payload: Data([raw])) }
        }
        // MouseButton valid range 0...2.
        var payload = ControlMessage.mouseDown(MouseButtonEvent(seq: 1, button: .left, x: 0, y: 0, clickCount: 1, modifiers: 0)).encodePayload()
        payload[4] = 3
        #expect(throws: WireError.malformed("invalid mouse button 3")) { try ControlMessage.decode(type: 10, payload: payload) }
        // Valid boundaries decode.
        #expect(try ControlMessage.decode(type: 4, payload: Data([7, 0, 0])) == .deny(Deny(reason: .timeout, message: "")))
        #expect(try ControlMessage.decode(type: 4, payload: Data([8, 0, 0])) == .deny(Deny(reason: .authFailed, message: "")))
        #expect(try ControlMessage.decode(type: 15, payload: Data([6])) == .disconnect(.appQuit))
    }

    @Test func badBoolRejected() {
        var payload = ControlMessage.keyDown(KeyEvent(seq: 1, keyCode: 2, modifiers: 3, isRepeat: false)).encodePayload()
        payload[payload.count - 1] = 2
        #expect(throws: WireError.malformed("invalid bool")) { try ControlMessage.decode(type: 8, payload: payload) }
    }

    @Test func wrongFixedSizesRejected() throws {
        // AUTH is exactly 32 + 32 + 16.
        #expect(throws: WireError.truncated) { try ControlMessage.decode(type: 2, payload: Data(count: 79)) }
        #expect(throws: WireError.malformed("trailing bytes")) { try ControlMessage.decode(type: 2, payload: Data(count: 81)) }
        #expect(try ControlMessage.decode(type: 2, payload: Data(count: 80)) ==
                .auth(Auth(viewerFingerprint: Data(count: 32), hostFingerprint: Data(count: 32), nonce: Data(count: 16))))

        // ACCEPT with a 15-byte token followed by a valid string: the shifted layout must not parse.
        var w = ByteWriter()
        w.u32(1)
        w.bytes(Data(repeating: 0xAA, count: 15))
        w.string("host")
        #expect(throws: WireError.self) { try ControlMessage.decode(type: 3, payload: w.data) }
    }

    @Test func decodedFixedFieldsAreZeroBased() throws {
        guard case .auth(let a) = try ControlMessage.decode(type: 2, payload: sampleMessages[1].encodePayload()) else {
            Issue.record("not auth"); return
        }
        #expect(a.viewerFingerprint.startIndex == 0 && a.viewerFingerprint.count == 32)
        #expect(a.hostFingerprint.startIndex == 0 && a.hostFingerprint[0] == 255)
        #expect(a.nonce.startIndex == 0 && a.nonce.count == 16)
    }

    @Test func misSizedFixedFieldsAreNormalizedOnEncode() throws {
        let auth = Auth(viewerFingerprint: Data([1, 2, 3]), hostFingerprint: Data(repeating: 9, count: 40), nonce: Data())
        let payload = ControlMessage.auth(auth).encodePayload()
        #expect(payload.count == 80)
        guard case .auth(let decoded) = try ControlMessage.decode(type: 2, payload: payload) else { Issue.record(); return }
        #expect(decoded.viewerFingerprint == Data([1, 2, 3] + [UInt8](repeating: 0, count: 29)))
        #expect(decoded.hostFingerprint == Data(repeating: 9, count: 32))
        #expect(decoded.nonce == Data(count: 16))

        let accept = ControlMessage.accept(Accept(sessionId: 1, sessionToken: Data([7]), hostName: "h"))
        guard case .accept(let a) = try ControlMessage.decode(type: 3, payload: accept.encodePayload()) else { Issue.record(); return }
        #expect(a.sessionToken.count == 16)
    }

    @Test func stringLimitsInMessages() throws {
        // 256 bytes is accepted.
        let ok = ControlMessage.hello(Hello(protocolVersion: 1, deviceName: String(repeating: "x", count: 256), appVersion: ""))
        #expect(try ControlMessage.decode(type: 1, payload: ok.encodePayload()) == ok)

        // A hand-built 257-byte string is rejected.
        var w = ByteWriter()
        w.u16(1)
        w.u16(257)
        w.bytes(Data(repeating: 0x61, count: 257))
        w.u16(0)
        #expect(throws: WireError.oversized) { try ControlMessage.decode(type: 1, payload: w.data) }

        // Encoding a long name truncates instead of producing an undecodable message.
        let long = ControlMessage.deny(Deny(reason: .busy, message: String(repeating: "ü", count: 500)))
        guard case .deny(let d) = try ControlMessage.decode(type: 4, payload: long.encodePayload()) else { Issue.record(); return }
        #expect(d.message.utf8.count == 256)

        // Invalid UTF-8.
        var bad = ByteWriter()
        bad.u8(1)
        bad.u16(2)
        bad.bytes(Data([0xC3, 0x28]))
        #expect(throws: WireError.malformed("invalid UTF-8")) { try ControlMessage.decode(type: 4, payload: bad.data) }
    }

    @Test func nonFiniteFloats() throws {
        // Decode rejects NaN / infinity.
        for bits: UInt32 in [0x7FC0_0000, 0x7F80_0000, 0xFF80_0000] {
            var w = ByteWriter()
            w.u32(1)
            w.u32(bits)
            w.f32(0.5)
            w.u8(0)
            #expect(throws: WireError.malformed("non-finite float")) { try ControlMessage.decode(type: 12, payload: w.data) }
        }
        // Encode never emits them.
        let m = ControlMessage.mouseMove(PointerState(seq: 1, x: .nan, y: .infinity, buttonsMask: 0))
        #expect(try ControlMessage.decode(type: 12, payload: m.encodePayload()) ==
                .mouseMove(PointerState(seq: 1, x: 0, y: 0, buttonsMask: 0)))
    }
}

extension ControlMessage: CustomTestStringConvertible {
    public var testDescription: String { "\(type)" }
}
