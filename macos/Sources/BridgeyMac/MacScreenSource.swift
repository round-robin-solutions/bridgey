import AppKit
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ScreenCaptureKit
import os

/*
 * Mac screen to phone: the displays this Mac can share and where frames come from. Both sit behind protocols so
 * tests and throwaway test instances use a synthetic display and a moving test pattern; the real path uses
 * ScreenCaptureKit, and every ScreenCaptureKit call is behind CGPreflightScreenCaptureAccess(), which never shows
 * a prompt. Nothing here asks macOS for Screen Recording (ScreenRecordingAccess.request does, and only Settings
 * calls it, when the person changes a phone's choice from Off).
 */

/// One display as the host maps it: global Quartz bounds (origin top left of the main display, y down, negative
/// left of or above it) and its native pixels.
struct MacDisplayInfo: Equatable, Identifiable {
    let id: UInt32
    let name: String
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    var scale: Double { bounds.width > 0 ? Double(pixelWidth) / Double(bounds.width) : 1 }
}

@MainActor
protocol MacDisplayProviding: AnyObject {
    func displays() -> [MacDisplayInfo]
    var mainDisplayID: UInt32 { get }
    /// Called on the main actor after any display is added, removed, resized or rearranged.
    var onChange: (() -> Void)? { get set }
}

/// Where frames come from. `frames` and `failed` may be called on any thread.
protocol MacScreenSource: AnyObject {
    func start(display: MacDisplayInfo, width: Int, height: Int, fps: Int,
               frames: @escaping (CVPixelBuffer, Int64) -> Void, failed: @escaping (String) -> Void)
    /// The display changed size: capture at the new size from now on.
    func update(display: MacDisplayInfo, width: Int, height: Int)
    func stop()
    /// Where input was last injected, as fractions of the captured display; only the synthetic source draws it.
    func markInput(x: Double, y: Double)
}

extension MacScreenSource {
    func markInput(x: Double, y: Double) {}
}

/// macOS Screen Recording. `isAllowed` never prompts; `request` shows macOS's own prompt and is called only from
/// Settings, when the person turns sharing on for a phone.
enum ScreenRecordingAccess {
    static func isAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

    static func request() { _ = CGRequestScreenCaptureAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

// MARK: The real displays

@MainActor
final class SystemDisplays: MacDisplayProviding {
    var onChange: (() -> Void)?
    private var registered = false

    init() {}

    var mainDisplayID: UInt32 { CGMainDisplayID() }

    func displays() -> [MacDisplayInfo] {
        registerIfNeeded()
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelWidth = mode?.pixelWidth ?? Int(bounds.width)
            let pixelHeight = mode?.pixelHeight ?? Int(bounds.height)
            return MacDisplayInfo(id: id, name: names[id] ?? L10n.text("display.name.fallback", fallback: "Display"), bounds: bounds,
                                  pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }

    private func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Called before and after a change; act once it is done.
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let owner = Unmanaged<SystemDisplays>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.onChange?() } }
        }, context)
    }
}

// MARK: The synthetic display (tests and throwaway test instances)

/// A display that does not exist: 1,512 by 982 points at scale 2 by default, so the stream is 1,920 by 1,246, the
/// size of a 14-inch MacBook Pro's display.
@MainActor
final class SyntheticDisplays: MacDisplayProviding {
    static let displayID: UInt32 = 1
    var onChange: (() -> Void)?
    private(set) var current: MacDisplayInfo

    init(width: Double = 1512, height: Double = 982, scale: Double = 2, origin: CGPoint = .zero) {
        current = Self.make(width: width, height: height, scale: scale, origin: origin)
    }

    var mainDisplayID: UInt32 { Self.displayID }

    func displays() -> [MacDisplayInfo] { [current] }

    /// The test pattern display changes size (points, at its scale): a new geometry generation for a running stream.
    func resize(width: Double, height: Double) {
        current = Self.make(width: width, height: height, scale: current.scale, origin: current.bounds.origin)
        onChange?()
    }

    private static func make(width: Double, height: Double, scale: Double, origin: CGPoint) -> MacDisplayInfo {
        MacDisplayInfo(id: displayID, name: L10n.text("display.name.test", fallback: "Test pattern"),
                       bounds: CGRect(origin: origin, size: CGSize(width: width, height: height)),
                       pixelWidth: Int(width * scale), pixelHeight: Int(height * scale))
    }
}

/// A moving test pattern at the stream's size, 30 frames a second: colour bars, a square that sweeps across, a frame
/// counter and a crosshair where input was last injected, so a screenshot of the viewer shows both motion and where
/// a tap landed. Never captures anything.
final class SyntheticScreenSource: MacScreenSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.display.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var size = (width: 0, height: 0)
    private var frame = 0
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()
    private var marker: (x: Double, y: Double)?
    private var label = ""

    init() {}

    func start(display: MacDisplayInfo, width: Int, height: Int, fps: Int,
               frames: @escaping (CVPixelBuffer, Int64) -> Void, failed: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.size = (width, height)
            self.label = display.name
            self.pool = nil
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(1, fps)), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, let image = self.render() else { return }
                frames(image, monotonicMicros())
            }
            self.timer = timer
            timer.resume()
        }
    }

    func update(display: MacDisplayInfo, width: Int, height: Int) {
        queue.async {
            self.size = (width, height)
            self.pool = nil
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func markInput(x: Double, y: Double) { lock.withLock { marker = (x, y) } }

    private func render() -> CVPixelBuffer? {
        let (width, height) = size
        guard width > 0, height > 0 else { return nil }
        if pool == nil {
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width,
                                               kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        frame += 1
        Self.draw(context, width: Double(width), height: Double(height), frame: frame, label: label,
                  marker: lock.withLock { marker })
        return buffer
    }

    /// The pattern, in a CGContext whose origin is bottom left (y is flipped for the top-left fractions).
    static func draw(_ context: CGContext, width: Double, height: Double, frame: Int, label: String, marker: (x: Double, y: Double)?) {
        context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bars: [(Double, Double, Double)] = [(0.94, 0.94, 0.94), (0.94, 0.85, 0.2), (0.2, 0.8, 0.85), (0.25, 0.75, 0.3),
                                                (0.8, 0.3, 0.75), (0.85, 0.25, 0.2), (0.2, 0.3, 0.85)]
        let barHeight = height * 0.18
        for (index, colour) in bars.enumerated() {
            let barWidth = width / Double(bars.count)
            context.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1))
            context.fill(CGRect(x: Double(index) * barWidth, y: height - barHeight, width: barWidth, height: barHeight))
        }
        // A square that sweeps left to right once every four seconds at 30 frames a second.
        let side = height * 0.16
        let travel = width - side
        let position = travel * Double(frame % 120) / 119
        context.setFillColor(CGColor(red: 0.55, green: 0.42, blue: 1, alpha: 1))
        context.fill(CGRect(x: position, y: height * 0.36, width: side, height: side))
        // A grid every tenth of the display, to read positions off a screenshot.
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        context.setLineWidth(max(1, width / 1920))
        for step in 1..<10 {
            let x = width * Double(step) / 10, y = height * Double(step) / 10
            context.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: height - barHeight)])
            context.strokeLineSegments(between: [CGPoint(x: 0, y: y), CGPoint(x: width, y: y)])
        }
        let text = "\(label)  \(Int(width))x\(Int(height))  frame \(frame)"
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, height * 0.045, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFDictionary
        if let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes) {
            let line = CTLineCreateWithAttributedString(string)
            context.textPosition = CGPoint(x: width * 0.03, y: height * 0.08)
            CTLineDraw(line, context)
        }
        if let marker {
            let x = marker.x * width, y = (1 - marker.y) * height
            let arm = height * 0.05
            context.setStrokeColor(CGColor(red: 1, green: 0.27, blue: 0.23, alpha: 1))
            context.setLineWidth(max(3, width / 480))
            context.strokeLineSegments(between: [CGPoint(x: x - arm, y: y), CGPoint(x: x + arm, y: y),
                                                 CGPoint(x: x, y: y - arm), CGPoint(x: x, y: y + arm)])
            context.strokeEllipse(in: CGRect(x: x - arm / 2, y: y - arm / 2, width: arm, height: arm))
        }
    }
}

// MARK: ScreenCaptureKit (the real display)

/// The selected display through ScreenCaptureKit at the stream's pixel size, 30 frames a second at most, 420v, the
/// pointer included. It needs Screen Recording; without it `start` fails at once and nothing is asked.
final class ScreenCaptureKitSource: NSObject, MacScreenSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.display.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var frames: ((CVPixelBuffer, Int64) -> Void)?
    private var failed: ((String) -> Void)?
    private var fps = MacScreenRates.fps

    func start(display: MacDisplayInfo, width: Int, height: Int, fps: Int,
               frames: @escaping (CVPixelBuffer, Int64) -> Void, failed: @escaping (String) -> Void) {
        lock.withLock {
            self.frames = frames
            self.failed = failed
            self.fps = fps
        }
        guard ScreenRecordingAccess.isAllowed() else {
            failed("screen_recording_not_allowed")
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let content, let target = content.displays.first(where: { $0.displayID == display.id }) else {
                self.fail("display_not_found \(error.map { String(describing: $0) } ?? "")")
                return
            }
            let filter = SCContentFilter(display: target, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: self.configuration(width: width, height: height), delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                self.fail("output \(error)")
                return
            }
            self.lock.withLock { self.stream = stream }
            stream.startCapture { [weak self] error in
                if let error { self?.fail("start \(error)") }
            }
        }
    }

    func update(display: MacDisplayInfo, width: Int, height: Int) {
        guard let stream = lock.withLock({ stream }) else { return }
        stream.updateConfiguration(configuration(width: width, height: height)) { [weak self] error in
            if let error { self?.fail("update \(error)") }
        }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            let current = self.stream
            self.stream = nil
            frames = nil
            failed = nil
            return current
        }
        stream?.stopCapture { _ in }
    }

    private func configuration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.scalesToFit = true
        return configuration
    }

    private func fail(_ why: String) {
        BridgeyLog.screen.error("display capture failed: \(why, privacy: .public)")
        let callback = lock.withLock { failed }
        callback?(why)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: statusValue) == .complete,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let callback = lock.withLock { frames }
        callback?(image, monotonicMicros())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("stopped \(error)")
    }
}
