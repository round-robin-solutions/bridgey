import Foundation

/// Local policy and authenticated direct-peer state. The host supplies ACL/session checks and
/// encrypts the payloads; this layer never trusts a claimed origin or forwards another peer's call.
@MainActor
final class CallMediaPeers {
    struct Peer {
        var sessionID: String
        var lastSentAt = -Double.greatestFiniteMagnitude
        var sentRevision: Int?
        var lastResult: CallMediaResultPacket?
    }
    var enabled: () -> Bool = { false }
    var allowed: (String) -> Bool = { _ in false }
    var policy: () -> CallMediaPolicy = { CallMediaPolicy() }
    var send: (String, String, [String: Any]) -> Bool = { _, _, _ in false }
    var onChanged: () -> Void = {}
    private let now: () -> TimeInterval
    private let platform: CallMediaPlatform
    private let scheduler: CallMediaScheduler?
    private lazy var engine = CallMediaController(platform: platform, scheduler: scheduler) { [weak self] result in
        self?.resultChanged(result)
    }
    private var peers: [String: Peer] = [:]
    private var sources = CallMediaSources()
    private var lostSources = Set<String>()
    private var legacySources = Set<String>()
    /// One last handled snapshot per peer, at most 16 IDs; no historical call log.
    private var handledCalls: [String: Set<String>] = [:]
    private var manualCallID: String?
    private var handledManualID: String?
    private var preparingReset = false
    private var localRevision = 1
    private var lastReplies: [String: CallMediaResultPacket] = [:]
    private(set) var manualActive = false
    private(set) var localResult = CallMediaResult()
    private(set) var remoteResults: [String: CallMediaResultPacket] = [:]
    var recoveryItems: [CallMediaRecoveryItem] { engine.recoveryItems }

    init(platform: CallMediaPlatform? = nil, scheduler: CallMediaScheduler? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.platform = platform ?? CallMediaMacPlatform()
        self.scheduler = scheduler
        self.now = now
    }

    func peerReady(_ id: String, sessionID: String, permitted: Bool) {
        guard enabled(), permitted, allowed(id) else { drop(id, reason: .permissionLost); return }
        if peers[id]?.sessionID != sessionID {
            // A fresh session is not an explicit end of the old session's call.
            if peers[id] != nil { drop(id, reason: .disconnected) }
            peers[id] = Peer(sessionID: sessionID)
            remoteResults.removeValue(forKey: id)
            lastReplies.removeValue(forKey: id)
        }
        publishState(to: id, force: true)
    }

    func settingsChanged() {
        engine.updatePolicy(policy())
        if !enabled() {
            if manualActive { manualActive = false; advanceRevision() }
            peers.removeAll(); sources = CallMediaSources(); lostSources.removeAll(); handledCalls.removeAll()
            manualCallID = nil; handledManualID = nil
            lastReplies.removeAll(); remoteResults.removeAll()
            engine.release(reason: .disabled)
            onChanged()
            return
        }
        for id in Array(peers.keys) where !allowed(id) { drop(id, reason: .permissionLost) }
        reconcile(explicitEnd: false)
    }

    func setManualCall(_ active: Bool) {
        guard !preparingReset, !active || enabled(), manualActive != active else { return }
        manualActive = active
        manualCallID = active ? UUID().uuidString.lowercased() : nil
        if !active { handledManualID = nil }
        advanceRevision()
        reconcile(explicitEnd: !active)
        for id in peers.keys { publishState(to: id, force: true) }
        onChanged()
    }

    func receiveState(_ state: CallMediaStatePacket, from id: String, sessionID: String) {
        guard !preparingReset, enabled(), allowed(id), peers[id]?.sessionID == sessionID,
              sources.receive(state, peerID: id, sessionID: sessionID, now: now()) else { return }
        // Losing a source makes this ownership interval ineligible for autoplay. A replacement
        // session's empty snapshot cannot retroactively confirm the old session's call ended.
        // The interval marker clears only when that interval releases, not on another snapshot.
        reconcile(explicitEnd: state.calls.isEmpty)
        if !state.calls.isEmpty { handledCalls[id] = Set(state.calls) }
        else if !state.uncertain { handledCalls.removeValue(forKey: id) }
        sendResults()
    }

    func receiveResult(_ result: CallMediaResultPacket, from id: String, sessionID: String) {
        guard enabled(), allowed(id), let peer = peers[id], peer.sessionID == sessionID,
              peer.sentRevision == result.revision else { return }
        remoteResults[id] = result
        onChanged()
    }

    /// Reuses each session's existing 10/25-second heartbeat; no independent per-frame loop.
    func heartbeat() {
        if preparingReset {
            if manualActive { for id in peers.keys { publishState(to: id, force: false) } }
            return
        }
        let activeBefore = Set(sources.sources.filter { !$0.value.state.calls.isEmpty || $0.value.state.uncertain }.keys)
        let expired = sources.expire(now: now())
        lostSources.formUnion(expired.intersection(activeBefore))
        for id in expired { lastReplies.removeValue(forKey: id) }
        if !expired.isDisjoint(with: activeBefore) { reconcile(explicitEnd: false) }
        if manualActive { for id in peers.keys { publishState(to: id, force: false) } }
    }

    func drop(_ id: String, reason: CallMediaReleaseReason = .disconnected) {
        if reason == .permissionLost || reason == .disabled { handledCalls.removeValue(forKey: id) }
        peers.removeValue(forKey: id)
        lastReplies.removeValue(forKey: id)
        remoteResults.removeValue(forKey: id)
        let hadCalls = sources.sources[id].map { !$0.state.calls.isEmpty || $0.state.uncertain } == true
        if sources.remove(id), hadCalls {
            lostSources.insert(id)
            if !preparingReset { reconcile(explicitEnd: false, reason: reason) }
        }
        onChanged()
    }

    func handlesCalls(from id: String) -> Bool {
        enabled() && allowed(id) && peers[id] != nil
    }

    func setLegacyCallActive(_ active: Bool) { setLegacySources(active ? ["@legacy"] : []) }

    func setLegacySources(_ active: Set<String>) {
        legacySources = active
        if active.isEmpty, sources.activeCalls.isEmpty, !manualActive, !lostSources.isEmpty {
            // Discard autoplay eligibility before lifting the last legacy restoration barrier.
            engine.release(reason: .disconnected)
            lostSources.removeAll()
        }
        engine.setPlaybackRestorationBlocked(!active.isEmpty)
    }

    func legacySourceLost(_ id: String) {
        guard legacySources.contains(id) else { return }
        lostSources.insert(id)
        if sources.activeCalls.isEmpty && !manualActive { engine.release(reason: .disconnected) }
    }

    func allLegacySourcesLost() {
        for id in legacySources { legacySourceLost(id) }
    }
    func checkSoundRecovery() { engine.checkSoundRecovery() }

    func prepareForReset(_ completion: @escaping (Bool) -> Void) {
        guard !preparingReset else { completion(false); return }
        preparingReset = true
        engine.prepareForReset { [weak self] succeeded in
            guard let self else { completion(false); return }
            self.preparingReset = false
            if !succeeded {
                var active = self.sources.activeCalls
                if let call = self.manualCallID { active.insert("@local/manual/" + call) }
                self.engine.adoptCallsWithoutQuieting(active, policy: self.policy(), localCallActive: self.manualActive)
            }
            completion(succeeded)
        }
    }

    func resultSummary(_ id: String) -> String {
        guard enabled() else { return L10n.text("callMedia.off", fallback: "Quiet media during calls is off") }
        guard allowed(id) else { return L10n.text("callMedia.notAllowed", fallback: "Not enabled on both devices or not allowed here") }
        guard let result = remoteResults[id] else {
            return L10n.text("callMedia.waiting", fallback: "Waiting for this device's playback result")
        }
        let counts = String(format: L10n.text("callMedia.counts", fallback: "%d paused, %d muted"), result.paused, result.muted)
        return result.limited > 0 ? counts + " · " + L10n.text("callMedia.limited", fallback: "Some apps cannot be controlled") : counts
    }

    private func advanceRevision() {
        // At one change per second this bound is more than 68 years. Never wrap to an accepted
        // old revision; clearing local state remains possible even at the bound.
        if localRevision < 2_147_483_647 { localRevision += 1 }
    }

    private func publishState(to id: String, force: Bool) {
        guard enabled(), allowed(id), var peer = peers[id], force || now() - peer.lastSentAt >= 25 else { return }
        let packet = CallMediaStatePacket(revision: localRevision, calls: manualCallID.map { [$0] } ?? [])
        if send(id, "calls.quiet_state", packet.payload) {
            peer.lastSentAt = now(); peer.sentRevision = localRevision
            peers[id] = peer
        }
    }

    private func reconcile(explicitEnd: Bool, reason: CallMediaReleaseReason = .disconnected) {
        var active = sources.activeCalls
        if enabled(), let call = manualCallID { active.insert("@local/manual/" + call) }
        if active.isEmpty && (!explicitEnd || sources.hasUncertainty || !lostSources.isEmpty) {
            engine.release(reason: reason)
            // A disconnected/forgotten peer only blocks this ownership interval. A still-live
            // wire uncertainty remains in sources until that source is freshly observed.
            if legacySources.isEmpty { lostSources.removeAll() }
        }
        else {
            var handled = Set(handledCalls.flatMap { peer, calls in calls.map { peer + ":" + $0 } })
            if let call = handledManualID { handled.insert("@local/manual/" + call) }
            if !active.isEmpty, !engine.hasActiveCalls, active.isSubset(of: handled) {
                // A returning copy of the same call does not undo manual playback after a loss.
                engine.adoptCallsWithoutQuieting(active, policy: policy(), localCallActive: manualActive)
            } else { engine.updateCalls(active, policy: policy(), localCallActive: manualActive) }
            if manualActive { handledManualID = manualCallID }
        }
    }

    private func resultChanged(_ result: CallMediaResult) {
        var observed = result
        if sources.hasUncertainty || !lostSources.isEmpty { observed.issues.insert(.cancelled) }
        localResult = observed
        sendResults()
        onChanged()
    }

    private func sendResults() {
        for (id, source) in sources.sources {
            guard let peer = peers[id], peer.sessionID == source.sessionID, allowed(id) else { continue }
            let result = CallMediaResultPacket(revision: source.state.revision, result: localResult)
            if lastReplies[id] != result, send(id, "calls.quiet_result", result.payload) { lastReplies[id] = result }
        }
    }
}
