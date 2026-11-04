package dev.bridgey.android.media

import org.json.JSONObject

data class CallQuietPeer(val deviceId: String, val sessionId: String)

/** Main-thread, direct-peer lease state. Transport validates crypto, replay and the current ACL. */
class CallQuietHub(
    private val effects: CallQuietEffects,
    private val scheduler: CallMediaScheduler,
    private val now: () -> Long,
    private val enabled: () -> Boolean,
    private val policy: () -> CallMediaPolicy,
    private val peers: () -> List<CallQuietPeer>,
    private val send: (CallQuietPeer, String, JSONObject) -> Boolean,
    private val connectedSession: (String) -> String? = { id -> peers().firstOrNull { it.deviceId == id }?.sessionId },
    private val resultsChanged: (Map<String, CallQuietResult>) -> Unit = {},
) {
    private data class Source(val session: String, val state: CallQuietState, val seen: Long)
    private data class Sent(val session: String, val revision: Int, val at: Long)
    private val sources = linkedMapOf<String, Source>()
    /** Keep the per-session revision fence after a lease expires; expiry is not a new session. */
    private val versions = linkedMapOf<String, Source>()
    private val sent = linkedMapOf<String, Sent>()
    private val results = linkedMapOf<String, CallQuietResult>()
    private val acknowledgements = linkedMapOf<String, CallQuietResult>()
    /** Loss of one source cannot become a clean end merely because another source later ends. */
    private val lostSources = mutableSetOf<String>()
    private val handled = linkedSetOf<String>()
    private var effectCalls = emptySet<String>()
    private var local = emptySet<String>()
    private var localUncertain = false
    private var revision = 1
    private var lastEffects = CallMediaResult()
    private var cancelTimer: (() -> Unit)? = null

    fun localCallsChanged(calls: Set<String>, uncertain: Boolean = false) {
        require(calls.size <= 16 && calls.all { it.matches(Regex("[A-Za-z0-9_-]{1,64}")) })
        if (calls == local && uncertain == localUncertain) return
        if (!uncertain) clearVerifiedEnded("local/", calls)
        local = calls.toSet()
        localUncertain = uncertain
        revision = if (revision == Int.MAX_VALUE) 1 else revision + 1
        if (enabled()) {
            updateEffects(CallMediaReleaseReason.CALLS_ENDED)
            peers().forEach { publish(it, force = true) }
        }
        armTimer()
    }

    fun policyChanged() {
        effects.updatePolicy(policy())
        if (!enabled()) {
            sources.clear(); sent.clear(); acknowledgements.clear(); results.clear(); lostSources.clear(); handled.clear(); effectCalls = emptySet()
            resultsChanged(emptyMap())
            effects.release(CallMediaReleaseReason.DISABLED)
        } else peersChanged()
        armTimer()
    }

    /** Call after local/remote feature maps or session readiness changes, never a selected-peer change. */
    fun peersChanged() {
        val current = if (enabled()) peers().associateBy(CallQuietPeer::deviceId) else emptyMap()
        val removed = sources.filter { (id, source) -> current[id]?.sessionId != source.session }.keys
        removed.forEach { id ->
            sources.remove(id)?.let {
                if (it.state.calls.isNotEmpty() || it.state.uncertain) lostSources += id
                if (connectedSession(id) == it.session) handled.removeAll { key -> key.startsWith("$id/") }
            }
            acknowledgements.remove(id)
        }
        sent.keys.filter { current[it]?.sessionId != sent[it]?.session }.toList().forEach { sent.remove(it); results.remove(it) }
        if (removed.isNotEmpty()) updateEffects(CallMediaReleaseReason.PERMISSION_LOST)
        if (enabled()) current.values.forEach { publish(it, force = false) }
        resultsChanged(results.toMap())
        armTimer()
    }

    fun disconnected(deviceId: String) {
        val had = sources.remove(deviceId)
        if (had != null && (had.state.calls.isNotEmpty() || had.state.uncertain)) lostSources += deviceId
        sent.remove(deviceId); acknowledgements.remove(deviceId); results.remove(deviceId); versions.remove(deviceId)
        if (had != null) updateEffects(CallMediaReleaseReason.DISCONNECTED)
        resultsChanged(results.toMap())
        armTimer()
    }

    fun receiveState(peer: CallQuietPeer, state: CallQuietState): Boolean {
        if (!permitted(peer)) return false
        val previous = sources[peer.deviceId]
        if (previous != null && previous.session != peer.sessionId) {
            sources.remove(peer.deviceId); acknowledgements.remove(peer.deviceId)
            if (previous.state.calls.isNotEmpty() || previous.state.uncertain) lostSources += peer.deviceId
            updateEffects(CallMediaReleaseReason.DISCONNECTED)
        }
        val old = versions[peer.deviceId]?.takeIf { it.session == peer.sessionId }
        if (old != null && (state.revision < old.state.revision ||
                state.revision == old.state.revision && (state.calls != old.state.calls || state.uncertain != old.state.uncertain))) return false
        sources[peer.deviceId] = Source(peer.sessionId, state, now())
        versions[peer.deviceId] = sources.getValue(peer.deviceId)
        if (!state.uncertain) clearVerifiedEnded("${peer.deviceId}/", state.calls)
        // Loss disqualifies the whole current ownership interval from autoplay. A returning
        // session cannot retroactively confirm the old call ended while another call remains.
        updateEffects(CallMediaReleaseReason.CALLS_ENDED)
        acknowledge(peer, state.revision)
        armTimer()
        return true
    }

    fun receiveResult(peer: CallQuietPeer, result: CallQuietResult): Boolean {
        if (!permitted(peer)) return false
        val request = sent[peer.deviceId] ?: return false
        if (request.session != peer.sessionId || request.revision != result.revision) return false
        results[peer.deviceId] = result
        resultsChanged(results.toMap())
        return true
    }

    fun effectsChanged(result: CallMediaResult) {
        lastEffects = result
        sources.toMap().forEach { (id, source) ->
            val peer = CallQuietPeer(id, source.session)
            if (permitted(peer)) acknowledge(peer, source.state.revision)
        }
    }

    fun stop() {
        cancelTimer?.invoke(); cancelTimer = null
        local = emptySet(); localUncertain = false; sources.clear(); versions.clear(); sent.clear(); acknowledgements.clear(); results.clear(); lostSources.clear(); handled.clear(); effectCalls = emptySet()
        effects.release(CallMediaReleaseReason.DISABLED)
        resultsChanged(emptyMap())
    }

    private fun permitted(peer: CallQuietPeer): Boolean = enabled() && peers().any { it == peer }

    private fun publish(peer: CallQuietPeer, force: Boolean) {
        if (!permitted(peer)) return
        val old = sent[peer.deviceId]
        if (!force && old?.session == peer.sessionId && old.revision == revision) return
        if (send(peer, "calls.quiet_state", CallQuietState(revision, local, localUncertain).encode())) {
            if (old == null || old.revision != revision || old.session != peer.sessionId) {
                if (results.remove(peer.deviceId) != null) resultsChanged(results.toMap())
            }
            sent[peer.deviceId] = Sent(peer.sessionId, revision, now())
        }
    }

    private fun acknowledge(peer: CallQuietPeer, revision: Int) {
        if (lastEffects.phase == CallMediaPhase.PENDING) return
        val result = lastEffects.wireResult(revision)
        if (acknowledgements[peer.deviceId] == result) return
        if (send(peer, "calls.quiet_result", result.encode())) acknowledgements[peer.deviceId] = result
    }

    private fun updateEffects(reason: CallMediaReleaseReason) {
        val active = buildSet {
            local.forEach { add("local/$it") }
            sources.forEach { (device, source) -> source.state.calls.forEach { add("$device/$it") } }
        }
        val uncertain = localUncertain || sources.values.any { it.state.uncertain } || lostSources.isNotEmpty()
        if (active.isEmpty() && (reason != CallMediaReleaseReason.CALLS_ENDED || uncertain))
            effects.release(if (reason == CallMediaReleaseReason.CALLS_ENDED && uncertain) CallMediaReleaseReason.DISCONNECTED else reason)
        else if (effectCalls.isEmpty() && active.isNotEmpty() && active.all(handled::contains))
            effects.adoptCalls(active, policy(), local.isNotEmpty())
        else effects.updateCalls(active, policy(), local.isNotEmpty())
        effectCalls = active
        handled += active
        while (handled.size > 512) handled.remove(handled.firstOrNull { it !in active } ?: handled.first())
        if (active.isEmpty()) lostSources.clear()
    }

    private fun clearVerifiedEnded(prefix: String, calls: Set<String>) {
        handled.removeAll { it.startsWith(prefix) && it.removePrefix(prefix) !in calls }
    }

    private fun armTimer() {
        cancelTimer?.invoke(); cancelTimer = null
        if (!enabled()) return
        val instant = now()
        val expiry = sources.values.filter { it.state.calls.isNotEmpty() || it.state.uncertain }.minOfOrNull { it.seen + CALL_QUIET_EXPIRE_MS }
        val renewal = if ((local.isNotEmpty() || localUncertain) && peers().isNotEmpty())
            peers().minOf { (sent[it.deviceId]?.at ?: instant) + CALL_QUIET_RENEW_MS } else null
        val at = listOfNotNull(expiry, renewal).minOrNull() ?: return
        cancelTimer = scheduler.schedule((at - instant).coerceAtLeast(1)) {
            cancelTimer = null
            tick()
        }
    }

    private fun tick() {
        val instant = now()
        val expired = sources.filter { (it.value.state.calls.isNotEmpty() || it.value.state.uncertain) && instant - it.value.seen >= CALL_QUIET_EXPIRE_MS }.keys
        expired.forEach { sources.remove(it); acknowledgements.remove(it); lostSources += it }
        if (expired.isNotEmpty()) updateEffects(CallMediaReleaseReason.DISCONNECTED)
        if (local.isNotEmpty() || localUncertain) peers().forEach { peer ->
            if (instant - (sent[peer.deviceId]?.at ?: Long.MIN_VALUE / 2) >= CALL_QUIET_RENEW_MS) publish(peer, force = true)
        }
        armTimer()
    }
}
