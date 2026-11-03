# SwiftDesk — PRD compliance

Status of every PRD requirement and milestone exit criterion after the integration pass (2026-11-03). Evidence is a
source location (`file:line`) or a test (`TestTarget/Suite.test`). Statuses:

- **Done**: implemented and verified by tests or a run on this Mac.
- **Partial**: implemented, but part of the requirement is missing or measured short of the goal.
- **Not done**: not implemented.
- **Needs 2-Mac test**: implemented, but it can only be verified on two Macs, on a real network, or with TCC grants
  this machine's test process does not have (Screen Recording and Accessibility were both **not granted**).

Measured numbers: `docs/MEASUREMENTS.md`. Test totals (integration pass, run twice): `swift test` 424 tests in 61
suites, 0 failures, 3 skipped (2 opt-in benchmarks, 1 live-capture test that needs Screen Recording). AppUI: 58 tests
in 12 suites via `xcodebuild test`. After the recovery pass (FEC, §10): `swift test --scratch-path .build/recovery`
462 tests in 64 suites, 0 failures, the same 3 skipped; AppUI tests were not re-run. After the review fixes (§11):
`swift test --scratch-path .build/final` (clean scratch path) **486 tests in 66 suites, 0 failures, 3 skipped**; AppUI
**58 tests in 12 suites** via `xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds 0 warnings.
After password access (§12, 0.1.2): `swift test --scratch-path .build/pw` (clean scratch path) **541 tests in 72
suites, 0 failures, 3 skipped**; AppUI **65 tests in 13 suites**; debug and release builds 0 warnings.
After native resolution (§14, 0.1.3): `swift test` (clean scratch path) **568 tests in 72 suites, 0 failures,
3 skipped**; AppUI **71 tests in 15 suites** via `xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds
0 warnings.
After dropout resilience (§15, 0.1.4): `swift test` **606 tests in 75 suites, 0 failures**; AppUI **76 tests in 16
suites** via `xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds 0 warnings.
After clipboard sharing (§16, 0.1.5): `swift test` **651 tests in 78 suites, 0 failures**; AppUI **82 tests in 17 suites** via
`xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds 0 warnings.
After remote pointer shape (§17, 0.1.6): `swift test` **687 tests in 81 suites, 0 failures**; AppUI **86 tests in 18
suites** via `xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds 0 warnings.
After system shortcuts (§18, 0.1.7): `swift test` **707 tests in 83 suites, 0 failures**; AppUI **93 tests in 19
suites** via `xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds 0 warnings. Two pre-existing
timing flakes seen in full runs were fixed in the tests (§18 last row; `LoopbackSessionTests.packetizedLoopbackSurvivesLoss`
now waits for the periodic metrics snapshot instead of reading it once).

After the address book (§19, 0.1.8): `swift test` **721 tests**, 0 failures; AppUI **100 tests** via `xcodebuild test
-only-testing:SwiftDeskTests`. After Open at Login (§20, 0.1.9): `swift test` **721 tests in 84 suites, 0 failures**
(no SwiftPM test change; one pre-existing keychain read-after-write flake fixed in the test, §20 last row); AppUI
**110 tests in 21 suites** via `xcodebuild test -only-testing:SwiftDeskTests`; debug and release builds 0 warnings.

Release **0.2.0 (build 5)**: the features labelled 0.1.4–0.1.9 below plus the review fixes in §21. After those fixes:
`swift test` **728 tests in 84 suites, 0 failures**, 3 skipped (2 opt-in benchmarks, 1 live-capture test without
Screen Recording); AppUI **113 tests in 21 suites** via `xcodebuild test
-only-testing:SwiftDeskTests`; debug build (clean scratch path) and `scripts/build-app.sh` release build 0 warnings.

## 1. Goals (P0)

| # | Requirement | Status | Evidence |
|---|---|---|---|
| P0-1 | Native SwiftUI macOS app; one `.app` for Host and Viewer | Done | `Sources/SwiftDeskApp/SwiftDeskApp.swift:6` (`@main`), `Sources/AppUI/RootView.swift`, `AppRole` host/viewer/loopback; `scripts/build-app.sh` → `build/SwiftDesk.app`, launched for 6 s and quit cleanly with no crash report; `xcodebuild -scheme SwiftDesk build` succeeded |
| P0-2 | One authenticated Mac at a time; Host explicitly accepts | Done | busy rejection `HostSession.incoming` (only while a request awaits approval or a session is active; unidentified connections wait in a bounded pool, review security-1); approval gate `HostSession.swift:289` + `HostHandshake.decide` (`Sources/SessionCore/HostHandshake.swift`); input dropped before approval `Sources/SessionCore/HostConnectionRouter.swift` (`guard isActive`); tests `SessionCoreTests/EndToEndTests.secondViewerIsBusyWhileARequestIsPending`, `.fullSessionStreamsVideoAndForwardsInput` ("No input sink exists before approval"), `.silentUnidentifiedPeerDoesNotBlockAnotherViewer`, `.deniedViewerIsRateLimitedWithoutANewPrompt` |
| P0-3 | One display at 720p/60 with H.264 HW encode and decode | Partial / Needs 2-Mac test | 0.1.3: Sharp (default) streams the display's native size up to 1920×1080@60, Balanced keeps 1280×720@60 (§14); `CaptureConfig` bounds `Sources/CaptureCore/CaptureConfig.swift:21`; 1600×900 and 1920×1080 @60 HW encode + decode measured with `PipelineBench` (§14); HW encoder spec + low-latency RC `Sources/CodecCore/H264Encoder.swift:211`; HW decode verified (`hw_decoder=true`) in `docs/bench/*.txt`. ScreenCaptureKit capture itself never ran (no Screen Recording grant) |
| P0-4 | Mouse move, left/right click, drag, scroll, keyboard incl. modifiers | Done (logic) / Needs 2-Mac test (real injection) | Viewer: `Sources/InputCore/ViewerInputTranslator.swift`; Host: `Sources/InputCore/HostInjectionEngine.swift:113`, drags `:265`, scroll `Sources/InputCore/EventPoster.swift:46`; tests `InputCoreTests` (74), e.g. `clickIsMoveThenDownThenUp`, `doubleClickCarriesClickState2`, `pointerMovesWhileHeldBecomeDrags`, `keysCarryFlagsAndAutorepeat`, `preciseScrollPostsPixelsWithPhasesAndCarriesRemainders`. No CGEvent was posted (no Accessibility grant) |
| P0-5 | LAN direct, and remote via an existing Tailscale tunnel | Needs 2-Mac test | dial by IP/hostname `Sources/SessionCore/ViewerSession.swift:204`; tailnet detection `Sources/TransportCore/NetworkInfo.swift:55`; direct/relay probe `Sources/TransportCore/TailscaleProbe.swift:7`; Bonjour `Sources/TransportCore/HostListener.swift:95`. Verified on 127.0.0.1 only |
| P0-6 | Status: connected, RTT, effective FPS, bitrate, loss, decode→render lag | Done (loopback) | `MetricsSnapshot` `Sources/DiagnosticsCore/MetricsSnapshot.swift`; Viewer toolbar `Sources/AppUI/StreamingView.swift:97-102`; Host tiles `Sources/AppUI/HostView.swift`; test `EndToEndTests.fullSessionStreamsVideoAndForwardsInput` (metrics flow on both sides). On-glass decode→present only exercised in RenderCore's probe window |
| P0-7 | One-click Disconnect, prominent sharing indicator, immediate stop on Host | Done (logic) / manual UI check pending | `ActiveSharingBanner` `Sources/AppUI/HostView.swift:229`, Stop Sharing `:259`; menu-bar extra `Sources/AppUI/SwiftDeskScenes.swift:28`; Session menu ⌘. / ⇧⌘D; `HostSession.stopSharing()` `HostSession.swift:304`; tests `EndToEndTests.hostStopSharingEndsTheViewerSession`, AppUI `PresentationTests` (menu-bar state). Red menu-bar image not visually verified |
| P0-8 | No video, audio, keystroke or clipboard logging | Done | audit of every `Logger`/`Log.*`/`print` call (integration pass): lifecycle and counts only; input logger logs authorization only `Sources/InputCore/HostInputInjector.swift:63-65`; signposts carry frame ids, sizes and input **sequence numbers** only (`Sources/DiagnosticsCore/Signposts.swift`, `ControlMessage.inputSequence` in `Sources/SessionCore/SessionSeams.swift`); the only persistence is the trusted-host list (address, port, fingerprint, name) `Sources/SessionCore/TrustedHostStore.swift:36` |

## 2. Performance targets (§2)

All **Needs 2-Mac test**. See `docs/MEASUREMENTS.md` §3 for the table and procedures. Loopback-only numbers that
exist: approve→first decoded frame 0.29–0.33 s on 127.0.0.1; local pipeline source→decodeDone p50 ~7 ms.

## 3. Core UX (§4)

| Requirement | Status | Evidence |
|---|---|---|
| Host: choose "Share this Mac" | Done | `AppRole.host`, `Sources/AppUI/HostView.swift` |
| Host: check Screen Recording and Accessibility, explain why, let macOS prompt | Done (UI) / Needs manual check | `PermissionCard` in `Sources/AppUI/Components.swift`; `ScreenCapturePermission` (`CGRequestScreenCaptureAccess`) `Sources/CaptureCore/ScreenCapturePermission.swift:18`; `AccessibilityPermission` (`AXIsProcessTrustedWithOptions`) `Sources/InputCore/AccessibilityPermission.swift:15`. `NSScreenCaptureUsageDescription` omitted: not found in this SDK's headers (README explains) |
| Host: choose one display; show host name, LAN and Tailscale IPs | Done | display picker + addresses `Sources/AppUI/HostView.swift`; `DisplayInfo.activeDisplayIDs()` now falls back to online displays when all are asleep `Sources/CaptureCore/DisplayInfo.swift:61`; `AddressPresentation` (AppUI tests) |
| Host: listen securely; on connection show peer identity + Allow Control / Deny | Done | `ApprovalSheet` `Sources/AppUI/HostView.swift` (fingerprint, address, version, countdown; Deny = Esc, Allow has no shortcut; title `lineLimit(2)`); `ConnectionRequest` `HostSession.swift:11`; peer-supplied names sanitized by `SessionSupport.displayName` (review security-2, `DisplayNameSanitizingTests`, `EndToEndTests.hostileDeviceNameIsSanitizedInTheRequest`) |
| Host: on Allow start capture, grant control for this session only, persistent indicator + Stop Sharing | Done | `HostSession.startSession` `HostSession.swift:391`; per-session `setAuthorized(true)` `:422`; banner + menu bar |
| Host: on end/loss stop capture, reject events, release held state | Done | single teardown `HostSession.end` `HostSession.swift:490` (router deactivate → `setAuthorized(false)` releases keys/buttons → pipeline stop); tests `EndToEndTests.fullSessionStreamsVideoAndForwardsInput` (DISCONNECT path), **`EndToEndTests.connectionLossWithoutDisconnectStopsCaptureAndReleasesInput`** (added in integration: transport vanishes with Shift held), `InputCoreTests/HostInputInjectorTests.revokeReleasesHeldKeysAndButtonsThenRejects` |
| Viewer: choose "Control a Mac"; connect by hostname/IP; Bonjour optional; save pinned device | Done | `Sources/AppUI/ViewerView.swift`, `ConnectTarget` parsing (AppUI tests), `BonjourDiscovery`, `TrustedHostStore` |
| Viewer: verify identity, obtain approval | Done | `ViewerHandshake` `Sources/SessionCore/ViewerHandshake.swift` (nothing sent before trust), verification sheet; tests `EndToEndTests.viewerRejectingTheHostClosesWithoutHello`, `.wrongPinnedFingerprintFailsWithIdentityChanged` |
| Viewer: aspect-fit Metal view; toolbar with latency/FPS, scaling, Disconnect | Partial | aspect-fit `VideoGeometry.aspectFitRect` (RenderCore tests); toolbar `Sources/AppUI/StreamingView.swift:97-138`. No explicit scaling control: the video always aspect-fits the window (resize scales) |
| Viewer: interact; escape keyboard capture via a local shortcut | Done (logic) / Needs manual check | ⌃⌥⎋ `Sources/InputCore/ViewerInputTranslator.swift:21`; `ViewerSession.handleKey` turns capture off and releases; tests `releaseShortcutIsNotForwardedAndLeavesNoStuckEscape`. Not tried in a real window |
| Viewer: reconnect needs new authorization | Done (deviation, §15) | Host prompts on every connection unless the Host opted into password access (§12), in which case each connection needs a fresh password proof; test `fullSessionStreamsVideoAndForwardsInput` (second, pinned connection still needs approval), `disabledPasswordAccessPromptsAsBefore`. 0.1.4: the "narrowly scoped preference" the PRD anticipates — a Viewer whose allowed session *dropped* may resume without a prompt within 2 min (Host setting, default on, revocable); a deliberate new connection after a Viewer disconnect or Stop Sharing is still prompted (`revokedGracePromptsAgain`, `stopSharingIsNotReconnected`, `silentViewerGetsHeldInputReleasedButKeepsTheSession`) |
| Security UX: no hidden control; Host can always revoke; TCC mandatory | Done | banner + menu bar + Stop Sharing; injection requires `AXIsProcessTrusted()` at authorization time `Sources/InputCore/HostInputInjector.swift:38,60`; test `untrustedProcessNeverInjectsEvenWhenAuthorized`; capture requires Screen Recording (DENY otherwise) `EndToEndTests.missingScreenRecordingIsDenied` |

## 4. Technical architecture (§5)

### Video pipeline

| Requirement | Status | Evidence |
|---|---|---|
| SCShareableContent + SCContentFilter (one display) + SCStream, minimumFrameInterval 1/60, queueDepth 3 (never 1) | Done (code) / Needs 2-Mac test (never run) | `Sources/CaptureCore/CaptureStreamSettings.swift:51-56`, `CaptureConfig.swift` (default 4 since the review, because the encoder retains its newest frame; clamped 3…8); `CaptureCoreTests` (44 run, live capture skipped) |
| App-level pending encode frames 0–1 | Done | one in-flight slot (atomic compare-exchange) in `H264Encoder.encode`, never queued behind; a busy arrival only takes the latest-frame slot and is submitted after a ~1.5-interval quiet period if nothing newer arrives (review latency-2); frames admitted during `reconfigure` are dropped by session generation (review concurrency-1); tests `CodecRoundTripTests.frameArrivingWhileBusyIsEncodedNextInsteadOfLost`, `.newerWaitingFrameReplacesOlderOne`, `.frameAdmittedDuringReconfigureIsDroppedNotQueued`; bench `dropped_backpressure` 1 per run, `waiting_submitted=0 refreshes=0` in live runs |
| 1280×720 or nearest aspect size, encoder-compatible format, no CPU colour conversion | Done (deliberately exceeded, §14) | Sharp: native pixel size up to 1920×1080 (bounds compared with the display's *pixel* size, never upscaled); Balanced and the second Sharp rung: 1280×720; `CaptureGeometry.fit`, `CaptureCoreTests/CaptureStreamSettings.nativeNonRetinaCapture`; 420v BT.709 `CaptureStreamSettings.swift:56`; IOSurface pixel buffers go straight to VideoToolbox |
| H.264 HW, real-time, low-latency RC, no reordering, minimal delay, fallbacks recorded | Done | `H264Encoder.swift:211` (LL + require HW, 3-step fallback), `:260-261` RealTime / AllowFrameReordering=false; `appliedProperties` records rejected `MaxFrameDelayCount`, `MaximumRealTimeFrameRate`, `PrioritizeEncodingSpeedOverQuality` (bench output) |
| 60 fps, ~3 Mbps, adaptive 1–5 Mbps; drop to 960×540, then 30 fps | Done (logic) / Needs 2-Mac test (tuning) | Balanced: exactly this. Sharp (default, §14): per-rung ranges scaled to the encoded picture (1600×900@60 ≤ 8250 kbps, starts at 4000 and probes up; 720p ≤ 5000), drop to 1280×720, then 960×540, then 30 fps; `Sources/SessionCore/AdaptationController.swift`; `SessionCoreTests/AdaptationControllerTests`; `MediaPipelineTests.ladderStepReconfiguresSourceEncoderAndConfig`. Thresholds untuned on real networks |
| Viewer: VT decode to CVPixelBuffer, newest complete frame to Metal via CVMetalTextureCache, no CPU copy | Done | `Sources/RenderCore/YCbCrPipeline.swift:82,110`; test `RenderCoreTests.textureCacheMapsBothPlanesZeroCopy` |
| On loss/corruption discard incomplete data and request a keyframe | Done | `FrameReassembler` + `RecoveryGate` `Sources/WireProtocol/RecoveryGate.swift:34`; `ViewerMediaPipeline.handle` `Sources/SessionCore/ViewerMediaPipeline.swift`; tests `WireProtocolTests` reassembler/gate suites, `MediaPipelineTests.videoStaysLiveUnderThreePercentLoss` (FEC off). Recovery pass: single losses per FEC group are rebuilt from XOR parity before a frame is declared lost (`FrameReassembler.ingestParity`, `Sources/WireProtocol/FEC.swift`); keyframe recovery remains the fallback |
| Validate keyframe strategy under low-latency mode (long/infinite GOP) | Done | measured: no periodic IDR within 2 s in LL mode (CodecCore report); recovery uses `ForceKeyFrame`; on a static screen the retained newest frame is resubmitted as the IDR (review latency-1, `CodecRoundTripTests.keyframeRequestOnAStaticScreenResubmitsTheNewestFrame`) |
| Hide Host cursor; draw Viewer cursor locally | Done (code) / Needs manual check | `CaptureConfig.showsCursor = false`; `RemoteDisplayView` keeps the system arrow (`Sources/RenderCore/RemoteDisplayView.swift:127`) |

### Networking

| Requirement | Status | Evidence |
|---|---|---|
| Native Network.framework, authenticated QUIC + datagrams; spike first | Done | `QUICSpike` (all checks pass, `docs/TRANSPORT.md`); `NWConnectionGroup` over `NWMultiplexGroup` `Sources/TransportCore/PeerConnection.swift:190`; datagram flow `isDatagram` `Sources/TransportCore/QUICConfiguration.swift:50` |
| Peer authentication (pinned identity), never auto-trust in production | Done | mTLS TLS 1.3, client cert required on Host `QUICConfiguration.swift:35-39`; SHA-256 leaf pinning; AUTH channel binding `HostHandshake.receive`; tests `TransportCoreTests.wrongPinFailsFastAndHostNeverSeesTheConnection`, `SessionCoreTests/HostHandshakeTests` |
| LAN by IP; optional Bonjour `_swiftdesk._udp` | Done (loopback/this Mac) / Needs 2-Mac test | `WireConstants.bonjourServiceType`; QUICSpike Bonjour resolve PASS |
| Tailscale by tailnet IP/hostname; report direct vs relay; never expose unauthenticated port | Done (code) / Needs 2-Mac test | `TailscaleProbe` (real CLI, 3 peers: all relayed while idle); Viewer path label `ViewerSession.startPathProbe`; listener requires mTLS before any data, rate-limited per IP before TLS `Sources/TransportCore/HostListener.swift:147` |
| Packetize into datagrams within transport limit; versioned header with session/frame/index/count/timestamp/flags | Done | 32-byte header `Sources/WireProtocol/Datagram.swift:21`; `maxDatagramSize = min(usable, 1150)`; `WireProtocolTests/DatagramTests` |
| Reassemble within short deadline; cap memory; reject malformed/oversized/duplicates; drop expired; no ordering assumption | Done | `FrameReassembler` deadline `Sources/WireProtocol/FrameReassembler.swift:58`, caps `:60`; inbox cap 4096 in `ViewerMediaPipeline`; tests `WireProtocolTests/FuzzTests`, reassembler simulation (1–3 % loss, reorder, duplicates), **`SessionCoreTests/HostileDatagramTests.floodOfHostileDatagramsIsBoundedAndHarmless`** (added in integration) |
| Control types HELLO … DISCONNECT (+ STATS) | Done | `Sources/WireProtocol/ControlMessages.swift`, `ControlCodec.swift`; round-trip + truncation tests |
| Keys/buttons/auth/connect/disconnect reliable and ordered; pointer as latest-state datagrams; seq numbers; release on disconnect | Done | `ViewerConnectionRouter.send` (reliable → stream, pointer → datagram); seq `InputStateTracker.takeSequence` `Sources/InputCore/InputStateTracker.swift:31`; Host drops stale pointer seq (`stalePointerSequenceIsDropped`); release on disconnect (see §3) |
| Pace sending, observe backlog, adapt on RTT/loss/delivery/queue; do not bypass congestion control | Done (logic) / Needs 2-Mac test | per-batch time bound: ≤ 80 ms of video at the target bitrate + the undrained part of the last keyframe may be queued ahead (`HostMediaPipeline.allowedBacklogAhead`, `PeerConnection.sendDatagrams(_:maxQueuedAheadBytes:)`, review latency-3; an absolute cap stays, 1 MiB since 0.1.3, was 256 KiB); adaptation backlog thresholds in ms (350 / 85); Host skips to next keyframe on refusal (`MediaPipelineTests.sendBackpressureSkipsToNextKeyframe`); `AdaptationController.update` uses RTT, loss, Viewer fps, backlog, encoder drops; QUIC congestion control is Network.framework's (not bypassed) |

### Input correctness

| Requirement | Status | Evidence |
|---|---|---|
| Viewer catches NSEvent only inside the focused remote view; emergency escape | Done (logic) / Needs manual check | `RemoteDisplayView` forwards only while `isCapturingInput` (`RenderCoreTests.nothingIsForwardedWhenNotCapturing`); ⌃⌥⎋ |
| Host injects only after Accessibility approval and session authorization | Done | `HostInputInjector.setAuthorized` + `AXIsProcessTrusted()`; router drops input before activation; tests `unauthorizedDropsEverything`, `untrustedProcessNeverInjectsEvenWhenAuthorized`, `EndToEndTests.missingAccessibilityMeansViewOnly` |
| Map viewer coords through scaling, letterboxing and Host display geometry (points ≠ pixels) | Done | `VideoGeometry.normalizedPoint` (RenderCore tests incl. letterbox bars); moves/drags/ups outside the video clamp to its edge (`clampedNormalizedPoint`, review input-3); Host display bounds re-read at session start and on display reconfiguration (`ScreenCapturer.displayFrame` live, review input-1, `EndToEndTests.screenParameterChangeUpdatesTheInputMapping`); `HostCoordinateMapper.globalPoint` `Sources/InputCore/HostCoordinateMapper.swift:13` (tests incl. negative-origin secondary display, `retinaScaleIsIrrelevantBecauseFramesAreInPoints`) |
| Press/hold/drag/double-click, scroll direction, left/right, keycodes + modifiers, release on focus loss/disconnect; US layout first | Done (logic) / Needs 2-Mac test | InputCore tests listed in P0-4; pointer datagrams whose button mask disagrees with the Host's held buttons wait for the reliable button event (review input-2, `pointerAfterADelayedMouseUpIsNotADrag`, `pointerBeforeADelayedMouseDownBecomesTheDrag`); focus loss → `ViewerSession.focusChanged` releases; layouts other than US untested |
| Don't promise injection into secure surfaces | Done | README "Known limitations" |

## 5. Native tuning rules (§6)

| Rule | Status | Evidence |
|---|---|---|
| 1. No JSON on the hot path; compact binary, bounded | Done | WireProtocol is hand-written big-endian (`ByteCoding.swift`); the only JSON is `TailscaleProbe` (CLI output, every 15 s, off the hot path) |
| 2. No JPEG/PNG/WebSocket video/screen polling | Done | ScreenCaptureKit stream + VideoToolbox only (grep: no ImageIO/JPEG/`CGWindowListCreateImage` anywhere in Sources; the only JSON decoding is `TailscaleProbe`) |
| 3. No guaranteed-order video transport | Done | video on QUIC datagrams; reassembler tolerates any order |
| 4. No unnecessary copies | Done | IOSurface buffers capture→encode; decoder output IOSurface → `CVMetalTextureCache` zero-copy (test); one deliberate copy of slice NALs into a CMBlockBuffer in the decoder (documented in CodecCore) |
| 5. Separate control and video | Done | control = reliable QUIC stream, video = QUIC datagrams with a time-based backlog bound (~80 ms + keyframe allowance; 1 MiB absolute cap), on the same connection (shared congestion window, no shared app queue); latency under load is a 2-Mac measurement (`docs/MEASUREMENTS.md` procedure C) |
| 6. One pending/latest video frame; never block SCK callbacks | Done | encoder one-in-flight slot plus a latest-frame slot that is only used on a static screen; encode hands off to its own queue because LL `EncodeFrame` blocks ~2.5 ms (measured); renderer newest-frame slot `Sources/RenderCore/FrameRenderer.swift:96-101`; tests `pendingFramesAreReplacedNewestWins`, `suspendedRendererKeepsOnlyNewestFrame` |
| 7. No actor hops per frame; dedicated queues | Done | `HostMediaPipeline` / `ViewerMediaPipeline` doc comments and code: no `Task {}` or main-actor hop per frame; main actor gets ≤ 2 Hz metrics |
| 8. Instrument capture, encode, enqueue, receive, decode, present | Done | `PipelineSignpost` emitted at `FrameDelivery.swift:128` (capture), `H264Encoder.swift:428` (encoded), `HostMediaPipeline` (netSend), `ViewerMediaPipeline` (netRecv), `H264Decoder.swift:81` (decoded), `FrameRenderer.swift:321` (presented); integration pass removed duplicate `capture`/`presented` emissions and added `input` (seq only) on Viewer send and Host receive |
| 9. Design for 60 Hz first | Done | 60 fps defaults; 120 fps not attempted |
| 10. Optimize by measurement | Partial | headless bench, QUIC loopback session bench, module probes; no Instruments/real input-to-photon data yet |

## 6. Permissions and distribution (§7)

| Requirement | Status | Evidence |
|---|---|---|
| Screen Recording via documented practice (+ usage string where supported) | Partial | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; `NSScreenCaptureUsageDescription` not added (not in this SDK's headers; README documents the decision) |
| Accessibility via `AXIsProcessTrustedWithOptions`; guide to System Settings | Done | `AccessibilityPermission.swift:15`, `openSettings()` |
| Never suppress/masquerade TCC prompts; session visible | Done | no prompt UI imitation; sharing banner/menu bar |
| Stable bundle id; signing/notarization plan | Partial | `com.swiftdesk.app` `Resources/Info.plist:11`; ad-hoc signing verified; Developer ID signing path in `scripts/build-app.sh` untested (no certificate); not notarized |
| Pairing: trusted identity + per-session consent + rate limit + random tokens + no unauthenticated channel | Done | pinning + approval; `ConnectionRateLimiter` 6/min/IP, 30/min global `Sources/TransportCore/ConnectionRateLimiter.swift:22`; DENY(rateLimited) for 60 s after an operator Deny of the same fingerprint, unidentified connections cannot hold the session slot (review security-1); session id/token from `SecRandomCopyBytes` `Sources/SessionCore/SecureRandom.swift:6`; mTLS before any stream |

## 7. Milestone exit criteria (§8)

| Milestone | Exit criterion | Status | Evidence / gap |
|---|---|---|---|
| A — Local loopback | Stable visual pipeline; 720p target; no CPU PNG/JPEG | Partial | Headless 720p60 pipeline stable (58.7–59.5 fps encoded and decoded, `docs/bench`); `LoopbackSession` + Loopback screen with Metal preview exist and run with the synthetic source (`SessionCoreTests/LoopbackSessionTests`). **Gap:** the ScreenCaptureKit source and the on-screen Metal preview have not been run in the app (no Screen Recording grant; tests create no windows) |
| B — Secure LAN transport | Protected, approved connection | Done (loopback) / Needs 2-Mac test | mTLS + pinning + AUTH binding + approval (E2E tests) |
| B | Video remains live under 1–3 % loss | **Done (bench, loopback)** / Needs 2-Mac test | Recovery pass: adaptive XOR FEC (Host default, `HostSession.Configuration.forwardErrorCorrection`) + keyframe fallback. PipelineBench release, 720p60, 3000 kbps, 1150 B, 10 s, default seed, two clean repeats: **52.6 / 52.6 decoded fps at 1 %** and **47.1 / 51.9 at 3 %** (FEC off in the same session: 30.2 / 30.3 and 17.7 / 18.6); 0 % loss unchanged at 58.7 fps with no measurable latency cost, +20 % wire bytes (`docs/bench/recovery-*.txt`, `docs/MEASUREMENTS.md` §2.1). Tests: `WireProtocolTests` FEC suites (33 tests: every loss position, two losses per group, single-fragment frames, hostile parity, expiry/stale interaction, adaptive policy), `MediaPipelineTests.fecKeepsVideoNearFullRateUnderThreePercentLoss` (≥ 90 frames in 3 s at 3 %, debug), `.fecGroupSizeFollowsViewerStats`, `.hostSendsParityAfterDataAndNoneWhenFECIsOff`, `HostileDatagramTests.floodOfHostileParityDatagramsIsBoundedAndHarmless`, `LoopbackSessionTests.packetizedLoopbackRebuildsLostFragmentsWithFEC`. Gaps: no real-network (Network Link Conditioner) run yet; bursty loss longer than a frame's group count is not covered by FEC; residual losses still cost an IDR (LTR not implemented) |
| B | No runaway memory | Done (bounded by construction + tests) | reassembler frame/byte caps, inbox cap, datagram backlog cap; `HostileDatagramTests`, WireProtocol simulation (peak pending ≤ 65 KB). A long-run RSS measurement on a real link is still a 2-Mac task |
| C — Full remote input | Usable Finder, browser, text editing | Needs 2-Mac test | InputCore logic complete and tested; no real injection run |
| C | No stuck held keys after disconnect | Done (logic) / Needs 2-Mac test | Viewer releases before DISCONNECT (E2E key-up test); Host releases on deauthorize, including on connection loss (new E2E test) |
| D — Latency optimization and diagnostics | Local cursor overlay; adaptive resolution/bitrate; latest-frame discipline; RTT/FPS/loss/encode/decode metrics | Done (code) | see §4/§5 rows |
| D | Test 2.4/5 GHz Wi-Fi and wired; loss/reorder; Host sleep / app quit; permission revoked; peer reconnect | Partial | loss/reorder (WireProtocol simulation, bench), permission revoked (`captureRevokedBySystemDisconnectsWithPermissionRevoked`, `accessibilityRevokedMidSessionDropsToViewOnly`), reconnect (pinned second connection), app quit (bounded `shutdown`, AppUI tests). Wi-Fi/wired and Host sleep: Needs 2-Mac test |
| D | Measure and report p50/p95 LAN click-to-photon | Not done | **NOT YET MEASURED — requires two Macs** (`docs/MEASUREMENTS.md` §3, procedure A) |
| E — Tailscale | Connect by tailnet IP/hostname; report direct vs relay; Host still approves; works across networks without a project server | Needs 2-Mac test | code paths exist (TailscaleProbe, path label, same approval flow); no cross-network run |

## 8. QA / definition of done (§9)

| Item | Status | Evidence |
|---|---|---|
| Both roles install and run on macOS 15+ with the tested toolchain | Partial | builds for macOS 15 target, launched on macOS 27.0.1; not run on a macOS 15 machine |
| Permission requests explained; deny paths degrade safely; never bypass TCC | Done (logic) | no Screen Recording → DENY(permissionsMissing) (`missingScreenRecordingIsDenied`); no Accessibility → view-only (`missingAccessibilityMeansViewOnly`); revocation mid-session handled |
| Session acceptance required before control; Host can revoke any time | Done | approval gate + `stopSharing`; E2E tests |
| Input matrix: modifiers, drag, scrolling, resize, zoom, network drop/reconnect, wrong identity, malformed datagrams, stale packets | Partial | modifiers/drag/scroll (InputCore tests); wrong identity (TransportCore + E2E); malformed/stale (Fuzz + HostileDatagramTests + reassembler tests); connection drop (new E2E test); reconnect (E2E). Resize/zoom and real-network drop: Needs 2-Mac test |
| Viewer never renders an old frame once a fresher complete frame exists | Done | newest-frame slot taken after `nextDrawable()` (`FrameRenderer.swift:177-207`); reassembler delivers strictly increasing ids; tests `pendingFramesAreReplacedNewestWins`, `rendersNewestFrameOnRenderQueue`, E2E `nonIncreasing == 0` |
| Connection loss clears session keys and input state; no crash or unbounded memory | Done (loopback) | `HostSession.end` drops router/handshake/pipeline/session id; Viewer `teardown` releases input and drops the router; new connection-loss E2E test; bounded buffers (above) |
| Performance report: p50/p95 input-to-photon, path, FPS, bitrate, drops, machine specs | Partial | `docs/MEASUREMENTS.md` has machine specs and every local number; input-to-photon and path results **NOT YET MEASURED — requires two Macs** |

## 9. Changes made in the integration pass

- `Sources/CaptureCore/DisplayInfo.swift`: when every display is asleep (0 active), list online non-mirrored displays
  instead of nothing. Fixed the one failing test (`HostSessionEnvironmentTests.environmentIsPopulated`) at the root.
- `Sources/TransportCore/BonjourBrowser.swift`: callback moved out of a bare `Mutex<Closure?>` into a struct field (the
  thunk-chain stack-overflow pattern CaptureCore found).
- `Sources/SessionCore/*`: removed duplicate `capture`/`presented` signposts; the synthetic source emits `capture` like
  ScreenCapturer; added `input` signposts (sequence numbers only) on Viewer send and Host receive;
  `ViewerMediaPipeline.healthCounters()` (internal, for diagnostics/tests).
- `Sources/PipelineBench`: `--dup-keyframes` to reproduce the production keyframe duplication; `dup_keyframes` key in
  the RESULT line; self-test 62 checks.
- New tests: `DiagnosticsCoreTests` (15, replacing the placeholder), `SessionCoreTests/ConnectionLossTests`,
  `HostileDatagramTests`, `InputSequenceTests`.
- Docs: `docs/MEASUREMENTS.md`, this file, refreshed `docs/bench/*`, `docs/TRANSPORT.md` re-run section, README
  status rows; `.gitignore` covers `.build/`, `build/`, `DerivedData/`, `xcuserdata/`, `.DS_Store`.

## 10. Changes made in the recovery pass (Milestone B loss gap)

- `Sources/WireProtocol/FEC.swift` (new): `FECLayout` (interleaved groups, XOR helper), `ParityPacketHeader` (32-byte
  header, magic `'F'`), `FECPolicy` (adaptive K from loss reports, hysteresis), `FrameReassembler.Stats.lossEstimate`.
- `Sources/WireProtocol/Datagram.swift`: video header byte 3 = `fecGroupSize`; `Datagram.parity`; `VideoPacketizer`
  `packetize(..., fecGroupSize:)` appends parity after the data, `parityCount(forFrameBytes:fecGroupSize:)`.
- `Sources/WireProtocol/FrameReassembler.swift`: `ingestParity`, `ingest(_ datagram:)`, immediate single-loss
  rebuild with length/padding validation, parity under the byte budget, new FEC counters in `Stats`.
- `Sources/SessionCore`: `HostMediaPipeline` sends parity with K from `FECPolicy`, updated from STATS;
  `ViewerMediaPipeline` routes parity and reports loss with `lossEstimate`; `LoopbackPipeline` (packetize mode) does
  both, with 1 s loss feedback; `HostSession.Configuration.forwardErrorCorrection`,
  `LoopbackSession.Options.forwardErrorCorrection`, `LoopbackMetrics.fecFragmentsRecovered` / `fecGroupSize`.
- `Sources/PipelineBench`: `--fec`, `--fec-k K`; RESULT keys `fec`, `parity_datagrams`, `fragments_recovered`,
  `fec_k_mean`, `decode_fps`; self-test 73 checks.
- No HELLO/CONFIG change and no protocol version bump: receivers without FEC drop parity (`badMagic`) and ignore
  header byte 3 (`docs/CONTRACT.md`).
- LTR recovery (`kVTCompressionPropertyKey_EnableLTR`, `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`,
  `kVTEncodeFrameOptionKey_ForceLTRRefresh`, `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`, all macOS 12+
  in this SDK's `VTCompressionProperties.h`) was **not** implemented: FEC alone met the goal, and LTR needs a new
  control message (old peers reject unknown control types, so it needs negotiation) plus decoder-gate changes.

## 11. Review (2026-11-03)

Fixes for the adversarially verified review findings. Verification from a clean scratch path: `swift build
--scratch-path .build/final` debug and `-c release` 0 warnings / 0 errors; `swift test --scratch-path .build/final`
486 tests in 66 suites, 0 failures, 3 skipped (+24 regression tests); `xcodegen generate`, `xcodebuild -scheme SwiftDesk
build` succeeded, `xcodebuild test -only-testing:SwiftDeskTests` 58 tests in 12 suites passed; PipelineBench
`--self-test` 73/73; PipelineBench release `--dup-keyframes --fec` two repeats: 58.68 / 58.69 decoded fps at 0 %, 52.49 /
52.57 at 1 %, 51.90 / 53.80 at 3 % (unchanged from the recovery pass; `docs/bench/review-*.txt`, `docs/MEASUREMENTS.md`).

| id | outcome | reason / change |
|---|---|---|
| concurrency-1 | fixed | `H264Encoder` session generation: read after the slot is taken, bumped in `createSession` just before its final `releaseSlot`; `submit` drops (no slot release) a frame from an older generation. Test `frameAdmittedDuringReconfigureIsDroppedNotQueued` |
| concurrency-2 | fixed | `isolated deinit {}` on `MetalVideoView` (subclasses must now be isolated too; `RemoteDisplayView` already was). Test `MetalVideoViewDeinitTests.lastReleaseOffMainDeinitializesOnMain` |
| security-1 | fixed | `HostSession`: pre-AUTH connections live in a bounded pool (`maxPendingHandshakes` = 4, newcomer evicts the oldest from its address) with their own timeouts; only `.requestApproval` takes the slot; DENY(rateLimited) for `deniedPeerCooldown` (60 s) after Deny/approval timeout; `pendingConnectionCount` + `dropPendingConnections()`. No HostView row for the count was added (API only). Tests `silentUnidentifiedPeerDoesNotBlockAnotherViewer`, `fullUnidentifiedPoolEvictsTheOldestFromTheSameAddress`, `deniedViewerIsRateLimitedWithoutANewPrompt`. A peer can still mint fresh certificates; each costs a rate-limited connection |
| security-2 | fixed | `SessionSupport.displayName` (Cc/Cf/Zl/Zp/whitespace → one space, trimmed, 64-Character cap, fallback) for HELLO name/version and ACCEPT host name; ApprovalSheet title `lineLimit(2)` and device-name cell `lineLimit(1)`. Tests `DisplayNameSanitizingTests` (5), `hostileDeviceNameIsSanitizedInTheRequest` |
| latency-1 | fixed | The encoder retains its newest frame; `requestKeyframe()` arms a refresh that resubmits it as the IDR when no capture arrives for ~1.5 frame intervals (`CaptureConfig.queueDepth` default 3 → 4 for the pinned surface). Test `keyframeRequestOnAStaticScreenResubmitsTheNewestFrame` (IDR within 200 ms, nothing further once delivered) |
| latency-2 | fixed | A busy arrival takes a one-slot latest-frame mailbox; a VideoToolbox-dropped newest frame arms the same refresh; both are submitted only after the quiet period, bounded to 40 consecutive refreshes. A first version drained the mailbox immediately on slot release; in the deterministic bench that encoded one extra frame right after the first IDR and moved VideoToolbox from 13 to 40 rate-control drops at 0 % loss (56.1 vs 58.7 fps), so it was changed to the quiet-period rule, which leaves a live stream's encode sequence identical (`waiting_submitted=0 refreshes=0`). Tests `frameArrivingWhileBusyIsEncodedNextInsteadOfLost`, `newerWaitingFrameReplacesOlderOne` |
| latency-3 | fixed | `HostMediaPipeline.allowedBacklogAhead` (80 ms at the target bitrate + undrained keyframe batch) passed per batch through the new `SessionTransport.sendDatagrams(_:maxQueuedAheadBytes:)`; `AdaptationController` backlog thresholds now 350 / 85 ms (equal to the old 128 / 32 KiB at 3000 kbps). Tests `sendQueueBoundIsTimeBasedWithKeyframeAllowance`, `hostPassesTheSendQueueBoundWithEveryBatch`, `sendBacklogThresholdScalesWithBitrate`, `LoopbackIntegrationTests.perBatchQueueBoundRefusesBehindABacklog`. Latency benefit on a constrained link **not measured** (needs procedure C) |
| input-1 | fixed | `startSession` calls `refreshDisplays()`; `ScreenCapturer.displayFrame` reads live `CGDisplayBounds`; during a session `didChangeScreenParametersNotification` re-applies `updateDisplayFrame`. Test `screenParameterChangeUpdatesTheInputMapping` |
| input-2 | fixed | `HostInjectionEngine` defers a pointer state whose `buttonsMask` disagrees with the held buttons and applies it after the button event that makes them agree; safety valve after 64 seqs. Tests `pointerAfterADelayedMouseUpIsNotADrag`, `pointerBeforeADelayedMouseDownBecomesTheDrag`, `persistentMaskMismatchStopsDeferring` |
| input-3 | fixed | `VideoGeometry.clampedNormalizedPoint`; `RemoteDisplayView` sends clamped points for moves/drags/ups (downs outside stay nil) and a clamped move on `mouseExited`. Tests `movesDragsAndUpsOutsideTheVideoAreClampedToItsEdge`, `mouseExitIsForwardedAsAClampedMove`, `clampedPointsMapOutsidePointsOntoTheEdge` |
| input-4 | refuted (not changed) | Documented limitation (`docs/CONTRACT.md`: the Viewer is not told the session is view-only; no protocol field); deny path degrades safely and the Host shows view-only |

## 12. Password access (0.1.2) — deliberate, user-requested addition

PRD §3 lists **unattended access** as an MVP non-goal. The product owner explicitly asked for it ("connect using
password so the other PC does not need to allow"), so it was added as an **opt-in** Host feature, **off by default**;
with it off, behaviour is unchanged (`EndToEndTests.disabledPasswordAccessPromptsAsBefore`, every pre-existing test
unchanged). Start-at-boot / login items remain out of scope: the new "Start listening when SwiftDesk opens" option
only auto-starts the listener when the app is opened (0.1.9 later added a login item, §20; still no boot agent). Version bumped to **0.1.2 (build 3)**.

| Item | Status | Evidence |
|---|---|---|
| Wire: PASSWORD_CHALLENGE 17 (52 B), PASSWORD_RESPONSE 18 (33 B), DENY authFailed 8; strict decode | Done | `Sources/WireProtocol/ControlMessages.swift`, `ControlCodec.swift`; `WireProtocolTests/PasswordMessageTests` (exact bytes, sizes, bad kind, non-canonical "none", fuzz), round-trip/truncation/trailing-byte suites cover the new samples |
| Compatibility, protocolVersion 1 | Done (deviation) | capability marker `"SDC1"` + flags in the AUTH nonce (`Auth.Capabilities`): old decoders treat type 17 as fatal, so only flagged Viewers are challenged. Old Viewer → prompt at once; flagged but silent → 3 s fallback; old Host → new Viewer unchanged. `EndToEndTests.silentAndLegacyViewersGetThePrompt`, `PasswordMessageTests.legacyNonceHasNoCapabilities` |
| Crypto: PBKDF2-HMAC-SHA256 (NFC) + HMAC-SHA256 proof bound to nonce + both TLS fingerprints, constant-time verify | Done | `Sources/SessionCore/AccessPassword.swift`; known-answer vector computed with Python hashlib/hmac `AccessPasswordTests.knownAnswerVector`, `verifyAcceptsOnlyTheExactBinding` |
| Rounds: ~100–200 ms on Apple silicon | Done | 1 000 000 rounds = 146 ms (M4 Pro, `swiftc -O`, best of 5; 600 000 = 88 ms); Viewer accepts 1 000 000…5 000 000 only (floor raised from 100 000 in the review below, `viewerRefusesOutOfRangeIterations`, `outOfRangeRoundsAreDeclined`), derives in a detached task |
| Host storage: keychain `com.swiftdesk.access-password`, `{salt, iterations, key, enabled}`, never the password | Done | `HostAccessPassword`; `hostSetVerifyDisableClear` (blob has no password bytes), `keychainStoreRoundTrip` (unique service, cleaned up) |
| Flow: challenge after AUTH, 3 s without prompt; valid → ACCEPT; none/timeout → prompt (timeout and stale challenge tell the Viewer); wrong → DENY(authFailed) | Done | `HostHandshake` (`.awaitingPassword`, `.sendChallenge`, `.passwordAccepted`), `HostSession`; `HostPasswordHandshakeTests` (12), e2e `correctPasswordStreamsWithoutApproval`, `wrongPasswordIsAuthFailed`, `noPasswordFallsBackToThePrompt`, `silentAndLegacyViewersGetThePrompt` |
| Brute force: 5 / 15 min per fingerprint and per IP → 15 min lockout of password attempts (prompt still reachable, see review); 30 / 10 min global → prompt only; success resets fingerprint | Done | `PasswordAttemptLimiter` (pure, bounded memory); `PasswordAttemptLimiterTests` (6), e2e `fiveFailuresLockTheViewerOut` |
| Visibility | Done (logic) / manual UI check pending | `HostPeer.viaPassword`; banner, strip, status row and menu bar read "Controlled via password by <name>" (`HostPeerPresentation`), Host window opens and the Dock bounces once (`AppModel`, `SharingMenuBarLabel`), wrong attempts counted in the Host's Password access section; no Notification Center alert (would need a notification permission prompt). AppUI `PasswordPresentationTests`, `AppModelTests.passwordSessionIsSurfaced` |
| Host UI: toggle, set/change (2 fields, ≥ 8, match), warning, auto-listen | Done (logic) / manual UI check pending | `PasswordAccessSection` in `Sources/AppUI/HostView.swift`, `PasswordFormValidation`; `AppModel.startListeningAtLaunch` (UserDefaults `SwiftDesk.host.startListeningAtLaunch`, default off) applied in `applicationDidFinishLaunching`; `AppModelTests.startListeningAtLaunchIsPersistedAndApplied`, `ViewSmokeTests.hostViewRendersThePasswordSection` |
| Viewer: optional password, remember (keychain `com.swiftdesk.host-password`, account = fingerprint hex, pinned Host only, after success), forget, incorrect-password retry, never before verification | Done | `ViewerSession`, `ViewerHandshake` (`.answerChallenge`, `.declineChallenge`), `SavedHostPasswords`, `ConnectForm`/`TrustedHostRow`; `ViewerPasswordHandshakeTests` (6 incl. `challengeBeforeVerificationEndsWithoutAProof`), `savedHostPasswordsInKeychain`, e2e `passwordIsNotSavedForAnUnpinnedHost` |
| Two-Mac test | Needs 2-Mac test | verified on 127.0.0.1 only; UI not clicked through |

## 13. Password access review (2026-11-03)

A review of the 0.1.2 password-access feature confirmed 7 findings; all 7 are fixed, none skipped. Verification:
`swift build` (debug and `-c release`, clean scratch path) 0 warnings; `swift test` all pass; `xcodebuild` app build
and `-only-testing:SwiftDeskTests` pass; `dist/SwiftDesk-0.1.2.dmg` rebuilt.

| Finding | Severity | Outcome | Change and regression test |
|---|---|---|---|
| security-3: a Host the user trusted without checking could ask for 100 000 rounds and harvest a proof 10x cheaper to crack than the real Host's | low | fixed | `AccessPassword.acceptedIterations = defaultIterations...5_000_000`. Every real Host uses 1 000 000, so a lower floor only helped an attacker. Tests and e2e now use production rounds. `viewerRefusesOutOfRangeIterations` (100 000, 600 000 and 999 999 refused), `outOfRangeRoundsAreDeclined`. README now says to compare the fingerprint before typing a password. Not done: a warning before sending a typed password to a trust-once Host, and a PAKE (SRP/OPAQUE); both remain possible later hardening |
| protocol-1: a proof that arrived after the 3 s fallback was still treated as a password login on the Viewer (unverified password saved, session marked "via password", "Nobody needs to click Allow" shown during the real prompt) | medium | fixed | New reducer effect `HostHandshake.Effect.fallbackToPrompt` (password timeout and stale challenge). `HostSession` sends **PASSWORD_RESPONSE(none) Host → Viewer** before showing the prompt. `ViewerConnectionRouter` forwards it, `ViewerHandshake` maps it (only after a challenge, only kind `none`) to `.passwordFallback`, and `ViewerSession` cancels the proof task and clears `isUsingPassword` / `usedSavedPassword`. Tests: e2e `lateProofAfterTheFallbackIsNotAPasswordLogin` (operator approves: nothing saved, `viaPassword` false on both sides), `silentAndLegacyViewersGetThePrompt` (raw Viewer receives the fallback), reducer `silentViewerTimesOutToThePrompt`, `hostFallbackAfterTheChallengeIsReported`, `hostFallbackWithoutAChallengeIsIgnored`. Wire-compatible: only Viewers that announced `passwordAuth` are ever challenged |
| protocol-2: switching password access off, or changing the password, during a challenge turned a correct proof into DENY(authFailed), counted a failure and deleted the Viewer's saved password | low | fixed | `HostAccessPassword.check(...) -> ProofResult (.valid / .invalid / .stale)`. The reducer maps `.stale` to `.fallbackToPrompt` (no DENY, no failure counted); only `.invalid` is DENY(authFailed). `verify(...) -> Bool` is kept as a wrapper. Tests: `checkTellsStaleFromInvalid`, reducer `staleChallengeFallsBackToThePrompt`, e2e `switchingPasswordAccessOffMidChallengePrompts` (prompt shown, `passwordFailureCount == 0`, no DENY, fallback sent) |
| ux-1: "Change Password…" turned password access back on after the user had switched it off | medium | fixed | `HostAccessPassword.set(password:)` keeps the existing record's `enabled` flag; only the first password (no record) turns access on. Doc comments in `AccessPassword.swift` and `HostSession.setAccessPassword` updated. Test `changingThePasswordKeepsTheSwitch` |
| ux-2: the Host status still promised "You will be asked before anyone can see or control this Mac" while password access was on | medium | fixed | `HostStatusPresentation.make(_:passwordAccess:)` and `MenuBarStatus.make(...passwordAccess:)` (default false, so the text is unchanged when the feature is off). With password access on, the listening/idle text reads "Viewers with the access password can connect without asking; others need your approval". The menu bar shows "Listening on port N · password access on". The permission cards and the Nearby footer mention password sessions. Tests `passwordAccessChangesThePromise` and `idleListeningAndViewerStates` |
| ux-3: after 5 wrong passwords the Viewer was also blocked from asking for approval, despite the banner's advice, and the Host could not lift the lockout | medium | fixed | `PasswordGate.lockedOut` now skips the challenge and returns `.requestApproval`. The lockout covers password attempts only, and the prompt keeps its own deny cooldown and connection rate limits. The Viewer banner advice ("leave it empty to ask the Host for approval") is now true, and the operator can approve, so no separate "Clear lockouts" button is needed. The duplicated "Too many…" DENY text is no longer sent. Host footer text updated. Tests: reducer `lockedOutIsPromptedWithoutAChallenge`, e2e `fiveFailuresLockTheViewerOut` (right password after 5 failures → prompt, approve → normal session; another identity from the same IP → prompt; failure count stays 5) |
| ux-5: README said an unattended Host "only needs SwiftDesk running", but a Host that is only listening holds no sleep assertion | low | fixed (docs) | README and the Host's Password access footer now say the Mac must stay awake and logged in: Energy settings "Prevent automatic sleeping when the display is off" and "Wake for network access". A locked screen shows the lock screen. No code change: holding a sleep assertion while listening would change power behaviour for every listening Host, so it is left as a possible opt-in |

Refuted (no change):

| Finding | Why refuted |
|---|---|
| security-1: another local process can plant the Host password record in the login keychain | Accurate mechanics, but the attacker is same-user code. The app ships without hardened runtime (`ENABLE_HARDENED_RUNTIME: NO`, ad-hoc signed), so such code can already inject into SwiftDesk (for example `DYLD_INSERT_LIBRARIES` through a LaunchAgent) and use its Screen Recording and Accessibility grants directly. The planted record adds nothing. Revisit (authenticated record or data-protection keychain) if hardened runtime is enabled. **Caveat found while building the DMG:** `scripts/build-app.sh` signs with `--options runtime` whenever `SIGN_IDENTITY` is set, and `Resources/SwiftDesk.entitlements` grants no dyld or library-validation exception. So the distributed `dist/SwiftDesk-0.1.2.dmg` *is* hardened, and the refutation's premise holds only for the ad-hoc Xcode/SwiftPM build. For the signed DMG this finding should be re-reviewed as a possible defense-in-depth issue. It was not changed in this pass |
| security-2: per-IP lockout uses the full IPv6 address, so rotating addresses within a /64 avoids it | The same outcome is reachable on IPv4 with LAN aliases, and a new certificate per attempt avoids the fingerprint key either way. The global cap (30 / 10 min → prompt only, no denial of service) is the limit that actually binds, by design |
| ux-4: a typed or saved password is silently ignored when the Host never challenges | Not a defect. The Host never tells the Viewer that no challenge is coming, so the Viewer cannot tell "none" from "not yet". It shows the accurate "Waiting for approval…", and the form placeholder and README say the password is used only if the Host allows password access |

## 14. Native resolution (0.1.3) — deliberate move above the PRD's 1280×720 starting point

User report: "smooth, but too blurry. The Host's (virtual) monitor is 1600×900, no HiDPI; SwiftDesk shows 1280×720."
The PRD's 1280×720 / 2–5 Mbps default (§2, §5) made the Host shrink that desktop by 0.8 (a non-integer resample of
1-pixel text), and the Viewer then stretched it back up bilinearly: two resamples of every glyph. The PRD sets 720p as a
*starting point* for latency, and frame rate and responsiveness are unchanged by this release (same 60 fps, same
latency-first encoder settings, same 80 ms send-queue bound). So 0.1.3 streams the display at its native pixel size by
default and keeps the PRD configuration as a one-click option and as the first fallback rung. Version **0.1.3 (build 4)**.

| Item | Status | Evidence |
|---|---|---|
| Host › Display › Quality: **Sharp** (default) = native resolution up to 1920×1080; **Balanced** = the PRD's 1280×720 and 1–5 Mbps, unchanged; persisted, applies to the next session | Done (logic) / manual UI check pending | `StreamQuality`, `HostSession.streamQuality` / `expectedStreamSize`, `AppModel.hostStreamQuality` (UserDefaults `SwiftDesk.host.streamQuality`), `HostView` picker + "Streams at 1600×900, 60 fps; drops lower on a weak network."; `AdaptationControllerTests.qualityMapsToTheRightProfile`, `AppModelTests.hostStreamQualityIsPersistedAndApplied` |
| Sharp ladder ≤1920×1080@60 → 1280×720@60 → 960×540@60 → 960×540@30 (bounds vs the display's *pixel* size; a 1600×900 1× display streams at exactly 1600×900; a 2880×1800 HiDPI display at 1728×1080 from the backing raster) | Done (logic) / Needs 2-Mac test | `AdaptationController.defaultLadder`, `CaptureConfig` default 1920×1080; `CaptureStreamSettingsTests.nativeNonRetinaCapture`, `.hidpiCaptureUsesPixels`, `CaptureGeometryTests.nativeSharpRung` |
| Bitrate scaled to the *encoded* picture: ceiling 5000 × (pixel rate / 720p60)^1.1 → 1600×900@60 8250, 1080p60 12000 (global cap), 720p 5000, 540p60 2750, 540p30 1250 kbps; floor 40 % of the ceiling; start at 60 % of rung 0's ceiling | Done (logic) / Needs 2-Mac test (tuning) | `Configuration.resolved(sourceWidth:sourceHeight:)` (called by `HostMediaPipeline` with the source's real output size; collapsed rungs dropped); `AdaptationControllerTests.resolvedFor1600x900UsesTheEncodedSize`, `.resolvedDropsRungsThatCollapseToTheSameSize` |
| Lossy links still step down cleanly and come back | Done (logic) / Needs 2-Mac test | congestion cuts continue to the global floor while recurring congestion at/below the rung floor (bursts with short clean gaps included) steps the ladder down; encoder-overload step-downs back off (×2 clean time per overload, rung blocked after 3) (bitrate clamped to the smaller rung's ceiling, also after an encoder-overload step); step-up gate = min(current ceiling, 0.6 × target ceiling); probe step max(250, 5 % of ceiling); `AdaptationControllerTests.sharpStepsDownCleanlyAtTheRungFloor`, `.burstyCongestionStillStepsDown`, `.encoderOverloadBacksOffAndThenBlocksTheRung`, `.overloadStepDownClampsToTheSmallerRungCeiling`, `.stepUpBackToTheNativeRungIsReachable` (back at the native rung within 120 s of clean time) |
| Larger keyframes | Done (logic) | duplicated keyframes and FEC parity kept; the Host's per-batch allowance already scales with the bitrate and the last keyframe batch; `PeerConnection`'s absolute cap raised from 256 KiB to 1 MiB (≈ 0.7 s at 12 Mbps), because 256 KiB was below the Host's own allowance for a duplicated native-size keyframe above ~6 Mbps and refused the P-frames behind it (each refusal = another keyframe) |
| Encoder | Done (measured) | Constrained High (CABAC, 8×8 transform; still no B-frames / reordering) preferred over Constrained Baseline; AutoLevel (1080p60 = Level 4.2). PipelineBench, M4 Pro, synthetic, 6 s each: 1600×900@60 8250 kbps src→encodeDone p50 5.95 ms / p95 10.4 ms; 1920×1080@60 12000 kbps 6.37 / 7.50 ms; 1280×720@60 5000 kbps 5.66 / 6.72 ms, all 60 fps, HW, low-latency RC. `PrioritizeEncodingSpeedOverQuality` is rejected by low-latency sessions (already their behaviour) and kept for the fallbacks; DataRateLimits (1.5× / 1 s) is not binding for a keyframe at these rates |
| Viewer shows the stream pixel for pixel | Done (logic) / manual UI check pending | window snaps at session start to the largest whole magnification of the *native* stream that fits (1:1, or 2:1 pixel doubling), or fills the screen when that would be under 60 % of it (a 1× Host on a Retina laptop) or does not fit; View › Actual Size (⌘0) and a 1:1 toolbar button snap to strict 1:1; adaptation steps never shrink the window (it is sized for the largest stream seen on the display), a step past that size, a Host display change (live point size in CONFIG — the Host re-fits capture and ladder on `didChangeScreenParameters` — or aspect change) and a move to a screen with another backing scale re-snap unless the user resized (`ViewerWindowSizer`); the render view sits on whole device pixels (`PixelAlignedContainer`); the viewport snaps to exactly a whole multiple of the frame size within 2 px and samples luma with nearest filtering, linear otherwise (`VideoGeometry.pixelViewport`, `YCbCrPipeline`); input maps against that exact viewport (`VideoGeometry.videoRect`). Tests: `VideoGeometryTests.viewportWithinTwoPixelsOfTheFrameSnapsToOneToOne`, `.videoRectMatchesTheRendererViewportInPoints`, `.actualSizeOnRetinaShowsTheStreamPixelForPixel`, `.wholeMultiplesAreDrawnExactly`, `.automaticSizingDoesNotShrinkA1xHostOnRetina`, `.automaticSizingPrefersAWholeMagnification`, `YCbCrPipelineTests.nearOneToOneTargetIsDrawnPixelForPixel`, `.exactDoubleTargetIsPixelDoubled`, `ViewerWindowSizerPolicyTests`, `MediaPipelineTests.displayChangeRefitsCaptureLadderAndConfig` |
| HUD | Done | Viewer toolbar and Diagnostics show the *encoded* size from CONFIG ("Encoded resolution") |
| Two-Mac test (1600×900 virtual display, lossy Wi-Fi / Tailscale) | Needs 2-Mac test | not run; real capture on a HiDPI or virtual display not run here (no Screen Recording grant) |

## 15. Dropout resilience and automatic reconnect (0.1.4) — deliberate addition

User report from lossy Wi-Fi: bursts of 0 fps for 3–10 s; the 10 s QUIC idle timeout then ended the session and the
Host operator had to click Allow again. PRD §4 Viewer step 6 says "reconnect requires new authorization unless an
explicit, narrowly scoped pairing preference is later added", and §2 lists unattended access as a non-goal. The
reconnect grace below is that narrowly scoped preference: it covers only a session the operator already allowed
(or one started with the opt-in access password, §12) whose connection dropped, for 2 minutes, from the same
TLS-proven device identity, is a visible Host setting (on by default, `SwiftDesk.host.reconnectWithoutPrompt`) and is
revocable at any time. Everything else still needs the operator. No protocol message was added; protocolVersion 1.

| Item | Status | Evidence |
|---|---|---|
| Capability exchange in both directions (reusable): `PeerCapabilities` in the AUTH nonce (Viewer) and, new, the ACCEPT session token (Host); bit 1 `sessionResume`; a feature is used only when both sides announce it | Done | `Sources/WireProtocol/Capabilities.swift`; `WireProtocolTests/CapabilityTests` (exact bytes, legacy token → [], both-sides rule, wire round trip); `docs/TRANSPORT.md` §3 "Optional features" |
| Keep the session through blackouts: QUIC idle timeout 30 s (was 10 s), 3 s keepalive | Done (config) / Needs 2-Mac test | `QUICConfiguration.idleTimeoutMillis`; QUIC uses the smaller of both peers' values (0.1.3 peers: 10 s) |
| Liveness still prompt: 1 s without anything received = stalled (both peers PING every 500 ms) | Done | `LinkActivity`, `LinkSilenceDetector`; `ConnectionResilienceTests.silenceIsReportedOncePerEpisode`, `.viewerPipelineReportsStallAndRecovery` |
| Host safety: release all held keys/modifiers/buttons after 1 s of silence, session continues | Done | `HostConnectionRouter` 200 ms watchdog → `InputSink.releaseAll()`, `HostSession.isPeerSilent`; e2e `silentViewerGetsHeldInputReleasedButKeepsTheSession` (released once, still authorized and sharing, flag clears when heard again) |
| Viewer: last frame dimmed with "Poor connection" after 1 s without traffic, cleared when it resumes | Done (logic) / manual UI check pending | `ViewerSession.isLinkStalled`, `StreamingView` `PoorConnectionOverlay` |
| Viewer auto-reconnect with back-off 0.5, 1, 2, 4, 8 … s within 60 s, progress + Cancel + Try Now, pinned to the session's certificate | Done (logic) / manual UI check pending | `ReconnectBackoff`, `ReconnectPolicy`, `ViewerSession.State.reconnecting`, `ReconnectOverlay`, `ReconnectPresentation`; `ConnectionResilienceTests.backoffScheduleDoublesToTheCapWithinTheBudget`, `.backoffGivesUpAfterTheBudget`, `.onlyFailuresAndBusyAreRetried`; e2e `droppedSessionReconnectsWithoutASecondPrompt`, `cancelStopsReconnecting`, `hostSettingOffMeansAPromptAndNoAnnouncement`; AppUI `DropoutPresentationTests` |
| Host grace: same fingerprint, allowed or password session, connection dropped ≤ 2 min ago (or still the active session), not revoked (Stop Sharing / Stop Listening / Deny / Require Approval / setting off / password access off or changed); Viewer must announce `sessionResume`; non-modal "Reconnected <peer>" | Done | `ReconnectGrace`, `HostHandshake` `.resumeAccepted`, `HostSession` (`reconnectGrace`, `reconnectedNotice`, `revokeReconnectGrace`, `allowsReconnectWithoutPrompt`); `ConnectionResilienceTests` (grace window, refusals, revoke/consume, password rule, handshake precedence after binding/Screen Recording checks); e2e `droppedSessionReconnectsWithoutASecondPrompt`, `revokedGracePromptsAgain`, `stopSharingIsNotReconnected`, `droppedPasswordSessionResumesAndRespectsTheSwitch` |
| Password sessions: grace applies; outside it the remembered (in-memory) typed or keychain-saved password is used again | Done | `ViewerSession.ReconnectContext.password`; e2e `droppedPasswordSessionResumesAndRespectsTheSwitch` |
| Keyframe storm: one request after a blackout | Done (logic) / Needs 2-Mac test | Viewer `RecoveryGate(maxSilentRerequestIntervalNanos:)` + `noteTraffic()` (10 s outage: ≤ 4 queued requests instead of ~20, exactly one when traffic returns); Host suppression window capped at 400 ms; refused recovery keyframes re-asked at ≤ 2 Hz instead of per frame. `RecoveryGateBlackoutTests` (4), `viewerPipelineReportsStallAndRecovery` |
| Settings persisted | Done | `AppModel.hostAllowsReconnectWithoutPrompt` (`SwiftDesk.host.reconnectWithoutPrompt`), `AppModel.viewerAutoReconnect` (`SwiftDesk.viewer.autoReconnect`), both default on; `AppModelTests.reconnectSettingsArePersistedAndApplied` |
| Pre-existing bug fixed on the way | Done | `ViewerConnectionRouter` dropped every FEC parity datagram (`'F'`) before the pipeline, so parity recovery never ran on a real Viewer (only in pipeline-level tests and the loopback bench) |
| Two-Mac test on lossy Wi-Fi / roaming / Host sleep | Needs 2-Mac test | loopback only: the drop is simulated (`ViewerSession.simulateConnectionLoss`, a raw silent client) |

## 16. Clipboard sharing (0.1.5) — deliberate addition

PRD §3 lists **clipboard sync** among the MVP non-goals (and goal 8 forbids clipboard *logging*). The product owner
asked for AnyDesk-style bidirectional clipboard sharing; it is a deliberate addition, kept inside the PRD's consent
model: it exists only inside an authorized session, both sides have a visible, live switch (default on), and contents
are never logged or persisted. Wire additions are negotiated (capability bit), so 0.1.4-and-older peers see no change.

| Item | Status | Evidence |
|---|---|---|
| Wire: CLIPBOARD_STATE (19, control stream) and CLIPBOARD (20, side stream only), strict codec with per-kind caps checked before reading | Done | `Sources/WireProtocol/Clipboard.swift`, `ControlCodec.swift`; `WireProtocolTests/ClipboardMessageTests` (exact bytes, caps at/over 1 MiB and 16 MiB, hostile length, duplicate/unknown kinds, invalid UTF-8, PNG signature, reserved bits, chunked 3 MiB decode on the side-stream decoder, refused by the 64 KiB control decoder); `ControlMessageTests` samples cover both types |
| Capability bit 2 `clipboard` (reuses `PeerCapabilities`); nothing clipboard-related is sent unless both sides set it | Done | `Capabilities.swift`; e2e `olderViewerGetsNoClipboardTraffic`, `olderHostGetsNoSideStream` |
| Large payloads off the control stream: Viewer-opened second reliable QUIC stream ("side stream", preamble byte 6 = 1), one in flight, latest wins; side-stream types refused on the control stream and vice versa | Done (loopback) | `PeerConnection.openSideStream/sendSide/onSideMessage`, `TransportPreamble.Kind`; `LoopbackIntegrationTests.sideStreamCarriesLargePayloadsBesideTheControlStream` (4 MiB both ways while PING/PONG continues), `.clipboardOnTheControlStreamClosesTheConnection`; `docs/TRANSPORT.md` "Side stream" |
| Text / RTF / PNG (TIFF → PNG) / URL; files skipped; caps text 1 MiB, image 16 MiB after PNG encoding, notice when skipped | Done | `ClipboardPolicy.content(from:)`; `ClipboardPolicyTests` (caps, TIFF conversion with a real bitmap, partial drop), `ClipboardChannelTests.oversizedCopyShowsANotice`, `.copiedFilesAreNotShared` |
| Concealed / transient / auto-generated pasteboard items never read or sent | Done | `ClipboardPolicy.screen(types:)` (types only, so no content read and no paste prompt); `ClipboardChannelTests.concealedContentIsNeverReadOrSent`, e2e `clipboardFlowsBothWaysWithoutEchoes` |
| No echo: own writes tracked by change count plus an origin marker type | Done | `ClipboardEchoGuard`, `ClipboardPolicy.originMarkerType`; `ClipboardChannelTests.receivedContentIsNotEchoedBack`, e2e `clipboardFlowsBothWaysWithoutEchoes` |
| Only inside an authorized session; Host setting respected live (Host data reaches the Viewer only while "Allow clipboard sharing" is on); Host clipboard from before the session not sent | Done | channel created at ACCEPT, stopped at teardown; routers drop clipboard traffic unless active/streaming; e2e `clipboardSwitchesApplyLiveInBothDirections`, the pre-approval check in every clipboard e2e test, `ClipboardChannelTests.hostSendsOnlyCopiesMadeDuringTheSession`, `.hostSwitchedBackOnSendsOnlyNewCopies` |
| Viewer → Host only while the stream window is key (checked when it becomes key, 4 Hz change-count poll while key) | Done (logic) / manual UI check pending | `ViewerSession.streamWindowIsKey`, `NSWindow.didBecomeKeyNotification` observer; `ClipboardChannelTests.viewerReadsOnlyWhileTheStreamWindowIsKey`, e2e `backgroundStreamWindowNeverReadsTheViewerClipboard` |
| macOS paste privacy (15.4+ `NSPasteboard.accessBehavior`): poll `changeCount` only, read contents only when a new copy is about to be shared, skip reads under `.alwaysDeny`, report refused reads, one-line hint pointing to Privacy & Security › Paste from Other Apps | Done (logic) / Needs 2-Mac test | `PasteboardAccessBehavior`, `SystemPasteboard`, `ClipboardChannel.checkLocal`; `ClipboardChannelTests.refusedReadsAreReported`, `.alwaysDenyIsNotEvenTried`; AppUI `ClipboardPresentationTests.accessHintPointsToPasteFromOtherApps`. The real prompt and the `Privacy_Pasteboard` settings anchor were not exercised |
| UI: Host Clipboard section + session row, Viewer Connection toggle, stream-toolbar toggle and notes, menu-bar and Session-menu switches | Done (logic) / manual UI check pending | `HostView`, `ViewerView`, `StreamingView`, `MenuBar`, `SwiftDeskScenes`, `ClipboardPresentation`; AppUI `ViewSmokeTests.clipboardRowsRenderInEveryState`, `ClipboardPresentationTests` |
| Settings persisted | Done | `SwiftDesk.host.allowClipboardSharing`, `SwiftDesk.viewer.shareClipboard` (both default on); `AppModelTests.clipboardSettingsArePersistedAndApplied` |
| Two-Mac test with the real pasteboard | Needs 2-Mac test | tests use in-memory pasteboards (`FakePasteboard`); the e2e harness never touches the real clipboard |

## 17. Remote pointer shape (0.1.6) — deliberate addition

PRD §5 asks to hide the Host cursor from the captured video and draw the Viewer cursor locally, for immediate pointer
feedback; it does not ask for the Host's cursor *shape*. Unlike clipboard sync (§16), it is not among the PRD's
explicit non-goals, but it goes beyond what the PRD specifies (a plain local cursor). The product owner asked for I-beam, resize, pointing-hand, custom and hidden cursors. This is a deliberate addition
that keeps the PRD's principle: the pointer is still painted locally on the Viewer and never waits for video; only
its shape comes from the Host. It exists only inside an authorized session, both sides have a live switch (default
on), the Host's switch stops the Host from even reading its pointer, and images are never logged. Wire additions are
negotiated (capability bit 3), so 0.1.5-and-older peers see no change.

| Item | Status | Evidence |
|---|---|---|
| Wire: CURSOR_IMAGE (21, side stream only, PNG ≤ 320 KiB, ≤ 256 × 256 px, point size and hot spot) and CURSOR_SHAPE (22, control stream, 5 bytes: unavailable / hidden / image id / off), strict codec | Done | `Sources/WireProtocol/Cursor.swift`, `ControlCodec.swift`; `WireProtocolTests/CursorMessageTests` (exact bytes, limits at and over, hostile PNG length rejected before reading, non-canonical ids, non-finite geometry, side-stream decoder accepts what the control decoder refuses); `ControlMessageTests` samples cover both types |
| Capability bit 3 `cursorShape` (reuses `PeerCapabilities`); side stream reused (`PeerCapabilities.sideStreamFeatures`), opened when only pointer shapes need it | Done | `Capabilities.swift`, `ViewerConnectionRouter`; e2e `olderViewerNeverGetsPointerShapes` (no side-stream feature at all), `olderHostLeavesTheArrow` |
| Host: `NSCursor.currentSystem` sampled ≈ 30 Hz only during an active session with the switch on; rendered at up to 2× (≤ 256 px), FNV-1a fingerprint, FIFO cache of 32 ids, CURSOR_SHAPE only on change, CURSOR_IMAGE once per shape; hidden via `CGCursorIsVisible()` or a transparent image | Done (logic) / Needs 2-Mac test | `CursorShapeTracker`, `CursorRendering`, `SystemCursorSource`, `CursorShapeChannel`; `CursorShapeTests` (fingerprint, cache and eviction, change detection, deferral until the side stream opens, failed send/encode, size caps, hot-spot clamp, 2× rendition from a two-representation image, PNG round trip, channel switch and polling). `NSCursor.currentSystem` with other apps' cursors and `CGCursorIsVisible()` with a hidden pointer were not exercised (no second Mac, no foreground app in the test environment) |
| Viewer: definitions cached (64, FIFO), a shape whose definition has not arrived keeps the previous pointer, undecodable PNGs ignored; NSCursor at Host point size × video magnification (0.75–2×), only while capturing and over the video rect; arrow before the first message, for old Hosts, when off | Done (logic) / manual UI check pending | `RemoteCursorState`, `ViewerSession` (`showsRemotePointer`, `remotePointerStatus`, `remotePointer`), `RemoteDisplayView.remotePointer`, `RemotePointerCursor`; `CursorShapeTests` (viewer state), `RenderCoreTests/RemotePointerTests` (scale, cursor geometry, capture/letterbox rules, rebuild on magnification change), e2e `pointerShapeFollowsTheHost` |
| Only inside an authorized session; Host setting respected live | Done | channel created at ACCEPT (only for a Viewer with the bit), stopped at teardown; routers drop pointer traffic unless streaming; e2e checks the pointer is not read before approval, after Stop or with the switch off |
| UI: Host Display toggle with live caption, menu-bar switch while sharing, Viewer Connection toggle, stream-toolbar toggle with status tooltip, Session-menu switches | Done (logic) / manual UI check pending | `HostView`, `ViewerView`, `StreamingView`, `MenuBar`, `SwiftDeskScenes`, `PointerPresentation`; AppUI `PointerPresentationTests`, `ViewSmokeTests` |
| Settings persisted | Done | `SwiftDesk.host.sharePointerShape`, `SwiftDesk.viewer.showRemotePointer` (both default on); `AppModelTests.pointerShapeSettingsArePersistedAndApplied` |
| Two-Mac test with real cursors | Needs 2-Mac test | tests use `FakeCursorSource`; the e2e harness never reads the real pointer, NetBench and the benchmark test turn the feature off |

## 18. System shortcuts and Send Keys (0.1.7) — deliberate addition

PRD §5 asks the Viewer to catch `NSEvent`s "inside the focused remote view only" and to keep a local emergency
escape; the MVP README listed capturing system shortcuts (⌘Tab, ⌘Space, Mission Control, screenshots …) as out of
scope because it needs an event tap. The product owner asked for both a Send Keys menu and an optional capture switch.
Both are deliberate additions beyond the PRD, kept inside its rules: the escape (⌃⌥⎋) still always works and is never
forwarded, the tap exists only while the user controls an authorized session in the focused stream view (so input is
still taken only "inside the focused remote view", just before macOS consumes it), the switch is off by default and
needs an explicit Accessibility grant on the Viewer, and keys are never logged. Nothing changed on the wire (plain
KEY_DOWN / KEY_UP), so every Host version accepts them and no capability bit was needed.

| Item | Status | Evidence |
|---|---|---|
| Send Keys: ⌘Tab, ⌘Space, ⌃⌘Space, Mission Control (⌃↑), App Exposé (⌃↓), Show Desktop (F11), Launchpad / Apps (key code 131), ⇧⌘3 / ⇧⌘4 / ⇧⌘5, ⌥⌘Esc, ⌃⌘Q (asks first); modifiers down, key, modifiers up in reverse, hardware fn / keypad flags on arrows and F-keys; anything held released first | Done (logic) / Needs 2-Mac test | `InputCore/SystemShortcuts.swift` (`SystemShortcut`, `KeyChord.strokes`, `ModifierKeys.intrinsicFlags`), `ViewerInputController.send`, `ViewerSession.send`; `InputCoreTests/SystemShortcutTests` (exact strokes, balance, default chords, flags, descriptions, translator order and sequence numbers); e2e `sendKeysPressesTheShortcutOnTheHost` |
| Host injection at a level where system shortcuts trigger | Done (unchanged) / Needs 2-Mac test | `CGEventPoster` posts at `.cghidEventTap` from a `.hidSystemState` source (since 0.1.0); limits in README and `docs/TRANSPORT.md` "System shortcuts". Which synthetic combinations trigger on a real Host was not tried (no second Mac, no Accessibility grant here) |
| Optional capture: "Send system shortcuts to the remote Mac", default off; active HID-level keyboard tap (listen + filter), Accessibility on the Viewer (`AccessibilityPermission` reused, hint with *Allow…* / *Open Settings…*) | Done (logic) / Needs manual check | `SystemShortcutTap`, `SystemShortcutFilter`, `ViewerSession.updateShortcutTap`, `SystemShortcutCaptureStatus`; `SystemShortcutTests` filter tests; `SystemShortcutCaptureTests`; e2e `shortcutTapFollowsControlFocusAndPermission`, `refusedTapIsReportedAsUnavailable`. The real tap was not installed (no grant in the test environment): `unpermittedTapIsNeverInstalledAndRemoveIsSafe` only checks refusal and removal |
| Tap removed on resign key, capture off, ⌃⌥⎋, app deactivation, reconnect, session end, switch off, permission revoked; never swallows outside the session (gate checked per event; own events, local menus and ⌃⌥⎋ pass) | Done (logic) | arming rule `SystemShortcutCaptureStatus.shouldArm`, re-evaluated on every switch / capture / focus / state change; e2e `shortcutTapFollowsControlFocusAndPermission` walks every transition; filter tests `nothingIsTakenWhileNotArmed`, `releaseShortcutAlwaysStaysLocal`, `ownEventsAndLocalMenusAreNeverTaken` |
| ⌘Q kept sane | Done (0.2.0 review) | as specified: ⌘Q is forwarded only with the switch on (the tap takes it while armed; otherwise `RemoteDisplayView.forwardsQuitShortcut`, mirrored from `sendsSystemShortcuts`, lets `performKeyEquivalent` forward it). With the switch off it is SwiftDesk's Quit, which asks first (`QuitPresentation`) when ⌘Q is pressed with the stream window up. ⌃⌘Q / ⇧⌘Q unaffected. `MetalVideoViewTests.commandQIsForwardedOnlyWhenSystemShortcutsAreSent`, e2e `quitShortcutFollowsTheSystemShortcutSwitch`, `PresentationTests.quitAsksFirstOnlyForCommandQDuringAStream`; README "Keyboard" |
| UI: toolbar ⌘ Send Keys menu (with the switch, filled while active, tooltip status), Session menu, menu-bar panel, Viewer Connection toggle with permission hint, Lock Screen confirmation, start-of-capture note | Done (logic) / manual UI check pending | `StreamingView.SendKeysMenu`, `SendKeysMenuItems`, `ShortcutPermissionHint`, `SwiftDeskScenes`, `MenuBar`, `ViewerView`, `RootView`, `ShortcutPresentation`; AppUI `ShortcutPresentationTests`, `ViewSmokeTests.sendKeysMenuAndPermissionHintRender`, `AppModelTests` |
| Setting persisted | Done | `SwiftDesk.viewer.sendSystemShortcuts` (default off); `AppModelTests.systemShortcutSettingIsPersistedAndApplied` |
| Pre-existing flaky test fixed | Done | `ClipboardEndToEndTests.clipboardSwitchesApplyLiveInBothDirections` raced the Viewer's re-offer of its clipboard (on switching back on) against the Host copy it then checks; the test now waits for that delivery first. Test-only change |

## 19. Address book and recent connections (0.1.8) — deliberate addition

PRD §4 (Viewer step 2) asks only to connect by hostname/IP and "optionally save a pinned, trusted device"; Bonjour is
a convenience. The product owner asked for an AnyDesk-style home with Favorites and Recent Hosts, editable names and a
picture of each Host's screen. This goes beyond the PRD and touches two of its rules, so it is recorded as a deliberate
addition:

- **"No … cloud accounts, proprietary ID directory" (§2 non-goals).** The address book is local only: one JSON file and
  small JPEGs in `~/Library/Application Support/SwiftDesk` on the Viewer, nothing on a server and nothing on the wire.
  Entries are addresses the user actually dialed, not an ID system.
- **"No video … logging" (goal 8) and "no JPEG-per-frame" (§6).** A thumbnail is one downscaled (≤ 320 px) JPEG of the
  last frame the Viewer already decoded, written once when a session ends — never per frame, never on the capture,
  encode or network path, never sent anywhere and never logged. It is still a picture of the remote screen kept on
  disk, so it is opt-out (*Save thumbnails of remote screens*, default on as requested; off deletes every saved
  picture) and covered by *Clear History*; files get file protection (until first unlock) and 0600 permissions, and
  thumbnails are excluded from backups.

Trust is unchanged: an entry's fingerprint is its identity, not a pin. Pins stay in `TrustedHostStore` (set only by
"Remember this Host"), so a click on a card is the same dial as typing the address — pinned addresses go straight to
the Host's approval, others show the verification sheet. Passwords stay in the keychain; the address book holds no
secrets.

| Item | Status | Evidence |
|---|---|---|
| Store: CRUD (record, rename, favorite, remove with thumbnail), merge by certificate fingerprint (one entry for LAN + Tailscale), an address moves to the identity now presenting it, recent cap 20 (favorites never evicted), Clear History, JSON round trip, fail-closed loading (corrupt, future version, bad fingerprints, duplicates, orphaned thumbnails) | Done | `Sources/SessionCore/AddressBook.swift`; `SessionCoreTests/AddressBookTests` (temporary folder) |
| Linkage with `TrustedHostStore`: pin state per address (pinned / unpinned / pinned to another identity), same address key, neither store edits the other | Done | `SavedHost.pinState(of:trusted:)`, `ViewerSession.pinState(of:)`; `AddressBookTests.pinStateFollowsTheTrustedHostStore`, e2e `successfulConnectionIsRecordedWithAThumbnail` |
| Recorded on successful connect only (after ACCEPT, with the TLS-observed fingerprint); not on reject, deny or failure; resume does not duplicate | Done | `ViewerSession` `.startStreaming`; e2e tests in `SessionCoreTests/AddressBookEndToEndTests` |
| Thumbnail of the last decoded frame at session end (user, Host or failure), ≤ 320 px JPEG encoded off the main actor; switch honoured live; no per-frame cost beyond one pointer swap in the existing lock | Done | `FrameSinkSlot.deliver`, `SessionThumbnail`, `ViewerSession.saveThumbnailOfEndedStream`; `AddressBookTests.thumbnailsAreSmallJPEGs` (real 420v IOSurface buffer), e2e (1280×720 → 320×180, switch off, Host-ended session) |
| Storage: Application Support/SwiftDesk, atomic writes, file protection, 0600 / 0700, no secrets or paths in the JSON | Done | `AddressBookTests.filesAreProtectedAndHoldNoSecrets` |
| UI: Favorites and Recent card grids (thumbnail or tinted placeholder, name, address, last connected, favorite star, pin badge), one-click connect, context menu (Connect, Connect Via, Rename…, Add to / Remove from Favorites, Copy Address, Remove); Nearby (Bonjour) and Trusted Hosts sections kept; *Save thumbnails* toggle and *Clear History…* in Connection; Session › Connect To and a menu-bar *Connect To* menu | Done (logic) / manual UI check pending | `AddressBookView.swift`, `ViewerView`, `SwiftDeskScenes`, `MenuBar`, `AddressBookPresentation`; AppUI `AddressBookPresentationTests`, `ViewSmokeTests.addressBookRendersOnTheConnectScreen`, `AppModelTests.quickConnectDialsASavedHost` |
| Setting persisted | Done | `SwiftDesk.viewer.saveThumbnails` (default on); `AppModelTests.saveThumbnailsIsPersistedAndApplied` |
| Real windows, two Macs | Needs manual check | none of the new UI has been clicked through; thumbnails come from loopback sessions with a synthetic source |

## 20. Open at Login (0.1.9) — deliberate addition

PRD §2 lists "unattended access, start-at-boot agent" among the non-goals. Unattended access already became a
user-requested addition in 0.1.2 (§12); the product owner now asked for an "Open at Login" switch so a Host comes back
after a restart. It is recorded as a deliberate addition and kept deliberately narrower than a start-at-boot agent:

- **A login item, not an agent.** `SMAppService.mainApp` opens the normal app after a user logs in. Nothing runs at
  boot or at the login window, no LaunchAgent/LaunchDaemon plist is installed, and no remote login or FileVault unlock
  is attempted (still non-goals). The optional external watchdog LaunchAgent (`com.swiftdesk.watchdog`) is not
  touched; README documents it as optional and that replacing it with Open at Login is planned.
- **No change to authorization.** Opening the app does not listen by itself (*Start listening when SwiftDesk opens* is
  separate and off by default) and every connection still needs approval or the access password. Off by default.
- **The system is the source of truth.** The switch shows `SMAppService.Status` read back after every change, at
  launch and on app activation; SwiftDesk never re-registers on its own.

| Item | Status | Evidence |
|---|---|---|
| Switch in Host › Startup next to *Start listening when SwiftDesk opens*; register / unregister via `SMAppService.mainApp` behind a protocol | Done (logic) / manual UI check pending | `Sources/AppUI/LoginItem.swift` (`LoginItemService`, `SystemLoginItemService`, `LoginItemController`), `HostView.StartupSection`; AppUI `LoginItemTests.switchRegistersAndShowsTheRealStatus` (fake service) |
| Real status: enabled / requires approval (approval note + *Open Login Items…* → `SMAppService.openSystemSettingsLoginItems()`) / not registered / not found; refreshed on activation | Done | `LoginItemPresentation.make`, `SwiftDeskAppDelegate.applicationDidBecomeActive`; `LoginItemTests.presentationFollowsTheSystemStatus`, `.approvalIsRequestedWhenLoginItemsHasItOff`, `.appModelUsesTheInjectedService` |
| Errors mapped (already registered / not registered are success; denied by user, invalid signature, other shown); removal outside SwiftDesk explained, never silently undone; app location (Applications, translocated, elsewhere, not a bundle) | Done | `LoginItemFailure.from`, `LoginItemLocation.classify`; `LoginItemTests.serviceManagementErrorsAreMapped`, `.appLocationIsClassified`, `.presentationExplainsFailuresAndLocations`, `.failuresAreShownAndBenignErrorsIgnored`, `.removalOutsideSwiftDeskIsExplainedAfterRelaunch`; `ViewSmokeTests.hostViewRendersTheStartupSection` |
| Ad-hoc / development signed app | Partial | Probe on macOS 27 (ad-hoc signed bundle): register/unregister succeed without a prompt, repeats throw nothing, never-registered = *not found*, status stays enabled after an ad-hoc re-sign. Launch at the next login, a rebuilt ad-hoc copy, and macOS 26.3 not verified (needs a log-out / the other Mac) |
| Setting | Done | Truth is Login Items; last choice in `SwiftDesk.host.openAtLogin` (explains a removal only) |
| Pre-existing flake fixed (test only) | Done | `AccessPasswordTests.savedHostPasswordsInKeychain` failed once in a full run (keychain read right after write, the same lag `reload` already retries for); it now retries the read briefly |
| Real window, real login | Needs manual check | the Startup section has not been clicked through; login launch untested |

## 21. Review fixes for 0.2.0

Reviewer-verified findings on the 0.1.4–0.1.9 features, fixed before the release. No new message type or capability
bit; nothing changes for 0.1.3 peers.

| Finding | Status | Evidence |
|---|---|---|
| Host read and decoded a side stream (≈ 19 MiB messages) before HELLO / AUTH / approval | Fixed | `PeerConnection.allowSideStream()` (called by `HostConnectionRouter.activate`); before it an extra stream's first receive is parked unread and undecoded (≤ 2 streams, QUIC flow control holds the rest). `LoopbackIntegrationTests.sideStreamCarriesLargePayloadsBesideTheControlStream` checks nothing is identified or delivered before it; `docs/TRANSPORT.md` "Side stream" |
| A password Viewer's automatic reconnect undid *Require Approval* / Stop Sharing | Fixed (Host side, works with older Viewers) | `HostSession.promptedPasswordReturns`: revoking a password grace (Require Approval, Stop Sharing, Stop Listening, Deny) or stopping a password session whose Viewer is silent makes that fingerprint's next password login within max(grace window, 120 s) a prompt (one-shot). e2e `requireApprovalOnAPasswordGracePromptsTheNextPasswordLogin`. Residual: Stop Sharing less than 1 s after a drop the Host has not yet seen as silence |
| Clipboard: a copy between the type screening and the contents reads was sent unscreened | Fixed | `ClipboardChannel.checkLocal` discards the snapshot when `changeCount` moved; `ClipboardChannelTests.copyBetweenScreeningAndReadIsNotSent` |
| Clipboard: a stale local copy (waiting, or converting) overwrote the peer's newer one | Fixed | `received(_:)` drops `pending` and bumps `receivedEpoch`; `.receivedCopyDropsAWaitingLocalOne`, `.receivedCopyDropsALocalOneBeingConverted`. Residual: a copy already on the wire when the peer's arrives still crosses it (no ordering on the wire) |
| Open at Login: stale failure note after a fix in System Settings (reported twice) | Fixed | `LoginItemController.refresh()` clears `failure` when the status changes; `LoginItemTests.failureFixedInSystemSettingsClearsTheNote` |
| Address book: an unreadable / partly undecodable / newer file was replaced and thumbnails deleted | Fixed | lenient per-entry decoding, damaged file renamed `AddressBook.unreadable-<date>.json` before the first save, orphan cleanup only after a clean load, newer version never overwritten; `AddressBookTests.damagedOrNewerFilesAreNeverOverwrittenSilently` |
| Stream toolbar too wide for the 800 pt 1:1 window (min ≈ 905 pt) | Fixed | `StreamToolbar` uses `ViewThatFits` over full / compact / minimal rows; `ViewSmokeTests.streamToolbarFitsNarrowWindows` (1600 … 480 pt, long name, wide numbers) |
| Session › Connect To and the menu-bar Connect To needed the Viewer session first | Fixed | `AppModel(addressBook:)` (app: `.standard()`) feeds the menus until the Viewer exists; choosing a Host creates it. `AppModelTests.quickConnectDialsASavedHost` |
| Version still 0.1.3 (build 4) | Fixed | 0.2.0 (build 5) in `project.yml`, `project.pbxproj`, `Resources/Info.plist`; README / CONTRACT explain the 0.1.4–0.1.9 labels |
| No visible note when *Send system shortcuts* is turned on during a stream without Accessibility | Fixed | `StreamingView` shows `ShortcutPermissionCapsule` (*Allow…*, *Open Settings…*, hide) for 10 s; `ShortcutPresentation.streamNote`; `PresentationTests`, `ViewSmokeTests.sendKeysMenuAndPermissionHintRender` |
| ⌘Q forwarded although the switch was off (spec deviation) | Fixed to spec | §18 "⌘Q kept sane" row; README "Keyboard" |
