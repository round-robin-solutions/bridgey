import Foundation

/*
 * Update all, the side that runs it (T3 Code's "update everything", for Bridgey). Macs are not paired
 * to each other, so "all" means every phone connected to this Mac, plus this Mac. Phones update first,
 * all at once; this Mac downloads meanwhile and restarts last, after a short countdown with Later.
 * Everything here is pure (clock and IDs injected) so the rules are unit tested; UpdateAllCoordinator
 * wires it to the session and to Sparkle. Android has the same rules in UpdateAll.kt.
 */

// MARK: - Plan

/// Why a device is left out of Update all.
enum UpdateSkipReason: String, Codable, Equatable {
    /// Paired but not connected now.
    case offline
    /// Upstream Bridgey, an older edition build, or a build that cannot update itself.
    case byHand
    /// Connected and supports Update all, but has not sent its version yet.
    case noStatus
    /// Its last update did not apply; it is never tried again on its own.
    case notApplied
    /// Its "Let paired devices start updates" switch is off.
    case remoteOff
}

/// One device as Update all sees it.
struct UpdateAllPhone: Equatable {
    let id: String
    let name: String
    let connected: Bool
    /// The phone advertised `updates_draft1` (this Mac always does).
    let supportsUpdates: Bool
    let status: PeerUpdateStatus?
}

struct UpdatePlanEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        /// `to` nil: the newest build of its channel, if there is a newer one (its last check is old).
        case update(to: String?, toBuild: Int?)
        case upToDate
        case skipped(UpdateSkipReason)
    }

    let id: String
    let name: String
    let isLocal: Bool
    let app: String?
    let build: Int?
    let channel: UpdateChannel?
    let kind: Kind

    var isTarget: Bool {
        if case .update = kind { return true }
        return false
    }

    var knownTarget: String? {
        if case let .update(to, _) = kind { return to }
        return nil
    }
}

struct UpdatePlan: Equatable {
    static let localID = "this-mac"
    /// A phone's "up to date" counts only this long after its own check; older, Update all asks it to check.
    static let staleAfter: TimeInterval = 3600

    /// Phones by name, then this Mac.
    var entries: [UpdatePlanEntry] = []

    var targets: [UpdatePlanEntry] { entries.filter(\.isTarget) }
    var phoneTargets: [UpdatePlanEntry] { targets.filter { !$0.isLocal } }
    var includesLocal: Bool { targets.contains(where: \.isLocal) }
    var skipped: [UpdatePlanEntry] { entries.filter { if case .skipped = $0.kind { return true } else { return false } } }
    var upToDate: [UpdatePlanEntry] { entries.filter { $0.kind == .upToDate } }
    /// Update all shows when at least one device has a known update.
    var visible: Bool { targets.contains { $0.knownTarget != nil } }
    /// The devices it would update are on more than one channel; each stays on its own.
    var channelsDiffer: Bool { Set(targets.compactMap(\.channel)).count > 1 }

    /// `refreshBefore` (automatic and command-line runs): a phone that reported "up to date" from a check
    /// older than this is asked to check again, because this device has just found a newer build.
    static func make(local: PeerUpdateStatus, localName: String, phones: [UpdateAllPhone], now: Date, refreshBefore: Date? = nil) -> UpdatePlan {
        let sorted = phones.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var entries = sorted.map { phoneEntry($0, now: now, refreshBefore: refreshBefore) }
        entries.append(localEntry(local, name: localName))
        return UpdatePlan(entries: entries)
    }

    private static func phoneEntry(_ phone: UpdateAllPhone, now: Date, refreshBefore: Date?) -> UpdatePlanEntry {
        let status = phone.status
        func entry(_ kind: UpdatePlanEntry.Kind) -> UpdatePlanEntry {
            UpdatePlanEntry(id: phone.id, name: phone.name, isLocal: false, app: status?.app, build: status?.build,
                            channel: status?.channel, kind: kind)
        }
        guard phone.connected else { return entry(.skipped(.offline)) }
        guard phone.supportsUpdates else { return entry(.skipped(.byHand)) }
        guard let status else { return entry(.skipped(.noStatus)) }
        if status.state == .manual { return entry(.skipped(.byHand)) }
        if status.state == .failed, status.reason == .notApplied { return entry(.skipped(.notApplied)) }
        guard status.remoteStart else { return entry(.skipped(.remoteOff)) }
        switch status.state {
        case .available, .downloading, .ready, .needsUser, .installing, .failed:
            return entry(.update(to: status.target, toBuild: status.targetBuild))
        case .current, .checking:
            let checked = Date(timeIntervalSince1970: TimeInterval(status.checkedAt) / 1000)
            let stale = status.checkedAt == 0 || now.timeIntervalSince(checked) > staleAfter || refreshBefore.map { checked < $0 } == true
            return entry(stale ? .update(to: nil, toBuild: nil) : .upToDate)
        case .manual:
            return entry(.skipped(.byHand))
        }
    }

    private static func localEntry(_ status: PeerUpdateStatus, name: String) -> UpdatePlanEntry {
        func entry(_ kind: UpdatePlanEntry.Kind) -> UpdatePlanEntry {
            UpdatePlanEntry(id: localID, name: name, isLocal: true, app: status.app, build: status.build, channel: status.channel, kind: kind)
        }
        switch status.state {
        case .manual:
            return entry(.skipped(.byHand))
        case .available, .downloading, .ready, .installing, .needsUser, .failed:
            // The person is here: even a version that did not apply may be tried again from this Mac.
            guard let target = status.target else { return entry(.upToDate) }
            return entry(.update(to: target, toBuild: status.targetBuild))
        case .current, .checking:
            return entry(.upToDate)
        }
    }
}

// MARK: - Run

enum UpdateRunFailure: String, Codable, Equatable {
    // Refusals from the phone.
    case disabled, rateLimited, manual, busy, other
    // Its own update stopped.
    case check, download, safety, installer, cancelled
    // Seen from here.
    case noAnswer, lostConnection, noReturn
}

enum UpdateRunStep: Codable, Equatable {
    case waiting
    case starting
    case checking
    case downloading(Int?)
    /// This Mac only: downloaded, waiting for the phones or the countdown.
    case ready
    case installing
    case restarting
    case needsUser(PeerUpdateReason?)
    /// This Mac only: Later; Sparkle installs it when Bridgey quits.
    case later
    case done(String)
    case upToDate
    case failed(UpdateRunFailure)
    case notApplied

    var isTerminal: Bool {
        switch self {
        case .done, .upToDate, .failed, .notApplied: true
        default: false
        }
    }

    /// The step's kind, so a new download percentage does not restart its timer.
    fileprivate var kind: Int {
        switch self {
        case .waiting: 0
        case .starting: 1
        case .checking: 2
        case .downloading: 3
        case .ready: 4
        case .installing: 5
        case .restarting: 6
        case .needsUser: 7
        case .later: 8
        case .done: 9
        case .upToDate: 10
        case .failed: 11
        case .notApplied: 12
        }
    }
}

struct UpdateRunItem: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let isLocal: Bool
    let fromApp: String
    let fromBuild: Int
    var targetApp: String?
    var targetBuild: Int?
    let channel: UpdateChannel
    var step: UpdateRunStep
    var startedAt: Date
    var stepSince: Date
    var disconnectedAt: Date?
    var requestID: String?

    var canRetry: Bool {
        guard !isLocal else { return false }
        switch step {
        case .failed, .notApplied: return true
        default: return false
        }
    }

    fileprivate mutating func move(_ next: UpdateRunStep, now: Date) {
        if next.kind != step.kind { stepSince = now }
        step = next
    }
}

enum UpdateRunEffect: Equatable {
    /// The countdown ended: install this Mac's update now.
    case installLocal
}

struct UpdateRun: Codable, Equatable {
    /// The countdown before this Mac restarts when the person started the run here.
    static let countdown: TimeInterval = 10
    static let slowAfter: TimeInterval = 180
    static let answerTimeout: TimeInterval = 20
    static let lostAfter: TimeInterval = 180
    static let returnTimeout: TimeInterval = 900
    /// A saved run is shown again after a relaunch only this long after its last change.
    static let expiry: TimeInterval = 1800

    let id: String
    let startedAt: Date
    var items: [UpdateRunItem]
    var countdownUntil: Date?
    var updatedAt: Date
    /// The person closed the finished run.
    var dismissed = false
    /// Started by Update all devices automatically or the command line, not by a click here: phones are
    /// told so, and this Mac's restart waits 60 seconds. Optional so runs saved by older builds still load.
    var auto: Bool?
    /// Someone is busy (a call, a screen share, ...): this Mac's restart waits. Not saved.
    var hold: UpdateBusy?
    /// While held: the next look (every few minutes in an automatic run, at once otherwise).
    var holdCheckAt: Date?

    var isAuto: Bool { auto == true }
    /// How long this Mac's restart counts down: 60 seconds in an automatic run, 10 otherwise.
    var countdownLength: TimeInterval { isAuto ? AutoUpdateRules.countdown : Self.countdown }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, items, countdownUntil, updatedAt, dismissed, auto
    }

    var phones: [UpdateRunItem] { items.filter { !$0.isLocal } }
    var local: UpdateRunItem? { items.first(where: \.isLocal) }

    /// Starts every phone at once (one `updates.start` each); this Mac's item starts downloading.
    /// `auto`: nobody clicked Update all (the setting, or the command line).
    static func start(plan: UpdatePlan, now: Date, auto: Bool = false, newID: () -> String) -> (run: UpdateRun, starts: [(deviceID: String, request: UpdateStartRequest)])? {
        let targets = plan.targets
        guard !targets.isEmpty else { return nil }
        var starts: [(String, UpdateStartRequest)] = []
        let items = targets.map { entry -> UpdateRunItem in
            var requestID: String?
            if !entry.isLocal {
                let id = newID()
                requestID = id
                starts.append((entry.id, UpdateStartRequest(requestID: id, auto: auto)))
            }
            var toBuild: Int?
            if case let .update(_, build) = entry.kind { toBuild = build }
            return UpdateRunItem(id: entry.id, name: entry.name, isLocal: entry.isLocal, fromApp: entry.app ?? "", fromBuild: entry.build ?? 0,
                                 targetApp: entry.knownTarget, targetBuild: toBuild, channel: entry.channel ?? .stable,
                                 step: entry.isLocal ? .downloading(nil) : .starting, startedAt: now, stepSince: now, requestID: requestID)
        }
        return (UpdateRun(id: newID(), startedAt: now, items: items, updatedAt: now, auto: auto ? true : nil), starts)
    }

    private mutating func change(_ id: String, now: Date, _ transform: (inout UpdateRunItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[index]
        transform(&items[index])
        if items[index] != before { updatedAt = now }
    }

    /// A phone's answer to its start.
    mutating func result(from id: String, _ result: UpdateStartResult, now: Date) {
        change(id, now: now) { item in
            guard !item.isLocal, item.requestID == result.requestID, item.step == .starting else { return }
            switch result.refusal {
            case nil: item.move(.checking, now: now)
            case .notApplied: item.move(.notApplied, now: now)
            case .disabled: item.move(.failed(.disabled), now: now)
            case .rateLimited: item.move(.failed(.rateLimited), now: now)
            case .manual: item.move(.failed(.manual), now: now)
            case .busy: item.move(.failed(.busy), now: now)
            case .other: item.move(.failed(.other), now: now)
            }
        }
    }

    /// A phone's `updates.status` while the run lasts.
    mutating func status(from id: String, _ status: PeerUpdateStatus, now: Date) {
        change(id, now: now) { item in
            guard !item.isLocal else { return }
            item.disconnectedAt = nil
            if let target = status.target, status.state != .current {
                item.targetApp = target
                if let build = status.targetBuild { item.targetBuild = build }
            }
            let newer = status.build > item.fromBuild && status.build >= (item.targetBuild ?? item.fromBuild + 1)
            switch item.step {
            case .waiting, .done, .upToDate:
                return
            case .failed, .notApplied:
                // Only a phone that came back on a newer build changes a finished row.
                if newer { item.move(.done(status.app), now: now) }
                return
            case .restarting:
                if newer {
                    item.move(.done(status.app), now: now)
                } else if status.build <= item.fromBuild, status.state != .installing, status.state != .needsUser {
                    item.move(.notApplied, now: now)
                } else if status.state == .needsUser {
                    item.move(.needsUser(status.reason), now: now)
                }
                return
            case .starting:
                // A status sent before the phone saw the start says nothing about this run.
                if status.state == .current || status.state == .failed || status.state == .manual { return }
            default:
                break
            }
            switch status.state {
            case .checking:
                item.move(.checking, now: now)
            case .available:
                item.move(.downloading(nil), now: now)
            case .downloading:
                item.move(.downloading(status.progress), now: now)
            case .ready, .installing:
                item.move(.installing, now: now)
            case .needsUser:
                item.move(.needsUser(status.reason), now: now)
            case .failed:
                item.move(status.reason == .notApplied ? .notApplied : .failed(Self.failure(status.reason)), now: now)
            case .manual:
                item.move(.failed(.manual), now: now)
            case .current:
                if newer {
                    item.move(.done(status.app), now: now)
                } else if item.step == .installing || item.step.kind == UpdateRunStep.needsUser(nil).kind {
                    item.move(.notApplied, now: now)
                } else {
                    item.move(.upToDate, now: now)
                }
            }
        }
    }

    private static func failure(_ reason: PeerUpdateReason?) -> UpdateRunFailure {
        switch reason {
        case .check: .check
        case .download: .download
        case .safety: .safety
        case .installer: .installer
        case .cancelled: .cancelled
        default: .other
        }
    }

    /// A phone's session ended: while installing it is restarting; earlier, it may come back.
    mutating func disconnected(_ id: String, now: Date) {
        change(id, now: now) { item in
            guard !item.isLocal, !item.step.isTerminal else { return }
            switch item.step {
            case .installing:
                item.move(.restarting, now: now)
            case .waiting, .restarting:
                break
            default:
                if item.disconnectedAt == nil { item.disconnectedAt = now }
            }
        }
    }

    /// This Mac's own update moved (its status, as phones would see it).
    mutating func local(_ status: PeerUpdateStatus, now: Date) {
        guard let id = local?.id else { return }
        change(id, now: now) { item in
            switch item.step {
            case .done, .upToDate, .notApplied, .installing:
                return
            case .later:
                // Sparkle installs it when Bridgey quits; only an error changes the row.
                if status.state == .failed { item.move(.failed(Self.failure(status.reason)), now: now) }
                return
            default:
                break
            }
            if let target = status.target {
                item.targetApp = target
                if let build = status.targetBuild { item.targetBuild = build }
            }
            switch status.state {
            case .checking: item.move(.checking, now: now)
            case .available: if item.step != .ready { item.move(.downloading(nil), now: now) }
            case .downloading: item.move(.downloading(status.progress), now: now)
            case .ready: item.move(.ready, now: now)
            case .installing: item.move(.installing, now: now)
            case .needsUser: item.move(.needsUser(status.reason), now: now)
            case .failed: item.move(status.reason == .notApplied ? .notApplied : .failed(Self.failure(status.reason)), now: now)
            case .manual: item.move(.failed(.manual), now: now)
            case .current: item.move(.upToDate, now: now)
            }
        }
        if local?.step != .ready { countdownUntil = nil }
    }

    /// Every phone finished, failed, or handed over to its installer (or waits for its person).
    var phonesSettled: Bool {
        phones.allSatisfy { item in
            switch item.step {
            case .done, .upToDate, .failed, .notApplied, .needsUser, .restarting, .installing: true
            default: false
            }
        }
    }

    /// Nothing more will happen without the person.
    var finished: Bool {
        items.allSatisfy { $0.step.isTerminal || $0.step == .later }
    }

    /// What the person is doing on any device, each tick. Busy holds this Mac's restart at once (and stops
    /// a countdown); it goes on when nobody is busy at the next look, every few minutes in an automatic run.
    mutating func busy(_ busy: UpdateBusy?, now: Date) {
        if let busy {
            if hold != busy { hold = busy }
            holdCheckAt = now.addingTimeInterval(isAuto ? AutoUpdateRules.recheck : 0)
            if countdownUntil != nil {
                countdownUntil = nil
                updatedAt = now
            }
        } else if hold != nil, now >= (holdCheckAt ?? now) {
            hold = nil
            holdCheckAt = nil
        }
    }

    /// Timeouts, the countdown, and this Mac's install once the phones are settled.
    mutating func tick(now: Date) -> [UpdateRunEffect] {
        var effects: [UpdateRunEffect] = []
        for index in items.indices where !items[index].isLocal {
            var item = items[index]
            switch item.step {
            case .starting where now.timeIntervalSince(item.stepSince) >= Self.answerTimeout:
                item.move(.failed(.noAnswer), now: now)
            case .restarting where now.timeIntervalSince(item.stepSince) >= Self.returnTimeout:
                item.move(.failed(.noReturn), now: now)
            default:
                if let lost = item.disconnectedAt, !item.step.isTerminal, item.step != .restarting,
                   now.timeIntervalSince(lost) >= Self.lostAfter {
                    item.disconnectedAt = nil
                    item.move(.failed(.lostConnection), now: now)
                }
            }
            if item != items[index] {
                items[index] = item
                updatedAt = now
            }
        }
        if let index = items.firstIndex(where: \.isLocal), items[index].step == .ready, phonesSettled, hold == nil {
            if let until = countdownUntil {
                if now >= until {
                    countdownUntil = nil
                    items[index].move(.installing, now: now)
                    updatedAt = now
                    effects.append(.installLocal)
                }
            } else {
                countdownUntil = now.addingTimeInterval(countdownLength)
                updatedAt = now
            }
        }
        return effects
    }

    /// Later during the countdown: this Mac installs when Bridgey quits.
    mutating func later(now: Date) {
        guard let id = local?.id else { return }
        countdownUntil = nil
        change(id, now: now) { item in
            if item.step == .ready { item.move(.later, now: now) }
        }
        updatedAt = now
    }

    /// Restart now, after Later (or to skip the rest of the countdown). The person asked, so a hold goes too.
    mutating func installNow(now: Date) -> Bool {
        guard let id = local?.id, let step = local?.step, step == .ready || step == .later else { return false }
        countdownUntil = nil
        hold = nil
        holdCheckAt = nil
        change(id, now: now) { $0.move(.installing, now: now) }
        return true
    }

    /// Retry for one phone that failed or whose update did not apply. Never called on its own.
    mutating func retry(_ id: String, now: Date, newID: () -> String) -> UpdateStartRequest? {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].canRetry else { return nil }
        let request = UpdateStartRequest(requestID: newID(), retry: true)
        items[index].requestID = request.requestID
        items[index].startedAt = now
        items[index].disconnectedAt = nil
        items[index].move(.starting, now: now)
        updatedAt = now
        return request
    }

    /// The phone whose current step has run the longest, once that is over 3 minutes.
    func slowItem(now: Date) -> UpdateRunItem? {
        items
            .filter { item in
                switch item.step {
                case .starting, .checking, .downloading, .installing, .restarting: true
                default: false
                }
            }
            .filter { now.timeIntervalSince($0.startedAt) >= Self.slowAfter }
            .min { $0.startedAt < $1.startedAt }
    }

    /// After this Mac relaunched: its own row is done or did not apply; phones that were installing are restarting.
    mutating func restored(installedApp: String, installedBuild: Int, now: Date) {
        countdownUntil = nil
        for index in items.indices {
            var item = items[index]
            if item.isLocal {
                switch item.step {
                case .installing, .ready, .later, .downloading, .checking:
                    if installedBuild > item.fromBuild, installedBuild >= (item.targetBuild ?? item.fromBuild + 1) {
                        item.move(.done(installedApp), now: now)
                    } else if item.step == .installing {
                        item.move(.notApplied, now: now)
                    }
                default: break
                }
            } else if item.step == .installing {
                item.move(.restarting, now: now)
            } else if !item.step.isTerminal, item.step != .restarting, item.step != .waiting {
                item.disconnectedAt = item.disconnectedAt ?? now
            }
            items[index] = item
        }
        updatedAt = now
    }

    var updatedCount: Int {
        items.filter { if case .done = $0.step { return true }; return $0.step == .upToDate }.count
    }
}

// MARK: - Words

/// What Update all says, in the panel card and in Settings.
enum UpdateAllText {
    static var thisMac: String { L10n.text("updateAll.thisMac", fallback: "This Mac") }

    /// "Update ready for OnePlus 11" or "Updates for 3 devices".
    static func title(_ plan: UpdatePlan) -> String {
        let targets = plan.targets
        if targets.count == 1, let only = targets.first {
            return String(format: L10n.text("updateAll.title.one", fallback: "Update ready for %@"), only.isLocal ? thisMac : only.name)
        }
        return String.localizedStringWithFormat(L10n.text("updateAll.title", fallback: "Updates for %d devices"), targets.count)
    }

    /// "Updates 2 connected phones and this Mac", "Updates this Mac", "Updates 1 connected phone".
    static func summary(_ plan: UpdatePlan) -> String {
        let phones = plan.phoneTargets.count
        switch (phones, plan.includesLocal) {
        case (0, _):
            return L10n.text("updateAll.summary.mac", fallback: "Updates this Mac")
        case (1, true):
            return L10n.text("updateAll.summary.onePhoneAndMac", fallback: "Updates 1 connected phone and this Mac")
        case (1, false):
            return L10n.text("updateAll.summary.onePhone", fallback: "Updates 1 connected phone")
        case (_, true):
            return String.localizedStringWithFormat(L10n.text("updateAll.summary.phonesAndMac", fallback: "Updates %d connected phones and this Mac"), phones)
        case (_, false):
            return String.localizedStringWithFormat(L10n.text("updateAll.summary.phones", fallback: "Updates %d connected phones"), phones)
        }
    }

    /// From and to for a target: "0.9.0-rr.3-beta.2 > beta.3", or "newest Beta, if newer".
    static func change(_ entry: UpdatePlanEntry) -> String {
        let from = entry.app ?? ""
        guard let to = entry.knownTarget else {
            let channel = entry.channel?.title ?? UpdateChannel.stable.title
            return from.isEmpty
                ? String(format: L10n.text("updateAll.newest", fallback: "Newest %@, if newer"), channel)
                : String(format: L10n.text("updateAll.fromNewest", fallback: "%1$@ > newest %2$@, if newer"), from, channel)
        }
        return "\(from) > \(UpdateFlowText.shortVersion(to, comparedTo: from))"
    }

    /// The hover text: one line per device it updates.
    static func help(_ plan: UpdatePlan) -> String {
        plan.targets.map { entry in
            let line = "\(entry.isLocal ? thisMac : entry.name): \(change(entry))"
            return entry.isLocal ? line + ", " + L10n.text("updateAll.restartsLast", fallback: "restarts last") : line
        }.joined(separator: "\n")
    }

    static func skipReason(_ reason: UpdateSkipReason) -> String {
        switch reason {
        case .offline: L10n.text("updateAll.skip.offline", fallback: "Not connected")
        case .byHand: L10n.text("updateAll.skip.byHand", fallback: "Update this one by hand")
        case .noStatus: L10n.text("updateAll.skip.noStatus", fallback: "Hasn\u{2019}t sent its version yet")
        case .notApplied: L10n.text("updateAll.skip.notApplied", fallback: "Last update didn\u{2019}t apply")
        case .remoteOff: L10n.text("updateAll.skip.remoteOff", fallback: "Updates from other devices are off there")
        }
    }

    /// "Each device stays on its own channel: OnePlus 11 on Beta, this Mac on Stable."
    static func channelNote(_ plan: UpdatePlan) -> String? {
        guard plan.channelsDiffer else { return nil }
        let parts = plan.targets.compactMap { entry -> String? in
            guard let channel = entry.channel else { return nil }
            return String(format: L10n.text("updateAll.channel.part", fallback: "%1$@ on %2$@"), entry.isLocal ? thisMac.lowercasedFirst : entry.name, channel.title)
        }
        return String(format: L10n.text("updateAll.channels", fallback: "Each device stays on its own channel: %@."), parts.joined(separator: ", "))
    }

    static func failure(_ failure: UpdateRunFailure) -> String {
        switch failure {
        case .disabled: L10n.text("updateAll.failure.disabled", fallback: "updates from other devices are off there")
        case .rateLimited: L10n.text("updateAll.failure.rateLimited", fallback: "asked too often, try again in a minute")
        case .manual: L10n.text("updateAll.failure.manual", fallback: "update it by hand")
        case .busy: L10n.text("updateAll.failure.busy", fallback: "it was busy")
        case .other: L10n.text("updateAll.failure.other", fallback: "something went wrong")
        case .check: L10n.text("updateAll.failure.check", fallback: "couldn\u{2019}t check for updates")
        case .download: L10n.text("updateAll.failure.download", fallback: "the download failed")
        case .safety: L10n.text("updateAll.failure.safety", fallback: "the download failed its safety check")
        case .installer: L10n.text("updateAll.failure.installer", fallback: "the installer stopped")
        case .cancelled: L10n.text("updateAll.failure.cancelled", fallback: "it was cancelled")
        case .noAnswer: L10n.text("updateAll.failure.noAnswer", fallback: "no answer")
        case .lostConnection: L10n.text("updateAll.failure.lost", fallback: "the connection was lost")
        case .noReturn: L10n.text("updateAll.failure.noReturn", fallback: "it didn\u{2019}t come back")
        }
    }

    /// A device row during a run: "Downloading 42%", "Updated to 0.9.0-rr.3", "Didn't finish: no answer".
    static func step(_ item: UpdateRunItem, countdownUntil: Date?, now: Date) -> String {
        switch item.step {
        case .waiting: return L10n.text("updateAll.step.waiting", fallback: "Waiting")
        case .starting: return L10n.text("updateAll.step.starting", fallback: "Starting")
        case .checking: return L10n.text("updateAll.step.checking", fallback: "Checking")
        case let .downloading(progress):
            guard let progress else { return L10n.text("updateAll.step.downloading", fallback: "Downloading") }
            return String(format: L10n.text("updateAll.step.downloadingPercent", fallback: "Downloading %d%%"), progress)
        case .ready:
            if let countdownUntil { return countdown(countdownUntil, now: now) }
            return L10n.text("updateAll.step.ready", fallback: "Ready, restarts last")
        case .installing: return L10n.text("updateAll.step.installing", fallback: "Installing")
        case .restarting: return L10n.text("updateAll.step.restarting", fallback: "Restarting")
        case .needsUser: return L10n.text("updateAll.step.needsUser", fallback: "Waiting for you")
        case .later: return L10n.text("updateAll.step.later", fallback: "Restarts when Bridgey quits")
        case let .done(app): return String(format: L10n.text("updateAll.step.done", fallback: "Updated to %@"), app)
        case .upToDate: return L10n.text("updateAll.step.upToDate", fallback: "Already up to date")
        case let .failed(failure):
            return String(format: L10n.text("updateAll.step.failed", fallback: "Didn\u{2019}t finish: %@"), Self.failure(failure))
        case .notApplied: return L10n.text("updateAll.step.notApplied", fallback: "Update didn\u{2019}t apply")
        }
    }

    /// "Tap the notification on OnePlus 11", under a phone that waits for its person.
    static func needsUserDetail(_ item: UpdateRunItem) -> String? {
        guard case let .needsUser(reason) = item.step else { return nil }
        if reason == .permission {
            return String(format: L10n.text("updateAll.needsUser.permission", fallback: "Allow Bridgey to install updates on %@"), item.name)
        }
        return String(format: L10n.text("updateAll.needsUser.confirm", fallback: "Tap Update on %@ to finish"), item.name)
    }

    static func countdown(_ until: Date, now: Date) -> String {
        let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        return String(format: L10n.text("updateAll.countdown", fallback: "Restarting in %d s"), seconds)
    }

    /// "4m", "<1m", "1h 5m".
    static func elapsed(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    enum CapsuleAction: Equatable {
        case later, restartNow, retry(String), retryAll, dismiss
    }

    enum CapsuleTone: Equatable { case normal, slow, needsYou, failed, done }

    struct Capsule: Equatable {
        let tone: CapsuleTone
        let label: String
        let action: CapsuleAction?
    }

    /// The run in one line, as T3 Code's update button shows it.
    static func capsule(_ run: UpdateRun, now: Date) -> Capsule {
        // Someone is busy: this Mac's restart waits (Later still puts it off).
        if let hold = run.hold, run.local?.step == .ready, run.phonesSettled {
            return Capsule(tone: .normal, label: AutoUpdateText.waiting(hold, device: nil), action: .later)
        }
        if let until = run.countdownUntil {
            return Capsule(tone: .normal, label: countdown(until, now: now), action: .later)
        }
        if run.local?.step == .installing {
            return Capsule(tone: .normal, label: L10n.text("updateAll.restarting", fallback: "Restarting\u{2026}"), action: nil)
        }
        if let waiting = run.phones.first(where: { if case .needsUser = $0.step { return true } else { return false } }) {
            return Capsule(tone: .needsYou, label: String(format: L10n.text("updateAll.waitingFor", fallback: "Waiting for you on %@"), waiting.name), action: nil)
        }
        if let slow = run.slowItem(now: now) {
            let label = String(format: L10n.text("updateAll.slow", fallback: "%1$@ is taking longer than usual \u{00B7} %2$@"),
                               slow.isLocal ? thisMac : slow.name, elapsed(now.timeIntervalSince(slow.startedAt)))
            return Capsule(tone: .slow, label: label, action: nil)
        }
        let total = run.items.count
        let active = run.items.contains { !$0.step.isTerminal && $0.step != .later && $0.step != .ready }
        if active {
            return Capsule(tone: .normal, label: progressLine(run.updatedCount, total), action: nil)
        }
        let failed = run.items.filter { if case .failed = $0.step { return true }; return $0.step == .notApplied }
        if failed.count == 1, let only = failed.first {
            let label = only.step == .notApplied
                ? String(format: L10n.text("updateAll.notAppliedOn", fallback: "%@: update didn\u{2019}t apply"), only.isLocal ? thisMac : only.name)
                : String(format: L10n.text("updateAll.failedOn", fallback: "%@: update didn\u{2019}t finish"), only.isLocal ? thisMac : only.name)
            return Capsule(tone: .failed, label: label, action: only.canRetry ? .retry(only.id) : .dismiss)
        }
        if failed.count > 1 {
            return Capsule(tone: .failed, label: String.localizedStringWithFormat(L10n.text("updateAll.failedMany", fallback: "%d didn\u{2019}t finish"), failed.count),
                           action: failed.contains(where: \.canRetry) ? .retryAll : .dismiss)
        }
        if run.local?.step == .later {
            return Capsule(tone: .normal, label: L10n.text("updateAll.macOnQuit", fallback: "This Mac restarts when Bridgey quits"), action: .restartNow)
        }
        if run.local?.step == .ready {
            return Capsule(tone: .normal, label: progressLine(run.updatedCount, total), action: nil)
        }
        return Capsule(tone: .done, label: L10n.text("updateAll.allUpdated", fallback: "All updated"), action: .dismiss)
    }

    static func progressLine(_ done: Int, _ total: Int) -> String {
        String(format: L10n.text("updateAll.progress", fallback: "%1$d of %2$d updated"), done, total)
    }
}

private extension String {
    /// "This Mac" in the middle of a sentence.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

// MARK: - This Mac's own status

extension UpdateFlowText {
    /// Sparkle and network errors as the reason phones see. Codes are Sparkle's `SUError` values.
    static func errorReason(domain: String, code: Int) -> PeerUpdateReason {
        if domain == NSURLErrorDomain { return .check }
        guard domain == "SUSparkleErrorDomain" else { return .other }
        switch code {
        case 1000, 1002, 1004: return .check
        case 1003, 1005, 4012: return .installer
        case 2000, 2001, 3000: return .download
        case 3001, 3002, 4009: return .safety
        case 4001, 4007, 4008: return .cancelled
        default: return .other
        }
    }
}

/// What this Mac reports in `updates.status`, from Sparkle's flow. Pure, so the mapping is unit tested.
struct LocalUpdateInputs: Equatable {
    var available: Bool
    var app: String
    var build: Int
    var channel: UpdateChannel
    var flow: UpdateFlow
    var deferral: UpdateDeferral?
    /// The build Sparkle last offered (SUAppcastItem.versionString).
    var offeredBuild: Int?
    var failureReason: PeerUpdateReason?
    var lastCheck: Date?
    var remoteStartAllowed: Bool
    var notApplied: UpdateAttemptStore.Attempt?
    /// Update all devices automatically is on here.
    var auto = false
    /// What the person is doing on this Mac.
    var busy: UpdateBusy?

    var status: PeerUpdateStatus {
        var status = PeerUpdateStatus(platform: .macos, edition: "rr", app: app, build: max(1, build), channel: channel, state: .current,
                                      remoteStart: available && remoteStartAllowed,
                                      checkedAt: lastCheck.map { max(0, Int(($0.timeIntervalSince1970 * 1000).rounded(.down))) } ?? 0,
                                      auto: available && auto, busy: busy)
        guard available else {
            status.state = .manual
            return status
        }
        func offer(_ state: PeerUpdateState, _ version: String) {
            status.state = state
            status.target = version
            status.targetBuild = offeredBuild
        }
        switch flow {
        case .idle, .upToDate:
            if let deferral, deferral.kind != .skipped {
                offer(deferral.kind == .onQuit ? .ready : .available, deferral.version)
            }
        case .checking:
            status.state = .checking
        case let .available(update):
            offer(update.downloaded ? .ready : .available, update.version)
        case let .downloading(version, _, _):
            offer(.downloading, version)
            status.progress = flow.progress.map { Int(($0 * 100).rounded(.down)) }
        case let .extracting(version, _):
            offer(.downloading, version)
            status.progress = 100
        case let .ready(version):
            offer(.ready, version)
        case let .installing(version):
            offer(.installing, version)
        case .failed:
            status.state = .failed
            status.reason = failureReason ?? .other
        }
        // A version that did not apply stays reported until another build is offered or the person retries.
        if let notApplied, status.state == .current || status.state == .failed
            || ((status.state == .available || status.state == .ready) && (offeredBuild == nil || offeredBuild == notApplied.build)) {
            status.state = .failed
            status.reason = .notApplied
            status.target = notApplied.version
            status.targetBuild = notApplied.build
            status.progress = nil
        }
        return status
    }
}
