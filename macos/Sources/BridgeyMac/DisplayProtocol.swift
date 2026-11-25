import CoreGraphics
import Foundation

/*
 * Mac screen to phone, draft `screen_control_draft1` (docs/protocol.md, "Mac screen to phone"): the source's side
 * of the wire, pure and checked against protocol/test-vectors/display-v1.json. The Mac is the source: it decodes
 * what the viewer (the phone) sends and builds what it sends back. Frames reuse the `screen.frame` layout
 * (ScreenFramePart). Input packets are the shared contract's (ScreenControlContract.swift).
 */

enum DisplayLimits {
    static let requestBytes = 1_024
    static let startBytes = 2_048
    static let messageBytes = 512
    static let displayNameBytes = 64
    /// The long side of the stream.
    static let longSide = 1_920
    static let minimumSide = 16
    static let fps = 1...60
    static let bitrate = 100_000...50_000_000
    static let maximumFrame = UInt32.max
    /// One open request per viewer, at most one every 3 seconds, expiring after 2 minutes.
    static let requestSpacing: TimeInterval = 3
    static let requestLifetime: TimeInterval = 120
    static let startedTimeout: TimeInterval = 5
    static let ackTimeout: TimeInterval = 6
    static let rememberedStreams = 16
}

/// `display.status`.
enum DisplayStatus: String, CaseIterable, Equatable {
    case waiting, declined, busy, disabled, permission, locked, failed
}

/// Why a stream ended. `disconnected` is local only and never sent.
enum DisplayStopReason: String, CaseIterable, Equatable {
    case user
    case leftScreen = "left_screen"
    case screenOff = "screen_off"
    case localStop = "local_stop"
    case disabled, permission, locked
    case sourceChanged = "source_changed"
    case invalid, timeout, failed
}

/// Why control ended or was refused (`display.control`). An unknown reason reads as `failed`.
enum DisplayControlReason: String, CaseIterable, Equatable {
    case user
    case localStop = "local_stop"
    case disabled, permission, locked, busy, focus, timeout, rate, invalid
    case sourceChanged = "source_changed"
    case failed
}

enum DisplayControlAction: String, Equatable {
    case begin, end
}

/// What the source says about control.
enum DisplayControlState: Equatable {
    case active(session: UInt64, input: ScreenControl.InputCapabilities)
    case ended(DisplayControlReason)
    case refused(DisplayControlReason)
}

private func displayObject(_ data: Data, limit: Int) -> [String: Any]? {
    guard data.count <= limit, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          jsonInteger(object["version"]) == 1 else { return nil }
    return object
}

private func displayInteger(_ object: [String: Any], _ key: String, _ range: ClosedRange<Int>) -> Int? {
    guard let value = jsonInteger(object[key]), range.contains(value) else { return nil }
    return value
}

private func displayStreamHeader(_ object: [String: Any]) -> (streamID: String, sequence: Int)? {
    guard let streamID = screenUUID(object["streamId"]),
          let sequence = displayInteger(object, "sequence", 1...ScreenLimits.maximumSequence) else { return nil }
    return (streamID, sequence)
}

// MARK: What the source reads

struct DisplayRequest: Equatable {
    let requestID: String
    let capabilities: ScreenControl.Capabilities

    /// At most 1,024 bytes, a UUID requestId and the viewer's contract capabilities (v 1).
    static func decode(_ data: Data) -> DisplayRequest? {
        guard let object = displayObject(data, limit: DisplayLimits.requestBytes),
              let requestID = screenUUID(object["requestId"]),
              case let .success(capabilities) = ScreenControl.Capabilities.decode(object: object["capabilities"]) else { return nil }
        return DisplayRequest(requestID: requestID, capabilities: capabilities)
    }
}

struct DisplayStarted: Equatable {
    let streamID: String
    let sequence: Int

    static func decode(_ data: Data) -> DisplayStarted? {
        guard let object = displayObject(data, limit: DisplayLimits.messageBytes), let header = displayStreamHeader(object) else { return nil }
        return DisplayStarted(streamID: header.streamID, sequence: header.sequence)
    }
}

struct DisplayAck: Equatable {
    let streamID: String
    let sequence: Int
    let frame: UInt32
    let decodeMs: Int
    let keyframe: Bool

    static func decode(_ data: Data) -> DisplayAck? {
        guard let object = displayObject(data, limit: DisplayLimits.messageBytes), let header = displayStreamHeader(object),
              let frame = displayInteger(object, "frame", 1...Int(DisplayLimits.maximumFrame)),
              let decodeMs = displayInteger(object, "decodeMs", 0...60_000) else { return nil }
        var keyframe = false
        if let value = object["keyframe"], !(value is NSNull) {
            guard let flag = JSONField.bool(value) else { return nil }
            keyframe = flag
        }
        return DisplayAck(streamID: header.streamID, sequence: header.sequence, frame: UInt32(frame), decodeMs: decodeMs, keyframe: keyframe)
    }
}

/// `display.control` as the viewer sends it: `action` begin or end. A source-form payload is not read here.
struct DisplayViewerControl: Equatable {
    let streamID: String
    let sequence: Int
    let action: DisplayControlAction

    static func decode(_ data: Data) -> DisplayViewerControl? {
        guard let object = displayObject(data, limit: DisplayLimits.messageBytes), let header = displayStreamHeader(object),
              let wire = object["action"] as? String, let action = DisplayControlAction(rawValue: wire) else { return nil }
        return DisplayViewerControl(streamID: header.streamID, sequence: header.sequence, action: action)
    }
}

struct DisplayStop: Equatable {
    let streamID: String
    let sequence: Int
    let reason: DisplayStopReason

    /// An unknown or missing reason reads as `failed`.
    static func decode(_ data: Data) -> DisplayStop? {
        guard let object = displayObject(data, limit: DisplayLimits.messageBytes), let header = displayStreamHeader(object) else { return nil }
        let reason = (object["reason"] as? String).flatMap(DisplayStopReason.init(rawValue:)) ?? .failed
        return DisplayStop(streamID: header.streamID, sequence: header.sequence, reason: reason)
    }
}

// MARK: What the source writes

/// The fields of a `display.start`.
struct DisplayStartInfo: Equatable {
    var streamID: String
    var sequence: Int
    var requestID: String
    var fps: Int
    var bitrate: Int
    var stream: UInt64
    var transport: UInt64
    var geometry: ScreenControl.Geometry
    var capabilities: ScreenControl.Capabilities
    var control: Bool
    var displayName: String?
}

enum DisplayPayloads {
    static func status(requestID: String, status: DisplayStatus) -> [String: Any] {
        ["version": 1, "requestId": requestID, "status": status.rawValue]
    }

    /// The display name is cut to 64 UTF-8 bytes on a character boundary, never sent longer.
    static func start(_ info: DisplayStartInfo) -> [String: Any] {
        var payload: [String: Any] = [
            "version": 1, "streamId": info.streamID, "sequence": info.sequence, "requestId": info.requestID, "codec": "h264",
            "fps": info.fps, "bitrate": info.bitrate, "stream": Int(info.stream), "transport": Int(info.transport),
            "geometry": info.geometry.json, "capabilities": info.capabilities.json, "control": info.control,
        ]
        if let name = info.displayName.map(boundedDisplayName), !name.isEmpty { payload["displayName"] = name }
        return payload
    }

    static func stats(streamID: String, sequence: Int, latencyMs: Int, rttMs: Int, bitrate: Int, sentBitrate: Int, fps: Int,
                      dropped: Int) -> [String: Any] {
        ["version": 1, "streamId": streamID, "sequence": sequence,
         "latencyMs": min(max(latencyMs, 0), 60_000), "rttMs": min(max(rttMs, 0), 60_000),
         "bitrate": min(max(bitrate, 0), 50_000_000), "sentBitrate": min(max(sentBitrate, 0), 50_000_000),
         "fps": min(max(fps, 0), 120), "dropped": min(max(dropped, 0), 1_000)]
    }

    static func geometry(streamID: String, sequence: Int, geometry: ScreenControl.Geometry) -> [String: Any] {
        ["version": 1, "streamId": streamID, "sequence": sequence, "geometry": geometry.json]
    }

    static func control(streamID: String, sequence: Int, state: DisplayControlState) -> [String: Any] {
        var payload: [String: Any] = ["version": 1, "streamId": streamID, "sequence": sequence]
        switch state {
        case let .active(session, input):
            payload["state"] = "active"
            payload["session"] = Int(session)
            payload["input"] = input.json
        case let .ended(reason):
            payload["state"] = "ended"
            payload["reason"] = reason.rawValue
        case let .refused(reason):
            payload["state"] = "refused"
            payload["reason"] = reason.rawValue
        }
        return payload
    }

    static func stop(streamID: String, sequence: Int, reason: DisplayStopReason) -> [String: Any] {
        ["version": 1, "streamId": streamID, "sequence": sequence, "reason": reason.rawValue]
    }

    static func boundedDisplayName(_ name: String) -> String {
        var result = ""
        for character in name {
            if result.utf8.count + String(character).utf8.count > DisplayLimits.displayNameBytes { break }
            result.append(character)
        }
        return result
    }
}

// MARK: Geometry rules

enum DisplayGeometryRules {
    /// The captured size: the display's native pixels, aspect kept, the long side at most 1,920, both sides even and
    /// at least 16.
    static func captureSize(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
        let long = max(nativeWidth, nativeHeight, 1)
        let scale = min(1.0, Double(DisplayLimits.longSide) / Double(long))
        func side(_ value: Int) -> Int { max(DisplayLimits.minimumSide, Int((Double(value) * scale / 2).rounded(.down)) * 2) }
        return (side(nativeWidth), side(nativeHeight))
    }

    /// Where a validated packet position lands: the contract's captured pixel, then its centre on the selected
    /// display in global Quartz points (`bounds`, origin top left of the main display, y down; negative left of
    /// or above it). Nil for a position outside `[0, 1]` or an invalid geometry: nothing is ever clamped onto
    /// another display.
    static func macPoint(geometry: ScreenControl.Geometry, bounds: CGRect, x: Double, y: Double)
        -> (pixel: ScreenControl.PixelPoint, point: CGPoint)? {
        guard let pixel = geometry.pixel(x, y), !bounds.isEmpty else { return nil }
        let point = CGPoint(x: Double(bounds.minX) + (Double(pixel.x) + 0.5) * Double(bounds.width) / Double(geometry.width),
                            y: Double(bounds.minY) + (Double(pixel.y) + 0.5) * Double(bounds.height) / Double(geometry.height))
        return (pixel, point)
    }

    /// Key and text input go to the focused window: it must be on the shared display (its centre), unless the Mac has
    /// only one display. With more than one display and no focused window, typing is refused.
    static func keyboardEligible(display: CGRect, focusedWindow: CGRect?, displayCount: Int) -> Bool {
        if displayCount <= 1 { return true }
        guard let window = focusedWindow else { return false }
        let centre = CGPoint(x: window.midX, y: window.midY)
        return centre.x >= display.minX && centre.x < display.maxX && centre.y >= display.minY && centre.y < display.maxY
    }
}
