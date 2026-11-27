import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Where decoded pictures go: the screen view's display layer, or a counter in tests.
protocol ScreenFrameSink: AnyObject {
    func show(_ sample: CMSampleBuffer)
}

/// Decodes a stream's H.264 access units with VideoToolbox into IOSurface-backed pixel buffers and hands each picture
/// to a sink as a sample buffer to show at once. Used from the frame pump's thread only. A changed SPS or PPS (a
/// rotation, a new size) makes a new session; an error waits for the next key frame.
final class ScreenDecoder {
    enum Outcome: Equatable {
        case shown
        /// Nothing to show: no picture yet, or waiting for a key frame.
        case skipped
        /// VideoToolbox refused it; ask for a key frame.
        case failed(OSStatus)
    }

    private weak var sink: ScreenFrameSink?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var waitingForKey = true
    /// The picture VideoToolbox handed back for the frame being decoded (decoding here is synchronous).
    private var output: (CVImageBuffer?, OSStatus) = (nil, noErr)
    private(set) var decoded = 0
    /// The latest decode time, for `decoded {ms}`.
    private(set) var lastMilliseconds: Double = 0

    init(sink: ScreenFrameSink?) {
        self.sink = sink
    }

    deinit { invalidate() }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    /// One whole access unit. `key` comes from the frame's flags.
    func decode(_ data: UnsafeRawBufferPointer, key: Bool) -> Outcome {
        let unit = H264.accessUnit(data)
        if let newSPS = unit.sps, let newPPS = unit.pps, newSPS != sps || newPPS != pps || session == nil {
            guard let description = H264.formatDescription(sps: newSPS, pps: newPPS) else { return .failed(kVTVideoDecoderBadDataErr) }
            invalidate()
            sps = newSPS
            pps = newPPS
            format = description
            guard makeSession() else { return .failed(kVTVideoDecoderNotAvailableNowErr) }
        }
        if waitingForKey && !key { return .skipped }
        guard let session, let format, unit.hasPicture else { return .skipped }
        guard let sample = sampleBuffer(unit.avcc, format: format) else { return .failed(kVTVideoDecoderBadDataErr) }
        output = (nil, noErr)
        let start = CACurrentMediaTime()
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &flags)
        // Synchronous: the picture is out before this returns (no B-frames on these streams).
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        lastMilliseconds = (CACurrentMediaTime() - start) * 1000
        guard status == noErr, output.1 == noErr else {
            waitingForKey = true
            return .failed(status != noErr ? status : output.1)
        }
        waitingForKey = false
        guard let image = output.0, let shown = displaySample(image) else { return .skipped }
        decoded += 1
        sink?.show(shown)
        return .shown
    }

    /// After an error the next key frame starts again.
    func waitForKeyFrame() { waitingForKey = true }

    private func makeSession() -> Bool {
        guard let format else { return false }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            // IOSurface-backed, so the layer shows the decoder's own memory.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                guard let refcon else { return }
                let decoder = Unmanaged<ScreenDecoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.output = (image, status)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var made: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback,
                                                  decompressionSessionOut: &made)
        guard status == noErr, let made else { return false }
        VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = made
        waitingForKey = true
        return true
    }

    private func sampleBuffer(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// A decoded picture as a sample buffer the display layer shows straight away.
    private func displaySample(_ image: CVImageBuffer) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: description,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
