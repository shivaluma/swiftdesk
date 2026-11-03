import Foundation

// MARK: - Layout

/// Forward error correction layout: XOR parity over interleaved groups of a frame's data fragments.
///
/// A frame of `n` data fragments protected with group size `K` (1...255) gets `G = ceil(n / K)` parity datagrams.
/// Data fragment `i` belongs to group `i % G`, so each group holds at most `K` fragments and a burst of consecutive
/// losses is spread over different groups. Parity `g` is the XOR of its members, each zero-padded to the longest
/// member; it also carries the XOR of the members' true lengths, so a lost short (last) fragment is rebuilt with
/// its exact length. Any single loss per group is recoverable; two losses in one group are not (the frame is lost
/// and the normal keyframe recovery runs).
///
/// The parity datagram is a separate datagram kind (magic `'F'`), so a receiver that predates FEC drops it in
/// `Datagram.parse` (`badMagic`) and is otherwise unaffected. Data fragments carry `K` in header byte 3, which
/// such receivers ignore (it was reserved and documented as ignored on receive).
public enum FECLayout {
    /// Largest group size the one-byte header field can carry.
    public static let maxGroupSize = 255

    /// Number of parity datagrams (= groups) for `packetCount` data fragments; 0 when `groupSize` is 0 (FEC off).
    public static func groupCount(packetCount: Int, groupSize: Int) -> Int {
        guard packetCount > 0, groupSize > 0 else { return 0 }
        return (packetCount + groupSize - 1) / groupSize
    }

    /// Group of data fragment `index`.
    @inline(__always)
    public static func group(ofIndex index: Int, groupCount: Int) -> Int { index % groupCount }

    /// Number of data fragments in group `group`.
    public static func memberCount(group: Int, packetCount: Int, groupCount: Int) -> Int {
        guard group < packetCount else { return 0 }
        return (packetCount - group + groupCount - 1) / groupCount
    }

    /// Whether group `group` contains only the frame's last fragment, so its parity is as long as that (possibly
    /// short) fragment rather than a full fragment.
    public static func isLastOnlyGroup(group: Int, packetCount: Int, groupCount: Int) -> Bool {
        memberCount(group: group, packetCount: packetCount, groupCount: groupCount) == 1
            && group == (packetCount - 1) % groupCount
    }

    /// XORs `src` into the first `src.count` bytes of `dst` (requires `src.count <= dst.count`), 8 bytes at a time.
    static func xor(into dst: UnsafeMutableRawBufferPointer, _ src: UnsafeRawBufferPointer) {
        let count = min(src.count, dst.count)
        guard count > 0, let d = dst.baseAddress, let s = src.baseAddress else { return }
        var offset = 0
        while offset + 8 <= count {
            let value = d.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                ^ s.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            d.storeBytes(of: value, toByteOffset: offset, as: UInt64.self)
            offset += 8
        }
        while offset < count {
            let value = d.load(fromByteOffset: offset, as: UInt8.self) ^ s.load(fromByteOffset: offset, as: UInt8.self)
            d.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
            offset += 1
        }
    }
}

// MARK: - Parity header

/// Fixed 32-byte header in front of every parity datagram. Same frame metadata as `VideoPacketHeader`, so a parity
/// datagram can open a reassembly slot on its own and is checked against the frame's other datagrams.
///
/// Layout (big-endian): magic u8 `0x46` ('F') @0, version u8 @1, flags u8 @2 (the frame's `VideoFlags`),
/// groupSize u8 @3 (K, 1...255), sessionId u32 @4, frameId u32 @8, parityIndex u16 @12 (group, `< G`),
/// packetCount u16 @14 (data fragments of the frame), payloadLength u16 @16 (parity bytes = longest member),
/// captureTimestampNanos u64 @18, hostPipelineMicros u32 @26, lengthXor u16 @30 (XOR of the members' lengths).
public struct ParityPacketHeader: Sendable, Equatable {
    public static let size = 32

    public var flags: VideoFlags
    /// K: the data fragments per group the Host used for this frame.
    public var groupSize: UInt8
    public var sessionId: UInt32
    public var frameId: UInt32
    /// Group this parity protects, `0..<groupCount`.
    public var parityIndex: UInt16
    /// Data fragments of the frame (same value as in its `VideoPacketHeader`s).
    public var packetCount: UInt16
    /// Must equal datagram length − 32.
    public var payloadLength: UInt16
    public var captureTimestampNanos: UInt64
    public var hostPipelineMicros: UInt32
    /// XOR of the true payload lengths of the group's data fragments.
    public var lengthXor: UInt16

    public init(flags: VideoFlags, groupSize: UInt8, sessionId: UInt32, frameId: UInt32, parityIndex: UInt16,
                packetCount: UInt16, payloadLength: UInt16, captureTimestampNanos: UInt64, hostPipelineMicros: UInt32,
                lengthXor: UInt16) {
        self.flags = flags
        self.groupSize = groupSize
        self.sessionId = sessionId
        self.frameId = frameId
        self.parityIndex = parityIndex
        self.packetCount = packetCount
        self.payloadLength = payloadLength
        self.captureTimestampNanos = captureTimestampNanos
        self.hostPipelineMicros = hostPipelineMicros
        self.lengthXor = lengthXor
    }

    /// `ceil(packetCount / groupSize)`.
    public var groupCount: Int { FECLayout.groupCount(packetCount: Int(packetCount), groupSize: Int(groupSize)) }

    /// Appends exactly `ParityPacketHeader.size` bytes.
    public func encode(into w: inout ByteWriter) {
        w.u8(WireConstants.parityMagic)
        w.u8(WireConstants.datagramVersion)
        w.u8(flags.rawValue)
        w.u8(groupSize)
        w.u32(sessionId)
        w.u32(frameId)
        w.u16(parityIndex)
        w.u16(packetCount)
        w.u16(payloadLength)
        w.u64(captureTimestampNanos)
        w.u32(hostPipelineMicros)
        w.u16(lengthXor)
    }

    /// Structural checks that do not depend on the datagram length.
    var structuralError: WireError? {
        if packetCount == 0 || Int(packetCount) > WireConstants.maxPacketsPerFrame {
            return .malformed("packetCount out of range")
        }
        if groupSize == 0 { return .malformed("parity groupSize 0") }
        if Int(parityIndex) >= groupCount { return .malformed("parityIndex >= groupCount") }
        if payloadLength == 0 { return .malformed("empty parity") }
        return nil
    }
}

// MARK: - Adaptive policy (Host side)

/// Chooses the FEC group size K from the loss the Viewer reports (STATS, ~1 Hz).
///
/// More loss → smaller K (more parity). Protection is raised on the first report that asks for it and relaxed only
/// after `relaxAfterReports` consecutive reports agree, so a quiet second between bursts does not strip it.
/// Pure value type: the Host keeps it next to its packetizer and calls `update` from the STATS handler.
public struct FECPolicy: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// false: never send parity.
        public var enabled = true
        /// Non-nil: always use this K (1...255) and ignore loss reports.
        public var fixedGroupSize: Int?
        /// `(maxLossPercent, K)` rows in increasing loss order: the first row whose bound is above the smoothed
        /// loss wins; above the last bound the last row's K is used. K = 0 sends no parity at that loss level.
        public var ladder: [Rung] = Self.defaultLadder
        /// K before the first loss report arrives.
        public var initialGroupSize = 6
        /// Weight of a new report in the smoothed loss (exponential moving average).
        public var smoothing = 0.5
        public var relaxAfterReports = 3

        public struct Rung: Sendable, Equatable {
            public var maxLossPercent: Double
            public var groupSize: Int
            public init(maxLossPercent: Double, groupSize: Int) {
                self.maxLossPercent = maxLossPercent
                self.groupSize = groupSize
            }
        }

        /// Chosen from a fixed-K sweep with PipelineBench (docs/bench/README.md, FEC section) at 720p60 / 3000 kbps /
        /// 1150 B datagrams: at 1 % loss K = 3/4/6 decoded 57.0/56.9/55.6 fps (mean of 3 seeds) for +44/+27/+18 %
        /// datagrams; at 3 % loss K = 3/4 decoded 53.0/46.8 fps. K = 10 keeps some protection against isolated
        /// losses for about +10–17 % datagrams (P-frames here are ~6 datagrams, so they get one parity).
        public static let defaultLadder: [Rung] = [
            Rung(maxLossPercent: 0.3, groupSize: 10),
            Rung(maxLossPercent: 0.8, groupSize: 6),
            Rung(maxLossPercent: 2.0, groupSize: 4),
            Rung(maxLossPercent: .infinity, groupSize: 3),
        ]

        public init() {}

        public static let off: Configuration = {
            var c = Configuration()
            c.enabled = false
            return c
        }()

        public static func fixed(_ groupSize: Int) -> Configuration {
            var c = Configuration()
            c.fixedGroupSize = groupSize
            return c
        }
    }

    public let configuration: Configuration
    /// K to use for the next frame; 0 = no parity.
    public private(set) var groupSize: Int
    public private(set) var smoothedLossPercent: Double?
    private var relaxStreak = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        if !configuration.enabled {
            groupSize = 0
        } else if let fixed = configuration.fixedGroupSize {
            groupSize = Self.clamp(fixed)
        } else {
            groupSize = Self.clamp(configuration.initialGroupSize)
        }
    }

    /// Feeds one loss report (percent of datagrams, 0...100; nil = no data this window). Returns the new K.
    @discardableResult
    public mutating func update(lossPercent: Double?) -> Int {
        guard configuration.enabled, configuration.fixedGroupSize == nil,
              let loss = lossPercent, loss.isFinite else { return groupSize }
        let sample = min(100, max(0, loss))
        let alpha = min(1, max(0, configuration.smoothing))
        let smoothed = smoothedLossPercent.map { $0 + alpha * (sample - $0) } ?? sample
        smoothedLossPercent = smoothed
        let target = Self.target(for: max(smoothed, sample), ladder: configuration.ladder)
        if protection(of: target) >= protection(of: groupSize) {
            // More (or equal) protection: apply now. Rate the raw sample too, so a sudden burst reacts at once.
            relaxStreak = 0
            groupSize = target
        } else {
            let relaxed = Self.target(for: smoothed, ladder: configuration.ladder)
            relaxStreak += 1
            if relaxStreak >= max(1, configuration.relaxAfterReports) {
                relaxStreak = 0
                groupSize = relaxed
            }
        }
        return groupSize
    }

    /// Parity overhead ordering: K = 0 is the least protection, then larger K is less protection.
    private func protection(of k: Int) -> Int { k == 0 ? 0 : 1_000 - k }

    static func target(for loss: Double, ladder: [Configuration.Rung]) -> Int {
        guard let last = ladder.last else { return 0 }
        for rung in ladder where loss < rung.maxLossPercent { return clamp(rung.groupSize) }
        return clamp(last.groupSize)
    }

    static func clamp(_ k: Int) -> Int { min(FECLayout.maxGroupSize, max(0, k)) }
}

// MARK: - Loss estimate (Viewer side)

extension FrameReassembler.Stats {
    /// Datagrams received and estimated lost between `earlier` and `self` (two snapshots of the same reassembler).
    ///
    /// Lost = data fragments rebuilt from parity (each is exactly one lost datagram) + frames that never completed
    /// × the average datagrams per completed frame. Lost parity datagrams are not visible and not counted.
    public func lossEstimate(since earlier: FrameReassembler.Stats) -> (received: UInt64, lost: UInt64) {
        let data = packetsReceived &- earlier.packetsReceived
        let parity = parityReceived &- earlier.parityReceived
        let completed = framesCompleted &- earlier.framesCompleted
        let framesLost = framesLost &- earlier.framesLost
        let recovered = fragmentsRecovered &- earlier.fragmentsRecovered
        let received = data &+ parity
        let perFrame = completed > 0 ? max(1, Double(received &+ recovered) / Double(completed)) : 1
        let lost = recovered &+ UInt64((Double(framesLost) * perFrame).rounded())
        return (received, lost)
    }
}
