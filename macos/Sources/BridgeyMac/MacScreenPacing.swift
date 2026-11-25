import Foundation

/*
 * The source's side of pacing a screen stream (docs/protocol.md, "Mac screen to phone", "Frames and pacing"): the
 * same rules the phone applies to its own stream (android .../screen/ScreenPacing.kt), ported for the Mac as the
 * source. Which frames go, which are dropped until the next key frame, how the bit rate moves, and the
 * once-a-second stats. Clock values are milliseconds of one monotonic clock; nothing here touches the system.
 */

enum MacScreenRates {
    static let fps = 30
    static let startBitrate = 4_000_000
    static let minBitrate = 300_000
    static let maxBitrate = 8_000_000
    static let maxFramesInFlight = 6
    static let minWindowBytes = 64 * 1024
    static let windowMillis = 250
    /// The round trip may grow this much over its minimum before the bit rate comes down.
    static let rttGrowthMillis: Int64 = 80
    static let decreaseSpacingMillis: Int64 = 500
    static let increaseAfterMillis: Int64 = 2_000
    /// Key frames are asked of the encoder at most this often.
    static let keyframeSpacingMillis: Int64 = 500
}

enum MacScreenFrameVerdict: Equatable {
    case send
    /// Waiting for a key frame: this one would not decode. Not a sign of congestion.
    case skip
    /// The window is full: congestion.
    case drop
}

/// Frames sent and not yet acknowledged: at most 6 frames and max(64 KiB, 250 ms at the bit rate). An empty pipe
/// always takes the next frame, so a key frame bigger than the window still goes. After a drop every frame up to
/// the next key frame is dropped too, and a key frame is asked for. Thread safe.
final class MacScreenPacer: @unchecked Sendable {
    struct AckSample: Equatable {
        let rttMillis: Int64
        let latencyMillis: Int64
    }

    private struct InFlight {
        let frame: UInt32
        let bytes: Int
        let captureMillis: Int64
        var writtenAtMillis: Int64
    }

    private let lock = NSLock()
    private var inFlight: [InFlight] = []
    private var inFlightBytes = 0
    private var waiting = true

    /// True after a drop, or before the first frame: only a key frame may go next.
    var waitingForKey: Bool { lock.withLock { waiting } }
    var framesInFlight: Int { lock.withLock { inFlight.count } }
    var bytesInFlight: Int { lock.withLock { inFlightBytes } }

    func windowBytes(_ bitrate: Int) -> Int { max(MacScreenRates.minWindowBytes, bitrate * MacScreenRates.windowMillis / 1000 / 8) }

    func admit(bytes: Int, key: Bool, bitrate: Int) -> MacScreenFrameVerdict {
        lock.withLock {
            if waiting && !key { return .skip }
            let fits = inFlight.isEmpty || (inFlight.count < MacScreenRates.maxFramesInFlight && inFlightBytes + bytes <= windowBytes(bitrate))
            if !fits {
                waiting = true
                return .drop
            }
            waiting = false
            return .send
        }
    }

    /// The encoder or the viewer needs a fresh key frame: nothing else goes until one does.
    func requireKey() { lock.withLock { waiting = true } }

    func sending(frame: UInt32, bytes: Int, captureMillis: Int64, nowMillis: Int64) {
        lock.withLock {
            inFlight.append(InFlight(frame: frame, bytes: bytes, captureMillis: captureMillis, writtenAtMillis: nowMillis))
            inFlightBytes += bytes
        }
    }

    /// Its last part is written.
    func written(frame: UInt32, nowMillis: Int64) {
        lock.withLock {
            if let index = inFlight.lastIndex(where: { $0.frame == frame }) { inFlight[index].writtenAtMillis = nowMillis }
        }
    }

    /// A frame could not be written at all: it is not in flight.
    func unsent(frame: UInt32) {
        lock.withLock {
            inFlight.removeAll { entry in
                guard entry.frame == frame else { return false }
                inFlightBytes -= entry.bytes
                return true
            }
        }
    }

    /// The viewer has `frame` and every earlier one, decoded in `decodeMs`. The round trip is from the frame's last
    /// byte written to the ack, minus decoding; the latency from capture to the ack, minus half the round trip.
    func acknowledge(frame: UInt32, decodeMs: Int64, nowMillis: Int64) -> AckSample? {
        lock.withLock {
            var newest: InFlight?
            while let first = inFlight.first, first.frame <= frame {
                newest = inFlight.removeFirst()
                inFlightBytes -= first.bytes
            }
            guard let acked = newest, acked.frame == frame else { return nil }
            let rtt = max(0, nowMillis - acked.writtenAtMillis - decodeMs)
            let latency = max(0, nowMillis - acked.captureMillis - rtt / 2)
            return AckSample(rttMillis: rtt, latencyMillis: latency)
        }
    }

    func clear() {
        lock.withLock {
            inFlight.removeAll()
            inFlightBytes = 0
            waiting = true
        }
    }

    /// When the oldest frame still waiting for its ack was written, or nil with nothing in flight.
    func oldestWrittenAtMillis() -> Int64? { lock.withLock { inFlight.first?.writtenAtMillis } }
}

/// The bit rate: down by a quarter on a drop or when the round trip grows 80 ms over its minimum (at most every
/// 500 ms), up by 15 percent after 2 seconds without either, between 300 kb/s and 8 Mb/s. Thread safe.
final class MacScreenBitrate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int
    private var minimumRtt: Int64?
    private var lastDecreaseAt = Int64.min / 2
    private var calmSince: Int64

    init(startMillis: Int64, initial: Int = MacScreenRates.startBitrate) {
        current = min(max(initial, MacScreenRates.minBitrate), MacScreenRates.maxBitrate)
        calmSince = startMillis
    }

    var bitrate: Int { lock.withLock { current } }
    var minRttMillis: Int64? { lock.withLock { minimumRtt } }

    /// The new bit rate when it changed.
    func onRtt(_ rttMillis: Int64, nowMillis: Int64) -> Int? {
        lock.withLock {
            let lowest = min(minimumRtt ?? rttMillis, rttMillis)
            minimumRtt = lowest
            return rttMillis > lowest + MacScreenRates.rttGrowthMillis ? congested(nowMillis) : grow(nowMillis)
        }
    }

    func onDrop(nowMillis: Int64) -> Int? { lock.withLock { congested(nowMillis) } }

    /// On the stats tick, so the rate grows even when acks are few.
    func tick(nowMillis: Int64) -> Int? { lock.withLock { grow(nowMillis) } }

    private func congested(_ now: Int64) -> Int? {
        calmSince = now
        guard now - lastDecreaseAt >= MacScreenRates.decreaseSpacingMillis else { return nil }
        lastDecreaseAt = now
        return set(current * 3 / 4)
    }

    private func grow(_ now: Int64) -> Int? {
        guard now - calmSince >= MacScreenRates.increaseAfterMillis else { return nil }
        calmSince = now
        return set(current * 115 / 100)
    }

    private func set(_ value: Int) -> Int? {
        let next = min(max(value, MacScreenRates.minBitrate), MacScreenRates.maxBitrate)
        guard next != current else { return nil }
        current = next
        return next
    }
}

/// One second of the source's view of the stream, for display.stats and the log.
struct MacScreenStats: Equatable {
    var latencyMs: Int
    var rttMs: Int
    var bitrate: Int
    var sentBitrate: Int
    var fps: Int
    var dropped: Int
}

/// Counts for the current second; `take` gives the stats and starts the next second. Thread safe.
final class MacScreenStatsWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Int64
    private var frames = 0
    private var drops = 0
    private var bytes = 0
    private var latencySum: Int64 = 0
    private var latencyCount = 0
    private var lastLatency: Int64 = 0
    private var lastRtt: Int64 = 0

    init(startMillis: Int64) { startedAt = startMillis }

    func sent(_ frameBytes: Int) { lock.withLock { frames += 1; bytes += frameBytes } }
    func dropped() { lock.withLock { drops += 1 } }
    func sample(_ sample: MacScreenPacer.AckSample) {
        lock.withLock {
            latencySum += sample.latencyMillis
            latencyCount += 1
            lastLatency = sample.latencyMillis
            lastRtt = sample.rttMillis
        }
    }

    func take(nowMillis: Int64, bitrate: Int) -> MacScreenStats {
        lock.withLock {
            let elapsed = max(1, nowMillis - startedAt)
            let stats = MacScreenStats(
                latencyMs: Int(latencyCount > 0 ? latencySum / Int64(latencyCount) : lastLatency),
                rttMs: Int(lastRtt),
                bitrate: bitrate,
                sentBitrate: Int(Int64(bytes) * 8 * 1000 / elapsed),
                fps: Int((Int64(frames) * 1000 + elapsed / 2) / elapsed),
                dropped: drops)
            startedAt = nowMillis
            frames = 0
            drops = 0
            bytes = 0
            latencySum = 0
            latencyCount = 0
            return stats
        }
    }
}
