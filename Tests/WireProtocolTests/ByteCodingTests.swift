import Foundation
import Testing
@testable import WireProtocol

@Suite("ByteWriter / ByteReader")
struct ByteCodingTests {
    @Test func writerIsBigEndian() {
        var w = ByteWriter()
        w.u8(0xAB)
        w.u16(0x0102)
        w.u32(0x0304_0506)
        w.u64(0x0708_090A_0B0C_0D0E)
        w.f32(1.0)            // 0x3F800000
        w.bool(true)
        w.bool(false)
        #expect(Array(w.data) == [0xAB, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
                                  0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
                                  0x3F, 0x80, 0x00, 0x00, 0x01, 0x00])
        #expect(w.count == 21)
    }

    @Test func roundTripAllWidths() throws {
        var w = ByteWriter()
        w.u8(.max); w.u16(.max); w.u32(.max); w.u64(.max)
        w.f32(-0.0); w.f32(.greatestFiniteMagnitude); w.f32(.leastNonzeroMagnitude)
        w.bool(true)
        w.string("héllo")
        w.bytes(Data([9, 8, 7]))
        var r = ByteReader(w.data)
        #expect(try r.u8() == .max)
        #expect(try r.u16() == .max)
        #expect(try r.u32() == .max)
        #expect(try r.u64() == .max)
        #expect(try r.f32().bitPattern == Float(-0.0).bitPattern)
        #expect(try r.f32() == .greatestFiniteMagnitude)
        #expect(try r.f32() == .leastNonzeroMagnitude)
        #expect(try r.bool() == true)
        #expect(try r.string() == "héllo")
        #expect(try r.bytes(count: 3) == Data([9, 8, 7]))
        #expect(r.remaining == 0)
        try r.expectEnd()
    }

    @Test func readerHandlesSliceWithNonZeroStartIndex() throws {
        let backing = Data([0xEE, 0xEE, 0xEE, 0x01, 0x02, 0x00, 0x00, 0x00, 0x2A, 0xFF])
        let slice = backing[3..<9]
        #expect(slice.startIndex == 3)
        var r = ByteReader(slice)
        #expect(r.remaining == 6)
        #expect(try r.u16() == 0x0102)
        #expect(r.offset == 2)
        #expect(try r.u32() == 42)
        #expect(r.remaining == 0)
        #expect(throws: WireError.truncated) { try r.u8() }   // must not read the 0xFF past the slice end
    }

    @Test func truncatedReadsThrowAndDoNotAdvance() {
        var r = ByteReader(Data([1, 2, 3]))
        #expect(throws: WireError.truncated) { try r.u32() }
        #expect(r.remaining == 3)
        #expect(throws: WireError.truncated) { try r.u64() }
        #expect(throws: WireError.truncated) { try r.bytes(count: 4) }
        #expect(throws: WireError.malformed("negative length")) { try r.bytes(count: -1) }
        #expect(r.remaining == 3)
        var empty = ByteReader(Data())
        #expect(throws: WireError.truncated) { try empty.u8() }
        #expect(throws: WireError.truncated) { try empty.string() }
    }

    @Test func boolIsStrict() {
        var r = ByteReader(Data([2]))
        #expect(throws: WireError.malformed("invalid bool")) { try r.bool() }
    }

    @Test func bytesIsZeroBasedAndSliceSharesIndices() throws {
        let backing = Data([0, 0, 10, 11, 12, 13])
        var r = ByteReader(backing[2...])
        let copy = try r.bytes(count: 2)
        #expect(copy.startIndex == 0)
        #expect(copy[0] == 10)
        let s = try r.slice(count: 2)
        #expect(s.startIndex == 4)
        #expect(Array(s) == [12, 13])
    }

    @Test func expectEndRejectsTrailing() {
        let r = ByteReader(Data([1]))
        #expect(throws: WireError.malformed("trailing bytes")) { try r.expectEnd() }
    }

    @Test func stringTruncatesOnScalarBoundary() throws {
        // ASCII: hard cut at 256.
        try expectTruncated(String(repeating: "a", count: 300), byteCount: 256)
        // 2-byte scalars: 400 bytes -> 256 (128 scalars).
        try expectTruncated(String(repeating: "é", count: 200), byteCount: 256)
        // 3-byte scalars: 300 bytes -> 255 (85 scalars), never split.
        try expectTruncated(String(repeating: "€", count: 100), byteCount: 255)
        // 4-byte scalars: 280 bytes -> 256 (64 scalars).
        try expectTruncated(String(repeating: "😀", count: 70), byteCount: 256)
        // Mixed: 255 ASCII + one 2-byte scalar would be 257 -> the scalar is dropped entirely.
        try expectTruncated(String(repeating: "a", count: 255) + "é", byteCount: 255)
        // Exactly the limit is untouched.
        try expectTruncated(String(repeating: "b", count: 256), byteCount: 256)
    }

    private func expectTruncated(_ s: String, byteCount: Int) throws {
        var w = ByteWriter()
        w.string(s)
        #expect(w.count == 2 + byteCount)
        var r = ByteReader(w.data)
        let decoded = try r.string()
        #expect(decoded.utf8.count == byteCount)
        #expect(s.utf8.starts(with: decoded.utf8))
        try r.expectEnd()
    }

    @Test func stringRejectsOversizedAndInvalidUTF8() {
        var w = ByteWriter()
        w.u16(257)
        w.bytes(Data(repeating: 0x61, count: 257))
        var r = ByteReader(w.data)
        #expect(throws: WireError.oversized) { try r.string() }

        for bad: [UInt8] in [[0xFF], [0xC3], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0x61, 0x80]] {
            var w2 = ByteWriter()
            w2.u16(UInt16(bad.count))
            w2.bytes(Data(bad))
            var r2 = ByteReader(w2.data)
            #expect(throws: WireError.malformed("invalid UTF-8")) { try r2.string() }
        }
    }

    @Test func fixedBytesPadsAndTruncates() {
        var w = ByteWriter()
        w.fixedBytes(Data([1, 2]), count: 4)
        w.fixedBytes(Data([3, 4, 5, 6, 7]), count: 3)
        w.fixedBytes(Data([9, 9, 1, 2])[2...], count: 2)
        #expect(Array(w.data) == [1, 2, 0, 0, 3, 4, 5, 1, 2])
    }
}
