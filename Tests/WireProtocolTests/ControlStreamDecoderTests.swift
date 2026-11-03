import Foundation
import Testing
@testable import WireProtocol

@Suite("ControlStreamDecoder")
struct ControlStreamDecoderTests {
    @Test func wholeStreamInOneChunk() throws {
        var d = ControlStreamDecoder()
        #expect(try d.append(framedSampleStream()) == sampleMessages)
        #expect(d.bufferedByteCount == 0)
    }

    @Test func byteByByte() throws {
        var d = ControlStreamDecoder()
        var out: [ControlMessage] = []
        for byte in framedSampleStream() {
            out += try d.append(Data([byte]))
        }
        #expect(out == sampleMessages)
        #expect(d.bufferedByteCount == 0)
    }

    @Test(arguments: [UInt64(1), 2, 3, 1234, 0xC0FFEE])
    func randomChunking(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        // Repeat the sample stream so chunks span many message boundaries.
        var stream = Data()
        for _ in 0..<5 { stream.append(framedSampleStream()) }
        var d = ControlStreamDecoder()
        var out: [ControlMessage] = []
        var pos = 0
        while pos < stream.count {
            let n = min(Int.random(in: 0...90, using: &rng), stream.count - pos)
            // Pass slices with non-zero startIndex, as Network.framework reads may be.
            out += try d.append(stream[pos..<(pos + n)])
            pos += n
            #expect(d.bufferedByteCount <= 4 + WireConstants.maxControlMessageSize)
        }
        #expect(out == Array(repeating: sampleMessages, count: 5).flatMap { $0 })
    }

    @Test func multipleMessagesPlusPartialPerChunk() throws {
        let a = ControlFraming.frame(sampleMessages[5])
        let b = ControlFraming.frame(sampleMessages[6])
        let c = ControlFraming.frame(sampleMessages[0])
        var chunk1 = a + b
        chunk1.append(c.prefix(3))      // partial length prefix
        var d = ControlStreamDecoder()
        #expect(try d.append(chunk1) == [sampleMessages[5], sampleMessages[6]])
        #expect(d.bufferedByteCount == 3)
        #expect(try d.append(c.dropFirst(3).prefix(4)) == [])
        #expect(d.bufferedByteCount == 7)
        var tail = Data(c.dropFirst(7))
        tail.append(a)
        #expect(try d.append(tail) == [sampleMessages[0], sampleMessages[5]])
        #expect(d.bufferedByteCount == 0)
    }

    @Test func emptyChunkIsNoOp() throws {
        var d = ControlStreamDecoder()
        #expect(try d.append(Data()) == [])
    }

    @Test func zeroLengthKillsStream() {
        var d = ControlStreamDecoder()
        #expect(throws: WireError.malformed("zero-length control frame")) { try d.append(Data([0, 0, 0, 0])) }
        #expect(d.isFailed)
        // Dead: even a valid frame now throws the same error.
        #expect(throws: WireError.malformed("zero-length control frame")) {
            try d.append(ControlFraming.frame(sampleMessages[5]))
        }
    }

    @Test func zeroLengthAcrossChunks() throws {
        var d = ControlStreamDecoder()
        #expect(try d.append(Data([0, 0])) == [])
        #expect(throws: WireError.malformed("zero-length control frame")) { try d.append(Data([0, 0])) }
    }

    @Test func oversizedLengthRejectedAsSoonAsPrefixArrives() throws {
        var d = ControlStreamDecoder()
        let tooBig = UInt32(WireConstants.maxControlMessageSize + 1)
        var w = ByteWriter()
        w.u32(tooBig)
        #expect(throws: WireError.oversized) { try d.append(w.data) }

        var d2 = ControlStreamDecoder()
        #expect(try d2.append(w.data.prefix(2)) == [])
        #expect(throws: WireError.oversized) { try d2.append(w.data.suffix(2)) }

        var d3 = ControlStreamDecoder()
        #expect(throws: WireError.oversized) { try d3.append(Data([0xFF, 0xFF, 0xFF, 0xFF])) }
    }

    @Test func maxLengthAcceptedButBufferStaysBounded() throws {
        // A frame at exactly the limit is legal framing (its payload is not a valid message, though).
        var d = ControlStreamDecoder()
        var w = ByteWriter()
        w.u32(UInt32(WireConstants.maxControlMessageSize))
        w.u8(ControlMessageType.ping.rawValue)
        #expect(try d.append(w.data) == [])
        let filler = Data(count: 1000)
        for _ in 0..<64 {
            if d.bufferedByteCount + filler.count >= 4 + WireConstants.maxControlMessageSize { break }
            #expect(try d.append(filler) == [])
            #expect(d.bufferedByteCount <= 4 + WireConstants.maxControlMessageSize)
        }
        let missing = 4 + WireConstants.maxControlMessageSize - d.bufferedByteCount
        #expect(throws: WireError.malformed("trailing bytes")) { try d.append(Data(count: missing)) }
    }

    @Test func customMaxMessageSize() throws {
        var d = ControlStreamDecoder(maxMessageSize: 13)
        #expect(try d.append(ControlFraming.frame(sampleMessages[5])) == [sampleMessages[5]])   // length 13
        #expect(throws: WireError.oversized) { try d.append(ControlFraming.frame(sampleMessages[0])) }
    }

    @Test func unknownTypeKillsStream() {
        var d = ControlStreamDecoder()
        #expect(throws: WireError.unknownType(77)) { try d.append(rawFrame(type: 77, payload: [1, 2])) }
        #expect(d.isFailed)
    }

    @Test func truncatedPayloadInsideFrame() {
        var d = ControlStreamDecoder()
        // PING needs 12 payload bytes; the frame carries 3.
        #expect(throws: WireError.truncated) { try d.append(rawFrame(type: 6, payload: [0, 0, 1])) }
    }

    @Test func trailingBytesInsideFrame() {
        var d = ControlStreamDecoder()
        #expect(throws: WireError.malformed("trailing bytes")) { try d.append(rawFrame(type: 14, payload: [1, 2])) }
    }

    @Test func badEnumInsideFrame() {
        var d = ControlStreamDecoder()
        #expect(throws: WireError.malformed("invalid disconnect reason 0")) { try d.append(rawFrame(type: 15, payload: [0])) }
    }

    @Test func errorAfterValidMessagesInSameChunk() {
        var d = ControlStreamDecoder()
        var chunk = ControlFraming.frame(sampleMessages[5])
        chunk.append(rawFrame(type: 99, payload: []))
        #expect(throws: WireError.unknownType(99)) { try d.append(chunk) }
    }

    @Test func partialMessagePendingThenError() throws {
        var d = ControlStreamDecoder()
        let bad = rawFrame(type: 6, payload: [1])
        #expect(try d.append(bad.prefix(5)) == [])
        #expect(throws: WireError.truncated) { try d.append(bad.suffix(1)) }
        #expect(d.bufferedByteCount == 0)
    }
}
