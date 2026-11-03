import CoreMedia
import Foundation
import Testing
@testable import CodecCore

/// Exercises the CMSampleBuffer → wire AVCC conversion with hand-built sample buffers, including the
/// rare path where the format reports a NAL length size other than 4 (VideoToolbox's H.264 encoder uses
/// 4 in practice, so this path cannot be reached through a real session).
@Suite("AVCC writer")
struct AVCCWriterTests {
    // Real parameter sets from a 1280x720 Constrained Baseline stream produced by this encoder.
    private func parameterSets() throws -> (sps: Data, pps: Data) {
        let encoder = try H264Encoder(config: EncoderConfig(width: 640, height: 360))
        defer { encoder.invalidate() }
        let collector = EncodedCollector()
        collector.attach(to: encoder)
        let buffer = SyntheticVideo.makeFrame(width: 640, height: 360, frame: 0)
        try #require(encoder.encode(buffer, presentationTime: .zero, captureNanos: 0, sequence: 0))
        try #require(collector.waitForFrame(encoder))
        let nals = try AVCC.nalUnits(in: collector.all[0].data)
        return (nals[0], nals[1])
    }

    private func makeSample(sps: Data, pps: Data, lengthSize: Int, nals: [Data], notSync: Bool?) throws -> CMSampleBuffer {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(lengthSize), formatDescriptionOut: &format)
            }
        }
        try #require(status == noErr && format != nil)

        var payload = Data()
        for nal in nals {
            var length = nal.count
            var header = [UInt8](repeating: 0, count: lengthSize)
            for i in (0..<lengthSize).reversed() { header[i] = UInt8(length & 0xFF); length >>= 8 }
            payload.append(contentsOf: header)
            payload.append(nal)
        }
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block) == kCMBlockBufferNoErr)
        try payload.withUnsafeBytes { raw in
            try #require(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                                       dataLength: payload.count) == kCMBlockBufferNoErr)
        }
        var sample: CMSampleBuffer?
        var size = payload.count
        try #require(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                               sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                               sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
        if let notSync, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(notSync ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
        }
        return sample!
    }

    @Test(arguments: [1, 2, 4])
    func keyframeGetsParameterSetsAndFourByteLengths(lengthSize: Int) throws {
        let (sps, pps) = try parameterSets()
        let idr = Data([0x65] + [UInt8](repeating: 0x5A, count: 200))
        let sei = Data([0x06, 0x05, 0x01, 0x80])
        let sample = try makeSample(sps: sps, pps: pps, lengthSize: lengthSize, nals: [sei, idr], notSync: nil)
        let unit = try #require(AVCCWriter.accessUnit(from: sample))
        #expect(unit.isKeyframe)
        #expect(try AVCC.nalUnits(in: unit.bytes) == [sps, pps, sei, idr])
    }

    @Test func notSyncSampleIsDeltaFrameWithoutParameterSets() throws {
        let (sps, pps) = try parameterSets()
        let p = Data([0x41, 0x9A, 0x11, 0x22])
        let sample = try makeSample(sps: sps, pps: pps, lengthSize: 4, nals: [p], notSync: true)
        #expect(!AVCCWriter.isSyncSample(sample))
        let unit = try #require(AVCCWriter.accessUnit(from: sample))
        #expect(!unit.isKeyframe)
        #expect(unit.bytes == AVCC.lengthPrefixed([p]))
    }

    @Test func explicitNotSyncFalseIsKeyframe() throws {
        let (sps, pps) = try parameterSets()
        let sample = try makeSample(sps: sps, pps: pps, lengthSize: 4, nals: [Data([0x65, 0x01])], notSync: false)
        #expect(AVCCWriter.isSyncSample(sample))
    }
}
