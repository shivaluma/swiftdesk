import Foundation
import Testing
import WireProtocol
@testable import TransportCore

@Suite("TransportPreamble")
struct TransportPreambleTests {
    @Test func encodesEightBytes() {
        #expect(Array(TransportPreamble.encode(role: .viewer)) == [0x53, 0x44, 0x51, 0x31, 1, 1, 0, 0])
        #expect(Array(TransportPreamble.encode(role: .host)) == [0x53, 0x44, 0x51, 0x31, 1, 2, 0, 0])
    }

    @Test func roundTrips() throws {
        try TransportPreamble.validate(TransportPreamble.encode(role: .viewer), expectedRole: .viewer)
        try TransportPreamble.validate(TransportPreamble.encode(role: .host), expectedRole: .host)
    }

    @Test func rejectsWrongRoleMagicVersionAndReserved() {
        #expect(throws: WireError.self) {
            try TransportPreamble.validate(TransportPreamble.encode(role: .host), expectedRole: .viewer)
        }
        #expect(throws: WireError.badMagic) {
            try TransportPreamble.validate(Data([0x16, 0x03, 0x01, 0x00, 1, 1, 0, 0]), expectedRole: .viewer)
        }
        #expect(throws: WireError.unsupportedVersion(9)) {
            try TransportPreamble.validate(Data([0x53, 0x44, 0x51, 0x31, 9, 1, 0, 0]), expectedRole: .viewer)
        }
        #expect(throws: WireError.self) {
            try TransportPreamble.validate(Data([0x53, 0x44, 0x51, 0x31, 1, 1, 0, 1]), expectedRole: .viewer)
        }
        #expect(throws: WireError.truncated) {
            try TransportPreamble.validate(Data([0x53, 0x44]), expectedRole: .viewer)
        }
    }

    @Test func sideStreamKind() throws {
        // 0.1.5: byte 6 is the stream kind; the control preamble is unchanged (still all-zero there).
        #expect(Array(TransportPreamble.encode(role: .viewer, kind: .side)) == [0x53, 0x44, 0x51, 0x31, 1, 1, 1, 0])
        try TransportPreamble.validate(TransportPreamble.encode(role: .viewer, kind: .side), expectedRole: .viewer, kind: .side)
        #expect(throws: WireError.self) {
            // A side preamble can never open the control stream (an older Host rejects it the same way).
            try TransportPreamble.validate(TransportPreamble.encode(role: .viewer, kind: .side), expectedRole: .viewer)
        }
        #expect(TransportPreamble.viewerKind(TransportPreamble.encode(role: .viewer, kind: .side)) == .side)
        #expect(TransportPreamble.viewerKind(TransportPreamble.encode(role: .viewer)) == .control)
        #expect(TransportPreamble.viewerKind(TransportPreamble.encode(role: .host, kind: .side)) == nil)
        #expect(TransportPreamble.viewerKind(Data([0x53, 0x44, 0x51, 0x31, 1, 1, 7, 0])) == nil)
    }

    @Test func aControlFrameIsNeverMistakenForAPreamble() {
        // A peer that skips the preamble and sends a framed message straight away must be rejected.
        let frame = ControlFraming.frame(.ping(Ping(id: 1, sentAtNanos: 2)))
        #expect(throws: WireError.self) {
            try TransportPreamble.validate(frame.prefix(TransportPreamble.size), expectedRole: .viewer)
        }
    }
}
