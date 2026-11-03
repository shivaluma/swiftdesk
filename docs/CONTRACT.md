# SwiftDesk — module interface contract

This file is the single source of truth for cross-module APIs. Modules may add *internal* types freely and may
add extra public API, but must not rename/remove what is listed here without updating this file. PRD: `docs/PRD.md`.

Version labels: the app ships as **0.2.0 (build 5)**, which contains every feature labelled 0.1.4–0.1.9 below; the
previous release is 0.1.3. "0.2.0" marks the review changes made for that release.

## Global rules

- Toolchain: Xcode 27.2 at `/Applications/Xcode.app` (xcode-select points at CLT, so **always**
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). Swift 6.4, Swift 6 language mode,
  deployment target macOS 15. Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- Do not edit `Package.swift` (report needed changes instead). Delete a target's `_Placeholder.swift` once it has real sources.
- Building in parallel: use your own scratch path, e.g.
  `swift build --target CodecCore --scratch-path .build/agent-codec` and
  `swift test --filter CodecCoreTests --scratch-path .build/agent-codec`.
- Only Apple frameworks. No third-party packages, no Rust/FFI, no JSON on hot paths, no JPEG/PNG frames, no screenshot polling.
- Hot path threading: dedicated serial `DispatchQueue`s + `Synchronization.Mutex`/`Atomic` for narrow shared state.
  No actor hops or `Task {}` per frame. SwiftUI state lives on `@MainActor` and is updated ≤ ~4 Hz from metrics.
  Classes shared across queues are `final class X: @unchecked Sendable` with a documented synchronization story.
  Callback properties are `@Sendable` closures. `@preconcurrency import` is allowed for Apple modules that need it.
- Never log/persist video, audio, keystrokes, key codes, or clipboard contents (0.1.5 clipboard sharing logs only
  "sent"/"received"), or pointer images (0.1.6). `DiagnosticsCore.Log` loggers are for lifecycle only.
- Do not invent Apple APIs. Verify against the SDK swiftinterfaces/headers under
  `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`. When an optional
  property (e.g. a VideoToolbox key) is rejected at runtime, fall back and record that it was not applied.
- Timestamps: `DiagnosticsCore.MonotonicClock.nowNanos()` (CLOCK_UPTIME_RAW). Host timestamps are not comparable on the Viewer.

## DiagnosticsCore (done — `Sources/DiagnosticsCore`)

`MonotonicClock`, `PipelineSignpost` (capture/encoded/sent/received/decoded/presented/input), `Log`
(session/transport/media/input), `RateCounter`, `RollingStats` (+`Summary`), `RTTEstimator`, `MetricsSnapshot`. Read the source.

## WireProtocol (pure Swift, `import Foundation` only)

All integers **big-endian**. Floats are IEEE-754 `Float32` bit patterns, big-endian.

```swift
public enum WireConstants {
    public static let protocolVersion: UInt16 = 1
    public static let alpn = "swiftdesk/1"
    public static let defaultPort: UInt16 = 47800
    public static let bonjourServiceType = "_swiftdesk._udp"
    public static let defaultMaxDatagramSize = 1150      // whole datagram incl. header; safe under Tailscale's 1280 MTU
    public static let maxControlMessageSize = 64 * 1024
    public static let maxSideStreamMessageSize   // 0.1.5: 1 + max(ClipboardContent.maxPayloadBytes (≈ 19 MiB), CursorImage.maxPayloadBytes)
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxPacketsPerFrame = 4096
    public static let maxStringBytes = 256
}

public enum WireError: Error, Equatable, Sendable {
    case truncated, badMagic, unsupportedVersion(UInt8), unknownType(UInt8), oversized, malformed(String)
}

public struct ByteWriter {   // append-only big-endian writer
    public init(capacity: Int = 64)
    public mutating func u8(_:) / u16(_:) / u32(_:) / u64(_:) / f32(_:) / bool(_:) / bytes(_ data: Data) / string(_ s: String) // string = u16 len + UTF-8, truncated to maxStringBytes on a scalar boundary
    public var data: Data { get }
}
public struct ByteReader {
    public init(_ data: Data)           // must handle Data slices with non-zero startIndex
    public mutating func u8() throws -> UInt8   // ... u16/u32/u64/f32/bool/bytes(count:)/string()
    public var remaining: Int { get }
}
```

### Control messages (reliable, ordered QUIC stream)

Framing on the stream: `[u32 length][u8 type][payload]` where `length = 1 + payload.count`, `1 ≤ length ≤ maxControlMessageSize`.

```swift
public enum ControlMessageType: UInt8, Sendable {
    case hello = 1, auth = 2, accept = 3, deny = 4, config = 5, ping = 6, pong = 7,
         keyDown = 8, keyUp = 9, mouseDown = 10, mouseUp = 11, mouseMove = 12, scroll = 13,
         requestKeyframe = 14, disconnect = 15, stats = 16,
         passwordChallenge = 17, passwordResponse = 18,     // 0.1.2: opt-in password access, see below
         clipboardState = 19, clipboard = 20,               // 0.1.5: clipboard sharing; 20 = side stream only
         cursorImage = 21, cursorShape = 22                 // 0.1.6: remote pointer shape; 21 = side stream only
    public var isSideStream: Bool { get }                   // true only for .clipboard and .cursorImage
}
public struct Hello: Sendable, Equatable { public var protocolVersion: UInt16; public var deviceName: String; public var appVersion: String }
/// Channel-binding confirmation sent by the Viewer after HELLO: the fingerprints it observed in TLS.
public struct Auth: Sendable, Equatable { public var viewerFingerprint: Data /*32*/; public var hostFingerprint: Data /*32*/; public var nonce: Data /*16*/
    // 0.1.2: capability marker inside the nonce (see "Password access" below); 0.1.4: shared type
    public typealias Capabilities = PeerCapabilities
    public static let capabilityMarker: Data   // "SDC1"
    public static func nonce(capabilities: Capabilities, random: Data) -> Data   // marker ‖ flags ‖ 11 random bytes
    public var capabilities: Capabilities { get }                                 // [] without the marker
}
public struct Accept: Sendable, Equatable { public var sessionId: UInt32; public var sessionToken: Data /*16*/; public var hostName: String
    // 0.1.4: the token carries the Host's capabilities (see "Capability bits" below)
    public static func sessionToken(capabilities: PeerCapabilities, random: Data) -> Data   // marker ‖ flags ‖ 11 random bytes
    public var capabilities: PeerCapabilities { get }                                        // [] without the marker
}
public enum DenyReason: UInt8, Sendable { case userDenied = 1, busy, rateLimited, versionMismatch, identityMismatch, permissionsMissing, timeout,
                                          authFailed /* 8, 0.1.2: wrong access password; only sent to Viewers announcing passwordAuth */ }
public struct Deny: Sendable, Equatable { public var reason: DenyReason; public var message: String }
public struct StreamConfig: Sendable, Equatable {
    public var width: UInt16; public var height: UInt16; public var fps: UInt8; public var bitrateKbps: UInt32
    public var displayPointWidth: Float; public var displayPointHeight: Float   // host display size in points (live:
                                                                                // re-sent when the Host display changes)
    public var codec: UInt8   // 1 = H.264
}
public struct Ping: Sendable, Equatable { public var id: UInt32; public var sentAtNanos: UInt64 }   // PONG echoes the same struct
public struct KeyEvent: Sendable, Equatable { public var seq: UInt32; public var keyCode: UInt16; public var modifiers: UInt64 /*CGEventFlags.rawValue*/; public var isRepeat: Bool }
public enum MouseButton: UInt8, Sendable { case left = 0, right = 1, other = 2 }
/// x/y normalized to the video frame: (0,0) top-left, (1,1) bottom-right.
public struct MouseButtonEvent: Sendable, Equatable { public var seq: UInt32; public var button: MouseButton; public var x: Float; public var y: Float; public var clickCount: UInt8; public var modifiers: UInt64 }
/// Latest pointer state. Sent as MOUSE_MOVE (reliable) or as a pointer datagram (preferred, unreliable). Receiver ignores seq <= last applied.
public struct PointerState: Sendable, Equatable { public var seq: UInt32; public var x: Float; public var y: Float; public var buttonsMask: UInt8 /*bit0 left, bit1 right, bit2 other*/ }
public struct ScrollEvent: Sendable, Equatable { public var seq: UInt32; public var deltaX: Float; public var deltaY: Float; public var isPrecise: Bool /*true: pixels, false: lines*/; public var phase: UInt8; public var momentumPhase: UInt8 }
public enum DisconnectReason: UInt8, Sendable { case userInitiated = 1, hostStopped, timeout, protocolError, permissionRevoked, appQuit }
public struct ViewerStats: Sendable, Equatable {
    public var windowMillis: UInt32; public var packetsReceived: UInt32; public var packetsLost: UInt32 /*estimated*/
    public var framesCompleted: UInt32; public var framesLost: UInt32; public var framesPresented: UInt32
    public var decodeMicrosAvg: UInt32; public var decodeToPresentMicrosAvg: UInt32
}
/// 0.1.2. Host → Viewer. Payload exactly 52 bytes: 16 salt, u32 iterations, 32 nonce.
public struct PasswordChallenge: Sendable, Equatable { public static let saltSize = 16, nonceSize = 32
    public var salt: Data; public var iterations: UInt32; public var nonce: Data }
/// 0.1.2. Viewer → Host. Payload exactly 33 bytes: u8 kind (0 none, 1 proof), 32 proof (all zero for none; a "none"
/// with any non-zero byte is malformed).
public struct PasswordResponse: Sendable, Equatable { public static let proofSize = 32
    public enum Kind: UInt8 { case none = 0, proof = 1 }; public var kind: Kind; public var proof: Data
    public static let none: PasswordResponse; public static func proof(_: Data) -> PasswordResponse }
public enum ControlMessage: Sendable, Equatable {
    case hello(Hello), auth(Auth), accept(Accept), deny(Deny), config(StreamConfig), ping(Ping), pong(Ping),
         keyDown(KeyEvent), keyUp(KeyEvent), mouseDown(MouseButtonEvent), mouseUp(MouseButtonEvent),
         mouseMove(PointerState), scroll(ScrollEvent), requestKeyframe(reason: UInt8), disconnect(DisconnectReason), stats(ViewerStats),
         passwordChallenge(PasswordChallenge), passwordResponse(PasswordResponse),
         clipboardState(ClipboardState), clipboard(ClipboardContent),  // 0.1.5
         cursorImage(CursorImage), cursorShape(CursorShape)            // 0.1.6
    public var type: ControlMessageType { get }
    public func encodePayload() -> Data
    public static func decode(type: UInt8, payload: Data) throws -> ControlMessage   // rejects trailing bytes, bad enums, wrong fixed sizes
}
public enum ControlFraming { public static func frame(_ message: ControlMessage) -> Data }
public struct ControlStreamDecoder {           // incremental; tolerant of arbitrary chunking
    public init(maxMessageSize: Int = WireConstants.maxControlMessageSize)
    public mutating func append(_ chunk: Data) throws -> [ControlMessage]   // throws on oversized/zero length/malformed; after a throw the stream is dead
}
```

### Password access (0.1.2, opt-in, user-requested addition)

PRD §3 lists unattended access as an MVP non-goal; the product owner asked for it, so it exists as an **opt-in**
Host feature (off by default; `docs/PRD_COMPLIANCE.md` §12).

- **Key and proof.** `key = PBKDF2-HMAC-SHA256(UTF-8(NFC(password)), salt, iterations)` (32 bytes, CommonCrypto);
  `proof = HMAC-SHA256(key, "swiftdesk-password-v1" ‖ nonce ‖ hostFingerprint ‖ viewerFingerprint)` (CryptoKit). The
  fingerprints are the SHA-256 certificate fingerprints each side observed in mutual TLS, so a proof is bound to the
  channel, the nonce and both identities. The Host stores `{salt, iterations, key}`, never the password, and verifies
  in constant time (`HMAC.isValidAuthenticationCode`). Default rounds 1 000 000 (≈146 ms on M4 Pro); a Viewer
  answers only challenges with 1 000 000…5 000 000 rounds (others get `none`): the floor equals the rounds every real
  Host uses, so a hostile Host cannot obtain a proof that is cheaper to crack offline.
- **Order.** Viewer: HELLO, AUTH (unchanged layout). Host: version, channel binding and Screen Recording checks as
  before; then, if password access is enabled, the Viewer announced `passwordAuth` and it is not locked out →
  PASSWORD_CHALLENGE (fresh 32-byte `SecRandomCopyBytes` nonce, single use) and up to 3 s **without** an operator
  prompt. Valid proof → ACCEPT (same path as `approve()`). `none` → normal prompt. No answer in 3 s, or a proof for a
  challenge that went stale (password access switched off or removed, or the password changed, while the Viewer was
  answering) → the Host sends **PASSWORD_RESPONSE(none) Host → Viewer** ("prompting instead; your password is not
  used") and shows the normal prompt; a stale proof is not counted as a failure. A Viewer that gets this message
  after answering a challenge stops any proof, shows "waiting for approval" and never treats the following ACCEPT as
  a password login (nothing saved, not "via password"). Wrong proof → DENY(authFailed, "Incorrect password") and
  close. Locked out (see `PasswordAttemptLimiter`) → no challenge, normal prompt: the lockout covers password
  attempts only, so the Viewer can still ask the operator.
- **Compatibility, `protocolVersion` stays 1.** Decoders reject unknown types, so an old Viewer would drop the
  connection on PASSWORD_CHALLENGE instead of ignoring it. A new Viewer therefore announces support in the AUTH nonce
  (bytes 0–3 `"SDC1"`, byte 4 flags, bit 0 = `passwordAuth`, bytes 5–15 random), which every Host version only
  length-checks. The Host challenges only Viewers with the flag: an old Viewer is prompted at once; a flagged Viewer
  that stays silent hits the 3 s fallback. An old Host never challenges: a new Viewer behaves as before (its password
  is simply not used). DENY(authFailed) is only ever sent in answer to a proof, and Host → Viewer PASSWORD_RESPONSE
  only after a challenge, i.e. both only to new Viewers.

### Clipboard sharing (0.1.5, capability bit 2; PRD non-goal, deliberate addition)

```swift
/// CLIPBOARD (20), side stream only. Payload: u8 count (1…4), count × { u8 kind, u32 length, bytes }.
public struct ClipboardContent: Sendable, Equatable {
    public enum Kind: UInt8 { case plainText = 1, richText = 2, png = 3, url = 4 }
    public struct Item { public var kind: Kind; public var data: Data }
    public static let maxTextBytes = 1 << 20      // plain text, RTF, URL (each)
    public static let maxImageBytes = 16 << 20    // PNG, after encoding
    public static let maxPayloadBytes; public static let pngSignature
    public init(items:)                           // kept in kind order
    public var items: [Item] { get }; public func data(for: Kind) -> Data?; kinds; totalBytes; isEmpty
    public var isWellFormed: Bool { get }         // senders check it: the decoder rules below
}
/// CLIPBOARD_STATE (19), control stream. Payload: u8 flags, bit 0 enabled, other bits must be 0.
public struct ClipboardState: Sendable, Equatable { public var enabled: Bool }
```

Decode rules: a kind at most once, `1 ≤ length ≤ limit(kind)` (checked before reading), text and URL valid UTF-8,
PNG starts with the PNG signature, no trailing bytes. Both types are sent only when both peers announced
`PeerCapabilities.clipboard`; CLIPBOARD only on the side stream (`docs/TRANSPORT.md`, "Side stream"). Each side sends
CLIPBOARD_STATE after the session starts (Host after ACCEPT, Viewer on ACCEPT) and on every change of its switch;
clipboard data flows only while both say enabled.

### Remote pointer shape (0.1.6, capability bit 3; deliberate addition)

The Viewer still draws its own pointer locally (PRD §5: instant feedback; the Host cursor stays out of the captured
video), but in the shape the Host pointer has: I-beam, resize arrows, pointing hand, an app's custom cursor, hidden.

```swift
/// CURSOR_IMAGE (21), Host → Viewer, side stream only. Defines one shape under an id, once.
/// Payload (28-byte header): u32 id, u16 pixelWidth, u16 pixelHeight, f32 pointWidth, f32 pointHeight,
/// f32 hotSpotX, f32 hotSpotY (points from the top-left), u32 pngLength, png.
public struct CursorImage: Sendable, Equatable {
    public static let maxPixelSize = 256; maxPointSize: Float = 512; maxPNGBytes = 320 KiB; headerSize = 28
    public static let hostCacheSize = 32; viewerCacheSize = 64; pngSignature; maxPayloadBytes
    public var id: UInt32; pixelWidth, pixelHeight: UInt16; pointWidth, pointHeight, hotSpotX, hotSpotY: Float; png: Data
    public var isWellFormed: Bool { get }          // senders check it: the decoder rules below
}
/// CURSOR_SHAPE (22), Host → Viewer, control stream. Payload: u8 kind, u32 id (5 bytes).
public enum CursorShape: Sendable, Equatable, Hashable {
    case unavailable      // 0: the Host cannot tell → Viewer arrow
    case hidden           // 1
    case image(id: UInt32) // 2: id ≠ 0, names a CURSOR_IMAGE
    case off              // 3: the Host's switch is off → Viewer arrow
}
```

Decode rules: `id ≠ 0`; `1 ≤ pixel size ≤ 256`; `0 < point size ≤ 512`, finite; hot spot inside the point size;
`1 ≤ pngLength ≤ maxPNGBytes` (checked before reading); PNG signature; no trailing bytes. CURSOR_SHAPE: `id` must be 0
for every kind but 2, and non-zero for 2. Both types are sent only when both peers announced
`PeerCapabilities.cursorShape`; the Viewer then opens the side stream (as for clipboard). Ids count up from 1 and are
not reused within a connection; the Host references only its 32 most recent definitions (first in, first out) and
the Viewer keeps the 64 most recent, so a definition overtaking a CURSOR_SHAPE (two streams, no mutual order) never
evicts the id it names. A CURSOR_SHAPE naming an id not defined yet keeps the previous pointer until the
CURSOR_IMAGE arrives. The Host sends a CURSOR_SHAPE after ACCEPT, on every change (sampled ≈ 30 Hz) and on every change
of its switch (`off`).

### System shortcuts (0.1.7; no wire change; PRD scope extension, deliberate addition)

Send Keys and "Send system shortcuts" use only KEY_DOWN / KEY_UP (types 8 / 9) on the control stream, exactly as
typed keys do: no new message type, no capability bit (bits 4–7 stay free), no side-stream use, `protocolVersion`
stays 1. Every Host version therefore accepts them, and a 0.1.6-or-older Viewer simply never sends them. The Host
side is unchanged: it posts them at the HID tap (see InputCore), where the WindowServer's system shortcuts trigger.
Details: InputCore and ViewerSession below, `docs/TRANSPORT.md` "System shortcuts".

### Address book (0.1.8; no wire change; local only; PRD scope extension, deliberate addition)

Favorites / Recent on the Viewer's connect screen are stored on the Viewer only (SessionCore `AddressBookStore`,
below). Nothing new on the wire: no message type, no capability bit (bits 4–7 stay free), no side-stream use,
`protocolVersion` stays 1; it works with every Host version. `docs/TRANSPORT.md` "Address book".

### Open at Login (0.1.9; no wire change; local only; PRD non-goal "start-at-boot agent" touched, deliberate addition)

Host › Startup › *Open SwiftDesk at login* registers the app itself as a login item with `SMAppService.mainApp`
(ServiceManagement, macOS 13+). AppUI only (`Sources/AppUI/LoginItem.swift`): no SessionCore change, no message
type, no capability bit (bits 4–7 stay free), no side-stream use, `protocolVersion` stays 1. No launch agent or daemon
is installed, and the optional external watchdog LaunchAgent (`scripts/swiftdesk-watchdog.sh`,
`com.swiftdesk.watchdog`) is never read, changed or removed. `docs/TRANSPORT.md` "Open at Login".

```swift
enum LoginItemStatus { notRegistered, enabled, requiresApproval, notFound }   // SMAppService.Status
enum LoginItemFailure { alreadyRegistered, notRegistered /* both benign */, deniedByUser, invalidSignature,
    other(domain:code:); static from(_ error:) /* SMAppServiceErrorDomain codes only */; isBenign }
enum LoginItemLocation { applications, translocated, elsewhere(folder:), notAppBundle; static classify(bundleURL:homeDirectory:) }
@MainActor protocol LoginItemService: AnyObject { status; bundleURL; register() throws; unregister() throws;
    openSystemSettingsLoginItems() }
@MainActor final class SystemLoginItemService: LoginItemService   // SMAppService.mainApp
struct LoginItemPresentation { isOn; isAvailable; caption; needsApproval; note; noteTone (.info / .warning);
    static approvalMessage; static make(status:wanted:failure:location:listensAtLaunch:) }   // pure, unit-tested
@MainActor @Observable final class LoginItemController { static wantedKey = "SwiftDesk.host.openAtLogin";
    init(service:defaults:) /* reads the status */; status; wanted; failure; location; isOn;
    presentation(listensAtLaunch:); refresh() /* 0.2.0: a changed status clears `failure` */;
    setEnabled(_:) /* register/unregister, then re-read */; openSystemSettings() }
// AppModel.loginItem (init(…, loginItemService: = SystemLoginItemService(), addressBook: AddressBookStore? = nil
// /* 0.2.0: quick-connect menus before the Viewer exists; the app passes .standard() */)); refreshed by
// SwiftDeskAppDelegate.applicationDidBecomeActive. The switch shows the system's status, never the stored choice;
// the stored choice only explains an item removed outside SwiftDesk. SwiftDesk never re-registers on its own.
```

### Capability bits (0.1.4, both directions; reuse for every optional feature)

```swift
public struct PeerCapabilities: OptionSet, Sendable, Hashable { public let rawValue: UInt8
    public static let passwordAuth   /* bit 0: Viewer only (0.1.2) */
    public static let sessionResume  /* bit 1 (0.1.4): Viewer reconnects on its own; Host may resume without a prompt */
    public static let clipboard      /* bit 2 (0.1.5): CLIPBOARD_STATE / CLIPBOARD and the side stream */
    public static let cursorShape    /* bit 3 (0.1.6): CURSOR_SHAPE / CURSOR_IMAGE (Host → Viewer) and the side stream */
    public static let sideStreamFeatures: PeerCapabilities   // [.clipboard, .cursorShape]: the Viewer opens the side
                                                             // stream at an ACCEPT sharing at least one with it
    public static let marker: Data   // "SDC1"
    public static let carrierSize = 16
    public static func carrier(_: PeerCapabilities, random: Data) -> Data   // marker ‖ flags ‖ first 11 bytes of random
    public static func announced(in: Data) -> PeerCapabilities              // [] unless exactly 16 bytes with the marker
}
```

Viewer → Host in the AUTH nonce, Host → Viewer in the ACCEPT session token (both 16 bytes that every 0.1.x decoder
only length-checks; the token was otherwise unused). A feature is active only if **both** sides set its bit, and a
peer never sends a message type belonging to a feature the other side did not announce. Bits 4–7 are free; add new
ones here. No message layout changed; `protocolVersion` stays 1. Details: `docs/TRANSPORT.md` §3.

### Datagrams (unreliable QUIC datagrams). First byte = magic.

Video fragment header — exactly 32 bytes:

| off | size | field |
|---|---|---|
| 0 | 1 | magic `0x56` ('V') |
| 1 | 1 | version `1` |
| 2 | 1 | flags (`VideoFlags`) |
| 3 | 1 | fecGroupSize K (0 = no FEC parity for this frame). Was "reserved (0)" before the recovery pass; receivers that predate it ignore it |
| 4 | 4 | sessionId |
| 8 | 4 | frameId (monotonic per session, starts at 1) |
| 12 | 2 | packetIndex |
| 14 | 2 | packetCount (≥1, ≤ maxPacketsPerFrame) |
| 16 | 2 | payloadLength (must equal datagram length − 32) |
| 18 | 8 | captureTimestampNanos (host clock) |
| 26 | 4 | hostPipelineMicros (host capture → packetize) |
| 30 | 2 | reserved (0) |

Pointer datagram: `[0x50 'P'][version 1][u32 seq][f32 x][f32 y][u8 buttonsMask]` (15 bytes).

FEC parity datagram (added in the recovery pass) — 32-byte header + parity payload:

| off | size | field |
|---|---|---|
| 0 | 1 | magic `0x46` ('F') |
| 1 | 1 | version `1` |
| 2 | 1 | flags (`VideoFlags` of the frame) |
| 3 | 1 | groupSize K (1…255) |
| 4 | 4 | sessionId |
| 8 | 4 | frameId |
| 12 | 2 | parityIndex g (`< G = ceil(packetCount / K)`) |
| 14 | 2 | packetCount (data fragments of the frame) |
| 16 | 2 | payloadLength (must equal datagram length − 32; = longest member of the group) |
| 18 | 8 | captureTimestampNanos |
| 26 | 4 | hostPipelineMicros |
| 30 | 2 | lengthXor (XOR of the true payload lengths of the group's members) |

Layout (`FECLayout`): a frame of `n` data fragments with group size K has `G = ceil(n / K)` groups; data fragment `i`
belongs to group `i mod G` (interleaved, so a burst is spread over groups; every group has ≤ K members). Parity `g` =
XOR of its members, each zero-padded to the longest member (a full fragment, or the last fragment's length when the
group is that fragment alone). The Host sends the `G` parity datagrams after the frame's data fragments, in the same
batch, and duplicates them with the data for keyframes. **Compatibility:** no HELLO/CONFIG negotiation was added
(HELLO/CONFIG decoders reject trailing bytes, so a new field would break old peers). Instead a receiver without FEC
support drops parity at `Datagram.parse` (`badMagic`) and ignores byte 3, so old Viewers keep working (they only pay
the parity bandwidth); old Hosts send K = 0 and no parity. `protocolVersion` stays 1.

```swift
public struct VideoFlags: OptionSet, Sendable, Equatable { public let rawValue: UInt8; public static let keyframe = VideoFlags(rawValue: 1); public static let recovery = VideoFlags(rawValue: 2) }
public struct VideoPacketHeader: Sendable, Equatable {
    public static let size = 32
    public var flags: VideoFlags; public var sessionId: UInt32; public var frameId: UInt32
    public var packetIndex: UInt16; public var packetCount: UInt16; public var payloadLength: UInt16
    public var captureTimestampNanos: UInt64; public var hostPipelineMicros: UInt32
    public var fecGroupSize: UInt8                          // byte 3; init parameter defaults to 0
    public func encode(into: inout ByteWriter)
}
public struct ParityPacketHeader: Sendable, Equatable {      // recovery pass
    public static let size = 32
    public var flags: VideoFlags; public var groupSize: UInt8; public var sessionId: UInt32; public var frameId: UInt32
    public var parityIndex: UInt16; public var packetCount: UInt16; public var payloadLength: UInt16
    public var captureTimestampNanos: UInt64; public var hostPipelineMicros: UInt32; public var lengthXor: UInt16
    public var groupCount: Int { get }
    public func encode(into: inout ByteWriter)
}
public enum FECLayout {                                      // recovery pass
    public static let maxGroupSize = 255
    public static func groupCount(packetCount: Int, groupSize: Int) -> Int
    public static func group(ofIndex: Int, groupCount: Int) -> Int
    public static func memberCount(group: Int, packetCount: Int, groupCount: Int) -> Int
    public static func isLastOnlyGroup(group: Int, packetCount: Int, groupCount: Int) -> Bool
}
/// Host-side choice of K from the Viewer's loss reports. Raises protection on the first report that needs it, relaxes
/// after `relaxAfterReports` (3) agreeing reports. Default ladder: < 0.3 % → 10, < 0.8 % → 6, < 2 % → 4, else 3;
/// initial K 6 before the first report.
public struct FECPolicy: Sendable, Equatable {               // recovery pass
    public struct Configuration: Sendable, Equatable { enabled = true; fixedGroupSize: Int?; ladder: [Rung];
        initialGroupSize = 6; smoothing = 0.5; relaxAfterReports = 3; static let off; static func fixed(_:) }
    public init(configuration: Configuration = Configuration())
    public private(set) var groupSize: Int                   // 0 = no parity
    public private(set) var smoothedLossPercent: Double?
    @discardableResult public mutating func update(lossPercent: Double?) -> Int
}
public enum Datagram: Sendable, Equatable {
    case video(VideoPacketHeader, payload: Data)
    case pointer(PointerState)
    case parity(ParityPacketHeader, payload: Data)            // recovery pass
    public static func parse(_ data: Data) throws -> Datagram     // validates magic, version, lengths, index < count
    public static func encodePointer(_ p: PointerState) -> Data
}
public struct VideoPacketizer: Sendable {
    public init(sessionId: UInt32, maxDatagramSize: Int = WireConstants.defaultMaxDatagramSize)
    /// Splits one encoded access unit into datagrams. Throws `.oversized` if > maxFrameBytes or > maxPacketsPerFrame.
    /// fecGroupSize K > 0 (clamped to 255): data fragments carry K and ceil(n/K) parity datagrams are appended.
    public func packetize(frameId: UInt32, frame: Data, flags: VideoFlags, captureTimestampNanos: UInt64, hostPipelineMicros: UInt32,
                          fecGroupSize: Int = 0) throws -> [Data]
    public func parityCount(forFrameBytes: Int, fecGroupSize: Int) -> Int
}
public struct EncodedFrame: Sendable, Equatable {
    public var frameId: UInt32; public var flags: VideoFlags; public var data: Data
    public var captureTimestampNanos: UInt64; public var hostPipelineMicros: UInt32
    public var firstPacketAtNanos: UInt64; public var completedAtNanos: UInt64   // viewer clock
}
public enum ReassemblyEvent: Sendable, Equatable {
    case frameComplete(EncodedFrame)
    /// Frames that will never be delivered (gap or expiry). Caller must request a keyframe and gate decoding.
    case framesLost(count: Int)
}
/// Single-queue use only (not thread-safe). Bounded memory.
public final class FrameReassembler {
    public struct Config: Sendable {
        public var sessionId: UInt32
        public var deadlineNanos: UInt64 = 120_000_000
        public var keyframeDeadlineNanos: UInt64 = 500_000_000   // .keyframe frames (large, sent duplicated)
        public var maxPendingFrames: Int = 8
        public var maxPendingBytes: Int = 8 * 1024 * 1024
        public var maxFrameBytes: Int = WireConstants.maxFrameBytes
        public init(sessionId: UInt32)
    }
    public struct Stats: Sendable, Equatable {
        public var packetsReceived, packetsDuplicate, packetsMalformed, packetsStale, packetsWrongSession: UInt64
        public var framesCompleted, framesLost: UInt64
        public var pendingFrames: Int; public var pendingBytes: Int
        // recovery pass:
        public var parityReceived, parityStale, parityUnused, fragmentsRecovered, parityMalformed: UInt64
        public func lossEstimate(since: Stats) -> (received: UInt64, lost: UInt64)   // drives STATS
    }
    public init(config: Config)
    public func ingest(header: VideoPacketHeader, payload: Data, nowNanos: UInt64) -> [ReassemblyEvent]
    public func ingestParity(header: ParityPacketHeader, payload: Data, nowNanos: UInt64) -> [ReassemblyEvent]   // recovery pass
    public func ingest(_ datagram: Datagram, nowNanos: UInt64) -> [ReassemblyEvent]   // routes video/parity; pointer → []
    public func expire(nowNanos: UInt64) -> [ReassemblyEvent]   // call ~every 10–20 ms
    public func reset()
    public var stats: Stats { get }
    public var lastDeliveredFrameId: UInt32 { get }
}
```

Reassembly rules: deliver complete frames in strictly increasing `frameId`; a packet for `frameId <= lastDelivered` is
stale (count, drop); when frame N completes, every pending incomplete frame `< N` is discarded and the number of skipped
ids `N - lastDelivered - 1` is reported once via `framesLost` (before the `frameComplete`); first frame of a session may
start at any id (no loss reported if it is a keyframe); duplicates of an already-received packetIndex are counted and
ignored; packetCount/flags/timestamp mismatch within one frameId → malformed, drop the whole frame; evict the oldest
pending frame when `maxPendingFrames`/`maxPendingBytes` would be exceeded (counts as lost); frames past deadline expire.

FEC rules (recovery pass): a parity datagram is checked like a fragment (session, structure, stale floor — counted in
`parityStale`, not `packetsStale`, because at no loss every parity arrives after its frame completed) and can open a
slot. Frame metadata including K must match the slot, else the frame is malformed and dropped. Parity length must be
a full fragment (or the last fragment's length for a last-only group); a mismatch drops the frame. Parity for a group
with nothing missing, or a duplicate, is counted in `parityUnused` and not buffered. When a group is missing exactly
one data fragment and its parity is held, the fragment is rebuilt at once: XOR, true length = `lengthXor` ⊕ the other
members' lengths, which must be 1…parity length with all padding bytes zero, and no member may be longer than the
parity; otherwise the parity is discarded (`parityMalformed`) and the frame keeps waiting for the real fragment. A
rebuilt fragment passes the normal size checks. Parity bytes count toward `maxPendingBytes`, are freed when their
group completes, and with the frame on completion, expiry or eviction. Two or more losses in one group are
unrecoverable: the frame is lost by the usual gap/expiry rules and keyframe recovery runs.

```swift
/// Decoder-side recovery: after loss, drop non-keyframes until a keyframe arrives; rate-limit keyframe requests.
public struct RecoveryGate: Sendable {
    public init(minRequestIntervalNanos: UInt64 = 200_000_000, rerequestAfterNanos: UInt64 = 500_000_000,
                maxSilentRerequestIntervalNanos: UInt64? = nil)   // 0.1.4: non-nil = back off re-requests while silent
    public mutating func noteTraffic()                   // 0.1.4: datagrams arrived (once per receive batch)
    public var currentRerequestIntervalNanos: UInt64 { get }   // 500 ms with traffic; 1 s, 2 s, … ≤ cap while silent
    public private(set) var awaitingKeyframe: Bool       // initially true (need the first keyframe)
    public mutating func onLoss(nowNanos: UInt64) -> Bool   // returns true if a REQUEST_KEYFRAME should be sent now
    public mutating func onDecodeError(nowNanos: UInt64) -> Bool
    public mutating func admit(flags: VideoFlags) -> Bool   // false => drop frame without decoding; keyframe clears awaiting
    public mutating func tick(nowNanos: UInt64) -> Bool     // true => re-send request (still awaiting after rerequestAfter)
}
```

## TransportCore (Network.framework QUIC, Security, CryptoKit)

```swift
public final class DeviceIdentity: @unchecked Sendable {
    /// Loads or creates a self-signed P-256 certificate + private key in the login keychain (label default "SwiftDesk Device Identity").
    public static func loadOrCreate(label: String = "SwiftDesk Device Identity") throws -> DeviceIdentity
    public static func regenerate(label: String = "SwiftDesk Device Identity") throws -> DeviceIdentity
    public let secIdentity: SecIdentity
    public let certificateDER: Data
    public let fingerprint: Data                 // SHA-256(certificateDER), 32 bytes
    public var fingerprintDisplay: String { get } // Self.display(fingerprint)
    public static func display(_ fingerprint: Data) -> String   // e.g. "3F2A 9C01 77DE …" first 16 bytes as 8 groups of 4 hex, uppercase
}
public enum PeerConnectionState: Sendable, Equatable { case connecting, ready, failed(String), closed }
public final class PeerConnection: @unchecked Sendable {
    /// Viewer side. If `pinnedHostFingerprint` is non-nil the TLS handshake fails unless the host leaf cert matches.
    /// If nil, the handshake succeeds and the session layer must get explicit user trust before sending HELLO.
    public static func connect(host: String, port: UInt16, identity: DeviceIdentity, pinnedHostFingerprint: Data?) -> PeerConnection
    public var onStateChange: (@Sendable (PeerConnectionState) -> Void)?
    public var onControlMessage: (@Sendable (ControlMessage) -> Void)?   // in order, on the transport queue
    public var onDatagram: (@Sendable (Data) -> Void)?                   // on the transport queue: must return fast
    public var onProtocolError: (@Sendable (WireError) -> Void)?         // malformed control stream => connection closed
    public func start()                       // set callbacks first
    public var state: PeerConnectionState { get }
    public var peerFingerprint: Data? { get } // SHA-256 of peer leaf cert, known once ready
    public var remoteAddress: String { get }  // "ip:port" or hostname
    public var maxDatagramSize: Int { get }   // min(usable QUIC datagram size, WireConstants.defaultMaxDatagramSize)
    public func sendControl(_ message: ControlMessage)
    /// Unreliable. Returns false (and drops) if the send backlog exceeds `maxBacklogBytes` — caller counts it as backpressure.
    @discardableResult public func sendDatagrams(_ datagrams: [Data]) -> Bool
    /// Review 2026-11-03: also refused when more than `maxQueuedAheadBytes` are already queued ahead (nothing pending admits).
    @discardableResult public func sendDatagrams(_ datagrams: [Data], maxQueuedAheadBytes: Int) -> Bool
    public var maxBacklogBytes: Int           // default 1 MiB (0.1.3; was 256 KiB) — absolute cap; the Host also bounds each batch in time
    public var pendingDatagramBytes: Int { get }  // bytes handed to Network.framework whose send completion has not fired
    public func close(reason: DisconnectReason?)  // sends DISCONNECT if ready, then cancels; idempotent
    // 0.1.5 side stream (bulk payloads; docs/TRANSPORT.md "Side stream"). sendControl refuses side-stream types;
    // a type on the wrong stream is a protocol error (connection closed).
    public func openSideStream()                  // Viewer only, after both peers announced a feature using it; idempotent
    public func allowSideStream()                 // Host only (0.2.0): call once the session is authorized; until then a side stream is parked unread; idempotent
    public var isSideStreamOpen: Bool { get }
    @discardableResult public func sendSide(_ message: ControlMessage, completion: (@Sendable (Bool) -> Void)? = nil) -> Bool
    public var onSideMessage: (@Sendable (ControlMessage) -> Void)?   // transport queue, in order
    public var onSideStreamReady: (@Sendable () -> Void)?             // once per connection
}
public enum ListenerState: Sendable, Equatable { case starting, ready(port: UInt16), failed(String), stopped }
public final class HostListener: @unchecked Sendable {
    public init(port: UInt16 = WireConstants.defaultPort, identity: DeviceIdentity, deviceName: String, advertiseBonjour: Bool = true)
    public var onStateChange: (@Sendable (ListenerState) -> Void)?
    /// Called once the QUIC/TLS handshake is complete (peerFingerprint known) and the rate limiter allowed it.
    public var onIncoming: (@Sendable (PeerConnection) -> Void)?
    public func start(); public func stop()
}
/// Token-bucket style limiter: per-remote-IP and global. Pure, testable.
public struct ConnectionRateLimiter: Sendable {
    public init(perAddressPerMinute: Int = 6, globalPerMinute: Int = 30)
    public mutating func allow(address: String, nowNanos: UInt64) -> Bool
}
public struct InterfaceAddress: Sendable, Equatable, Hashable { public var interface: String; public var address: String; public var isIPv6: Bool; public var isTailscale: Bool }
public enum NetworkInfo { public static func localAddresses() -> [InterfaceAddress] }   // getifaddrs; tailscale = 100.64.0.0/10 or fd7a:115c:a1e0::/48
public struct TailscalePeerPath: Sendable, Equatable { public var peerAddress: String; public var direct: Bool; public var relay: String?; public var currentAddress: String? }
public enum TailscaleProbe {
    /// Best-effort: runs the Tailscale CLI (`tailscale status --json`, app bundle or PATH) off the main thread; nil if unavailable.
    public static func path(to peerAddress: String) async -> TailscalePeerPath?
}
public final class BonjourBrowser: @unchecked Sendable {   // optional convenience
    public struct Result: Sendable, Hashable { public var name: String; public var endpointDescription: String }
    public init(); public var onResults: (@Sendable ([Result]) -> Void)?; public func start(); public func stop()
    public func resolve(_ result: Result) async -> (host: String, port: UInt16)?
}
```

Transport design requirements: one QUIC connection per session (NWConnectionGroup over NWMultiplexGroup,
`maxDatagramFrameSize` set, a bidirectional stream for control, a datagram flow extracted with `isDatagram = true`) —
**validate with `QUICSpike` on loopback first**; if the single-connection approach cannot be made to work, document why in
`docs/TRANSPORT.md` and fall back to two authenticated QUIC connections bound by the session token. mTLS: both sides present
their DeviceIdentity; custom verify blocks compute SHA-256 of the peer leaf; host requires a client certificate. TLS 1.3.
Idle timeout 30 s (0.1.4; was ~10 s) + 3 s keepalive; QUIC uses the smaller of both peers' values. Never accept the control stream before the handshake. Datagram receive loop must re-arm
immediately and do no allocation-heavy work.

## CaptureCore (ScreenCaptureKit)

```swift
public struct DisplayInfo: Sendable, Identifiable, Hashable {
    public var id: CGDirectDisplayID; public var name: String
    public var frame: CGRect          // global display coordinates in points (CGDisplayBounds)
    public var pixelWidth: Int; public var pixelHeight: Int
}
public enum ScreenCapturePermission { public static func isGranted() -> Bool; public static func request() -> Bool; public static func openSettings() }
public struct CaptureConfig: Sendable, Equatable { public var maxWidth = 1920; public var maxHeight = 1080 /* 0.1.3: Sharp top rung; was 1280×720 */; public var fps = 60; public var showsCursor = false; public var queueDepth = 4 /* review: was 3; the encoder retains its newest frame */; public init(...) }
public enum CaptureGeometry { public static func fit(sourceWidth: Int, sourceHeight: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) }  // aspect preserving, even dims, never upscales
public struct CapturedFrame: @unchecked Sendable { public let pixelBuffer: CVPixelBuffer; public let presentationTime: CMTime; public let captureNanos: UInt64; public let sequence: UInt64 }
public final class ScreenCapturer: @unchecked Sendable {
    public static func availableDisplays() async throws -> [DisplayInfo]
    public init(display: DisplayInfo, config: CaptureConfig)
    public var onFrame: (@Sendable (CapturedFrame) -> Void)?     // capture queue; only SCFrameStatus.complete frames; must not block
    public var onStopped: (@Sendable (Error?) -> Void)?          // stream stopped by system (permission revoked, display gone)
    public func start() async throws
    public func update(config: CaptureConfig) async throws        // SCStream.updateConfiguration
    public func stop() async
    public private(set) var outputSize: (width: Int, height: Int)
}
```
Pixel format `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, BT.709 color matrix, `showsCursor = false`, `queueDepth = 4` (sanitized to 3…8)
(never 1), `minimumFrameInterval = 1/fps`.

## CodecCore (VideoToolbox)

```swift
public struct EncoderConfig: Sendable, Equatable { public var width: Int; public var height: Int; public var fps: Int = 60; public var bitrateKbps: Int = 3000; public var keyframeIntervalSeconds: Double = 4; public init(...) }
public struct EncodedVideoFrame: Sendable {
    public var data: Data          // AVCC: 4-byte BE length-prefixed NAL units; keyframes are prefixed with SPS + PPS NALUs
    public var isKeyframe: Bool; public var captureNanos: UInt64; public var encodeDoneNanos: UInt64; public var sequence: UInt64
}
public final class H264Encoder: @unchecked Sendable {
    public init(config: EncoderConfig) throws
    public var onEncodedFrame: (@Sendable (EncodedVideoFrame) -> Void)?   // VideoToolbox callback thread
    /// Non-blocking. Returns false (counts it) if one encode is already in flight; the frame then only waits in the single
    /// latest-frame slot: a newer capture replaces it, and with no newer capture for ~1.5 frame intervals (static screen)
    /// it is submitted then. Never queued behind the in-flight frame.
    @discardableResult public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, captureNanos: UInt64, sequence: UInt64) -> Bool
    public func requestKeyframe()                  // next encoded frame is an IDR; on a static screen the newest frame is resubmitted as it
    public func setBitrate(kbps: Int)              // live update
    public func reconfigure(_ config: EncoderConfig) throws   // recreate session (resolution/fps change); next frame is keyframe
    public func invalidate()
    public var isHardwareAccelerated: Bool? { get }
    public var lowLatencyRateControl: Bool { get }  // true if the session was created with EnableLowLatencyRateControl
    public var appliedProperties: [String: Bool] { get }
    public var droppedForBackpressure: UInt64 { get }
    public var refreshesSubmitted: UInt64 { get }      // retained frames resubmitted (keyframe request / dropped newest frame, static screen)
    public var waitingFramesSubmitted: UInt64 { get }  // latest-slot frames submitted after the quiet period
    public var hasWaitingFrame: Bool { get }
    // Frames admitted while `reconfigure` rebuilds the session carry the old generation and are dropped, not encoded.
}
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer      // 420v, IOSurface-backed, Metal compatible
    public let frameId: UInt32; public let captureNanos: UInt64 /*host clock*/
    public let receivedNanos: UInt64; public let decodeDoneNanos: UInt64
}
public final class H264Decoder: @unchecked Sendable {
    public init()
    public var onDecodedFrame: (@Sendable (DecodedFrame) -> Void)?
    public var onError: (@Sendable (OSStatus) -> Void)?    // caller requests a keyframe
    /// Parses AVCC; (re)creates format description/session when SPS/PPS change. Returns false if it could not decode (no params yet, malformed).
    @discardableResult public func decode(_ data: Data, frameId: UInt32, captureNanos: UInt64, receivedNanos: UInt64) -> Bool
    public func reset()
}
public enum AVCC {   // pure helpers, unit-tested
    public static func nalUnits(in data: Data) throws -> [Data]
    public static func nalType(_ nal: Data) -> UInt8
    public static func lengthPrefixed(_ nals: [Data]) -> Data
}
```
Encoder: `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true` (+ require HW if available, fall back), RealTime,
AllowFrameReordering=false, ProfileLevel ConstrainedHigh AutoLevel first (0.1.3; then ConstrainedBaseline/Main/Baseline/High),
AverageBitRate, ExpectedFrameRate,
MaxKeyFrameIntervalDuration, MaxFrameDelayCount=0 where accepted. Note low-latency mode may use long GOPs — keyframes on
demand via `kVTEncodeFrameOptionKey_ForceKeyFrame` are the recovery mechanism. Decoder output attributes: 420v,
`kCVPixelBufferMetalCompatibilityKey`, IOSurface properties. Decode synchronously on caller's queue (`decodeFlags = []`) to keep ordering simple and latency minimal.

## RenderCore (Metal)

```swift
public protocol RenderableFrame: Sendable { var pixelBuffer: CVPixelBuffer { get }; var frameId: UInt32 { get }; var decodeDoneNanos: UInt64 { get } }
public struct PresentedFrameInfo: Sendable { public var frameId: UInt32; public var decodeToPresentNanos: UInt64 }
public enum VideoGeometry {   // pure, unit-tested
    public static func aspectFitRect(content: CGSize, in bounds: CGRect) -> CGRect
    /// View point (AppKit coords, origin bottom-left unless isFlipped) → normalized video point (0,0 top-left). nil if outside the video rect.
    public static func normalizedPoint(viewPoint: CGPoint, videoRect: CGRect, viewIsFlipped: Bool) -> CGPoint?
    /// Same, but outside points are clamped onto the video's edge (moves, drags, button-ups while capturing; review).
    public static func clampedNormalizedPoint(viewPoint: CGPoint, videoRect: CGRect, viewIsFlipped: Bool) -> CGPoint?
    /// 0.1.3: the renderer's whole-pixel viewport in view points (input maps against exactly what is drawn). The
    /// viewport snaps to exactly a whole multiple of the frame size (1×, 2×, …) when within 2 px of it, and is then
    /// sampled with nearest luma (exact 1:1, or clean pixel doubling); any other factor is sampled linearly.
    public static func videoRect(content: CGSize, bounds: CGRect, scale: CGFloat, viewIsFlipped: Bool) -> CGRect
    public enum WindowSizing { case actualSize /* ⌘0: strict 1:1 */; case automatic /* largest whole magnification
        that fits, or fill the screen when that is < 60 % of it on both axes */ }
    /// 0.1.3: Viewer window frame showing `streamPixels` at one stream pixel per screen pixel (or as large as fits).
    public static func actualSizeWindowFrame(windowFrame: CGRect, videoArea: CGSize, streamPixels: CGSize,
        backingScale: CGFloat, visibleFrame: CGRect, minimumFrameSize: CGSize = .zero,
        sizing: WindowSizing = .actualSize) -> CGRect?
}
@MainActor public class MetalVideoView: NSView {   // CAMetalLayer-backed; renders YUV 420v via CVMetalTextureCache
    public init(frame: CGRect)
    /// Thread-safe; callable from the decode queue. Replaces any not-yet-displayed frame (counts replacements).
    nonisolated public func enqueue(_ frame: any RenderableFrame)
    public var onPresented: (@Sendable (PresentedFrameInfo) -> Void)?
    public var videoRect: CGRect { get }        // current aspect-fit rect in view coords = renderer viewport (whole pixels)
    nonisolated public var framesReplacedBeforeDisplay: UInt64 { get }
    public func clear()
}
/// MetalVideoView subclass that captures input while focused and forwards it. Keeps the local system arrow cursor visible
/// (local pointer feedback; host cursor is hidden from capture).
@MainActor public final class RemoteDisplayView: MetalVideoView {
    public var onMouse: ((NSEvent, CGPoint?) -> Void)?      // normalized point (nil outside video)
    public var onScroll: ((NSEvent) -> Void)?
    public var onKey: ((NSEvent) -> Void)?                  // keyDown/keyUp/flagsChanged, including key equivalents while captured
    public var onFocusChange: ((Bool) -> Void)?             // became/resigned first responder or window key status lost
    public var isCapturingInput: Bool                        // when false, events are not forwarded
    public var forwardsQuitShortcut: Bool                    // 0.2.0: ⌘Q forwarded only when true (ViewerSession mirrors sendsSystemShortcuts)
    public static func isQuitShortcut(_ event: NSEvent) -> Bool
    // 0.1.6 remote pointer shape: shown instead of the arrow while capturing and over `videoRect` (letterbox: arrow);
    // applied through cursorUpdate / mouse moves (no cursor rect while it is shown) and at once on change.
    public var remotePointer: RemotePointer                  // .standard (arrow, default) / .hidden / .image(RemotePointerImage)
    public var remoteDisplayPointSize: CGSize?               // Host display in points (CONFIG), for the scale
}
public struct RemotePointerImage: Sendable, Equatable { id: UInt32; image: CGImage; pointSize: CGSize; hotSpot: CGPoint }
public enum RemotePointer: Sendable, Equatable { case standard, hidden, image(RemotePointerImage) }
public enum RemotePointerCursor {
    static let scaleRange: ClosedRange<CGFloat> = 0.75...2   // Host point size × video magnification, 5 % steps
    static func scale(videoRect:hostPointSize:) -> CGFloat; static func cursor(for:scale:) -> NSCursor
    static let hidden: NSCursor                              // transparent (never NSCursor.hide())
}
```
Shaders: compile at runtime with `device.makeLibrary(source:options:)` from an embedded string (robust with or without the
metal CLI). Render on demand when a new frame arrives (drive via `CAMetalDisplayLink` or `NSView.displayLink(target:selector:)`,
macOS 14+), never queue more than one frame, `maximumDrawableCount` 2–3, `displaySyncEnabled` true,
`presentsWithTransaction` false. Use `MTLDrawable.addPresentedHandler` for decode→present latency.

## InputCore

```swift
public enum AccessibilityPermission { public static func isTrusted(prompt: Bool) -> Bool; public static func openSettings() }
public enum OutgoingInput: Sendable, Equatable { case reliable(ControlMessage); case pointer(PointerState) }
/// Viewer side. Translates NSEvents → wire messages; tracks held keys/buttons; owns sequence numbers.
@MainActor public final class ViewerInputController {
    public init(send: @escaping @Sendable (OutgoingInput) -> Void)
    public static let releaseShortcutDescription: String  // "⌃⌥⎋" (Control-Option-Escape)
    public func handleMouse(_ event: NSEvent, normalized: CGPoint?)
    public func handleScroll(_ event: NSEvent)
    /// Returns false if this was the local release shortcut (caller stops capturing; nothing is sent).
    public func handleKey(_ event: NSEvent) -> Bool
    public func releaseAll()      // key-up for every held key, mouse-up for every held button
}
public struct InputStateTracker: Sendable { ... }   // pure: held keys/buttons/modifiers, seq numbers; unit-tested
public enum ModifierKeys { public static func flag(forKeyCode: UInt16) -> UInt64? }   // flagsChanged → down/up classification
public enum HostCoordinateMapper {   // pure, unit-tested
    /// normalized (0,0 top-left) → global CG display coordinates in points (origin top-left of main display), clamped to the display.
    public static func globalPoint(normalizedX: Float, normalizedY: Float, displayFrame: CGRect) -> CGPoint
}
/// Host side. Posts CGEvents only while authorized; serial queue; releases held state on revoke.
public final class HostInputInjector: @unchecked Sendable {
    public init(displayFrame: CGRect)
    public func setAuthorized(_ authorized: Bool)    // false => releaseAll() then reject everything
    public func updateDisplayFrame(_ frame: CGRect)
    public func handle(_ message: ControlMessage)     // key/mouse/scroll/mouseMove; ignores others
    public func handlePointer(_ state: PointerState)  // datagram path; drops seq <= last
    public func releaseAll()
}
```
System shortcuts (0.1.7, Viewer side; all pure parts unit-tested in `InputCoreTests/SystemShortcutTests`):

```swift
public struct KeyStroke: Sendable, Equatable { keyCode: UInt16; isDown: Bool; flags: UInt64 /* CGEventFlags after it */ }
public struct KeyChord: Sendable, Hashable { keyCode: UInt16; modifiers: [UInt16]   // modifier key codes, press order
    public var strokes: [KeyStroke]   // modifiers down (flag + left device flag each), key down/up (+ intrinsic
                                      // fn/keypad flags), modifiers up in reverse; ends with no modifier flag set
    public var symbols: String }      // "⌃⌘Q" (Apple order ⌃⌥⇧⌘)
public enum SystemShortcut: CaseIterable, Identifiable { appSwitcher ⌘Tab, spotlight ⌘Space, emojiAndSymbols ⌃⌘Space,
    missionControl ⌃↑, appExpose ⌃↓, showDesktop F11, launchpad (key code 131), screenshotScreen ⇧⌘3,
    screenshotSelection ⇧⌘4, screenshotOptions ⇧⌘5, forceQuit ⌥⌘Esc, lockScreen ⌃⌘Q
    var title; var chord: KeyChord; var keysDescription; var group: Group /* apps, windows, screenshots, system */
    var needsConfirmation: Bool /* lockScreen */; static func shortcuts(in: Group) -> [SystemShortcut] }
ModifierKeys.intrinsicFlags(forKeyCode:) -> UInt64      // fn on F-keys/navigation keys, fn + keypad on arrows
ViewerInputController.send(_ chord: KeyChord)            // releases held input, then the chord's strokes (reliable)
ViewerInputController.handleKey(_ event: TapKeyEvent) -> Bool   // same rules as handleKey(NSEvent)
public struct TapKeyEvent: Sendable, Equatable { kind: .down/.up/.flagsChanged; keyCode; flags; isRepeat }
public enum SystemShortcutFilter {   // pure decision for every event the tap sees
    static func decide(type: CGEventType, keyCode:, flags:, armed: Bool, postedByThisProcess: Bool = false,
                       trackingLocalUI: Bool = false) -> Decision   // .pass / .forward / .reenable
    static func keyEvent(type:keyCode:flags:autorepeat:) -> TapKeyEvent? }
@MainActor public protocol SystemShortcutTapping: AnyObject { var isInstalled: Bool; func install() -> Bool; func remove() }
@MainActor public final class SystemShortcutTap: SystemShortcutTapping {
    init(isArmed: @escaping @MainActor () -> Bool, deliver: @escaping @MainActor (TapKeyEvent) -> Void) }
```
Filter rules: unarmed → pass everything; armed → forward every keyDown/keyUp/flagsChanged (one ordered path for all
keys, so the ⌘ of ⌘Tab precedes its Tab) except the release shortcut ⌃⌥⎋ (passes to the view, which ends capture),
events posted by this process (no loop with a Host on the same Mac) and keys while a local menu/drag is tracked
(`RunLoop` in `.eventTracking`); `tapDisabledByTimeout/UserInput` → re-enable while armed. The tap is an active
(`.defaultTap`) `.cghidEventTap` / `.headInsertEventTap` tap for keyDown/keyUp/flagsChanged, run on the main run loop
in common modes, needing Accessibility. `isArmed` is evaluated for every event.

Injection: `CGEventSource(stateID: .hidSystemState)`, post to `.cghidEventTap`; drag events while a button is held;
`.mouseEventClickState` = clickCount; key events via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with tracked
modifier flags; scroll via `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)` (pixel/line units).

## SessionCore / AppUI

Defined in wave 3 against the APIs above: `HostSession`, `ViewerSession`, `LoopbackSession` (Milestone A: capture →
encode → decode → Metal locally), `AdaptationController` (pure; 0.1.3 Sharp ladder ≤1920×1080@60 → 1280×720@60 →
960×540@60 → 960×540@30 with per-rung bitrate ranges; Balanced = the original 1280×720@60 → 960×540@60 → 960×540@30,
1000–5000 kbps, default 3000), `TrustedHostStore`. AppUI: role picker, Host screen, Viewer screen, Loopback screen,
menu-bar sharing indicator.

## SessionCore (implemented)

`Sources/SessionCore`. Everything below is `public`; the real source wins over this text. AppUI depends only on
SessionCore in `Package.swift`, but SwiftPM lets it `import` the transitive modules it needs for types that appear in
this API: `DiagnosticsCore` (`MetricsSnapshot`, `RollingStats.Summary`, `RTTEstimator.Value`), `CaptureCore`
(`DisplayInfo`, `CaptureConfig`), `TransportCore` (`InterfaceAddress`, `DeviceIdentity`), `RenderCore`
(`MetalVideoView`, `RemoteDisplayView`), `WireProtocol` (`StreamConfig`, `WireConstants`), `InputCore`
(`SystemShortcut`, 0.1.7). Adding them as explicit
AppUI dependencies would be cleaner (not done: Package.swift is frozen).

**Threading rule for AppUI:** the three session classes are `@MainActor @Observable`; read their properties directly
in SwiftUI. They update at most ~2 Hz (metrics) plus on discrete events. No frame or input ever passes through the
main actor except AppKit input, which is forwarded synchronously from the event handler.

### HostSession (`@MainActor @Observable final class`) — "Share this Mac"

```swift
let host = try HostSession.makeDefault()            // loads/creates the keychain identity, fills `displays`
// or: HostSession(configuration: .init(), dependencies: .system(identity: try DeviceIdentity.loadOrCreate()))

enum HostSession.State: Equatable { case idle, starting, listening(port: UInt16),
                                    awaitingApproval(ConnectionRequest), active(HostPeer) }
struct ConnectionRequest: Identifiable, Equatable { id: UUID; peerName; appVersion; fingerprint: Data;
    fingerprintDisplay: String; remoteAddress: String; accessibilityGranted: Bool; receivedAt: Date }
struct HostPeer: Equatable { name; fingerprintDisplay; remoteAddress; sessionId: UInt32; startedAt: Date; isViewOnly: Bool;
    viaPassword: Bool = false /* 0.1.2: session started with the access password, no Allow click */ }

// Observable state
var state: State                         // idle → starting → listening → awaitingApproval → active → listening
var metrics: MetricsSnapshot             // ≈2 Hz while active; reset to MetricsSnapshot() when the session ends
var displays: [DisplayInfo]; var selectedDisplayID: CGDirectDisplayID?   // settable; used at the next approve()
var selectedDisplay: DisplayInfo? { get }
var localAddresses: [InterfaceAddress]   // NetworkInfo.localAddresses(); `isTailscale` flags tailnet IPs
var screenRecordingGranted: Bool; var accessibilityGranted: Bool        // refreshPermissions() re-reads them
var isViewOnly: Bool                     // active session cannot inject input (Accessibility missing/revoked)
var lastError: String?; var lastEndReason: String?    // e.g. "The Viewer disconnected", "You stopped sharing"
let deviceName: String; let fingerprintDisplay: String; let fingerprintDisplayFull: String   // own identity, show to the Viewer's user
var pendingRequest: ConnectionRequest? { get }; var isSharing: Bool { get }; var activePeer: HostPeer? { get }
var pendingConnectionCount: Int          // connections past mTLS that have not sent HELLO + AUTH yet (hold no slot)
var streamQuality: StreamQuality         // 0.1.3; applies to the next session (AppModel persists it)
var expectedStreamSize: (width: Int, height: Int)? { get }   // e.g. 1600×900 for a 1600×900 display on Sharp
var sessionAdaptation: AdaptationController.Configuration { get }   // streamQuality.adaptation(base: configuration.adaptation)
// 0.1.2 password access
var passwordAccessEnabled: Bool; var passwordAccessConfigured: Bool; var supportsPasswordAccess: Bool { get }
var passwordFailureCount: Int; var lastPasswordFailure: String?   // e.g. "Wrong password from 192.168.1.20 (Mac mini)"
func setAccessPassword(_ password: String) async throws   // ≥ AccessPassword.minimumLength (8); PBKDF2 off the main actor
func setPasswordAccessEnabled(_: Bool) throws; func clearAccessPassword(); func refreshPasswordState()

// Actions
func startListening(); func stopListening()          // stopListening ends any session (DISCONNECT hostStopped)
func approve(); func deny()                          // only act while awaitingApproval
func stopSharing()                                   // DISCONNECT hostStopped, stop capture, release input, keep listening
func refreshPermissions(); func refreshDisplays(); func refreshNetworkInfo()
func dropPendingConnections()                        // closes every not-yet-identified connection
@discardableResult func requestScreenRecordingPermission() -> Bool; func openScreenRecordingSettings()
@discardableResult func requestAccessibilityPermission() -> Bool;   func openAccessibilitySettings()
func waitForTeardown() async                         // capture/encode of ended sessions fully stopped (app quit, tests)

// 0.1.4 dropouts
var allowsReconnectWithoutPrompt: Bool   // default true (AppModel persists); off ⇒ revokes grace, ACCEPT omits sessionResume
var reconnectGrace: ReconnectGraceInfo?  // { peerName, expiresAt, viaPassword } while a dropped session may resume
var reconnectedNotice: ReconnectedNotice? // { id, peerName, at } after a resume; cleared at session end
var isPeerSilent: Bool                   // active Viewer silent ≥ inputReleaseAfterSilence (held input released)
func revokeReconnectGrace(); func dismissReconnectedNotice()
// HostPeer.resumed: Bool = false        // resumed without a prompt; startedAt/viaPassword of the original session

struct HostSession.Configuration { port = 47800; deviceName = computer name; advertiseBonjour = true;
    rateLimiter = ConnectionRateLimiter(); preHelloTimeout = 60 s; handshakeTimeout = 10 s (HELLO→AUTH);
    approvalTimeout = 60 s; capture = CaptureConfig(); adaptation = AdaptationController.Configuration();
    adaptationEnabled = true; duplicateKeyframePackets = true;
    forwardErrorCorrection = FECPolicy.Configuration() /* adaptive XOR parity; .off disables (recovery pass) */;
    maxPendingHandshakes = 4; deniedPeerCooldown = 60 s /* review 2026-11-03 */;
    passwordTimeout = 3 s; passwordAttempts = PasswordAttemptLimiter.Configuration() /* 0.1.2 */;
    reconnectGraceWindow = 120 s; inputReleaseAfterSilence = 1 s /* 0.1.4 */ }
struct HostSession.Dependencies { identity; permissions: PermissionChecker;
    makeVideoSource: @Sendable (DisplayInfo?, CaptureConfig) throws -> any VideoSource;
    makeInputSink: @Sendable (CGRect) -> any InputSink;
    accessPassword: HostAccessPassword? = nil /* 0.1.2; .system(identity:) uses the keychain */;
    static func system(identity:) -> Dependencies }
enum HostSessionError: Error { case noDisplay }
```

Behaviour: one session at a time — any other connection gets DENY(busy) while a request awaits approval or a session is
active. Connections that have not identified themselves yet (HELLO + AUTH) hold no slot: up to `maxPendingHandshakes`
wait side by side (when full, the oldest from the newcomer's address, else the oldest overall, gets DENY(busy)); the first
to pass AUTH takes the slot. After an operator Deny or approval timeout, the same Viewer fingerprint gets
DENY(rateLimited) without a prompt for `deniedPeerCooldown`. HELLO/ACCEPT names are passed through
`SessionSupport.displayName` (no control/format/separator scalars, single line, ≤ 64 Characters). The input sink's
display frame is re-read at session start and on `NSApplication.didChangeScreenParametersNotification` during a
session (`ScreenCapturer.displayFrame` is live `CGDisplayBounds`). HELLO within `preHelloTimeout` (long, because
a first-time Viewer sends HELLO only after its user compared fingerprints), AUTH within `handshakeTimeout` after it.
AUTH must equal the TLS-observed fingerprints both ways, else DENY(identityMismatch); version mismatch → DENY(versionMismatch);
no Screen Recording → DENY(permissionsMissing); no Accessibility → request shows `accessibilityGranted == false` and an
approved session is view-only. Operator silence → DENY(timeout). On `approve()`: ACCEPT (random non-zero sessionId via
`SecRandomCopyBytes`, random 16-byte token), CONFIG after capture starts, capture → encode → packetize → send on
dedicated queues, input sink authorized. Teardown (stopSharing, Viewer DISCONNECT, connection loss, capture stopped by the
system) always: deauthorize input (releases held keys/buttons) → DENY/DISCONNECT → stop capture/encoder → back to
`.listening`. Capture stopped by the system with Screen Recording gone → DISCONNECT(permissionRevoked).
Accessibility is re-checked every ~2 s during a session; if revoked the session drops to view-only.
Password access (0.1.2, off unless a password is set and enabled): after AUTH a capable Viewer is challenged and the
connection takes the session slot without a prompt (`state` stays `.listening`) for `passwordTimeout`; the
operator-deny cooldown is checked only if it falls back to the prompt (a timeout or stale challenge first sends
PASSWORD_RESPONSE(none) to the Viewer). `PasswordAttemptLimiter` (in memory): 5 failures per Viewer fingerprint or per
remote IP within 15 min → 15 min lockout of password attempts (no challenge; the operator is prompted as usual); 30
failures in 10 min overall → challenges paused (prompt only) until they age out; a success clears the fingerprint's
count. Replacing the password (`setAccessPassword`) keeps the current on/off switch; only the first password turns
password access on.
`metrics.pathDescription` is "LAN" / "Loopback" / "Tailscale" from the Viewer's address.

Dropouts (0.1.4): the router stamps every receive; after `inputReleaseAfterSilence` (1 s) without anything from the
Viewer its 200 ms watchdog calls `InputSink.releaseAll()` once and sets `isPeerSilent` (the session is **not** ended;
QUIC's 30 s idle timeout decides that). A session that ends by `.transportEnded` opens `ReconnectGrace` for its
Viewer fingerprint (if `allowsReconnectWithoutPrompt`); a Viewer DISCONNECT, Stop Sharing, Stop Listening, capture
or permission endings do not. At AUTH, a Viewer announcing `sessionResume` whose fingerprint matches the grace entry
— or the active session's fingerprint (a connection from the active Viewer's identity is let past the busy check;
the old session is then ended with DISCONNECT(timeout)) — gets `HostHandshake.Effect.resumeAccepted`: ACCEPT
without prompt or password challenge, `HostPeer.resumed`, `reconnectedNotice`. Revoked by `deny()`,
`stopSharing()`, `stopListening()`, `revokeReconnectGrace()`, the setting off, and (password sessions)
`setPasswordAccessEnabled(false)` / `clearAccessPassword()` / `setAccessPassword(_:)`. ACCEPT's token announces
`sessionResume` while the setting is on. 0.2.0: when the operator revokes a grace from a password session (Require
Approval = `revokeReconnectGrace()`, Stop Sharing, Stop Listening, Deny), or stops a password session whose Viewer is
silent (`isPeerSilent`), that Viewer's next password login within max(grace window, 120 s) gets no challenge and is
prompted instead (one-shot), so its automatic reconnect cannot replay the password past the operator.

Clipboard (0.1.5): `Configuration.clipboardSharing = true` (announce bit 2), `clipboardPollInterval = 250 ms`;
`Dependencies.makePasteboard: @MainActor @Sendable () -> any PasteboardAccess` (default `SystemPasteboard()`);
`var allowsClipboardSharing: Bool` (default true, AppModel persists, live: sends CLIPBOARD_STATE);
`var clipboardStatus: ClipboardSyncStatus` (`.inactive` outside a session); `var pasteboardAccess:
PasteboardAccessBehavior`, `refreshPasteboardAccess()`. A `ClipboardChannel` runs from ACCEPT (only if the Viewer's AUTH
announced the bit) to teardown, with the Host's change count at session start as baseline (earlier copies are not
sent).

Pointer shape (0.1.6): `Configuration.cursorShapes = true` (announce bit 3), `cursorPollInterval = 33 ms`;
`Dependencies.makeCursorSource: @MainActor @Sendable () -> any CursorSource` (default `SystemCursorSource()`);
`var sharesPointerShape: Bool` (default true, AppModel persists, live: off stops sampling and sends
CURSOR_SHAPE(off)); `var cursorShapeStatus: CursorShapeStatus` (`.inactive` outside a session). A
`CursorShapeChannel` runs from ACCEPT (only if the Viewer's AUTH announced the bit) to teardown: the pointer is never
read outside an authorized session or while the switch is off.

### ViewerSession (`@MainActor @Observable final class`) — "Control a Mac"

```swift
let viewer = try ViewerSession.makeDefault()        // or ViewerSession(identity:trustStore:configuration:)

enum ViewerSession.State: Equatable { case idle, connecting(host: String, port: UInt16),
    verifyingHost(HostVerification), awaitingApproval, streaming(StreamInfo),
    reconnecting(ReconnectStatus) /* 0.1.4 */, disconnected(reason: String) }
struct ReconnectStatus: Equatable { stream: StreamInfo; host; port; phase: .waiting(nextAttemptAt:) / .connecting /
    .awaitingApproval; attempt: Int; lostReason; lastError: String?; startedAt; deadline: Date; hostSupportsResume }
struct HostVerification: Equatable { host; port; fingerprint: Data; fingerprintDisplay; fingerprintDisplayFull; firstTime: Bool }
struct StreamInfo: Equatable { hostName; remoteAddress; sessionId: UInt32; hostFingerprintDisplay; isTrusted: Bool;
    viaPassword: Bool /* 0.1.2 */ }

var state: State; var metrics: MetricsSnapshot (≈2 Hz while streaming); var streamConfig: StreamConfig?
var trustedHosts: [TrustedHost]; var pathDescription: String   // "LAN", "Loopback", "Tailscale", "Tailscale (relay: fra)"
var isCapturingInput: Bool { get set }   // mirrors RemoteDisplayView.isCapturingInput; false ⇒ releases held input
var isStreaming: Bool { get }; let fingerprintDisplay: String; let deviceName: String
static let releaseShortcutDescription: String          // "⌃⌥⎋"
let trustStore: TrustedHostStore

func connect(host: String, port: UInt16 = WireConstants.defaultPort,
             password: String? = nil, rememberPassword: Bool = false)   // from .idle / .disconnected only
// 0.1.2: init(identity:trustStore:savedPasswords: SavedHostPasswords = SavedHostPasswords(), configuration:)
var isUsingPassword: Bool; var savedPasswordFingerprints: Set<String>; let savedPasswords: SavedHostPasswords
func hasSavedPassword(_: TrustedHost) -> Bool; func forgetSavedPassword(for: TrustedHost)
func trustHost(remember: Bool)   // in .verifyingHost: remember ⇒ pin fingerprint for host:port; then HELLO+AUTH
func rejectHost()                // in .verifyingHost
func disconnect()                // releases held input, DISCONNECT(userInitiated), → .disconnected("Disconnected")
func attach(renderView: MetalVideoView?)   // weak; RemoteDisplayView also gets onMouse/onScroll/onKey/onFocusChange wired
func attach(frameSink: (any VideoFrameSink)?)
func handleMouse(_:normalized:); func handleScroll(_:); @discardableResult func handleKey(_:) -> Bool
func focusChanged(_ focused: Bool); func releaseAllInput()      // for custom views; RemoteDisplayView is wired automatically
func refreshTrustedHosts(); func forgetTrustedHost(key: String)

struct ViewerSession.Configuration { deviceName; appVersion; establishmentTimeout = 10 s; approvalTimeout = 75 s;
    tailscaleProbeInterval = 15 s; reconnect = ReconnectBackoff.Configuration(); reconnectAttemptTimeout = 4 s /* 0.1.4 */ }
// 0.1.4 dropouts
var autoReconnect: Bool                 // default true (AppModel persists); also gates announcing sessionResume
var isLinkStalled: Bool                 // nothing from the Host for 1 s while streaming ("Poor connection")
var isPresentingStream: Bool { get }    // streaming or reconnecting (keep the stream window); isReconnecting
var lastReconnectedAt: Date?; var hostSupportsResume: Bool   // Host's ACCEPT announced sessionResume
func reconnectNow()                     // skip the wait; disconnect() cancels a reconnect
// 0.1.5 clipboard
// Configuration.clipboardSharing = true; clipboardPollInterval = 250 ms
// init(identity:trustStore:savedPasswords:configuration:makePasteboard: = { SystemPasteboard() })
var sharesClipboard: Bool               // default true (AppModel persists); live
var clipboardStatus: ClipboardSyncStatus; var pasteboardAccess: PasteboardAccessBehavior
func refreshPasteboardAccess(); func syncClipboardNow()
// 0.1.6 pointer shape
// Configuration.cursorShapes = true
var showsRemotePointer: Bool            // default true (AppModel persists); live, local only (the Host keeps sending)
var remotePointerStatus: RemotePointerStatus   // .inactive / .unsupported / .offOnHost / .unavailable / .active
var remotePointer: RemotePointer        // what the attached RemoteDisplayView is told to draw
// 0.1.7 system shortcuts
// init(…, makePasteboard:, shortcutPermission: @MainActor (prompt: Bool) -> Bool = AccessibilityPermission.isTrusted,
//      makeShortcutTap: SystemShortcutTapFactory = { SystemShortcutTap(isArmed:deliver:) })
@discardableResult func send(_ shortcut: SystemShortcut) -> Bool   // Send Keys; false unless streaming
@discardableResult func send(_ chord: KeyChord) -> Bool
var sendsSystemShortcuts: Bool          // default false (AppModel persists); live
var systemShortcutStatus: SystemShortcutCaptureStatus   // .off / .needsPermission / .standby / .active / .unavailable
var shortcutPermissionGranted: Bool
func requestShortcutPermission()        // AX prompt (one-time system alert); never called by the session itself
func refreshShortcutPermission(); func openShortcutPermissionSettings()
// 0.1.8 address book
// init(identity:trustStore:savedPasswords:addressBook: AddressBookStore? = nil /* nil: no history */, configuration:, …);
// makeDefault() passes AddressBookStore.standard() (Application Support/SwiftDesk)
let addressBook: AddressBookStore?
var savedHosts: [SavedHost]             // every saved Host (refreshSavedHosts() re-reads the store)
var savesThumbnails: Bool               // default true (AppModel persists); off deletes saved thumbnails
func renameSavedHost(id:to:) /* "" → Host's name */; func setFavorite(id:_:); func removeSavedHost(id:) /* + thumbnail */
func clearHistory()                     // non-favorites + every thumbnail; favorites stay (lastConnectedAt cleared)
func thumbnailURL(for:) -> URL?; func pinState(of:address:) -> SavedHostPinState   // against `trustedHosts`
func waitForPendingThumbnail() async    // the ended session's thumbnail is written (app quit, tests)
```

UI flow: `.connecting` → (pinned address) `.awaitingApproval` | (not pinned) `.verifyingHost` — show
`fingerprintDisplay` and ask the user to compare it with the Host screen's `HostSession.fingerprintDisplay`; offer
"Trust" (+ "Remember" toggle) / "Cancel" → `.awaitingApproval` → `.streaming` → `.disconnected(reason)` with a
human-readable reason (DENY reasons, Host stop/revoke, connection loss). A pinned address presenting another
certificate ends with `ViewerHandshake.identityChangedMessage` ("Host identity changed: …") and is never re-pinned; the
user resolves it with `forgetTrustedHost(key:)`. The release shortcut (⌃⌥⎋) turns `isCapturingInput` off. Typical
view hookup: create a `RemoteDisplayView`, `viewer.attach(renderView:)`, toggle `viewer.isCapturingInput`, call
`attach(renderView: nil)` when the window closes. `metrics.fps` is on-glass FPS (presented), `receivedFPS` complete
frames from the network, `framesReplacedBeforeDisplay` comes from the attached view.
The Viewer is **not** told when the Host session is view-only (no protocol field); the Host shows it.
Password (0.1.2): HELLO/AUTH announce `passwordAuth`. A PASSWORD_CHALLENGE is answered only in `.awaitingApproval`
(after verification or a matching pin; earlier, while streaming, or a second one ends the attempt with a protocol
error) — with a proof from the typed password, else the one saved for the Host's fingerprint, else `none`. PBKDF2 runs
in a detached task. A typed password is saved (keychain, `SavedHostPasswords`) only with `rememberPassword`, only for
a pinned address whose pin equals the TLS fingerprint, and only after ACCEPT of a password login; a PASSWORD_RESPONSE(none)
from the Host after the challenge (its fallback to the prompt) cancels the proof and clears `isUsingPassword`, so a
later ACCEPT is an ordinary approval. A saved password that gets DENY(authFailed) is deleted. `forgetTrustedHost` also deletes it unless the fingerprint is trusted elsewhere.

Reconnect (0.1.4): a `.streaming` session whose transport fails (`ReconnectPolicy.shouldRetry`: any failure except
the pin mismatch) enters `.reconnecting` with `autoReconnect` on: input released and capture paused, the last frame
kept (`renderView.clear()` skipped), the same address redialed per `ReconnectBackoff` with the TLS fingerprint of the
lost session as the pin (never the trust store, never a verification sheet) and the typed password kept in memory.
DENY(busy) and transport failures of an attempt schedule the next one; any other DENY, DISCONNECT, an identity change,
the approval timeout or the spent 60 s budget end it (`.disconnected`); `disconnect()` cancels. ACCEPT → `.streaming`,
`lastReconnectedAt`, capture restored if it was on and the window is key. `ViewerMediaPipeline` reports link stalls
from the router's `LinkActivity` and uses `RecoveryGate(maxSilentRerequestIntervalNanos: 4 s)`. The router also
passes FEC parity datagrams (`'F'`) to the pipeline (before 0.1.4 it dropped them: FEC never ran on a real Viewer).
Clipboard (0.1.5): at an ACCEPT announcing `clipboard` the router opens the side stream and the session starts a
`ClipboardChannel` (no baseline: the clipboard as it is counts, so copy → focus the stream window → paste works). This
Mac's clipboard is read only while the stream window is the key window of the active app (on
`NSWindow.didBecomeKeyNotification` and the poll); the Host's clipboard is written at any time.
Pointer shape (0.1.6): at an ACCEPT announcing `cursorShape` the session keeps a `RemoteCursorState` (CURSOR_IMAGE
decoded by `CursorRendering.pointerImage`, ignored if it does not decode to the announced size) and pushes the result
to `RemoteDisplayView.remotePointer` (and `remoteDisplayPointSize` from CONFIG); teardown and reconnect reset it to
`.standard`.
System shortcuts (0.1.7): `send(_:)` works whether or not input is captured (the controller releases anything held
first). The keyboard tap is created lazily and installed only while
`SystemShortcutCaptureStatus.shouldArm(enabled: sendsSystemShortcuts, permitted: Accessibility, streaming:
isStreaming, capturing: isCapturingInput, focused: the RemoteDisplayView has input focus and NSApp is active)`;
re-evaluated on every change of the switch, capture, focus (`focusChanged`) and `state`, so it is removed on capture
off / ⌃⌥⎋, resign key, app deactivation, reconnect and teardown. Accessibility is re-checked without prompting whenever
the tap would arm. Taken events go through `ViewerInputController.handleKey(TapKeyEvent)`; one arriving after the
session disarmed is dropped. `SystemShortcutCaptureStatus` and `SystemShortcutTapFactory` live in
`SessionCore/SystemShortcutCapture.swift`. AppUI imports InputCore for `SystemShortcut` (transitive, like the others).
Address book (0.1.8): at `.startStreaming` of a new (not resumed) stream the session calls
`AddressBookStore.recordConnection(host:port:fingerprint: <TLS-observed>, hostName: <sanitized ACCEPT name>)` and keeps
the entry id through a reconnect. With an address book and `savesThumbnails`, `FrameSinkSlot.deliver` (the decode
queue's existing per-frame lock) also remembers the newest decoded frame; when the stream ends (`finish`, from
streaming or reconnecting: user, Host, failure) the session takes it and a detached task encodes it with
`SessionThumbnail.jpeg` (≤ 320 px long edge, quality 0.7), written only if the switch is still on. Teardown without
`keepPicture` drops the frame. Entries are never pins: a saved Host is dialed with the ordinary `connect`.

### LoopbackSession (`@MainActor @Observable final class`) — Milestone A

```swift
let loopback = LoopbackSession()                     // init(makeSource:) injectable
enum LoopbackSession.Source: Equatable { case screen(displayID: CGDirectDisplayID?), synthetic(width: Int, height: Int) }
struct LoopbackSession.Options: Equatable { source = .screen(displayID: nil); capture = CaptureConfig(); bitrateKbps = 3000;
    packetize = false; simulatedLossPercent = 0; forwardErrorCorrection = true }   // loss and FEC apply only with packetize
enum LoopbackSession.State: Equatable { case idle, starting, running, failed(String) }
var state: State; var metrics: LoopbackMetrics; var options: Options
func attach(renderView: MetalVideoView?); func attach(frameSink: (any VideoFrameSink)?)
func start(options: Options) async; func stop() async

struct LoopbackMetrics: Equatable { capturedFPS, encodedFPS, decodedFPS, presentedFPS, bitrateKbps: Double;
    captureToEncodeDone, encodeDoneToDecodeDone, decodeToPresent, captureToPresent: RollingStats.Summary;
    framesCaptured, framesEncoded, framesDecoded, encoderBackpressureDrops, framesLost, keyframeRequests,
    decodeFailures, framesReplacedBeforeDisplay, simulatedPacketsDropped, fecFragmentsRecovered: UInt64;
    fecGroupSize, width, height: Int;
    hardwareEncoder, lowLatencyRateControl, hardwareDecoder: Bool? }
```
`.screen` needs Screen Recording; failure → `.failed("Screen Recording permission is required")`.

### Pure / supporting API

```swift
struct AdaptationController { struct Rung { width; height; fps; maxBitrateKbps: Int?; minBitrateKbps: Int? }
    static let defaultLadder   // Sharp (0.1.3): ≤1920×1080@60, 1280×720@60, 960×540@60, 960×540@30 (bounds; ranges from bounds)
    static let balancedLadder  // 1280×720@60, 960×540@60, 960×540@30 (no per-rung range: the global one)
    static func bitrateCeilingKbps(width:height:fps:) -> Int   // 5000 × (pixel rate / 720p60)^1.1, 250-kbps steps
    static func bitrateFloorKbps(ceilingKbps:) -> Int          // 40 % of the ceiling (non-bottom rungs)
    struct Configuration { min/max bitrate 1000/12000 (Balanced 1000/5000); initial nil = 60 % of rung 0's ceiling,
        at most initialBitrateMaxKbps 4000 (Balanced: 3000); scalesBitrateToPicture; decreaseFactor 0.7 (cuts always
        continue to the global floor); decreaseCooldown 1 s;
        +max(250, 5 % of the rung ceiling) kbps per 2 s clean;
        congested: loss ≥ 5 %, RTT inflation > max(50 ms, minRTT), backlog > 350 ms at the target bitrate, any send drop,
        viewer fps < 0.6× sent; clean: loss < 1 %, inflation < max(20 ms, 0.5×minRTT), backlog ≤ 85 ms; encoder overload
        > 15 % drops; stepDownAfter 3 s (≥ 3 congested ticks at/below the rung's floor, none more than
        congestionMemory 5 s apart — or 3 s overloaded; bitrate clamped to the new rung's ceiling); stepUpAfter 10 s
        clean and bitrate ≥ min(current ceiling, 0.6 × target rung ceiling); each encoder-overload step-down from a rung
        doubles the clean time to return to it (max ×8), the 3rd blocks it for the session
        static var sharp; static var balanced
        func resolved(sourceWidth:sourceHeight:) -> Configuration   // per-rung ranges from the *encoded* size; drops
                                                                    // rungs that fit to the same size+fps }
    struct Inputs { nowNanos; lossPercent?; rttMillis?; minRTTMillis?; sendBacklogBytes; encoderBackpressureDrops;
        sendBackpressureDrops; viewerFPS?; hostSentFPS? }
    struct Decision { bitrateKbps; rung; rungIndex; bitrateChanged; rungChanged; condition: .congested/.neutral/.clean; signals }
    init(configuration:initialRungIndex:); var bitrateKbps; var rungIndex; var rung; var currentCeilingKbps;
    var currentFloorKbps; var stepUpGateKbps; var stepUpCleanNanos: UInt64?; mutating func update(_:) -> Decision }
enum StreamQuality: String, CaseIterable { case sharp, balanced   // 0.1.3 Host › Display › Quality
    func adaptation(base:) -> AdaptationController.Configuration; func streamSize(displayPixelWidth:displayPixelHeight:base:) }
struct TrustedHost: Codable, Identifiable { key /* "host:port" */; fingerprintHex; name; addedAt; var fingerprint: Data? }
final class TrustedHostStore: @unchecked Sendable { init(defaults: UserDefaults = .standard, storageKey:);
    static func key(host:port:) -> String; list(); entry(host:port:); pinnedFingerprint(host:port:) -> Data?;
    contains(fingerprint:) -> Bool; @discardableResult add(host:port:fingerprint:name:now:); rename(key:to:);
    remove(key:); remove(host:port:); removeAll(); static hex(_:) / data(fromHex:) }
struct HostHandshake / struct ViewerHandshake      // pure handshake reducers returning effects (used by the sessions; unit-tested)
    // 0.1.2: HostHandshake.Phase.awaitingPassword(Hello, PasswordChallenge); Effect .sendChallenge / .passwordAccepted /
    // .fallbackToPrompt(Hello); PasswordGate .disabled / .lockedOut (→ prompt) / .available(challenge);
    // receive(_:screenRecordingGranted:password:verifyProof: (Data, PasswordChallenge) -> HostAccessPassword.ProofResult);
    // passwordTimedOut() -> .fallbackToPrompt; 0.1.4: receive(…, resume: Bool) → .resumeAccepted(Hello) for a
    // `sessionResume` Viewer (after version/binding/Screen Recording, before any challenge or prompt).
    // ViewerHandshake Effect .answerChallenge(challenge, hostFingerprint:) /
    // .declineChallenge / .passwordFallback.
enum AccessPassword { minimumLength = 8; defaultIterations = 1_000_000; acceptedIterations = defaultIterations...5_000_000;
    deriveKey(password:salt:iterations:); proof(key:nonce:hostFingerprint:viewerFingerprint:);
    verify(proof:key:nonce:hostFingerprint:viewerFingerprint:) /* constant time */; answer(_:password:hostFingerprint:viewerFingerprint:) }
protocol SecretStore; final class KeychainSecretStore(service:) /* generic password, AfterFirstUnlockThisDeviceOnly */; InMemorySecretStore
final class HostAccessPassword { init(store: = KeychainSecretStore(service: "com.swiftdesk.access-password"), iterations:);
    isConfigured; isEnabled; set(password:) throws /* keeps the enabled flag of an existing record */; setEnabled(_:) throws;
    clear(); challengeParameters(); check(proof:challenge:hostFingerprint:viewerFingerprint:) -> ProofResult (.valid / .invalid / .stale);
    verify(proof:challenge:hostFingerprint:viewerFingerprint:); verify(proof:nonce:hostFP:viewerFP:) }
    // keychain blob (54 B): u8 version 1, u8 enabled, u32 iterations, 16 salt, 32 key
final class SavedHostPasswords { init(store: = KeychainSecretStore(service: "com.swiftdesk.host-password")) /* account = fingerprint hex */ }
struct PasswordAttemptLimiter { check(fingerprint:address:nowNanos:) -> .allowed / .lockedOut / .passwordDisabled;
    recordFailure(fingerprint:address:nowNanos:); recordSuccess(fingerprint:nowNanos:) }
// 0.1.5 clipboard (Sources/SessionCore/ClipboardPolicy.swift, ClipboardChannel.swift)
enum PasteboardAccessBehavior { unrestricted /* < macOS 15.4 */, default, ask, alwaysAllow, alwaysDeny; mayPrompt;
    static settingsURL /* Privacy_Pasteboard anchor, unverified */; static openSettings() }
@MainActor protocol PasteboardAccess { changeCount; types /* metadata, no prompt */; accessBehavior;
    data(forType:) /* the read macOS may prompt for */; write(_ representations:) -> Int }
@MainActor final class SystemPasteboard: PasteboardAccess   // NSPasteboard.general
enum ClipboardPolicy { concealedType, transientType, autoGeneratedType, originMarkerType ("com.swiftdesk.remote-clipboard");
    screen(types:) -> SkipReason? /* .privateContent / .fromPeer / .files / .unsupported */;
    snapshot(_:types:) /* main actor */; content(from:encodePNG:) -> ReadOutcome /* caps; .tooLarge */;
    pngFromTIFF(_:); representations(for:) /* + origin marker; lone URL also as text */ }
struct ClipboardEchoGuard { init(baseline:); shouldExamine(changeCount:); noteWritten(changeCount:); rebase(_:) }
struct ClipboardSyncStatus { peerSupports; peerEnabled; localEnabled; accessDenied; notice: ClipboardNotice?;
    lastTransfer: ClipboardTransfer?; isActive; static inactive }
struct ClipboardNotice { kind: .tooLarge(bytes:limit:) / .filesNotShared / .accessDenied; id; at }
protocol ClipboardTransport { sendControl(_:); sendSide(_:completion:) -> Bool }   // PeerConnection conforms
// internal: ClipboardChannel (main actor, one per session: polls changeCount, reads only when changed + active +
// allowed, TIFF→PNG off the main actor, one CLIPBOARD in flight / latest wins, drops CLIPBOARD while off here;
// 0.2.0: a received CLIPBOARD drops a local copy still waiting or converting; a read whose changeCount moved
// between screening and contents is discarded)
// 0.1.6 pointer shape (Sources/SessionCore/CursorShapePolicy.swift, CursorShapeChannel.swift)
struct CursorSnapshot { pixelWidth; pixelHeight; rgba /* premultiplied RGBA8, top row first */; pointSize; hotSpot;
    isFullyTransparent; fingerprint /* FNV-1a 64 over geometry + pixels */ }
enum CursorObservation { unavailable, hidden, image(CursorSnapshot) }
struct CursorShapeTracker { init(capacity: = 32); observe(_:encodePNG:define:) -> CursorShape? /* only on change;
    define nil = side stream not open: new shapes wait */; switchedOff(); forgetLastSent(); lastSent; definedCount }
struct RemoteCursorState<Image> { init(capacity: = 64); define(id:image:) -> Bool; apply(_:) -> Bool; appearance
    (.standard / .hidden / .image(id:, Image)); shape; isWaitingForDefinition }
enum CursorRendering { snapshot(image:hotSpot:) /* ≤ 2×, ≤ 256 px */; cgImage(_:); png(_:); pointerImage(_:) }
@MainActor protocol CursorSource { observe() -> CursorObservation }
@MainActor final class SystemCursorSource   // NSCursor.currentSystem (+ CGCursorIsVisible via dlsym, transparent = hidden)
struct CursorShapeStatus { peerSupports; enabled; isActive; static inactive }
enum RemotePointerStatus { inactive, unsupported, offOnHost, unavailable, active }
// internal: CursorShapeChannel (main actor, one per Host session: samples ≈ 30 Hz while enabled, CURSOR_IMAGE via
// sendSide then CURSOR_SHAPE via sendControl, `.off` once when switched off; reuses `ClipboardTransport`)
// 0.1.8 address book (Sources/SessionCore/AddressBook.swift, SessionThumbnail.swift)
struct SavedHostAddress: Codable, Hashable { host; port; key /* TrustedHostStore.key */; endpoint; shareable(defaultPort:) }
struct SavedHost: Codable, Identifiable { id: UUID; customName: String?; hostName; addresses /* most recent first */;
    fingerprintHex /* TLS identity of the last connection; the entry's identity, not a pin */; addedAt;
    lastConnectedAt: Date?; isFavorite; thumbnailUpdatedAt: Date? /* file = Thumbnails/<id>.jpg, never stored */;
    displayName; primaryAddress; hasThumbnail; fingerprint: Data?; pinState(of:trusted:) -> SavedHostPinState }
enum SavedHostPinState { pinned, unpinned, pinnedToOtherIdentity }
struct SavedHostSections { init(_:); favorites /* by name */; recent /* non-favorites, newest first */ }
final class AddressBookStore: @unchecked Sendable { init(directory:recentLimit: = 20); static defaultDirectory()
    /* ~/Library/Application Support/SwiftDesk */; static standard(); list(); sections(); entry(id:) / entry(fingerprint:)
    / entry(host:port:); @discardableResult recordConnection(host:port:fingerprint:hostName:now:) -> SavedHost;
    rename(id:to:); setFavorite(id:_:); remove(id:); clearHistory(); saveThumbnail(_:for:now:) -> Bool;
    removeAllThumbnails(); removeAll(); thumbnailURL(for:); thumbnailData(for:); maxAddressesPerHost = 8 }
    // AddressBook.json {version: 1, hosts: [SavedHost]} + Thumbnails/<uuid>.jpg; atomic writes,
    // .completeFileProtectionUntilFirstUserAuthentication, 0600 files / 0700 folders, thumbnails excluded from backup;
    // merge by fingerprint; an address belongs to one identity (moves; an entry left without addresses is deleted);
    // non-favorites capped (oldest evicted with its thumbnail); entries decoded one by one (0.2.0): an undecodable
    // entry or file is renamed aside (AddressBook.unreadable-<date>.json) before the first save, and orphaned
    // thumbnails are only removed after a clean load; a future-version file reads as empty and is never overwritten;
    // load drops invalid entries. No secrets (passwords stay in SavedHostPasswords).
enum SessionThumbnail { maxPixels = 320; jpegQuality = 0.7; jpeg(from: CVPixelBuffer) / jpeg(from: CGImage) -> Data?
    /* VTCreateCGImageFromCVPixelBuffer → CGContext → ImageIO */; scaledSize(width:height:maxPixels:) }
struct KeyframeRequestLimiter                      // host: ≥ 100 ms between honored requests, suppressed ~1 RTT (100–400 ms, 0.1.4 cap) after a keyframe
// 0.1.4 dropout policies (pure, Sources/SessionCore/ConnectionResilience.swift)
struct LinkSilenceDetector { init(thresholdNanos: = 1 s); isSilent; update(lastHeardNanos:nowNanos:) -> .silent / .resumed / nil }
struct ReconnectBackoff { Configuration { initialDelay 0.5 s; maxDelay 8 s; budget 60 s }; attempts;
    nextDelay(elapsed:) -> Duration? /* nil = give up */; static schedule(_:) }   // 0.5, 1, 2, 4, 8, 8, … (sum ≤ 60 s)
enum ReconnectPolicy { shouldRetry(after: PeerConnectionState); shouldRetry(after: DenyReason) /* busy only */ }
struct ReconnectGrace { init(window: = 120 s); entry; sessionDropped(_:); revoke(); current(nowNanos:);
    allowsResume(fingerprint:capabilities:enabled:passwordAccessEnabled:nowNanos:); consume() }
enum KeyframeRequestReason: UInt8 { unspecified, frameLoss, decodeError, stillWaiting }   // REQUEST_KEYFRAME(reason:) values
enum SecureRandom { bytes(_:), sessionId(), sessionToken() }
enum SessionSupport { computerName(), appVersion(), hostPart(of:), pathLabel(forHost:), shouldProbeTailscale(host:) }

// Dependency-injection seams (production conformances are provided)
protocol VideoSource: AnyObject, Sendable { onFrame; onStopped; outputSize; displayFrame;
    predictedOutputSize(for:) /* size update(config:) would give on the display's current mode */;
    start() async throws; update(config:) async throws; stop() async }   // ScreenCapturer conforms
final class SyntheticVideoSource: VideoSource                    // 420v IOSurface frames on a strict timer; no TCC needed
protocol InputSink: AnyObject, Sendable { handle(_:); handlePointer(_:); setAuthorized(_:); updateDisplayFrame(_:);
    releaseAll(); var canInject: Bool }                          // HostInputInjector conforms
protocol SessionTransport: AnyObject, Sendable { sendControl(_:); sendDatagrams(_:) -> Bool;
    sendDatagrams(_:maxQueuedAheadBytes:) -> Bool /* default: ignores the bound */; pendingDatagramBytes;
    maxDatagramSize }                                            // PeerConnection conforms
// HostMediaPipeline bounds each batch: ≤ 80 ms of video at the target bitrate + the undrained part of the last keyframe
// may be queued ahead (`allowedBacklogAhead`). AdaptationController's backlog thresholds are in ms (350 congested / 85 clean).
// HostInjectionEngine defers pointer states whose buttonsMask disagrees with its held buttons until the reliable button
// event arrives (bounded by 64 seqs).
protocol VideoFrameSink: AnyObject { func enqueue(_ frame: any RenderableFrame) }   // MetalVideoView conforms
struct PermissionChecker: Sendable { screenRecordingGranted, accessibilityGranted: @Sendable () -> Bool; static let system }
```

Wire-level choices made by SessionCore: the Host also sends PING every 500 ms (the Viewer echoes PONG) so the Host has
its own RTT for adaptation; the Viewer sends PING every 500 ms and STATS every 1 s (`packetsReceived` counts data and
parity datagrams; `packetsLost` = fragments rebuilt from parity + lost frames × average datagrams per frame, see
`FrameReassembler.Stats.lossEstimate`). The Host feeds that loss to `FECPolicy` (K for the next frames) as well as to
the adaptation controller. Keyframe datagrams are sent twice by default (the reassembler drops duplicates)
so on-demand recovery survives random loss. When the transport refuses a frame, its frame id is still consumed so
the Viewer detects the gap; the Host then sends no P-frames until a keyframe went out.

## Integration notes (added in the integration pass)

- **ScrollEvent phases on the wire** carry `NSEvent.Phase` raw bits (began 1, stationary 2, changed 4, ended 8,
  cancelled 16, mayBegin 32), for both `phase` and `momentumPhase`. The Host converts them to `CGScrollPhase` /
  `CGMomentumScrollPhase` (`InputCore/HostInjectionEngine`). Never put CoreGraphics phase values on the wire.
- **Transport preamble.** TransportCore prefixes the control stream with an 8-byte preamble (`"SDQ1"`, version,
  role, 2 reserved) before WireProtocol framing, so a Viewer reports `.ready` only after the Host accepted it
  (`docs/TRANSPORT.md` §3). Invisible to other modules.
- **Callbacks in a `Mutex`.** Never store an optional closure directly as `Mutex<Closure?>` and read it with
  `withLock { $0 }`: each read wraps it in another reabstraction thunk and the chain overflows the stack after ~1M
  reads. Store it in a struct field (`Mutex<Callbacks>`) or a final class box. All modules now follow this.
- **Signposts** (`PipelineSignpost`, subsystem `com.swiftdesk.app`, Points of Interest): `capture` is emitted by the
  source (ScreenCapturer / SyntheticVideoSource), `encoded` by H264Encoder, `netSend` / `netRecv` by the session
  pipelines, `decoded` by H264Decoder, `presented` by RenderCore's presented handler, and `input` (sequence number
  only, never key codes or positions) on Viewer send and Host receive.
- **`DisplayInfo.activeDisplayIDs()`** falls back to online, non-mirrored displays when every display is asleep.
- **AppUI public API** (`AppModel`, `SwiftDeskScenes`, `SwiftDeskAppDelegate`, `RootView`, presentation helpers) is
  listed in the AppUI module report and documented in the source; it has no consumers outside the app target.
- **Suggested Package.swift changes (not made):** `.testTarget(name: "AppUITests", dependencies: ["AppUI"])` (AppUI
  tests currently run through the Xcode project), `.testTarget(name: "PipelineBenchTests", dependencies:
  ["PipelineBench"])`, explicit AppUI dependencies on the modules it imports transitively, `DiagnosticsCore` for
  InputCore, and renaming the `SwiftDesk` executable product to avoid a second "SwiftDesk" scheme in Xcode.
