import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/*
 * Mac screen to phone: frames in, H.264 Annex B access units out, with VideoToolbox. The hardware encoder is
 * requested, not required, so a Mac without one (a VM) still streams; real time, no frame reordering (no B-frames),
 * low-latency rate control where macOS offers it, key frames on demand, SPS and PPS in front of every key frame.
 * A key frame asked for on a still screen re-encodes the last frame, so the viewer never waits for motion.
 */

/// One encoded access unit, ready for the wire.
struct MacScreenAccessUnit {
    let data: Data
    let key: Bool
    let parameterSets: Bool
    /// When the frame was captured, on the monotonic clock.
    let captureMillis: Int64
    let captureMicros: Int64
}

/// What the stream asks of an encoder; tests and the synthetic path use fakes.
protocol MacScreenEncoding: AnyObject {
    var onAccessUnit: ((MacScreenAccessUnit) -> Void)? { get set }
    func encode(_ image: CVPixelBuffer, captureMicros: Int64)
    func requestKeyFrame()
    func setBitrate(_ bitsPerSecond: Int)
    /// A new size (the shared display changed): the next frame is a key frame of that size.
    func resize(width: Int, height: Int)
    func invalidate()
}

func monotonicMicros() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000) }

final class MacScreenEncoder: MacScreenEncoding, @unchecked Sendable {
    var onAccessUnit: ((MacScreenAccessUnit) -> Void)?

    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.display.encoder", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var width: Int
    private var height: Int
    private let fps: Int
    private var bitrate: Int
    private var forceKey = true
    private var lastImage: CVPixelBuffer?
    private var lastEncodeMicros: Int64 = 0
    private var frameIndex: Int64 = 0
    private var invalidated = false
    /// Whether VideoToolbox reports a hardware encoder; nil when the encoder does not answer (the low-latency
    /// encoder, `h264.rtvc`, does not support the query; the hardware-preferred fallback is `ave.avc`).
    private(set) var hardware: Bool?
    private(set) var encoderID: String?

    init(width: Int, height: Int, fps: Int = MacScreenRates.fps, bitrate: Int = MacScreenRates.startBitrate) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    deinit { session.map { VTCompressionSessionInvalidate($0) } }

    func encode(_ image: CVPixelBuffer, captureMicros: Int64) {
        queue.async { self.encodeNow(image, captureMicros: captureMicros) }
    }

    func requestKeyFrame() {
        queue.async {
            self.forceKey = true
            // A still screen delivers no new frames: encode the last one again as a key frame.
            if let last = self.lastImage, monotonicMicros() - self.lastEncodeMicros > 50_000 {
                self.encodeNow(last, captureMicros: monotonicMicros())
            }
        }
    }

    func setBitrate(_ bitsPerSecond: Int) {
        queue.async {
            self.bitrate = bitsPerSecond
            if let session = self.session { Self.applyBitrate(session, bitsPerSecond, fps: self.fps) }
        }
    }

    func resize(width: Int, height: Int) {
        queue.async {
            guard width != self.width || height != self.height else { return }
            self.width = width
            self.height = height
            self.teardown()
            self.lastImage = nil
            self.forceKey = true
        }
    }

    func invalidate() {
        queue.sync {
            invalidated = true
            teardown()
            lastImage = nil
            onAccessUnit = nil
        }
    }

    private func teardown() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// A VideoToolbox property, or nil when the encoder does not answer. The value comes back retained (a Copy
    /// function), which the optional takes over.
    private static func copyProperty(_ session: VTSession, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer($0))
        }
        return status == noErr ? value : nil
    }

    private func makeSession() -> VTCompressionSession? {
        // Low-latency rate control first, then plain hardware-preferred, so older Macs and VMs still work.
        let attempts: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
             kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true],
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
            [:],
        ]
        for (index, specification) in attempts.enumerated() {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                    codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
                                                    imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                    refcon: nil, compressionSessionOut: &created)
            guard status == noErr, let created else { continue }
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
            // Key frames come on demand (a new viewer, a drop); the interval is a safety net.
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 10) as CFNumber)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
            Self.applyBitrate(created, bitrate, fps: fps)
            VTCompressionSessionPrepareToEncodeFrames(created)
            hardware = (Self.copyProperty(created, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? NSNumber)?.boolValue
            encoderID = Self.copyProperty(created, kVTCompressionPropertyKey_EncoderID) as? String
            let hardwareText = hardware.map { $0 ? "true" : "false" } ?? "unknown"
            BridgeyLog.screen.notice("display encoder \(self.width, privacy: .public)x\(self.height, privacy: .public) encoder=\(self.encoderID ?? "unknown", privacy: .public) hardware=\(hardwareText, privacy: .public) attempt=\(index, privacy: .public)")
            return created
        }
        BridgeyLog.screen.error("display encoder could not be created")
        return nil
    }

    private static func applyBitrate(_ session: VTCompressionSession, _ bitrate: Int, fps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // At most 1.5x the average over any second, so a burst cannot fill the pacing window by itself.
        let limits = [Double(bitrate) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    private func encodeNow(_ image: CVPixelBuffer, captureMicros: Int64) {
        guard !invalidated else { return }
        if session == nil {
            // The capture may run at a size the encoder has not been told about (a resize in flight): follow it.
            width = CVPixelBufferGetWidth(image)
            height = CVPixelBufferGetHeight(image)
            session = makeSession()
            forceKey = true
        }
        guard let session else { return }
        if CVPixelBufferGetWidth(image) != width || CVPixelBufferGetHeight(image) != height {
            // A frame of the old size after a resize: skip it; the next one rebuilds the session.
            teardown()
            return
        }
        lastImage = image
        lastEncodeMicros = monotonicMicros()
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        var properties: [CFString: Any] = [:]
        let key = forceKey
        if key { properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        forceKey = false
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: properties as CFDictionary, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            self.deliver(sample, captureMicros: captureMicros)
        }
        if status != noErr {
            BridgeyLog.screen.error("display encode failed status=\(status, privacy: .public)")
            if status == kVTInvalidSessionErr { teardown() }
            forceKey = true
        }
    }

    private func deliver(_ sample: CMSampleBuffer, captureMicros: Int64) {
        guard let unit = Self.annexB(sample) else { return }
        onAccessUnit?(MacScreenAccessUnit(data: unit.data, key: unit.key, parameterSets: unit.parameterSets,
                                          captureMillis: captureMicros / 1_000, captureMicros: captureMicros))
    }

    /// An encoded sample as Annex B, with the SPS and PPS first on a key frame.
    static func annexB(_ sample: CMSampleBuffer) -> (data: Data, key: Bool, parameterSets: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let avcc = Data(bytes: pointer, count: length)
        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true {
            key = false
        }
        var sets: [Data] = []
        if key, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var setPointer: UnsafePointer<UInt8>?
                var setSize = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &setPointer,
                                                                      parameterSetSizeOut: &setSize, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let setPointer {
                    sets.append(Data(bytes: setPointer, count: setSize))
                }
            }
        }
        guard let data = annexB(avcc: avcc, parameterSets: sets) else { return nil }
        return (data, key, !sets.isEmpty)
    }

    /// 4-byte length-prefixed NAL units (AVCC) to start-code-prefixed ones (Annex B), with `parameterSets` first.
    /// Nil when a length runs past the end.
    static func annexB(avcc: Data, parameterSets: [Data]) -> Data? {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: avcc.count + parameterSets.reduce(0) { $0 + $1.count + 4 })
        for set in parameterSets {
            out.append(contentsOf: startCode)
            out.append(set)
        }
        let bytes = [UInt8](avcc)
        var index = 0
        while index + 4 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 4
            guard length > 0, index + length <= bytes.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[index..<index + length])
            index += length
        }
        guard index == bytes.count, out.count > 0 else { return nil }
        return out
    }
}
