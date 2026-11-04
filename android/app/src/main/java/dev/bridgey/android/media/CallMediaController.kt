package dev.bridgey.android.media

enum class CallMediaMode(val key: String) {
    PAUSE_THEN_MUTE("pause_then_mute"),
    PAUSE_ONLY("pause_only"),
    MUTE_ONLY("mute_only"),
}

enum class CallMediaRestoration(val key: String) {
    RESTORE_AND_RESUME("restore_and_resume"),
    RESTORE_SOUND("restore_sound"),
    LEAVE_AS_IS("leave_as_is"),
}

/** Enablement and authenticated call-source grants are deliberately outside the local engine. */
data class CallMediaPolicy(
    val mode: CallMediaMode = CallMediaMode.PAUSE_THEN_MUTE,
    val restoration: CallMediaRestoration = CallMediaRestoration.RESTORE_AND_RESUME,
)

enum class CallMediaPlayback { PLAYING, PAUSED, STOPPED, OTHER }

/** An opaque, process-local session identity; never a package name or media title in results. */
data class CallMediaSession(
    val id: String,
    val playback: CallMediaPlayback,
    val canPause: Boolean,
    val canPlay: Boolean,
    val mediaOrGame: Boolean,
    /** Changes when observable playback state/position changes, including a manual seek while paused. */
    val revision: Long,
    /** A phone media-stream mute cannot silence a remote renderer such as a Cast device. */
    val localPlayback: Boolean = true,
    /** Stable content identity hashed locally; null means automatic restoration cannot be verified. */
    val contentId: String? = null,
    val positionMs: Long = 0,
    /** Monotonic time represented by positionMs; paused samples keep the player's update time. */
    val positionTimeMs: Long = 0,
    val playbackSpeed: Float = 0f,
)

internal fun callMediaPosition(position: Long, speed: Float, updatedAt: Long, capturedAt: Long, playing: Boolean): Long {
    if (position < 0) return -1
    if (!playing) return position
    if (!speed.isFinite() || updatedAt < 0 || capturedAt < updatedAt) return -1
    val projected = position.toDouble() + (capturedAt - updatedAt).toDouble() * speed.toDouble()
    return if (projected.isFinite()) projected.coerceIn(0.0, Long.MAX_VALUE.toDouble()).toLong() else -1
}

enum class CallMediaAvailability { AVAILABLE, PERMISSION_NEEDED, UNAVAILABLE }

/** Exact media-stream state used for compare-before-restore; never the master or voice-call stream. */
data class CallMediaMusicState(
    val volume: Int,
    val muted: Boolean,
    val route: String,
    val revision: Long,
    val active: Boolean,
    val safeToMute: Boolean,
    val protectedCallAudio: Boolean = false,
)

data class CallMediaSnapshot(
    val availability: CallMediaAvailability,
    val sessions: List<CallMediaSession> = emptyList(),
    val music: CallMediaMusicState? = null,
    /** Public session enumeration cannot establish whether arbitrary non-session apps are quiet. */
    val truncated: Boolean = false,
)

interface CallMediaPlatform {
    /** All calls/callbacks are serialized on the caller's main thread. May throw SecurityException. */
    fun observe(changed: () -> Unit): () -> Unit
    fun snapshot(): CallMediaSnapshot
    fun pause(sessionId: String): Boolean
    fun play(sessionId: String): Boolean
    /** Returns the observed owned state only when a mute was actually applied. */
    fun muteMusic(expected: CallMediaMusicState): CallMediaMusicState?
    /** Restores only if the stream still exactly matches this feature's owned state. */
    fun restoreMusic(owned: CallMediaMusicState, previous: CallMediaMusicState): Boolean
    /** Forget durable ownership after a manual change or an explicit leave-as-is choice. */
    fun abandonMusic(owned: CallMediaMusicState, explicit: Boolean = false) {}
}

fun interface CallMediaScheduler {
    /** The callback is asynchronous, including when delayMs is zero. Returns a cancellation. */
    fun schedule(delayMs: Long, task: () -> Unit): () -> Unit
}

enum class CallMediaReason {
    PERMISSION_NEEDED, PLATFORM_UNAVAILABLE, CALL_AUDIO_PROTECTED, PAUSE_UNSUPPORTED,
    PAUSE_UNCONFIRMED, MUTE_UNAVAILABLE, SESSION_LIMIT, MANUAL_PLAYBACK, STATE_CHANGED,
    RESTORE_UNVERIFIED, UNEXPOSED_PLAYBACK,
}

enum class CallMediaPhase { IDLE, PENDING, APPLIED, PARTIAL, UNAVAILABLE }

data class CallMediaResult(
    val phase: CallMediaPhase = CallMediaPhase.IDLE,
    val paused: Int = 0,
    /** A media-stream mute, not a claim that every application on the device is silent. */
    val muted: Boolean = false,
    val pending: Int = 0,
    val unsupported: Int = 0,
    val reasons: Set<CallMediaReason> = emptySet(),
)

/** Only a confirmed last-call end may automatically resume playback. */
enum class CallMediaReleaseReason { CALLS_ENDED, DISABLED, DISCONNECTED, PERMISSION_LOST, SHUTDOWN }

interface CallQuietEffects {
    fun updateCalls(active: Set<String>, policy: CallMediaPolicy, localCallActive: Boolean)
    fun updatePolicy(policy: CallMediaPolicy)
    fun release(reason: CallMediaReleaseReason)
    /** Returning state for an already-handled call must not repeat a quiet-once action. */
    fun adoptCalls(active: Set<String>, policy: CallMediaPolicy, localCallActive: Boolean)
}

/**
 * Quiet once for one overlapping-call interval. Newly started/manual playback stays allowed.
 * Holds only session/stream operation ownership in memory; no media content or caller data.
 */
class CallMediaController(
    private val platform: CallMediaPlatform,
    private val scheduler: CallMediaScheduler,
    private val pauseConfirmationMs: Long = 750,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val onResult: (CallMediaResult) -> Unit = {},
) : CallQuietEffects {
    private data class Pause(val initial: CallMediaSession, val requestedAt: Long, var paused: CallMediaSession? = null)
    private data class Mute(val previous: CallMediaMusicState, val owned: CallMediaMusicState)

    private var calls = emptySet<String>()
    private var policy = CallMediaPolicy()
    private var localCallActive = false
    private var stopObserving: (() -> Unit)? = null
    private var cancelConfirmation: (() -> Unit)? = null
    private var cancelRefresh: (() -> Unit)? = null
    private var cancelSettling: (() -> Unit)? = null
    private var epoch = 0L
    private var initialPlaying = emptySet<String>()
    private val observedPlayback = mutableMapOf<String, CallMediaPlayback>()
    private var lastMusicActive: Boolean? = null
    private val pauses = linkedMapOf<String, Pause>()
    private val settling = linkedMapOf<String, Pause>()
    private var mute: Mute? = null
    private var confirmationFinished = false
    private var quietFinished = false
    private var quietMode = CallMediaMode.PAUSE_THEN_MUTE
    private var initialUnknownMusic = false
    private var manualPlayback = false
    private var unsupported = 0
    private val reasons = linkedSetOf<CallMediaReason>()
    var result: CallMediaResult = CallMediaResult()
        private set

    init { require(pauseConfirmationMs in 1..5_000) }

    /** localCallActive must describe a real local call, not merely the remote call set. */
    override fun updateCalls(active: Set<String>, policy: CallMediaPolicy, localCallActive: Boolean) {
        this.policy = policy
        this.localCallActive = localCallActive
        if (active.isEmpty()) {
            if (calls.isNotEmpty()) release(CallMediaReleaseReason.CALLS_ENDED)
            return
        }
        val starting = calls.isEmpty()
        calls = active.toSet()
        if (starting) begin()
        else {
            // Snapshot/lease refreshes and overlapping calls do not quiet manually restarted media.
            reconcile()
        }
    }

    /** A setting change affects later restoration but never repeats a quiet-once operation. */
    override fun updatePolicy(policy: CallMediaPolicy) {
        this.policy = policy
        if (settling.isNotEmpty() && policy.restoration != CallMediaRestoration.RESTORE_AND_RESUME) finishSettling()
    }

    override fun adoptCalls(active: Set<String>, policy: CallMediaPolicy, localCallActive: Boolean) {
        if (calls.isNotEmpty() || active.isEmpty()) { updateCalls(active, policy, localCallActive); return }
        finishSettling()
        this.policy = policy
        this.localCallActive = localCallActive
        calls = active.toSet()
        pauses.clear(); mute = null
        unsupported = 0; initialPlaying = emptySet()
        confirmationFinished = true; quietFinished = true; manualPlayback = true
        reasons.clear(); reasons += CallMediaReason.MANUAL_PLAYBACK
        publish(CallMediaResult(CallMediaPhase.APPLIED, reasons = reasons.toSet()))
    }

    override fun release(reason: CallMediaReleaseReason) {
        cancelConfirmation?.invoke(); cancelConfirmation = null
        cancelRefresh?.invoke(); cancelRefresh = null
        cancelSettling?.invoke(); cancelSettling = null
        settling.clear()
        val current = safeSnapshot()
        if (reason != CallMediaReleaseReason.CALLS_ENDED || policy.restoration != CallMediaRestoration.LEAVE_AS_IS) restoreOwnedSound()
        else mute?.let { runCatching { platform.abandonMusic(it.owned, explicit = true) } }
        if (reason == CallMediaReleaseReason.CALLS_ENDED &&
            policy.restoration == CallMediaRestoration.RESTORE_AND_RESUME &&
            current.availability == CallMediaAvailability.AVAILABLE
        ) {
            val sessions = current.sessions.associateBy(CallMediaSession::id)
            pauses.forEach { (id, owned) ->
                val paused = owned.paused
                val snapshot = sessions[id]
                if (snapshot != null && isOurPausedContent(owned, snapshot) && (paused == null || snapshot == paused)) {
                    runCatching { platform.play(id) }
                } else if (paused == null && snapshot != null && owned.initial.contentId != null && owned.initial.canPlay &&
                    snapshot.contentId == owned.initial.contentId && snapshot.playback == CallMediaPlayback.PLAYING &&
                    now() < owned.requestedAt + pauseConfirmationMs
                ) {
                    settling[id] = owned
                }
            }
        }
        calls = emptySet()
        pauses.clear()
        mute = null
        initialPlaying = emptySet()
        observedPlayback.clear(); lastMusicActive = null
        if (settling.isEmpty()) finishSettling()
        else {
            val at = settling.values.maxOf { it.requestedAt + pauseConfirmationMs }
            cancelSettling = scheduler.schedule((at - now()).coerceAtLeast(1)) { settleLatePauses(final = true) }
        }
        publish(CallMediaResult())
    }

    private fun begin() {
        finishSettling()
        epoch += 1
        pauses.clear(); reasons.clear(); unsupported = 0
        mute = null; manualPlayback = false; confirmationFinished = false; quietFinished = false
        quietMode = policy.mode
        val observing = epoch
        try {
            stopObserving = platform.observe { queueRefresh(observing) }
        } catch (_: SecurityException) {
            unavailable(CallMediaReason.PERMISSION_NEEDED)
            return
        } catch (_: RuntimeException) {
            unavailable(CallMediaReason.PLATFORM_UNAVAILABLE)
            return
        }
        val snapshot = safeSnapshot()
        if (!available(snapshot)) return
        if (snapshot.truncated) reasons += CallMediaReason.SESSION_LIMIT
        val playing = snapshot.sessions.filter { it.playback == CallMediaPlayback.PLAYING }
        initialPlaying = playing.mapTo(mutableSetOf(), CallMediaSession::id)
        observedPlayback.clear()
        playing.forEach { observedPlayback[it.id] = it.playback }
        lastMusicActive = snapshot.music?.active
        initialUnknownMusic = playing.isEmpty() && snapshot.music?.active == true
        playing.filterNot(CallMediaSession::mediaOrGame).forEach { _ ->
            unsupported += 1; reasons += CallMediaReason.CALL_AUDIO_PROTECTED
        }
        if (quietMode != CallMediaMode.MUTE_ONLY) {
            playing.filter(CallMediaSession::mediaOrGame).forEach { session ->
                if (!session.canPause) {
                    reasons += CallMediaReason.PAUSE_UNSUPPORTED
                } else {
                    pauses[session.id] = Pause(session, now())
                    if (runCatching { platform.pause(session.id) }.getOrDefault(false).not()) {
                        pauses.remove(session.id)
                        reasons += CallMediaReason.PAUSE_UNSUPPORTED
                    }
                }
            }
        }
        if (pauses.isEmpty()) {
            confirmationFinished = true
            finishQuieting(snapshot)
        } else {
            cancelConfirmation = scheduler.schedule(pauseConfirmationMs) {
                if (epoch != observing || calls.isEmpty()) return@schedule
                cancelConfirmation = null
                confirmationFinished = true
                reconcile()
            }
            reconcile()
        }
    }

    private fun queueRefresh(observing: Long) {
        if (calls.isEmpty() && settling.isEmpty() || epoch != observing || cancelRefresh != null) return
        cancelRefresh = scheduler.schedule(0) {
            cancelRefresh = null
            if (epoch == observing) {
                if (calls.isNotEmpty()) reconcile() else if (settling.isNotEmpty()) settleLatePauses()
            }
        }
    }

    private fun reconcile() {
        if (calls.isEmpty()) return
        val snapshot = safeSnapshot()
        if (!available(snapshot)) {
            // Permission/capability loss never gives permission to autoplay later.
            pauses.clear()
            restoreOwnedSound()
            cancelConfirmation?.invoke(); cancelConfirmation = null
            return
        }
        val sessions = snapshot.sessions.associateBy(CallMediaSession::id)
        for (id in initialPlaying) {
            val current = sessions[id]?.playback ?: continue
            val previous = observedPlayback.put(id, current)
            if (previous != null && previous != CallMediaPlayback.PLAYING && current == CallMediaPlayback.PLAYING) {
                manualPlayback = true
            }
        }
        if (quietFinished && lastMusicActive == false && snapshot.music?.active == true) manualPlayback = true
        lastMusicActive = snapshot.music?.active
        val iterator = pauses.iterator()
        while (iterator.hasNext()) {
            val (_, owned) = iterator.next()
            val now = sessions[owned.initial.id]
            if (owned.paused == null) {
                when {
                    now == null || !now.mediaOrGame -> iterator.remove()
                    now.contentId != owned.initial.contentId -> {
                        iterator.remove(); manualPlayback = true; reasons += CallMediaReason.STATE_CHANGED
                    }
                    now.playback == CallMediaPlayback.PAUSED -> owned.paused = now
                    now.playback == CallMediaPlayback.STOPPED -> iterator.remove()
                    confirmationFinished -> { iterator.remove(); reasons += CallMediaReason.PAUSE_UNCONFIRMED }
                }
            } else if (now != owned.paused) {
                // A seek, stop, session change or manual resume gives ownership back to the person.
                if (now?.playback == CallMediaPlayback.PLAYING) manualPlayback = true
                iterator.remove()
            }
        }
        if (snapshot.sessions.any { it.id !in initialPlaying && it.playback == CallMediaPlayback.PLAYING }) {
            manualPlayback = true
        }
        mute?.let { owned ->
            if (!ownsMusic(snapshot.music, owned.owned)) {
                // Do not restore a volume/output choice made after Bridgey's change, even if it
                // later returns to its original value. Forgetting the lease is irreversible.
                runCatching { platform.abandonMusic(owned.owned) }
                mute = null
                reasons += CallMediaReason.STATE_CHANGED
            } else if (manualPlayback || localCallActive || snapshot.music?.safeToMute != true) {
                restoreOwnedSound()
            }
        }
        if (manualPlayback) reasons += CallMediaReason.MANUAL_PLAYBACK
        if (!confirmationFinished && pauses.values.none { it.paused == null }) {
            cancelConfirmation?.invoke(); cancelConfirmation = null
            confirmationFinished = true
        }
        if (confirmationFinished) finishQuieting(snapshot)
        else publishCurrent()
    }

    private fun finishQuieting(snapshot: CallMediaSnapshot) {
        val stillPlaying = snapshot.sessions.filter {
            it.id in initialPlaying && it.mediaOrGame && it.playback == CallMediaPlayback.PLAYING
        }
        val unknownPlaying = initialUnknownMusic && snapshot.music?.active == true
        val needsMute = quietMode != CallMediaMode.PAUSE_ONLY && (stillPlaying.any(CallMediaSession::localPlayback) || unknownPlaying)
        if (!quietFinished && needsMute && mute == null && !manualPlayback && CallMediaReason.STATE_CHANGED !in reasons) {
            val before = snapshot.music
            if (before != null && !before.muted && before.volume > 0 && before.safeToMute && !localCallActive &&
                !snapshot.truncated && snapshot.sessions.none { it.playback == CallMediaPlayback.PLAYING && !it.mediaOrGame }
            ) {
                val after = runCatching { platform.muteMusic(before) }.getOrNull()
                if (after != null) mute = Mute(before, after)
                else reasons += CallMediaReason.MUTE_UNAVAILABLE
            } else if (before == null || !before.muted && before.volume > 0) {
                reasons += if (localCallActive || before?.protectedCallAudio == true) CallMediaReason.CALL_AUDIO_PROTECTED
                else CallMediaReason.MUTE_UNAVAILABLE
            }
        }
        quietFinished = true
        val localMuted = mute != null || snapshot.music?.let { it.muted || it.volume == 0 } == true
        val residualUnexposed = !initialUnknownMusic && snapshot.music?.active == true &&
            stillPlaying.none(CallMediaSession::localPlayback) && !manualPlayback && !localMuted
        if (residualUnexposed) reasons += CallMediaReason.UNEXPOSED_PLAYBACK
        val unquiet = stillPlaying.count { !it.localPlayback || !localMuted } +
            if ((unknownPlaying || residualUnexposed) && !localMuted) 1 else 0
        publishCurrent(unquiet)
    }

    private fun restoreOwnedSound() {
        val owned = mute ?: return
        mute = null
        runCatching { platform.restoreMusic(owned.owned, owned.previous) }
    }

    private fun isOurPausedContent(owned: Pause, current: CallMediaSession): Boolean {
        if (current.playback != CallMediaPlayback.PAUSED || !current.canPlay || current.contentId == null ||
            current.contentId != owned.initial.contentId || current.positionMs < 0) return false
        val expected = callMediaPosition(owned.initial.positionMs, owned.initial.playbackSpeed,
            owned.initial.positionTimeMs, current.positionTimeMs, playing = true)
        return expected >= 0 && kotlin.math.abs(current.positionMs.toDouble() - expected.toDouble()) <= 2_000.0
    }

    private fun settleLatePauses(final: Boolean = false) {
        if (calls.isNotEmpty() || policy.restoration != CallMediaRestoration.RESTORE_AND_RESUME) { finishSettling(); return }
        val snapshot = safeSnapshot()
        if (snapshot.availability != CallMediaAvailability.AVAILABLE) { finishSettling(); return }
        val current = snapshot.sessions.associateBy(CallMediaSession::id)
        val iterator = settling.iterator()
        while (iterator.hasNext()) {
            val (id, owned) = iterator.next()
            val item = current[id]
            if (item == null || item.contentId != owned.initial.contentId || item.playback == CallMediaPlayback.STOPPED) iterator.remove()
            else if (isOurPausedContent(owned, item)) {
                iterator.remove()
                runCatching { platform.play(id) }
            } else if (final || now() >= owned.requestedAt + pauseConfirmationMs) iterator.remove()
        }
        if (settling.isEmpty()) finishSettling()
    }

    private fun finishSettling() {
        epoch += 1
        cancelSettling?.invoke(); cancelSettling = null
        cancelRefresh?.invoke(); cancelRefresh = null
        settling.clear()
        stopObserving?.let { runCatching(it) }; stopObserving = null
    }

    private fun ownsMusic(now: CallMediaMusicState?, owned: CallMediaMusicState): Boolean = now != null &&
        now.volume == owned.volume && now.muted == owned.muted && now.route == owned.route && now.revision == owned.revision

    private fun safeSnapshot(): CallMediaSnapshot = try { platform.snapshot() }
    catch (_: SecurityException) { CallMediaSnapshot(CallMediaAvailability.PERMISSION_NEEDED) }
    catch (_: RuntimeException) { CallMediaSnapshot(CallMediaAvailability.UNAVAILABLE) }

    private fun available(snapshot: CallMediaSnapshot): Boolean = when (snapshot.availability) {
        CallMediaAvailability.AVAILABLE -> true
        CallMediaAvailability.PERMISSION_NEEDED -> { unavailable(CallMediaReason.PERMISSION_NEEDED); false }
        CallMediaAvailability.UNAVAILABLE -> { unavailable(CallMediaReason.PLATFORM_UNAVAILABLE); false }
    }

    private fun unavailable(reason: CallMediaReason) {
        reasons += reason
        publish(CallMediaResult(CallMediaPhase.UNAVAILABLE, reasons = reasons.toSet()))
    }

    private fun publishCurrent(unquiet: Int = 0) {
        val pending = pauses.values.count { it.paused == null }
        val restoreLimited = if (policy.restoration == CallMediaRestoration.RESTORE_AND_RESUME)
            pauses.values.count { it.paused != null && (it.initial.contentId == null || it.paused?.contentId == null ||
                it.initial.positionMs < 0 || (it.paused?.positionMs ?: -1) < 0) } else 0
        val failures = unsupported + unquiet + restoreLimited
        val incomplete = failures > 0 || reasons.any {
            it == CallMediaReason.SESSION_LIMIT || it == CallMediaReason.MUTE_UNAVAILABLE || it == CallMediaReason.CALL_AUDIO_PROTECTED
        }
        publish(CallMediaResult(
            phase = if (pending > 0) CallMediaPhase.PENDING else if (incomplete) CallMediaPhase.PARTIAL else CallMediaPhase.APPLIED,
            paused = pauses.values.count { it.paused != null },
            muted = mute != null,
            pending = pending,
            unsupported = failures,
            reasons = reasons.toSet() + if (restoreLimited > 0) setOf(CallMediaReason.RESTORE_UNVERIFIED) else emptySet(),
        ))
    }

    private fun publish(value: CallMediaResult) {
        if (result == value) return
        result = value
        onResult(value)
    }
}
