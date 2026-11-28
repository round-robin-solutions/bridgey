package dev.bridgey.android

import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/**
 * The one way Bridgey posts and removes notifications: through the app's [NotificationThrottle], so Android never
 * sheds an update (the acceptance soak, 28 Nov 2026, saw "Package enqueue rate ... Shedding" for the stress build).
 * Updates that wait are built when they go out, on the main thread, so only the latest state is ever built.
 */
object AppNotifications {
    /** Progress notifications: one update a second, as before the throttle. */
    const val PROGRESS_INTERVAL_MS = 1_000L

    private class Holder(val app: Context, val throttle: NotificationThrottle<() -> Notification, Notification>)

    @Volatile private var holder: Holder? = null

    /** One throttle per application: tests replace the application, the app has one for its life. */
    private fun throttle(context: Context): NotificationThrottle<() -> Notification, Notification> {
        val app = context.applicationContext ?: context
        holder?.takeIf { it.app === app }?.let { return it.throttle }
        return synchronized(this) {
            holder?.takeIf { it.app === app }?.throttle ?: Holder(app, create(app)).also { holder = it }.throttle
        }
    }

    private fun create(app: Context): NotificationThrottle<() -> Notification, Notification> {
        val manager = app.getSystemService(NotificationManager::class.java)
        val main = Handler(Looper.getMainLooper())
        lateinit var throttle: NotificationThrottle<() -> Notification, Notification>
        val flush = Runnable { throttle.flush() }
        throttle = NotificationThrottle(
            clock = SystemClock::elapsedRealtime,
            wakeAt = { at ->
                main.removeCallbacks(flush)
                main.postDelayed(flush, (at - SystemClock.elapsedRealtime()).coerceAtLeast(0))
            },
            prepare = { build ->
                runCatching(build).onFailure { BridgeyLogging.w(LogCategory.NOTIFICATIONS, "notification not built", it) }.getOrNull()
            },
            post = { key, notification ->
                runCatching { manager.notify(key.tag, key.id, notification) }
                    .onFailure { BridgeyLogging.w(LogCategory.NOTIFICATIONS, "notification ${key.id} not posted", it) }
                    .isSuccess
            },
            remove = { key -> runCatching { manager.cancel(key.tag, key.id) } },
            // Notifications an earlier process left up are updates to Android.
            shown = runCatching { manager.activeNotifications.map { NotificationKey(it.tag, it.id) } }.getOrDefault(emptyList()),
        )
        return throttle
    }

    /** Posts [notification] now, or as soon as the throttle lets it; see [NotificationThrottle]. */
    fun post(
        context: Context,
        id: Int,
        notification: Notification,
        tag: String? = null,
        urgency: NotificationUrgency = NotificationUrgency.NORMAL,
        minIntervalMs: Long? = null,
    ): Boolean = post(context, id, tag, urgency, minIntervalMs) { notification }

    /** As [post], building the notification only when it goes out (a waiting update is built on the main thread). */
    fun post(
        context: Context,
        id: Int,
        tag: String? = null,
        urgency: NotificationUrgency = NotificationUrgency.NORMAL,
        minIntervalMs: Long? = null,
        build: () -> Notification,
    ): Boolean {
        val throttle = throttle(context)
        val key = NotificationKey(tag, id)
        return if (minIntervalMs == null) throttle.notify(key, build, urgency) else throttle.notify(key, build, urgency, minIntervalMs)
    }

    /** Removes the notification now, with any update still waiting for it. */
    fun cancel(context: Context, id: Int, tag: String? = null) = throttle(context).cancel(NotificationKey(tag, id))

    /** Removes every notification, showing or waiting, whose tag and ID match. */
    fun cancelWhere(context: Context, matches: (tag: String?, id: Int) -> Boolean) {
        val throttle = throttle(context)
        val showing = runCatching {
            context.getSystemService(NotificationManager::class.java).activeNotifications.map { NotificationKey(it.tag, it.id) }
        }.getOrDefault(emptyList())
        (throttle.known() + showing).filter { matches(it.tag, it.id) }.forEach(throttle::cancel)
    }

    /** Service.startForeground, which cannot wait, counted by the throttle. */
    fun startForeground(service: Service, id: Int, notification: Notification, type: Int? = null) {
        if (type != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) service.startForeground(id, notification, type)
        else service.startForeground(id, notification)
        throttle(service).posted(NotificationKey(null, id))
    }

    /** Service.stopForeground with its notification removed, and no waiting update left to bring it back. */
    fun stopForeground(service: Service, id: Int) {
        service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        cancel(service, id)
    }
}
