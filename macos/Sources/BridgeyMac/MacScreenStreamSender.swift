import Foundation
import os

/*
 * One stream from this Mac to one viewer (docs/protocol.md, "Mac screen to phone"): display.start, waiting for
 * display.started, frames paced on the viewer's acks, display.stats once a second, display.geometry and
 * display.control in the stream's order, and display.stop. Thread safe: frames come from the encoder's queue, acks
 * from the main actor, ticks from a timer. Every message this Mac sends on the stream takes the next sequence and
 * is handed to the session under one lock, so the viewer sees them in sequence order.
 */

/// How a stream reaches its viewer: encrypted on the session it started on. After a reconnect sends fail.
protocol MacScreenLink: AnyObject {
    /// A JSON stream message (it carries its own sequence). False when the session is gone.
    func sendJSON(kind: String, payload: [String: Any]) -> Bool
    /// One display.frame plaintext; `written` runs once it has gone to the socket (false on failure).
    func sendFrame(_ plaintext: Data, written: @escaping (Bool) -> Void) -> Bool
}

enum MacScreenStreamPhase: Equatable {
    case starting, streaming, ended
}

final class MacScreenStreamSender: @unchecked Sendable {
    let streamID: String
    private let link: MacScreenLink
    private let clock: () -> Int64
    weak var encoder: MacScreenEncoding?

    /// Called once when the stream ends, with the reason and whether this Mac told the viewer.
    var onEnded: (DisplayStopReason, Bool) -> Void = { _, _ in }
    var onStarted: () -> Void = {}
    var onStats: (MacScreenStats) -> Void = { _ in }

    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private var currentPhase = MacScreenStreamPhase.starting
    private var sequence = 0
    private var viewerSequence = ScreenSequence()
    private let pacer = MacScreenPacer()
    private let startedAt: Int64
    private let bitrate: MacScreenBitrate
    private let window: MacScreenStatsWindow
    private var frameNumber: UInt32 = 0
    private var lastKeyRequestAt = Int64.min / 2
    private var lastAckAt: Int64
    private var framesSent = 0
    private var framesDropped = 0
    private var latestStats: MacScreenStats?

    var sentCount: Int { stateLock.withLock { framesSent } }
    var droppedCount: Int { stateLock.withLock { framesDropped } }
    var lastStats: MacScreenStats? { stateLock.withLock { latestStats } }

    init(streamID: String = UUID().uuidString.lowercased(), link: MacScreenLink, clock: @escaping () -> Int64 = { monotonicMicros() / 1_000 }) {
        self.streamID = streamID
        self.link = link
        self.clock = clock
        let now = clock()
        startedAt = now
        lastAckAt = now
        bitrate = MacScreenBitrate(startMillis: now)
        window = MacScreenStatsWindow(startMillis: now)
    }

    var phase: MacScreenStreamPhase { stateLock.withLock { currentPhase } }
    var currentBitrate: Int { bitrate.bitrate }
    var framesInFlight: Int { pacer.framesInFlight }

    /// Sends display.start (its payload gets this stream's first sequence). False when the session is gone.
    @discardableResult
    func start(_ payload: (Int) -> [String: Any]) -> Bool {
        let sent = sendLock.withLock { () -> Bool in
            sequence += 1
            return link.sendJSON(kind: DisplayKinds.start, payload: payload(sequence))
        }
        if !sent { end(.failed, tell: false) }
        return sent
    }

    /// Any other JSON stream message (display.geometry, display.control), in sequence with the frames.
    @discardableResult
    func send(kind: String, _ payload: (Int) -> [String: Any]) -> Bool {
        guard phase != .ended else { return false }
        return sendLock.withLock {
            sequence += 1
            return link.sendJSON(kind: kind, payload: payload(sequence))
        }
    }

    /// A viewer message's sequence: only ever higher (per stream, the viewer's own count).
    func acceptViewerSequence(_ value: Int) -> Bool { stateLock.withLock { viewerSequence.accept(value) } }

    func receiveStarted() {
        let now = clock()
        let started = stateLock.withLock { () -> Bool in
            guard currentPhase == .starting else { return false }
            currentPhase = .streaming
            lastAckAt = now
            return true
        }
        guard started else { return }
        pacer.requireKey()
        requestKey(now, force: true)
        BridgeyLog.screen.notice("display started stream=\(String(self.streamID.prefix(8)), privacy: .public)")
        onStarted()
    }

    func receiveAck(frame: UInt32, decodeMs: Int, keyframe: Bool) {
        guard phase != .ended else { return }
        let now = clock()
        stateLock.withLock { lastAckAt = now }
        if let sample = pacer.acknowledge(frame: frame, decodeMs: Int64(decodeMs), nowMillis: now) {
            window.sample(sample)
            if let changed = bitrate.onRtt(sample.rttMillis, nowMillis: now) { encoder?.setBitrate(changed) }
        }
        if keyframe {
            pacer.requireKey()
            requestKey(now, force: false)
        }
    }

    /// One encoded access unit: sent in parts when the pacer admits it; otherwise dropped, with a key frame asked for
    /// and the bit rate lowered.
    func encoded(_ unit: MacScreenAccessUnit) {
        guard phase == .streaming, !unit.data.isEmpty else { return }
        let now = clock()
        if unit.data.count > ScreenLimits.maximumPartPayload * ScreenLimits.maximumParts {
            dropped(congestion: true, now: now)
            return
        }
        switch pacer.admit(bytes: unit.data.count, key: unit.key, bitrate: bitrate.bitrate) {
        case .send: break
        case .skip:
            dropped(congestion: false, now: now)
            return
        case .drop:
            dropped(congestion: true, now: now)
            return
        }
        let ok = sendLock.withLock { () -> Bool in
            guard phase == .streaming else { return false }
            frameNumber &+= 1
            if frameNumber == 0 { frameNumber = 1 }
            let frame = frameNumber
            let parts = Self.parts(streamID: streamID, firstSequence: sequence + 1, frame: frame, unit: unit)
            sequence += parts.count
            pacer.sending(frame: frame, bytes: unit.data.count, captureMillis: unit.captureMillis, nowMillis: now)
            var all = true
            for (index, part) in parts.enumerated() {
                let last = index == parts.count - 1
                let accepted = link.sendFrame(part) { [pacer, clock] written in
                    guard last else { return }
                    if written { pacer.written(frame: frame, nowMillis: clock()) } else { pacer.unsent(frame: frame) }
                }
                if !accepted {
                    all = false
                    break
                }
            }
            if !all { pacer.unsent(frame: frame) }
            return all
        }
        if ok {
            window.sent(unit.data.count)
            stateLock.withLock { framesSent += 1 }
        } else if phase == .streaming {
            end(.failed, tell: false)
        }
    }

    /// Once a second: timeouts, the bit rate's growth and display.stats.
    func tick() {
        let now = clock()
        switch phase {
        case .ended:
            return
        case .starting:
            if now - startedAt >= Int64(DisplayLimits.startedTimeout * 1000) {
                BridgeyLog.screen.notice("display no started stream=\(String(self.streamID.prefix(8)), privacy: .public)")
                end(.timeout, tell: true)
            }
        case .streaming:
            let lastAck = stateLock.withLock { lastAckAt }
            if let oldest = pacer.oldestWrittenAtMillis(), now - lastAck >= Int64(DisplayLimits.ackTimeout * 1000),
               now - oldest >= Int64(DisplayLimits.ackTimeout * 1000) {
                BridgeyLog.screen.notice("display no ack for 6 s stream=\(String(self.streamID.prefix(8)), privacy: .public)")
                end(.timeout, tell: true)
                return
            }
            if let changed = bitrate.tick(nowMillis: now) { encoder?.setBitrate(changed) }
            let stats = window.take(nowMillis: now, bitrate: bitrate.bitrate)
            stateLock.withLock { latestStats = stats }
            send(kind: DisplayKinds.stats) { sequence in
                DisplayPayloads.stats(streamID: self.streamID, sequence: sequence, latencyMs: stats.latencyMs, rttMs: stats.rttMs,
                                      bitrate: stats.bitrate, sentBitrate: stats.sentBitrate, fps: stats.fps, dropped: stats.dropped)
            }
            BridgeyLog.screen.notice("display stats latencyMs=\(stats.latencyMs, privacy: .public) rttMs=\(stats.rttMs, privacy: .public) bitrate=\(stats.bitrate, privacy: .public) sentBitrate=\(stats.sentBitrate, privacy: .public) fps=\(stats.fps, privacy: .public) dropped=\(stats.dropped, privacy: .public) inflight=\(self.pacer.framesInFlight, privacy: .public)")
            onStats(stats)
        }
    }

    /// The encoder restarted at a new size: the next frame must be a key frame with its SPS and PPS.
    func encoderRestarted() {
        pacer.requireKey()
        requestKey(clock(), force: true)
    }

    /// This Mac ends the stream: display.stop to the viewer (unless `tell` is false), then onEnded.
    func stop(_ reason: DisplayStopReason, tell: Bool = true) { end(reason, tell: tell) }

    private func end(_ reason: DisplayStopReason, tell: Bool) {
        let ending = stateLock.withLock { () -> Bool in
            guard currentPhase != .ended else { return false }
            currentPhase = .ended
            return true
        }
        guard ending else { return }
        if tell {
            sendLock.withLock {
                sequence += 1
                _ = link.sendJSON(kind: DisplayKinds.stop, payload: DisplayPayloads.stop(streamID: streamID, sequence: sequence, reason: reason))
            }
        }
        pacer.clear()
        BridgeyLog.screen.notice("display end stream=\(String(self.streamID.prefix(8)), privacy: .public) reason=\(reason.rawValue, privacy: .public) told=\(tell, privacy: .public)")
        onEnded(reason, tell)
    }

    private func dropped(congestion: Bool, now: Int64) {
        window.dropped()
        stateLock.withLock { framesDropped += 1 }
        if congestion {
            pacer.requireKey()
            if let changed = bitrate.onDrop(nowMillis: now) { encoder?.setBitrate(changed) }
        }
        requestKey(now, force: false)
    }

    private func requestKey(_ now: Int64, force: Bool) {
        let ask = stateLock.withLock { () -> Bool in
            if !force && now - lastKeyRequestAt < MacScreenRates.keyframeSpacingMillis { return false }
            lastKeyRequestAt = now
            return true
        }
        if ask { encoder?.requestKeyFrame() }
    }

    /// One access unit cut into parts of at most 32,768 bytes, each with its 40-byte header.
    static func parts(streamID: String, firstSequence: Int, frame: UInt32, unit: MacScreenAccessUnit) -> [Data] {
        let size = ScreenLimits.maximumPartPayload
        let count = (unit.data.count + size - 1) / size
        return (0..<count).map { index in
            let start = unit.data.startIndex + index * size
            let end = min(start + size, unit.data.endIndex)
            return ScreenFramePart(streamID: streamID, sequence: firstSequence + index, frame: frame, part: index, key: unit.key,
                                   parameterSets: unit.parameterSets, last: index == count - 1, captureMicros: unit.captureMicros,
                                   payload: unit.data.subdata(in: start..<end)).encoded()
        }
    }
}
