import AppKit
import Combine
import Foundation
import Network

/*
 * Update all devices automatically on this Mac: the setting, the checks (every 30 minutes on Beta and
 * Nightly, 6 hours on Stable, and on wake and network changes), what the person is doing (so a run
 * waits), the decision (AutoUpdatePolicy), the notice with Later, the activity entries and the
 * command line (`BridgeyMac --update-all`, served by UpdateControlServer).
 */

/// What the person is doing on this Mac, from the session's published state. Pure mapping in `busy(...)`.
@MainActor
final class MacBusyMonitor: ObservableObject {
    @Published private(set) var active: Set<UpdateBusy> = []
    private var cancellables = Set<AnyCancellable>()

    var current: UpdateBusy? { UpdateBusy.mostImportant(active) }

    func attach(pairing: PairingCoordinator, setup: SetupCenter) {
        let session = Publishers.CombineLatest4(
            pairing.$remoteCall.map { $0 != nil }.removeDuplicates(),
            pairing.phoneScreen.$streaming.map { !$0.isEmpty }.removeDuplicates(),
            pairing.remoteInput.$active.map { $0 != nil }.removeDuplicates(),
            pairing.$fileTransfers.map { Array($0.values) }
        )
        Publishers.CombineLatest3(session, pairing.$pairingFlow, setup.$setupOpen)
            .map { session, flow, setupOpen in
                Self.busy(call: session.0, screen: session.1, remote: session.2, transfers: session.3, pairing: flow, setupOpen: setupOpen)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.active = $0 }
            .store(in: &cancellables)
    }

    /// A call card (ringing or in a call), the phone's screen shown here, remote control, a transfer
    /// (a folder coming from the phone is a Phone files download), or setup and pairing.
    nonisolated static func busy(call: Bool, screen: Bool, remote: Bool, transfers: [FileTransferRow], pairing: PairingState, setupOpen: Bool) -> Set<UpdateBusy> {
        var active: Set<UpdateBusy> = []
        if call { active.insert(.call) }
        if screen { active.insert(.screenShare) }
        if remote { active.insert(.remoteControl) }
        for row in transfers where row.active {
            active.insert(row.folder?.incoming == true ? .phoneFiles : .transfer)
        }
        switch pairing {
        case .connecting, .verification: active.insert(.setup)
        default: break
        }
        if setupOpen { active.insert(.setup) }
        return active
    }
}

/// The last automatic run and how it ended, for Settings > Updates.
struct AutoRunRecord: Codable, Equatable {
    var runID: String
    var at: Date
    /// The newest version the run installed or offered.
    var version: String?
    var updated: Int
    var total: Int
    var failed: Int
    /// This Mac's restart was put off with Later.
    var later = false
    var finished = false

    init(run: UpdateRun) {
        runID = run.id
        at = run.startedAt
        updated = 0
        total = run.items.count
        failed = 0
        update(from: run)
    }

    mutating func update(from run: UpdateRun) {
        version = run.items.compactMap { item -> String? in
            if case let .done(app) = item.step { return app }
            return item.targetApp
        }.max { $0.compare($1, options: .numeric) == .orderedAscending }
        updated = run.updatedCount
        total = run.items.count
        failed = run.items.filter { if case .failed = $0.step { return true }; return $0.step == .notApplied }.count
        later = run.local?.step == .later
        finished = run.finished
    }
}

/// Saved when another device's automatic start was accepted: after the relaunch, "Updated automatically".
struct AutoPeerMarker: Codable, Equatable {
    var fromBuild: Int
    var by: String
    var at: Date
}

@MainActor
final class AutoUpdateCoordinator: ObservableObject {
    static let shared = AutoUpdateCoordinator()
    nonisolated static let choiceKey = "updates.autoUpdateAll"
    nonisolated static let memoryKey = "updates.autoMemory"
    nonisolated static let lastRunKey = "updates.autoLastRun"
    nonisolated static let markerKey = "updates.autoPeerMarker"

    /// The person's own choice, nil until they make one (the channel's default applies).
    @Published private(set) var storedChoice: Bool?
    @Published private(set) var decision: AutoDecision = .nothingToDo
    @Published private(set) var lastRun: AutoRunRecord?
    @Published private(set) var memory: AutoMemory
    let busy = MacBusyMonitor()
    let notice = AutoUpdateNoticeController()

    private let defaults: UserDefaults
    private weak var pairing: PairingCoordinator?
    private weak var updater: AppUpdater?
    private weak var updateAll: UpdateAllCoordinator?
    private var localID = ""
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    /// When this Mac accepted another device's start (it then does not start its own run for a while).
    private var lastPeerStart: Date?
    /// The last scheduled check this coordinator asked for (a failed one is not retried every minute).
    private var lastScheduledCheck: Date?
    private var checkWaiters: [(Bool) -> Void] = []
    private var lastHoldLogged: String?
    private let launchedAt = Date()
    private var settleLookScheduled = false
    /// The last run whose end was counted (each run once).
    private var endedRunID: String?
    private var evaluateQueued = false
    private var controlServer: UpdateControlServer?
    var clock: () -> Date = Date.init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedChoice = defaults.object(forKey: Self.choiceKey) as? Bool
        memory = defaults.data(forKey: Self.memoryKey).flatMap { try? JSONDecoder().decode(AutoMemory.self, from: $0) } ?? AutoMemory()
        lastRun = defaults.data(forKey: Self.lastRunKey).flatMap { try? JSONDecoder().decode(AutoRunRecord.self, from: $0) }
    }

    // MARK: The setting

    /// On by default for Beta and Nightly, off for Stable; the person's choice wins. It needs Sparkle's
    /// automatic checks and an updater that can run.
    var enabled: Bool {
        guard let updater, updater.isAvailable, updater.automaticallyChecks else { return false }
        return AutoUpdateRules.enabled(stored: storedChoice, channel: updater.channel)
    }

    /// The switch in Settings > Updates and setup. On also turns on automatic checks (it needs them).
    func setEnabled(_ value: Bool) {
        storedChoice = value
        defaults.set(value, forKey: Self.choiceKey)
        if value, let updater, !updater.automaticallyChecks { updater.setAutomaticallyChecks(true) }
        settingChanged()
    }

    private func settingChanged() {
        objectWillChange.send()
        updateAll?.statusInputsChanged()
        scheduleEvaluate()
    }

    // MARK: Wiring

    func configure(pairing: PairingCoordinator, updater: AppUpdater, updateAll: UpdateAllCoordinator, localDeviceID: String) {
        self.pairing = pairing
        self.updater = updater
        self.updateAll = updateAll
        localID = localDeviceID
        updateAll.auto = self
        busy.attach(pairing: pairing, setup: SetupCenter.shared)
        notice.attach(updateAll: updateAll, auto: self)
        settleMarker()
    }

    /// After UpdateAllCoordinator is configured: subscriptions, the minute timer, wake and network
    /// watching, and the command-line hand-over.
    func start() {
        guard let pairing, let updater, let updateAll else { return }
        busy.$active.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.updateAll?.statusInputsChanged()
            self?.scheduleEvaluate()
        }.store(in: &cancellables)
        updater.$flow.removeDuplicates().sink { [weak self] _ in self?.scheduleEvaluate() }.store(in: &cancellables)
        updater.$channel.removeDuplicates().dropFirst().sink { [weak self] _ in self?.settingChanged() }.store(in: &cancellables)
        updater.$automaticallyChecks.removeDuplicates().dropFirst().sink { [weak self] _ in self?.settingChanged() }.store(in: &cancellables)
        pairing.$connectedPhones.removeDuplicates().sink { [weak self] _ in self?.scheduleEvaluate() }.store(in: &cancellables)
        updateAll.$run.removeDuplicates().sink { [weak self] _ in self?.scheduleEvaluate() }.store(in: &cancellables)
        updater.onCheckEnded = { [weak self] found in self?.checkEnded(found) }
        let minute = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        RunLoop.main.add(minute, forMode: .common)
        timer = minute
        watchWakeAndNetwork()
        startControlServer()
        heartbeat()
    }

    // MARK: Checks

    private func heartbeat() {
        scheduledCheckIfDue()
        evaluate()
    }

    private func scheduledCheckIfDue() {
        guard enabled, let updater, let interval = AutoUpdateRules.checkInterval(enabled: true, channel: updater.channel) else { return }
        let now = clock()
        guard AutoUpdateRules.checkDue(lastCheck: updater.lastCheck, now: now, interval: interval) else { return }
        // A check that failed (offline) is tried again after the event gap, not every minute.
        if let last = lastScheduledCheck, now >= last, now.timeIntervalSince(last) < AutoUpdateRules.eventCheckGap { return }
        if updater.checkInBackground() { lastScheduledCheck = now }
    }

    private func eventCheck() {
        guard enabled, let updater else { return }
        guard AutoUpdateRules.eventCheckAllowed(lastCheck: updater.lastCheck, lastEventCheck: updater.lastEventCheck, now: clock()) else { return }
        updater.checkInBackground(event: true)
    }

    private func watchWakeAndNetwork() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.eventCheck() }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.signature(path)
            Task { @MainActor in self?.pathChanged(signature, satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "in.roundrobin.bridgey.auto-update.path"))
        pathMonitor = monitor
    }

    nonisolated private static func signature(_ path: NWPath) -> String {
        path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",") + "|\(path.status)"
    }

    private func pathChanged(_ signature: String, satisfied: Bool) {
        defer { pathSignature = signature }
        // The first reading is the network at launch, not a change.
        guard let previous = pathSignature, previous != signature, satisfied else { return }
        eventCheck()
    }

    private func checkEnded(_ found: Bool) {
        let waiters = checkWaiters
        checkWaiters = []
        for waiter in waiters { waiter(found) }
        scheduleEvaluate()
    }

    // MARK: Deciding

    /// Many changes arrive together (a status, a flow step, a run step): decide once after them.
    func scheduleEvaluate() {
        guard !evaluateQueued else { return }
        evaluateQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.evaluateQueued = false
                self?.evaluate()
            }
        }
    }

    func facts(now: Date) -> AutoFacts? {
        guard let pairing, let updater, let updateAll, let local = updateAll.localStatus else { return nil }
        let peers = pairing.connectedPhones.compactMap { phone -> AutoPeer? in
            guard phone.state.remoteUpdates, let status = phone.state.updateStatus else { return nil }
            return AutoPeer(id: phone.id, name: phone.name, status: status)
        }
        let updating: Bool = {
            guard let start = lastPeerStart, now >= start, now.timeIntervalSince(start) < AutoUpdateRules.peerRequestWindow else { return false }
            switch updater.flow {
            case .checking, .available, .downloading, .extracting, .ready, .installing: return true
            default: return false
            }
        }()
        let idle = macIdleSeconds() >= AutoUpdateRules.idleAfter || BridgeyWindows.screenUnavailable()
        return AutoFacts(now: now, enabled: enabled, localID: localID, localName: UpdateAllText.thisMac, local: local,
                         localBusy: busy.current, peers: peers, runActive: updateAll.runActive, updatingForPeer: updating, idle: idle)
    }

    /// What the person is doing on any connected device (this Mac first), and where (nil: this Mac):
    /// holds this Mac's restart.
    func busyAnywhere() -> (UpdateBusy, String?)? {
        guard let facts = facts(now: clock()) else { return busy.current.map { ($0, nil) } }
        return AutoUpdatePolicy.busy(facts)
    }

    /// An automatic run's restart is held: "Waiting: call in progress" once per activity and device.
    func runHeld(_ kind: UpdateBusy, device: String?, runID: String) {
        let key = "\(runID)|\(kind.rawValue)|\(device ?? "")"
        guard key != lastHoldLogged else { return }
        lastHoldLogged = key
        record(.updateAutoWaiting, device: device, content: kind.rawValue)
    }

    func evaluate() {
        guard let facts = facts(now: clock()) else { return }
        if settlingAfterLaunch(facts.now) { return }
        let step = AutoUpdatePolicy.decide(facts, memory: memory)
        if step.memory != memory {
            memory = step.memory
            save(memory, Self.memoryKey)
        }
        if case let .waiting(kind, device)? = step.log { record(.updateAutoWaiting, device: device, content: kind.rawValue) }
        if decision != step.decision {
            decision = step.decision
            BridgeyLog.updates.notice("AUTO decision=\(String(describing: step.decision), privacy: .public)")
        }
        if case let .start(_, refreshBefore) = step.decision {
            updateAll?.startAll(auto: true, refreshBefore: refreshBefore)
        }
    }

    /// Just launched: wait for paired phones to reconnect and report (at most a minute), so an automatic
    /// run found at launch includes them. Looks again when the minute is over.
    private func settlingAfterLaunch(_ now: Date) -> Bool {
        guard let pairing else { return false }
        let ready = Set(pairing.connectedPhones.filter { !$0.state.remoteUpdates || $0.state.updateStatus != nil }
            .filter(\.state.featureStateReceived).map(\.id))
        guard AutoUpdateRules.settling(launchedAt: launchedAt, now: now, paired: pairing.trustedDevices.map(\.id), ready: ready) else { return false }
        if !settleLookScheduled {
            settleLookScheduled = true
            let delay = max(1, AutoUpdateRules.launchSettle - now.timeIntervalSince(launchedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        return true
    }

    // MARK: The run

    /// An automatic (or command-line) run started: every device it leaves out goes to the activity stream.
    func runStarted(plan: UpdatePlan) {
        for entry in plan.skipped where !entry.isLocal {
            guard case let .skipped(reason) = entry.kind, reason != .noStatus else { continue }
            record(.updateAutoSkipped, deviceID: entry.id, device: entry.name, content: reason.wireKey)
        }
    }

    /// The person chose Later on the notice or the run card of an automatic run.
    /// Later in any run (clicked or automatic) while the setting is on: the automatic rules respect it
    /// too, so a clicked run's Later is not followed by an automatic restart.
    func laterChosen() {
        let now = clock()
        guard enabled, let target = facts(now: now).flatMap(AutoUpdatePolicy.target) else { return }
        memory = memory.forTarget(target, now: now)
        memory.later(now: now)
        save(memory, Self.memoryKey)
        scheduleEvaluate()
    }

    /// Every run's changes. When any run ends, the next automatic run for what is still on offer waits an
    /// hour (a phone that did not answer must not be asked again at once). Automatic runs also keep their
    /// record for Settings and list the devices that did not finish.
    func runChanged(_ run: UpdateRun) {
        let now = clock()
        if run.finished, endedRunID != run.id {
            endedRunID = run.id
            if let target = facts(now: now).flatMap(AutoUpdatePolicy.target) {
                memory = memory.forTarget(target, now: now)
                memory.ran(now: now)
                save(memory, Self.memoryKey)
            }
        }
        guard run.isAuto else { return }
        var summary = lastRun?.runID == run.id ? lastRun! : AutoRunRecord(run: run)
        let wasFinished = lastRun?.runID == run.id && lastRun?.finished == true
        summary.update(from: run)
        if summary != lastRun {
            lastRun = summary
            save(summary, Self.lastRunKey)
        }
        if summary.finished && !wasFinished {
            for item in run.items {
                let content: String
                switch item.step {
                case let .failed(failure): content = failure.wireKey
                case .notApplied: content = "not_applied"
                default: continue
                }
                record(.updateAutoFailed, deviceID: item.isLocal ? nil : item.id, device: item.isLocal ? nil : item.name, content: content)
            }
        }
    }

    /// After the relaunch an automatic run installed: once.
    func updatedAutomatically(to version: String) {
        record(.updateAutoDone, device: nil, content: version)
    }

    /// Another device started this Mac's update automatically (`updates.start` with `auto`, accepted).
    func peerStarted(by deviceID: String) {
        guard let pairing, let updater else { return }
        let name = pairing.phoneName(deviceID)
        lastPeerStart = clock()
        save(AutoPeerMarker(fromBuild: updater.buildNumber, by: name, at: clock()), Self.markerKey)
        record(.updateAutoStartedBy, deviceID: deviceID, device: name, content: nil)
        notice.showStartedBy(name)
        scheduleEvaluate()
    }

    /// At launch: a marker from an automatic start says whether this Mac now runs the newer build.
    private func settleMarker() {
        guard let updater, let marker = defaults.data(forKey: Self.markerKey).flatMap({ try? JSONDecoder().decode(AutoPeerMarker.self, from: $0) }) else { return }
        defaults.removeObject(forKey: Self.markerKey)
        let now = clock()
        guard now >= marker.at, now.timeIntervalSince(marker.at) < 3600, updater.buildNumber > marker.fromBuild else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updatedAutomatically(to: updater.shortVersion) }
        }
    }

    // MARK: Command line

    private func startControlServer() {
        let server = UpdateControlServer(path: UpdateControlServer.defaultSocketURL().path) { [weak self] request, reply in
            Task { @MainActor in
                guard let self else { return reply.finish(.blocked, reason: "not_ready", text: nil) }
                await self.handle(request, reply: reply)
            }
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            BridgeyLog.updates.error("UPDATE_CONTROL start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `--update-all`: check now, then Update all, as an automatic run (phones are told it was automatic,
    /// this Mac's restart waits 60 seconds with Later). Never over a run, another device's update, or
    /// someone busy. The request carries no URL or version.
    func handle(_ request: UpdateControlRequest, reply: UpdateControlReply) async {
        guard request.command == .updateAll, let updater, let updateAll, let pairing else {
            return reply.finish(.blocked, reason: "not_ready", text: nil)
        }
        reply.info(version: updater.shortVersion, build: updater.buildNumber, channel: updater.channel.rawValue)
        if request.launched { await waitForPhones(pairing, seconds: 20) }
        if let blocked = blockedNow() { return reply.blocked(blocked) }
        if updater.isAvailable {
            reply.progress("checking")
            _ = await checkNow(updater)
        }
        if let blocked = blockedNow() { return reply.blocked(blocked) }
        let now = clock()
        let local = updateAll.localStatus
        let target = local.flatMap(AutoUpdatePolicy.localTarget)
        let refreshBefore = target.map { memory.targetBuild == $0 ? (memory.foundAt ?? now) : now }
        let plan = updateAll.plan(now: now, refreshBefore: refreshBefore)
        reply.plan(plan, refreshing: refreshBefore != nil)
        guard plan.visible else { return reply.finish(.upToDate, reason: nil, text: nil) }
        guard updateAll.startAll(auto: true, refreshBefore: refreshBefore) != nil else { return reply.finish(.upToDate, reason: nil, text: nil) }
        reply.finish(.started, reason: nil, text: nil)
    }

    private func blockedNow() -> AutoUpdatePolicy.Blocked? {
        facts(now: clock()).flatMap(AutoUpdatePolicy.commandLineBlocked)
    }

    /// Starts a quiet check and waits for its end (at most a minute). False when Sparkle could not check.
    private func checkNow(_ updater: AppUpdater) async -> Bool {
        switch updater.flow {
        case .available, .ready, .downloading, .extracting, .installing: return true
        default: break
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (Bool) -> Void = { found in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: found)
            }
            checkWaiters.append(finish)
            // When Sparkle is checking already (a scheduled check), that check's end answers; the
            // timeout answers if nothing does.
            updater.checkInBackground()
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { finish(false) }
        }
    }

    private func waitForPhones(_ pairing: PairingCoordinator, seconds: Int) async {
        let trusted = Set(pairing.trustedDevices.map(\.id))
        for _ in 0..<(seconds * 2) {
            let connected = Set(pairing.connectedPhones.filter { $0.state.featureStateReceived }.map(\.id))
            if trusted.isSubset(of: connected) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Helpers

    private func record(_ kind: ActivityKind, deviceID: String? = nil, device: String?, content: String?) {
        pairing?.activity.record(kind, deviceID: deviceID, deviceName: device ?? "", content: content, previews: false)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

extension UpdateRunFailure {
    /// The key shared with Android (RunFailure.wire) in activity entries.
    var wireKey: String {
        switch self {
        case .disabled: "disabled"
        case .rateLimited: "rate_limited"
        case .manual: "manual"
        case .busy: "busy"
        case .other: "other"
        case .check: "check"
        case .download: "download"
        case .safety: "safety"
        case .installer: "installer"
        case .cancelled: "cancelled"
        case .noAnswer: "no_answer"
        case .lostConnection: "lost_connection"
        case .noReturn: "no_return"
        }
    }

    init?(wireKey: String) {
        guard let match = [UpdateRunFailure.disabled, .rateLimited, .manual, .busy, .other, .check, .download, .safety, .installer,
                           .cancelled, .noAnswer, .lostConnection, .noReturn].first(where: { $0.wireKey == wireKey }) else { return nil }
        self = match
    }
}

extension UpdateSkipReason {
    /// The key shared with Android in activity entries.
    var wireKey: String {
        switch self {
        case .offline: "offline"
        case .byHand: "by_hand"
        case .noStatus: "no_status"
        case .notApplied: "not_applied"
        case .remoteOff: "remote_off"
        }
    }

    init?(wireKey: String) {
        guard let match = [UpdateSkipReason.offline, .byHand, .noStatus, .notApplied, .remoteOff].first(where: { $0.wireKey == wireKey }) else { return nil }
        self = match
    }
}
