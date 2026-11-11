package dev.bridgey.android.sharing

import dev.bridgey.android.routing.ObservedPresence

data class ShareMac(
    val id: String,
    val name: String,
    val sessionId: String?,
    val allowed: Boolean,
    val presence: ObservedPresence? = null,
) {
    val eligible: Boolean get() = sessionId != null && allowed
}

/** Caller supplies trusted Macs only. No wall clock or selected-device preference is used. */
fun shareDestination(macs: List<ShareMac>, lastShared: String?, now: Long): String? {
    val eligible = macs.filter { it.eligible }
    val active = eligible.mapNotNull { mac -> mac.presence?.activeAge(now)?.let { mac.id to it } }
        .sortedWith(compareBy<Pair<String, Long>> { it.second }.thenBy { it.first }).firstOrNull()
    return active?.first ?: eligible.firstOrNull { it.id == lastShared }?.id ?: eligible.singleOrNull()?.id
}

enum class SharePhase { CHOOSING, GRACE, SENDING, SUCCEEDED, PARKED, FAILED, CANCELLED }
data class ShareFlow(
    val phase: SharePhase,
    val target: String? = null,
    val sessionId: String? = null,
    val message: String? = null,
) {
    companion object {
        fun begin(macs: List<ShareMac>, lastShared: String?, alwaysAsk: Boolean, now: Long): ShareFlow {
            val suggestion = shareDestination(macs, lastShared, now)
            val mac = macs.firstOrNull { it.id == suggestion }
            return ShareFlow(if (mac != null && !alwaysAsk) SharePhase.GRACE else SharePhase.CHOOSING, mac?.id, mac?.sessionId)
        }
    }

    fun choose(mac: ShareMac): ShareFlow = if (phase == SharePhase.CHOOSING && mac.eligible)
        copy(target = mac.id, sessionId = mac.sessionId) else this
    fun change(): ShareFlow = if (phase in setOf(SharePhase.GRACE, SharePhase.FAILED))
        copy(phase = SharePhase.CHOOSING, message = null) else this
    fun cancel(): ShareFlow = if (phase != SharePhase.SENDING) copy(phase = SharePhase.CANCELLED) else this
    fun send(macs: List<ShareMac>, unavailable: String): ShareFlow {
        if (phase !in setOf(SharePhase.GRACE, SharePhase.CHOOSING, SharePhase.FAILED)) return this
        val mac = macs.firstOrNull { it.id == target && it.sessionId == sessionId && it.eligible }
        return if (mac == null) copy(phase = SharePhase.FAILED, message = unavailable)
            else copy(phase = SharePhase.SENDING, message = null)
    }
    fun finish(success: Boolean, message: String, parked: Boolean = false): ShareFlow = if (phase == SharePhase.SENDING)
        copy(phase = if (!success) SharePhase.FAILED else if (parked) SharePhase.PARKED else SharePhase.SUCCEEDED, message = message) else this
}
