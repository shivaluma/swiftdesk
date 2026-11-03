import WireProtocol

/// One Viewer→Host input message, tagged with the delivery class it needs.
///
/// Key and button transitions must never be lost or reordered (a lost key-up is a stuck key), so they travel on the
/// reliable control stream. Pointer positions are latest-state: a newer one supersedes any older one, so they go as
/// unreliable datagrams and never build a backlog behind lost packets.
public enum OutgoingInput: Sendable, Equatable {
    case reliable(ControlMessage)
    case pointer(PointerState)
}
