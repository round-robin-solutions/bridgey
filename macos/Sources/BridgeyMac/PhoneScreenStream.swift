import CoreVideo
import Foundation
import os

/*
 * One phone's screen stream, off the main thread. Frames, stats and the phone's stop are decrypted,
 * sequence-checked, reassembled and decoded on this stream's serial queue, in the order the session
 * received them; decoded frames go straight to the display layer. Acks, stats, the size and stops
 * go to the main actor, which owns the window and sends this Mac's messages.
 */
final class ScreenStreamReceiver: @unchecked Sendable {
    let streamID: String
    let deviceID: String

    /// Called on the main queue.
    var onAck: (_ frame: UInt32, _ decodeMs: Int, _ keyframe: Bool) -> Void = { _, _, _ in }
    var onStats: (ScreenStats) -> Void = { _ in }
    var onStop: (ScreenStopReason) -> Void = { _ in }
    var onSize: (_ width: Int, _ height: Int) -> Void = { _, _ in }

    private let key: Data
    private let queue: DispatchQueue
    private let decrypt: (String, String, Data) -> Data?
    private var phoneSequence: ScreenSequence
    private var assembler = ScreenFrameAssembler()
    private let decoder = ScreenVideoDecoder()
    private var sink: ScreenDisplaySink?
    private var waitingForKey = true
    private var lastKeyRequest: UInt64 = 0
    private var finished = false
    private var size: (Int, Int)?

    private let lock = NSLock()
    private var activity = Date()

    // Counters for the once-a-second log line.
    private var windowStart = DispatchTime.now().uptimeNanoseconds
    private var framesDecoded = 0
    private var bytesReceived = 0
    private var decodeTotalMs = 0.0
    private var decodeMaxMs = 0.0
    private var framesLost = 0
    private var partsDropped = 0

    /// `startSequence`: the phone's `screen.start` sequence; everything after must be higher.
    init(streamID: String, deviceID: String, key: Data, startSequence: Int,
         decrypt: @escaping (String, String, Data) -> Data? = { nonce, ciphertext, key in try? BridgeyMac.decrypt(nonce: nonce, ciphertext: ciphertext, key: key) }) {
        self.streamID = streamID
        self.deviceID = deviceID
        self.key = key
        self.decrypt = decrypt
        phoneSequence = ScreenSequence(after: startSequence)
        queue = DispatchQueue(label: "in.roundrobin.bridgey.screen.\(streamID.prefix(8))", qos: .userInteractive)
    }

    /// The last frame part or stats accepted.
    var lastActivity: Date { lock.withLock { activity } }

    func attach(_ sink: ScreenDisplaySink) { queue.async { self.sink = sink } }

    /// Stops processing; later messages are dropped.
    func finish() {
        queue.async {
            self.finished = true
            self.decoder.invalidate()
            self.sink = nil
        }
    }

    /// A `screen.frame`, `screen.stats` or `screen.stop` for this stream, still encrypted. Main queue.
    func receive(kind: String, nonce: String, ciphertext: String) {
        queue.async { self.process(kind: kind, nonce: nonce, ciphertext: ciphertext) }
    }

    /// The same, with the plaintext already decrypted (tests and the round trip).
    func receivePlaintext(kind: String, _ data: Data) {
        queue.async { self.handle(kind: kind, data) }
    }

    /// Runs `body` after everything queued so far (tests).
    func sync(_ body: @escaping () -> Void = {}) { queue.sync(execute: body) }

    private func process(kind: String, nonce: String, ciphertext: String) {
        guard !finished, let data = decrypt(nonce, ciphertext, key) else {
            if !finished { partsDropped += 1 }
            return
        }
        handle(kind: kind, data)
    }

    private func handle(kind: String, _ data: Data) {
        guard !finished else { return }
        switch kind {
        case "screen.frame":
            guard let part = ScreenFramePart.decode(data), part.streamID == streamID, phoneSequence.accept(part.sequence) else {
                partsDropped += 1
                return
            }
            touch()
            bytesReceived += part.payload.count
            receive(part)
        case "screen.stats":
            guard let stats = ScreenStats.decode(data), stats.streamID == streamID, phoneSequence.accept(stats.sequence) else { return }
            touch()
            BridgeyLog.screen.notice("screen stats stream=\(String(self.streamID.prefix(8)), privacy: .public) latencyMs=\(stats.latencyMs, privacy: .public) rttMs=\(stats.rttMs, privacy: .public) bitrate=\(stats.bitrate, privacy: .public) sentBitrate=\(stats.sentBitrate, privacy: .public) fps=\(stats.fps, privacy: .public) dropped=\(stats.dropped, privacy: .public)")
            let callback = onStats
            DispatchQueue.main.async { callback(stats) }
        case "screen.stop":
            guard let stop = ScreenStop.decode(data), stop.streamID == streamID, phoneSequence.accept(stop.sequence) else { return }
            finished = true
            decoder.invalidate()
            let callback = onStop
            DispatchQueue.main.async { callback(stop.reason) }
        default:
            break
        }
    }

    private func touch() { lock.withLock { activity = Date() } }

    private func receive(_ part: ScreenFramePart) {
        switch assembler.add(part) {
        case .pending, .ignored:
            break
        case let .lost(frame):
            framesLost += 1
            waitingForKey = true
            acknowledge(frame, decodeMs: 0, wantKey: true)
        case let .complete(frame):
            if waitingForKey && !frame.key {
                acknowledge(frame.frame, decodeMs: 0, wantKey: true)
                return
            }
            switch decoder.decode(frame) {
            case let .decoded(image, decodeMs):
                waitingForKey = false
                framesDecoded += 1
                decodeTotalMs += decodeMs
                decodeMaxMs = max(decodeMaxMs, decodeMs)
                sink?.show(image)
                let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
                if size.map({ $0 != (width, height) }) ?? true {
                    size = (width, height)
                    let callback = onSize
                    DispatchQueue.main.async { callback(width, height) }
                }
                acknowledge(frame.frame, decodeMs: Int(decodeMs.rounded()), wantKey: false)
            case .needsKeyFrame:
                framesLost += 1
                waitingForKey = true
                acknowledge(frame.frame, decodeMs: 0, wantKey: true)
            }
        }
        logEverySecond()
    }

    /// Acks every complete frame; `keyframe` at most once a second.
    private func acknowledge(_ frame: UInt32, decodeMs: Int, wantKey: Bool) {
        var keyframe = false
        if wantKey {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastKeyRequest >= 1_000_000_000 || lastKeyRequest == 0 {
                lastKeyRequest = now
                keyframe = true
            }
        }
        let callback = onAck
        DispatchQueue.main.async { callback(frame, decodeMs, keyframe) }
    }

    private func logEverySecond() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - windowStart) / 1_000_000_000
        guard elapsed >= 1 else { return }
        let fps = Double(framesDecoded) / elapsed
        let kbps = Int(Double(bytesReceived) * 8 / elapsed / 1000)
        let average = framesDecoded > 0 ? decodeTotalMs / Double(framesDecoded) : 0
        let dimensions = size.map { "\($0.0)x\($0.1)" } ?? "none"
        BridgeyLog.screen.notice("screen receive stream=\(String(self.streamID.prefix(8)), privacy: .public) fps=\(String(format: "%.1f", fps), privacy: .public) kbps=\(kbps, privacy: .public) decodeMsAvg=\(String(format: "%.2f", average), privacy: .public) decodeMsMax=\(String(format: "%.2f", self.decodeMaxMs), privacy: .public) lost=\(self.framesLost, privacy: .public) dropped=\(self.partsDropped, privacy: .public) size=\(dimensions, privacy: .public)")
        windowStart = now
        framesDecoded = 0
        bytesReceived = 0
        decodeTotalMs = 0
        decodeMaxMs = 0
        framesLost = 0
        partsDropped = 0
    }
}
