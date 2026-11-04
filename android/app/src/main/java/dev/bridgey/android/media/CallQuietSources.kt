package dev.bridgey.android.media

import android.Manifest
import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.notification.StatusBarNotification
import android.telephony.TelephonyManager
import dev.bridgey.android.CallLifecycle
import dev.bridgey.android.PhoneCallStateObserver
import dev.bridgey.android.notificationCallType
import dev.bridgey.android.resolvedNotificationCallType
import java.lang.ref.WeakReference
import java.util.UUID

/** Cellular observation is application-owned, independent of mirroring/listener binding. */
internal class CallQuietSources(
    private val context: Context,
    private val changed: (Set<String>, Boolean) -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    private var enabled = false
    private var observingCell = false
    private var cellKnown = false
    private var cellUncertain = false
    private var notificationsUncertain = false
    private var cell: String? = null
    private var idleCheck: Runnable? = null
    private var batch = false
    private var last = emptySet<String>()
    private var lastUncertain = false
    private val notificationKeys = linkedMapOf<String, String>()
    /** Identities only: observer loss must not advertise these calls as still active. */
    private val suspendedNotificationKeys = linkedMapOf<String, String>()
    private val phone = PhoneCallStateObserver(context, ::phoneChanged)
    private val voip = CallLifecycle(
        scheduler = { delay, task ->
            val runnable = Runnable(task)
            handler.postDelayed(runnable, delay)
            val cancel: () -> Unit = { handler.removeCallbacks(runnable) }
            cancel
        },
        telephonyState = { null },
        endCall = { id, _ -> notificationKeys.entries.removeAll { it.value == id }; publish() },
    )

    fun update(enabled: Boolean) {
        this.enabled = enabled
        live = WeakReference(this)
        val allowed = enabled && context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
        if (!allowed) {
            phone.stop(); observingCell = false; cellKnown = false
            idleCheck?.let(handler::removeCallbacks); idleCheck = null
            val lost = cell != null
            cell = null
            if (lost) cellUncertain = true
            if (!enabled) {
                voip.clear(); notificationKeys.clear(); suspendedNotificationKeys.clear()
                cellUncertain = false; notificationsUncertain = false
            }
            publish()
            return
        }
        if (!observingCell) {
            try {
                phone.start()
                observingCell = true
                readPhone()?.let(::phoneChanged)
            } catch (_: RuntimeException) {
                phone.stop(); observingCell = false; cellKnown = false
                val lost = cell != null
                cell = null
                if (lost) cellUncertain = true
                publish()
            }
        }
    }

    fun notificationPosted(sbn: StatusBarNotification, cellularSource: Boolean) {
        if (!enabled) return
        if (cellularSource && cellKnown) return
        val notification = sbn.notification
        val tracked = voip.isTracked(sbn.key) || sbn.key in suspendedNotificationKeys
        val ongoing = notification.flags and Notification.FLAG_ONGOING_EVENT != 0
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (notification.category != Notification.CATEGORY_CALL && !(tracked && ongoing)) {
            if (tracked) voip.updateNoLongerCall(sbn.key)
            suspendedNotificationKeys.remove(sbn.key)
            return
        }
        val reported = notificationCallType(notification.extras.getInt("android.callType", 0))
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) resolvedNotificationCallType(
            reportedType = reported,
            hasAnswer = hasIntent(notification, Notification.EXTRA_ANSWER_INTENT),
            hasDecline = hasIntent(notification, Notification.EXTRA_DECLINE_INTENT),
            hasHangUp = hasIntent(notification, Notification.EXTRA_HANG_UP_INTENT),
            hasFullScreenIntent = notification.fullScreenIntent != null,
            isTelephonyCall = cellularSource,
        ) else reported
        val active = type == "incoming" || type == "ongoing" ||
            type == "unknown" && (ongoing || notification.fullScreenIntent != null)
        if (!active) {
            if (tracked && type != "unknown") voip.updateNoLongerCall(sbn.key)
            if (type != "unknown") suspendedNotificationKeys.remove(sbn.key)
            return
        }
        val fresh = suspendedNotificationKeys.remove(sbn.key)
            ?: "app_${UUID.randomUUID().toString().replace("-", "")}"
        val id = voip.callIdFor(sbn.key, sbn.packageName, fresh)
        voip.forwarded(id, sbn.key, sbn.packageName, telephony = false)
        notificationKeys[sbn.key] = id
        // A rekey keeps its call ID but retires the old notification key.
        notificationKeys.keys.removeAll { !voip.isTracked(it) }
        publish()
    }

    fun notificationRemoved(sbn: StatusBarNotification) {
        suspendedNotificationKeys.remove(sbn.key)
        if (enabled) voip.notificationRemoved(sbn.key)
    }

    /** A rebind snapshot is rebuilt before publication; missing state after a gap is not an end. */
    fun notificationsConnected(active: List<Pair<StatusBarNotification, Boolean>>) {
        if (!enabled) return
        batch = true
        val keys = active.mapTo(mutableSetOf()) { it.first.key }
        notificationKeys.keys.filterNot(keys::contains).forEach(voip::notificationRemoved)
        active.forEach { (notification, cellular) -> notificationPosted(notification, cellular) }
        // The verified snapshot retires absent/filtered keys, even if the app later reuses one.
        suspendedNotificationKeys.clear()
        batch = false
        notificationsUncertain = false
        publish()
    }

    fun notificationsDisconnected() {
        if (voip.trackedIds.isEmpty()) return
        notificationsUncertain = true
        notificationKeys.filterKeys(voip::isTracked).forEach { (key, id) -> suspendedNotificationKeys[key] = id }
        while (suspendedNotificationKeys.size > 16) suspendedNotificationKeys.remove(suspendedNotificationKeys.keys.first())
        voip.clear(); notificationKeys.clear()
        publish()
    }

    private fun phoneChanged(state: Int) {
        if (!enabled) return
        cellKnown = true
        idleCheck?.let(handler::removeCallbacks); idleCheck = null
        when (state) {
            TelephonyManager.CALL_STATE_RINGING, TelephonyManager.CALL_STATE_OFFHOOK -> {
                cellUncertain = false
                if (cell == null) cell = "cell_${UUID.randomUUID().toString().replace("-", "")}"
                publish()
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                val check = Runnable {
                    idleCheck = null
                    when (readPhone()) {
                        TelephonyManager.CALL_STATE_RINGING, TelephonyManager.CALL_STATE_OFFHOOK -> Unit
                        TelephonyManager.CALL_STATE_IDLE -> { cell = null; cellUncertain = false; publish() }
                        else -> { if (cell != null) cellUncertain = true; cell = null; cellKnown = false; publish() }
                    }
                }
                idleCheck = check
                handler.postDelayed(check, CallLifecycle.IDLE_DEBOUNCE_MS)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun readPhone(): Int? = runCatching {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) null
        else context.getSystemService(TelephonyManager::class.java)?.callState
    }.getOrNull()

    private fun publish() {
        if (batch) return
        val current = if (enabled) (voip.trackedIds + listOfNotNull(cell)).sorted().take(16).toSet() else emptySet()
        val uncertain = enabled && (cellUncertain || notificationsUncertain)
        if (last == current && uncertain == lastUncertain) return
        last = current
        lastUncertain = uncertain
        changed(current, uncertain)
    }

    @Suppress("DEPRECATION")
    private fun hasIntent(notification: Notification, key: String): Boolean =
        runCatching { notification.extras.get(key) is android.app.PendingIntent }.getOrDefault(false)

    companion object {
        private var live: WeakReference<CallQuietSources>? = null
        fun permissionsChanged() {
            live?.get()?.let { source -> source.handler.post { source.update(source.enabled) } }
        }
    }
}
