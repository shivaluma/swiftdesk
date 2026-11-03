import Foundation
import Testing
@testable import WireProtocol

@Suite("Video header, datagrams, packetizer")
struct DatagramTests {
    static let header = VideoPacketHeader(flags: [.keyframe, .recovery], sessionId: 0x1122_3344, frameId: 0x5566_7788,
                                          packetIndex: 0x0102, packetCount: 0x0F03, payloadLength: 0x0405,
                                          captureTimestampNanos: 0xA1A2_A3A4_A5A6_A7A8, hostPipelineMicros: 0xB1B2_B3B4)

    @Test func headerByteOffsets() {
        var w = ByteWriter()
        Self.header.encode(into: &w)
        let b = Array(w.data)
        #expect(b.count == VideoPacketHeader.size)
        #expect(b.count == 32)
        #expect(b[0] == 0x56)                               // magic 'V'
        #expect(b[1] == 1)                                  // version
        #expect(b[2] == 0x03)                               // flags keyframe|recovery
        #expect(b[3] == 0)                                  // fecGroupSize (0 = no FEC)
        #expect(Array(b[4..<8]) == [0x11, 0x22, 0x33, 0x44])  // sessionId
        #expect(Array(b[8..<12]) == [0x55, 0x66, 0x77, 0x88]) // frameId
        #expect(Array(b[12..<14]) == [0x01, 0x02])          // packetIndex
        #expect(Array(b[14..<16]) == [0x0F, 0x03])          // packetCount
        #expect(Array(b[16..<18]) == [0x04, 0x05])          // payloadLength
        #expect(Array(b[18..<26]) == [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8]) // captureTimestampNanos
        #expect(Array(b[26..<30]) == [0xB1, 0xB2, 0xB3, 0xB4]) // hostPipelineMicros
        #expect(Array(b[30..<32]) == [0, 0])                // reserved
    }

    private func videoDatagram(_ h: VideoPacketHeader, payloadBytes: Int) -> Data {
        var w = ByteWriter()
        h.encode(into: &w)
        w.bytes(Data(repeating: 0x5A, count: payloadBytes))
        return w.data
    }

    private var validHeader: VideoPacketHeader {
        VideoPacketHeader(flags: .keyframe, sessionId: 9, frameId: 3, packetIndex: 1, packetCount: 4,
                          payloadLength: 10, captureTimestampNanos: 123, hostPipelineMicros: 45)
    }

    @Test func parseValidVideo() throws {
        let d = videoDatagram(validHeader, payloadBytes: 10)
        guard case .video(let h, let payload) = try Datagram.parse(d) else { Issue.record(); return }
        #expect(h == validHeader)
        #expect(payload == Data(repeating: 0x5A, count: 10))
        #expect(payload.startIndex == 32)   // zero-copy slice
    }

    @Test func parseFromSliceWithNonZeroStartIndex() throws {
        var backing = Data(repeating: 0xEE, count: 7)
        backing.append(videoDatagram(validHeader, payloadBytes: 10))
        backing.append(Data(repeating: 0xEE, count: 3))
        let slice = backing[7..<(7 + 42)]
        guard case .video(let h, let payload) = try Datagram.parse(slice) else { Issue.record(); return }
        #expect(h == validHeader)
        #expect(payload.count == 10)
        #expect(payload.allSatisfy { $0 == 0x5A })
    }

    @Test func reservedFieldIgnoredOnReceiveAndByte3IsFECGroupSize() throws {
        var d = videoDatagram(validHeader, payloadBytes: 10)
        d[3] = 0x7F
        d[30] = 1
        d[31] = 2
        guard case .video(let h, _) = try Datagram.parse(d) else { Issue.record(); return }
        var expected = validHeader
        expected.fecGroupSize = 0x7F
        #expect(h == expected)
    }

    @Test func parseRejections() {
        #expect(throws: WireError.truncated) { try Datagram.parse(Data()) }
        #expect(throws: WireError.badMagic) { try Datagram.parse(Data([0x00, 1])) }
        #expect(throws: WireError.badMagic) { try Datagram.parse(Data([0x76, 1, 0, 0])) }   // lowercase 'v'
        #expect(throws: WireError.truncated) { try Datagram.parse(Data([0x56])) }

        var badVersion = videoDatagram(validHeader, payloadBytes: 10)
        badVersion[1] = 2
        #expect(throws: WireError.unsupportedVersion(2)) { try Datagram.parse(badVersion) }
        badVersion[1] = 0
        #expect(throws: WireError.unsupportedVersion(0)) { try Datagram.parse(badVersion) }

        // Shorter than the header.
        #expect(throws: WireError.truncated) { try Datagram.parse(videoDatagram(validHeader, payloadBytes: 10).prefix(31)) }

        // payloadLength mismatch: datagram too long / too short.
        #expect(throws: WireError.malformed("payloadLength mismatch")) { try Datagram.parse(videoDatagram(validHeader, payloadBytes: 11)) }
        #expect(throws: WireError.malformed("payloadLength mismatch")) { try Datagram.parse(videoDatagram(validHeader, payloadBytes: 9)) }
        #expect(throws: WireError.malformed("payloadLength mismatch")) { try Datagram.parse(videoDatagram(validHeader, payloadBytes: 0)) }

        var h = validHeader
        h.packetIndex = 4   // == count
        #expect(throws: WireError.malformed("packetIndex >= packetCount")) { try Datagram.parse(videoDatagram(h, payloadBytes: 10)) }
        h.packetIndex = 0xFFFF
        #expect(throws: WireError.malformed("packetIndex >= packetCount")) { try Datagram.parse(videoDatagram(h, payloadBytes: 10)) }

        h = validHeader
        h.packetCount = 0
        h.packetIndex = 0
        #expect(throws: WireError.malformed("packetCount out of range")) { try Datagram.parse(videoDatagram(h, payloadBytes: 10)) }
        h.packetCount = UInt16(WireConstants.maxPacketsPerFrame + 1)
        #expect(throws: WireError.malformed("packetCount out of range")) { try Datagram.parse(videoDatagram(h, payloadBytes: 10)) }
        h.packetCount = UInt16(WireConstants.maxPacketsPerFrame)
        h.packetIndex = UInt16(WireConstants.maxPacketsPerFrame - 1)
        #expect((try? Datagram.parse(videoDatagram(h, payloadBytes: 10))) != nil)

        h = validHeader
        h.payloadLength = 0
        #expect(throws: WireError.malformed("empty fragment")) { try Datagram.parse(videoDatagram(h, payloadBytes: 0)) }
    }

    @Test func pointerDatagram() throws {
        let p = PointerState(seq: 0x0102_0304, x: 0.5, y: 1.0, buttonsMask: 0b011)
        let d = Datagram.encodePointer(p)
        #expect(Array(d) == [0x50, 1, 1, 2, 3, 4, 0x3F, 0x00, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00, 3])
        #expect(try Datagram.parse(d) == .pointer(p))

        #expect(throws: WireError.truncated) { try Datagram.parse(d.prefix(14)) }
        #expect(throws: WireError.malformed("pointer datagram length")) { try Datagram.parse(d + Data([0])) }
        var badVersion = d
        badVersion[1] = 9
        #expect(throws: WireError.unsupportedVersion(9)) { try Datagram.parse(badVersion) }
        var nan = d
        nan.replaceSubrange(6..<10, with: [0x7F, 0xC0, 0, 0])
        #expect(throws: WireError.malformed("non-finite float")) { try Datagram.parse(nan) }
        // encode sanitizes non-finite.
        #expect(try Datagram.parse(Datagram.encodePointer(PointerState(seq: 1, x: .nan, y: -.infinity, buttonsMask: 0)))
                == .pointer(PointerState(seq: 1, x: 0, y: 0, buttonsMask: 0)))
    }

    // MARK: Packetizer

    private func reassembleDirect(_ datagrams: [Data]) throws -> (headers: [VideoPacketHeader], data: Data) {
        var headers: [VideoPacketHeader] = []
        var data = Data()
        for d in datagrams {
            guard case .video(let h, let payload) = try Datagram.parse(d) else { throw WireError.badMagic }
            headers.append(h)
            data.append(payload)
        }
        return (headers, data)
    }

    @Test func packetizerBoundarySizes() throws {
        let p = VideoPacketizer(sessionId: 5)
        let maxPayload = WireConstants.defaultMaxDatagramSize - 32
        #expect(p.maxPayloadSize == maxPayload)
        #expect(maxPayload == 1118)

        for (size, expectedCount) in [(1, 1), (maxPayload - 1, 1), (maxPayload, 1), (maxPayload + 1, 2),
                                      (2 * maxPayload, 2), (2 * maxPayload + 1, 3)] {
            let frame = frameBytes(id: UInt32(size), count: size)
            let datagrams = try p.packetize(frameId: 77, frame: frame, flags: .keyframe,
                                            captureTimestampNanos: 99, hostPipelineMicros: 7)
            #expect(datagrams.count == expectedCount, "size \(size)")
            #expect(p.packetCount(forFrameBytes: size) == expectedCount)
            let (headers, data) = try reassembleDirect(datagrams)
            #expect(data == frame)
            for (i, h) in headers.enumerated() {
                #expect(h.packetIndex == UInt16(i))
                #expect(h.packetCount == UInt16(expectedCount))
                #expect(h.frameId == 77 && h.sessionId == 5 && h.flags == .keyframe)
                #expect(h.captureTimestampNanos == 99 && h.hostPipelineMicros == 7)
                if i < headers.count - 1 { #expect(Int(h.payloadLength) == maxPayload) }
            }
            #expect(datagrams.allSatisfy { $0.count <= WireConstants.defaultMaxDatagramSize })
        }
        // max+1 => last fragment is exactly 1 byte.
        let two = try p.packetize(frameId: 1, frame: Data(count: maxPayload + 1), flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        #expect(two.map(\.count) == [WireConstants.defaultMaxDatagramSize, 33])
    }

    @Test func packetizerOneMegabyteFrame() throws {
        let p = VideoPacketizer(sessionId: 1)
        let frame = frameBytes(id: 1, count: 1 << 20)
        let datagrams = try p.packetize(frameId: 1, frame: frame, flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        #expect(datagrams.count == (1 << 20 + 1117) / 1118)
        #expect(datagrams.count == 938)
        #expect(try reassembleDirect(datagrams).data == frame)
    }

    @Test func packetizerFromSlice() throws {
        let backing = frameBytes(id: 3, count: 5000)
        let slice = backing[1000..<4000]
        let p = VideoPacketizer(sessionId: 1)
        let datagrams = try p.packetize(frameId: 2, frame: slice, flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        #expect(try reassembleDirect(datagrams).data == Data(slice))
    }

    @Test func packetizerRejections() throws {
        let p = VideoPacketizer(sessionId: 1)
        #expect(throws: WireError.malformed("empty frame")) {
            try p.packetize(frameId: 1, frame: Data(), flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        }
        #expect(throws: WireError.oversized) {
            try p.packetize(frameId: 1, frame: Data(count: WireConstants.maxFrameBytes + 1), flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        }
        // Exactly maxFrameBytes is fine at the default datagram size (3752 packets <= 4096).
        let maxFrame = try p.packetize(frameId: 1, frame: Data(count: WireConstants.maxFrameBytes), flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        #expect(maxFrame.count == 3752)

        // Too many packets: 1-byte payloads.
        let tiny = VideoPacketizer(sessionId: 1, maxDatagramSize: 33)
        #expect(tiny.maxPayloadSize == 1)
        #expect(try tiny.packetize(frameId: 1, frame: Data(count: 4096), flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0).count == 4096)
        #expect(throws: WireError.oversized) {
            try tiny.packetize(frameId: 1, frame: Data(count: 4097), flags: [], captureTimestampNanos: 0, hostPipelineMicros: 0)
        }
    }

    @Test func packetizerClampsDatagramSize() {
        #expect(VideoPacketizer(sessionId: 1, maxDatagramSize: 0).maxDatagramSize == 33)
        #expect(VideoPacketizer(sessionId: 1, maxDatagramSize: -5).maxPayloadSize == 1)
        #expect(VideoPacketizer(sessionId: 1, maxDatagramSize: 1_000_000).maxPayloadSize == Int(UInt16.max))
        #expect(VideoPacketizer(sessionId: 1, maxDatagramSize: 1200).maxPayloadSize == 1168)
    }
}
