import os

/// os_signpost milestones for Instruments (Points of Interest / os_signpost instrument).
///
/// Stage names match PRD §6.8: capture callback, encoder callback, network enqueue,
/// network receive, decoder callback, Metal present. Only ids and sizes are emitted — never content.
public enum PipelineSignpost {
    public static let subsystem = "com.swiftdesk.app"
    public static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    @inline(__always) public static func capture(frame: UInt64) {
        signposter.emitEvent("capture", "frame=\(frame)")
    }
    @inline(__always) public static func encoded(frame: UInt64, bytes: Int, keyframe: Bool) {
        signposter.emitEvent("encoded", "frame=\(frame) bytes=\(bytes) key=\(keyframe)")
    }
    @inline(__always) public static func sent(frame: UInt64, packets: Int) {
        signposter.emitEvent("netSend", "frame=\(frame) packets=\(packets)")
    }
    @inline(__always) public static func received(frame: UInt64, bytes: Int) {
        signposter.emitEvent("netRecv", "frame=\(frame) bytes=\(bytes)")
    }
    @inline(__always) public static func decoded(frame: UInt64) {
        signposter.emitEvent("decoded", "frame=\(frame)")
    }
    @inline(__always) public static func presented(frame: UInt64) {
        signposter.emitEvent("presented", "frame=\(frame)")
    }
    @inline(__always) public static func input(seq: UInt32) {
        signposter.emitEvent("input", "seq=\(seq)")
    }
}

/// Logger for lifecycle/state events only. Never log video, audio, keystrokes or clipboard (PRD goal 8).
public enum Log {
    public static let session = Logger(subsystem: PipelineSignpost.subsystem, category: "session")
    public static let transport = Logger(subsystem: PipelineSignpost.subsystem, category: "transport")
    public static let media = Logger(subsystem: PipelineSignpost.subsystem, category: "media")
    public static let input = Logger(subsystem: PipelineSignpost.subsystem, category: "input")
}
