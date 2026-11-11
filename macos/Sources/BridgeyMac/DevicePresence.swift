import AppKit
import Foundation

let devicePresenceFeatureKey = "device_presence_draft1"

enum DevicePresenceState: String, Codable, Equatable {
    case active, idle, locked, unknown
}

/// A coarse activity sample. No keys, application names or screen content are read or retained.
struct DevicePresenceSample: Equatable {
    let state: DevicePresenceState
    let idleSeconds: Int?
    static let unknown = DevicePresenceSample(state: .unknown, idleSeconds: nil)
    static let locked = DevicePresenceSample(state: .locked, idleSeconds: nil)

    static func available(idleSeconds: TimeInterval) -> DevicePresenceSample {
        guard idleSeconds.isFinite, idleSeconds >= 0 else { return .unknown }
        let seconds = Int(min(idleSeconds, 86_400))
        return DevicePresenceSample(state: seconds < 120 ? .active : .idle, idleSeconds: seconds)
    }
}

struct DevicePresencePacket: Equatable {
    static let maximumSequence = 9_007_199_254_740_991
    let sequence: Int
    let sample: DevicePresenceSample
    var payload: [String: Any] {
        var object: [String: Any] = ["version": 1, "sequence": sequence, "state": sample.state.rawValue]
        if let idle = sample.idleSeconds { object["idleSeconds"] = idle }
        return object
    }

    static func decode(_ data: Data) -> DevicePresencePacket? {
        guard data.count <= 512, let object = presenceJSONObject(data),
              jsonInteger(object["version"]) == 1,
              let sequence = jsonInteger(object["sequence"]), (1...maximumSequence).contains(sequence),
              let stateText = object["state"] as? String, let state = DevicePresenceState(rawValue: stateText) else { return nil }
        let sample: DevicePresenceSample
        switch state {
        case .active, .idle:
            guard Set(object.keys) == ["version", "sequence", "state", "idleSeconds"],
                  let idle = jsonInteger(object["idleSeconds"]), (0...86_400).contains(idle),
                  (state == .active ? idle < 120 : idle >= 120) else { return nil }
            sample = DevicePresenceSample(state: state, idleSeconds: idle)
        case .locked, .unknown:
            guard Set(object.keys) == ["version", "sequence", "state"] else { return nil }
            sample = DevicePresenceSample(state: state, idleSeconds: nil)
        }
        return DevicePresencePacket(sequence: sequence, sample: sample)
    }
}

struct DevicePresencePeer: Hashable {
    let deviceID: String
    let sessionID: String
}

/// Per-session sequencing and send coalescing, independent of AppKit and real clocks.
struct DevicePresencePublisher {
    struct Emission: Equatable {
        let peer: DevicePresencePeer
        let packet: DevicePresencePacket
    }
    private struct Memory {
        var previous: DevicePresenceSample
        var sentAt: TimeInterval
        var sampledAt: TimeInterval
    }
    private var peers: [DevicePresencePeer: Memory] = [:]
    // Keep sequence alone across an opt-out/opt-in in the same session; never restart at one
    // while the phone may still have that session's replay fence. No activity samples survive.
    private var sequences: [DevicePresencePeer: Int] = [:]
    private var sequenceOrder: [DevicePresencePeer] = []
    static let keepAlive: TimeInterval = 10

    mutating func reset() { peers.removeAll() }

    mutating func emissions(to subscribers: Set<DevicePresencePeer>, sample: DevicePresenceSample,
                            now: TimeInterval, force: Bool = false) -> [Emission] {
        peers = peers.filter { subscribers.contains($0.key) }
        guard now.isFinite else { return [] }
        var emissions: [Emission] = []
        for peer in subscribers.sorted(by: { ($0.deviceID, $0.sessionID) < ($1.deviceID, $1.sessionID) }) {
            let prior = peers[peer]
            // Compare inferred input time, not just a decreasing age. Continuous typing can
            // yield age zero on every poll and must still renew which Mac is most recent.
            let input = prior.flatMap { old in
                old.previous.idleSeconds.flatMap { before in
                    sample.idleSeconds.map { after in
                        Double(after) + 1 <= Double(before) + max(0, now - old.sampledAt)
                    }
                }
            } == true
            let stateChanged = prior?.previous.state != sample.state
            let due = prior.map { now < $0.sentAt || now - $0.sentAt >= Self.keepAlive } ?? true
            guard force || stateChanged || input || due else {
                if var old = prior { old.previous = sample; old.sampledAt = now; peers[peer] = old }
                continue
            }
            let sequence = (sequences[peer] ?? 0) + 1
            guard sequence <= DevicePresencePacket.maximumSequence else { continue }
            let replaced = Set(sequences.keys.filter { $0.deviceID == peer.deviceID && $0.sessionID != peer.sessionID })
            for old in replaced { sequences.removeValue(forKey: old) }
            sequenceOrder.removeAll { replaced.contains($0) }
            if sequences[peer] == nil { sequenceOrder.append(peer) }
            sequences[peer] = sequence
            while sequenceOrder.count > max(256, subscribers.count),
                  let oldest = sequenceOrder.firstIndex(where: { !subscribers.contains($0) }) {
                sequences.removeValue(forKey: sequenceOrder.remove(at: oldest))
            }
            peers[peer] = Memory(previous: sample, sentAt: now, sampledAt: now)
            emissions.append(Emission(peer: peer, packet: DevicePresencePacket(sequence: sequence, sample: sample)))
        }
        return emissions
    }
}

/// Polls only aggregate OS idle time, and only while a trusted peer subscribes. Lock and sleep
/// notifications invalidate the sample immediately; no global event tap or Accessibility grant.
@MainActor
final class DevicePresenceMonitor {
    var send: (DevicePresencePeer, DevicePresencePacket) -> Void = { _, _ in }
    var sample: () -> DevicePresenceSample = DevicePresenceMonitor.systemSample
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var subscribers = Set<DevicePresencePeer>()
    private var publisher = DevicePresencePublisher()
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    enum AvailabilityReason: Hashable { case screenLocked, displayAsleep, systemAsleep, sessionInactive }
    private var unavailableReasons = Set<AvailabilityReason>()

    var isRunning: Bool { timer != nil }

    func update(subscribers next: Set<DevicePresencePeer>) {
        guard next != subscribers else { return }
        subscribers = next
        if next.isEmpty {
            timer?.invalidate(); timer = nil
            for (center, token) in observers { center.removeObserver(token) }
            observers.removeAll()
            unavailableReasons.removeAll()
            publisher.reset()
            return
        }
        if timer == nil {
            observeAvailability()
            timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 0.5
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        tick(force: true)
    }

    func tick(force: Bool = false) {
        guard !subscribers.isEmpty else { return }
        let value = unavailableReasons.isEmpty ? sample() : DevicePresenceSample.locked
        for emission in publisher.emissions(to: subscribers, sample: value, now: clock(), force: force) {
            send(emission.peer, emission.packet)
        }
    }

    func availabilityChanged(_ reason: AvailabilityReason, unavailable: Bool) {
        if unavailable { unavailableReasons.insert(reason) } else { unavailableReasons.remove(reason) }
        tick(force: true)
    }

    private func observeAvailability() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let states: [(NotificationCenter, Notification.Name, AvailabilityReason, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, .systemAsleep, true),
            (workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep, true),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked, true),
            (workspace, NSWorkspace.didWakeNotification, .systemAsleep, false),
            (workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep, false),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenLocked, false),
        ]
        for (center, name, reason, unavailable) in states {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.availabilityChanged(reason, unavailable: unavailable)
                }
            }
            observers.append((center, token))
        }
    }

    nonisolated static func systemSample() -> DevicePresenceSample {
        sessionSample(CGSessionCopyCurrentDictionary() as? [String: Any],
                      displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                      idleSeconds: macIdleSeconds())
    }

    /// Session dictionaries use state-dependent keys. Match the existing Mac convention for
    /// the optional screen-lock key, but only after proving this is a completed console login.
    /// A missing/malformed session is unknown, never implicitly active. Lock/sleep observers
    /// additionally override this sample until an availability event permits a fresh query.
    nonisolated static func sessionSample(_ session: [String: Any]?, displayAsleep: Bool,
                              idleSeconds: TimeInterval) -> DevicePresenceSample {
        guard let session,
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool else { return .unknown }
        guard onConsole, loginDone, !displayAsleep else { return .locked }
        if let raw = session["CGSSessionScreenIsLocked"] {
            guard let locked = raw as? Bool else { return .unknown }
            if locked { return .locked }
        }
        return .available(idleSeconds: idleSeconds)
    }
}

func presenceJSONObject(_ data: Data) -> [String: Any]? {
    guard String(data: data, encoding: .utf8) != nil, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let bytes = [UInt8](data)
    var depth = 0, index = 0
    var expectingKey = false
    var seen = Set<String>()
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x22 {
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x5c { index += 2; continue }
                if bytes[index] == 0x22 { break }
                index += 1
            }
            guard index < bytes.count else { return nil }
            if depth == 1 && expectingKey {
                let token = Data(bytes[start...index])
                guard let key = (try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed)) as? String,
                      seen.insert(key).inserted else { return nil }
                expectingKey = false
            }
        } else if byte == 0x7b || byte == 0x5b {
            depth += 1
            if depth == 1 { expectingKey = true }
        } else if byte == 0x7d || byte == 0x5d { depth -= 1 }
        else if byte == 0x2c && depth == 1 { expectingKey = true }
        index += 1
    }
    return seen == Set(object.keys) ? object : nil
}
