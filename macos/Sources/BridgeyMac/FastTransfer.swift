import CryptoKit
import Foundation

// Fast transfers (draft files_fast_draft1; docs/transfer-speed.md, docs/protocol.md "Fast transfers"). Between two
// peers that both advertise the key, file chunks travel as binary frames instead of base64 inside JSON, chunks are
// 256 KiB instead of 24 KiB, receivers acknowledge every chunk, and senders keep a window of unacknowledged bytes
// that follows the queueing delay of the link. Peers without the key keep the 24 KiB JSON chunks and 64-chunk
// window. Android has the same code in FastTransfer.kt.

/// The feature key. Both apps advertise it whenever they support it; it is a capability, not a setting.
let filesFastFeatureKey = "files_fast_draft1"

enum FastFrame {
    /// The first byte of a binary frame. It can never start a JSON frame (`{` or whitespace) and is not a valid
    /// first byte of UTF-8 text, so a peer without the key would close the session rather than misread it.
    static let marker: UInt8 = 0xB1
    /// Marker, kind, and the body length as a 32-bit big-endian integer.
    static let headerBytes = 6
    /// files.chunk: one chunk of a file (single files, folders, downloads, clipboard files).
    static let chunkKind: UInt8 = 1
    /// speed.data: test bytes for the speed test, acknowledged and thrown away.
    static let speedKind: UInt8 = 2
    static let maximumPlaintext = 1_048_576
    static let maximumIDBytes = 64
    /// The largest body: ID length, ID, sequence, nonce, the largest ciphertext and its tag.
    static let maximumBody = 1 + maximumIDBytes + 8 + 12 + maximumPlaintext + 16
    /// What senders use. Receivers take up to `maximumPlaintext`.
    static let chunkSize = 256 * 1024
    static let maximumSequence: Int64 = 9_007_199_254_740_991
    /// The first field of the associated data. Fast frames exist only on protocol 2 sessions.
    static let associatedDataLabel = "bridgey-fast-frame-v2"
}

/// A decoded binary frame: what a files.chunk JSON message carried, without the envelope.
struct FastFramePayload: Equatable {
    let kind: UInt8
    let id: String
    let sequence: Int64
    let plaintext: Data
}

enum FastFrameError: Error, Equatable {
    case malformed
    case undecryptable
}

/// What the AES-GCM tag covers besides the ciphertext, length-prefixed like protocol 2 envelope tags
/// (SessionSecurity.lengthPrefixed): the label, the sending device's ID, the kind, the transfer (or test) ID and the
/// sequence. So a frame cannot be moved to another transfer, position or kind, and cannot be reflected back to the
/// device that sent it: its own ID is not the sender the receiver checks.
func fastFrameAssociatedData(sender: String, kind: UInt8, id: String, sequence: Int64) -> Data {
    SessionSecurity.lengthPrefixed([FastFrame.associatedDataLabel, sender, String(kind), id, String(sequence)])
}

private func validFastID(_ id: Data) -> Bool {
    (1...FastFrame.maximumIDBytes).contains(id.count) && id.allSatisfy { (0x21...0x7E).contains($0) }
}

/// One whole frame, header included, from `sender` (this device's ID). `nonce` is random unless a test vector fixes it.
func sealFastFrame(kind: UInt8, id: String, sequence: Int64, plaintext: Data, key: Data, sender: String, nonce: Data? = nil) throws -> Data {
    let idBytes = Data(id.utf8)
    guard validFastID(idBytes), (0...FastFrame.maximumSequence).contains(sequence),
          (1...FastFrame.maximumPlaintext).contains(plaintext.count) else { throw FastFrameError.malformed }
    let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
    let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce,
                                  authenticating: fastFrameAssociatedData(sender: sender, kind: kind, id: id, sequence: sequence))
    let bodyLength = 1 + idBytes.count + 8 + 12 + sealed.ciphertext.count + 16
    var frame = Data(capacity: FastFrame.headerBytes + bodyLength)
    frame.append(FastFrame.marker)
    frame.append(kind)
    var length = UInt32(bodyLength).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(UInt8(idBytes.count))
    frame.append(idBytes)
    var big = UInt64(sequence).bigEndian
    withUnsafeBytes(of: &big) { frame.append(contentsOf: $0) }
    frame.append(contentsOf: gcmNonce)
    frame.append(sealed.ciphertext)
    frame.append(sealed.tag)
    return frame
}

/// Reads and decrypts a frame body (what follows the 6-byte header) from `sender` (the other device's ID). A malformed
/// field or a failed tag is dropped and counted like a frame with a bad envelope tag (16 close the session).
func openFastFrameBody(kind: UInt8, body: Data, key: Data, sender: String) throws -> FastFramePayload {
    let bytes = [UInt8](body)
    guard bytes.count <= FastFrame.maximumBody, let idLength = bytes.first.map(Int.init),
          (1...FastFrame.maximumIDBytes).contains(idLength), bytes.count >= 1 + idLength + 8 + 12 + 16 + 1 else {
        throw FastFrameError.malformed
    }
    let idBytes = Data(bytes[1..<(1 + idLength)])
    guard validFastID(idBytes) else { throw FastFrameError.malformed }
    var sequence: UInt64 = 0
    for byte in bytes[(1 + idLength)..<(1 + idLength + 8)] { sequence = sequence << 8 | UInt64(byte) }
    guard sequence <= UInt64(FastFrame.maximumSequence) else { throw FastFrameError.malformed }
    let nonceStart = 1 + idLength + 8
    let cipherStart = nonceStart + 12
    let tagStart = bytes.count - 16
    guard tagStart - cipherStart <= FastFrame.maximumPlaintext else { throw FastFrameError.malformed }
    do {
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: bytes[nonceStart..<cipherStart]),
                                        ciphertext: bytes[cipherStart..<tagStart], tag: bytes[tagStart...])
        let id = String(decoding: idBytes, as: UTF8.self)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key),
                                         authenticating: fastFrameAssociatedData(sender: sender, kind: kind, id: id, sequence: Int64(sequence)))
        return FastFramePayload(kind: kind, id: id, sequence: Int64(sequence), plaintext: plaintext)
    } catch {
        throw FastFrameError.undecryptable
    }
}

/// Binary frames do not enter the messageId window. Instead each kind and ID must carry a higher sequence than the last
/// frame taken with them (file chunks follow on 0, 1, 2, ...; speed test bytes too), so a frame recorded and sent again
/// is dropped before it reaches a transfer. Remembers the 256 most recently used IDs, so a long transfer that keeps
/// sending is never forgotten while short ones come and go. A forgotten ID's replayed frame still reaches no data:
/// every receiver takes only the exact next sequence of a transfer it owns.
struct FastReplayGuard {
    private var highest: [String: Int64] = [:]
    /// Least recently used first.
    private var order: [String] = []
    let capacity = 256

    mutating func accept(_ payload: FastFramePayload) -> Bool {
        let key = "\(payload.kind):\(payload.id)"
        if let last = highest[key] {
            guard payload.sequence > last else { return false }
            if order.last != key, let index = order.lastIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
        } else {
            order.append(key)
            if order.count > capacity { highest.removeValue(forKey: order.removeFirst()) }
        }
        highest[key] = payload.sequence
        return true
    }
}

// MARK: - Window

/// Sender-side flow control for one transfer (or one folder, or one speed test).
///
/// Legacy peers: at most 64 chunks unacknowledged, as before. Fast peers: a window of unacknowledged bytes that
/// grows while acknowledgements come back quickly and shrinks when their round trip climbs more than
/// `targetQueueDelay` above the lowest one seen, so a transfer fills the link without parking seconds of data in
/// front of clipboard, notifications and calls (a delay-based controller in the spirit of LEDBAT, RFC 6817).
/// Thread-safe: senders on worker threads wait in `waitForRoom`; acknowledgements arrive from the main thread.
final class TransferPacer: @unchecked Sendable {
    static let legacyWindowChunks = 64
    static let initialWindow: Int64 = 2 * 1024 * 1024
    static let maximumWindow: Int64 = 32 * 1024 * 1024
    static let targetQueueDelay: TimeInterval = 0.040
    /// How long the lowest round trip is remembered; older minimums expire so a changed route is learnt again.
    static let baseRoundTripMemory: TimeInterval = 10

    let fast: Bool
    let chunkSize: Int
    private let condition = NSCondition()
    private var inFlight: [String: [(sequence: Int64, bytes: Int, sentAt: TimeInterval)]] = [:]
    private var inFlightBytes: Int64 = 0
    private var inFlightChunks = 0
    private(set) var window: Int64
    private var minimumWindow: Int64
    private var baseRoundTrips: [(at: TimeInterval, value: TimeInterval)] = []
    private var lastDecrease: TimeInterval = 0
    private var windowLimited = false
    private(set) var lastRoundTrip: TimeInterval?
    private(set) var smoothedRoundTrip: TimeInterval?
    private var cancelled = false
    private let now: () -> TimeInterval

    /// `initialWindow`: where the window ended for the previous file to the same device, so a queue of files does
    /// not start from 2 MiB each time (live test 2026-10-30: 200 files of 5 MB). Clamped to the window's limits.
    init(fast: Bool, initialWindow: Int64? = nil, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fast = fast
        chunkSize = fast ? FastFrame.chunkSize : 24 * 1024
        minimumWindow = Int64(2 * FastFrame.chunkSize)
        window = fast ? min(Self.maximumWindow, max(minimumWindow, initialWindow ?? Self.initialWindow)) : Int64(Self.legacyWindowChunks)
        self.now = now
    }

    /// The lowest round trip seen recently, in seconds.
    var baseRoundTrip: TimeInterval? { condition.withLock { baseRoundTrips.map(\.value).min() } }
    var windowBytes: Int64 { condition.withLock { fast ? window : Int64(Self.legacyWindowChunks * chunkSize) } }
    var unacknowledgedBytes: Int64 { condition.withLock { inFlightBytes } }

    /// True when one more chunk of `bytes` fits. With nothing in flight a chunk always fits.
    func canSend(_ bytes: Int) -> Bool {
        condition.withLock { roomLocked(bytes) }
    }

    private func roomLocked(_ bytes: Int) -> Bool {
        if fast {
            if inFlightBytes == 0 { return true }
            let fits = inFlightBytes + Int64(bytes) <= window
            if !fits { windowLimited = true }
            return fits
        }
        return inFlightChunks < Self.legacyWindowChunks
    }

    /// Blocks until a chunk of `bytes` fits. Throws `PairingError.cancelled` when cancelled and
    /// `PairingError.invalidMessage` after `timeout` without an acknowledgement making room.
    func waitForRoom(_ bytes: Int, timeout: TimeInterval = 10, isCancelled: () -> Bool = { false }) throws {
        condition.lock()
        defer { condition.unlock() }
        var deadline = Date().addingTimeInterval(timeout)
        var lastBytes = inFlightBytes
        while !roomLocked(bytes) && !cancelled && !isCancelled() {
            if !condition.wait(until: min(deadline, Date().addingTimeInterval(0.25))) {
                if inFlightBytes != lastBytes {
                    lastBytes = inFlightBytes
                    deadline = Date().addingTimeInterval(timeout)
                } else if Date() >= deadline {
                    throw PairingError.invalidMessage
                }
            }
        }
        if cancelled || isCancelled() { throw PairingError.cancelled }
    }

    /// Blocks until everything sent is acknowledged.
    func waitForAll(timeout: TimeInterval = 10, isCancelled: () -> Bool = { false }) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while inFlightChunks > 0 && !cancelled && !isCancelled() {
            if !condition.wait(until: min(deadline, Date().addingTimeInterval(0.25))), Date() >= deadline {
                throw PairingError.invalidMessage
            }
        }
        if cancelled || isCancelled() { throw PairingError.cancelled }
    }

    func didSend(_ id: String, sequence: Int64, bytes: Int) {
        condition.withLock {
            inFlight[id, default: []].append((sequence, bytes, now()))
            inFlightBytes += Int64(bytes)
            inFlightChunks += 1
        }
    }

    /// A cumulative acknowledgement: every chunk of `id` up to `sequence` arrived.
    func acknowledged(_ id: String, through sequence: Int64) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard var queue = inFlight[id], let first = queue.first, first.sequence <= sequence else { return }
        let at = now()
        var ackedBytes = 0
        var ackedChunks = 0
        var newest = first
        while let head = queue.first, head.sequence <= sequence {
            ackedBytes += head.bytes
            ackedChunks += 1
            newest = head
            queue.removeFirst()
        }
        inFlight[id] = queue.isEmpty ? nil : queue
        inFlightBytes -= Int64(ackedBytes)
        inFlightChunks -= ackedChunks
        sample(roundTrip: max(0, at - newest.sentAt), ackedBytes: ackedBytes, at: at)
    }

    /// Drops what is left of a transfer (completed, cancelled or failed) so it no longer counts.
    func forget(_ id: String) {
        condition.withLock {
            guard let queue = inFlight.removeValue(forKey: id) else { return }
            inFlightBytes -= Int64(queue.reduce(0) { $0 + $1.bytes })
            inFlightChunks -= queue.count
            condition.broadcast()
        }
    }

    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    private func sample(roundTrip: TimeInterval, ackedBytes: Int, at: TimeInterval) {
        lastRoundTrip = roundTrip
        smoothedRoundTrip = smoothedRoundTrip.map { $0 * 0.875 + roundTrip * 0.125 } ?? roundTrip
        baseRoundTrips.removeAll { at - $0.at > Self.baseRoundTripMemory }
        baseRoundTrips.append((at, roundTrip))
        if baseRoundTrips.count > 64 { baseRoundTrips.removeFirst(baseRoundTrips.count - 64) }
        guard fast, let base = baseRoundTrips.map(\.value).min() else { return }
        let queueing = roundTrip - base
        if queueing > Self.targetQueueDelay {
            // At most one decrease per round trip, so one burst of late acknowledgements counts once.
            if at - lastDecrease >= max(roundTrip, 0.02) {
                window = max(minimumWindow, Int64(Double(window) * 0.7))
                lastDecrease = at
            }
        } else if windowLimited {
            let growth = queueing < Self.targetQueueDelay / 2 ? Int64(ackedBytes) : Int64(ackedBytes) * Int64(chunkSize) / max(window, 1)
            window = min(Self.maximumWindow, window + max(growth, 1))
            windowLimited = false
        }
    }
}

// MARK: - Speed shown in transfer rows

/// The speed shown in transfer rows: an average with a two-second time constant, so the number is steady enough to
/// read and the time left does not jump, yet follows a real change within a few seconds. The first sample stands alone.
func smoothedRate(_ previous: Double, sample: Double, elapsed: TimeInterval) -> Double {
    guard previous > 0, elapsed < 2 else { return sample }
    return previous + (sample - previous) * (1 - exp(-max(0, elapsed) / 2))
}

/// Bytes per second smoothed over about two seconds, and the time left from it, for transfer rows.
/// Samples come at most every quarter second; a gap longer than a second (a pause) restarts the average.
struct TransferSpeedMeter {
    private var lastAt: TimeInterval?
    private var lastBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0

    mutating func update(bytes: Int64, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let lastAt else {
            self.lastAt = now
            lastBytes = bytes
            return true
        }
        let elapsed = now - lastAt
        guard elapsed >= 0.25 else { return false }
        bytesPerSecond = smoothedRate(bytesPerSecond, sample: Double(max(0, bytes - lastBytes)) / elapsed, elapsed: elapsed)
        self.lastAt = now
        lastBytes = bytes
        return true
    }

    func secondsLeft(remaining: Int64) -> Double? {
        guard bytesPerSecond >= 1, remaining > 0 else { return nil }
        return Double(remaining) / bytesPerSecond
    }
}

/// Fast transfers are on unless turned off for a test (`defaults write in.roundrobin.bridgey transfers.fastOff
/// -bool true`): then this Mac advertises `files_fast_draft1` false and every peer gets the 24 KiB JSON chunks.
enum FastTransferSettings {
    static var enabled: Bool { !UserDefaults.standard.bool(forKey: "transfers.fastOff") }
}
