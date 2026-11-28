import CoreMedia
import Foundation
import UIKit
import VideoToolbox

#if DEBUG
/// Screenshots of a screen (BRIDGEY_DEMO=screen-phone or screen-mac): a drawn phone home screen or Mac desktop,
/// encoded once with VideoToolbox and served as the stream's key frame, so the real decoder and display layer show it.
extension DemoClient {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var streams: [UInt64: (area: PhoneArea, served: Date?)] = [:]
    nonisolated(unsafe) private static var frames: [PhoneArea: Data] = [:]

    func demoScreen(_ area: PhoneArea, deviceID: String, command: [String: Any]) -> [String: Any] {
        let handle: UInt64 = area == .display ? 9_002 : 9_001
        switch command["op"] as? String {
        case "request":
            let (width, height) = area == .display ? (1440, 900) : (540, 1170)
            Self.lock.withLock { Self.streams[handle] = (area, nil) }
            let control: [String: Any] = ["stream": handle, "capable": true, "allowed": true, "phase": "off",
                                          "input": ["pointer": area == .display, "touch": area == .screen, "keys": true, "text": true, "navigation": area == .screen]]
            var started: [String: Any] = ["stream": handle, "width": width, "height": height, "fps": 30, "bitrate": 4_000_000,
                                          "screenshots": area == .screen, "control": control]
            if area == .display { started["displayName"] = "Built-in Retina Display" }
            emitLater(area, deviceID: deviceID, name: "started", id: handle, json: started)
            if area == .screen {
                // The phone's screenshots show control on, with its buttons.
                var active = control
                active["phase"] = "active"
                emitLater(area, deviceID: deviceID, name: "control", id: handle, json: active, after: 0.6)
            }
            return ["ok": true, "requestId": UUID().uuidString.lowercased()]
        default:
            return ["ok": true, "taken": true]
        }
    }

    private func emitLater(_ area: PhoneArea, deviceID: String, name: String, id: UInt64, json: [String: Any], after: TimeInterval = 0.2) {
        let text = (try? JSONSerialization.data(withJSONObject: json)).flatMap { String(data: $0, encoding: .utf8) }
        let event = CoreEvent(kind: area.eventKind, id: id, deviceID: deviceID, name: name, text: text)
        let onEvent = onEvent
        DispatchQueue.global().asyncAfter(deadline: .now() + after) { onEvent(event) }
    }

    /// The drawn screen once a second (a still picture needs no more).
    func demoScreenFrame(_ stream: UInt64, timeoutMs: UInt32, buffer: UnsafeMutableRawBufferPointer) -> ScreenFramePull {
        let due: PhoneArea? = Self.lock.withLock {
            guard let entry = Self.streams[stream] else { return nil }
            if let served = entry.served, Date().timeIntervalSince(served) < 1 { return nil }
            Self.streams[stream] = (entry.area, Date())
            return entry.area
        }
        guard let area = due else {
            if Self.lock.withLock({ Self.streams[stream] == nil }) { return .ended }
            Thread.sleep(forTimeInterval: Double(timeoutMs) / 1000)
            return .timeout
        }
        guard let frame = Self.frame(for: area) else { return .ended }
        guard frame.count <= buffer.count else { return .tooLarge(needed: frame.count) }
        frame.copyBytes(to: buffer)
        return .frame(length: frame.count, captureMicros: 0, key: true, parameterSets: true)
    }

    private static func frame(for area: PhoneArea) -> Data? {
        if let cached = lock.withLock({ frames[area] }) { return cached }
        let image = area == .display ? DemoScreens.macDesktop() : DemoScreens.phoneHome()
        guard let data = DemoScreens.encode(image) else { return nil }
        lock.withLock { frames[area] = data }
        return data
    }

    /// Screenshots of a screen: the home first, then the phone's or the Mac's screen open.
    @MainActor
    static func seedScreen(_ model: AppModel, screen: String) {
        let id: String
        switch screen {
        case "screen-phone": id = pixel
        case "screen-mac": id = mac
        default: return
        }
        guard let device = model.devices.first(where: { $0.id == id }) else { return }
        model.screen.open(device)
    }
}

/// The pictures the demo streams: made-up content, nothing personal.
enum DemoScreens {
    static func phoneHome() -> UIImage {
        let size = CGSize(width: 540, height: 1170)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colours = [UIColor(red: 0.16, green: 0.12, blue: 0.36, alpha: 1).cgColor, UIColor(red: 0.05, green: 0.36, blue: 0.48, alpha: 1).cgColor,
                           UIColor(red: 0.18, green: 0.62, blue: 0.52, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.6, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            func text(_ s: String, _ font: UIFont, _ y: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                let w = (s as NSString).size(withAttributes: attributes).width
                (s as NSString).draw(at: CGPoint(x: (size.width - w) / 2, y: y), withAttributes: attributes)
            }
            text("10:24", .systemFont(ofSize: 22, weight: .semibold), 14)
            text("10:24", .systemFont(ofSize: 96, weight: .light), 150)
            text("Friday 28 November", .systemFont(ofSize: 24, weight: .medium), 270)
            let tints: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemYellow, .systemRed,
                                    .systemIndigo, .systemMint, .systemCyan, .systemBrown]
            let icon: CGFloat = 92, gap: CGFloat = 38
            let left = (size.width - 4 * icon - 3 * gap) / 2
            for row in 0..<3 {
                for col in 0..<4 {
                    let rect = CGRect(x: left + CGFloat(col) * (icon + gap), y: 420 + CGFloat(row) * (icon + 52), width: icon, height: icon)
                    tints[(row * 4 + col) % tints.count].withAlphaComponent(0.9).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 26).fill()
                    UIColor.white.withAlphaComponent(0.85).setFill()
                    UIBezierPath(roundedRect: CGRect(x: rect.minX + 12, y: rect.maxY + 10, width: icon - 24, height: 10), cornerRadius: 5).fill()
                }
            }
            UIColor.white.withAlphaComponent(0.22).setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: size.height - 170, width: size.width - 48, height: 130), cornerRadius: 40).fill()
            for col in 0..<4 {
                tints[(col + 5) % tints.count].setFill()
                UIBezierPath(roundedRect: CGRect(x: left + CGFloat(col) * (icon + gap), y: size.height - 151, width: icon, height: icon), cornerRadius: 26).fill()
            }
        }
    }

    static func macDesktop() -> UIImage {
        let size = CGSize(width: 1440, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colours = [UIColor(red: 0.10, green: 0.16, blue: 0.40, alpha: 1).cgColor, UIColor(red: 0.42, green: 0.30, blue: 0.70, alpha: 1).cgColor,
                           UIColor(red: 0.90, green: 0.55, blue: 0.45, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.55, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.75).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 30))
            let bar: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.black]
            ("Notes      File      Edit      Format      View      Window" as NSString).draw(at: CGPoint(x: 24, y: 6), withAttributes: bar)
            ("Fri 28 Nov  10:24" as NSString).draw(at: CGPoint(x: size.width - 160, y: 6), withAttributes: bar)
            let window = CGRect(x: 250, y: 120, width: 900, height: 560)
            cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 40, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: window, cornerRadius: 14).fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(white: 0.95, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 52), byRoundingCorners: [.topLeft, .topRight],
                         cornerRadii: CGSize(width: 14, height: 14)).fill()
            for (i, colour) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                colour.setFill()
                UIBezierPath(ovalIn: CGRect(x: window.minX + 20 + CGFloat(i) * 22, y: window.minY + 19, width: 14, height: 14)).fill()
            }
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: UIColor.black]
            ("Trip to Goa" as NSString).draw(at: CGPoint(x: window.minX + 48, y: window.minY + 84), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.darkGray]
            for (i, line) in ["Flights on Friday, 07:40", "Book the boat for Saturday morning", "Pack the charger and the camera",
                              "Dinner at the beach on Sunday"].enumerated() {
                ("•  " + line as NSString).draw(at: CGPoint(x: window.minX + 48, y: window.minY + 150 + CGFloat(i) * 44), withAttributes: body)
            }
            UIColor.white.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: CGRect(x: 470, y: size.height - 88, width: 500, height: 72), cornerRadius: 22).fill()
            let tints: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemYellow, .systemIndigo]
            for (i, tint) in tints.enumerated() {
                tint.setFill()
                UIBezierPath(roundedRect: CGRect(x: 486 + CGFloat(i) * 60, y: size.height - 78, width: 52, height: 52), cornerRadius: 14).fill()
            }
        }
    }

    /// One H.264 key frame of the picture in Annex B, with its parameter sets, as a phone or Mac would send it.
    static func encode(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let (width, height) = (cgImage.width, cgImage.height)
        var pixels: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixels) == kCVReturnSuccess,
              let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                         refcon: nil, compressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        var result: Data?
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: 0, timescale: 30),
                                                     duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var sets: [Data] = []
            for i in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
            var length = 0
            var data: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data) == noErr,
                  let data, sets.count == 2 else { return }
            result = H264.annexB(avcc: Data(bytes: data, count: length), sps: sets[0], pps: sets[1])
        }
        guard status == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return result
    }
}
#endif
