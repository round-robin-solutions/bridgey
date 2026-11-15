import Foundation

let callMediaFeatureKey = "call_quiet_draft1"

struct CallMediaStatePacket: Equatable {
    let revision: Int
    let calls: [String]
    let uncertain: Bool
    init(revision: Int, calls: [String], uncertain: Bool = false) {
        self.revision = revision; self.calls = calls; self.uncertain = uncertain
    }
    var payload: [String: Any] { ["version": 1, "revision": revision, "calls": calls, "uncertain": uncertain] }

    static func decode(_ data: Data) -> CallMediaStatePacket? {
        guard let object = callMediaObject(data, limit: 2048, keys: ["version", "revision", "calls", "uncertain"]),
              let revision = callMediaRevision(object), let calls = object["calls"] as? [String],
              let uncertain = jsonBool(object["uncertain"]),
              calls.count <= 16, Set(calls).count == calls.count,
              calls.allSatisfy(callMediaWireID) else { return nil }
        return CallMediaStatePacket(revision: revision, calls: calls, uncertain: uncertain)
    }
}

struct CallMediaResultPacket: Equatable {
    let revision: Int
    let paused: Int
    let muted: Int
    let limited: Int
    let issues: [CallMediaIssue]
    var payload: [String: Any] {
        ["version": 1, "revision": revision, "paused": paused, "muted": muted,
         "limited": limited, "issues": issues.map(\.rawValue)]
    }

    static func decode(_ data: Data) -> CallMediaResultPacket? {
        guard let object = callMediaObject(data, limit: 1024,
                                          keys: ["version", "revision", "paused", "muted", "limited", "issues"]),
              let revision = callMediaRevision(object),
              let paused = jsonInteger(object["paused"]), (0...64).contains(paused),
              let muted = jsonInteger(object["muted"]), (0...64).contains(muted),
              let limited = jsonInteger(object["limited"]), (0...64).contains(limited),
              let values = object["issues"] as? [String], values.count <= 16, Set(values).count == values.count else { return nil }
        let issues = values.compactMap(CallMediaIssue.init(rawValue:))
        guard issues.count == values.count else { return nil }
        return CallMediaResultPacket(revision: revision, paused: paused, muted: muted, limited: limited, issues: issues)
    }

    init(revision: Int, paused: Int, muted: Int, limited: Int, issues: [CallMediaIssue]) {
        self.revision = revision; self.paused = paused; self.muted = muted; self.limited = limited; self.issues = issues
    }

    init(revision: Int, result: CallMediaResult) {
        self.init(revision: revision, paused: min(result.paused, 64), muted: min(result.muted, 64),
                  limited: min(result.issues.count, 64), issues: result.issues.sorted { $0.rawValue < $1.rawValue })
    }
}

private func callMediaRevision(_ object: [String: Any]) -> Int? {
    guard jsonInteger(object["version"]) == 1, let revision = jsonInteger(object["revision"]),
          (1...2_147_483_647).contains(revision) else { return nil }
    return revision
}

private func callMediaWireID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) || $0 == 0x2d || $0 == 0x5f
    }
}

/// This draft deliberately rejects duplicate top-level keys rather than accepting whichever
/// value Foundation happened to keep. The shared strict parser supplies the full JSON grammar.
private func callMediaObject(_ data: Data, limit: Int, keys: Set<String>) -> [String: Any]? {
    guard data.count <= limit, String(data: data, encoding: .utf8) != nil, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          Set(object.keys) == keys else { return nil }
    let bytes = [UInt8](data)
    var depth = 0
    var expectingKey = false
    var index = 0
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
    return seen == keys ? object : nil
}

/// Source identity is supplied by the authenticated session, never by a wire origin field.
struct CallMediaSources {
    struct Source {
        var sessionID: String
        var state: CallMediaStatePacket
        var renewedAt: TimeInterval
    }
    private(set) var sources: [String: Source] = [:]
    // Expiry removes evidence of an active call, not the session's revision high-water mark.
    private var revisions: [String: Source] = [:]
    static let lease: TimeInterval = 75

    var activeCalls: Set<String> {
        Set(sources.flatMap { peer, source in source.state.calls.map { peer + ":" + $0 } })
    }

    var hasUncertainty: Bool { sources.values.contains { $0.state.uncertain } }

    @discardableResult
    mutating func receive(_ state: CallMediaStatePacket, peerID: String, sessionID: String, now: TimeInterval) -> Bool {
        if let old = revisions[peerID], old.sessionID == sessionID {
            guard state.revision >= old.state.revision else { return false }
            if state.revision == old.state.revision,
               Set(state.calls) != Set(old.state.calls) || state.uncertain != old.state.uncertain { return false }
        }
        let received = Source(sessionID: sessionID, state: state, renewedAt: now)
        sources[peerID] = received
        revisions[peerID] = received
        return true
    }

    @discardableResult
    mutating func remove(_ peerID: String) -> Bool {
        revisions.removeValue(forKey: peerID)
        return sources.removeValue(forKey: peerID) != nil
    }

    @discardableResult
    mutating func expire(now: TimeInterval) -> Set<String> {
        let expired = Set(sources.filter { now - $0.value.renewedAt >= Self.lease }.keys)
        for peer in expired { sources.removeValue(forKey: peer) }
        return expired
    }
}
