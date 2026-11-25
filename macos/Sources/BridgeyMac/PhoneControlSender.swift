import Foundation

/// What the window asks the phone to do, before it is numbered. Positions are fractions of the phone's full stream.
enum PhoneControlAction: Equatable {
    case touch(contact: UInt8, phase: ScreenControl.TouchPhase, x: Double, y: Double)
    /// Stream pixels the content moves, positive right and down (the content follows the fingers).
    case scroll(dx: Int, dy: Int, x: Double, y: Double)
    case navigate(ScreenControl.Navigation)
    case text(String)
    case key(ScreenControl.Key, down: Bool)
}

/*
 * This Mac's side of one phone control session (docs/protocol.md, "Mac controls the phone"): it owns the binding
 * (session, transport, connection, stream), the acknowledged geometry and the packet sequence. Packets are numbered only
 * when they go: each finger's motion and scrolling are coalesced first, touch, key, text and navigation transitions stay
 * in order and are never dropped once numbered, consecutive text is joined, and every class keeps a little under the
 * phone's budgets (120 motion, 20 discrete, 10 control a second). geometry_ack goes first and after every geometry
 * change, which also drops everything not yet sent. Stop is never rate limited. Main actor only.
 */
final class PhoneControlSender {
    struct Rates {
        var motion = 100
        var discrete = 16
        var control = 8
    }

    struct Binding: Equatable {
        let transport: UInt64
        let connection: [UInt8]
        let stream: UInt64
    }

    private enum Entry: Equatable {
        case move(contact: UInt8, x: Double, y: Double)
        case scroll(dx: Int, dy: Int, x: Double, y: Double)
        case discrete(ScreenControl.Input)
    }

    private struct Bucket {
        let rate: Int
        var tokens: Int
        var updated: UInt64

        init(rate: Int, now: UInt64) {
            self.rate = rate
            tokens = rate * 1_000
            updated = now
        }

        mutating func take(_ now: UInt64) -> Bool {
            let elapsed = now >= updated ? min(now - updated, 1_000) : 0
            tokens = min(rate * 1_000, tokens + Int(elapsed) * rate)
            updated = max(updated, now)
            guard tokens >= 1_000 else { return false }
            tokens -= 1_000
            return true
        }
    }

    static let maxQueue = 64
    static let heartbeatMs: UInt64 = 2_000

    private let clock: () -> UInt64
    private let rates: Rates
    private var session: UInt64 = 0
    private var binding: Binding?
    private(set) var geometry: UInt64 = 0
    private(set) var input = ScreenControl.InputCapabilities()
    private var sequence: UInt64 = 0
    private var queue: [Entry] = []
    private var motion: Bucket
    private var discrete: Bucket
    private var control: Bucket
    private var lastHeartbeat: UInt64 = 0
    private var heldContacts: Set<UInt8> = []
    private var heldKeys: Set<ScreenControl.Key> = []
    /// Refused here: unsupported, invalid, an unmatched transition or a full queue.
    private(set) var dropped = 0

    init(clock: @escaping () -> UInt64, rates: Rates = Rates()) {
        self.clock = clock
        self.rates = rates
        motion = Bucket(rate: rates.motion, now: 0)
        discrete = Bucket(rate: rates.discrete, now: 0)
        control = Bucket(rate: rates.control, now: 0)
    }

    var active: Bool { binding != nil }
    var pending: Int { queue.count }

    /// The phone answered `active`: a new session, starting with geometry_ack for `geometryGeneration`.
    func begin(session: UInt64, input: ScreenControl.InputCapabilities, binding: Binding, geometryGeneration: UInt64) -> [ScreenControl.Packet] {
        clear()
        guard ScreenControl.validCounter(session), ScreenControl.validCounter(geometryGeneration), ScreenControl.validCounter(binding.transport),
              ScreenControl.validCounter(binding.stream), binding.connection.count == 16, binding.connection.contains(where: { $0 != 0 }) else { return [] }
        let now = clock()
        self.session = session
        self.binding = binding
        self.input = input
        geometry = geometryGeneration
        sequence = 0
        motion = Bucket(rate: rates.motion, now: now)
        discrete = Bucket(rate: rates.discrete, now: now)
        control = Bucket(rate: rates.control, now: now)
        lastHeartbeat = now
        return packet(.geometryAck).map { [$0] } ?? []
    }

    /// A new geometry generation: everything not sent yet is dropped (the phone already lifted its fingers) and the new
    /// generation is acknowledged before anything else goes.
    func geometryChanged(_ generation: UInt64) -> [ScreenControl.Packet] {
        guard binding != nil, generation > geometry else { return [] }
        queue.removeAll()
        heldContacts.removeAll()
        heldKeys.removeAll()
        geometry = generation
        lastHeartbeat = clock()
        return packet(.geometryAck).map { [$0] } ?? []
    }

    /// Queues one action; false when there is no session or it was refused. Nothing is numbered until `flush`.
    @discardableResult
    func submit(_ action: PhoneControlAction) -> Bool {
        guard binding != nil else { return false }
        let accepted: Bool
        switch action {
        case let .touch(contact, phase, x, y):
            accepted = input.touch && contact < 10 && valid(x, y) && touch(contact, phase, x, y)
        case let .scroll(dx, dy, x, y):
            accepted = input.pointer && valid(x, y) && (dx != 0 || dy != 0) && scroll(dx, dy, x, y)
        case let .navigate(action):
            accepted = input.navigation && queue.count < Self.maxQueue && append(.discrete(.navigate(action)))
        case let .text(text):
            accepted = input.text && self.text(text)
        case let .key(key, down):
            accepted = input.keys && Self.sendableKeys.contains(key) && self.key(key, down)
        }
        if !accepted { dropped += 1 }
        return accepted
    }

    /// One press and release of `key`, with Shift around it when asked.
    @discardableResult
    func press(_ key: ScreenControl.Key, shift: Bool = false) -> Bool {
        guard binding != nil, input.keys else { return false }
        if shift, !submit(.key(.shift, down: true)) { return false }
        let down = submit(.key(key, down: true))
        if down { submit(.key(key, down: false)) }
        if shift { submit(.key(.shift, down: false)) }
        return down
    }

    /// The packets that may go now, numbered in order; a heartbeat every 2 seconds.
    func flush() -> [ScreenControl.Packet] {
        guard binding != nil else { return [] }
        let now = clock()
        var out: [ScreenControl.Packet] = []
        while let head = queue.first {
            let allowed: Bool
            switch head {
            case .discrete: allowed = discrete.take(now)
            case .move, .scroll: allowed = motion.take(now)
            }
            guard allowed else { break }
            let next: ScreenControl.Input
            switch head {
            case let .move(contact, x, y):
                queue.removeFirst()
                next = .touch(contact: contact, phase: .move, x: x, y: y)
            case let .discrete(input):
                queue.removeFirst()
                next = input
            case let .scroll(dx, dy, x, y):
                // Within the contract's bounds per packet; the rest stays at the head for the next one.
                let sx = max(-1_000, min(1_000, dx))
                let sy = max(-1_000, min(1_000, dy))
                if dx - sx == 0 && dy - sy == 0 {
                    queue.removeFirst()
                } else {
                    queue[0] = .scroll(dx: dx - sx, dy: dy - sy, x: x, y: y)
                }
                if sx == 0 && sy == 0 { continue }
                next = .scroll(dx: Int32(sx), dy: Int32(sy), x: x, y: y)
            }
            guard let numbered = packet(next) else { return out }
            out.append(numbered)
        }
        if now - lastHeartbeat >= Self.heartbeatMs, control.take(now) {
            lastHeartbeat = now
            if let beat = packet(.heartbeat) { out.append(beat) }
        }
        return out
    }

    /// The person ended control: the stop packet (never rate limited), then nothing more.
    func stop() -> ScreenControl.Packet? {
        guard binding != nil else { return nil }
        let stop = packet(.stop)
        clear()
        return stop
    }

    /// Control ended elsewhere (the phone, the stream, a disconnect): pending input is dropped.
    func end() { clear() }

    /// The contacts held down now (the window lifts them when it loses the mouse).
    var contactsDown: Set<UInt8> { heldContacts }

    // MARK: Private

    private func touch(_ contact: UInt8, _ phase: ScreenControl.TouchPhase, _ x: Double, _ y: Double) -> Bool {
        let held = heldContacts.contains(contact)
        switch phase {
        case .down:
            guard !held, queue.count < Self.maxQueue else { return false }
            heldContacts.insert(contact)
            return append(.discrete(.touch(contact: contact, phase: .down, x: x, y: y)))
        case .up:
            guard held else { return false }
            heldContacts.remove(contact)
            // An up is always queued: dropping it would leave the phone's finger down.
            queue.append(.discrete(.touch(contact: contact, phase: .up, x: x, y: y)))
            return true
        case .move:
            guard held else { return false }
            // The newest position of this finger replaces an older one not sent yet, unless a transition is between them.
            for index in queue.indices.reversed() {
                switch queue[index] {
                case .discrete: break
                case let .move(other, _, _) where other == contact:
                    queue[index] = .move(contact: contact, x: x, y: y)
                    return true
                default: continue
                }
                break
            }
            guard queue.count < Self.maxQueue else { return false }
            queue.append(.move(contact: contact, x: x, y: y))
            return true
        }
    }

    private func scroll(_ dx: Int, _ dy: Int, _ x: Double, _ y: Double) -> Bool {
        if case let .scroll(ox, oy, _, _) = queue.last {
            queue[queue.count - 1] = .scroll(dx: ox + dx, dy: oy + dy, x: x, y: y)
            return true
        }
        guard queue.count < Self.maxQueue else { return false }
        queue.append(.scroll(dx: dx, dy: dy, x: x, y: y))
        return true
    }

    private func text(_ text: String) -> Bool {
        guard ScreenControl.validText(text) else { return false }
        // Fast typing joins into one packet, so it stays within the discrete budget.
        if case let .discrete(.text(previous)) = queue.last, ScreenControl.validText(previous + text) {
            queue[queue.count - 1] = .discrete(.text(previous + text))
            return true
        }
        guard queue.count < Self.maxQueue else { return false }
        queue.append(.discrete(.text(text)))
        return true
    }

    private func key(_ key: ScreenControl.Key, _ down: Bool) -> Bool {
        let held = heldKeys.contains(key)
        guard held != down else { return false }
        if down {
            guard queue.count < Self.maxQueue else { return false }
            heldKeys.insert(key)
        } else {
            heldKeys.remove(key)
        }
        queue.append(.discrete(.key(key, down: down)))
        return true
    }

    private func append(_ entry: Entry) -> Bool {
        queue.append(entry)
        return true
    }

    private func packet(_ input: ScreenControl.Input) -> ScreenControl.Packet? {
        guard let binding else { return nil }
        guard sequence < ScreenControl.maxSequence else {
            // Exhausted: the session stops rather than wrapping.
            clear()
            return nil
        }
        sequence += 1
        return ScreenControl.Packet(v: ScreenControl.version, session: session, transport: binding.transport, connection: binding.connection,
                                    stream: binding.stream, geometry: geometry, seq: sequence, input: input)
    }

    private func clear() {
        binding = nil
        session = 0
        geometry = 0
        sequence = 0
        input = ScreenControl.InputCapabilities()
        queue.removeAll()
        heldContacts.removeAll()
        heldKeys.removeAll()
    }

    private func valid(_ x: Double, _ y: Double) -> Bool { ScreenControl.coordinate(x) && ScreenControl.coordinate(y) }

    /// The phone takes the named keys and Shift; Control, Option and Command never go (they would end control).
    static let sendableKeys: Set<ScreenControl.Key> = Set(ScreenControl.Key.allCases).subtracting([.control, .alt, .meta])
}

extension ScreenControl {
    /// Typed text the host accepts: 1 to 256 scalars, at most 1,024 UTF-8 bytes, no control characters.
    static func validText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maxTextBytes && text.unicodeScalars.count <= maxTextScalars && !text.unicodeScalars.contains(where: isControl)
    }
}
