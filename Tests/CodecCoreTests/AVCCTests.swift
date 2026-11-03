import Foundation
import Testing
@testable import CodecCore

@Suite("AVCC framing")
struct AVCCTests {
    private let sps = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x01, 0x40])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let idr = Data([0x65, 0x88, 0x84, 0x00, 0x33, 0xFF])
    private let pSlice = Data([0x41, 0x9A, 0x02])

    @Test func parsesValidAccessUnit() throws {
        let data = Data([0, 0, 0, 7] + Array(sps) + [0, 0, 0, 4] + Array(pps) + [0, 0, 0, 6] + Array(idr))
        let nals = try AVCC.nalUnits(in: data)
        #expect(nals == [sps, pps, idr])
        #expect(nals.map(AVCC.nalType) == [7, 8, 5])
        #expect(nals.allSatisfy { $0.startIndex == 0 })
    }

    @Test func lengthPrefixedRoundTrip() throws {
        let original = [sps, pps, idr, pSlice]
        let framed = AVCC.lengthPrefixed(original)
        #expect(framed.count == original.reduce(0) { $0 + 4 + $1.count })
        #expect(Array(framed.prefix(4)) == [0, 0, 0, 7])
        #expect(try AVCC.nalUnits(in: framed) == original)
    }

    @Test func largeNALLengthIsBigEndian() throws {
        let big = Data([0x41] + [UInt8](repeating: 0xAB, count: 70_000))
        let framed = AVCC.lengthPrefixed([big])
        #expect(Array(framed.prefix(4)) == [0x00, 0x01, 0x11, 0x71])  // 70_001
        #expect(try AVCC.nalUnits(in: framed) == [big])
    }

    @Test func handlesDataSliceWithNonZeroStartIndex() throws {
        let framed = Data([0xEE, 0xEE, 0xEE]) + AVCC.lengthPrefixed([pps, pSlice])
        let slice = framed[3...]
        #expect(slice.startIndex == 3)
        #expect(try AVCC.nalUnits(in: slice) == [pps, pSlice])
        #expect(AVCC.containsIDR(slice) == false)
    }

    @Test func rejectsTruncatedLengthPrefix() {
        let data = AVCC.lengthPrefixed([pSlice]) + Data([0, 0])
        #expect(throws: AVCCError.truncatedLength(offset: 7)) { try AVCC.nalUnits(in: data) }
    }

    @Test func rejectsTruncatedPayload() {
        var data = AVCC.lengthPrefixed([idr])
        data.removeLast()
        #expect(throws: AVCCError.truncatedPayload(offset: 0, declared: 6, available: 5)) { try AVCC.nalUnits(in: data) }
    }

    @Test func rejectsZeroLengthNAL() {
        let data = AVCC.lengthPrefixed([pSlice]) + Data([0, 0, 0, 0]) + AVCC.lengthPrefixed([pSlice])
        #expect(throws: AVCCError.zeroLengthNAL(offset: 7)) { try AVCC.nalUnits(in: data) }
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: AVCCError.empty) { try AVCC.nalUnits(in: Data()) }
    }

    @Test func rejectsGarbage() {
        // Annex B start codes are not AVCC: 00 00 00 01 declares a 1-byte NAL, then 0x67.. is read as a huge length.
        let annexB = Data([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F, 0, 0, 0, 1, 0x68])
        #expect(throws: (any Error).self) { try AVCC.nalUnits(in: annexB) }
        let random = Data((0..<257).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) | 0x80 })
        #expect(throws: (any Error).self) { try AVCC.nalUnits(in: random) }
        #expect(throws: (any Error).self) { try AVCC.nalUnits(in: Data([0xFF, 0xFF, 0xFF, 0xFF, 0x65])) }
    }

    @Test func nalTypeMasksForbiddenAndRefBits() {
        #expect(AVCC.nalType(Data([0x65])) == AVCC.NALType.idrSlice)
        #expect(AVCC.nalType(Data([0x25])) == AVCC.NALType.idrSlice)
        #expect(AVCC.nalType(Data([0x41])) == AVCC.NALType.nonIDRSlice)
        #expect(AVCC.nalType(Data([0x06])) == AVCC.NALType.sei)
        #expect(AVCC.nalType(Data([0x09, 0xF0])) == AVCC.NALType.accessUnitDelimiter)
        #expect(AVCC.nalType(Data()) == 0)
        let slice = Data([0x00, 0x67])[1...]
        #expect(AVCC.nalType(slice) == AVCC.NALType.sps)
    }

    @Test func containsIDR() {
        #expect(AVCC.containsIDR(AVCC.lengthPrefixed([sps, pps, idr])))
        #expect(!AVCC.containsIDR(AVCC.lengthPrefixed([pSlice])))
        #expect(!AVCC.containsIDR(Data([0, 0, 0, 9, 0x65])))  // malformed
    }

    @Test func rangeWalkerSupportsShortLengthHeaders() throws {
        let twoByte = Data([0, 3] + Array(pSlice) + [0, 4] + Array(pps))
        var found: [Data] = []
        try twoByte.withUnsafeBytes { raw in
            try AVCC.forEachNAL(in: raw, lengthSize: 2) { found.append(Data(raw[$0])) }
        }
        #expect(found == [pSlice, pps])
    }
}
