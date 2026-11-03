# SwiftDesk — measurements

This file separates **what was actually measured on one Mac** from **what the PRD asks to be measured on two Macs**.
Nothing in section 3 has been measured. No number here is an end-to-end (click-to-photon) result.

## 1. Test machine and toolchain

| | |
|---|---|
| Model | Mac16,11 (Mac mini), Apple M4 Pro, 12 CPU cores, 24 GB RAM |
| OS | macOS 27.0.1 (26A434) |
| Display | one external display ("Kuycon G27P"), 5120×2880 pixels, UI 2560×1440 points @ 60 Hz |
| Toolchain | Xcode 27.2 (27B52), Apple Swift 6.4.2, Swift 6 language mode, deployment target macOS 15 |
| Date | 2026-11-03 |
| TCC state of the test process | Screen Recording **not granted** (`CGPreflightScreenCaptureAccess() == false`), Accessibility **not granted** (`AXIsProcessTrusted() == false`). Nothing was requested. |

Because of the TCC state, **every video number below uses a synthetic 420v IOSurface source** instead of
ScreenCaptureKit, **no CGEvent was ever posted**, and the only on-glass (Metal present) numbers come from RenderCore's
module probe window.

## 2. Measured locally

### 2.1 Headless media pipeline (`PipelineBench`, release build)

Conditions: synthetic source, 1280×720, 60 fps target, 3000 kbps target, H.264 hardware encoder with low-latency rate
control (Constrained Baseline), 1150-byte datagrams, seeded uniform random datagram loss, in-process (no network, no
capture, no display), 10 s per run. Raw output and the exact command lines: [`docs/bench`](bench/README.md).

| run | encoded fps | VT-dropped | decoded fps | source→encodeDone p50/p95 ms | source→decodeDone p50/p95/p99 ms | recovery p50 ms |
|---|---|---|---|---|---|---|
| 0 % loss | 58.68 | 13 | 58.68 | 5.79 / 6.12 | 7.01 / 7.58 / 8.11 | — |
| 0 % loss (earlier runs, same day) | 58.67–59.47 | 4–13 | 58.67–59.47 | 2.62–5.70 / 6.27–6.58 | 3.18–6.96 / 7.80–8.26 / 8.97–12.47 | — |
| 1 % loss | 37.19 | 228 | 19.50 | 5.95 / 6.41 | 7.32 / 9.36 / 74.18 | 36.6 |
| 1 % loss, keyframe datagrams ×2 | 36.16 | 238 | 30.17 | 5.90 / 6.43 | 7.27 / 8.84 / 9.49 | 36.0 |
| 3 % loss | 34.86 | 251 | 6.89 | 5.87 / 6.43 | 7.59 / 10.35 / 97.46 | 354.4 |
| 3 % loss, keyframe datagrams ×2 | 33.39 | 266 | 17.80 | 5.91 / 6.48 | 7.45 / 9.50 / 10.30 | 69.0 |

"Keyframe datagrams ×2" is what the production Host does (`HostMediaPipeline.Configuration.duplicateKeyframePackets`,
default true); the bench reproduces it with `--dup-keyframes`. Process CPU was 4.6–5.7 % of one core (including the
synthetic CPU fill). Hardware decoder with `RealTime` on every run; one decoder session per run.

**Recovery pass: forward error correction** (same conditions, release, 10 s, default seed, `--dup-keyframes`; FEC
off vs `--fec`, the adaptive XOR parity the production Host now sends by default). Two clean back-to-back repeats
per row (`docs/bench/recovery-*.txt`):

| run | decoded fps | encoded fps | VT-dropped | keyframes | frames lost | wire kbps | source→decodeDone p50/p95 ms | recovery p50 ms |
|---|---|---|---|---|---|---|---|---|
| 0 %, FEC off | 58.69 / 58.67 | 58.69 / 58.67 | 13 / 13 | 3 / 3 | 0 / 0 | 3116 / 3115 | 7.08 / 7.91 · 3.09 / 3.31 | — |
| 0 %, FEC auto | **58.69 / 58.68** | 58.69 / 58.68 | 13 / 13 | 3 / 3 | 0 / 0 | 3746 / 3745 | 6.86 / 7.66 · 4.89 / 8.09 | — |
| 1 %, FEC off | 30.19 / 30.29 | 36.19 / 36.88 | 238 / 230 | 28 / 28 | 28 / 28 | 3584 / 3558 | 7.63 / 9.12 · 3.13 / 8.12 | 36.0 / 34.6 |
| 1 %, FEC auto (mean K 4.2) | **52.60 / 52.58** | 52.80 / 52.78 | 72 / 72 | 4 / 4 | 1 / 1 | 4097 / 4095 | 7.20 / 8.48 · 4.69 / 8.55 | 18.0 / 17.6 |
| 3 %, FEC off | 17.69 / 18.59 | 33.08 / 33.89 | 269 / 260 | 45 / 44 | 71 / 68 | 3966 / 3905 | 7.89 / 9.81 · 5.63 / 9.29 | 52.9 / 69.6 |
| 3 %, FEC auto (mean K 3.3) | **47.08 / 51.87** | 48.48 / 52.67 | 114 / 73 | 8 / 5 | 7 / 4 | 4367 / 4351 | 7.66 / 8.64 · 5.47 / 8.01 | 18.5 / 17.4 |

- FEC rebuilt 38 (1 %) and 103–120 (3 %) lost fragments per run without any keyframe; frames still lost fell from
  28 → 1 and ~70 → 4–7. The Milestone B goal set for this pass (≥ 50 decoded fps at 1 %, ≥ 40 at 3 %) is met in both
  repeats.
- 0 % loss: no measurable latency cost. The stages FEC touches stayed at encodeDone→packetized p50 0.077 vs 0.079 ms
  and packetized→reassembled 0.027 vs 0.025 ms in the same-encoder-mode pair; the source→decodeDone differences in the
  table come from the bimodal encoder latency (source→encodeDone 2.56 vs 3.94 ms in the second pair). The cost is
  bandwidth: +20 % datagram bytes at K = 10 (each ~6-datagram P-frame gets one parity datagram), +14–15 % at 1 % loss
  and +10–11 % at 3 % relative to the FEC-off runs, whose bytes are inflated by the extra IDRs.
- What is left is the keyframe fallback: each residual frame loss still costs an IDR, after which VideoToolbox's
  low-latency rate control drops frames (72 VT-dropped after one recovery IDR at 1 %). LTR recovery was not
  implemented.
- Noise: the machine was shared (load average up to 74). Two further matrix repeats had external encoder slowdowns
  (56–180 one-in-flight drops instead of 1–2, 0 % loss without FEC down to 40.7 fps); they are listed in
  `docs/bench/recovery-all-runs.txt` and left out of the table. The fixed-K sweep that chose the ladder is in
  `docs/bench/README.md`.

**Review re-run (2026-11-03, after the review fixes; files `docs/bench/review-*.txt`).** Same command
(`--seconds 10 --mode synthetic --loss L --dup-keyframes --fec`, default seed), release build from a clean
`.build/final`, two back-to-back repeats, load average 7–12:

| run | decoded fps | encoded fps | VT-dropped | keyframes | frames lost | wire kbps | fragments rebuilt | mean K | source→decodeDone p50/p95 ms | recovery p50 ms | waiting / refreshes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 %, FEC auto | 58.68 / 58.69 | 58.68 / 58.69 | 13 / 13 | 3 / 3 | 0 / 0 | 3745 / 3746 | 0 / 0 | 8.77 | 6.35 / 8.11 · 6.84 / 7.94 | — | 0 / 0 |
| 1 %, FEC auto | 52.49 / 52.57 | 52.69 / 52.77 | 72 / 72 | 4 / 4 | 1 / 1 | 4090 / 4095 | 39 / 38 | 4.19 | 5.57 / 7.86 · 6.95 / 8.22 | 17.9 / 18.3 | 0 / 0 |
| 3 %, FEC auto | 51.90 / 53.80 | 52.70 / 54.60 | 73 / 54 | 5 / 6 | 4 / 4 | 4353 / 4376 | 120 / 110 | 3.22 | 7.21 / 8.16 · 7.01 / 7.85 | 17.9 / 18.1 | 0 / 0 |

The numbers match the recovery pass: the encoder's latest-frame slot and static-screen refresh never fire in a live
stream (`waiting_submitted=0 refreshes=0`), so the encode sequence is unchanged. A first version of the fix that
submitted a waiting frame immediately on slot release did change it (one extra frame right after the first IDR) and
moved VideoToolbox from 13 to 40 rate-control drops at 0 % loss (56.1 vs 58.7 fps, three alternating A/B pairs against
the pre-review binary, all 40 vs 13); that version was replaced. `--self-test` 73/73
(`docs/bench/self-test-release-review.txt`). The new send-queue bound (`HostMediaPipeline`, review latency-3) is not
exercised by PipelineBench (no transport queue); its effect on a constrained link is **not measured** (procedure C).

What these numbers say:

- The local encode→packetize→reassemble→decode floor is ~7–8 ms p50 at 720p60 (a p50 of ~3 ms was seen in one run;
  the bimodal encode time is not root-caused).
- VideoToolbox's low-latency rate controller skips ~7–8 frames after each ~54 KB IDR at 3000 kbps. An integration
  experiment ruled out CodecCore's `DataRateLimits` cap as the cause (details in `docs/bench/README.md`).
- Keyframe-only recovery does **not** hold 45+ fps under 1–3 % random loss; with FEC (recovery pass, table above)
  the bench decodes 52.6 fps at 1 % and 47–52 fps at 3 % (see `docs/PRD_COMPLIANCE.md`, Milestone B).

### 2.2 Full session over real QUIC on 127.0.0.1 (SessionCore benchmark tests)

Conditions: real `HostSession` + `ViewerSession`, TransportCore QUIC with mutual TLS on 127.0.0.1, synthetic
1280×720@60 source, recording frame sink (no window), debug build, 10 s steady state.
Command: `SWIFTDESK_BENCH=1 swift test --filter SessionCoreTests.Benchmark --scratch-path .build/integration`.

| metric | integration run | module-pass run |
|---|---|---|
| connect → approval request shown on Host | 158 ms | 142 ms |
| approve → first decoded frame on Viewer | 332 ms | 290 ms |
| Host sent fps / bitrate | 60.0 fps / 702 kbps (synthetic content compresses well) | 60.0 / ~702 kbps |
| Host capture→encoded p50 / p95 / max | 5.78 / 6.20 / 8.65 ms | 5.57 / 6.12 / 6.87 ms |
| Host capture→datagrams enqueued p50 / p95 / max | 5.87 / 6.35 / 8.85 ms | 5.66 / 6.30 / 6.97 ms |
| Viewer first packet→decoded p50 / p95 / max | 1.17 / 1.54 / 1.87 ms | 1.18 / 1.51 / 4.90 ms |
| Viewer received / decoded fps | 59.0 / 60.0 | 60.0 / — |
| RTT (PING/PONG on the control stream) srtt / min | 0.49 / 0.21 ms | 0.59 / 0.23 ms |
| frames lost / keyframe requests | 0 / 0 | 0 / 0 |

`LoopbackSession` (no network) in the same run: 60 fps captured/encoded/decoded, capture→encoded p50/p95/max
5.75/5.95/6.30 ms, encoded→decoded 1.28/1.44/3.09 ms, 1 of 595 frames dropped by the one-in-flight rule.

The PRD's "≤ 3 s from approval to first usable frame" is consistent with 0.3 s on loopback, but it is a LAN target
and is listed in section 3.

### 2.3 Transport (`QUICSpike`, release, loopback)

From the integration re-run (earlier run in `docs/TRANSPORT.md` §4):

| metric | value |
|---|---|
| pinned connect → `.ready` (incl. preamble round trip) | 199.7 ms (161 ms earlier); ~80–100 ms per side is a loopback `.waiting` transient |
| control RTT, 1000 PING/PONG on the QUIC stream | mean 0.086, p50 0.072, p95 0.178, p99 0.234, max 0.429 ms |
| datagrams, 4×1150 B every 2 ms (~18 Mbit/s) | 2000/2000 both directions at 0 % simulated loss; 1934/2000 at 3 % simulated loss |
| backpressure, 200 unpaced 64.4 KB batches vs 128 KiB limit | 198 refused, peak 128,800 B pending, drained to 0 |
| idle 15 s with 10 s idle timeout / 3 s keepalive | connection survived, control worked afterwards |
| wrong pinned fingerprint | failed in 75.7 ms; host never hands the connection out |
| rate limiter at 2/min/address | attempts 1–2 ready (154 ms), attempt 3 refused (3146 ms establishment timeout) |
| usable QUIC datagram frame size on loopback | 9156–9164 B, so `maxDatagramSize` = 1150 (the protocol cap) |

### 2.4 Module-level numbers (measured by the module passes on this machine and day; not re-run here)

| module | measurement | result |
|---|---|---|
| CodecCore | VT submit→output, 720p, 3000 kbps, 120 paced frames, debug test | median 2.64 ms, p95 2.81 ms, first frame 34.6 ms |
| CodecCore | synchronous `decode()` per 720p frame | median 0.50 ms (debug), 0.64 ms (release, paced); first frame 52–79 ms (session creation) |
| CodecCore | in low-latency mode `VTCompressionSessionEncodeFrame` blocks until output | 2.5–2.6 ms per call (why the encoder hands off to its own queue) |
| CaptureCore | per-frame delivery overhead (attachments, status filter, signpost, callback), synthetic sample buffer, `-O` | 511 ns/frame |
| RenderCore | decode→present on a real window, 60 Hz display, 2 drawables, producer at 60 fps | p50 28.6 ms, p95 28.6 ms (producer phase-locked to vsync) |
| RenderCore | same, producer at 240 fps | p50 34.2 ms with 2 drawables vs 51.0 ms with 3 (why `maximumDrawableCount` = 2) |
| WireProtocol | reassembler simulation, 2000 frames, 3 % loss + jitter + duplicates | peak pending ≤ 64,832 B; ids strictly increasing; byte-exact frames |

### 2.5 Not measurable on this machine

- ScreenCaptureKit capture latency and real desktop IDR sizes (no Screen Recording grant; `PipelineBench --mode
  capture` exits 2, see `docs/bench/capture.txt`).
- Host-side CGEvent injection latency (no Accessibility grant).
- Anything across a real network: LAN, Wi-Fi, Tailscale direct/relay, path MTU below 1280 B.
- On-glass Viewer FPS and decode→present inside the app window (tests create no windows).

## 3. PRD performance targets — NOT YET MEASURED (requires two Macs)

| PRD metric | MVP target | status | how to measure |
|---|---|---|---|
| Click on Viewer → visual update on Viewer (LAN) | p50 ≤ 80 ms, p95 ≤ 150 ms (stretch 60/100) | **NOT YET MEASURED — requires two Macs** | 240 fps camera or photodiode, ≥ 100 clicks over ≥ 2 sessions (procedure A below) |
| Pointer response on Viewer | visually immediate, ≤ 1 refresh | **NOT YET MEASURED — requires two Macs** (design: the Viewer keeps the local system arrow, `RemoteDisplayView`) | 240 fps camera: mouse movement vs local cursor movement |
| Interactive delivered FPS on LAN | 45+ fps, aiming at 60 | **NOT YET MEASURED — requires two Macs** | Viewer toolbar FPS (on-glass presents/s) during scripted desktop use, p50 over 5 min (procedure B) |
| Video configuration | 1280×720 / 60 fps / ~2–5 Mbps | implemented: Balanced quality = 1280×720@60, 1000–5000 kbps; Sharp (default since 0.1.3) = native size up to 1920×1080@60 with per-rung ranges (1600×900 ≤ 8250 kbps, 1080p ≤ 12000) (`AdaptationController`, `docs/PRD_COMPLIANCE.md` §14); effective bitrate on real desktop content **NOT YET MEASURED** | Toolbar bitrate + Host Diagnostics during procedure B |
| UI/control events never wait behind video | separate streams | by construction (control = QUIC stream, video = QUIC datagrams; the Host refuses a frame when more than ~80 ms of video plus the undrained part of the last keyframe is queued ahead, 1 MiB absolute cap since 0.1.3); latency under load **NOT YET MEASURED — requires two Macs** | Procedure C |
| Connect → first usable frame after approval (LAN) | ≤ 3 s | 0.29–0.33 s on 127.0.0.1 only; **LAN NOT YET MEASURED — requires two Macs** | Stopwatch / screen recording from clicking Allow Control to first frame, 10 trials |
| WAN latency | record RTT and click-to-photon; ambition ~RTT + 80 ms p50 | **NOT YET MEASURED — requires two Macs on different networks with Tailscale** | Procedure A over Tailscale; record `pathDescription` (direct/relay) and RTT |

### Procedures

**A. Click-to-photon (p50/p95).** Full step list and results template: README, "Measuring click-to-photon". In short:
two Macs on wired or strong 5 GHz Wi-Fi; on the Host a full-screen window that turns from black to white on
mouse-down; the Viewer full screen (record the stream size, e.g. 1600×900 Sharp or 1280×720 Balanced); film the Viewer's mouse and screen at 240 fps (≈ 4.2 ms resolution) or
use a photodiode + USB-HID microcontroller; ≥ 100 clicks about 1 s apart over ≥ 2 sessions; latency = frames ×
1000/240 ms; report nearest-rank p50/p95/max plus the Diagnostics panel values (RTT, on-glass FPS, loss,
decode→present, path), both machine models, macOS versions and refresh rates.

**B. Delivered FPS and bitrate under desktop use.** Host: scroll a long web page, drag a Finder window, type in a
text editor for 5 minutes. Viewer: record the toolbar FPS / bitrate / loss every second (or the Host's Diagnostics
grid). Report p50/p5 FPS, mean bitrate, frames lost, keyframe requests. Repeat on wired, 5 GHz and 2.4 GHz Wi-Fi.

**C. Control under video load.** While the Host streams a full-screen video (worst-case bitrate), click and type at
1 Hz and run procedure A on those clicks; compare with procedure A on a static desktop. Also capture an Instruments
trace with the `com.swiftdesk.app` Points of Interest signposts (`input` on Viewer send and Host receive, `capture`,
`encoded`, `netSend`, `netRecv`, `decoded`, `presented`) to split the latency per stage.

**D. Loss / recovery on a real link (Milestone B exit).** On the Viewer Mac, use Network Link Conditioner (Xcode
Additional Tools) with 1 % and 3 % packet loss; stream for 60 s each; record decoded/on-glass FPS, frames lost,
keyframe requests and memory (Activity Monitor) at the start and end. The bench predicts ~52 fps at 1 % and ~47–52
fps at 3 % with FEC (the default), and ~30 / ~18 fps with `HostSession.Configuration.forwardErrorCorrection = .off`.
Network Link Conditioner loss is closer to uniform than real Wi-Fi loss; also record bursty conditions, where the
interleaved FEC groups help only while a burst is shorter than the number of groups in a frame.
