import CoreMedia
import Foundation

/// One stream's frames: a thread that pulls each whole access unit with `screenFrame` (never through the event queue),
/// decodes it and hands the picture to the sink. It tells the session the decode time about once a second and asks
/// for a key frame after a decoder error. It stops on `stop()` or when the stream ends.
final class FramePump: @unchecked Sendable {
    private let client: CoreClient
    private let area: PhoneArea
    private let deviceID: String
    private let stream: UInt64
    private let decoder: ScreenDecoder
    private let lock = NSLock()
    private var running = true
    private var thread: Thread?
    /// Called on the main thread after the first picture, and when the stream ends here.
    private let onFirstFrame: @MainActor () -> Void
    private let onEnded: @MainActor () -> Void

    init(client: CoreClient, area: PhoneArea, deviceID: String, stream: UInt64, sink: ScreenFrameSink?,
         onFirstFrame: @escaping @MainActor () -> Void = {}, onEnded: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.area = area
        self.deviceID = deviceID
        self.stream = stream
        decoder = ScreenDecoder(sink: sink)
        self.onFirstFrame = onFirstFrame
        self.onEnded = onEnded
    }

    var isRunning: Bool { lock.withLock { running } }

    var decodedFrames: Int { lock.withLock { decoderCount } }
    private var decoderCount = 0

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Bridgey screen \(stream)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.withLock { running = false }
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var lastReport = CFAbsoluteTimeGetCurrent()
        var told = false
        while isRunning {
            let pulled = CFAbsoluteTimeGetCurrent()
            let pull = buffer.withUnsafeMutableBytes { client.screenFrame(stream, timeoutMs: 200, buffer: $0) }
            switch pull {
            case .timeout:
                // A source that answers at once (a test's fake) must not spin.
                if CFAbsoluteTimeGetCurrent() - pulled < 0.01 { Thread.sleep(forTimeInterval: 0.02) }
                continue
            case let .tooLarge(needed):
                // The frame stays next; a bigger buffer takes it on the next pull.
                buffer = [UInt8](repeating: 0, count: max(needed, buffer.count * 2))
                continue
            case .ended:
                lock.withLock { running = false }
                let ended = onEnded
                DispatchQueue.main.async { MainActor.assumeIsolated { ended() } }
                return
            case let .frame(length, _, key, _):
                let outcome = buffer.withUnsafeBytes { decoder.decode(UnsafeRawBufferPointer(rebasing: $0[0..<length]), key: key) }
                switch outcome {
                case .shown:
                    lock.withLock { decoderCount += 1 }
                    if !told {
                        told = true
                        let first = onFirstFrame
                        DispatchQueue.main.async { MainActor.assumeIsolated { first() } }
                    }
                case .skipped:
                    break
                case .failed:
                    decoder.waitForKeyFrame()
                    _ = client.phone(area, deviceID: deviceID, command: ["op": "keyframe"])
                }
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastReport >= 1 {
                    lastReport = now
                    _ = client.phone(area, deviceID: deviceID, command: ["op": "decoded", "ms": Int(decoder.lastMilliseconds.rounded())])
                }
            }
        }
        decoder.invalidate()
    }
}
