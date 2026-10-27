import Foundation

/*
 * Phone screen to Mac, draft `screen_draft1` (docs/protocol.md, "Phone screen to Mac"): the wire
 * format only, pure and tested against the golden vectors. The phone captures and encodes; this
 * Mac decodes, shows and acknowledges. View only: nothing here sends input to the phone.
 */

let screenFeatureKey = "screen_draft1"

enum ScreenLimits {
    static let requestBytes = 512
    static let startBytes = 1024
    static let messageBytes = 512
    static let headerBytes = 40
    static let maximumPartPayload = 32_768
    static let maximumParts = 64
    static let maximumSequence = 9_007_199_254_740_991
    static let maximumFrame = UInt32.max
    static let dimensions = 16...4096
    static let fps = 1...60
    static let bitrate = 100_000...50_000_000
}

/// `screen.status`: how the phone answered this Mac's request.
enum ScreenStatus: String, Equatable, CaseIterable {
    case waiting, declined, busy, disabled, failed
}

/// Why a stream ended. `disconnected` is local only (the session closed) and never sent.
enum ScreenStopReason: String, Equatable, CaseIterable {
    case user, closed, ended, screenOff = "screen_off", disabled, invalid, timeout, failed
}

/// A canonical lowercase UUID, or nil.
func screenUUID(_ value: Any?) -> String? {
    guard let text = value as? String, let uuid = UUID(uuidString: text) else { return nil }
    return uuid.uuidString.lowercased()
}

private func screenObject(_ data: Data, limit: Int) -> [String: Any]? {
    guard data.count <= limit, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          jsonInteger(object["version"]) == 1 else { return nil }
    return object
}

private func screenInteger(_ object: [String: Any], _ key: String, _ range: ClosedRange<Int>) -> Int? {
    guard let value = jsonInteger(object[key]), range.contains(value) else { return nil }
    return value
}

/// The fields every stream message carries: the stream and the sender's sequence.
private func streamHeader(_ object: [String: Any]) -> (streamID: String, sequence: Int)? {
    guard let streamID = screenUUID(object["streamId"]),
          let sequence = screenInteger(object, "sequence", 1...ScreenLimits.maximumSequence) else { return nil }
    return (streamID, sequence)
}

// MARK: Asking

/// The `screen.request` plaintext.
func screenRequestPayload(_ requestID: String) -> [String: Any] { ["version": 1, "requestId": requestID] }

/// A `screen.status` plaintext: at most 512 bytes, a UUID `requestId` and a known `status`.
func decodeScreenStatus(_ data: Data) -> (requestID: String, status: ScreenStatus)? {
    guard let object = screenObject(data, limit: ScreenLimits.messageBytes),
          let requestID = screenUUID(object["requestId"]),
          let wire = object["status"] as? String, let status = ScreenStatus(rawValue: wire) else { return nil }
    return (requestID, status)
}

// MARK: Stream messages

struct ScreenStart: Equatable {
    let streamID: String
    let sequence: Int
    let requestID: String?
    let codec: String
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int

    /// At most 1,024 bytes; codec `h264`; even sizes from 16 to 4,096; 1 to 60 fps; 100 kb/s to 50 Mb/s.
    static func decode(_ data: Data) -> ScreenStart? {
        guard let object = screenObject(data, limit: ScreenLimits.startBytes), let header = streamHeader(object),
              let codec = object["codec"] as? String, codec == "h264",
              let width = screenInteger(object, "width", ScreenLimits.dimensions), width % 2 == 0,
              let height = screenInteger(object, "height", ScreenLimits.dimensions), height % 2 == 0,
              let fps = screenInteger(object, "fps", ScreenLimits.fps),
              let bitrate = screenInteger(object, "bitrate", ScreenLimits.bitrate) else { return nil }
        var requestID: String?
        if let value = object["requestId"], !(value is NSNull) {
            guard let id = screenUUID(value) else { return nil }
            requestID = id
        }
        return ScreenStart(streamID: header.streamID, sequence: header.sequence, requestID: requestID, codec: codec,
                           width: width, height: height, fps: fps, bitrate: bitrate)
    }

    /// The stream a start that failed validation names, so the Mac can answer `invalid`.
    static func streamID(of data: Data) -> String? {
        guard data.count <= ScreenLimits.startBytes, isStrictJSONObject(data),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return screenUUID(object["streamId"])
    }
}

struct ScreenStats: Equatable {
    let streamID: String
    let sequence: Int
    let latencyMs: Int
    let rttMs: Int
    let bitrate: Int
    let sentBitrate: Int
    let fps: Int
    let dropped: Int

    static func decode(_ data: Data) -> ScreenStats? {
        guard let object = screenObject(data, limit: ScreenLimits.messageBytes), let header = streamHeader(object),
              let latency = screenInteger(object, "latencyMs", 0...60_000),
              let rtt = screenInteger(object, "rttMs", 0...60_000),
              let bitrate = screenInteger(object, "bitrate", 0...50_000_000),
              let sent = screenInteger(object, "sentBitrate", 0...50_000_000),
              let fps = screenInteger(object, "fps", 0...120),
              let dropped = screenInteger(object, "dropped", 0...1000) else { return nil }
        return ScreenStats(streamID: header.streamID, sequence: header.sequence, latencyMs: latency, rttMs: rtt,
                           bitrate: bitrate, sentBitrate: sent, fps: fps, dropped: dropped)
    }
}

struct ScreenStop: Equatable {
    let streamID: String
    let sequence: Int
    let reason: ScreenStopReason

    /// An unknown or missing reason reads as `failed`.
    static func decode(_ data: Data) -> ScreenStop? {
        guard let object = screenObject(data, limit: ScreenLimits.messageBytes), let header = streamHeader(object) else { return nil }
        let reason = (object["reason"] as? String).flatMap(ScreenStopReason.init(rawValue:)) ?? .failed
        return ScreenStop(streamID: header.streamID, sequence: header.sequence, reason: reason)
    }
}

/// What this Mac writes on a stream.
func screenStartedPayload(streamID: String, sequence: Int) -> [String: Any] {
    ["version": 1, "streamId": streamID, "sequence": sequence]
}

/// `keyframe` is written only when true.
func screenAckPayload(streamID: String, sequence: Int, frame: UInt32, decodeMs: Int, keyframe: Bool) -> [String: Any] {
    var payload: [String: Any] = ["version": 1, "streamId": streamID, "sequence": sequence, "frame": Int(frame),
                                  "decodeMs": min(max(decodeMs, 0), 60_000)]
    if keyframe { payload["keyframe"] = true }
    return payload
}

func screenStopPayload(streamID: String, sequence: Int, reason: ScreenStopReason) -> [String: Any] {
    ["version": 1, "streamId": streamID, "sequence": sequence, "reason": reason.rawValue]
}

// MARK: Frames

/// One `screen.frame` plaintext: the 40-byte header and its H.264 Annex B bytes.
struct ScreenFramePart: Equatable {
    static let keyFlag: UInt8 = 0x01
    static let parameterSetsFlag: UInt8 = 0x02
    static let lastFlag: UInt8 = 0x04

    let streamID: String
    let sequence: Int
    let frame: UInt32
    let part: Int
    let key: Bool
    let parameterSets: Bool
    let last: Bool
    let captureMicros: Int64
    let payload: Data

    /// Nil when shorter than the header plus one byte, over 32,808 bytes, version not 1, part over 63,
    /// sequence or frame out of range, a capture time over 2^63-1, or a part 0 without a start code.
    static func decode(_ data: Data) -> ScreenFramePart? {
        let count = data.count
        guard count > ScreenLimits.headerBytes, count <= ScreenLimits.headerBytes + ScreenLimits.maximumPartPayload else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ScreenFramePart? in
            let bytes = raw.bindMemory(to: UInt8.self)
            func integer(_ offset: Int, _ length: Int) -> UInt64 {
                var value: UInt64 = 0
                for index in offset..<offset + length { value = value << 8 | UInt64(bytes[index]) }
                return value
            }
            guard bytes[0] == 1 else { return nil }
            let flags = bytes[1]
            let part = Int(integer(2, 2))
            let sequence = integer(20, 8)
            let frame = integer(28, 4)
            let capture = integer(32, 8)
            guard part < ScreenLimits.maximumParts, (1...UInt64(ScreenLimits.maximumSequence)).contains(sequence), frame >= 1,
                  capture <= UInt64(Int64.max) else { return nil }
            let uuidBytes = (bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                             bytes[12], bytes[13], bytes[14], bytes[15], bytes[16], bytes[17], bytes[18], bytes[19])
            let payload = Data(bytes[ScreenLimits.headerBytes...])
            if part == 0 && !annexBStartsWithStartCode(payload) { return nil }
            return ScreenFramePart(streamID: UUID(uuid: uuidBytes).uuidString.lowercased(), sequence: Int(sequence), frame: UInt32(frame),
                                   part: part, key: flags & keyFlag != 0, parameterSets: flags & parameterSetsFlag != 0,
                                   last: flags & lastFlag != 0, captureMicros: Int64(capture), payload: payload)
        }
    }

    /// The plaintext the phone writes (used by tests and the round trip).
    func encoded() -> Data {
        var data = Data(capacity: ScreenLimits.headerBytes + payload.count)
        data.append(1)
        data.append((key ? Self.keyFlag : 0) | (parameterSets ? Self.parameterSetsFlag : 0) | (last ? Self.lastFlag : 0))
        func put(_ value: UInt64, _ length: Int) { for shift in stride(from: (length - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) } }
        put(UInt64(part), 2)
        let uuid = UUID(uuidString: streamID)?.uuid ?? UUID().uuid
        withUnsafeBytes(of: uuid) { data.append(contentsOf: $0) }
        put(UInt64(sequence), 8)
        put(UInt64(frame), 4)
        put(UInt64(captureMicros), 8)
        data.append(payload)
        return data
    }
}

/// Starts with 00 00 01 or 00 00 00 01.
func annexBStartsWithStartCode(_ data: Data) -> Bool {
    let bytes = [UInt8](data.prefix(4))
    if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 { return true }
    return bytes.count >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1
}

// MARK: Reassembly

/// A whole access unit, ready to decode.
struct ScreenAssembledFrame: Equatable {
    let frame: UInt32
    let key: Bool
    let parameterSets: Bool
    let captureMicros: Int64
    let data: Data
}

/// Puts the parts of each frame back together. Keeps one unfinished frame; a part out of order, a
/// missing part 0 or a later frame arriving first loses the frame (the caller then waits for a key frame).
struct ScreenFrameAssembler {
    enum Event: Equatable {
        /// Waiting for more parts.
        case pending
        /// A complete frame.
        case complete(ScreenAssembledFrame)
        /// A frame was lost: `frame` is the newest frame number seen.
        case lost(frame: UInt32)
        /// A part of a frame already finished or given up: dropped quietly.
        case ignored
    }

    private struct Partial {
        let frame: UInt32
        var nextPart: Int
        let key: Bool
        let parameterSets: Bool
        let captureMicros: Int64
        var data: Data
    }

    private var partial: Partial?
    /// The newest frame number finished or given up.
    private(set) var newestFrame: UInt32 = 0

    mutating func add(_ part: ScreenFramePart) -> Event {
        if part.frame <= newestFrame { return .ignored }
        var lostOne = false
        if let current = partial, current.frame != part.frame {
            // A later frame started before this one finished.
            partial = nil
            lostOne = true
        }
        if var current = partial {
            guard part.part == current.nextPart else { return give(up: part.frame) }
            current.data.append(part.payload)
            current.nextPart += 1
            partial = current
        } else {
            guard part.part == 0 else { return give(up: part.frame) }
            partial = Partial(frame: part.frame, nextPart: 1, key: part.key, parameterSets: part.parameterSets,
                              captureMicros: part.captureMicros, data: part.payload)
        }
        if part.last, let done = partial {
            partial = nil
            newestFrame = done.frame
            // A lost earlier frame still means the decoder needs a key frame, unless this one is one.
            if lostOne && !done.key { return .lost(frame: done.frame) }
            return .complete(ScreenAssembledFrame(frame: done.frame, key: done.key, parameterSets: done.parameterSets,
                                                  captureMicros: done.captureMicros, data: done.data))
        }
        return lostOne ? .lost(frame: part.frame) : .pending
    }

    private mutating func give(up frame: UInt32) -> Event {
        partial = nil
        newestFrame = max(newestFrame, frame)
        return .lost(frame: frame)
    }
}

/// A per-stream high-water mark for one side's messages.
struct ScreenSequence: Equatable {
    private(set) var last = 0

    init(after start: Int = 0) { last = start }

    mutating func accept(_ sequence: Int) -> Bool {
        guard (1...ScreenLimits.maximumSequence).contains(sequence), sequence > last else { return false }
        last = sequence
        return true
    }
}

// MARK: H.264 Annex B

enum AnnexB {
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    static let accessUnitDelimiter: UInt8 = 9

    /// The NAL units between start codes, without the start codes or trailing zero bytes.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let begin = start { units.append(trimmed(bytes, begin, index)) }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let begin = start, begin < bytes.count { units.append(trimmed(bytes, begin, bytes.count)) }
        return units.filter { !$0.isEmpty }
    }

    private static func trimmed(_ bytes: [UInt8], _ begin: Int, _ end: Int) -> Data {
        var stop = end
        while stop > begin, bytes[stop - 1] == 0 { stop -= 1 }
        return Data(bytes[begin..<stop])
    }

    static func type(_ unit: Data) -> UInt8 { (unit.first ?? 0) & 0x1F }

    /// The access unit split into its parameter sets and the rest as 4-byte length-prefixed NAL units (AVCC).
    static func avcc(_ data: Data) -> (sps: Data?, pps: [Data], avcc: Data, hasIDR: Bool) {
        var sps: Data?
        var pps: [Data] = []
        var avcc = Data()
        var idr = false
        for unit in nalUnits(data) {
            switch type(unit) {
            case Self.sps: sps = unit
            case Self.pps: pps.append(unit)
            case Self.accessUnitDelimiter: continue
            default:
                if type(unit) == 5 { idr = true }
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
                avcc.append(unit)
            }
        }
        return (sps, pps, avcc, idr)
    }
}
