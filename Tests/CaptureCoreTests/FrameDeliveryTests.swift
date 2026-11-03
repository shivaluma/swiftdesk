import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization
import Testing
import DiagnosticsCore
@testable import CaptureCore

/// Builds sample buffers shaped like ScreenCaptureKit's: IOSurface-backed 420v image + per-sample attachments.
enum SyntheticSample {
    static func pixelBuffer(width: Int = 64, height: Int = 36) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        try #require(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    static func make(status: SCFrameStatus?, displayMachTime: UInt64? = nil, withImage: Bool = true,
                     pts: CMTime = CMTime(value: 1, timescale: 60)) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        if withImage {
            let image = try pixelBuffer()
            var format: CMVideoFormatDescription?
            try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!,
                                                                  sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        } else {
            try #require(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
                                              refcon: nil, formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 0,
                                              sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                              sampleBufferOut: &sample) == noErr)
        }
        let buffer = try #require(sample)
        if status != nil || displayMachTime != nil {
            let array = try #require(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
            try #require(CFArrayGetCount(array) > 0)
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSMutableDictionary.self)
            if let status { dictionary[SCStreamFrameInfo.status.rawValue] = NSNumber(value: status.rawValue) }
            if let displayMachTime { dictionary[SCStreamFrameInfo.displayTime.rawValue] = NSNumber(value: displayMachTime) }
        }
        return buffer
    }
}

/// Thread-safe sink for delivered frames.
final class FrameCollector: Sendable {
    private let frames = Mutex<[CapturedFrame]>([])
    func append(_ frame: CapturedFrame) { frames.withLock { $0.append(frame) } }
    var all: [CapturedFrame] { frames.withLock { $0 } }
}

@Suite("Frame attachments + delivery")
struct FrameDeliveryTests {
    @Test("Status attachment is read for every SCFrameStatus", arguments: [
        (SCFrameStatus.complete, CaptureFrameStatus.complete), (.idle, .idle), (.blank, .blank),
        (.suspended, .suspended), (.started, .started), (.stopped, .stopped),
    ])
    func readsStatus(raw: SCFrameStatus, expected: CaptureFrameStatus) throws {
        let sample = try SyntheticSample.make(status: raw, displayMachTime: 12345)
        let values = FrameAttachments.read(sample)
        #expect(values.status == expected)
        #expect(values.displayMachTime == 12345)
    }

    @Test("Missing attachments and unknown values are reported, not trusted")
    func missingAndUnknown() throws {
        let bare = try SyntheticSample.make(status: nil)
        #expect(FrameAttachments.read(bare).status == .missing)
        #expect(FrameAttachments.read(bare).displayMachTime == 0)
        #expect(CaptureFrameStatus(rawStatus: 99) == .unknown(99))
    }

    @Test("Only .complete frames are delivered; sequence, timestamps and signposts per frame")
    func deliversOnlyComplete() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        let collector = FrameCollector()
        deliverer.frameHandler = { collector.append($0) }
        deliverer.isDelivering = true

        let before = MonotonicClock.nowNanos()
        let machNow = mach_absolute_time()
        let statuses: [SCFrameStatus?] = [.started, .complete, .idle, .complete, .blank, .suspended, nil, .complete, .stopped]
        for status in statuses {
            deliverer.handle(try SyntheticSample.make(status: status, displayMachTime: machNow))
        }
        let after = MonotonicClock.nowNanos()

        let frames = collector.all
        #expect(frames.map(\.sequence) == [1, 2, 3])
        for frame in frames {
            #expect(frame.captureNanos >= before && frame.captureNanos <= after)
            #expect(frame.width == 64 && frame.height == 36)
            #expect(frame.presentationTime == CMTime(value: 1, timescale: 60))
            #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            // displayTime is mach ticks; converted to the same CLOCK_UPTIME_RAW nanosecond base.
            #expect(frame.displayNanos > 0 && frame.displayNanos <= frame.captureNanos)
        }

        let snap = deliverer.diagnostics.snapshot()
        #expect(snap.framesDelivered == 3)
        #expect(snap.framesStarted == 1)
        #expect(snap.framesIdle == 1)
        #expect(snap.framesBlank == 1)
        #expect(snap.framesSuspended == 1)
        #expect(snap.framesStopped == 1)
        #expect(snap.framesWithoutStatus == 1)
        #expect(snap.displayToCallbackMillis.count == 3)
        #expect(snap.onFrameMillis.count == 3)
        #expect(snap.deliveredFPS > 0)
    }

    @Test("onFrame runs synchronously inside handle()")
    func synchronousCallback() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        let called = Atomic<Bool>(false)
        deliverer.frameHandler = { _ in called.store(true, ordering: .relaxed) }
        deliverer.isDelivering = true
        let seq = deliverer.handle(try SyntheticSample.make(status: .complete))
        #expect(seq == 1)
        let wasCalled = called.load(ordering: .relaxed)
        #expect(wasCalled)   // no async dispatch in between
    }

    @Test("Frames are dropped while not delivering (stopped / stopping)")
    func gatedWhenStopped() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        let collector = FrameCollector()
        deliverer.frameHandler = { collector.append($0) }
        #expect(deliverer.handle(try SyntheticSample.make(status: .complete)) == nil)
        deliverer.isDelivering = true
        #expect(deliverer.handle(try SyntheticSample.make(status: .complete)) == 1)
        deliverer.isDelivering = false
        #expect(deliverer.handle(try SyntheticSample.make(status: .complete)) == nil)
        #expect(collector.all.count == 1)
        #expect(deliverer.diagnostics.snapshot().framesAfterStop == 2)
        // Sequence numbers keep increasing across restarts.
        deliverer.isDelivering = true
        #expect(deliverer.handle(try SyntheticSample.make(status: .complete)) == 2)
    }

    @Test("Complete sample without an image buffer is counted and dropped")
    func missingImage() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        deliverer.isDelivering = true
        #expect(deliverer.handle(try SyntheticSample.make(status: .complete, withImage: false)) == nil)
        #expect(deliverer.diagnostics.snapshot().framesWithoutImage == 1)
    }

    @Test("Delivery works with no handler installed and the handler can be swapped")
    func swapHandler() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        deliverer.isDelivering = true
        #expect(deliverer.handle(try SyntheticSample.make(status: .complete)) == 1)
        let collector = FrameCollector()
        deliverer.frameHandler = { collector.append($0) }
        deliverer.handle(try SyntheticSample.make(status: .complete))
        deliverer.frameHandler = nil
        deliverer.handle(try SyntheticSample.make(status: .complete))
        #expect(collector.all.map(\.sequence) == [2])
        #expect(deliverer.lastSequence == 3)
    }

    @Test("Diagnostics reset clears everything")
    func diagnosticsReset() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        deliverer.isDelivering = true
        deliverer.handle(try SyntheticSample.make(status: .complete))
        deliverer.handle(try SyntheticSample.make(status: .idle))
        deliverer.diagnostics.reset()
        #expect(deliverer.diagnostics.snapshot() == CaptureDiagnostics.Snapshot())
    }

    @Test("Attachment parsing does not bridge to Swift containers (rough per-frame cost bound)")
    func parsingIsCheap() throws {
        let sample = try SyntheticSample.make(status: .complete, displayMachTime: 1)
        let iterations = 100_000
        let start = MonotonicClock.nowNanos()
        var completes = 0
        for _ in 0..<iterations where FrameAttachments.read(sample).status == .complete { completes += 1 }
        let perCallNanos = Double(MonotonicClock.nowNanos() - start) / Double(iterations)
        #expect(completes == iterations)
        // Generous bound for debug builds; a bridging implementation is typically an order of magnitude slower.
        #expect(perCallNanos < 20_000)
    }
}

@Suite("Callback storage regression")
struct CallbackStorageTests {
    /// Regression: a closure stored directly in a `Mutex` was re-thunked on every read; after ~1M reads, calling it
    /// overflowed the stack. 60 fps for 5 hours is ~1M frames.
    @Test("1M handler reads and frame deliveries, then the handler still runs")
    func manyReadsDoNotGrowThunkChain() throws {
        let deliverer = FrameDeliverer(diagnostics: CaptureDiagnostics())
        let count = Atomic<Int>(0)
        deliverer.frameHandler = { _ in count.wrappingAdd(1, ordering: .relaxed) }
        for _ in 0..<1_000_000 { _ = deliverer.frameHandler }
        deliverer.isDelivering = true
        let sample = try SyntheticSample.make(status: .complete)
        for _ in 0..<200_000 { deliverer.handle(sample) }
        deliverer.frameHandler?(CapturedFrame(pixelBuffer: try SyntheticSample.pixelBuffer(), presentationTime: .zero,
                                              captureNanos: 0, sequence: 0))
        let calls = count.load(ordering: .relaxed)
        #expect(calls == 200_001)
    }

    @Test("onStopped survives many reads")
    func stopHandlerManyReads() {
        let display = DisplayInfo(id: 1, name: "T", frame: CGRect(x: 0, y: 0, width: 100, height: 100), pixelWidth: 100, pixelHeight: 100)
        let capturer = ScreenCapturer(display: display, config: CaptureConfig())
        let called = Atomic<Bool>(false)
        capturer.onStopped = { _ in called.store(true, ordering: .relaxed) }
        for _ in 0..<1_000_000 { _ = capturer.onStopped }
        capturer.onStopped?(nil)
        let wasCalled = called.load(ordering: .relaxed)
        #expect(wasCalled)
    }
}
