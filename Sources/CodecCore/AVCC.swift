import Foundation

/// Errors thrown when an AVCC access unit cannot be parsed.
///
/// Every variant means the frame is unusable: the caller should drop it and rely on keyframe
/// recovery rather than try to salvage partial data (a half-parsed slice decodes to garbage).
public enum AVCCError: Error, Equatable, Sendable {
    /// Fewer than 4 bytes remained where a NAL length prefix was expected.
    case truncatedLength(offset: Int)
    /// A length prefix pointed past the end of the buffer.
    case truncatedPayload(offset: Int, declared: Int, available: Int)
    /// A length prefix of zero (never valid in an AVC sample).
    case zeroLengthNAL(offset: Int)
    /// The access unit contained no NAL units at all.
    case empty
}

/// Pure helpers for the AVCC framing used on the wire: each NAL unit is preceded by a 4-byte
/// big-endian length (no Annex B start codes), and keyframes carry SPS + PPS in-band so a viewer
/// can join or recover from any IDR without a separate configuration message.
public enum AVCC {
    /// Size of the big-endian NAL length prefix used everywhere in SwiftDesk.
    public static let lengthHeaderSize = 4

    /// H.264 `nal_unit_type` values (ITU-T H.264 Table 7-1) that the pipeline cares about.
    public enum NALType {
        public static let nonIDRSlice: UInt8 = 1
        public static let idrSlice: UInt8 = 5
        public static let sei: UInt8 = 6
        public static let sps: UInt8 = 7
        public static let pps: UInt8 = 8
        public static let accessUnitDelimiter: UInt8 = 9
    }

    /// Splits an AVCC access unit into its NAL units (without length prefixes).
    ///
    /// Each returned `Data` is an independent copy with `startIndex == 0`. Handles `Data` slices with
    /// a non-zero `startIndex`. The decoder uses the allocation-free range walker instead; this is the
    /// convenient form for tests and tooling.
    public static func nalUnits(in data: Data) throws -> [Data] {
        var result: [Data] = []
        try data.withUnsafeBytes { raw in
            try forEachNAL(in: raw) { range in
                result.append(Data(raw[range]))
            }
        }
        return result
    }

    /// The `nal_unit_type` (low 5 bits of the first byte), or 0 for an empty buffer.
    @inline(__always)
    public static func nalType(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return first & 0x1F
    }

    /// Joins NAL units into an AVCC access unit with 4-byte big-endian length prefixes.
    public static func lengthPrefixed(_ nals: [Data]) -> Data {
        var total = 0
        for nal in nals { total += lengthHeaderSize + nal.count }
        var out = Data(capacity: total)
        for nal in nals {
            let n = UInt32(truncatingIfNeeded: nal.count)
            let header: [UInt8] = [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            out.append(contentsOf: header)
            out.append(nal)
        }
        return out
    }

    /// True if the access unit contains an IDR slice. Returns false for malformed input.
    public static func containsIDR(_ data: Data) -> Bool {
        var found = false
        data.withUnsafeBytes { raw in
            try? forEachNAL(in: raw) { range in
                if raw[range.lowerBound] & 0x1F == NALType.idrSlice { found = true }
            }
        }
        return found
    }

    /// Walks the NAL units of an AVCC buffer, calling `body` with each payload's byte range
    /// (excluding the length prefix) relative to `buffer`. Allocation-free; validates every prefix
    /// before calling `body` for the unit it describes.
    @inline(__always)
    static func forEachNAL(in buffer: UnsafeRawBufferPointer, lengthSize: Int = lengthHeaderSize,
                           _ body: (Range<Int>) throws -> Void) throws {
        let count = buffer.count
        guard count > 0 else { throw AVCCError.empty }
        var offset = 0
        while offset < count {
            guard count - offset >= lengthSize else { throw AVCCError.truncatedLength(offset: offset) }
            var length = 0
            for i in 0..<lengthSize { length = (length << 8) | Int(buffer[offset + i]) }
            guard length > 0 else { throw AVCCError.zeroLengthNAL(offset: offset) }
            let start = offset + lengthSize
            guard length <= count - start else {
                throw AVCCError.truncatedPayload(offset: offset, declared: length, available: count - start)
            }
            try body(start..<(start + length))
            offset = start + length
        }
    }

    /// Writes `value` as a 4-byte big-endian length at `pointer`.
    @inline(__always)
    static func storeLength(_ value: Int, at pointer: UnsafeMutableRawPointer) {
        pointer.storeBytes(of: UInt32(truncatingIfNeeded: value).bigEndian, as: UInt32.self)
    }
}
