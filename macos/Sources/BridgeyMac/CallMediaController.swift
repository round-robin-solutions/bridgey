import Foundation

enum CallMediaMode: String, CaseIterable, Codable, Hashable, Sendable {
    case pauseThenMute = "pause_then_mute"
    case pauseOnly = "pause_only"
    case muteOnly = "mute_only"
}

enum CallMediaRestoration: String, CaseIterable, Codable, Hashable, Sendable {
    case restoreAndResume = "restore_and_resume"
    case restoreSound = "restore_sound"
    case leaveAsIs = "leave_as_is"
}

struct CallMediaPolicy: Equatable, Sendable {
    var mode: CallMediaMode = .pauseThenMute
    var restoration: CallMediaRestoration = .restoreAndResume
}

enum CallMediaReleaseReason: Equatable {
    case callsEnded, disabled, permissionLost, disconnected
}

enum CallMediaIssue: String, Hashable, Sendable {
    case permissionNeeded = "permission_needed"
    case unsupported = "unsupported"
    case callAudioProtected = "call_audio_protected"
    case changedByUser = "changed_by_user"
    case sessionGone = "session_gone"
    case commandFailed = "command_failed"
    case cancelled = "cancelled"
    case otherPlayersLimited = "other_players_limited"
    case selectiveMuteUnavailable = "selective_mute_unavailable"
}

/// Local-only identity and playback evidence. Content/position never belong in a network result.
struct CallMediaSession: Equatable, Codable, Sendable {
    var id: String
    var bundleID: String
    var contentID: String
    var playing: Bool
    var position: Int = 0
    var volume: Int? = nil
    var routeID: String = ""
    var canPause: Bool = true
    var canResume: Bool = true
    var canMute: Bool = false
    var protectedCallAudio: Bool = false
    /// Process-tap state is local resource ownership, independent of the player's real volume.
    var processMuteRouteID: String? = nil
    var processMuteToken: UUID? = nil
    var processMuteAvailable: Bool { processMuteRouteID != nil }
    /// A deliberate Stop is not an owned pause, even if the track and position still match.
    var stopped = false

    /// Playback must still be the item/position Bridgey paused, not another track or a user seek.
    func isStillPaused(from original: CallMediaSession) -> Bool {
        let difference = position.subtractingReportingOverflow(original.position)
        return isPausedSameItem(as: original) && !difference.overflow && (-1...1).contains(difference.partialValue)
    }

    func isPausedSameItem(as original: CallMediaSession) -> Bool {
        id == original.id && contentID == original.contentID && !playing && !stopped
    }

    func hasSameSoundRoute(as original: CallMediaSession) -> Bool {
        id == original.id && routeID == original.routeID
    }
}

struct CallMediaScan: Sendable {
    var sessions: [CallMediaSession]
    var issues: Set<CallMediaIssue> = []
}

enum CallMediaAction: Equatable, Sendable {
    case pause, resume, setVolume(Int)
    case muteProcess(UUID), releaseProcessMute(UUID)
}

/// Revocation is checked again on the serial platform queue immediately before a side effect.
final class CallMediaPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

@MainActor
protocol CallMediaPlatform: AnyObject {
    var requiresDurableMuteOwnership: Bool { get }
    func setLocalCallActive(_ active: Bool)
    func scan(_ completion: @escaping @MainActor (CallMediaScan) -> Void)
    func scan(permit: CallMediaPermit, _ completion: @escaping @MainActor (CallMediaScan) -> Void)
    /// Implementations revalidate process/content/route evidence before a command. Resume and
    /// volume restoration may return changedByUser rather than overwriting a later local choice.
    func command(_ action: CallMediaAction, session: CallMediaSession, permit: CallMediaPermit,
                 completion: @escaping @MainActor (Result<CallMediaSession, CallMediaIssue>) -> Void)
    /// Verification only: a restarted player may retain volume zero. It must be fixed manually,
    /// not automatically changed using a lease from the previous process.
    func soundWasReleased(_ ownership: CallMediaMutedOwnership, completion: @escaping @MainActor (Bool) -> Void)
    func observeProcessMuteRelease(_ changed: @escaping @MainActor (UUID, CallMediaIssue, Bool) -> Void)
}

extension CallMediaPlatform {
    var requiresDurableMuteOwnership: Bool { false }
    func setLocalCallActive(_ active: Bool) {}
    func observeProcessMuteRelease(_ changed: @escaping @MainActor (UUID, CallMediaIssue, Bool) -> Void) {}
    func scan(permit: CallMediaPermit, _ completion: @escaping @MainActor (CallMediaScan) -> Void) {
        guard permit.isValid else { completion(CallMediaScan(sessions: [], issues: [.cancelled])); return }
        scan(completion)
    }
    func soundWasReleased(_ ownership: CallMediaMutedOwnership, completion: @escaping @MainActor (Bool) -> Void) {
        scan { scan in
            completion(scan.sessions.contains { $0.bundleID == ownership.before.bundleID && ($0.volume ?? 0) > 0 })
        }
    }
}

extension CallMediaIssue: Error {}

@MainActor
protocol CallMediaScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
final class CallMediaMainScheduler: CallMediaScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

struct CallMediaResult: Equatable {
    var activeCalls = 0
    var paused = 0
    var muted = 0
    var pending = 0
    var restoring = false
    var issues: Set<CallMediaIssue> = []
}

struct CallMediaRecoveryItem: Identifiable, Equatable {
    let id: String
    let bundleID: String
    let originalVolume: Int
    var temporaryMute = false
    var appName: String {
        bundleID == MediaPlayer.musicBundleID ? "Music" : bundleID == MediaPlayer.spotifyBundleID ? "Spotify" : bundleID
    }
}

/// Quiet once for the no-call -> call transition. Later playback is an intentional override.
/// Only verified, owned changes can be restored after the final call; disconnect is not a call end.
@MainActor
final class CallMediaController {
    private let platform: CallMediaPlatform
    private let scheduler: CallMediaScheduler
    private let onResult: (CallMediaResult) -> Void
    private let ownershipStore: CallMediaOwnershipStore?
    private var ownershipHealthy = true
    private var recoveredOwnership = false
    private var policy = CallMediaPolicy()
    private var calls = Set<String>()
    var hasActiveCalls: Bool { !calls.isEmpty }
    private var generation = 0
    private var quietPermit = CallMediaPermit()
    private var restorePermits: [UUID: CallMediaPermit] = [:]
    private var paused: [String: CallMediaSession] = [:]
    private var pauseGenerations: [String: Int] = [:]
    private var muted: [String: CallMediaMutedOwnership] = [:]
    private var confirmedMuted = Set<String>()
    private var pending = Set<UUID>()
    private var beginScanInFlight = false
    private var queuedBeginGeneration: Int?
    private var confirming: [UUID: () -> Void] = [:]
    private var confirmationPermits: [UUID: CallMediaPermit] = [:]
    private var restoring: [String: UUID] = [:]
    private var attemptedRestore = Set<String>()
    private var unresolvedSound = Set<String>()
    private var issues = Set<CallMediaIssue>()
    private var ending: CallMediaRestoration = .restoreAndResume
    private var playbackRestorationBlocked = false
    private var forceSoundRelease = false
    private var releasedGenerations: [Int: CallMediaRestoration] = [:]
    private var muteGenerations: [String: Int] = [:]
    private var resetCompletion: ((Bool) -> Void)?
    private var cancelResetDeadline: (() -> Void)?
    private var ownershipLoadFailed = false
    private var manualSoundRelease = false
    /// Backup release permanently gives up all playback ownership dispatched before it.
    /// A later call may own new work, but cannot revive an older pause acknowledgement.
    private var autoplayVetoThroughGeneration = -1

    init(platform: CallMediaPlatform, scheduler: CallMediaScheduler? = nil,
         ownershipStore: CallMediaOwnershipStore? = nil,
         onResult: @escaping (CallMediaResult) -> Void = { _ in }) {
        self.platform = platform
        self.scheduler = scheduler ?? CallMediaMainScheduler()
        self.onResult = onResult
        // A SwiftPM/XCTest executable must never load the installed app's real recovery ledger.
        let liveStore = platform.requiresDurableMuteOwnership && CallMediaFileOwnershipStore.liveDefaultAvailable
        self.ownershipStore = ownershipStore ?? (liveStore ? CallMediaFileOwnershipStore() : nil)
        if platform.requiresDurableMuteOwnership && self.ownershipStore == nil {
            ownershipHealthy = false
            issues.insert(.unsupported)
        }
        do {
            for lease in try self.ownershipStore?.load() ?? [] { muted[lease.before.id] = lease }
            recoveredOwnership = !muted.isEmpty
        } catch { ownershipHealthy = false; ownershipLoadFailed = true; issues.insert(.commandFailed) }
        platform.observeProcessMuteRelease { [weak self] token, issue, released in
            guard let self, let id = self.muted.first(where: { $0.value.after.processMuteToken == token })?.key else { return }
            self.confirmedMuted.remove(id)
            if released { self.clearSoundOwnership(id) }
            else { self.unresolvedSound.insert(id) }
            self.record(issue)
            self.publish()
        }
    }

    var result: CallMediaResult {
        CallMediaResult(activeCalls: calls.count, paused: paused.count, muted: confirmedMuted.count,
                        pending: pending.count, restoring: !restoring.isEmpty, issues: issues)
    }

    var recoveryItems: [CallMediaRecoveryItem] {
        unresolvedSound.sorted().compactMap { id in
            muted[id].map { CallMediaRecoveryItem(id: id, bundleID: $0.before.bundleID,
                originalVolume: $0.before.volume ?? 0, temporaryMute: $0.before.processMuteAvailable) }
        }
    }

    var canRestoreSound: Bool { muted.values.contains { $0.before.processMuteAvailable } }

    /// Explicit escape hatch, including during a call. Release only Bridgey's resources, never
    /// start playback or write a player's volume. This interval must not quietly reapply them.
    func restoreSoundNow() {
        manualSoundRelease = true
        quietPermit.invalidate()
        restorePermits.values.forEach { $0.invalidate() }
        relinquishPlaybackOwnership()
        attemptedRestore.removeAll()
        restoreIfReleased()
        publish()
    }

    private func relinquishPlaybackOwnership() {
        autoplayVetoThroughGeneration = max(autoplayVetoThroughGeneration, generation)
        paused.removeAll(); pauseGenerations.removeAll()
        for epoch in Array(releasedGenerations.keys) where releasedGenerations[epoch] == .restoreAndResume {
            releasedGenerations[epoch] = .restoreSound
        }
        for (ticket, cancel) in confirming { cancel(); pending.remove(ticket) }
        confirming.removeAll()
        for (ticket, permit) in confirmationPermits { permit.invalidate(); pending.remove(ticket) }
        confirmationPermits.removeAll()
    }

    func updateCalls(_ active: Set<String>, policy: CallMediaPolicy, localCallActive: Bool = false) {
        self.policy = policy
        platform.setLocalCallActive(localCallActive)
        let wasActive = !calls.isEmpty
        calls = active
        if recoveredOwnership {
            recoveredOwnership = false
            if active.isEmpty { finish(.restoreSound); return }
        }
        if !wasActive && !active.isEmpty { begin() }
        else if wasActive && active.isEmpty { forceSoundRelease = false; finish(policy.restoration) }
        else { publish() }
    }

    /// A mode change never unexpectedly re-pauses something the person started during this call.
    func updatePolicy(_ policy: CallMediaPolicy) { self.policy = policy }

    /// A separately authorized legacy call may still be active after a new-protocol call ends.
    /// It is a restoration barrier only: it cannot initiate a new all-player quiet operation.
    func setPlaybackRestorationBlocked(_ blocked: Bool) {
        if blocked && !playbackRestorationBlocked && !forceSoundRelease {
            // A newly known call also revokes restoration already queued on the media worker.
            restorePermits.values.forEach { $0.invalidate() }
        }
        playbackRestorationBlocked = blocked
        if !blocked { restoreIfReleased() }
    }

    /// Prevent deletion of the recovery ledger until owned sound is restored. Playback is never
    /// resumed for reset, and a timeout/failure leaves its recovery evidence in place.
    func prepareForReset(_ completion: @escaping (Bool) -> Void) {
        guard resetCompletion == nil else { completion(false); return }
        if ownershipLoadFailed {
            do {
                for lease in try ownershipStore?.load() ?? [] { muted[lease.before.id] = lease }
                ownershipLoadFailed = false; ownershipHealthy = true
            } catch { completion(false); return }
        }
        resetCompletion = completion
        release(reason: .disabled)
        guard resetCompletion != nil else { return }
        cancelResetDeadline = scheduler.schedule(after: 30) { [weak self] in self?.finishReset(false) }
        checkResetReady()
    }

    /// A failed reset did not start a new call; restore its source bookkeeping without re-quieting.
    func adoptCallsWithoutQuieting(_ active: Set<String>, policy: CallMediaPolicy, localCallActive: Bool) {
        calls = active; self.policy = policy
        platform.setLocalCallActive(localCallActive)
        publish()
    }

    /// The user repaired sound in a player. Verify it before relinquishing recovery evidence;
    /// this check never plays a track or changes a player's current volume.
    func checkSoundRecovery() {
        for (id, lease) in muted where restoring[id] == nil {
            let ticket = UUID()
            let epoch = muteGenerations[id]
            restoring[id] = ticket
            platform.soundWasReleased(lease) { [weak self] released in
                guard let self else { return }
                guard self.restoring[id] == ticket else { return }
                self.restoring.removeValue(forKey: id)
                guard self.muted[id] == lease, self.muteGenerations[id] == epoch else { self.publish(); return }
                if released { self.clearSoundOwnership(id) }
                else { self.unresolvedSound.insert(id) }
                self.publish()
            }
        }
    }

    func release(reason: CallMediaReleaseReason) {
        if reason != .callsEnded {
            // A normal draft end may still have an acknowledgement pending behind a legacy
            // barrier. Later loss revokes that old interval's eligibility too, not just this epoch.
            for epoch in Array(releasedGenerations.keys) where releasedGenerations[epoch] == .restoreAndResume {
                releasedGenerations[epoch] = .restoreSound
            }
        }
        calls.removeAll()
        forceSoundRelease = reason == .disabled
        finish(reason == .callsEnded ? policy.restoration : .restoreSound)
    }

    private func begin() {
        forceSoundRelease = false
        manualSoundRelease = false
        generation += 1
        let epoch = generation
        quietPermit.invalidate()
        quietPermit = CallMediaPermit()
        restorePermits.values.forEach { $0.invalidate() }
        attemptedRestore.removeAll()
        issues.removeAll()
        queuedBeginGeneration = epoch
        publish()
    }

    /// One scan in flight and only the latest wanted generation. Outstanding command/confirmation
    /// work is bounded too, even when a test/backend returns scans before its commands settle.
    private func startLatestBeginScan() {
        guard !beginScanInFlight, let epoch = queuedBeginGeneration else { return }
        guard epoch == generation, !calls.isEmpty else { queuedBeginGeneration = nil; return }
        guard pending.count < 32 else { issues.insert(.commandFailed); return }
        queuedBeginGeneration = nil
        beginScanInFlight = true
        let ticket = UUID()
        pending.insert(ticket)
        platform.scan(permit: quietPermit) { [weak self] scan in
            guard let self else { return }
            self.beginScanInFlight = false
            self.pending.remove(ticket)
            guard self.generation == epoch, !self.calls.isEmpty else {
                self.restoreIfReleased()
                self.publish()
                return
            }
            self.issues.formUnion(scan.issues)
            // Bound platform work; a backend cannot cause unbounded command dispatch.
            if scan.sessions.count > 32 { self.issues.insert(.unsupported) }
            for session in scan.sessions.prefix(32) where session.playing {
                if session.protectedCallAudio { self.issues.insert(.callAudioProtected); continue }
                if self.paused[session.id] != nil || self.muted[session.id] != nil { continue }
                switch self.policy.mode {
                case .muteOnly: self.mute(session, epoch: epoch)
                case .pauseOnly, .pauseThenMute:
                    if session.canPause { self.pause(session, epoch: epoch) }
                    else if self.policy.mode == .pauseThenMute { self.mute(session, epoch: epoch) }
                    else { self.issues.insert(.unsupported) }
                }
            }
            self.publish()
        }
    }

    private func pause(_ original: CallMediaSession, epoch: Int) {
        let ticket = UUID()
        pending.insert(ticket)
        platform.command(.pause, session: original, permit: quietPermit) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .failure(let issue):
                self.pending.remove(ticket)
                self.record(issue)
                self.fallback(original, epoch: epoch)
                self.restoreIfReleased()
            case .success(let after):
                // The adapter confirms the observed pause. A slow/noncooperating player gets one
                // bounded recheck before selective mute, never a Play/Pause toggle or retry loop.
                if after.isPausedSameItem(as: original) { self.ownPause(after, ticket: ticket, epoch: epoch) }
                else {
                    if let released = self.releasedGenerations[epoch], released != .restoreAndResume {
                        self.pending.remove(ticket)
                        self.restoreIfReleased()
                        self.publish()
                        return
                    }
                    let permit = CallMediaPermit()
                    self.confirmationPermits[ticket] = permit
                    self.confirming[ticket] = self.scheduler.schedule(after: 0.35) { [weak self] in
                        guard let self else { return }
                        self.confirming.removeValue(forKey: ticket)
                        self.platform.scan(permit: permit) { [weak self] scan in
                            guard let self else { return }
                            self.confirmationPermits.removeValue(forKey: ticket)
                            guard permit.isValid else {
                                self.pending.remove(ticket)
                                self.publish()
                                return
                            }
                            if let current = scan.sessions.first(where: { $0.id == original.id }),
                               current.isPausedSameItem(as: original) { self.ownPause(current, ticket: ticket, epoch: epoch) }
                            else {
                                self.pending.remove(ticket)
                                self.issues.formUnion(scan.issues)
                                self.fallback(original, epoch: epoch)
                                self.restoreIfReleased()
                            }
                            self.publish()
                        }
                    }
                }
            }
            self.publish()
        }
    }

    private func ownPause(_ after: CallMediaSession, ticket: UUID, epoch: Int) {
        confirmationPermits.removeValue(forKey: ticket)
        pending.remove(ticket)
        let released: CallMediaRestoration? = releasedGenerations[epoch] ?? (epoch == generation ? nil : .restoreSound)
        if epoch > autoplayVetoThroughGeneration && released != .restoreSound && released != .leaveAsIs && paused[after.id] == nil {
            paused[after.id] = after
            pauseGenerations[after.id] = epoch
        }
        restoreIfReleased()
    }

    private func fallback(_ original: CallMediaSession, epoch: Int) {
        guard generation == epoch, !calls.isEmpty, quietPermit.isValid,
              policy.mode == .pauseThenMute else { return }
        mute(original, epoch: epoch)
    }

    private func mute(_ original: CallMediaSession, epoch: Int) {
        guard generation == epoch, !calls.isEmpty else { return }
        guard !manualSoundRelease, original.canMute, let volume = original.volume else {
            if !manualSoundRelease { issues.insert(.selectiveMuteUnavailable) }; return
        }
        guard original.processMuteAvailable || ownershipHealthy else { issues.insert(.commandFailed); return }
        // Something already silent is not Bridgey's property to unmute later.
        guard volume > 0 else { return }
        var expected = original
        let action: CallMediaAction
        if original.processMuteAvailable {
            let token = UUID()
            expected.processMuteToken = token
            action = .muteProcess(token)
        } else { expected.volume = 0; action = .setVolume(0) }
        muted[original.id] = CallMediaMutedOwnership(before: original, after: expected)
        muteGenerations[original.id] = epoch
        guard persistOwnership() else { muted.removeValue(forKey: original.id); muteGenerations.removeValue(forKey: original.id); return }
        let ticket = UUID()
        pending.insert(ticket)
        platform.command(action, session: original, permit: quietPermit) { [weak self] reply in
            guard let self else { return }
            self.pending.remove(ticket)
            if self.muteGenerations[original.id] != epoch { self.publish(); return }
            if self.releasedGenerations[epoch] == .leaveAsIs && !original.processMuteAvailable {
                self.muted.removeValue(forKey: original.id)
                self.confirmedMuted.remove(original.id)
                self.muteGenerations.removeValue(forKey: original.id)
                _ = self.persistOwnership()
                self.publish()
                return
            }
            switch reply {
            case .success(let after) where after.id == original.id &&
                (original.processMuteAvailable ? after.processMuteToken == expected.processMuteToken :
                    after.volume == 0 && after.hasSameSoundRoute(as: original)):
                self.muted[original.id] = CallMediaMutedOwnership(before: original, after: after)
                self.confirmedMuted.insert(original.id)
                _ = self.persistOwnership()
            case .success: self.issues.insert(.commandFailed)
            case .failure(let issue):
                self.record(issue)
                // Session loss may happen after the volume write reached the player. Only a
                // cancelled or superseded command proves this intent can be relinquished here.
                if issue == .cancelled || issue == .changedByUser {
                    self.muted.removeValue(forKey: original.id)
                    _ = self.persistOwnership()
                }
            }
            self.restoreIfReleased()
            self.publish()
        }
    }

    private func finish(_ behavior: CallMediaRestoration) {
        queuedBeginGeneration = nil
        if behavior != .restoreAndResume {
            relinquishPlaybackOwnership()
        }
        releasedGenerations[generation] = behavior
        if releasedGenerations.count > 64 {
            for old in releasedGenerations.keys.sorted().dropLast(64) { releasedGenerations.removeValue(forKey: old) }
        }
        generation += 1
        quietPermit.invalidate()
        restorePermits.values.forEach { $0.invalidate() }
        ending = behavior
        attemptedRestore.removeAll()
        restoreIfReleased()
        publish()
    }

    private func restoreIfReleased() {
        // User-selected manual restoration on Mac releases transient process mutes at call end,
        // leaving playback paused. The backup button may release them earlier in the interval.
        if manualSoundRelease {
            for (id, lease) in muted where lease.before.processMuteAvailable &&
                restoring[id] == nil && !attemptedRestore.contains(id) {
                if let token = lease.after.processMuteToken {
                    restore(.releaseProcessMute(token), expected: lease.after, id: id, sound: true)
                }
            }
        }
        guard calls.isEmpty else { return }
        // A legacy call cannot initiate all-player quieting, but it still keeps owned audio
        // quiet. Explicit feature disable/reset may release sound without resuming playback.
        guard !playbackRestorationBlocked || forceSoundRelease else { return }
        if ending == .leaveAsIs {
            paused.removeAll(); pauseGenerations.removeAll()
            for id in Array(muted.keys) where muted[id]?.before.processMuteAvailable != true {
                clearSoundOwnership(id)
            }
            _ = persistOwnership()
        }
        for (id, lease) in muted where restoring[id] == nil && !attemptedRestore.contains(id) {
            if let token = lease.after.processMuteToken {
                restore(.releaseProcessMute(token), expected: lease.after, id: id, sound: true)
            } else { restore(.setVolume(lease.before.volume ?? 0), expected: lease.after, id: id, sound: true) }
        }
        for (id, session) in paused where restoring[id] == nil {
            if ending == .restoreAndResume, !manualSoundRelease, session.canResume {
                if !playbackRestorationBlocked { restore(.resume, expected: session, id: id, sound: false) }
            } else { paused.removeValue(forKey: id); pauseGenerations.removeValue(forKey: id) }
        }
    }

    private func restore(_ action: CallMediaAction, expected: CallMediaSession, id: String, sound: Bool) {
        let ticket = UUID()
        let permit = CallMediaPermit()
        let lease = muted[id]
        let soundEpoch = muteGenerations[id]
        let pauseEpoch = pauseGenerations[id]
        restorePermits[ticket] = permit
        restoring[id] = ticket
        attemptedRestore.insert(id)
        platform.command(action, session: expected, permit: permit) { [weak self] reply in
            guard let self else { return }
            self.restorePermits.removeValue(forKey: ticket)
            guard self.restoring[id] == ticket else { return }
            self.restoring.removeValue(forKey: id)
            guard (sound ? self.muted[id] == lease && self.muteGenerations[id] == soundEpoch :
                self.paused[id] == expected && self.pauseGenerations[id] == pauseEpoch) else {
                self.restoreIfReleased(); self.publish(); return
            }
            if case .failure(.cancelled) = reply {
                self.attemptedRestore.remove(id)
                // A new call (or a changed release policy) owns the interval now. Keep the
                // lease until the current end behavior can be applied with a fresh permit.
                self.restoreIfReleased()
                self.publish()
                return
            }
            if sound {
                if case .success(let after) = reply,
                   (expected.processMuteToken != nil ? after.processMuteToken == nil : (after.volume ?? 0) > 0) {
                    self.clearSoundOwnership(id)
                } else if let lease {
                    self.restoring[id] = ticket
                    self.platform.soundWasReleased(lease) { [weak self] released in
                        guard let self else { return }
                        guard self.restoring[id] == ticket else { return }
                        self.restoring.removeValue(forKey: id)
                        guard self.muted[id] == lease, self.muteGenerations[id] == soundEpoch else {
                            self.restoreIfReleased(); self.publish(); return
                        }
                        if released { self.clearSoundOwnership(id) }
                        else { self.unresolvedSound.insert(id); self.confirmedMuted.remove(id) }
                        if case .failure(let issue) = reply { self.record(issue) }
                        else if !released { self.record(.commandFailed) }
                        self.restoreIfReleased()
                        self.publish()
                    }
                    return
                }
            }
            else { self.paused.removeValue(forKey: id); self.pauseGenerations.removeValue(forKey: id) }
            if case .failure(let issue) = reply { self.record(issue) }
            self.restoreIfReleased()
            self.publish()
        }
    }

    private func record(_ issue: CallMediaIssue) {
        if issue != .cancelled { issues.insert(issue) }
    }

    private func clearSoundOwnership(_ id: String) {
        if let ticket = restoring.removeValue(forKey: id) { restorePermits.removeValue(forKey: ticket)?.invalidate() }
        attemptedRestore.remove(id)
        muted.removeValue(forKey: id)
        confirmedMuted.remove(id)
        muteGenerations.removeValue(forKey: id)
        unresolvedSound.remove(id)
        _ = persistOwnership()
    }

    @discardableResult
    private func persistOwnership() -> Bool {
        do { try ownershipStore?.save(muted.values.filter { !$0.before.processMuteAvailable }); return true }
        catch { ownershipHealthy = false; issues.insert(.commandFailed); return false }
    }

    private func publish() {
        startLatestBeginScan()
        onResult(result)
        checkResetReady()
    }

    private func checkResetReady() {
        guard resetCompletion != nil, pending.isEmpty, restoring.isEmpty else { return }
        finishReset(muted.isEmpty && !ownershipLoadFailed)
    }

    private func finishReset(_ succeeded: Bool) {
        cancelResetDeadline?(); cancelResetDeadline = nil
        if !succeeded { unresolvedSound.formUnion(muted.keys) }
        let completion = resetCompletion
        resetCompletion = nil
        completion?(succeeded)
    }
}
