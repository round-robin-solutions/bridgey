package dev.bridgey.android

import android.app.Notification
import android.app.NotificationManager

/** Runs [task] after [delayMs] on the caller's thread; the returned function cancels it. */
internal fun interface CallScheduler {
    fun schedule(delayMs: Long, task: () -> Unit): () -> Unit
}

/**
 * Decides when a call mirrored on the Mac ends. A call card is persistent: it stays until the
 * call itself ends, never because the call's notification was updated into something the
 * listener does not forward (an ongoing update without the call category, a group change, a
 * ranking change), or because the dialer swapped the notification for a new one.
 *
 * - A tracked call's notification removal waits [rekeyGraceMs]: a call notification from the
 *   same app posted meanwhile continues the same card (same notification id on the Mac).
 * - A telephony call whose notification went away stays while the phone still reports a call.
 * - Telephony IDLE ends dialer calls only after it holds for [idleDebounceMs].
 *
 * Main thread only. [log] receives public tokens: an event, the call's 8-character id prefix
 * and a reason code. Never the caller, number or app.
 */
internal class CallLifecycle(
    private val scheduler: CallScheduler,
    /** "incoming", "ongoing" or "idle"; null when the phone state is unavailable. */
    private val telephonyState: () -> String?,
    private val endCall: (notificationId: String, reason: String) -> Unit,
    private val log: (event: String, notificationId: String?, reason: String) -> Unit = { _, _, _ -> },
    private val rekeyGraceMs: Long = REKEY_GRACE_MS,
    private val idleDebounceMs: Long = IDLE_DEBOUNCE_MS,
) {
    private class Call(
        val notificationId: String,
        var systemKey: String,
        val packageName: String,
        val telephony: Boolean,
    ) {
        var pendingEnd: (() -> Unit)? = null
        /** The notification is gone but the phone still reports the call: waiting for IDLE. */
        var notificationGone = false
    }

    private val calls = linkedMapOf<String, Call>()
    private var idleCheck: (() -> Unit)? = null

    val trackedIds: Set<String> get() = calls.keys.toSet()

    fun isTracked(systemKey: String): Boolean = callForKey(systemKey) != null

    fun isTrackedId(notificationId: String): Boolean = notificationId in calls

    fun isTelephonyCall(systemKey: String): Boolean = callForKey(systemKey)?.telephony == true

    /**
     * The notification id a call post is forwarded under: its own call's id, or the id of the same
     * app's call whose notification just went away (the dialer re-posted the call under a new key).
     */
    fun callIdFor(systemKey: String, packageName: String, freshId: String): String {
        callForKey(systemKey)?.let { call ->
            resume(call, "reposted")
            return call.notificationId
        }
        val replaced = calls.values.lastOrNull {
            it.packageName == packageName && (it.pendingEnd != null || it.notificationGone)
        } ?: return freshId
        replaced.systemKey = systemKey
        resume(replaced, "rekeyed")
        return replaced.notificationId
    }

    /** A call card was sent to the Mac for [systemKey]. */
    fun forwarded(notificationId: String, systemKey: String, packageName: String, telephony: Boolean) {
        val existing = calls[notificationId]
        if (existing != null) {
            existing.systemKey = systemKey
            return
        }
        calls[notificationId] = Call(notificationId, systemKey, packageName, telephony)
        log("started", notificationId, if (telephony) "telephony" else "app")
        while (calls.size > MAX_TRACKED_CALLS) {
            val oldest = calls.values.first()
            oldest.pendingEnd?.invoke()
            calls.remove(oldest.notificationId)
            log("untracked", oldest.notificationId, "limit")
        }
    }

    /**
     * A tracked call's update hit a path that does not forward it. Returns true when the card must
     * stay (the caller must not retract it).
     */
    fun keepOnFilteredUpdate(systemKey: String, reason: String): Boolean {
        val call = callForKey(systemKey) ?: return false
        log("update_kept", call.notificationId, reason)
        return true
    }

    /**
     * The tracked call's notification became something that is not a call. A dialer call stays
     * while the phone still reports a call; otherwise the call has ended. Returns true when the
     * card stays.
     */
    fun updateNoLongerCall(systemKey: String): Boolean {
        val call = callForKey(systemKey) ?: return false
        if (call.telephony && telephonyState().isActiveCall()) {
            log("update_kept", call.notificationId, "not_call_phone_active")
            return true
        }
        finish(call, "not_call")
        return false
    }

    /** Returns the call's id when [systemKey] was a tracked call: its end is decided here. */
    fun notificationRemoved(systemKey: String): String? {
        val call = callForKey(systemKey) ?: return null
        if (call.telephony && telephonyState() == "idle") {
            finish(call, "removed_phone_idle")
            return call.notificationId
        }
        if (call.pendingEnd == null) {
            log("removal_deferred", call.notificationId, "notification_removed")
            call.pendingEnd = scheduler.schedule(rekeyGraceMs) { removalGraceExpired(call) }
        }
        return call.notificationId
    }

    /** Telephony call state from the phone-state callback or a dialer post. */
    fun telephonyChanged(state: String?) {
        when (state) {
            "idle" -> {
                if (idleCheck != null || calls.values.none(Call::telephony)) return
                log("idle_seen", null, "debounce")
                idleCheck = scheduler.schedule(idleDebounceMs) {
                    idleCheck = null
                    confirmIdle()
                }
            }
            "incoming", "ongoing" -> idleCheck?.let { cancel ->
                cancel()
                idleCheck = null
                log("idle_cancelled", null, "phone_$state")
            }
        }
    }

    /** Forget a call the caller retracts itself (its app was turned off). */
    fun forget(notificationId: String) {
        calls.remove(notificationId)?.let { call ->
            call.pendingEnd?.invoke()
            log("untracked", notificationId, "retracted")
        }
    }

    fun clear() {
        calls.values.forEach { it.pendingEnd?.invoke() }
        calls.clear()
        idleCheck?.invoke()
        idleCheck = null
    }

    private fun callForKey(systemKey: String): Call? = calls.values.firstOrNull { it.systemKey == systemKey }

    private fun resume(call: Call, reason: String) {
        val wasEnding = call.pendingEnd != null || call.notificationGone
        call.pendingEnd?.invoke()
        call.pendingEnd = null
        call.notificationGone = false
        if (wasEnding) log("resumed", call.notificationId, reason)
    }

    private fun removalGraceExpired(call: Call) {
        call.pendingEnd = null
        if (calls[call.notificationId] !== call) return
        if (call.telephony && telephonyState().isActiveCall()) {
            call.notificationGone = true
            log("kept", call.notificationId, "phone_still_in_call")
            return
        }
        finish(call, "notification_removed")
    }

    private fun confirmIdle() {
        if (telephonyState().isActiveCall()) {
            log("idle_cancelled", null, "phone_active_again")
            return
        }
        calls.values.filter(Call::telephony).forEach { finish(it, "phone_idle") }
    }

    private fun finish(call: Call, reason: String) {
        call.pendingEnd?.invoke()
        call.pendingEnd = null
        if (calls.remove(call.notificationId) == null) return
        log("ended", call.notificationId, reason)
        endCall(call.notificationId, reason)
    }

    private fun String?.isActiveCall(): Boolean = this == "incoming" || this == "ongoing"

    companion object {
        const val REKEY_GRACE_MS = 1_500L
        const val IDLE_DEBOUNCE_MS = 1_500L
        private const val MAX_TRACKED_CALLS = 16
    }
}

/** What the listener needs from a posted notification to decide whether it is forwarded. */
internal data class NotificationUpdate(
    val systemKey: String,
    val flags: Int,
    val category: String?,
    val visibility: Int,
    /** The ranking importance, or null when the ranking map has no entry for the key. */
    val importance: Int?,
    val hasContent: Boolean,
)

internal sealed interface UpdateOutcome {
    data class Forward(val isCall: Boolean) : UpdateOutcome
    /** Not forwardable: retract any earlier mirrored state for the key. */
    data class Retract(val reason: String) : UpdateOutcome
    /** A call in progress whose update is not forwardable: its Mac card stays as it is. */
    data class KeepCall(val reason: String) : UpdateOutcome
}

/**
 * The listener's filters, in order. A tracked call is never retracted by them: dialers built on
 * AOSP re-post a ringing call without the call category (the quiet incoming and in-call variants,
 * flagged ongoing) under the same key, so a tracked ongoing update stays a call; any other
 * filtered update of a tracked call keeps the card. A tracked call whose update is plainly no
 * longer a call ends through [CallLifecycle.updateNoLongerCall].
 */
internal fun classifyNotificationUpdate(update: NotificationUpdate, calls: CallLifecycle): UpdateOutcome {
    val tracked = calls.isTracked(update.systemKey)
    val ongoing = update.flags and Notification.FLAG_ONGOING_EVENT != 0
    val isCall = update.category == Notification.CATEGORY_CALL || (tracked && ongoing)
    val filterReason = when {
        update.flags and Notification.FLAG_GROUP_SUMMARY != 0 -> "group_summary"
        !isCall && shouldIgnoreOngoingNotification(update.flags, update.category) -> "ongoing"
        update.visibility == Notification.VISIBILITY_SECRET -> "secret"
        update.importance != null && update.importance <= NotificationManager.IMPORTANCE_MIN -> "min_importance"
        !update.hasContent -> "empty"
        else -> null
    }
    if (filterReason != null) {
        return if (calls.keepOnFilteredUpdate(update.systemKey, filterReason)) {
            UpdateOutcome.KeepCall(filterReason)
        } else {
            UpdateOutcome.Retract(filterReason)
        }
    }
    if (tracked && !isCall && calls.updateNoLongerCall(update.systemKey)) return UpdateOutcome.KeepCall("not_call")
    return UpdateOutcome.Forward(isCall)
}
