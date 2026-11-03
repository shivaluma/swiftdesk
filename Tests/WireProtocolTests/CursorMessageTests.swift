import Foundation
import Testing
@testable import WireProtocol

/// 0.1.6 remote pointer shape on the wire: CURSOR_IMAGE (side stream) and CURSOR_SHAPE (control stream), the limits
/// enforced while decoding, the stream-channel split and the capability bit.
@Suite("Cursor messages")
struct CursorMessageTests {
    private static let png = CursorImage.pngSignature + Data([0, 0, 0, 13]) + Data("IHDR".utf8)

    private func image(id: UInt32 = 1, pixels: (UInt16, UInt16) = (56, 80), points: (Float, Float) = (28, 40),
                       hotSpot: (Float, Float) = (5, 5), png: Data = CursorMessageTests.png) -> CursorImage {
        CursorImage(id: id, pixelWidth: pixels.0, pixelHeight: pixels.1, pointWidth: points.0, pointHeight: points.1,
                    hotSpotX: hotSpot.0, hotSpotY: hotSpot.1, png: png)
    }

    private func decodeImage(_ image: CursorImage) throws -> ControlMessage {
        try ControlMessage.decode(type: 21, payload: ControlMessage.cursorImage(image).encodePayload())
    }

    @Test func typeCodesChannelsAndCapability() {
        #expect(ControlMessageType.cursorImage.rawValue == 21)
        #expect(ControlMessageType.cursorShape.rawValue == 22)
        #expect(ControlMessageType.cursorImage.isSideStream, "a PNG never waits in front of input")
        #expect(!ControlMessageType.cursorShape.isSideStream)
        #expect(PeerCapabilities.cursorShape.rawValue == 8)
        #expect(PeerCapabilities.sideStreamFeatures == [.clipboard, .cursorShape])
        let token = Accept.sessionToken(capabilities: [.clipboard, .cursorShape], random: Data(count: 11))
        #expect(Accept(sessionId: 1, sessionToken: token, hostName: "h").capabilities == [.clipboard, .cursorShape])
        // An older Host's random token announces nothing: the Viewer ignores pointer shapes (none will come).
        #expect(!Accept(sessionId: 1, sessionToken: Data(repeating: 9, count: 16), hostName: "h").capabilities
            .contains(.cursorShape))
    }

    @Test func shapeExactBytes() {
        #expect(Array(ControlFraming.frame(.cursorShape(.image(id: 0x0102_0304)))) == [0, 0, 0, 6, 22, 2, 1, 2, 3, 4])
        #expect(Array(ControlMessage.cursorShape(.unavailable).encodePayload()) == [0, 0, 0, 0, 0])
        #expect(Array(ControlMessage.cursorShape(.hidden).encodePayload()) == [1, 0, 0, 0, 0])
        #expect(Array(ControlMessage.cursorShape(.off).encodePayload()) == [3, 0, 0, 0, 0])
    }

    @Test(arguments: [CursorShape.unavailable, .hidden, .image(id: 1), .image(id: .max), .off])
    func shapeRoundTrips(_ shape: CursorShape) throws {
        #expect(try ControlMessage.decode(type: 22, payload: ControlMessage.cursorShape(shape).encodePayload())
            == .cursorShape(shape))
    }

    @Test func shapeRejectsNonCanonicalForms() {
        #expect(throws: WireError.malformed("cursor image id 0")) {
            try ControlMessage.decode(type: 22, payload: Data([2, 0, 0, 0, 0]))
        }
        #expect(throws: WireError.malformed("cursor id without image")) {
            try ControlMessage.decode(type: 22, payload: Data([1, 0, 0, 0, 7]))
        }
        #expect(throws: WireError.malformed("invalid cursor shape kind 4")) {
            try ControlMessage.decode(type: 22, payload: Data([4, 0, 0, 0, 0]))
        }
    }

    @Test func imageExactHeader() {
        let payload = ControlMessage.cursorImage(image(id: 7, pixels: (2, 4), points: (1, 2), hotSpot: (0, 0.5)))
            .encodePayload()
        #expect(payload.count == CursorImage.headerSize + Self.png.count)
        #expect(Array(payload.prefix(8)) == [0, 0, 0, 7, 0, 2, 0, 4])
        #expect(Array(payload[24..<28]) == [0, 0, 0, UInt8(Self.png.count)])
        #expect(payload.suffix(Self.png.count) == Self.png)
    }

    @Test func imageRoundTripsAtTheLimits() throws {
        var big = Self.png
        big.append(Data(count: CursorImage.maxPNGBytes - big.count))
        let maxed = image(id: .max, pixels: (256, 256), points: (512, 512), hotSpot: (512, 0), png: big)
        #expect(maxed.isWellFormed)
        #expect(try decodeImage(maxed) == .cursorImage(maxed))
        let small = image(id: 1, pixels: (1, 1), points: (0.5, 0.5), hotSpot: (0, 0))
        #expect(try decodeImage(small) == .cursorImage(small))
        #expect(ControlFraming.frame(.cursorImage(maxed)).count <= WireConstants.maxSideStreamMessageSize + 4)
    }

    @Test func imageRejectsOutOfRangeFields() {
        let bad: [CursorImage] = [
            image(id: 0),
            image(pixels: (0, 10)),
            image(pixels: (257, 10)),
            image(points: (0, 10)),
            image(points: (513, 10)),
            image(points: (-1, 10)),
            image(hotSpot: (29, 5)),
            image(hotSpot: (-0.5, 5)),
            image(png: Data("GIF89a".utf8)),
        ]
        for value in bad {
            #expect(!value.isWellFormed, "\(value)")
            #expect(throws: WireError.self) { try decodeImage(value) }
        }
    }

    @Test func oversizedPNGIsRejectedBeforeReading() {
        var w = ByteWriter()
        w.u32(1); w.u16(8); w.u16(8); w.f32(4); w.f32(4); w.f32(0); w.f32(0)
        w.u32(UInt32(CursorImage.maxPNGBytes + 1))
        w.bytes(Self.png)   // far fewer bytes than claimed: rejected on the length alone
        #expect(throws: WireError.oversized) { try ControlMessage.decode(type: 21, payload: w.data) }
        var over = Self.png
        over.append(Data(count: CursorImage.maxPNGBytes + 1 - over.count))
        #expect(!image(png: over).isWellFormed)
    }

    @Test func nonFiniteGeometryIsRejected() {
        var w = ByteWriter()
        w.u32(1); w.u16(8); w.u16(8); w.f32(.nan); w.f32(4); w.f32(0); w.f32(0)
        w.u32(UInt32(Self.png.count)); w.bytes(Self.png)
        #expect(throws: WireError.malformed("non-finite float")) { try ControlMessage.decode(type: 21, payload: w.data) }
    }

    @Test func sideStreamDecoderAcceptsAnImageTheControlDecoderRefuses() throws {
        var big = Self.png
        big.append(Data(count: 100_000))
        let message = ControlMessage.cursorImage(image(png: big))
        var side = ControlStreamDecoder(maxMessageSize: WireConstants.maxSideStreamMessageSize)
        #expect(try side.append(ControlFraming.frame(message)) == [message])
        var control = ControlStreamDecoder()
        #expect(throws: WireError.oversized) { try control.append(ControlFraming.frame(message)) }
    }
}
