import Foundation

/*
 * Update all devices automatically (Round Robin edition). With the setting on, a device that finds
 * a newer build on its own channel runs Update all by itself: connected devices first, this one last.
 * It waits while the person is busy on any device, lets only one device start when several find the
 * same build, and puts its own restart off with Later (three times, then only when the Mac is idle).
 * Everything here is pure (clock injected) so the rules are unit tested; AutoUpdateCoordinator wires
 * it to Sparkle, the session and the activity stream. Android has the same rules in AutoUpdate.kt.
 */

enum AutoUpdateRules {
    /// How often a device checks its channel with the setting on: Beta and Nightly.
    static let fastCheck: TimeInterval = 30 * 60
    /// Stable, with the setting on.
    static let stableCheck: TimeInterval = 6 * 3600
    /// Wake and network changes check too, at most this often (counting every other check).
    static let eventCheckGap: TimeInterval = 10 * 60
    /// While someone is busy, look again this often.
    static let recheck: TimeInterval = 5 * 60
    /// This device's own restart in an automatic run waits this long, with Later.
    static let countdown: TimeInterval = 60
    /// Later puts the automatic restart off this long.
    static let laterDelay: TimeInterval = 60 * 60
    /// After this many Laters for one build, it waits until the Mac is idle or locked.
    static let maxLater = 3
    /// The Mac counts as idle after this long without keyboard or mouse input.
    static let idleAfter: TimeInterval = 5 * 60
    /// A device that leaves the run to a lower device ID starts its own after this long.
    static let yieldTimeout: TimeInterval = 15 * 60
    /// The notice at the start of an automatic run goes by itself after this long.
    static let noticeSeconds: TimeInterval = 12
    /// "Started automatically by ..." on a device another one updates, this long.
    static let startedBySeconds: TimeInterval = 10
    /// After accepting another device's start, this device does not start its own run for this long.
    static let peerRequestWindow: TimeInterval = 10 * 60
    /// After an automatic run for a build ends, the next one for that build waits this long (a device that
    /// did not answer or refused keeps reporting the build, and must not be asked again every few seconds).
    static let retryAfter: TimeInterval = 60 * 60

    /// Right after launch the rules wait this long for paired devices to reconnect, so a run that starts
    /// at launch does not leave them out as "not connected".
    static let launchSettle: TimeInterval = 60

    /// Just launched, and a paired device has not reconnected and sent its update status yet.
    static func settling(launchedAt: Date, now: Date, paired: [String], ready: Set<String>) -> Bool {
        guard now >= launchedAt, now.timeIntervalSince(launchedAt) < launchSettle else { return false }
        return paired.contains { !ready.contains($0) }
    }

    /// On by default for Beta and Nightly, off for Stable.
    static func defaultOn(_ channel: UpdateChannel) -> Bool { channel != .stable }

    /// The setting: the person's own choice when they made one, otherwise the channel's default.
    static func enabled(stored: Bool?, channel: UpdateChannel) -> Bool { stored ?? defaultOn(channel) }

    /// How often this Mac checks: every 30 minutes on Beta and Nightly and every 6 hours on Stable with
    /// the setting on; nil leaves it to Sparkle's own daily schedule.
    static func checkInterval(enabled: Bool, channel: UpdateChannel) -> TimeInterval? {
        guard enabled else { return nil }
        return channel == .stable ? stableCheck : fastCheck
    }

    static func checkDue(lastCheck: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now < lastCheck || now.timeIntervalSince(lastCheck) >= interval
    }

    /// Wake or a network change: check unless any check (scheduled or not) ran in the last 10 minutes.
    static func eventCheckAllowed(lastCheck: Date?, lastEventCheck: Date?, now: Date) -> Bool {
        let last = [lastCheck, lastEventCheck].compactMap { $0 }.max()
        guard let last else { return true }
        return now < last || now.timeIntervalSince(last) >= eventCheckGap
    }
}

/// A connected device that supports Update all, as the automatic run sees it.
struct AutoPeer: Equatable {
    let id: String
    let name: String
    let status: PeerUpdateStatus
}

/// What the decision depends on, read fresh each time.
struct AutoFacts: Equatable {
    var now: Date
    /// Update all devices automatically is on here (and Sparkle checks automatically).
    var enabled: Bool
    /// This device's own device ID: the lowest ID among devices with the setting on starts the run.
    var localID: String
    var localName: String
    /// This device's own `updates.status`.
    var local: PeerUpdateStatus
    /// What the person is doing on this device.
    var localBusy: UpdateBusy?
    var peers: [AutoPeer]
    /// An Update all run is going here.
    var runActive: Bool
    /// This device is updating because another device asked.
    var updatingForPeer: Bool
    /// The Mac is idle (no input for 5 minutes), locked, or its display sleeps.
    var idle: Bool
    /// `--update-all` is deciding: its own check may find the build, and it starts the run itself.
    var commandLine = false
}

/// What the automatic run remembers between decisions (stored, so a relaunch keeps Later and the waits).
struct AutoMemory: Codable, Equatable {
    /// The build the Laters, the wait and the yield belong to. A newer build starts afresh.
    var targetBuild: Int?
    /// When this device first knew of `targetBuild`: devices that reported "up to date" before that
    /// are asked to check again.
    var foundAt: Date?
    var laterCount = 0
    var laterUntil: Date?
    var yieldingSince: Date?
    /// When the last automatic run for `targetBuild` ended.
    var ranAt: Date?
    /// While someone is busy: the next look, and what was logged for this wait.
    var waitUntil: Date?
    var waiting: UpdateBusy?
    var waitingDevice: String?

    /// The person chose Later on the automatic notice: the restart waits an hour, and after three
    /// Laters only until the Mac is idle.
    mutating func later(now: Date) {
        laterCount += 1
        laterUntil = now.addingTimeInterval(AutoUpdateRules.laterDelay)
    }

    /// The memory for `target`: this one, or a fresh one when it belongs to another build.
    func forTarget(_ target: Int, now: Date) -> AutoMemory {
        targetBuild == target ? self : AutoMemory(targetBuild: target, foundAt: now)
    }

    /// A run (automatic or clicked) for `targetBuild` ended: the next automatic one waits an hour.
    mutating func ran(now: Date) {
        guard targetBuild != nil else { return }
        ranAt = now
    }
}

enum AutoDecision: Equatable {
    /// The setting is off.
    case off
    case nothingToDo
    /// A run is going here, or this device updates because another one asked.
    case running
    /// Start Update all now. Peers that last reported "up to date" before `refreshBefore` are asked to check.
    case start(targetBuild: Int, refreshBefore: Date)
    /// Someone is busy: look again at `until`. `device` is nil for this device.
    case wait(UpdateBusy, device: String?, until: Date)
    /// The person chose Later.
    case later(until: Date)
    /// Later three times: only when the Mac is idle or locked.
    case waitForIdle
    /// A device with a lower ID and the setting on runs it. This device starts its own after `until`.
    case yield(to: String, until: Date)
    /// A run for this build ended a short while ago; the next one waits until `until`.
    case retry(until: Date)
    /// The last attempt here did not apply; nothing tries that build again on its own.
    case notApplied
}

/// One decision, the memory to keep, and what the activity stream gets this time.
struct AutoStep: Equatable {
    enum Log: Equatable {
        /// "Waiting: call in progress" (device nil: on this device).
        case waiting(UpdateBusy, device: String?)
    }

    var decision: AutoDecision
    var memory: AutoMemory
    var log: Log?
}

enum AutoUpdatePolicy {
    private static let hasUpdate: Set<PeerUpdateState> = [.available, .downloading, .ready]

    /// The build this device has on offer for itself, if any. A version that did not apply is never
    /// tried again on its own.
    static func localTarget(_ status: PeerUpdateStatus) -> Int? {
        guard hasUpdate.contains(status.state), status.target != nil, let build = status.targetBuild, build > status.build else { return nil }
        return build
    }

    /// A peer's own update this device runs for it: only peers that have the setting on themselves
    /// (they wait for the lowest ID), can be started from here, and have a newer build on offer.
    static func peerTarget(_ peer: AutoPeer) -> Int? {
        let status = peer.status
        guard status.auto, status.remoteStart, hasUpdate.contains(status.state), status.target != nil,
              let build = status.targetBuild, build > status.build else { return nil }
        return build
    }

    /// The newest build the automatic rules would run for: this device's own, or a peer's that waits for it.
    static func target(_ facts: AutoFacts) -> Int? {
        ([localTarget(facts.local)] + facts.peers.map(peerTarget)).compactMap { $0 }.max()
    }

    /// The lowest device ID among this device and the connected peers with the setting on starts the run.
    static func leader(localID: String, peers: [AutoPeer]) -> AutoPeer? {
        let mine = localID.lowercased()
        return peers.filter { $0.status.auto && $0.id.lowercased() < mine }.min { $0.id.lowercased() < $1.id.lowercased() }
    }

    /// The most important busy activity on any device, and where (nil: this device).
    static func busy(_ facts: AutoFacts) -> (UpdateBusy, String?)? {
        var all: [(UpdateBusy, String?)] = []
        if let mine = facts.localBusy { all.append((mine, nil)) }
        for peer in facts.peers { if let theirs = peer.status.busy { all.append((theirs, peer.name)) } }
        return UpdateBusy.order.lazy.compactMap { kind in all.first { $0.0 == kind } }.first
    }

    static func decide(_ facts: AutoFacts, memory: AutoMemory) -> AutoStep {
        let now = facts.now
        guard facts.enabled else { return AutoStep(decision: .off, memory: AutoMemory()) }
        if facts.runActive || facts.updatingForPeer { return AutoStep(decision: .running, memory: memory) }
        // The command line's check finding a build must not start a second run under it (it would answer
        // "blocked: run_active" while its own update went ahead).
        if facts.commandLine { return AutoStep(decision: .running, memory: memory) }
        let mine = localTarget(facts.local)
        guard let target = target(facts) else {
            let didNotApply = facts.local.state == .failed && facts.local.reason == .notApplied
            return AutoStep(decision: didNotApply ? .notApplied : .nothingToDo, memory: AutoMemory())
        }
        var next = memory.forTarget(target, now: now)
        // Waiting for someone: look again only every few minutes, even if they finished sooner.
        if let until = next.waitUntil, now < until, let waiting = next.waiting {
            return AutoStep(decision: .wait(waiting, device: next.waitingDevice, until: until), memory: next)
        }
        if let found = busy(facts) {
            let (kind, device) = found
            let changed = next.waiting != kind || next.waitingDevice != device
            next.waitUntil = now.addingTimeInterval(AutoUpdateRules.recheck)
            next.waiting = kind
            next.waitingDevice = device
            return AutoStep(decision: .wait(kind, device: device, until: next.waitUntil!), memory: next,
                            log: changed ? .waiting(kind, device: device) : nil)
        }
        next.waitUntil = nil
        next.waiting = nil
        next.waitingDevice = nil
        if let until = next.laterUntil, now < until { return AutoStep(decision: .later(until: until), memory: next) }
        if next.laterCount >= AutoUpdateRules.maxLater, !facts.idle { return AutoStep(decision: .waitForIdle, memory: next) }
        if let leader = leader(localID: facts.localID, peers: facts.peers) {
            let since = next.yieldingSince ?? now
            next.yieldingSince = since
            let until = since.addingTimeInterval(AutoUpdateRules.yieldTimeout)
            // Only this device's own update may go ahead without the leader, and only after the wait.
            if mine == nil || now < until { return AutoStep(decision: .yield(to: leader.name, until: until), memory: next) }
        }
        next.yieldingSince = nil
        if let ran = next.ranAt, now >= ran, now.timeIntervalSince(ran) < AutoUpdateRules.retryAfter {
            return AutoStep(decision: .retry(until: ran.addingTimeInterval(AutoUpdateRules.retryAfter)), memory: next)
        }
        return AutoStep(decision: .start(targetBuild: target, refreshBefore: next.foundAt ?? now), memory: next)
    }

    /// The command line (`--update-all`) skips the setting, Later and the lowest-ID rule, but never
    /// starts over a run, an update another device started, or someone busy.
    enum Blocked: Equatable {
        case runActive
        case updatingForPeer
        case busy(UpdateBusy, device: String?)
    }

    static func commandLineBlocked(_ facts: AutoFacts) -> Blocked? {
        if facts.runActive { return .runActive }
        if facts.updatingForPeer { return .updatingForPeer }
        if let found = busy(facts) { return .busy(found.0, device: found.1) }
        return nil
    }
}

/// What a device that was asked to update itself (`updates.start`) does with an automatic start.
enum AutoStartRule {
    /// An automatic start finds the person busy here: refuse `busy`. A start someone clicked goes ahead.
    static func refusesBusy(_ request: UpdateStartRequest, localBusy: UpdateBusy?) -> Bool { request.auto && localBusy != nil }
}
