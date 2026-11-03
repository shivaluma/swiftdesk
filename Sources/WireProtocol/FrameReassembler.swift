import Foundation

/// One fully reassembled encoded access unit, ready for the decoder.
public struct EncodedFrame: Sendable, Equatable {
    public var frameId: UInt32
    public var flags: VideoFlags
    /// Contiguous, zero-based access unit bytes.
    public var data: Data
    /// Host clock.
    public var captureTimestampNanos: UInt64
    public var hostPipelineMicros: UInt32
    /// Viewer clock: first fragment of this frame ingested.
    public var firstPacketAtNanos: UInt64
    /// Viewer clock: last missing fragment ingested.
    public var completedAtNanos: UInt64

    public init(frameId: UInt32, flags: VideoFlags, data: Data, captureTimestampNanos: UInt64,
                hostPipelineMicros: UInt32, firstPacketAtNanos: UInt64, completedAtNanos: UInt64) {
        self.frameId = frameId
        self.flags = flags
        self.data = data
        self.captureTimestampNanos = captureTimestampNanos
        self.hostPipelineMicros = hostPipelineMicros
        self.firstPacketAtNanos = firstPacketAtNanos
        self.completedAtNanos = completedAtNanos
    }
}

public enum ReassemblyEvent: Sendable, Equatable {
    case frameComplete(EncodedFrame)
    /// Frames that will never be delivered (gap or expiry). Caller must request a keyframe and gate decoding.
    case framesLost(count: Int)
}

/// Rebuilds video frames from unordered, lossy datagrams.
///
/// Latency first: frames are delivered in strictly increasing `frameId` and a newer complete frame always wins
/// over an older incomplete one, because a late frame is worse than a skipped one. Memory is bounded by
/// `maxPendingFrames` reusable slots and `maxPendingBytes` of buffered payload; per-packet work is O(1) with a
/// linear scan over at most `maxPendingFrames` slots only when a packet belongs to a different frame than the
/// previous one.
///
/// Loss accounting: the reassembler keeps a *floor* — the newest frame id that was either delivered or declared
/// lost. Packets at or below the floor are stale. Each id above the floor is reported lost exactly once, either
/// when a newer frame completes (the gap) or when a pending frame is discarded by expiry, eviction or a
/// metadata mismatch (everything up to and including that frame). This is the contract's
/// `N - lastDelivered - 1` rule, extended so ids already reported by an expiry/eviction are not counted twice.
///
/// Fragments are held as zero-copy slices of the received datagrams in per-slot arrays whose capacity is reused
/// across frames; the only per-frame allocation is the contiguous output buffer the decoder needs.
/// Frame ids are assumed not to wrap (2^32 frames is over two years at 60 fps).
///
/// FEC: parity datagrams (`ingestParity`) are buffered in the frame's slot under the same byte budget. When a group
/// is missing exactly one data fragment and its parity is present, the fragment is rebuilt immediately (XOR of the
/// parity and the group's other fragments, zero-padding verified, true length from `lengthXor`) and goes through the
/// same size checks as a received fragment, so a frame is declared lost only when some group lost two or more
/// datagrams (or the frame expired / was overtaken first). Parity for a frame that already completed is counted in
/// `parityStale`, never as an error: at no loss every parity datagram arrives after its frame completed.
///
/// Single-queue use only (not thread-safe): confine an instance to the queue that receives datagrams.
public final class FrameReassembler {
    public struct Config: Sendable {
        public var sessionId: UInt32
        /// A frame whose first fragment is older than this is abandoned by `expire`.
        public var deadlineNanos: UInt64 = 120_000_000
        /// The same deadline for a keyframe (never shorter than `deadlineNanos`). A keyframe is several times the
        /// datagrams of a P-frame — a native 1600×900 / 1080p IDR is ~150–250 datagrams, sent twice plus parity — so
        /// on a congested or lossy link its last fragment (or that fragment's duplicate, a whole copy later) can
        /// arrive well after 120 ms. Expiring it would discard the very frame recovery is waiting for and trigger
        /// another, equally large one. Waiting longer costs nothing in the normal case: the P-frames sent after it
        /// complete within a frame interval of its duplicates and declare it lost by gap if it really is.
        public var keyframeDeadlineNanos: UInt64 = 500_000_000
        public var maxPendingFrames: Int = 8
        public var maxPendingBytes: Int = 8 * 1024 * 1024
        public var maxFrameBytes: Int = WireConstants.maxFrameBytes

        public init(sessionId: UInt32) {
            self.sessionId = sessionId
        }
    }

    public struct Stats: Sendable, Equatable {
        public var packetsReceived: UInt64 = 0
        public var packetsDuplicate: UInt64 = 0
        public var packetsMalformed: UInt64 = 0
        public var packetsStale: UInt64 = 0
        public var packetsWrongSession: UInt64 = 0
        public var framesCompleted: UInt64 = 0
        public var framesLost: UInt64 = 0
        public var pendingFrames: Int = 0
        public var pendingBytes: Int = 0
        /// Parity datagrams handed to `ingestParity` (all of them, like `packetsReceived` for data).
        public var parityReceived: UInt64 = 0
        /// Parity for a frame at or below the floor (already delivered or declared lost). Expected, not an error.
        public var parityStale: UInt64 = 0
        /// Parity that arrived when its group had nothing missing (dropped without buffering) or was a duplicate.
        public var parityUnused: UInt64 = 0
        /// Data fragments rebuilt from parity. Each is exactly one lost data datagram.
        public var fragmentsRecovered: UInt64 = 0
        /// Parity rejected as inconsistent (counted in `packetsMalformed` too).
        public var parityMalformed: UInt64 = 0

        public init() {}
    }

    private final class Slot {
        var active = false
        var frameId: UInt32 = 0
        var flags: VideoFlags = []
        var packetCount = 0
        var captureTimestampNanos: UInt64 = 0
        var hostPipelineMicros: UInt32 = 0
        var firstPacketAtNanos: UInt64 = 0
        /// Indexed by packetIndex; an empty `Data` marks a missing fragment (empty fragments are rejected).
        var fragments: [Data] = []
        var receivedCount = 0
        var bytes = 0
        /// Size every non-last fragment must have; 0 until one is seen.
        var fragmentSize = 0
        /// Size of the last fragment; 0 until it is seen.
        var lastFragmentSize = 0
        /// FEC group size K (0 = no FEC) and group count G for this frame.
        var fecGroupSize = 0
        var groupCount = 0
        /// Indexed by group; an empty `Data` marks parity not (or no longer) held.
        var parity: [Data] = []
        var parityLengthXor: [UInt16] = []
        /// Data fragments still missing per group.
        var groupMissing: [Int] = []
        /// Buffered parity bytes (part of the reassembler's pending bytes, not of the frame).
        var parityBytes = 0

        func open(_ m: FrameMeta, now: UInt64) {
            active = true
            frameId = m.frameId
            flags = m.flags
            packetCount = m.packetCount
            captureTimestampNanos = m.captureTimestampNanos
            hostPipelineMicros = m.hostPipelineMicros
            firstPacketAtNanos = now
            fragments.removeAll(keepingCapacity: true)
            fragments.append(contentsOf: repeatElement(Data(), count: packetCount))
            receivedCount = 0
            bytes = 0
            fragmentSize = 0
            lastFragmentSize = 0
            fecGroupSize = m.fecGroupSize
            groupCount = FECLayout.groupCount(packetCount: packetCount, groupSize: fecGroupSize)
            parity.removeAll(keepingCapacity: true)
            parityLengthXor.removeAll(keepingCapacity: true)
            groupMissing.removeAll(keepingCapacity: true)
            if groupCount > 0 {
                parity.append(contentsOf: repeatElement(Data(), count: groupCount))
                parityLengthXor.append(contentsOf: repeatElement(0, count: groupCount))
                for g in 0..<groupCount {
                    groupMissing.append(FECLayout.memberCount(group: g, packetCount: packetCount, groupCount: groupCount))
                }
            }
            parityBytes = 0
        }

        func matches(_ m: FrameMeta) -> Bool {
            packetCount == m.packetCount && flags == m.flags && captureTimestampNanos == m.captureTimestampNanos
                && fecGroupSize == m.fecGroupSize
        }

        /// Drops the retained datagram slices immediately but keeps the array capacity for reuse.
        func release() {
            active = false
            fragments.removeAll(keepingCapacity: true)
            parity.removeAll(keepingCapacity: true)
            receivedCount = 0
            bytes = 0
            parityBytes = 0
        }

        func assemble() -> Data {
            var out = Data(capacity: bytes)
            for f in fragments { out.append(f) }
            return out
        }
    }

    /// Frame-level metadata repeated in every datagram of a frame (data or parity).
    struct FrameMeta {
        var frameId: UInt32
        var flags: VideoFlags
        var packetCount: Int
        var captureTimestampNanos: UInt64
        var hostPipelineMicros: UInt32
        var fecGroupSize: Int

        init(_ h: VideoPacketHeader) {
            frameId = h.frameId
            flags = h.flags
            packetCount = Int(h.packetCount)
            captureTimestampNanos = h.captureTimestampNanos
            hostPipelineMicros = h.hostPipelineMicros
            fecGroupSize = Int(h.fecGroupSize)
        }

        init(_ h: ParityPacketHeader) {
            frameId = h.frameId
            flags = h.flags
            packetCount = Int(h.packetCount)
            captureTimestampNanos = h.captureTimestampNanos
            hostPipelineMicros = h.hostPipelineMicros
            fecGroupSize = Int(h.groupSize)
        }
    }

    private let config: Config
    private let slots: [Slot]
    private var activeCount = 0
    private var pendingBytes = 0
    private var floor: UInt32 = 0
    private var hasFloor = false
    private var delivered: UInt32 = 0
    private var cachedSlot = 0
    private var counters = Stats()

    public init(config: Config) {
        var c = config
        c.maxPendingFrames = max(1, c.maxPendingFrames)
        c.maxPendingBytes = max(1, c.maxPendingBytes)
        c.maxFrameBytes = max(1, c.maxFrameBytes)
        self.config = c
        slots = (0..<c.maxPendingFrames).map { _ in Slot() }
    }

    public var stats: Stats {
        var s = counters
        s.pendingFrames = activeCount
        s.pendingBytes = pendingBytes
        return s
    }

    /// Id of the newest frame delivered via `.frameComplete`; 0 before the first delivery.
    public var lastDeliveredFrameId: UInt32 { delivered }

    /// Ingests one parsed fragment. Returns events in the order they must be handled (a `framesLost` always
    /// precedes the `frameComplete` that revealed the gap). Returns an empty, non-allocated array for the common
    /// case of a fragment that completes nothing.
    public func ingest(header: VideoPacketHeader, payload: Data, nowNanos: UInt64) -> [ReassemblyEvent] {
        counters.packetsReceived &+= 1
        guard header.sessionId == config.sessionId else {
            counters.packetsWrongSession &+= 1
            return []
        }
        guard header.structuralError == nil, payload.count == Int(header.payloadLength) else {
            counters.packetsMalformed &+= 1
            return []
        }
        if header.frameId <= floor {   // floor starts at 0, and frame ids start at 1, so id 0 is always stale
            counters.packetsStale &+= 1
            return []
        }

        var events: [ReassemblyEvent] = []
        guard let slot = acquireSlot(FrameMeta(header), now: nowNanos, &events) else { return events }

        let index = Int(header.packetIndex)
        if !slot.fragments[index].isEmpty {
            counters.packetsDuplicate &+= 1
            return events
        }
        insert(payload, at: index, into: slot, now: nowNanos, &events)
        return events
    }

    /// Ingests one parsed FEC parity datagram. Same event contract as `ingest`; a parity that completes its group
    /// may complete the frame.
    public func ingestParity(header: ParityPacketHeader, payload: Data, nowNanos: UInt64) -> [ReassemblyEvent] {
        counters.parityReceived &+= 1
        guard header.sessionId == config.sessionId else {
            counters.packetsWrongSession &+= 1
            return []
        }
        guard header.structuralError == nil, payload.count == Int(header.payloadLength) else {
            counters.packetsMalformed &+= 1
            counters.parityMalformed &+= 1
            return []
        }
        let id = header.frameId
        if id <= floor {
            counters.parityStale &+= 1
            return []
        }

        var events: [ReassemblyEvent] = []
        guard let slot = acquireSlot(FrameMeta(header), now: nowNanos, &events) else { return events }

        let group = Int(header.parityIndex)   // < groupCount: checked structurally, and K/count match the slot
        if !slot.parity[group].isEmpty || slot.groupMissing[group] == 0 {
            counters.parityUnused &+= 1
            return events
        }
        let length = payload.count
        if !paritySizeIsConsistent(slot, group: group, length: length) {
            counters.packetsMalformed &+= 1
            counters.parityMalformed &+= 1
            declareLost(through: id, &events)
            return events
        }
        guard reserve(length, for: slot, &events) else { return events }
        slot.parity[group] = payload
        slot.parityLengthXor[group] = header.lengthXor
        slot.parityBytes += length
        pendingBytes += length
        if slot.groupMissing[group] == 1 { recover(group: group, in: slot, now: nowNanos, &events) }
        return events
    }

    /// Convenience for receive loops: routes a parsed video or parity datagram (pointer datagrams yield nothing).
    public func ingest(_ datagram: Datagram, nowNanos: UInt64) -> [ReassemblyEvent] {
        switch datagram {
        case .video(let header, let payload): ingest(header: header, payload: payload, nowNanos: nowNanos)
        case .parity(let header, let payload): ingestParity(header: header, payload: payload, nowNanos: nowNanos)
        case .pointer: []
        }
    }

    /// Abandons frames whose first fragment arrived more than `deadlineNanos` ago (`keyframeDeadlineNanos` for a
    /// keyframe). Call every ~10–20 ms.
    public func expire(nowNanos: UInt64) -> [ReassemblyEvent] {
        var newestExpired: UInt32?
        let keyframeDeadline = max(config.deadlineNanos, config.keyframeDeadlineNanos)
        for slot in slots where slot.active {
            let deadline = slot.flags.contains(.keyframe) ? keyframeDeadline : config.deadlineNanos
            if nowNanos > slot.firstPacketAtNanos && nowNanos - slot.firstPacketAtNanos > deadline {
                newestExpired = max(newestExpired ?? 0, slot.frameId)
            }
        }
        guard let newestExpired else { return [] }
        var events: [ReassemblyEvent] = []
        declareLost(through: newestExpired, &events)
        return events
    }

    /// Drops all pending frames and returns to first-frame behaviour (any start id accepted). Lifetime counters
    /// in `stats` are kept so windowed deltas computed by the caller stay monotonic.
    public func reset() {
        for slot in slots where slot.active { slot.release() }
        activeCount = 0
        pendingBytes = 0
        floor = 0
        hasFloor = false
        delivered = 0
    }

    // MARK: - Internals

    /// Finds or opens the slot for a datagram of frame `m.frameId` (above the floor). Returns nil, with the loss
    /// events already appended, when the datagram's frame is given up instead (metadata mismatch, or older than
    /// every pending frame while all slots are busy).
    private func acquireSlot(_ m: FrameMeta, now: UInt64, _ events: inout [ReassemblyEvent]) -> Slot? {
        let id = m.frameId
        if let index = findSlot(id) {
            let slot = slots[index]
            guard slot.matches(m) else {
                counters.packetsMalformed &+= 1
                declareLost(through: id, &events)
                return nil
            }
            return slot
        }
        if activeCount == slots.count {
            let oldest = slots[lowestActiveSlotIndex()]
            if id < oldest.frameId {
                // The newcomer is older than everything pending: it is the one to give up on.
                declareLost(through: id, &events)
                return nil
            }
            declareLost(through: oldest.frameId, &events)
        }
        let free = freeSlotIndex()
        let slot = slots[free]
        slot.open(m, now: now)
        activeCount += 1
        cachedSlot = free
        return slot
    }

    /// Makes room for `length` more bytes by abandoning older frames. False (with `slot`'s frame declared lost) when
    /// `slot` is itself the oldest frame and still does not fit.
    private func reserve(_ length: Int, for slot: Slot, _ events: inout [ReassemblyEvent]) -> Bool {
        while pendingBytes + length > config.maxPendingBytes {
            let oldest = slots[lowestActiveSlotIndex()]
            if oldest === slot {
                declareLost(through: slot.frameId, &events)
                return false
            }
            declareLost(through: oldest.frameId, &events)
        }
        return true
    }

    /// Stores a received or recovered data fragment (not yet present) and completes or repairs as far as possible.
    private func insert(_ payload: Data, at index: Int, into slot: Slot, now: UInt64, _ events: inout [ReassemblyEvent]) {
        let length = payload.count
        if !fragmentSizeIsConsistent(slot, index: index, length: length) {
            counters.packetsMalformed &+= 1
            declareLost(through: slot.frameId, &events)
            return
        }
        guard reserve(length, for: slot, &events) else { return }

        slot.fragments[index] = payload
        slot.receivedCount += 1
        slot.bytes += length
        pendingBytes += length

        if slot.receivedCount == slot.packetCount {
            complete(slot, now: now, &events)
            return
        }
        guard slot.groupCount > 0 else { return }
        let group = FECLayout.group(ofIndex: index, groupCount: slot.groupCount)
        slot.groupMissing[group] -= 1
        if slot.groupMissing[group] == 0 {
            dropParity(group: group, in: slot)   // nothing left to repair in this group
        } else if slot.groupMissing[group] == 1 && !slot.parity[group].isEmpty {
            recover(group: group, in: slot, now: now, &events)
        }
    }

    /// Rebuilds the single missing data fragment of `group` from its parity and the group's other fragments.
    private func recover(group: Int, in slot: Slot, now: UInt64, _ events: inout [ReassemblyEvent]) {
        let parity = slot.parity[group]
        let parityLength = parity.count
        var lengthXor = slot.parityLengthXor[group]
        var missing = -1
        var memberTooLong = false
        var rebuilt = Data(parity)   // contiguous zero-based copy, XORed in place
        rebuilt.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var index = group
            while index < slot.packetCount {
                let fragment = slot.fragments[index]
                if fragment.isEmpty {
                    missing = index
                } else if fragment.count > parityLength {
                    memberTooLong = true
                } else {
                    lengthXor ^= UInt16(truncatingIfNeeded: fragment.count)
                    fragment.withUnsafeBytes { FECLayout.xor(into: dst, $0) }
                }
                index += slot.groupCount
            }
        }
        dropParity(group: group, in: slot)
        let length = Int(lengthXor)
        // The parity is consistent only if the true length fits and the zero padding beyond it XORs back to zero.
        guard missing >= 0, !memberTooLong, length >= 1, length <= parityLength,
              rebuilt[length..<parityLength].allSatisfy({ $0 == 0 }) else {
            counters.packetsMalformed &+= 1
            counters.parityMalformed &+= 1
            return   // keep waiting: the data fragment itself may still arrive
        }
        counters.fragmentsRecovered &+= 1
        insert(rebuilt.prefix(length), at: missing, into: slot, now: now, &events)
    }

    private func dropParity(group: Int, in slot: Slot) {
        let length = slot.parity[group].count
        guard length > 0 else { return }
        slot.parity[group] = Data()
        slot.parityBytes -= length
        pendingBytes -= length
    }

    /// Parity length = the longest member: a full fragment, unless the group holds only the (short) last fragment.
    private func paritySizeIsConsistent(_ slot: Slot, group: Int, length: Int) -> Bool {
        if length > config.maxFrameBytes { return false }
        if FECLayout.isLastOnlyGroup(group: group, packetCount: slot.packetCount, groupCount: slot.groupCount) {
            if slot.lastFragmentSize != 0 && length != slot.lastFragmentSize { return false }
            if slot.fragmentSize != 0 && length > slot.fragmentSize { return false }
            return true
        }
        if slot.fragmentSize != 0 { return length == slot.fragmentSize }
        return slot.lastFragmentSize <= length
    }

    private func fragmentSizeIsConsistent(_ slot: Slot, index: Int, length: Int) -> Bool {
        if slot.bytes + length > config.maxFrameBytes { return false }
        if index == slot.packetCount - 1 {
            if slot.fragmentSize != 0 && length > slot.fragmentSize { return false }
            slot.lastFragmentSize = length
            return true
        }
        if slot.fragmentSize == 0 {
            if slot.lastFragmentSize > length { return false }
            // Reject early when the declared shape can never fit, instead of buffering up to the limit.
            if (slot.packetCount - 1) * length + max(slot.lastFragmentSize, 1) > config.maxFrameBytes { return false }
            slot.fragmentSize = length
            return true
        }
        return length == slot.fragmentSize
    }

    private func complete(_ slot: Slot, now: UInt64, _ events: inout [ReassemblyEvent]) {
        let id = slot.frameId
        var discarded = 0
        for other in slots where other.active && other !== slot && other.frameId < id {
            discard(other)
            discarded += 1
        }
        let lost: Int
        if hasFloor {
            lost = Int(id - floor - 1)
        } else {
            // First delivery of the session: any start id is fine for a keyframe; a non-keyframe cannot be
            // decoded without its missing predecessors, so report loss to trigger a keyframe request.
            lost = slot.flags.contains(.keyframe) ? 0 : max(1, discarded)
        }
        if lost > 0 {
            counters.framesLost &+= UInt64(lost)
            events.append(.framesLost(count: lost))
        }
        let frame = EncodedFrame(frameId: id, flags: slot.flags, data: slot.assemble(),
                                 captureTimestampNanos: slot.captureTimestampNanos,
                                 hostPipelineMicros: slot.hostPipelineMicros,
                                 firstPacketAtNanos: slot.firstPacketAtNanos, completedAtNanos: now)
        discard(slot)
        floor = id
        hasFloor = true
        delivered = id
        counters.framesCompleted &+= 1
        events.append(.frameComplete(frame))
    }

    /// Gives up on every id in `(floor, through]`, discarding the pending frames in that range.
    private func declareLost(through id: UInt32, _ events: inout [ReassemblyEvent]) {
        var discarded = 0
        for slot in slots where slot.active && slot.frameId <= id {
            discard(slot)
            discarded += 1
        }
        let count = hasFloor ? Int(id - floor) : max(1, discarded)
        floor = id
        hasFloor = true
        counters.framesLost &+= UInt64(count)
        events.append(.framesLost(count: count))
    }

    private func discard(_ slot: Slot) {
        pendingBytes -= slot.bytes + slot.parityBytes
        activeCount -= 1
        slot.release()
    }

    private func findSlot(_ id: UInt32) -> Int? {
        let cached = slots[cachedSlot]
        if cached.active && cached.frameId == id { return cachedSlot }
        for i in slots.indices where slots[i].active && slots[i].frameId == id {
            cachedSlot = i
            return i
        }
        return nil
    }

    private func freeSlotIndex() -> Int {
        for i in slots.indices where !slots[i].active { return i }
        preconditionFailure("no free reassembly slot")   // unreachable: callers evict first
    }

    private func lowestActiveSlotIndex() -> Int {
        var best = -1
        for i in slots.indices where slots[i].active {
            if best < 0 || slots[i].frameId < slots[best].frameId { best = i }
        }
        precondition(best >= 0, "no active reassembly slot")
        return best
    }
}
