import Foundation

/*
 * The Mac controls the phone, draft `phone_control_draft1` (docs/protocol.md, "Mac controls the phone"): this Mac's side
 * of the wire inside a `screen_draft1` stream, pure and checked against protocol/test-vectors/phone-control-v1.json.
 * The phone is the source and input host; this Mac is the viewer and controller. Input packets are the shared contract's
 * (ScreenControlContract.swift).
 */

let phoneControlFeatureKey = "phone_control_draft1"

/// The messages this key adds to a phone's stream. Sent or handled by this Mac.
enum PhoneControlKinds {
    static let geometry = "screen.geometry"
    static let control = "screen.control"
    static let input = "screen.input"
}

enum PhoneControlLimits {
    static let messageBytes = 512
    static let inputBytes = ScreenControl.maxPacketBytes
}

/// Why control ended or was refused on the phone. An unknown reason reads as `failed`.
enum PhoneControlReason: String, CaseIterable, Equatable {
    case user
    case localStop = "local_stop"
    case declined, disabled, permission, locked, focus, timeout, rate, invalid
    case sourceChanged = "source_changed"
    case failed
}

/// What this Mac can do as a viewer and controller of a phone: H.264 decoding, touch (clicks and drags), a pointer
/// (scrolling), keys, text and navigation. Support, never permission.
let macControllerCapabilities = ScreenControl.Capabilities(
    v: ScreenControl.version, screenViewer: true, h264Decode: true,
    inputController: ScreenControl.InputCapabilities(pointer: true, touch: true, keys: true, text: true, navigation: true))

private func controlObject(_ data: Data) -> [String: Any]? {
    guard data.count <= PhoneControlLimits.messageBytes, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          jsonInteger(object["version"]) == 1 else { return nil }
    return object
}

private func controlHeader(_ object: [String: Any]) -> (streamID: String, sequence: Int)? {
    guard let streamID = screenUUID(object["streamId"]), let sequence = jsonInteger(object["sequence"]),
          (1...ScreenLimits.maximumSequence).contains(sequence) else { return nil }
    return (streamID, sequence)
}

/// A geometry a phone stream may use: valid, a display, even sides of at least 16 pixels.
func phoneStreamGeometry(_ value: Any?) -> ScreenControl.Geometry? {
    guard let geometry = ScreenControl.Geometry.decode(value), geometry.valid, geometry.kind == .display,
          geometry.width >= 16, geometry.height >= 16, geometry.width % 2 == 0, geometry.height % 2 == 0 else { return nil }
    return geometry
}

/// The control object of a control-capable `screen.start`.
struct PhoneControlOffer: Equatable {
    let stream: UInt64
    let transport: UInt64
    let geometry: ScreenControl.Geometry
    let capabilities: ScreenControl.Capabilities
    /// Control may be asked for now (the phone's accessibility service is on).
    let allowed: Bool

    /// Nil, so the stream is view only, when the object is missing or breaks any rule (the geometry must be the stream's size).
    static func decode(_ value: Any?, width: Int, height: Int) -> PhoneControlOffer? {
        guard let object = value as? [String: Any],
              let stream = JSONField.unsigned(object["stream"], max: ScreenControl.maxSequence), ScreenControl.validCounter(stream),
              let transport = JSONField.unsigned(object["transport"], max: ScreenControl.maxSequence), ScreenControl.validCounter(transport),
              let geometry = phoneStreamGeometry(object["geometry"]), Int(geometry.width) == width, Int(geometry.height) == height,
              case let .success(capabilities) = ScreenControl.Capabilities.decode(object: object["capabilities"]),
              let allowed = JSONField.bool(object["allowed"]) else { return nil }
        return PhoneControlOffer(stream: stream, transport: transport, geometry: geometry, capabilities: capabilities, allowed: allowed)
    }
}

/// `screen.geometry` from the phone.
struct PhoneGeometryMessage: Equatable {
    let streamID: String
    let sequence: Int
    let geometry: ScreenControl.Geometry

    static func decode(_ data: Data) -> PhoneGeometryMessage? {
        guard let object = controlObject(data), let header = controlHeader(object), let geometry = phoneStreamGeometry(object["geometry"]) else { return nil }
        return PhoneGeometryMessage(streamID: header.streamID, sequence: header.sequence, geometry: geometry)
    }
}

/// What the phone says about control.
enum PhoneControlState: Equatable {
    case waiting
    case active(session: UInt64, input: ScreenControl.InputCapabilities)
    case ended(PhoneControlReason)
    case refused(PhoneControlReason)
    case available(Bool)
}

/// `screen.control` from the phone.
struct PhoneControlMessage: Equatable {
    let streamID: String
    let sequence: Int
    let state: PhoneControlState

    /// Nil for anything malformed or an unknown state (dropped, never answered).
    static func decode(_ data: Data) -> PhoneControlMessage? {
        guard let object = controlObject(data), let header = controlHeader(object), let state = object["state"] as? String else { return nil }
        let decoded: PhoneControlState
        switch state {
        case "waiting":
            decoded = .waiting
        case "active":
            guard let session = JSONField.unsigned(object["session"], max: ScreenControl.maxSequence), ScreenControl.validCounter(session),
                  let input = ScreenControl.InputCapabilities.decode(object["input"]) else { return nil }
            decoded = .active(session: session, input: input)
        case "ended", "refused":
            let reason = (object["reason"] as? String).flatMap(PhoneControlReason.init(rawValue:)) ?? .failed
            decoded = state == "ended" ? .ended(reason) : .refused(reason)
        case "available":
            guard let allowed = JSONField.bool(object["allowed"]) else { return nil }
            decoded = .available(allowed)
        default:
            return nil
        }
        return PhoneControlMessage(streamID: header.streamID, sequence: header.sequence, state: decoded)
    }
}

/// `screen.control` from this Mac: begin, with this Mac's capabilities, or end.
func phoneControlBeginPayload(streamID: String, sequence: Int, capabilities: ScreenControl.Capabilities = macControllerCapabilities) -> [String: Any] {
    ["version": 1, "streamId": streamID, "sequence": sequence, "action": "begin", "capabilities": capabilities.json]
}

func phoneControlEndPayload(streamID: String, sequence: Int) -> [String: Any] {
    ["version": 1, "streamId": streamID, "sequence": sequence, "action": "end"]
}

/// The window's view of the picture: where the stream sits in a view, aspect kept and centred.
enum PhoneScreenGeometry {
    /// A point in a view of `size` (top-left origin) as fractions of the full stream; nil on the letterbox.
    static func fraction(viewSize: CGSize, videoWidth: Int, videoHeight: Int, point: CGPoint, clamp: Bool = false) -> (x: Double, y: Double)? {
        guard viewSize.width > 0, viewSize.height > 0, videoWidth > 0, videoHeight > 0 else { return nil }
        let k = min(Double(viewSize.width) / Double(videoWidth), Double(viewSize.height) / Double(videoHeight))
        let width = Double(videoWidth) * k
        let height = Double(videoHeight) * k
        let left = (Double(viewSize.width) - width) / 2
        let top = (Double(viewSize.height) - height) / 2
        var x = (Double(point.x) - left) / width
        var y = (Double(point.y) - top) / height
        guard x.isFinite, y.isFinite else { return nil }
        if clamp {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return (x, y)
    }

    /// A scroll distance in view points as stream pixels: the content moves with the fingers.
    static func streamPixels(viewDelta: Double, viewSize: CGSize, videoWidth: Int, videoHeight: Int) -> Double {
        guard viewSize.width > 0, viewSize.height > 0, videoWidth > 0, videoHeight > 0 else { return 0 }
        let k = min(Double(viewSize.width) / Double(videoWidth), Double(viewSize.height) / Double(videoHeight))
        return viewDelta / k
    }
}
