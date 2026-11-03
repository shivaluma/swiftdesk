import Foundation
import Testing
@testable import WireProtocol

/// 0.1.5 clipboard sharing on the wire: CLIPBOARD_STATE (control stream) and CLIPBOARD (side stream), the size caps
/// enforced while decoding, the stream-channel split and the capability bit.
@Suite("Clipboard messages")
struct ClipboardMessageTests {
    private static let png = ClipboardContent.pngSignature + Data([0, 0, 0, 13]) + Data("IHDR".utf8)

    private func payload(_ items: [(UInt8, Data)]) -> Data {
        var w = ByteWriter()
        w.u8(UInt8(items.count))
        for (kind, data) in items {
            w.u8(kind)
            w.u32(UInt32(data.count))
            w.bytes(data)
        }
        return w.data
    }

    @Test func typeCodesAndChannels() {
        #expect(ControlMessageType.clipboardState.rawValue == 19)
        #expect(ControlMessageType.clipboard.rawValue == 20)
        #expect(ControlMessageType.clipboard.isSideStream)
        #expect(ControlMessageType.allCases.filter(\.isSideStream) == [.clipboard, .cursorImage],
                "everything else stays on the control stream")
    }

    @Test func capabilityBit() {
        #expect(PeerCapabilities.clipboard.rawValue == 4)
        let token = Accept.sessionToken(capabilities: [.sessionResume, .clipboard], random: Data(count: 11))
        #expect(Accept(sessionId: 1, sessionToken: token, hostName: "h").capabilities == [.sessionResume, .clipboard])
        // An older Host's random token announces nothing: the Viewer never opens the side stream to it.
        #expect(!Accept(sessionId: 1, sessionToken: Data(repeating: 7, count: 16), hostName: "h").capabilities.contains(.clipboard))
    }

    @Test func exactBytes() {
        let content = ClipboardContent(items: [.init(kind: .plainText, data: Data("hi".utf8))])
        #expect(Array(ControlMessage.clipboard(content).encodePayload()) == [1, 1, 0, 0, 0, 2, 0x68, 0x69])
        #expect(Array(ControlFraming.frame(.clipboardState(ClipboardState(enabled: true)))) == [0, 0, 0, 2, 19, 1])
        #expect(Array(ControlMessage.clipboardState(ClipboardState(enabled: false)).encodePayload()) == [0])
    }

    @Test func everyKindRoundTrips() throws {
        let content = ClipboardContent(items: [
            .init(kind: .png, data: Self.png),
            .init(kind: .plainText, data: Data("text".utf8)),
            .init(kind: .richText, data: Data("{\\rtf1 text}".utf8)),
            .init(kind: .url, data: Data("https://swiftdesk.example".utf8)),
        ])
        #expect(content.kinds == [.plainText, .richText, .png, .url], "kept in kind order")
        #expect(content.isWellFormed)
        let decoded = try ControlMessage.decode(type: 20, payload: ControlMessage.clipboard(content).encodePayload())
        #expect(decoded == .clipboard(content))
    }

    @Test func textCapIsOneMebibyte() throws {
        let atLimit = Data(repeating: 0x61, count: ClipboardContent.maxTextBytes)
        let ok = try ControlMessage.decode(type: 20, payload: payload([(1, atLimit)]))
        #expect(ok == .clipboard(ClipboardContent(items: [.init(kind: .plainText, data: atLimit)])))
        let over = Data(repeating: 0x61, count: ClipboardContent.maxTextBytes + 1)
        #expect(throws: WireError.oversized) { try ControlMessage.decode(type: 20, payload: payload([(1, over)])) }
        #expect(throws: WireError.oversized) { try ControlMessage.decode(type: 20, payload: payload([(2, over)])) }
        #expect(!ClipboardContent(items: [.init(kind: .richText, data: over)]).isWellFormed)
    }

    @Test func imageCapIsSixteenMebibytes() throws {
        var image = Self.png
        image.append(Data(count: ClipboardContent.maxImageBytes - image.count))
        let ok = try ControlMessage.decode(type: 20, payload: payload([(3, image)]))
        #expect(ok == .clipboard(ClipboardContent(items: [.init(kind: .png, data: image)])))
        image.append(0)
        #expect(throws: WireError.oversized) { try ControlMessage.decode(type: 20, payload: payload([(3, image)])) }
    }

    @Test func hostileLengthIsRejectedBeforeReading() {
        // Claims 4 GiB with 3 bytes present: rejected on the length alone, nothing is buffered.
        let bytes = Data([1, 3, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3])
        #expect(throws: WireError.oversized) { try ControlMessage.decode(type: 20, payload: bytes) }
    }

    @Test func malformedContentIsRejected() {
        let text = Data("a".utf8)
        let cases: [(String, Data)] = [
            ("no items", Data([0])),
            ("too many items", payload([(1, text), (2, text), (3, Self.png), (4, text), (1, text)])),
            ("duplicate kind", payload([(1, text), (1, text)])),
            ("unknown kind", payload([(9, text)])),
            ("empty item", payload([(1, Data())])),
            ("invalid UTF-8 text", payload([(1, Data([0xFF, 0xFE]))])),
            ("invalid UTF-8 URL", payload([(4, Data([0xC3]))])),
            ("not a PNG", payload([(3, Data("GIF89a".utf8))])),
        ]
        for (name, bytes) in cases {
            #expect(throws: WireError.self, "\(name)") { try ControlMessage.decode(type: 20, payload: bytes) }
        }
    }

    @Test func wellFormedMatchesTheDecoder() {
        #expect(!ClipboardContent(items: []).isWellFormed)
        #expect(!ClipboardContent(items: [.init(kind: .plainText, data: Data("a".utf8)),
                                          .init(kind: .plainText, data: Data("b".utf8))]).isWellFormed)
        #expect(!ClipboardContent(items: [.init(kind: .png, data: Data([1, 2, 3]))]).isWellFormed)
        #expect(ClipboardContent(items: [.init(kind: .png, data: Self.png)]).isWellFormed)
    }

    @Test func stateReservedBitsRejected() {
        for flags: UInt8 in [2, 3, 0x80, 0xFF] {
            #expect(throws: WireError.self) { try ControlMessage.decode(type: 19, payload: Data([flags])) }
        }
    }

    @Test func sideStreamDecoderTakesALargeClipboardInChunks() throws {
        var image = Self.png
        image.append(Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let content = ClipboardContent(items: [.init(kind: .png, data: image),
                                               .init(kind: .plainText, data: Data("caption".utf8))])
        let framed = ControlFraming.frame(.clipboard(content))
        var decoder = ControlStreamDecoder(maxMessageSize: WireConstants.maxSideStreamMessageSize)
        var out: [ControlMessage] = []
        var offset = 0
        while offset < framed.count {
            let end = min(framed.count, offset + 65_536)
            out += try decoder.append(framed[offset..<end])
            offset = end
        }
        #expect(out == [.clipboard(content)])
        #expect(decoder.bufferedByteCount == 0)
        // The control stream's decoder would refuse it outright (64 KiB cap), so it can never stall input there.
        var control = ControlStreamDecoder()
        #expect(throws: WireError.oversized) { try control.append(framed.prefix(8)) }
    }

    @Test func sideStreamLimitCoversTheLargestClipboard() {
        #expect(WireConstants.maxSideStreamMessageSize >= 1 + 1 + 4 * 5 + 3 * ClipboardContent.maxTextBytes + ClipboardContent.maxImageBytes)
        #expect(WireConstants.maxSideStreamMessageSize < 20 << 20)
    }
}
