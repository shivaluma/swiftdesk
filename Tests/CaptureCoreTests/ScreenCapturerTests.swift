import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization
import Testing
import DiagnosticsCore
@testable import CaptureCore

/// Lifecycle tests that never reach ScreenCaptureKit (no stream is started), so they run without permission.
@Suite("ScreenCapturer lifecycle (no permission needed)")
struct ScreenCapturerLifecycleTests {
    private let display = DisplayInfo(id: 0xDEAD_BEEF, name: "Test", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                      pixelWidth: 3456, pixelHeight: 2234)

    @Test("Initial outputSize is predicted from the display geometry")
    func predictedOutputSize() {
        let capturer = ScreenCapturer(display: display, config: CaptureConfig())
        #expect(capturer.outputSize == (1670, 1080))   // 3456×2234 px in the default 1920×1080 bounds
        #expect(capturer.isRunning == false)
        #expect(capturer.appliedSettings == nil)
    }

    @Test("stop() without start() is a no-op and idempotent")
    func stopIsIdempotent() async {
        let capturer = ScreenCapturer(display: display, config: CaptureConfig())
        await capturer.stop()
        await capturer.stop()
        #expect(capturer.isRunning == false)
    }

    @Test("update(config:) while stopped stores the config and updates outputSize")
    func updateWhileStopped() async throws {
        let capturer = ScreenCapturer(display: display, config: CaptureConfig())
        let smaller = CaptureConfig(maxWidth: 960, maxHeight: 540, fps: 30)
        try await capturer.update(config: smaller)
        #expect(capturer.config == smaller)
        #expect(capturer.outputSize == (836, 540))
        #expect(capturer.isRunning == false)
    }

    @Test("Callbacks can be set, read and cleared")
    func callbacks() {
        let capturer = ScreenCapturer(display: display, config: CaptureConfig())
        #expect(capturer.onFrame == nil && capturer.onStopped == nil)
        capturer.onFrame = { _ in }
        capturer.onStopped = { _ in }
        #expect(capturer.onFrame != nil && capturer.onStopped != nil)
        capturer.onFrame = nil
        #expect(capturer.onFrame == nil)
    }

    @Test("Permission-denied classification")
    func permissionClassification() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(CaptureError.isPermissionDenied(declined))
        #expect(!CaptureError.isPermissionDenied(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)))
        #expect(!CaptureError.isPermissionDenied(CaptureError.displayNotFound(1)))
    }

    @Test("Capturer deallocates (no retain cycle through the stream output)")
    func noRetainCycle() {
        weak var weakCapturer: ScreenCapturer?
        do {
            let capturer = ScreenCapturer(display: display, config: CaptureConfig())
            capturer.onFrame = { _ in }
            weakCapturer = capturer
        }
        #expect(weakCapturer == nil)
    }
}

@Suite("AsyncSerialGate")
struct AsyncSerialGateTests {
    @Test("Critical sections never overlap, even across suspension points")
    func mutualExclusion() async {
        let gate = AsyncSerialGate()
        let inside = Atomic<Int>(0)
        let maxInside = Atomic<Int>(0)
        let completed = Atomic<Int>(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await gate.acquire()
                    let now = inside.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
                    _ = maxInside.max(now, ordering: .sequentiallyConsistent)
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 100_000)
                    inside.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                    completed.wrappingAdd(1, ordering: .relaxed)
                    gate.release()
                }
            }
        }
        let peak = maxInside.load(ordering: .relaxed)
        let done = completed.load(ordering: .relaxed)
        #expect(peak == 1)
        #expect(done == 50)
    }
}

/// Real capture. Runs only when this process already has Screen Recording permission; it never requests it.
@Suite("ScreenCapturer live capture", .enabled(if: CGPreflightScreenCaptureAccess(), "Screen Recording not granted to this process"))
struct ScreenCapturerLiveTests {
    @Test("Captures complete 420v frames at the fitted size, then stops cleanly")
    func liveCapture() async throws {
        let displays = try await ScreenCapturer.availableDisplays()
        let display = try #require(displays.first)
        let capturer = ScreenCapturer(display: display, config: CaptureConfig())
        let collector = FrameCollector()
        capturer.onFrame = { collector.append($0) }
        try await capturer.start()
        #expect(capturer.isRunning)
        let deadline = MonotonicClock.nowNanos() + 3_000_000_000
        while collector.all.isEmpty && MonotonicClock.nowNanos() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await capturer.stop()
        let countAtStop = collector.all.count
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(collector.all.count == countAtStop, "no frames after stop() returned")
        let frame = try #require(collector.all.first)
        #expect(frame.width == capturer.outputSize.width && frame.height == capturer.outputSize.height)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        await capturer.stop()
    }
}
