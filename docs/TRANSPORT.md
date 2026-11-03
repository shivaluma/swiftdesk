# SwiftDesk transport (TransportCore)

Status: **Milestone B transport validated on loopback** (macOS 27, Xcode 27.2, Swift 6.4, Apple silicon Mac mini).
The single-connection design required by `docs/CONTRACT.md` works: **one QUIC connection per session** carrying a
reliable bidirectional control stream plus unreliable QUIC DATAGRAM frames, with mutual TLS 1.3 using self-signed
device certificates pinned by SHA-256 fingerprint. The documented fallback (two QUIC connections bound by a session
token) was **not needed**.

Reproduce everything below with:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product QUICSpike --scratch-path .build/agent-transport
.build/agent-transport/release/QUICSpike --raw          # step 1: raw Network.framework exploration
.build/agent-transport/release/QUICSpike --raw --wrong-pin | --client-noid | --no-server-extract | --no-client-handler
.build/agent-transport/release/QUICSpike                # step 3: end to end through TransportCore (≈27 s, incl. 15 s idle)
swift test --filter TransportCoreTests --scratch-path .build/agent-transport
```

The spike creates uniquely labelled keychain identities and deletes them on exit.

---

## 1. Validated Network.framework usage

All APIs below were checked against the macOS SDK swiftinterface/headers and exercised by `QUICSpike`.
(The macOS 26+ `NetworkConnection<QUIC>` Swift API exists in the SDK but is unavailable on our macOS 15 deployment
target, so the classic `NWConnectionGroup` API is used.)

### QUIC/TLS options (both roles) — `QUICConfiguration.groupOptions`

```swift
let o = NWProtocolQUIC.Options(alpn: ["swiftdesk/1"])
o.idleTimeout = 30_000                 // ms (0.1.4; 10_000 before, see "Dropouts" below)
o.maxDatagramFrameSize = 65_535        // enables RFC 9221 DATAGRAM; usable size is read back later
o.direction = .bidirectional
let sec = o.securityProtocolOptions
sec_protocol_options_set_local_identity(sec, sec_identity_create(identity.secIdentity)!)
sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
sec_protocol_options_set_peer_authentication_required(sec, true)        // host only
sec_protocol_options_set_verify_block(sec, { metadata, trust, complete in
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
    let fp = leaf.map { SHA256(SecCertificateCopyData($0)) }
    complete(/* host: fp != nil ; viewer: pin == nil ? fp != nil : fp == pin */)
}, verifyQueue)
let parameters = NWParameters(quic: o)
parameters.serviceClass = .interactiveVideo
```

### Host

```swift
let listener = try NWListener(using: parameters, on: port)          // port 0 => ephemeral works
listener.service = NWListener.Service(name: deviceName, type: "_swiftdesk._udp")   // Bonjour works
listener.newConnectionGroupHandler = { group in
    // remote address available here, BEFORE the handshake: (group.descriptor as? NWMultiplexGroup)?.members.first
    group.newConnectionHandler = { stream in ... }                   // incoming QUIC streams
    group.stateUpdateHandler = { state in
        if case .ready = state {
            // peer certificate: group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
            //   -> .securityProtocolMetadata -> sec_protocol_metadata_access_peer_certificate_chain
            let dg = NWProtocolQUIC.Options(alpn: [alpn]); dg.isDatagram = true
            let datagramFlow = group.extract(connectionTo: nil, using: dg)!   // host extracts its own flow
            datagramFlow.start(queue: q)
        }
    }
    group.start(queue: q)
}
listener.start(queue: q)
```

### Viewer

```swift
let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: h, port: p)), using: parameters)
group.newConnectionHandler = { $0.cancel() }      // REQUIRED, see gotcha 2
group.stateUpdateHandler = { ... }
group.start(queue: q)
// on .ready:
let control = NWConnection(from: group)!                                   // bidirectional stream (id 4)
let dg = NWProtocolQUIC.Options(alpn: [alpn]); dg.isDatagram = true
let datagramFlow = NWConnection(from: group, to: nil, using: dg)!          // group.extract(...) also works
// datagramFlow metadata: (… as? NWProtocolQUIC.Metadata)?.usableDatagramFrameSize
```

Datagrams: `flow.batch { flow.send(content:completion:) … }` to send, `flow.receiveMessage` to receive (one
datagram per completion). Keepalive: `(group.metadata(definition: NWProtocolQUIC.definition) as?
NWProtocolQUIC.Metadata)?.keepAlive = .seconds(3)` after `.ready` — verified: a connection idle for 15 s with a
10 s idle timeout stays up (measured with the 10 s value; 0.1.4 raised it to 30 s).

`NWParameters.quicDatagram(alpn:)` was also checked: it returns parameters whose `defaultProtocolStack.transportProtocol`
is an `NWProtocolQUIC.Options` with `isDatagram == true` and `maxDatagramFrameSize == 0` (its
`applicationProtocols` is empty, so configure TLS through `transportProtocol`). A plain `NWConnection` with it
connects to our listener (usable size 9156 on loopback), but it gives a datagram-only connection without a
control stream, so it is not used.

## 2. Gotchas found empirically

1. **QUIC listener + both handlers ⇒ EINVAL.** Setting `newConnectionHandler` *and* `newConnectionGroupHandler` on
   an `NWListener(using: NWParameters(quic:))` makes it fail immediately with
   `POSIXErrorCode(rawValue: 22): Invalid argument`. Set only `newConnectionGroupHandler`. (Took a bisection of every
   TLS/QUIC option to find; none of them were at fault.)
2. **Client group without `newConnectionHandler` never starts.** A client `NWConnectionGroup(with: NWMultiplexGroup…)`
   whose `newConnectionHandler` (or receive handler) is unset stays in `.setup` forever — no error, no handshake
   (`--raw --no-client-handler`).
3. **Host must extract its datagram flow itself, immediately at group `.ready`.** If it doesn't, the client's
   datagram flow surfaces later through `group.newConnectionHandler` (a flow whose
   `usableDatagramFrameSize > 0`) only after the first datagram arrives, and datagrams before that are lost:
   385/2000 delivered in `--raw --no-server-extract` vs 2000/2000 with the host extracting. TransportCore still
   accepts such an implicit flow as a second datagram source, defensively.
4. **Wrong pinned fingerprint: the client group never fails.** When the viewer's verify block returns false the
   *server* group goes to `.failed(EINVAL)`, but the client group stays in `.setup` indefinitely. TransportCore
   reports the mismatch from inside the verify block (fails the connection immediately: observed 90 ms) and also has
   an establishment timeout (default 10 s).
5. **TLS 1.3 ordering: the client is "ready" before the server has accepted it.** The client finishes its handshake
   one flight before the server verifies the client certificate, and opening a QUIC stream/datagram flow is local.
   With no client identity the client group reaches `.ready`, then fails a few ms later when the server rejects it
   (`--raw --client-noid`). A host that cancels a rate-limited group would otherwise look connected to the viewer.
   → TransportCore exchanges an 8-byte **transport preamble** on the control stream (section 3); the viewer is
   `.ready` only after the host's reply.
6. **The server sees an extra idle stream.** Besides the control stream (stream id 4), the host's
   `newConnectionHandler` receives one more flow that never carries data and only turns `.ready` (stream 0) at
   teardown. It is harmless; TransportCore leaves it unread. The control stream is identified as the stream that
   delivers the viewer's preamble.
7. **Transient `.waiting(ENETDOWN)` before `.ready`.** Both groups briefly report
   `waiting(POSIXErrorCode(rawValue: 50): Network is down)` on loopback right before `.ready`; it is ignored (the
   establishment timeout bounds real failures). It costs ~80–100 ms per side, which is most of the ~160–190 ms
   loopback connect time. Not yet measured on a real LAN.
8. **Server group failure after a graceful close is `.failed(EINVAL)`**, not `.cancelled`. TransportCore maps a
   failure after a received DISCONNECT (or local close) to `.closed`.
9. **Keychain: `kSecAttrLabel` is ignored for certificates** in the file-based login keychain (the label becomes the
   subject CN). The certificate is therefore found through `kSecAttrPublicKeyHash`, which equals the private key's
   `kSecAttrApplicationLabel`. (An early version looked certificates up by label and leaked orphan certificates;
   they were found and removed.)
10. **SecTrust does not check an anchor's own signature** — self-anchoring a certificate validates dates and
    extensions only. The unit tests verify the ECDSA signature over the TBSCertificate directly.

## 3. TransportCore design

```
Viewer                                             Host
NWConnectionGroup ──── one QUIC connection (mTLS 1.3, ALPN swiftdesk/1) ──── NWListener → NWConnectionGroup
  control stream  ── "SDQ1" v1 viewer ─────────────────────────────────────▶ (identifies the control stream)
                  ◀────────────────────────────────── "SDQ1" v1 host ──────  (host accepted: viewer → .ready)
                  ⇄ [u32 len][u8 type][payload] … (WireProtocol ControlFraming / ControlStreamDecoder)
  datagram flow   ⇄ QUIC DATAGRAM frames (video fragments + FEC parity host→viewer, pointer state viewer→host)
  side stream     ── "SDQ1" v1 viewer kind=1 ──────────────────────────────▶ (0.1.5, optional: bulk payloads)
                  ⇄ [u32 len][u8 type][payload] … (only side-stream types, e.g. CLIPBOARD)
```

- **Transport preamble** (`TransportPreamble`, 8 bytes): `53 44 51 31` ("SDQ1"), version `1`, role (`1` viewer,
  `2` host), stream kind (`0` control; `1` side stream, 0.1.5), `00`. Exchanged before any framed control message; any other first 8 bytes close the connection
  ("Peer is not a compatible SwiftDesk endpoint"). This is internal to TransportCore and invisible to other modules;
  it adds one RTT to connection setup.
- **States.** Viewer: `.connecting` → `.ready` once TLS completed, the pin (if any) matched, the datagram flow is up
  and the host's preamble arrived. Host: a `PeerConnection` is handed to `HostListener.onIncoming` only when TLS
  completed with a client certificate (fingerprint known), the datagram flow is up and the viewer's preamble
  arrived; it is silent until the owner calls `start()`, which reports `.ready` once and starts callbacks. Bytes
  that arrive before `start()` stay in QUIC flow control (or a small stash) and are delivered in order afterwards.
- **Threading.** One private serial transport queue per connection runs every Network.framework handler and every
  callback (`onStateChange`, `onControlMessage`, `onDatagram`, `onProtocolError`). `sendDatagrams`/`sendControl` are
  called directly on the producer's queue — no hop, no `Task`: NWConnection sends are thread-safe; the shared state
  they touch is a `Mutex` (flow references, published state, pending control queue) or `Atomic`s (backlog bytes,
  counters, loss setting).
- **Datagram send path.** `sendDatagrams([Data])` → one `Mutex` read for the flow, backlog check, one `batch {}` with
  `.idempotent` completions for all but the last datagram and a single `.contentProcessed` completion for the batch
  that subtracts its bytes from `pendingDatagramBytes`. Whole batches (frames) are refused when
  `pending + batch > maxBacklogBytes` (default 1 MiB since 0.1.3, was 256 KiB) — except when nothing is pending, so a keyframe larger than
  the limit is never starved. Refused batches are counted (`stats.datagramBatchesDroppedBackpressure`); the caller
  treats `false` as backpressure (skip to a keyframe). No pacing or congestion bypass: QUIC congestion control applies
  to DATAGRAM frames.
- **FEC parity (recovery pass).** The Host appends each frame's XOR parity datagrams (WireProtocol magic `'F'`,
  `docs/CONTRACT.md`) to the same `sendDatagrams` batch, after the data fragments, so a frame and its parity are
  accepted or refused as one unit and the backlog accounting covers parity bytes too. TransportCore itself is
  unchanged: it never inspects datagram contents. Parity adds roughly 1/K to the datagram rate (≈ +17–44 % at the
  K values in use at 720p / 3 Mbit/s); on a congested link that shows up in `pendingDatagramBytes` and the
  adaptation controller lowers the encoder bitrate as before.
- **Datagram receive path.** `receiveMessage` is re-armed *before* the datagram is handed to `onDatagram`; the
  handler runs on the transport queue and must only enqueue work.
- **Control path.** Messages are framed with `ControlFraming.frame`, queued (≤ 256) while the stream is not yet
  established and flushed in order under the same lock `sendControl` takes. Received bytes go through one
  `ControlStreamDecoder`; any decode error calls `onProtocolError`, sends `DISCONNECT(protocolError)` and closes.
- **close(reason:)** is idempotent; when ready and a reason is given it sends `DISCONNECT(reason)` and tears down
  after the send completes (+50 ms) or 300 ms at most. No data callbacks are delivered after `close` begins.
- **`simulatedDatagramLossPercent`** (debug): send-side random drop per datagram, 0 by default (no RNG on the hot
  path when 0).
- **maxDatagramSize** = `min(usableDatagramFrameSize, WireConstants.defaultMaxDatagramSize = 1150)`; loopback
  reports 9156 (client) / 9164 (server), so 1150 is used. Real paths (Wi-Fi 1500, Tailscale 1280) are expected to
  report less than loopback but ≥ 1150 on Ethernet/Wi-Fi; unverified on Tailscale.

### Security model

- Every device has a long-lived **self-signed P-256 certificate** (X.509 v3, random 128-bit serial,
  CN "SwiftDesk <hostname>", O "SwiftDesk", ~10-year validity starting one day in the past, basicConstraints
  cA=false critical, keyUsage digitalSignature critical, extKeyUsage serverAuth+clientAuth, SKI), DER-encoded by a
  small internal encoder (`DER.swift`) and signed with `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)`.
  Identity = SHA-256 of the certificate DER. Display: first 16 bytes as 8 groups of 4 uppercase hex digits.
- **Mutual TLS 1.3**: both sides present their identity; the host requires a client certificate
  (`peer_authentication_required`). TLS proves possession of the private key for the presented certificate.
- **Host verify block** accepts any well-formed client certificate; the fingerprint (read from the connection's
  security metadata after the handshake) is what the operator approves and what AUTH binds (session layer).
- **Viewer verify block**: with a pinned fingerprint, anything else fails the handshake (and the connection fails
  fast); without a pin the handshake succeeds and `peerFingerprint` is recorded — the session layer must obtain
  explicit user trust before sending HELLO. The pin is re-checked against the metadata after `.ready`.
- **Rate limiting** (`ConnectionRateLimiter`, token buckets: 6/min per remote IP, 30/min global) runs in
  `newConnectionGroupHandler`, **before** the group is started, so a refused attempt costs no TLS work. A refused
  viewer sees `failed("Connection timed out")` after its establishment timeout (the host does not answer).
- No unauthenticated control channel: the control stream exists only inside an established mTLS connection, and the
  host ignores control bytes until the connection is handed out and started.
- Logging is lifecycle-only (`Log.transport`): no payloads, keystrokes, key codes, clipboard, fingerprints or
  peer addresses.

### Password access (0.1.2, session layer)

TransportCore is unchanged; this note records how the opt-in password feature sits on top of the mTLS channel
(full spec: `docs/CONTRACT.md`, "Password access").

- **Channel binding.** The proof is `HMAC-SHA256(PBKDF2 key, "swiftdesk-password-v1" ‖ nonce ‖ hostFP ‖ viewerFP)`
  over the fingerprints read from this connection's TLS metadata (`peerFingerprint` on each side). A proof captured
  or relayed by a man in the middle is useless: it would present another certificate, so the Host's fingerprint (or
  the Viewer's) in the MAC differs, and the nonce is fresh per connection.
- **Order of checks.** Rate limiting (`ConnectionRateLimiter`) and mTLS happen first, unchanged. The Viewer verifies
  the Host's fingerprint (pin or user comparison) before HELLO, so a password proof is never computed for an
  unverified Host. The Host checks AUTH channel binding before it issues a challenge.
- **Wire compatibility.** New control types 17/18 and `DenyReason.authFailed` (8) are only sent to a Viewer that set
  the `"SDC1"` capability marker in its AUTH nonce (type 18 Host → Viewer, kind `none`, means "the Host fell back to
  its prompt without using your password", sent after a challenge timed out or went stale), because older decoders treat an unknown type as a fatal protocol
  error (`onProtocolError` → close). `protocolVersion` and the ALPN stay `1` / `swiftdesk/1`.
- **Brute force.** Besides the connection limiter (6/min/IP), the session layer locks a Viewer fingerprint or IP out
  of password attempts for 15 min after 5 wrong passwords in 15 min (it is prompted instead of challenged) and pauses
  password acceptance after 30 failures in 10 min. The Viewer refuses challenges below 1 000 000 PBKDF2 rounds, so a
  hostile Host cannot harvest a proof cheaper to crack than the real Host's. The Host
  verifies with one HMAC (no PBKDF2 per attempt), so guessing costs the Host nothing but costs the guesser a QUIC +
  mTLS handshake per try.
- **Keychain.** Host: one generic-password item, service `com.swiftdesk.access-password`, holding
  `{salt, iterations, key, enabled}` (never the password). Viewer: service `com.swiftdesk.host-password`, account =
  Host fingerprint hex, the password itself (saved only for a pinned Host after it worked). Both
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, file-based login keychain like the identity.

### Optional features: capability bits (0.1.4, reusable)

Every control decoder rejects unknown message types and trailing bytes, so a new message or field sent to a 0.1.x
peer tears its connection down. Optional features are therefore negotiated **once per connection, in both
directions, inside two fixed 16-byte fields that every version only length-checks** (`WireProtocol.PeerCapabilities`):

| Direction | Carrier | Layout |
|---|---|---|
| Viewer → Host | AUTH `nonce` (since 0.1.2) | `"SDC1"` · flags · 11 random bytes |
| Host → Viewer | ACCEPT `sessionToken` (since 0.1.4; the token was unused) | `"SDC1"` · flags · 11 random bytes |

A peer without the marker announces `[]`. **A feature is used only when both sides set its bit, and no peer sends a
message type of a feature the other side did not announce.** Bits: 0 `passwordAuth` (Viewer only, 0.1.2), 1
`sessionResume` (0.1.4), 2 `clipboard` (0.1.5: CLIPBOARD_STATE / CLIPBOARD and the side stream), 3 `cursorShape`
(0.1.6: CURSOR_SHAPE / CURSOR_IMAGE, Host → Viewer, and the side stream), 4–7 free. A later feature adds its bit to `PeerCapabilities` (one table for both
directions), its message types to `ControlMessageType`, and sends them only after it has seen the peer's bit (the
Viewer at ACCEPT, the Host at AUTH). Eight bits are plenty for now; bit 7 could later mean "extended flags follow"
inside the 11 random bytes. `protocolVersion` and the ALPN stay `1` / `swiftdesk/1`.

**Large payloads (images, clipboard data): the side stream.** Decided once in 0.1.5 for clipboard sharing; every later
bulk feature reuses it (0.1.6 pointer images do; file transfer would). See the next section.

### Side stream for bulk payloads (0.1.5, reusable)

The control stream carries input events, so nothing large may ever sit in front of them (QUIC delivers a stream in
order: a 16 MiB message on it would hold up every key and click behind it for as long as it takes to send). Bulk
payloads therefore travel on a **second reliable, bidirectional QUIC stream in the same connection** — not in chunks
on the control stream:

- **Who opens it.** Only the Viewer (the Viewer's group rejects Host-initiated streams, gotcha 2), with
  `PeerConnection.openSideStream()`, right after an ACCEPT whose capabilities and its own both contain a feature that
  uses it (`PeerCapabilities.sideStreamFeatures`: 0.1.5 `clipboard`, 0.1.6 `cursorShape`). An older Host never sees it: it is not opened unless the Host announced the bit. (An
  older Host that did see one would leave it unread, as it always ignored extra streams.)
- **Identification.** Its first 8 bytes are the transport preamble with stream kind `1` (`53 44 51 31 01 01 01 00`).
  The Host accepts at most one side stream per connection, only after the control stream is established **and the
  session has authorized the connection** (`PeerConnection.allowSideStream()`, called when the Host session
  activates: operator approval, password or trusted Viewer). Before that an extra stream's first receive (≤ 64 KiB)
  is parked unread and undecoded, so QUIC flow control holds back the rest and an unauthenticated peer cannot make
  the Host buffer or parse ~19 MiB messages; a parked side stream is picked up on activation. Any other
  extra stream is still left unread. The Host does not answer the preamble. A side preamble can never open the
  control stream: byte 6 must be 0 there (also in every older Host).
- **Framing.** The control framing (`[u32 length][u8 type][payload]`) with its own decoder and limit:
  `WireConstants.maxSideStreamMessageSize` (1 + `ClipboardContent.maxPayloadBytes` ≈ 19 MiB) instead of 64 KiB. The
  length is checked before any body byte is buffered, and each item length inside a CLIPBOARD before it is copied.
- **Channel rules.** Only `ControlMessageType.isSideStream` types (0.1.5: CLIPBOARD, 20; 0.1.6: CURSOR_IMAGE, 21) are
  allowed on it, and they
  are refused on the control stream: `sendControl` drops them, and a receiver that sees a type on the wrong stream
  treats it as a protocol error (DISCONNECT protocolError, connection closed), exactly like a malformed frame.
- **Flow.** `sendSide(_:completion:)` returns false when the stream is not open. Clipboard keeps **one message in
  flight** (the completion releases the next) and replaces a waiting one with a newer one, so a slow link never
  accumulates stale payloads. Pointer images are small (≤ 320 KiB, typically a few KiB) and each is sent once per
  shape, so they are written directly, never dropped (the id cache on both sides relies on every definition arriving);
  one can wait behind a clipboard transfer on the same stream, during which the Viewer keeps its previous pointer. QUIC flow control is per stream, so a large transfer does not block the control stream; congestion control
  is shared, so a 16 MiB image does compete with video for a few seconds on a slow link (the adaptation controller
  sees the backlog and lowers the bitrate as usual).
- **Lifetime.** The side stream ending (reset, error) does not end the session; the feature simply stops sending.
  Teardown cancels it with the connection.

Clipboard payload (`docs/CONTRACT.md`, "Clipboard sharing"): `u8 count`, then `{u8 kind, u32 length, bytes}` per
representation (1 text, 2 RTF, 3 PNG, 4 URL; text, RTF and URL ≤ 1 MiB each, PNG ≤ 16 MiB). CLIPBOARD_STATE (19,
`u8 flags`, bit 0 enabled) is small and stays on the control stream.

### Remote pointer shape (0.1.6, session layer)

The Viewer draws its own pointer (immediate, PRD §5) and the Host's cursor stays out of the captured video, so the
Viewer used to show a plain arrow over text fields and window edges. Since 0.1.6 it draws that local pointer in the
Host pointer's **shape**, which costs a few bytes per change:

- **Host.** While a session with a `cursorShape` Viewer is active and *Show my pointer shape to the Viewer* is on,
  `CursorShapeChannel` reads `NSCursor.currentSystem` about 30 times a second on the main actor (the only public API for
  another app's cursor; Apple notes it may return nil in a future macOS, which degrades to `unavailable` → arrow),
  renders it at up to 2× (≤ 256 × 256 px) and fingerprints the pixels and geometry (FNV-1a 64). A new shape gets the
  next id and one CURSOR_IMAGE (PNG) on the side stream; then, and for every shape seen before, a 5-byte CURSOR_SHAPE
  on the control stream, only when the shape changed. Hidden: `CGCursorIsVisible()` (public, deprecated, looked up at
  run time) or a fully transparent cursor image. Switched off: sampling stops, CURSOR_SHAPE(off) once.
- **Cache.** Ids count up from 1 per connection. The Host references only its 32 most recent definitions (FIFO; an
  older shape seen again is defined anew), the Viewer keeps 64, so a definition overtaking a CURSOR_SHAPE on the other
  stream can never evict the id that CURSOR_SHAPE names. A CURSOR_SHAPE whose definition has not arrived keeps the
  previous pointer until it does.
- **Viewer.** The PNG is decoded with ImageIO and must match the announced pixel size (else ignored). The pointer is an
  `NSCursor` at the Host's point size times the video magnification (clamped 0.75–2×), shown only while input is
  captured and over the video rect; hidden = a transparent cursor, never `NSCursor.hide()`. Before the first message,
  for older Hosts, with *off* / *unavailable* or the Viewer's own switch off: the arrow.
- **Compatibility.** Only Host → Viewer messages, and only when both sides announced bit 3: a 0.1.5 Viewer never
  receives them (and the Host never even reads its pointer for it); a new Viewer facing a 0.1.5 Host keeps the arrow.
  A side stream is now also opened when only pointer shapes need it.

### System shortcuts (0.1.7, session layer; no wire change)

Send Keys (⌘Tab, Spotlight, Mission Control, screenshots, Force Quit, Lock Screen …) and the optional "Send system
shortcuts" keyboard tap need **nothing new on the wire**: each is an ordinary sequence of KEY_DOWN / KEY_UP (types 8 / 9)
on the control stream — modifiers down, key down, key up, modifiers up in reverse — with the same sequence numbers,
flags and ordering as typed keys. So:

- **No capability bit, no message type, no side stream.** `PeerCapabilities` bits 4–7 stay free; the decision of
  0.1.4 (optional features negotiate a bit) applies only to features that add messages. Nothing large is involved.
- **Interop.** Any 0.1.x Host accepts the sequences (it always accepted any key code with any flags); a 0.1.6-or-older
  Viewer simply cannot send them. The Host's settings apply unchanged: input is injected only in an approved (or
  password) session with Accessibility granted; a view-only session drops them like any key.
- **Where they trigger.** The Host posts every key at `.cghidEventTap` from a `.hidSystemState` source (unchanged since
  0.1.0), i.e. where hardware events enter, before the WindowServer matches its symbolic hot keys, so system shortcuts
  act on the Host as if typed on its keyboard. Arrow and function keys carry the fn / keypad flags a real keyboard
  sets, because the stored defaults include them (Mission Control = ⌃ + fn + ↑). Limits: Secure Event Input and the
  lock/login window ignore synthetic events; a Host whose user changed or disabled a shortcut does not react to the
  default chord; Launchpad (no default chord) is sent as Apple keyboards' Launchpad key code 131. Not yet verified on
  a second Mac.

### Address book (0.1.8, Viewer only; no wire change)

Favorites, Recent and their screen thumbnails live on the Viewer (`AddressBookStore`, Application Support/SwiftDesk)
and need **nothing on the wire**: an entry is recorded from what the session already has after ACCEPT (the dialed
address, the TLS-observed Host certificate fingerprint, the sanitized ACCEPT host name), and the thumbnail is the last
frame the Viewer decoded, encoded locally at session end. So:

- **No capability bit, no message type, no side stream.** Bits 4–7 stay free; nothing large is sent.
- **Interop.** Works with every Host version; the Host is not told and cannot tell.
- **Trust unchanged.** An entry's fingerprint identifies the entry; it is **not** a pin. Connecting from a card is the
  ordinary dial: `TrustedHostStore`'s address-keyed pin (if the user chose "Remember this Host") is enforced by TLS,
  otherwise the verification sheet appears; the Host still approves or checks the password. A card shows whether its
  address is pinned to its identity, or to a different one (that connection will fail with "Host identity changed").

### Open at Login (0.1.9, Host app only; no wire change)

*Open SwiftDesk at login* is a local login item (`SMAppService.mainApp`, AppUI `LoginItemController`): it only decides
whether the app is opened after the user logs in. Whether it then listens is still *Start listening when SwiftDesk
opens*, and every connection is authorized exactly as before (approval prompt, or the access password if enabled).

- **No capability bit, no message type, no side stream.** Bits 4–7 stay free; the Viewer is not told.
- **Interop.** Works with every Viewer version.
- **Coexists with the optional watchdog LaunchAgent** (`com.swiftdesk.watchdog`, `scripts/swiftdesk-watchdog.sh`),
  which SwiftDesk never touches: both open the app through LaunchServices, which keeps a single instance.

### Dropouts and reconnect (0.1.4, session layer)

The product owner's Wi-Fi delivers nothing for 3–10 s at a time. Before 0.1.4 the 10 s QUIC idle timeout ended
such a session and the Host operator had to click Allow again.

- **Idle timeout 30 s** (`QUICConfiguration.idleTimeoutMillis`), keepalive unchanged at 3 s. QUIC applies the
  smaller of both endpoints' values, so against a 0.1.3-or-older peer it stays 10 s (degrades, does not break).
- **Liveness no longer depends on it.** Both sides send PING every 500 ms, so 1 s without any received control
  message or datagram means the link stalled, even on a static screen (`SessionCore.LinkSilenceDetector`). Host: the
  router's 200 ms watchdog **releases every held key, modifier and mouse button** after 1 s of silence and shows
  "not responding"; the session continues. Viewer: the last frame stays on screen, dimmed, with "Poor connection",
  cleared when traffic resumes.
- **Automatic reconnect (Viewer).** If the connection of a streaming session fails (a transport failure, not a
  DENY/DISCONNECT/identity change), the Viewer keeps the last frame and redials the same address with back-off 0.5,
  1, 2, 4, 8, 8 … s, starting no attempt later than 60 s after the drop; each attempt has a 4 s establishment timeout
  and is **pinned to the certificate fingerprint the session was verified with** (a different certificate ends it as
  "identity changed"). DENY(busy) is retried (an older Host still holds the dead session until its idle timeout).
  The rate limiter (6/min/IP) only sees attempts that reach the Host, i.e. after the network is back.
- **Reconnect without a prompt (Host).** Only for a Viewer that announced `sessionResume`, with the same TLS-proven
  fingerprint as a session the operator allowed (or that used the access password), whose connection *dropped*
  (not a Viewer DISCONNECT, Stop Sharing, Stop Listening or capture/permission end) at most 2 minutes ago, unless the
  operator revoked it (Stop Sharing, Stop Listening, Deny, "Require Approval", the setting switched off; for a
  password session: password access switched off or the password changed). If the Host has not noticed the drop yet
  (its own idle timer is still running), a new connection from the **same** identity may replace the active session
  under the same rules; any other connection still gets DENY(busy). A resumed session gets a new session id and
  token (fresh ACCEPT/CONFIG/keyframe), keeps the original start time and "via password" flag, and the Host shows a
  non-modal "Reconnected <name>" note. Otherwise the normal prompt (or password challenge, answered from the password
  typed for the original connection, held in memory only) applies. Checks before it are unchanged: mTLS, rate
  limits, channel binding (AUTH), version, Screen Recording.
- **One keyframe after a blackout, not dozens.** REQUEST_KEYFRAME is reliable, so re-requests sent while the link is
  dead queue up and arrive together. The Viewer's `RecoveryGate` now backs re-requests off (1, 2, 4 s cap) while no
  datagram arrives and asks once, right away, when traffic returns (10 s outage: ≤ 4 queued instead of 20; the Host's
  `KeyframeRequestLimiter` folds a burst into one). The Host's suppression window after a keyframe is capped at
  400 ms (an RTT estimate inflated by PINGs that waited out the outage would otherwise ignore genuine re-requests for
  seconds), and a refused recovery keyframe is re-asked by the 2 Hz control timer instead of for every captured frame.
- **Compatibility.** No new message types. A 0.1.3 Viewer never announces `sessionResume`, so a new Host always prompts
  it; a 0.1.3 Host never announces it either, so a new Viewer still reconnects but is prompted (the overlay says so).

### Keychain

- File-based **login keychain** (`kSecUseDataProtectionKeychain` not used): the data-protection keychain needs a
  keychain-access-groups entitlement that unsigned/dev builds lack.
- Private key: `SecKeyCreateRandomKey` (`kSecAttrIsPermanent`, `kSecAttrApplicationTag =
  "com.swiftdesk.identity.<label>"`, `kSecAttrLabel = label`). Certificate: `SecItemAdd(kSecClassCertificate)`.
  Pairing via `kSecAttrPublicKeyHash` (gotcha 9). `SecIdentity` via `SecIdentityCreate(nil, cert, key)` (public since
  macOS 10.12), falling back to `SecIdentityCreateWithCertificate`.
- `loadOrCreate` reuses the stored pair (and regenerates if one half is missing or they mismatch); `regenerate`
  deletes and recreates; `delete(label:)` removes both. Creating an identity takes ~0.3–0.5 s.
- No keychain prompts were observed for the creating process. **Not verified:** an ad-hoc-signed rebuild of the app
  reusing a key created by a previous build may trigger a "wants to use your confidential information" prompt when
  signing; a stable code signature (Developer ID / Apple Development) avoids that.

### Discovery and paths

- **Bonjour**: `HostListener` advertises `_swiftdesk._udp` with the device name. `BonjourBrowser` uses `NWBrowser`;
  `resolve` opens a throwaway UDP `NWConnection` to the service endpoint (IPv4 preferred, then any) and reads
  `currentPath.remoteEndpoint` (no packets are sent). Verified: resolves the spike's listener to `192.168.x.y:<port>`.
- **NetworkInfo** (`getifaddrs`): up, non-loopback, non-link-local addresses; `isTailscale` = 100.64.0.0/10 or
  fd7a:115c:a1e0::/48.
- **TailscaleProbe**: runs `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/opt/homebrew/bin/tailscale`,
  `/usr/local/bin/tailscale` or `tailscale` on `PATH` with `status --json` (3 s timeout), finds the peer by
  `TailscaleIPs`/`HostName`/`DNSName`; `direct` = non-empty `CurAddr`; `relay` = `PeerRelay` if set, else the DERP
  region `Relay`. Verified against the Homebrew CLI on this Mac with three real peers (30–55 ms per call; all
  reported relayed because idle peers have no `CurAddr` — probe while the session is carrying traffic).

## 4. Measurements (loopback, release build, this Mac)

Raw Network.framework (`QUICSpike --raw`):

```
[  1.138] raw client group ready
[  1.138] raw handshake 190.35 ms
[  1.138] raw client control stream id=4
[  1.141] raw server group metadata peer=0314 4E4E 71FE EDE3 D612 FFB7 734F 7613 alpn=swiftdesk/1
[  1.141] raw server extracted datagram flow ready usableDatagramFrameSize=9164
[  1.215] raw control echo RTT n=1000 mean=0.076 p50=0.071 p95=0.106 p99=0.135 max=3.182 ms
[  1.215] raw client datagram flow usableDatagramFrameSize=9156; sending 2000 x 1150 B
[  2.221] raw RESULT client->server datagrams: extracted=2000 implicit=0 of 2000
[  3.225] raw RESULT server->client datagrams: 2000 of 2000
```

Variants: `--wrong-pin` → client verify block rejects, server group `failed(EINVAL)`, client group still `.setup`
after 10 s; `--client-noid` → client `.ready` after 111 ms, then both groups `failed(EINVAL)` 5 ms later;
`--no-server-extract` → 385/2000 datagrams; `--no-client-handler` → client group stuck in `.setup`.

TransportCore end to end (`QUICSpike`, release):

```
[  0.694] identities created in 694.2 ms
[  0.695] PASS loadOrCreate reloads the same identity from the keychain
[  0.858] PASS pinned connect reaches .ready (ready) in 161.1 ms
[  0.858] PASS host-side peerFingerprint == viewer fingerprint
[  0.858] viewer maxDatagramSize=1150 remote=127.0.0.1:63987
[  0.928] PASS 1000 PING/PONG control round trips completed (1000)
[  0.928] control RTT (PING->PONG over QUIC stream, loopback): n=1000 mean=0.064 p50=0.054 p95=0.098 p99=0.186 max=1.211 ms
[  2.695] viewer->host simulated loss=0%: handed 2000, refused batches 0, arrived 2000/2000 (0.00% missing)
[  4.462] viewer->host simulated loss=3%: handed 2000, refused batches 0, arrived 1947/2000 (2.65% missing)
[  6.219] host->viewer simulated loss=0%: handed 2000, refused batches 0, arrived 2000/2000
[  6.723] backpressure burst: 200 batches x 64400 B unpaced, refused 198, peak pending 128800 B, pending after drain 0 B
[ 21.724] PASS connection survives 15 s idle (keepalive)
[ 22.325] PASS host received DISCONNECT
[ 22.325] PASS host-side connection reports .closed ([ready, closed])
[ 22.416] PASS wrong pin fails: failed("Host identity does not match the pinned fingerprint") after 90.1 ms
[ 22.718] PASS host never hands out the wrong-pin connection
[ 22.889] PASS unpinned connect is ready and records the host fingerprint
[ 26.391] rate-limited attempts: ["ready (164 ms)", "ready (185 ms)", "failed(\"Connection timed out\") (3150 ms)"]
[ 26.400] bonjour resolved 'SwiftDesk QUICSpike EFAA97A4' -> 192.168.x.y:63987
[ 26.872] ALL CHECKS PASSED
```

Datagram tests send 4 × 1150-byte datagrams every 2 ms (≈ 18 Mbit/s). The 3 % run's 2.65 % missing is the
simulated drop (53 dropped by the simulator, no network loss). Loopback numbers say nothing about Wi-Fi/WAN latency;
the LAN/Tailscale measurements belong to Milestones B/E on two Macs.

### Re-run during the integration pass (same machine, release, 2026-11-03)

All checks passed again. Numbers that moved compared with the run above (loopback, so the differences are run-to-run
noise, not a regression):

```
[  0.926] identities created in 925.7 ms
[  1.139] PASS pinned connect reaches .ready (ready) in 199.7 ms
[  1.231] control RTT (PING->PONG over QUIC stream, loopback): n=1000 mean=0.086 p50=0.072 p95=0.178 p99=0.234 max=0.429 ms
[  5.190] viewer->host simulated loss=3%: handed 2000, refused batches 0, arrived 1934/2000 (3.30% missing)
[  7.665] backpressure burst: 200 batches x 64400 B unpaced, refused 198, peak pending 128800 B, pending after drain 0 B
[ 23.359] PASS wrong pin fails: failed("Host identity does not match the pinned fingerprint") after 75.7 ms
[ 27.281] rate-limited attempts: ["ready (154 ms)", "ready (154 ms)", "failed(\"Connection timed out\") (3146 ms)"]
[ 27.771] ALL CHECKS PASSED
```

Full session over this transport (real `HostSession` + `ViewerSession`, `SWIFTDESK_BENCH=1 swift test --filter
SessionCoreTests.Benchmark`): connect→approval request 158 ms, approve→first decoded frame 332 ms, viewer RTT srtt
0.49 ms. Details in `docs/MEASUREMENTS.md`.

## 5. Open issues / not yet verified

- Two-Mac LAN and Tailscale runs (usable datagram size over a 1280-byte MTU, handshake time without the loopback
  `.waiting` transient, behaviour on path changes / Wi-Fi roaming). Whether Network.framework migrates a QUIC
  connection across a Wi-Fi roam (new local address) is unverified; if not, the Viewer's automatic reconnect covers
  it after the idle timeout (up to 30 s). `maxDatagramSize` is sampled once at `.ready`.
- Keychain prompt behaviour across differently signed builds (see Keychain).
- System shortcuts (0.1.7) injected at the HID tap: which of ⌘Tab, ⌘Space, ⌃↑ / ⌃↓, F11, key code 131, ⇧⌘3/4/5,
  ⌥⌘Esc, ⌃⌘Q and ⌃⌘Space trigger on a real Host from synthetic events has not been tested (no second Mac, and no
  Accessibility grant in the test environment).
- A refused (rate-limited) viewer only learns of it through its establishment timeout; a fast explicit refusal
  would need the host to complete TLS first, which the design deliberately avoids.
- The host ignores additional data-bearing streams after the control stream, except one side stream (0.1.5); only
  one control stream per session is supported (by design). The side stream was verified on loopback only (4 MiB
  each way while PING/PONG continued on the control stream); its effect on video during a large transfer over a
  slow real link has not been measured.
