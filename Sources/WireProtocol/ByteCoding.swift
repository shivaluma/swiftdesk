import Foundation

/// Append-only big-endian writer used for every message and datagram the app emits.
///
/// Writes go straight into one growable `Data` buffer sized up front by `capacity`, so encoding a message or a
/// video fragment costs a single allocation and no intermediate arrays.
public struct ByteWriter {
    private var storage: Data

    public init(capacity: Int = 64) {
        storage = Data()
        storage.reserveCapacity(max(0, capacity))
    }

    /// The bytes written so far.
    public var data: Data { storage }

    /// Number of bytes written so far.
    public var count: Int { storage.count }

    public mutating func u8(_ value: UInt8) {
        storage.append(value)
    }

    public mutating func u16(_ value: UInt16) {
        appendRaw(value.bigEndian)
    }

    public mutating func u32(_ value: UInt32) {
        appendRaw(value.bigEndian)
    }

    public mutating func u64(_ value: UInt64) {
        appendRaw(value.bigEndian)
    }

    /// IEEE-754 binary32 bit pattern, big-endian.
    public mutating func f32(_ value: Float) {
        appendRaw(value.bitPattern.bigEndian)
    }

    /// One byte: 1 for true, 0 for false.
    public mutating func bool(_ value: Bool) {
        storage.append(value ? 1 : 0)
    }

    /// Raw bytes with no length prefix (fixed-size fields and payloads).
    public mutating func bytes(_ data: Data) {
        storage.append(data)
    }

    /// Exactly `count` bytes: `data` truncated or zero-padded. Used for fixed-size fields (fingerprints, nonces,
    /// tokens) so a mis-sized value can never shift the rest of the message.
    public mutating func fixedBytes(_ data: Data, count: Int) {
        let n = min(data.count, count)
        if n > 0 { storage.append(data.prefix(n)) }
        if count > n { storage.append(contentsOf: repeatElement(0 as UInt8, count: count - n)) }
    }

    /// `u16` byte length followed by UTF-8, truncated to `WireConstants.maxStringBytes` on a Unicode scalar
    /// boundary so the receiver never sees a string it would reject as too long or as invalid UTF-8.
    public mutating func string(_ s: String) {
        var utf8 = Array(s.utf8)
        let limit = WireConstants.maxStringBytes
        if utf8.count > limit {
            var cut = limit
            // Back up over UTF-8 continuation bytes (0b10xxxxxx) so the cut lands on a scalar boundary.
            while cut > 0 && (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
            utf8.removeSubrange(cut...)
        }
        u16(UInt16(utf8.count))
        storage.append(contentsOf: utf8)
    }

    /// Overwrites 4 bytes at `offset` (used to back-patch length prefixes). `offset` must be within the buffer.
    mutating func patchU32(_ value: UInt32, at offset: Int) {
        precondition(offset >= 0 && offset + 4 <= storage.count, "patch outside written bytes")
        let start = storage.startIndex + offset
        storage[start] = UInt8(truncatingIfNeeded: value >> 24)
        storage[start + 1] = UInt8(truncatingIfNeeded: value >> 16)
        storage[start + 2] = UInt8(truncatingIfNeeded: value >> 8)
        storage[start + 3] = UInt8(truncatingIfNeeded: value)
    }

    @inline(__always)
    private mutating func appendRaw<T: FixedWidthInteger>(_ bigEndianValue: T) {
        withUnsafeBytes(of: bigEndianValue) { raw in
            storage.append(raw.bindMemory(to: UInt8.self))
        }
    }
}

/// Bounds-checked big-endian reader over untrusted bytes.
///
/// Works on `Data` slices with a non-zero `startIndex` (datagrams and stream chunks are frequently slices), and
/// every read checks `remaining` first, throwing `WireError.truncated` instead of trapping on hostile input.
public struct ByteReader {
    private let base: Data
    private var position: Data.Index

    public init(_ data: Data) {
        base = data
        position = data.startIndex
    }

    /// Bytes not yet consumed.
    public var remaining: Int { base.endIndex - position }

    /// Bytes consumed so far.
    public var offset: Int { position - base.startIndex }

    public mutating func u8() throws -> UInt8 {
        try require(1)
        let v = base[position]
        position += 1
        return v
    }

    public mutating func u16() throws -> UInt16 {
        try require(2)
        let p = position
        let v = UInt16(base[p]) << 8 | UInt16(base[p + 1])
        position += 2
        return v
    }

    public mutating func u32() throws -> UInt32 {
        try require(4)
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(base[position + i]) }
        position += 4
        return v
    }

    public mutating func u64() throws -> UInt64 {
        try require(8)
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(base[position + i]) }
        position += 8
        return v
    }

    public mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    /// Strict: only 0 and 1 are accepted, anything else is `.malformed`.
    public mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw WireError.malformed("invalid bool")
        }
    }

    /// Copies `count` bytes into a new zero-based `Data` (safe to subscript from 0).
    public mutating func bytes(count: Int) throws -> Data {
        Data(try slice(count: count))
    }

    /// Returns the next `count` bytes as a slice sharing storage with the input (no copy).
    /// The result's `startIndex` is generally non-zero.
    public mutating func slice(count: Int) throws -> Data {
        guard count >= 0 else { throw WireError.malformed("negative length") }
        try require(count)
        let s = base[position..<(position + count)]
        position += count
        return s
    }

    /// `u16` length + UTF-8. Rejects lengths above `WireConstants.maxStringBytes` (`.oversized`) and invalid
    /// UTF-8 (`.malformed`).
    public mutating func string() throws -> String {
        let length = Int(try u16())
        guard length <= WireConstants.maxStringBytes else { throw WireError.oversized }
        let raw = try slice(count: length)
        guard let s = String(validating: raw, as: UTF8.self) else {
            throw WireError.malformed("invalid UTF-8")
        }
        return s
    }

    /// Skips `count` bytes.
    public mutating func skip(_ count: Int) throws {
        _ = try slice(count: count)
    }

    /// Throws `.malformed("trailing bytes")` unless every byte was consumed.
    public func expectEnd() throws {
        if remaining != 0 { throw WireError.malformed("trailing bytes") }
    }

    @inline(__always)
    private func require(_ n: Int) throws {
        if remaining < n { throw WireError.truncated }
    }
}
