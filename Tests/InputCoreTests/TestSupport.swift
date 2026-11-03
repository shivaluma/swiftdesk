import CoreGraphics
import Synchronization
import WireProtocol
@testable import InputCore

/// Records posted events instead of creating CGEvents.
final class RecordingPoster: EventPoster, @unchecked Sendable {
    private let storage = Mutex<[PostedEvent]>([])
    let fakeCursor: CGPoint?

    init(cursor: CGPoint? = CGPoint(x: 100, y: 100)) {
        fakeCursor = cursor
    }

    func post(_ event: PostedEvent) { storage.withLock { $0.append(event) } }
    func cursorLocation() -> CGPoint? { fakeCursor }

    var events: [PostedEvent] { storage.withLock { $0 } }
    func clear() { storage.withLock { $0.removeAll() } }
}

/// Synchronous collector for translator output.
struct Collected {
    var items: [OutgoingInput] = []

    var messages: [ControlMessage] {
        items.compactMap { if case .reliable(let m) = $0 { m } else { nil } }
    }
    var pointers: [PointerState] {
        items.compactMap { if case .pointer(let p) = $0 { p } else { nil } }
    }
}

extension OutgoingInput {
    /// Sequence number of whatever message this is.
    var seq: UInt32? {
        switch self {
        case .pointer(let p): p.seq
        case .reliable(let m):
            switch m {
            case .keyDown(let k), .keyUp(let k): k.seq
            case .mouseDown(let b), .mouseUp(let b): b.seq
            case .mouseMove(let p): p.seq
            case .scroll(let s): s.seq
            default: nil
            }
        }
    }
}

enum Flags {
    static let shift = ModifierKeys.shiftFlag
    static let control = ModifierKeys.controlFlag
    static let option = ModifierKeys.optionFlag
    static let command = ModifierKeys.commandFlag
    static let caps = ModifierKeys.alphaShiftFlag
    static let fn = ModifierKeys.functionFlag

    /// AppKit raw value for a CG flag word (same bit layout).
    static func appKit(_ cg: UInt64) -> UInt { UInt(cg) }
}
