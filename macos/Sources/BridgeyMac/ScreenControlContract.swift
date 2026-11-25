import CryptoKit
import Foundation

/*
 * The shared screen/control contract, `bridgey-screen-control-draft1` (docs/screen-control-core.md), ported from
 * rust/proto/src/screen_control.rs with the same rules and the same golden vectors
 * (rust/proto/test-vectors/screen-control-v1.json). Pure: no capture, no injection, no permission.
 *
 * The native adapter owns grants, permissions, capture and injection. It passes a fresh local authority snapshot
 * plus the sender's authenticated binding; neither comes from packet JSON. Every transition's `release` must be
 * applied before dispatching another native input.
 */
enum ScreenControl {
    static let protocolName = "bridgey-screen-control-draft1"
    static let version: UInt8 = 1
    static let maxSequence: UInt64 = 9_007_199_254_740_991
    static let maxPacketBytes = 2_048
    static let maxTextBytes = 1_024
    static let maxTextScalars = 256
    static let idleMillis: UInt64 = 6_000
    static let maxDimension: UInt32 = 32_768
    static let maxPixels: UInt64 = 67_108_864

    static func validCounter(_ value: UInt64) -> Bool { value > 0 && value <= maxSequence }

    // MARK: Capabilities

    struct InputCapabilities: Equatable {
        var pointer = false
        var touch = false
        var keys = false
        var text = false
        var navigation = false

        var any: Bool { pointer || touch || keys || text || navigation }

        func intersect(_ other: InputCapabilities) -> InputCapabilities {
            InputCapabilities(pointer: pointer && other.pointer, touch: touch && other.touch, keys: keys && other.keys,
                              text: text && other.text, navigation: navigation && other.navigation)
        }

        /// Missing flags are false, unknown flags ignored; a flag that is not a boolean rejects.
        static func decode(_ value: Any?) -> InputCapabilities? {
            guard let object = value as? [String: Any] else { return nil }
            var result = InputCapabilities()
            let flags: [(String, WritableKeyPath<InputCapabilities, Bool>)] = [
                ("pointer", \.pointer), ("touch", \.touch), ("keys", \.keys), ("text", \.text), ("navigation", \.navigation),
            ]
            for (key, path) in flags {
                guard let raw = object[key] else { continue }
                guard let flag = JSONField.bool(raw) else { return nil }
                result[keyPath: path] = flag
            }
            return result
        }

        var json: [String: Any] { ["pointer": pointer, "touch": touch, "keys": keys, "text": text, "navigation": navigation] }
    }

    /// Advisory support, never permission. Missing flags remain false; unknown flags are ignored.
    struct Capabilities: Equatable {
        var v: UInt8 = 0
        var screenSource = false
        var screenViewer = false
        var fullDisplaySource = false
        var h264Encode = false
        var h264Decode = false
        var inputHost = InputCapabilities()
        var inputController = InputCapabilities()
        var captureRequiresPrompt = false
        var captureRestoreSupported = false

        static func decode(_ data: Data) -> Result<Capabilities, Rejection> {
            guard data.count <= maxPacketBytes else { return .failure(.packetSize) }
            guard isStrictJSONObject(data), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(.malformed)
            }
            return decode(object: object)
        }

        /// An already parsed object (the capabilities field inside a display.* payload).
        static func decode(object: Any?) -> Result<Capabilities, Rejection> {
            guard let object = object as? [String: Any] else { return .failure(.malformed) }
            var result = Capabilities()
            if let raw = object["v"] {
                guard let v = JSONField.unsigned(raw, max: UInt64(UInt8.max)) else { return .failure(.malformed) }
                result.v = UInt8(v)
            }
            let flags: [(String, WritableKeyPath<Capabilities, Bool>)] = [
                ("screenSource", \.screenSource), ("screenViewer", \.screenViewer), ("fullDisplaySource", \.fullDisplaySource),
                ("h264Encode", \.h264Encode), ("h264Decode", \.h264Decode), ("captureRequiresPrompt", \.captureRequiresPrompt),
                ("captureRestoreSupported", \.captureRestoreSupported),
            ]
            for (key, path) in flags {
                guard let raw = object[key] else { continue }
                guard let flag = JSONField.bool(raw) else { return .failure(.malformed) }
                result[keyPath: path] = flag
            }
            let inputs: [(String, WritableKeyPath<Capabilities, InputCapabilities>)] = [
                ("inputHost", \.inputHost), ("inputController", \.inputController),
            ]
            for (key, path) in inputs {
                guard let raw = object[key] else { continue }
                guard let decoded = InputCapabilities.decode(raw) else { return .failure(.malformed) }
                result[keyPath: path] = decoded
            }
            guard result.v == ScreenControl.version else { return .failure(.version) }
            return .success(result)
        }

        static func negotiatedInput(host: Capabilities, controller: Capabilities) -> Result<InputCapabilities, Rejection> {
            guard host.v == ScreenControl.version, controller.v == ScreenControl.version else { return .failure(.version) }
            guard host.screenSource, host.fullDisplaySource, host.h264Encode, controller.screenViewer, controller.h264Decode else {
                return .failure(.unsupported)
            }
            let input = host.inputHost.intersect(controller.inputController)
            guard input.any else { return .failure(.unsupported) }
            return .success(input)
        }

        var json: [String: Any] {
            ["v": Int(v), "screenSource": screenSource, "screenViewer": screenViewer, "fullDisplaySource": fullDisplaySource,
             "h264Encode": h264Encode, "h264Decode": h264Decode, "inputHost": inputHost.json, "inputController": inputController.json,
             "captureRequiresPrompt": captureRequiresPrompt, "captureRestoreSupported": captureRestoreSupported]
        }
    }

    // MARK: Local authority (host-local only; never decoded from a packet)

    /// Pinned identity, not a display name or self-reported platform.
    struct PeerIdentity: Equatable {
        var device: [UInt8]
        var keySHA256: [UInt8]

        var valid: Bool {
            device.count == 16 && keySHA256.count == 32 && device.contains { $0 != 0 } && keySHA256.contains { $0 != 0 }
        }
    }

    /// `transport` is a host-issued generation of an authenticated encrypted transport.
    struct Binding: Equatable {
        var peer: PeerIdentity
        var transport: UInt64
        /// Unique authenticated-transport transcript nonce, never reused after a process restart.
        var connection: [UInt8]
    }

    /// Fresh LOCAL state, supplied on every input and on every permission/grant/lifecycle event. The adapter
    /// advances `generation` whenever any authority, source or connection changes.
    struct Authority: Equatable {
        var generation: UInt64
        var binding: Binding
        var stream: UInt64
        var trustedDevice: Bool
        var viewGrant: Bool
        var controlGrant: Bool
        var captureReady: Bool
        /// Permission AND the selected native target's eligibility for the attempted operation.
        var inputReady: Bool
        var unlocked: Bool
        var streamActive: Bool
        var host: Capabilities
        var controller: Capabilities
    }

    // MARK: Geometry

    enum SourceKind: String, Equatable {
        case display, window
    }

    struct PixelPoint: Equatable {
        let x: UInt32
        let y: UInt32
    }

    struct Geometry: Equatable {
        var generation: UInt64
        var source: UInt64
        var kind: SourceKind
        var width: UInt32
        var height: UInt32

        var valid: Bool {
            validCounter(generation) && validCounter(source) && width > 0 && height > 0 && width <= maxDimension
                && height <= maxDimension && UInt64(width) * UInt64(height) <= maxPixels
        }

        /// Fractions of the captured FULL display, after the viewer excluded its letterbox.
        func pixel(_ x: Double, _ y: Double) -> PixelPoint? {
            guard valid, coordinate(x), coordinate(y) else { return nil }
            return PixelPoint(x: UInt32((x * Double(width - 1)).rounded(.toNearestOrAwayFromZero)),
                              y: UInt32((y * Double(height - 1)).rounded(.toNearestOrAwayFromZero)))
        }

        /// Strict, like the Rust decoder: exactly these five fields, integers, a known kind. Validity is separate.
        static func decode(_ value: Any?) -> Geometry? {
            guard let object = value as? [String: Any],
                  Set(object.keys) == ["generation", "source", "kind", "width", "height"],
                  let generation = JSONField.unsigned(object["generation"], max: UInt64.max),
                  let source = JSONField.unsigned(object["source"], max: UInt64.max),
                  let kindText = object["kind"] as? String, let kind = SourceKind(rawValue: kindText),
                  let width = JSONField.unsigned(object["width"], max: UInt64(UInt32.max)),
                  let height = JSONField.unsigned(object["height"], max: UInt64(UInt32.max)) else { return nil }
            return Geometry(generation: generation, source: source, kind: kind, width: UInt32(width), height: UInt32(height))
        }

        var json: [String: Any] {
            ["generation": Int(generation), "source": Int(source), "kind": kind.rawValue, "width": Int(width), "height": Int(height)]
        }
    }

    // MARK: Input

    enum Button: UInt8, CaseIterable, Equatable {
        case primary, secondary, middle

        var wire: String {
            switch self {
            case .primary: "primary"
            case .secondary: "secondary"
            case .middle: "middle"
            }
        }

        init?(wire: String) {
            guard let found = Self.allCases.first(where: { $0.wire == wire }) else { return nil }
            self = found
        }
    }

    enum Key: UInt8, CaseIterable, Equatable {
        case enter, tab, backspace, escape, left, right, up, down, home, end, pageUp, pageDown, delete, shift, control, alt, meta

        var wire: String {
            switch self {
            case .enter: "enter"
            case .tab: "tab"
            case .backspace: "backspace"
            case .escape: "escape"
            case .left: "left"
            case .right: "right"
            case .up: "up"
            case .down: "down"
            case .home: "home"
            case .end: "end"
            case .pageUp: "page_up"
            case .pageDown: "page_down"
            case .delete: "delete"
            case .shift: "shift"
            case .control: "control"
            case .alt: "alt"
            case .meta: "meta"
            }
        }

        init?(wire: String) {
            guard let found = Self.allCases.first(where: { $0.wire == wire }) else { return nil }
            self = found
        }
    }

    enum Navigation: String, Equatable {
        case back, home, recents
    }

    enum TouchPhase: String, Equatable {
        case down, move, up
    }

    enum Input: Equatable, CustomDebugStringConvertible, CustomStringConvertible {
        case geometryAck
        case pointer(x: Double, y: Double)
        case button(Button, down: Bool, x: Double, y: Double)
        case scroll(dx: Int32, dy: Int32, x: Double, y: Double)
        case key(Key, down: Bool)
        case text(String)
        case navigate(Navigation)
        case touch(contact: UInt8, phase: TouchPhase, x: Double, y: Double)
        case heartbeat
        case stop

        /// Debugging or logging a packet must not expose typed text, keys or positions.
        var debugDescription: String {
            switch self {
            case .geometryAck: "GeometryAck"
            case .pointer: "Pointer(..)"
            case .button: "Button(..)"
            case .scroll: "Scroll(..)"
            case .key: "Key(..)"
            case .text: "Text([redacted])"
            case .navigate: "Navigate(..)"
            case .touch: "Touch(..)"
            case .heartbeat: "Heartbeat"
            case .stop: "Stop"
            }
        }

        var description: String { debugDescription }

        var isMotion: Bool {
            switch self {
            case .pointer, .scroll: true
            case let .touch(_, phase, _, _): phase == .move
            default: false
            }
        }

        /// Exactly the fields of one operation (deny_unknown_fields): anything missing, extra or mistyped rejects.
        static func decode(_ value: Any?) -> Input? {
            guard let object = value as? [String: Any], let op = object["op"] as? String else { return nil }
            func fields(_ names: Set<String>) -> Bool { Set(object.keys) == names.union(["op"]) }
            switch op {
            case "geometry_ack":
                return fields([]) ? .geometryAck : nil
            case "heartbeat":
                return fields([]) ? .heartbeat : nil
            case "stop":
                return fields([]) ? .stop : nil
            case "pointer":
                guard fields(["x", "y"]), let x = JSONField.double(object["x"]), let y = JSONField.double(object["y"]) else { return nil }
                return .pointer(x: x, y: y)
            case "button":
                guard fields(["button", "down", "x", "y"]), let name = object["button"] as? String, let button = Button(wire: name),
                      let down = JSONField.bool(object["down"]), let x = JSONField.double(object["x"]),
                      let y = JSONField.double(object["y"]) else { return nil }
                return .button(button, down: down, x: x, y: y)
            case "scroll":
                guard fields(["dx", "dy", "x", "y"]), let dx = JSONField.int32(object["dx"]), let dy = JSONField.int32(object["dy"]),
                      let x = JSONField.double(object["x"]), let y = JSONField.double(object["y"]) else { return nil }
                return .scroll(dx: dx, dy: dy, x: x, y: y)
            case "key":
                guard fields(["key", "down"]), let name = object["key"] as? String, let key = Key(wire: name),
                      let down = JSONField.bool(object["down"]) else { return nil }
                return .key(key, down: down)
            case "text":
                guard fields(["text"]), let text = object["text"] as? String else { return nil }
                return .text(text)
            case "navigate":
                guard fields(["action"]), let name = object["action"] as? String, let action = Navigation(rawValue: name) else { return nil }
                return .navigate(action)
            case "touch":
                guard fields(["contact", "phase", "x", "y"]), let contact = JSONField.unsigned(object["contact"], max: UInt64(UInt8.max)),
                      let phaseName = object["phase"] as? String, let phase = TouchPhase(rawValue: phaseName),
                      let x = JSONField.double(object["x"]), let y = JSONField.double(object["y"]) else { return nil }
                return .touch(contact: UInt8(contact), phase: phase, x: x, y: y)
            default:
                return nil
            }
        }

        var json: [String: Any] {
            switch self {
            case .geometryAck: ["op": "geometry_ack"]
            case .heartbeat: ["op": "heartbeat"]
            case .stop: ["op": "stop"]
            case let .pointer(x, y): ["op": "pointer", "x": x, "y": y]
            case let .button(button, down, x, y): ["op": "button", "button": button.wire, "down": down, "x": x, "y": y]
            case let .scroll(dx, dy, x, y): ["op": "scroll", "dx": Int(dx), "dy": Int(dy), "x": x, "y": y]
            case let .key(key, down): ["op": "key", "key": key.wire, "down": down]
            case let .text(text): ["op": "text", "text": text]
            case let .navigate(action): ["op": "navigate", "action": action.rawValue]
            case let .touch(contact, phase, x, y): ["op": "touch", "contact": Int(contact), "phase": phase.rawValue, "x": x, "y": y]
            }
        }
    }

    struct Packet: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        var v: UInt8
        var session: UInt64
        var transport: UInt64
        var connection: [UInt8]
        var stream: UInt64
        var geometry: UInt64
        var seq: UInt64
        var input: Input

        static let fields: Set<String> = ["v", "session", "transport", "connection", "stream", "geometry", "seq", "input"]

        /// Never the typed text, keys or positions.
        var description: String { "Packet(session: \(session), stream: \(stream), geometry: \(geometry), seq: \(seq), input: \(input.debugDescription))" }
        var debugDescription: String { description }

        /// Bounds bytes BEFORE JSON allocates strings. Invalid JSON and unknown operations fail closed.
        static func decode(_ data: Data) -> Result<Packet, Rejection> {
            guard data.count <= maxPacketBytes else { return .failure(.packetSize) }
            guard isStrictJSONObject(data), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  Set(object.keys) == fields,
                  let v = JSONField.unsigned(object["v"], max: UInt64(UInt8.max)),
                  let session = JSONField.unsigned(object["session"], max: UInt64.max),
                  let transport = JSONField.unsigned(object["transport"], max: UInt64.max),
                  let connection = JSONField.bytes16(object["connection"]),
                  let stream = JSONField.unsigned(object["stream"], max: UInt64.max),
                  let geometry = JSONField.unsigned(object["geometry"], max: UInt64.max),
                  let seq = JSONField.unsigned(object["seq"], max: UInt64.max),
                  let input = Input.decode(object["input"]) else { return .failure(.malformed) }
            guard UInt8(v) == ScreenControl.version else { return .failure(.version) }
            guard [session, transport, stream, geometry, seq].allSatisfy(validCounter) else { return .failure(.counter) }
            guard connection.contains(where: { $0 != 0 }) else { return .failure(.binding) }
            return .success(Packet(v: UInt8(v), session: session, transport: transport, connection: connection, stream: stream,
                                   geometry: geometry, seq: seq, input: input))
        }

        var json: [String: Any] {
            ["v": Int(v), "session": Int(session), "transport": Int(transport), "connection": connection.map { Int($0) },
             "stream": Int(stream), "geometry": Int(geometry), "seq": Int(seq), "input": input.json]
        }

        func encoded() -> Data { (try? JSONSerialization.data(withJSONObject: json)) ?? Data() }
    }

    // MARK: Transitions

    struct HeldInput: Equatable {
        var buttons: UInt8 = 0
        var keys: UInt32 = 0
        var contacts: UInt16 = 0

        var isEmpty: Bool { self == HeldInput() }
        var heldButtons: [Button] { Button.allCases.filter { buttons & (1 << $0.rawValue) != 0 } }
        var heldKeys: [Key] { Key.allCases.filter { keys & (UInt32(1) << UInt32($0.rawValue)) != 0 } }
    }

    enum Rejection: Error, Equatable {
        case version, unsupported, identity, counter, grant, permission, locked, noStream, busy, authorityReplay, binding, session
        case replay, geometry, geometryNotAcknowledged, coordinates, invalidInput, rate, packetSize, malformed, clock, exhausted
    }

    enum StopReason: Equatable {
        case user, authorityChanged, permissionLost, revoked, locked, disconnected, timeout, sequenceGap, sourceChanged
        case geometryInvalid, rateLimited, invalidInput, clock, exhausted
    }

    enum Status: Equatable {
        case accepted
        case rejected(Rejection)
        case stopped(StopReason)
    }

    /// Native code must release every indicated button/key/contact, even on rejection or stop.
    struct Transition: Equatable {
        var status: Status
        var release: HeldInput

        static let accepted = Transition(status: .accepted, release: HeldInput())
        static func rejected(_ reason: Rejection) -> Transition { Transition(status: .rejected(reason), release: HeldInput()) }
    }

    struct SessionInfo: Equatable {
        var session: UInt64
        var transport: UInt64
        var connection: [UInt8]
        var stream: UInt64
        var geometry: Geometry
    }

    struct Bucket {
        var tokens: UInt64
        var updatedMs: UInt64
        let rate: UInt64

        init(rate: UInt64, nowMs: UInt64) {
            tokens = rate * 1_000
            updatedMs = nowMs
            self.rate = rate
        }

        mutating func take(_ nowMs: UInt64) -> Bool {
            // The caller rejects clock reversal first. Refill at most one capacity, avoiding overflow.
            let elapsed = nowMs >= updatedMs ? nowMs - updatedMs : 0
            tokens = min(tokens + min(elapsed, 1_000) * rate, rate * 1_000)
            updatedMs = nowMs
            guard tokens >= 1_000 else { return false }
            tokens -= 1_000
            return true
        }
    }

    private struct Active {
        var info: SessionInfo
        var authority: Authority
        var input: InputCapabilities
        var acknowledged = false
        var sequence: UInt64 = 0
        var lastValidMs: UInt64
        var lastClockMs: UInt64
        var held = HeldInput()
        var motion: Bucket
        var discrete: Bucket
        var control: Bucket
    }

    /// One selected controller per host reducer. Session IDs are host-issued and monotonic within the reducer's
    /// lifetime, never secret capabilities; authentication still comes from Binding.
    struct HostSession {
        private var highestAuthority: UInt64 = 0
        private var observedAuthority: Authority?
        private var blockedAuthority = false
        private var lastSession: UInt64 = 0
        private var active: Active?

        init() {}

        var info: SessionInfo? { active?.info }
        var held: HeldInput { active?.held ?? HeldInput() }
        var acknowledged: Bool { active?.acknowledged ?? false }
        var isActive: Bool { active != nil }

        /// Tests only: put the counters at their limits.
        mutating func testingSetLastSession(_ value: UInt64) { lastSession = value }
        mutating func testingSetSequence(_ value: UInt64) { active?.sequence = value }

        mutating func begin(_ authority: Authority, geometry: Geometry, nowMs: UInt64) -> Result<SessionInfo, Rejection> {
            guard active == nil else { return .failure(.busy) }
            let input: InputCapabilities
            switch checkAuthority(authority) {
            case let .failure(reason): return .failure(reason)
            case let .success(value): input = value
            }
            guard geometry.valid, geometry.kind == .display else { return .failure(.geometry) }
            guard lastSession < UInt64.max, validCounter(lastSession + 1) else { return .failure(.exhausted) }
            lastSession += 1
            let info = SessionInfo(session: lastSession, transport: authority.binding.transport, connection: authority.binding.connection,
                                   stream: authority.stream, geometry: geometry)
            active = Active(info: info, authority: authority, input: input, lastValidMs: nowMs, lastClockMs: nowMs,
                            motion: Bucket(rate: 120, nowMs: nowMs), discrete: Bucket(rate: 20, nowMs: nowMs),
                            control: Bucket(rate: 10, nowMs: nowMs))
            return .success(info)
        }

        /// Call immediately on grant/permission/connection/lock events, not just on incoming packets.
        mutating func synchronize(_ authority: Authority) -> Transition {
            let obsolete = validCounter(authority.generation) && authority.generation < highestAuthority
            let checked = checkAuthority(authority)
            guard let current = active else {
                switch checked {
                case .success: return .accepted
                case let .failure(reason): return .rejected(reason)
                }
            }
            if case let .failure(reason) = checked {
                // An old asynchronous native callback cannot tear down a newer valid session.
                if obsolete { return .rejected(reason) }
                return stop(ScreenControl.stopReason(for: reason))
            }
            if authority != current.authority { return stop(.authorityChanged) }
            return .accepted
        }

        /// New captured dimensions fence all input until an ordered ACK of the new generation. Replacing the
        /// selected source stops; it cannot silently retarget an existing controller.
        mutating func geometryChanged(expected: SessionInfo, geometry: Geometry) -> Transition {
            guard var current = active else { return .rejected(.noStream) }
            if expected.session != current.info.session || expected.transport != current.info.transport
                || expected.connection != current.info.connection || expected.stream != current.info.stream {
                return .rejected(.session)
            }
            if !geometry.valid { return stop(.geometryInvalid) }
            if geometry.generation == current.info.geometry.generation && geometry != current.info.geometry {
                return stop(.geometryInvalid)
            }
            if geometry.generation <= current.info.geometry.generation { return .rejected(.geometry) }
            if geometry.source != current.info.geometry.source || geometry.kind != .display { return stop(.sourceChanged) }
            let release = current.held
            current.held = HeldInput()
            current.info.geometry = geometry
            current.acknowledged = false
            active = current
            return Transition(status: .accepted, release: release)
        }

        /// Stop is never rate limited, and held state is returned exactly once.
        mutating func stop(_ reason: StopReason) -> Transition {
            let current = active
            active = nil
            // Also burn an observed authority whose asynchronous native begin is still pending. Persistent grants
            // remain; a genuinely new request gets a fresh local generation.
            blockedAuthority = true
            return Transition(status: .stopped(reason), release: current?.held ?? HeldInput())
        }

        mutating func tick(_ nowMs: UInt64) -> Transition {
            guard var current = active else { return .rejected(.noStream) }
            if nowMs < current.lastClockMs { return stop(.clock) }
            current.lastClockMs = nowMs
            active = current
            if nowMs - current.lastValidMs >= idleMillis { return stop(.timeout) }
            return .accepted
        }

        mutating func receive(_ authority: Authority, sender: Binding, packet: Packet, nowMs: UInt64) -> Transition {
            let authorityResult = synchronize(authority)
            guard authorityResult.status == .accepted else { return authorityResult }
            let timeResult = tick(nowMs)
            guard timeResult.status == .accepted else { return timeResult }
            guard var current = active else { return .rejected(.noStream) }
            if sender != current.authority.binding || packet.transport != sender.transport || packet.connection != sender.connection {
                return .rejected(.binding)
            }
            if packet.v != ScreenControl.version { return .rejected(.version) }
            if packet.session != current.info.session || packet.stream != current.info.stream { return .rejected(.session) }
            if !validCounter(packet.seq) { return .rejected(.counter) }
            if packet.seq <= current.sequence { return .rejected(.replay) }
            let next = current.sequence + 1
            guard validCounter(next) else { return stop(.exhausted) }
            if packet.seq != next { return stop(.sequenceGap) }
            // Consume an authenticated ordered header even if its payload is rejected. Invalid inputs do not refresh
            // idle liveness, and cannot be replayed later after permission/geometry changes.
            current.sequence = packet.seq
            active = current
            if packet.input == .stop { return stop(.user) }
            if packet.seq == maxSequence { return stop(.exhausted) }
            if packet.geometry != current.info.geometry.generation {
                if !current.held.isEmpty { return stop(.geometryInvalid) }
                return .rejected(.geometry)
            }
            if packet.input == .geometryAck || packet.input == .heartbeat {
                let allowed = current.control.take(nowMs)
                if allowed {
                    if packet.input == .geometryAck { current.acknowledged = true }
                    current.lastValidMs = nowMs
                }
                active = current
                return allowed ? .accepted : .rejected(.rate)
            }
            if !current.acknowledged { return .rejected(.geometryNotAcknowledged) }
            let motion = packet.input.isMotion
            if let reason = ScreenControl.validate(packet.input, capabilities: current.input, geometry: current.info.geometry,
                                                    held: current.held) {
                if !motion && !current.held.isEmpty { return stop(.invalidInput) }
                return .rejected(reason)
            }
            let allowed = motion ? current.motion.take(nowMs) : current.discrete.take(nowMs)
            active = current
            if !allowed {
                // Never silently drop a key/button/touch transition and leave a native hold stuck.
                if !motion { return stop(.rateLimited) }
                return .rejected(.rate)
            }
            switch packet.input {
            case let .button(button, down, _, _):
                let bit = UInt8(1) << button.rawValue
                current.held.buttons = down ? current.held.buttons | bit : current.held.buttons & ~bit
            case let .key(key, down):
                let bit = UInt32(1) << UInt32(key.rawValue)
                current.held.keys = down ? current.held.keys | bit : current.held.keys & ~bit
            case let .touch(contact, phase, _, _):
                let bit = UInt16(1) << UInt16(contact)
                switch phase {
                case .down: current.held.contacts |= bit
                case .up: current.held.contacts &= ~bit
                case .move: break
                }
            default:
                break
            }
            current.lastValidMs = nowMs
            active = current
            return .accepted
        }

        private mutating func checkAuthority(_ authority: Authority) -> Result<InputCapabilities, Rejection> {
            guard validCounter(authority.generation), validCounter(authority.binding.transport), validCounter(authority.stream) else {
                return .failure(.counter)
            }
            if authority.generation < highestAuthority { return .failure(.authorityReplay) }
            if authority.generation > highestAuthority {
                highestAuthority = authority.generation
                observedAuthority = authority
                blockedAuthority = false
            } else if blockedAuthority || observedAuthority != authority {
                // Reusing one local authority generation for different permission/grant state is invalid. Burn that
                // generation so an older enabled snapshot cannot restart it.
                blockedAuthority = true
                return .failure(.authorityReplay)
            }
            guard authority.binding.peer.valid, authority.trustedDevice else { return .failure(.identity) }
            guard authority.binding.connection.count == 16, authority.binding.connection.contains(where: { $0 != 0 }) else {
                return .failure(.binding)
            }
            guard authority.viewGrant, authority.controlGrant else { return .failure(.grant) }
            guard authority.unlocked else { return .failure(.locked) }
            guard authority.captureReady, authority.inputReady else { return .failure(.permission) }
            guard authority.streamActive else { return .failure(.noStream) }
            return Capabilities.negotiatedInput(host: authority.host, controller: authority.controller)
        }
    }

    static func stopReason(for rejection: Rejection) -> StopReason {
        switch rejection {
        case .grant, .identity: .revoked
        case .permission: .permissionLost
        case .locked: .locked
        case .noStream: .disconnected
        default: .authorityChanged
        }
    }

    static func coordinate(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 1 }

    static func validate(_ input: Input, capabilities: InputCapabilities, geometry: Geometry, held: HeldInput) -> Rejection? {
        switch input {
        case let .pointer(x, y):
            guard capabilities.pointer else { return .unsupported }
            if geometry.pixel(x, y) == nil { return .coordinates }
        case let .button(button, down, x, y):
            guard capabilities.pointer else { return .unsupported }
            if geometry.pixel(x, y) == nil { return .coordinates }
            if (held.buttons & (UInt8(1) << button.rawValue) != 0) == down { return .invalidInput }
        case let .scroll(dx, dy, x, y):
            guard capabilities.pointer else { return .unsupported }
            if geometry.pixel(x, y) == nil { return .coordinates }
            if !(-1_000...1_000).contains(dx) || !(-1_000...1_000).contains(dy) || (dx == 0 && dy == 0) { return .invalidInput }
        case let .key(key, down):
            guard capabilities.keys else { return .unsupported }
            if (held.keys & (UInt32(1) << UInt32(key.rawValue)) != 0) == down { return .invalidInput }
        case let .text(text):
            guard capabilities.text else { return .unsupported }
            if text.isEmpty || text.utf8.count > maxTextBytes || text.unicodeScalars.count > maxTextScalars
                || text.unicodeScalars.contains(where: isControl) {
                return .invalidInput
            }
        case .navigate:
            guard capabilities.navigation else { return .unsupported }
        case let .touch(contact, phase, x, y):
            guard capabilities.touch else { return .unsupported }
            if contact >= 10 || geometry.pixel(x, y) == nil { return .coordinates }
            let isHeld = held.contacts & (UInt16(1) << UInt16(contact)) != 0
            if (phase == .down) == isHeld { return .invalidInput }
        case .geometryAck, .heartbeat, .stop:
            break
        }
        return nil
    }

    /// Rust's `char::is_control`: the Cc category (U+0000 to U+001F and U+007F to U+009F).
    static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) }

    // MARK: Connection nonce

    /// `HMAC-SHA256(session key, "bridgey-screen-control-connection-v1" || 0x00 || sessionId)[0..16]`: unique per
    /// authenticated session because every session has a fresh key (docs/protocol.md, Mac screen to phone).
    static func connectionNonce(sessionKey: Data, sessionID: String) -> [UInt8] {
        var message = Data("bridgey-screen-control-connection-v1".utf8)
        message.append(0)
        message.append(Data(sessionID.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: sessionKey))
        return Array(Data(mac).prefix(16))
    }
}

/// Strict JSON field readers shared by the contract and the display.* codecs: booleans are only JSON true/false,
/// integers never fractions (1.0 included, as serde rejects them), doubles any finite number but a boolean.
enum JSONField {
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// The exact decimal digits of an integral JSON number; nil for fractions, booleans and anything else.
    private static func digits(_ value: Any?) -> String? {
        guard let number = value as? NSNumber, !(number is NSDecimalNumber), CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber) else { return nil }
        return number.stringValue
    }

    static func unsigned(_ value: Any?, max: UInt64) -> UInt64? {
        guard let text = digits(value), let parsed = UInt64(text), parsed <= max else { return nil }
        return parsed
    }

    static func int32(_ value: Any?) -> Int32? {
        guard let text = digits(value), let parsed = Int32(text) else { return nil }
        return parsed
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func bytes16(_ value: Any?) -> [UInt8]? {
        guard let array = value as? [Any], array.count == 16 else { return nil }
        var bytes: [UInt8] = []
        for element in array {
            guard let byte = unsigned(element, max: 255) else { return nil }
            bytes.append(UInt8(byte))
        }
        return bytes
    }
}
