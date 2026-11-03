# PipelineBench: Milestone A headless loopback

`PipelineBench` runs the Host and Viewer media path back to back in one process, with no network and no display:

source (synthetic 420v IOSurface frames, or ScreenCaptureKit) → `H264Encoder` (one frame in flight) → `VideoPacketizer`
(1150 B datagrams, plus XOR parity datagrams with `--fec` / `--fec-k`) → seeded random datagram loss (applies to data
and parity alike) → `Datagram.parse` → `FrameReassembler` (rebuilds single losses per FEC group) → `RecoveryGate` (a
simulated REQUEST_KEYFRAME calls `encoder.requestKeyframe()` straight away) → `H264Decoder`. With `--fec` the viewer
side computes the same 1 s loss estimate as the Viewer's STATS and the sender adapts K with `FECPolicy`, as the
production Host does (feedback here has no network delay).

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product PipelineBench --scratch-path .build/integration
.build/integration/release/PipelineBench --seconds 10 --mode synthetic --loss 0   # also: --loss 1, --loss 3, --dup-keyframes
.build/integration/release/PipelineBench --seconds 10 --loss 3 --dup-keyframes --fec      # production recovery (adaptive FEC)
.build/integration/release/PipelineBench --seconds 10 --loss 3 --dup-keyframes --fec-k 4  # fixed group size
.build/integration/release/PipelineBench --mode capture                          # needs Screen Recording; exits 2 otherwise
.build/integration/release/PipelineBench --self-test                             # built-in checks (no test target exists)
```

The last line of every run is `RESULT key=value ...`, which scripts can parse. Exit codes: 0 means the run worked,
1 means it failed or decoded nothing, 2 means Screen Recording permission is missing (capture mode only; the bench
never asks for it), and 64 means the arguments were wrong.

## Files in this directory

All produced by the release build on 2026-11-03 on Mac16,11 (Apple M4 Pro, 12 cores, 24 GB), macOS 27.0.1 (26A434),
Xcode 27.2 / Swift 6.4.2, at 1280×720, 60 fps target, 3000 kbps, 1150 B datagrams, 10 s, default loss seed, unless
the file name says otherwise. The integration pass re-ran the 0/1/3 % runs and added the `-dupkf` runs; the
`repeat2`, `repeat3` and `bitrate6000` files are from the earlier module pass on the same machine and day.

| file | run |
|---|---|
| `synthetic-loss0.txt` | 10 s, 0 % loss (integration pass) |
| `synthetic-loss0-repeat2.txt`, `synthetic-loss0-repeat3.txt` | 10 s, 0 % loss, earlier pass (run-to-run variance) |
| `synthetic-loss1.txt` | 10 s, 1 % datagram loss (integration pass) |
| `synthetic-loss3.txt` | 10 s, 3 % datagram loss (integration pass) |
| `synthetic-loss1-dupkf.txt`, `synthetic-loss3-dupkf.txt` | as above with `--dup-keyframes`: keyframe datagrams sent twice, as the production `HostMediaPipeline` does (`duplicateKeyframePackets = true`) |
| `synthetic-loss1-bitrate6000.txt` | 10 s, 1 % loss at 6000 kbps (earlier pass) |
| `capture.txt` | capture mode: exits 2 because this terminal has no Screen Recording permission |
| `self-test-release.txt` | `--self-test`: 62 checks passed (integration pass) |
| `recovery-loss{0,1,3}-dupkf.txt` | recovery pass, FEC **off**, `--dup-keyframes` (the "before" of the FEC change, same binary and session) |
| `recovery-loss{0,1,3}-dupkf-fec.txt` | recovery pass, `--dup-keyframes --fec` (adaptive FEC, the production default) |
| `recovery-loss*-repeat2.txt` | the same six runs repeated (the run before the files above) |
| `recovery-all-runs.txt` | every RESULT line of the recovery pass: four matrix repeats, fixed-K sweeps (default seed and seeds 1–3), early adaptive runs, and the pre-FEC binary baseline |
| `self-test-release-fec.txt` | `--self-test` after the FEC change: 73 checks passed |
| `review-loss{0,1,3}-dupkf-fec-r{1,2}.txt` | review pass (2026-11-03), `--dup-keyframes --fec`, two repeats, release build from a clean `.build/final`; RESULT adds `waiting_submitted` and `refreshes` (encoder latest-frame slot / static-screen refresh; both 0 in live runs) |
| `self-test-release-review.txt` | `--self-test` after the review fixes: 73 checks passed |

## Recovery pass: forward error correction (FEC)

Design (details in `docs/CONTRACT.md`, WireProtocol): every frame gets `ceil(n / K)` XOR parity datagrams over
interleaved groups of at most K data fragments (fragment `i` is in group `i mod G`); each parity carries the XOR of its
members zero-padded to the longest, plus the XOR of their true lengths. The reassembler rebuilds a single missing
fragment per group as soon as the group's parity and other members are in, before the frame would be declared lost.
Parity is sent after the frame's data in the same batch, so it never delays a frame that arrived whole. K adapts
from the Viewer's loss report (`FECPolicy`: < 0.3 % → 10, < 0.8 % → 6, < 2 % → 4, otherwise 3).

Commands: `PipelineBench --seconds 10 --mode synthetic --loss L --dup-keyframes [--fec]`, default seed, release build
(`swift build -c release --product PipelineBench --scratch-path .build/recovery`), 2026-11-03, same machine as below.

### Before / after (files `recovery-*.txt`; two clean back-to-back repeats each)

| loss | FEC | decoded fps | encoded fps | VT-dropped | keyframes | frames lost | KF requests | wire kbps | fragments rebuilt | mean K | recovery p50 ms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 % | off | 58.69 / 58.67 | 58.69 / 58.67 | 13 / 13 | 3 / 3 | 0 / 0 | 0 / 0 | 3116 / 3115 | — | — | — |
| 0 % | auto | **58.69 / 58.68** | 58.69 / 58.68 | 13 / 13 | 3 / 3 | 0 / 0 | 0 / 0 | 3746 / 3745 | 0 / 0 | 8.77 | — |
| 1 % | off | 30.19 / 30.29 | 36.19 / 36.88 | 238 / 230 | 28 / 28 | 28 / 28 | 27 / 27 | 3584 / 3558 | — | — | 36.0 / 34.6 |
| 1 % | auto | **52.60 / 52.58** | 52.80 / 52.78 | 72 / 72 | 4 / 4 | 1 / 1 | 1 / 1 | 4097 / 4095 | 38 / 38 | 4.2 | 18.0 / 17.6 |
| 3 % | off | 17.69 / 18.59 | 33.08 / 33.89 | 269 / 260 | 45 / 44 | 71 / 68 | 44 / 43 | 3966 / 3905 | — | — | 52.9 / 69.6 |
| 3 % | auto | **47.08 / 51.87** | 48.48 / 52.67 | 114 / 73 | 8 / 5 | 7 / 4 | 7 / 4 | 4367 / 4351 | 103 / 120 | 3.3 | 18.5 / 17.4 |

Latency at 0 % loss (the pair of runs in the same encoder mode, `recovery-loss0-dupkf*.txt`): encodeDone→packetized
p50 0.077 → 0.079 ms (p95 0.149 → 0.129), packetized→reassembled p50 0.027 → 0.025 ms, source→decodeDone p50
7.08 → 6.86 ms, p95 7.91 → 7.66 ms. FEC adds no measurable latency; its cost at 0 % loss is bandwidth: +20 % on
the wire (3116 → 3746 kbps) because a ~6-datagram P-frame gets one parity datagram at K = 10. The repeat pair
(`-repeat2`) shows source→decodeDone p50 3.09 vs 4.89 ms, but that difference is in source→encodeDone (2.56 vs 3.94
ms, the known bimodal encoder latency); the FEC stages were 0.026 vs 0.044 ms (packetize) and 0.009 vs 0.016 ms
(reassemble).

Goal check (≥ 50 decoded fps at 1 %, ≥ 40 at 3 %): **met** in both clean repeats (52.6 / 52.6 at 1 %, 47.1 / 51.9
at 3 %). The remaining gap to 58.7 fps is the keyframe fallback: each residual frame loss still costs an IDR, and the
low-latency rate controller drops frames after it (72 VT-dropped frames after a single recovery IDR at 1 %, in both
repeats). LTR-based recovery (`kVTCompressionPropertyKey_EnableLTR` etc., present in the macOS 12+ SDK) would attack
that cost; it was not implemented in this pass.

**Measurement noise.** This machine was shared with other workloads during the pass (load average 5–74). Four matrix
repeats were run; in two of them several runs show 56–180 frames dropped by the one-in-flight encoder rule (normally
1–2), i.e. the hardware encoder was slow for reasons outside the pipeline (0 % loss *without* FEC fell to 40.7 fps in
one of them). Those repeats are kept in `recovery-all-runs.txt` (column `bp`) but not used in the table. In them,
FEC runs decoded 47.8–49.5 fps at 1 % and 39.5–53.8 fps at 3 %, versus 26.2–28.8 and 17.4–18.2 without FEC.

### Choosing K (fixed-K sweep, `--fec-k`)

| loss | K | decoded fps (default seed) | decoded fps (seeds 1 / 2 / 3) | wire kbps (default seed) |
|---|---|---|---|---|
| 1 % | 2 | 58.68 | — | 4934 |
| 1 % | 3 | 57.99 | 55.48 / 58.67 / 56.77 | 4408 |
| 1 % | 4 | 54.10 | 56.68 / 57.17 / 56.70 | 4109 |
| 1 % | 6 | 52.60 | 52.18 / 56.08 / 58.68 | 3803 |
| 1 % | 10 | 50.47 | — | 3635 |
| 3 % | 2 | 47.40 | — | 4967 |
| 3 % | 3 | 48.28 | 51.88 / 50.17 / 56.87 | 4443 |
| 3 % | 4 | 52.87 | 48.79 / 45.20 / 46.38 | 4201 |
| 3 % | 6 | 45.48 | — | 3871 |
| 3 % | 10 | 41.50 | — | 3778 |

Run-to-run spread is several fps (it is dominated by how many frames VideoToolbox drops after each recovery IDR), so
the ladder picks the cheapest K that stayed above the goal: K = 4 around 1 % (mean of the seeded runs 56.9 fps for
+27 % datagrams; K = 3 bought ~0.1 fps for +44 %), K = 3 at 2 % and above (53.0 vs 46.8 fps for K = 4 over the seeded
runs). "0 parity at 0 % loss" was not adopted: it would save the ~17–20 % parity bandwidth but no latency (none was
measured), and the first loss after a quiet period would cost a keyframe until the next 1 s loss report.

## Measured summary (numbers copied from the files above)

| run | encoded fps | VT-dropped | decoded fps | wire kbps | source→encodeDone p50/p95 ms | source→decodeDone p50/p95/p99 ms | frames lost | KF requests | gated | recovery p50 ms |
|---|---|---|---|---|---|---|---|---|---|---|
| loss 0 % | 58.68 | 13 | 58.68 | 3043 | 5.79 / 6.12 | 7.01 / 7.58 / 8.11 | 0 | 0 | 0 | — |
| loss 0 % (repeat 2, earlier) | 59.47 | 4 | 59.47 | 3046 | 5.70 / 6.58 | 6.96 / 8.26 / 12.47 | 0 | 0 | 0 | — |
| loss 0 % (repeat 3, earlier) | 58.67 | 13 | 58.67 | 3042 | 2.62 / 6.27 | 3.18 / 7.80 / 8.97 | 0 | 0 | 0 | — |
| loss 1 % | 37.19 | 228 | 19.50 | 3072 | 5.95 / 6.41 | 7.32 / 9.36 / 74.18 | 42 | 29 | 135 | 36.6 |
| loss 1 %, keyframes ×2 | 36.16 | 238 | 30.17 | 3582 | 5.90 / 6.43 | 7.27 / 8.84 / 9.49 | 28 | 27 | 32 | 36.0 |
| loss 3 % | 34.86 | 251 | 6.89 | 3108 | 5.87 / 6.43 | 7.59 / 10.35 / 97.46 | 94 | 38 | 186 | 354.4 |
| loss 3 %, keyframes ×2 | 33.39 | 266 | 17.80 | 3911 | 5.91 / 6.48 | 7.45 / 9.50 / 10.30 | 70 | 43 | 86 | 69.0 |
| loss 1 %, 6000 kbps (earlier) | 59.97 | 0 | 21.69 | 6187 | 5.41 / 6.27 | 6.54 / 8.93 / 20.51 | 81 | 43 | 302 | 118.4 |

The encoder reported hardware acceleration and low-latency rate control on every run, with the H.264 Constrained
Baseline profile. The session rejected three properties: `MaxFrameDelayCount`, `MaximumRealTimeFrameRate` and
`PrioritizeEncodingSpeedOverQuality`. The decoder was also hardware, and it accepted the `RealTime` property.

### How to read these numbers

- **source→decodeDone** is the local pipeline only: encode, packetize, reassemble and decode. It leaves out network
  transit, capture (in synthetic mode) and render/present.
- **max** always includes the warm-up: the first IDR, plus about 45 ms to create the decoder session.
- The steady encode latency fell into two groups on the same machine: a p50 of about 2.6 ms in one run and about
  5.7–6.1 ms in the others. The cause is unknown (CPU/media-engine power state is the leading guess).
- **Why VideoToolbox drops frames when keyframes are frequent (re-examined in the integration pass).** The earlier
  hypothesis was CodecCore's `DataRateLimits` cap (1.5× over 1 s). A temporary instrumented build tested it at
  1 % loss with the same seed: DataRateLimits removed → 216 VT-dropped / 199 decoded; cap 3× → 228 / 195; cap 4× over
  0.25 s → 216 / 199; unchanged → 228 / 195. **The cap is not the cause.** The drops track the number of IDRs: a
  ~54 KB IDR is ~9 frame budgets at 3000 kbps / 60 fps, and the low-latency rate controller skips roughly 7–8 frames
  after each one to pay for it (29 IDRs × ~7.5 ≈ 216). At 6000 kbps the per-frame budget doubles and no frames are
  skipped. Raising `MinAllowedFrameQP` (26 or 32, to shrink IDRs) changed little on this synthetic content
  (204–228 VT-dropped). The experiment code was reverted; CodecCore is unchanged.
- **Keyframe-only recovery does not keep video at full rate under 3 % loss.** An IDR at 3000 kbps is about 49
  datagrams; at 3 % uniform loss it arrives whole only about 23 % of the time (0.97^49). Sending keyframe datagrams
  twice (the production Host default) lifts this to ~97 % and raises decoded fps from 6.9 to 17.8 at 3 % and from 19.5
  to 30.2 at 1 %, with recovery p50 69 ms / 36 ms. The remaining gap is P-frame loss: every lost P-frame still costs
  an IDR and ~8 skipped frames. (Integration-pass text; the recovery pass added FEC, which closes most of this gap —
  see "Recovery pass" above.)
- In synthetic mode the CPU fills each frame. That costs about 0.06–0.26 ms per 720p frame (it is reported as
  `(harness) synthetic CPU fill`). The source timestamp is taken after the fill, so this cost is not counted in the
  pipeline numbers. The synthetic content includes a per-frame noise strip, so it is harder to compress than a
  typical desktop; real IDR sizes will differ.
