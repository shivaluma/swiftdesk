# SwiftDesk — Native macOS Low-Latency Remote Desktop

**Document:** MVP PRD + technical implementation plan  
**Version:** 1.0 · 2026-11-03  
**Product type:** Mac-to-Mac remote access and control  
**Nonnegotiable:** native macOS UI and runtime; responsiveness over picture quality  
**Primary recommendation:** Swift 6 + Apple frameworks only. **No Rust backend or Rust desktop engine for the MVP.**

## 1. Executive summary

Build one signed native macOS application that can act as either **Host** (share/control this Mac) or **Viewer** (control another Mac). The first test uses two Macs on the same LAN; the internet-capable MVP uses a separately installed Tailscale network tunnel on both Macs, avoiding the enormous scope of implementing NAT traversal and public relay infrastructure. A future standalone release may replace Tailscale with ICE/STUN/TURN and a small Rust signaling service.

The hot path must be native:

`ScreenCaptureKit -> IOSurface/CVPixelBuffer -> VideoToolbox (H.264 hardware encode) -> Network.framework (encrypted QUIC datagrams) -> VideoToolbox (hardware decode) -> CVPixelBuffer -> Metal renderer`

Input travels **separately**, from Viewer to Host: `AppKit local events -> QUIC reliable stream / latest-state datagrams -> CoreGraphics CGEventPost`.

Architecture principle: **display the newest available frame; never accumulate a queue of stale video frames just to make playback smooth.** Pointer feedback on the Viewer should be painted locally and immediately, not depend on receiving video from the Host.

## 2. Goals, success metrics and limits

### Goals (P0)

1. Native SwiftUI macOS app; one `.app` build supports both Host and Viewer.
2. Connect to one authenticated Mac at a time; Host explicitly accepts the session.
3. Stream one display at 720p/60fps target with H.264 hardware encoding and decoding.
4. Mouse movement, left/right click, drag, scrolling, keyboard events including modifiers.
5. LAN direct connection, and remote access between two user-controlled Macs through an existing Tailscale tunnel.
6. Show status: connected, RTT, effective FPS, estimated bitrate, packet/frame loss, video decode-to-render lag.
7. One-click Disconnect, prominent active-sharing indicator, and immediate stop on Host.
8. No video, audio, keystroke, or clipboard logging.

### Performance targets (acceptance goals, **not** measured claims)

**Test conditions:** two Apple Silicon Macs, wired/strong Wi-Fi LAN, 720p, 60-Hz-or-faster displays, stable uncongested network, one active desktop; record p50/p95 across at least 100 actions and multiple sessions.

| Metric | MVP target | Notes |
|---|---|---|
| Click on Viewer to resulting visual update on Viewer (LAN) | p50 <= 80 ms, p95 <= 150 ms | End-to-end *input-to-photon*. Stretch goal 60/100 ms. Depends on app and host workload. |
| Pointer response on Viewer | Visually immediate, ideally <= 1 display refresh | Draw locally; remote actual response still depends on network. |
| Interactive frame rate on LAN | 45+ delivered FPS under regular desktop use, aiming at 60 FPS | Source only emits frames when content updates. |
| Video configuration | Default 1280x720 / 60 FPS / approx. 2–5 Mbps | Adapt down first; do not overprotect sharpness. |
| UI and control events | Never wait behind queued video frames | Control and video travel on separate streams/flows. |
| Connect and show first usable frame | Target <= 3 seconds after Host approval on LAN | Permission onboarding excluded. |
| WAN latency | Record actual RTT and input-to-photon | No universal target without controlling route; rough design ambition ~ RTT + 80 ms p50. |

Measurement is required; do not claim parity with AnyDesk without head-to-head physical tests.

### Explicit non-goals

No Windows/Linux/iPhone client, audio, file transfers, printer forwarding, clipboard sync, multi-display control, cloud accounts, proprietary ID directory, unattended access, start-at-boot agent, remote login/FileVault unlocking, screen capture of protected content, web UI, remote gaming-specific optimization, or pixel-perfect retina quality.

## 3. Personas and user stories

- **Owner / developer:** I can run the app on my two Macs, pick Host on one and Viewer on another, and control the Host responsively with a keyboard and mouse.
- **Host operator:** I can inspect the peer name/fingerprint, grant or deny access, and end the session immediately.
- **Troubleshooter:** I can see whether lag is caused by network RTT, capture/encode delay, dropped frames, or rendering queues.

## 4. Core UX

### Host

1. Launch app, choose **Share this Mac**.
2. App checks **Screen & System Audio Recording** permission and **Accessibility** permission, and explains why each is necessary. Let macOS handle the prompts/settings.
3. Choose one display; show Host name and local IP / Tailscale IP (when available).
4. Host listens for a secure connection. On connection, show the peer identity/fingerprint and **Allow Control** / **Deny**.
5. On Allow, start capture and grant control only for this session. Show persistent status indicator and **Stop Sharing**.
6. When session ends or connectivity is lost, stop frame capture, reject subsequent events, and release any held modifier/button state.

### Viewer

1. Launch app, choose **Control a Mac**.
2. Connect by hostname/IP (Bonjour discovery is optional convenience, not a blocker); optionally save a pinned, trusted device.
3. Verify peer identity and obtain Host approval.
4. Show remote desktop in an aspect-fit Metal view, with a top toolbar for latency/FPS, scaling, and Disconnect.
5. Move the mouse and interact. Escape from remote keyboard capture via a dedicated local shortcut.
6. Reconnect requires new authorization unless an explicit, narrowly scoped pairing preference is later added.

**Security UX:** never provide hidden control. The Host must always have a visible way to revoke access, and macOS TCC permissions must remain mandatory.

## 5. Technical architecture

### Single-app, two roles

```text
HOST macOS                                           VIEWER macOS
┌────────────────────────┐                         ┌──────────────────────┐
│ SwiftUI host screen    │                         │ SwiftUI viewer       │
│ Permission coordinator │                         │ Event capture        │
│ ScreenCaptureKit       │                         │ Network.framework    │
│      ↓ CMSampleBuffer  │   QUIC encrypted        │      ↓               │
│ VideoToolbox H.264     ├══ datagram video ═══════>│ VideoToolbox H.264   │
│      ↓                 │                         │      ↓ CVPixelBuffer │
│ Network.framework     │                         │ Metal/MTKView        │
│      ↑                 │   QUIC control stream   │      │               │
│ CoreGraphics CGEvent  │<══ keys/buttons ═════════│ Keyboard/mouse       │
└────────────────────────┘   + latest pointer data └──────────────────────┘
```

**Language:** Swift 6 for GUI, host engine, viewer engine, transport and protocol. Do not add Rust or FFI into the capture/encode/decode hot path without a reproducible benchmark proving the change helps.

**Recommended modules (Swift Package targets):**

- `AppUI`: SwiftUI, window lifecycle, menu bar, onboarding.
- `SessionCore`: roles, state machine, authentication, authorization, disconnect.
- `CaptureCore`: ScreenCaptureKit stream lifecycle and filtering.
- `CodecCore`: VideoToolbox encoder/decoder and format negotiation.
- `TransportCore`: Network.framework QUIC reliable control + datagram video, framing, pacing.
- `InputCore`: AppKit keyboard/mouse forwarding and host CGEvent injection.
- `RenderCore`: Metal, `CVMetalTextureCache`, latest-frame display.
- `DiagnosticsCore`: os_signpost instrumentation, FPS/RTT/loss counters.

### Video pipeline

- Host: use `SCShareableContent`, `SCContentFilter` for one display and `SCStream` with `minimumFrameInterval = 1/60`, `queueDepth = 3` as a starting point. Apple's documentation states 3 is the default/minimum; **do not treat queueDepth=1 as a valid optimization**. Keep app-level pending encode frames to 0–1 when possible.
- Capture at 1280x720 or nearest aspect-preserving size, using an encoder-compatible pixel format; check support for YUV vs BGRA and avoid per-frame CPU color conversion. Actual source update rate may be lower on static desktops.
- Host: H.264, hardware VideoToolbox compression, real-time, low-latency rate control when available, no B-frame reordering, minimal frame delay, fast encode rather than maximum quality. Fall back to supported settings when the codec rejects optional properties.
- Default 60 FPS, target bit rate ~3 Mbps, adaptive 1–5 Mbps; reduce resolution to 960x540, then frame rate to 30 if lag persists. Prefer lower quality to queued frames.
- Viewer: VideoToolbox decompression into `CVPixelBuffer`, publish most recent complete frame to Metal with `CVMetalTextureCache`; do not copy raw pixels to CPU just to display.
- On packet loss/corruption, discard incomplete frame data and request a new recovery/key frame. A frequent keyframe strategy must be validated with the chosen low-latency encoder mode because Apple can use a long/infinite GOP under that mode.
- Hide the Host cursor from captured video if supported; draw the Viewer cursor locally at its current position. Host-side visible cursor remains controlled by injected system events.

### Networking

- **Transport:** native `Network.framework`. Prefer **authenticated QUIC + QUIC datagrams**: secure reliable stream(s) for session/control and unreliable datagrams for video. Apple provides `NWParameters.quicDatagram` / `NWProtocolQUIC.Options.isDatagram`; validate current API usage on the project's deployment target with a throwaway sender/receiver spike first.
- QUIC already provides transport encryption, but **encryption alone is not identity**: require proper peer authentication (pinned certificate/public-key identity, or a reviewed secure pairing flow). Never automatically trust arbitrary self-signed certificates in production.
- LAN: connect by entered IP, optionally Bonjour `_swiftdesk._udp` or service matching your selected QUIC listener configuration.
- Internet MVP: both machines install Tailscale and connect by tailnet IP/hostname, preserving the same native QUIC-based app transport. Detect/report relay rather than promising direct P2P. Never expose an unauthenticated control port to the public Internet.
- Video packetization: split encoded access units into datagrams within the negotiated transport limit / path MTU. Include `{sessionId, frameId, packetIndex, packetCount, timestamp, codecFlags, payload}` in a **versioned binary header**. Reassemble only within a short deadline; cap memory, reject malformed/oversized frames and duplicates, drop expired packets. Never rely on QUIC datagrams delivering packets in order or at all.
- Control packet types: `HELLO`, `AUTH`, `ACCEPT`, `DENY`, `CONFIG`, `PING`, `PONG`, `KEY_DOWN`, `KEY_UP`, `MOUSE_DOWN`, `MOUSE_UP`, `MOUSE_MOVE`, `SCROLL`, `REQUEST_KEYFRAME`, `DISCONNECT`.
- Send **key down/up, button down/up, auth, connect, disconnect** reliably and ordered. Prefer latest-state/unreliable messages for pointer movement if supported in the selected QUIC session; old pointer moves should not build up a backlog. Use event sequence numbers; on disconnect, release stuck keys/buttons.
- Pace sending and observe queue backlog. Adapt bitrate/resolution using RTT, loss, delivery rate and encode/send queue metrics. Do not flood or bypass congestion control.

### Input correctness

- Viewer catches native `NSEvent` inside the focused remote view only; preserve local emergency escape shortcut.
- Host injects with `CGEvent` / `CGEventPost` only after Accessibility approval and positive session authorization.
- Map displayed viewer coordinates through image scaling, letterboxing and selected Host display geometry. **macOS points ≠ Retina pixels**; capture pixels, display points and input coordinates must be transformed explicitly.
- Handle press/hold/drag/double-click, scroll direction, left/right buttons, physical keycode with `Command/Option/Control/Shift` modifiers, and release on focus loss/disconnect. Start with US keyboard layout and test others.
- Do not promise injection into login windows, FileVault, secure/protected surfaces, or all privileged permission dialogs.

## 6. Native tuning rules

1. **No JSON on the hot path.** Use a compact binary protocol with validated bounds and little allocation.
2. **No JPEG-per-frame, PNG, WebSocket video, or screen polling screenshots.** Use ScreenCaptureKit streaming and VideoToolbox.
3. **No guaranteed-order video transport.** A complete but late frame is generally worse than skipping it.
4. **No unnecessary copies.** Preserve `CVPixelBuffer` / IOSurface-backed surfaces across the Apple pipeline where compatible.
5. **Separate control and video.** Keyboard/button commands must not block behind bulk frame bytes.
6. **One pending/latest video frame** in the app's sender/renderer; don't block ScreenCaptureKit callbacks waiting for network or renderer.
7. **Avoid expensive actor hops in per-frame loops.** Use dedicated dispatch queues and narrow synchronization where profiling supports it; keep SwiftUI work on the main actor.
8. **Instrument first.** Record capture callback, encoder callback, network enqueue, network receive, decoder callback, and Metal-present milestones; don't infer performance from FPS alone.
9. **Design for 60Hz first.** Optional 120 FPS experiment only if both Macs, displays, capture API and hardware codecs actually sustain it.
10. **Optimize by measurement** using Instruments Time Profiler / Metal profiling and real input-to-photon tests.

## 7. Permissions and distribution

- Host screen capture: request Screen Recording permission using documented ScreenCaptureKit practices and `NSScreenCaptureUsageDescription` where supported by target OS/SDK.
- Host remote input: check `AXIsProcessTrustedWithOptions`, ask user to enable Accessibility in System Settings.
- Remote control UI: never suppress/masquerade as macOS permission prompts. User must be able to see the active session.
- Stable app bundle identifier for TCC consistency. Plan Developer ID signing/notarization for sharing a distributable build; do not treat unsigned local debug builds as production-ready.
- Pairing: trusted host identity + per-session consent + rate limit connection attempts + cryptographically random session tokens and no exposed unauthenticated control channel.

## 8. MVP development milestones and exit criteria

### Milestone A — Local video loopback (highest-risk spike)

- Build native SwiftUI macOS app.
- Record one display using ScreenCaptureKit.
- Encode H.264 with VideoToolbox, immediately decode it locally, and render it with Metal.
- Measure stage latency; check hardware encoder use and dropped frames.
- **Exit:** stable visual pipeline; 720p target; no CPU-side PNG/JPEG conversion.

### Milestone B — Secure LAN transport

- Create native QUIC sender/listener spike; test reliable stream + unreliable datagram support.
- Add framing, fragmentation, stale-frame discard, recovery-keyframe request, identity verification, approval handshake.
- Stream between two Macs on LAN.
- **Exit:** protected, approved connection; video remains live under artificial 1–3% packet loss; no runaway memory usage.

### Milestone C — Full remote input

- Enable Accessibility; implement pointer, click, drag, scroll, keydown/up, modifiers.
- Add coordinate scaling, focus/escape shortcut, state cleanup, disconnect.
- **Exit:** usable Finder, browser, text editing; no stuck held keys after disconnect.

### Milestone D — Latency optimization and diagnostics

- Local cursor overlay; adaptive resolution/bitrate; latest-frame queue discipline.
- Add RTT, FPS, loss, encode/decode metrics; test 2.4/5 GHz Wi-Fi and wired LAN.
- Test packet loss/reorder, Host sleep or app quit, permission revoked, peer reconnect.
- **Exit:** measure and report p50/p95 LAN click-to-photon; work toward defined goals.

### Milestone E — Remote access via existing network tunnel

- Connect by Tailscale IP/hostname; check connection is direct vs relay.
- Ensure Host still explicitly approves and transport authenticates peers.
- **Exit:** native app operates between two Macs on different networks without any project-owned server.

## 9. QA / definition of done

- Both roles install and run on macOS 15+ with tested Swift/Xcode toolchain and supported hardware.
- Permission requests are clearly explained; deny paths degrade safely and never bypass TCC.
- Session acceptance is required before remote control; Host can revoke at any time.
- Basic input test matrix passes: keyboard modifiers, drag, scrolling, resize, zoom, disconnected/reconnected network, wrong peer identity, malformed datagrams, stale packets.
- The Viewer does not render old video frames once a fresher complete frame exists.
- Connection loss clears session keys and input state; app does not crash or accumulate unbounded memory.
- Performance report includes actual p50/p95 input-to-photon results, direct/relayed path, effective FPS, bitrate, frame drops and machine specs.

## 10. What to defer — and when Rust makes sense

**No Rust for MVP.** Swift is already the API owner for ScreenCaptureKit, VideoToolbox, Metal, and CoreGraphics. Rust FFI can add integration/debugging complexity without lowering hardware encode/capture latency.

Use Rust later for a **small standalone coordination service**, if you remove Tailscale and provide automatic AnyDesk-style internet connectivity:

- `tokio + axum` server for peer discovery, short-lived device/session invitations, authentication and signaling.
- Mature ICE/STUN/TURN transport or interoperable NAT traversal libraries, with a global relay fallback where P2P fails.
- **Server never decodes video or sends it through an application-layer websocket.** Relays forward encrypted packets only.
- The native Mac app keeps capture, encode, decode, rendering and input in Swift.

If engineering a native QUIC real-time protocol proves unexpectedly expensive, evaluate a mature media transport (e.g. native WebRTC) in a measured spike, but do not introduce a browser or JS runtime for the UI.

## 11. Agent-ready brief (paste into coding agent)

> You are a senior macOS systems and real-time media engineer. Implement the PRD in this file incrementally. The product must be a **fully native macOS Swift 6 app**, with **SwiftUI + ScreenCaptureKit + VideoToolbox + Network.framework QUIC + CoreGraphics + Metal**. Do not add Electron, Tauri, React, JS, Node, Python, Rust FFI, FFmpeg, screenshot polling, or JPEG frame streams to the production app. Prioritize latency over visual quality. Follow Apple's real permission model and implement secure, authenticated, consent-based remote access.
>
> Start only with **Milestone A**: build a compilable Xcode project, implement ScreenCaptureKit -> hardware H.264 encoder -> local hardware decoder -> Metal renderer, add FPS and per-stage latency measurements, and include clear steps for running it. Validate actual current Apple APIs and codec feature availability before using them. Do not invent types/properties. Once A works, proceed through B, C, D and E. Add unit tests for wire protocol and packet reassembly. Never queue stale frames. Document assumptions and measured numbers; do not claim performance without data.

## 12. Primary sources (read before coding)

1. Apple ScreenCaptureKit overview: https://developer.apple.com/documentation/screencapturekit
2. Apple ScreenCaptureKit macOS sample: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
3. Apple queueDepth (default/minimum three): https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
4. Apple low-latency VideoToolbox sample: https://developer.apple.com/documentation/videotoolbox/encoding-video-for-low-latency-conferencing
5. Apple low-latency encoder spec: https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol
6. Apple H.264 frame reordering: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_allowframereordering
7. Apple Network.framework QUIC/datagrams: https://developer.apple.com/documentation/network/nwparameters and https://developer.apple.com/documentation/network/nwprotocolquic/options
8. Apple CGEvent posting: https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29
9. Apple Accessibility trusted API: https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
10. Tailscale direct vs relay connection types: https://tailscale.com/docs/reference/connection-types
11. Similar native open-source Mac host reference (study critically, don't copy blindly): https://github.com/omen18/MacDeck
12. Rust-based architecture reference (for research, not the proposed app stack): https://github.com/nchapman/tether
