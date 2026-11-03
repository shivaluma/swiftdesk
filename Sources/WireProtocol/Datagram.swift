import Foundation

/// Per-frame codec flags carried in every fragment of a frame.
public struct VideoFlags: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// IDR / sync frame: decodable without any earlier frame, so it ends a loss-recovery episode.
    public static let keyframe = VideoFlags(rawValue: 1)
    /// Sent in response to REQUEST_KEYFRAME.
    public static let recovery = VideoFlags(rawValue: 2)
}

/// Fixed 32-byte header in front of every video fragment datagram.
///
/// Layout (big-endian): magic u8 @0, version u8 @1, flags u8 @2, fecGroupSize u8 @3, sessionId u32 @4,
/// frameId u32 @8, packetIndex u16 @12, packetCount u16 @14, payloadLength u16 @16,
/// captureTimestampNanos u64 @18, hostPipelineMicros u32 @26, reserved u16 @30.
/// Every fragment repeats the frame metadata so any one fragment can open a reassembly slot regardless of
/// arrival order.
///
/// Byte 3 was reserved in the first release (written 0, ignored on receive); it now carries the FEC group size K the
/// Host used for this frame (0 = no parity datagrams follow), see `FECLayout`.
public struct VideoPacketHeader: Sendable, Equatable {
    public static let size = 32

    public var flags: VideoFlags
    public var sessionId: UInt32
    /// Monotonic per session, starts at 1.
    public var frameId: UInt32
    public var packetIndex: UInt16
    /// 1...maxPacketsPerFrame.
    public var packetCount: UInt16
    /// Must equal datagram length − 32.
    public var payloadLength: UInt16
    /// Host clock; not comparable with Viewer timestamps.
    public var captureTimestampNanos: UInt64
    /// Host capture → packetize latency.
    public var hostPipelineMicros: UInt32
    /// FEC group size K of this frame (0 = no parity). Identical in every fragment and parity datagram of a frame.
    public var fecGroupSize: UInt8

    public init(flags: VideoFlags, sessionId: UInt32, frameId: UInt32, packetIndex: UInt16, packetCount: UInt16,
                payloadLength: UInt16, captureTimestampNanos: UInt64, hostPipelineMicros: UInt32,
                fecGroupSize: UInt8 = 0) {
        self.flags = flags
        self.sessionId = sessionId
        self.frameId = frameId
        self.packetIndex = packetIndex
        self.packetCount = packetCount
        self.payloadLength = payloadLength
        self.captureTimestampNanos = captureTimestampNanos
        self.hostPipelineMicros = hostPipelineMicros
        self.fecGroupSize = fecGroupSize
    }

    /// Appends exactly `VideoPacketHeader.size` bytes (the reserved field at 30 written as zero).
    public func encode(into w: inout ByteWriter) {
        w.u8(WireConstants.videoMagic)
        w.u8(WireConstants.datagramVersion)
        w.u8(flags.rawValue)
        w.u8(fecGroupSize)
        w.u32(sessionId)
        w.u32(frameId)
        w.u16(packetIndex)
        w.u16(packetCount)
        w.u16(payloadLength)
        w.u64(captureTimestampNanos)
        w.u32(hostPipelineMicros)
        w.u16(0)
    }

    /// Structural checks that do not depend on the datagram length: count range and index < count.
    var structuralError: WireError? {
        if packetCount == 0 || Int(packetCount) > WireConstants.maxPacketsPerFrame {
            return .malformed("packetCount out of range")
        }
        if packetIndex >= packetCount { return .malformed("packetIndex >= packetCount") }
        if payloadLength == 0 { return .malformed("empty fragment") }
        return nil
    }
}

/// Every unreliable datagram the app exchanges. The first byte (magic) selects the format.
public enum Datagram: Sendable, Equatable {
    /// `payload` is a zero-copy slice of the parsed datagram; its `startIndex` is generally non-zero.
    case video(VideoPacketHeader, payload: Data)
    case pointer(PointerState)
    /// FEC parity for one group of a frame's fragments; `payload` is a zero-copy slice like `video`'s.
    case parity(ParityPacketHeader, payload: Data)

    /// `[0x50][version 1][u32 seq][f32 x][f32 y][u8 buttonsMask]`.
    public static let pointerSize = 15

    /// Validates magic, version, exact lengths, packet count range, `packetIndex < packetCount` and (for pointer
    /// datagrams) finite coordinates. The remaining reserved header field (video @30) is ignored on receive so it
    /// can be assigned later without a version bump; parity datagrams (magic 'F') also check `parityIndex < G`. Zero-length video fragments are rejected (the packetizer never produces them).
    /// Never traps; cost is O(1) and the video payload is not copied.
    public static func parse(_ data: Data) throws -> Datagram {
        var r = ByteReader(data)
        let magic = try r.u8()
        guard magic == WireConstants.videoMagic || magic == WireConstants.pointerMagic
            || magic == WireConstants.parityMagic else { throw WireError.badMagic }
        let version = try r.u8()
        guard version == WireConstants.datagramVersion else { throw WireError.unsupportedVersion(version) }

        if magic == WireConstants.pointerMagic {
            guard data.count >= pointerSize else { throw WireError.truncated }
            guard data.count == pointerSize else { throw WireError.malformed("pointer datagram length") }
            let state = PointerState(seq: try r.u32(), x: try r.finiteF32(), y: try r.finiteF32(), buttonsMask: try r.u8())
            return .pointer(state)
        }

        if magic == WireConstants.parityMagic {
            guard data.count >= ParityPacketHeader.size else { throw WireError.truncated }
            let header = ParityPacketHeader(flags: VideoFlags(rawValue: try r.u8()),
                                            groupSize: try r.u8(),
                                            sessionId: try r.u32(),
                                            frameId: try r.u32(),
                                            parityIndex: try r.u16(),
                                            packetCount: try r.u16(),
                                            payloadLength: try r.u16(),
                                            captureTimestampNanos: try r.u64(),
                                            hostPipelineMicros: try r.u32(),
                                            lengthXor: try r.u16())
            if let error = header.structuralError { throw error }
            guard Int(header.payloadLength) == r.remaining else {
                throw WireError.malformed("payloadLength mismatch")
            }
            return .parity(header, payload: try r.slice(count: r.remaining))
        }

        guard data.count >= VideoPacketHeader.size else { throw WireError.truncated }
        let flags = VideoFlags(rawValue: try r.u8())
        let fecGroupSize = try r.u8()
        let header = VideoPacketHeader(flags: flags,
                                       sessionId: try r.u32(),
                                       frameId: try r.u32(),
                                       packetIndex: try r.u16(),
                                       packetCount: try r.u16(),
                                       payloadLength: try r.u16(),
                                       captureTimestampNanos: try r.u64(),
                                       hostPipelineMicros: try r.u32(),
                                       fecGroupSize: fecGroupSize)
        try r.skip(2)
        if let error = header.structuralError { throw error }
        guard Int(header.payloadLength) == r.remaining else {
            throw WireError.malformed("payloadLength mismatch")
        }
        return .video(header, payload: try r.slice(count: r.remaining))
    }

    public static func encodePointer(_ p: PointerState) -> Data {
        var w = ByteWriter(capacity: pointerSize)
        w.u8(WireConstants.pointerMagic)
        w.u8(WireConstants.datagramVersion)
        w.u32(p.seq)
        w.finiteF32(p.x)
        w.finiteF32(p.y)
        w.u8(p.buttonsMask)
        return w.data
    }
}

/// Splits encoded access units into self-describing datagrams no larger than the transport limit.
///
/// Every fragment except the last carries exactly `maxPayloadSize` bytes; the reassembler relies on this to
/// validate fragment sizes. Output is one `Data` per datagram (each allocated once at its exact size), which is
/// the minimum allocation the datagram send API allows.
public struct VideoPacketizer: Sendable {
    public let sessionId: UInt32
    /// Effective whole-datagram size after clamping to `[header + 1, header + UInt16.max]`.
    public let maxDatagramSize: Int

    public init(sessionId: UInt32, maxDatagramSize: Int = WireConstants.defaultMaxDatagramSize) {
        self.sessionId = sessionId
        // Clamp instead of trapping: a transport that reports a tiny or bogus limit must not crash the Host.
        // payloadLength is a u16, which bounds the upper end.
        self.maxDatagramSize = min(max(maxDatagramSize, VideoPacketHeader.size + 1),
                                   VideoPacketHeader.size + Int(UInt16.max))
    }

    /// Payload bytes per fragment.
    public var maxPayloadSize: Int { maxDatagramSize - VideoPacketHeader.size }

    /// Number of datagrams `frameBytes` would produce (0 for an empty frame).
    public func packetCount(forFrameBytes frameBytes: Int) -> Int {
        frameBytes <= 0 ? 0 : (frameBytes + maxPayloadSize - 1) / maxPayloadSize
    }

    /// Number of parity datagrams `packetize` appends for `frameBytes` at group size `fecGroupSize`.
    public func parityCount(forFrameBytes frameBytes: Int, fecGroupSize: Int) -> Int {
        FECLayout.groupCount(packetCount: packetCount(forFrameBytes: frameBytes),
                             groupSize: min(fecGroupSize, FECLayout.maxGroupSize))
    }

    /// Splits one encoded access unit into datagrams. Throws `.oversized` if > maxFrameBytes or > maxPacketsPerFrame.
    /// An empty frame throws `.malformed("empty frame")`: there is nothing to decode, and zero-length fragments
    /// are rejected by `Datagram.parse`.
    ///
    /// With `fecGroupSize` K > 0 (clamped to 255), every fragment carries K and `ceil(n / K)` parity datagrams are
    /// appended after the `n` data fragments (see `FECLayout`), so at no loss the frame completes before any parity
    /// arrives and parity adds bandwidth but no latency.
    public func packetize(frameId: UInt32, frame: Data, flags: VideoFlags, captureTimestampNanos: UInt64,
                          hostPipelineMicros: UInt32, fecGroupSize: Int = 0) throws -> [Data] {
        guard !frame.isEmpty else { throw WireError.malformed("empty frame") }
        guard frame.count <= WireConstants.maxFrameBytes else { throw WireError.oversized }
        let count = packetCount(forFrameBytes: frame.count)
        guard count <= WireConstants.maxPacketsPerFrame else { throw WireError.oversized }

        let k = min(max(fecGroupSize, 0), FECLayout.maxGroupSize)
        let groups = FECLayout.groupCount(packetCount: count, groupSize: k)
        var out: [Data] = []
        out.reserveCapacity(count + groups)
        let chunk = maxPayloadSize
        var header = VideoPacketHeader(flags: flags, sessionId: sessionId, frameId: frameId, packetIndex: 0,
                                       packetCount: UInt16(count), payloadLength: 0,
                                       captureTimestampNanos: captureTimestampNanos,
                                       hostPipelineMicros: hostPipelineMicros, fecGroupSize: UInt8(k))
        var offset = frame.startIndex
        for index in 0..<count {
            let length = min(chunk, frame.endIndex - offset)
            header.packetIndex = UInt16(index)
            header.payloadLength = UInt16(length)
            var w = ByteWriter(capacity: VideoPacketHeader.size + length)
            header.encode(into: &w)
            w.bytes(frame[offset..<(offset + length)])
            out.append(w.data)
            offset += length
        }
        guard groups > 0 else { return out }

        let lastLength = frame.count - (count - 1) * chunk
        var parity = ParityPacketHeader(flags: flags, groupSize: UInt8(k), sessionId: sessionId, frameId: frameId,
                                        parityIndex: 0, packetCount: UInt16(count), payloadLength: 0,
                                        captureTimestampNanos: captureTimestampNanos,
                                        hostPipelineMicros: hostPipelineMicros, lengthXor: 0)
        frame.withUnsafeBytes { (all: UnsafeRawBufferPointer) in
            for g in 0..<groups {
                let length = FECLayout.isLastOnlyGroup(group: g, packetCount: count, groupCount: groups) ? lastLength : chunk
                var lengthXor: UInt16 = 0
                var datagram = Data(count: ParityPacketHeader.size + length)   // zero-filled: the padding
                datagram.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    let body = UnsafeMutableRawBufferPointer(rebasing: raw[ParityPacketHeader.size...])
                    var index = g
                    while index < count {
                        let start = index * chunk
                        let memberLength = index == count - 1 ? lastLength : chunk
                        lengthXor ^= UInt16(memberLength)
                        FECLayout.xor(into: body, UnsafeRawBufferPointer(rebasing: all[start..<(start + memberLength)]))
                        index += groups
                    }
                }
                parity.parityIndex = UInt16(g)
                parity.payloadLength = UInt16(length)
                parity.lengthXor = lengthXor
                var w = ByteWriter(capacity: ParityPacketHeader.size)
                parity.encode(into: &w)
                datagram.replaceSubrange(0..<ParityPacketHeader.size, with: w.data)
                out.append(datagram)
            }
        }
        return out
    }
}
