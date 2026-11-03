# Contributing to SwiftDesk

Thanks for helping make SwiftDesk better! Bug reports, measurements from real networks, and pull requests are all welcome.

## Ground rules

- **No third-party dependencies.** SwiftDesk uses only Apple frameworks (ScreenCaptureKit, VideoToolbox, Network.framework, Metal, CoreGraphics). Please don't add packages.
- **Latency first.** Changes on the capture → encode → network → decode → render path should keep or improve responsiveness. If you change it, include before/after numbers (see below).
- **Measure, don't guess.** Performance claims need a measurement from `PipelineBench`, `NetBench`, or the in-app stats overlay.
- **Match the surrounding code.** Swift 6 strict concurrency, the existing naming, and the existing comment style.

## Building

Requirements: macOS 15 or later, Xcode 16 or later (Swift 6).

```sh
swift build
swift test
scripts/build-app.sh          # builds SwiftDesk.app into ./build
scripts/build-dmg.sh          # universal disk image in ./dist
```

The module layout and the rules between modules are described in [`docs/CONTRACT.md`](docs/CONTRACT.md), and the wire protocol in [`docs/TRANSPORT.md`](docs/TRANSPORT.md).

## Measuring

```sh
swift run -c release PipelineBench --seconds 10                # local capture/encode/decode/render loop
swift run -c release NetBench host|viewer --p12 <identity> ...  # two-Mac network test with synthetic video (options in Sources/NetBench/main.swift)
```

Real-world numbers are recorded in [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md).

## Pull requests

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Keep each PR focused on one change.
3. `swift build` must have no warnings and `swift test` must pass.
4. If the change touches capture, input, transport or rendering, say how you tested it on two Macs.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
