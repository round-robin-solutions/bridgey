import Combine
import Foundation

/// What the panel card and Settings > Updates draw for Update all. Plain data, so screenshots render it.
struct UpdateAllDisplay: Equatable {
    var plan = UpdatePlan()
    var run: UpdateRun?
    var previewOpen = false
    var now = Date()

    /// A run that has not been closed.
    var activeRun: UpdateRun? { run.flatMap { $0.dismissed ? nil : $0 } }

    /// The panel shows the card when phones have something to update, or while a run lasts. An update for
    /// this Mac alone already has its own card there.
    var showsPanelCard: Bool { activeRun != nil || (plan.visible && !plan.phoneTargets.isEmpty) }

    /// Settings offers Update all whenever any device has a known update and nothing is running.
    var offersUpdateAll: Bool { activeRun == nil && plan.visible }
}

struct UpdateAllActions {
    var openPreview: () -> Void = {}
    var closePreview: () -> Void = {}
    var start: () -> Void = {}
    var later: () -> Void = {}
    var restartNow: () -> Void = {}
    var retry: (String) -> Void = { _ in }
    var retryAll: () -> Void = {}
    var dismiss: () -> Void = {}
}

/// Update all on this Mac: sends this Mac's `updates.status` to phones that understand it, answers their
/// `updates.start` (only by starting this Mac's own Sparkle update), and runs Update all from here.
@MainActor
final class UpdateAllCoordinator: ObservableObject {
    static let shared = UpdateAllCoordinator()
    nonisolated static let remoteStartKey = "updates.remoteStart"
    nonisolated static let runKey = "updates.updateAllRun"

    /// Settings > Updates > Let paired devices start updates on this Mac. On by default: it only triggers
    /// this Mac's own signed update from its own channel.
    @Published private(set) var remoteStartAllowed: Bool
    @Published private(set) var run: UpdateRun?
    @Published private(set) var previewOpen = false
    @Published private(set) var now = Date()

    private weak var pairing: PairingCoordinator?
    private weak var updater: AppUpdater?
    private let defaults: UserDefaults
    private var gate = UpdateStartGate()
    private var lastSent: [String: PeerUpdateStatus] = [:]
    private var lastSentAt: [String: Date] = [:]
    private var trailingSend: Set<String> = []
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Install this Mac's update as soon as Sparkle has it on offer (after the countdown or Restart now).
    private var installWhenOffered = false
    /// Download this Mac's update as soon as a check offers it (its run started from a put-off update).
    private var downloadWhenOffered = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        remoteStartAllowed = defaults.object(forKey: Self.remoteStartKey) as? Bool ?? true
    }

    func configure(pairing: PairingCoordinator, updater: AppUpdater) {
        self.pairing = pairing
        self.updater = updater
        pairing.updatesPeerReady = { [weak self] id in self?.sendStatus(to: id, force: true) }
        pairing.updatesStatusReceived = { [weak self] id, status in
            guard let self else { return }
            self.mutateRun { $0.status(from: id, status, now: Date()) }
        }
        pairing.updatesStartReceived = { [weak self] id, request in
            self?.receiveStart(from: id, request) ?? UpdateStartResult(requestID: request.requestID, refusal: .manual)
        }
        pairing.updatesResultReceived = { [weak self] id, result in
            self?.mutateRun { $0.result(from: id, result, now: Date()) }
        }
        pairing.updatesPhoneDisconnected = { [weak self] id in
            guard let self else { return }
            self.lastSent.removeValue(forKey: id)
            self.lastSentAt.removeValue(forKey: id)
            self.mutateRun { $0.disconnected(id, now: Date()) }
        }
        // Sparkle's flow and this Mac's settings: phones hear every change, the run follows this Mac's step.
        updater.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.localChanged() }
            .store(in: &cancellables)
        restoreRun()
        localChanged()
    }

    // MARK: Status to phones

    var localStatus: PeerUpdateStatus? { updater?.localInputs(remoteStartAllowed: remoteStartAllowed).status }

    private func localChanged() {
        guard let updater, let status = localStatus else { return }
        mutateRun { $0.local(status, now: Date()) }
        if installWhenOffered || downloadWhenOffered {
            switch updater.flow {
            case let .available(offer):
                if installWhenOffered || !offer.downloaded {
                    installWhenOffered = false
                    downloadWhenOffered = false
                    updater.install()
                }
            case .ready where installWhenOffered:
                installWhenOffered = false
                updater.install()
            case .upToDate, .failed:
                installWhenOffered = false
                downloadWhenOffered = false
            default:
                break
            }
        }
        broadcastStatus()
    }

    private func broadcastStatus() {
        guard let pairing else { return }
        for phone in pairing.connectedPhones where phone.state.remoteUpdates { sendStatus(to: phone.id, force: false) }
    }

    /// Every change but progress goes out at once; progress alone at most once a second (the last one trails).
    private func sendStatus(to id: String, force: Bool) {
        guard let pairing, let status = localStatus else { return }
        let date = Date()
        if !force, let last = lastSent[id] {
            if last == status { return }
            if last.sameApartFromProgress(status), let at = lastSentAt[id], date.timeIntervalSince(at) < 1 {
                guard !trailingSend.contains(id) else { return }
                trailingSend.insert(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, 1 - date.timeIntervalSince(at))) { [weak self] in
                    self?.trailingSend.remove(id)
                    self?.sendStatus(to: id, force: false)
                }
                return
            }
        }
        if pairing.sendUpdatesStatus(status, to: id) {
            lastSent[id] = status
            lastSentAt[id] = date
        }
    }

    func setRemoteStartAllowed(_ value: Bool) {
        guard value != remoteStartAllowed else { return }
        remoteStartAllowed = value
        defaults.set(value, forKey: Self.remoteStartKey)
        broadcastStatus()
    }

    // MARK: A phone asks this Mac to update

    private func receiveStart(from id: String, _ request: UpdateStartRequest) -> UpdateStartResult {
        guard let updater else { return UpdateStartResult(requestID: request.requestID, refusal: .manual) }
        let decision = gate.decide(deviceID: id, retry: request.retry, now: Date(), allowed: remoteStartAllowed,
                                   updaterAvailable: updater.isAvailable, notApplied: updater.notApplied != nil,
                                   canStart: updater.canStartForPeer)
        switch decision {
        case .accept:
            // After the answer is on its way: the phone hears "accepted" before the first progress.
            DispatchQueue.main.async { updater.startForPeer(retry: request.retry) }
            return UpdateStartResult(requestID: request.requestID)
        case let .refuse(reason):
            return UpdateStartResult(requestID: request.requestID, refusal: reason)
        }
    }

    // MARK: Update all from this Mac

    func plan(now: Date = Date()) -> UpdatePlan {
        guard let pairing, let local = localStatus else { return UpdatePlan() }
        var phones: [UpdateAllPhone] = []
        var seen = Set<String>()
        for phone in pairing.connectedPhones {
            seen.insert(phone.id)
            phones.append(UpdateAllPhone(id: phone.id, name: phone.name, connected: true, supportsUpdates: phone.state.remoteUpdates,
                                         status: phone.state.updateStatus))
        }
        for device in pairing.trustedDevices where !seen.contains(device.id) {
            phones.append(UpdateAllPhone(id: device.id, name: device.name, connected: false, supportsUpdates: false, status: nil))
        }
        return UpdatePlan.make(local: local, localName: UpdateAllText.thisMac, phones: phones, now: now)
    }

    func display(now: Date = Date()) -> UpdateAllDisplay {
        UpdateAllDisplay(plan: plan(now: now), run: run, previewOpen: previewOpen, now: max(now, self.now))
    }

    var actions: UpdateAllActions {
        UpdateAllActions(
            openPreview: { [weak self] in self?.previewOpen = true },
            closePreview: { [weak self] in self?.previewOpen = false },
            start: { [weak self] in self?.startAll() },
            later: { [weak self] in self?.later() },
            restartNow: { [weak self] in self?.restartNow() },
            retry: { [weak self] id in self?.retry(id) },
            retryAll: { [weak self] in self?.retryAll() },
            dismiss: { [weak self] in self?.dismiss() }
        )
    }

    func startAll() {
        guard let pairing, let updater else { return }
        previewOpen = false
        let date = Date()
        guard let started = UpdateRun.start(plan: plan(now: date), now: date, newID: { UUID().uuidString.lowercased() }) else { return }
        run = started.run
        for (id, request) in started.starts {
            if !pairing.sendUpdatesStart(request, to: id) { run?.disconnected(id, now: date) }
        }
        if started.run.local != nil {
            // This Mac downloads now and installs last.
            switch updater.flow {
            case let .available(offer) where !offer.downloaded: updater.install()
            case .available, .ready, .downloading, .extracting, .installing, .checking: break
            default:
                downloadWhenOffered = true
                updater.checkForUpdates()
            }
        }
        if let status = localStatus { run?.local(status, now: date) }
        runChanged()
    }

    private func later() {
        mutateRun { $0.later(now: Date()) }
        installWhenOffered = false
        updater?.later()
    }

    private func restartNow() {
        guard var current = run, current.installNow(now: Date()) else { return }
        run = current
        runChanged()
        installLocal()
    }

    private func installLocal() {
        guard let updater else { return }
        switch updater.flow {
        case .available, .ready:
            updater.install()
        default:
            // Put off with Later: Sparkle offers the downloaded update again on a check, then it installs.
            installWhenOffered = true
            updater.checkForUpdates()
        }
    }

    private func retry(_ id: String) {
        guard let pairing, var current = run,
              let request = current.retry(id, now: Date(), newID: { UUID().uuidString.lowercased() }) else { return }
        run = current
        if !pairing.sendUpdatesStart(request, to: id) { run?.disconnected(id, now: Date()) }
        runChanged()
    }

    private func retryAll() {
        for item in run?.items ?? [] where item.canRetry { retry(item.id) }
    }

    private func dismiss() {
        run = nil
        defaults.removeObject(forKey: Self.runKey)
        stopTimer()
    }

    // MARK: Run bookkeeping

    private func mutateRun(_ change: (inout UpdateRun) -> Void) {
        guard var current = run else { return }
        change(&current)
        guard current != run else { return }
        run = current
        runChanged()
    }

    private func runChanged() {
        guard let run else { return }
        if let data = try? JSONEncoder().encode(run) { defaults.set(data, forKey: Self.runKey) }
        if run.dismissed { stopTimer() } else { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let date = Date()
        now = date
        guard var current = run else { return stopTimer() }
        let effects = current.tick(now: date)
        if current != run {
            run = current
            runChanged()
        }
        if effects.contains(.installLocal) { installLocal() }
        // A finished run keeps its card until it is closed, but needs no clock.
        if current.finished && current.countdownUntil == nil { stopTimer() }
    }

    /// After this Mac relaunched (often: Update all just installed it), the run comes back for 30 minutes.
    private func restoreRun() {
        guard let updater, let data = defaults.data(forKey: Self.runKey),
              var saved = try? JSONDecoder().decode(UpdateRun.self, from: data) else { return }
        let date = Date()
        guard !saved.dismissed, date.timeIntervalSince(saved.updatedAt) < UpdateRun.expiry else {
            defaults.removeObject(forKey: Self.runKey)
            return
        }
        saved.restored(installedApp: updater.shortVersion, installedBuild: updater.buildNumber, now: date)
        run = saved
        runChanged()
    }
}
