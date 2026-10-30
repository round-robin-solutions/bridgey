package dev.bridgey.android.updates

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R

/**
 * Update all devices automatically, on the notification shade: a quiet notice while an automatic
 * run goes (the version, who goes first, this phone's one-minute countdown with Later, or what it
 * waits for), and "Started automatically by Work Mac" when a Mac starts this phone's update. Its own
 * low-importance channel: no sound, no heads-up, never full screen.
 */
class AutoUpdateNotifier(private val context: Context) {
    private val manager: NotificationManager? get() = context.getSystemService(NotificationManager::class.java)
    private var shown: AutoNotice? = null

    private fun allowed(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun channel() {
        manager?.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.update_auto_channel), NotificationManager.IMPORTANCE_LOW).apply {
                description = context.getString(R.string.update_auto_channel_detail)
                setSound(null, null)
                enableVibration(false)
            },
        )
    }

    private fun openSettings(requestCode: Int): PendingIntent = PendingIntent.getActivity(
        context,
        requestCode,
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(dev.bridgey.android.ui.SettingsDeepLink.EXTRA_SECTION, dev.bridgey.android.ui.SettingsSection.UPDATES.name),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** The automatic run's notice, posted again only when what it says changes; null takes it away. */
    @Synchronized fun show(notice: AutoNotice?) {
        if (notice == shown) return
        shown = notice
        if (notice == null) {
            manager?.cancel(RUN_NOTIFICATION_ID)
            return
        }
        if (!allowed()) return
        channel()
        val title = notice.version?.let { context.getString(R.string.update_auto_notice_title, it) } ?: context.getString(R.string.update_auto_notice_title_plain)
        val text = when {
            notice.restarting -> context.getString(R.string.update_auto_notice_restarting)
            notice.held != null -> context.getString(R.string.update_auto_waiting, busyWords(notice.held))
            notice.restartAt != null -> context.getString(R.string.update_auto_notice_countdown)
            notice.includesLocal && notice.first.isNotEmpty() -> context.getString(R.string.update_auto_notice_first, notice.first.joinToString(", "))
            notice.includesLocal -> context.getString(R.string.update_auto_notice_phone)
            else -> context.getString(R.string.update_auto_notice_devices, notice.first.joinToString(", "))
        }
        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setContentIntent(openSettings(RUN_NOTIFICATION_ID))
        val restartAt = notice.restartAt
        if (restartAt != null && notice.held == null) {
            // The header counts down to this phone's restart.
            builder.setWhen(restartAt).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
        }
        if (notice.includesLocal && !notice.restarting) {
            val later = PendingIntent.getBroadcast(
                context, RUN_NOTIFICATION_ID,
                Intent(context, AutoUpdateLaterReceiver::class.java).setAction(AutoUpdateLaterReceiver.ACTION_LATER),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(Notification.Action.Builder(null, context.getString(R.string.updates_later), later).build())
        }
        runCatching { manager?.notify(RUN_NOTIFICATION_ID, builder.build()) }
    }

    /** A Mac started this phone's update by itself. Gone after a while, or when the phone restarts into the new version. */
    fun startedBy(name: String) {
        if (!allowed()) return
        channel()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.update_auto_notice_title_plain))
            .setContentText(context.getString(R.string.update_auto_started_by, name))
            .setCategory(Notification.CATEGORY_STATUS)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setTimeoutAfter(STARTED_BY_LIFETIME_MILLIS)
            .setContentIntent(openSettings(STARTED_BY_NOTIFICATION_ID))
            .build()
        runCatching { manager?.notify(STARTED_BY_NOTIFICATION_ID, notification) }
    }

    private fun busyWords(busy: UpdateBusy): String = context.getString(
        when (busy) {
            UpdateBusy.CALL -> R.string.update_busy_call
            UpdateBusy.SCREEN_SHARE -> R.string.update_busy_screen_share
            UpdateBusy.REMOTE_CONTROL -> R.string.update_busy_remote_control
            UpdateBusy.TRANSFER -> R.string.update_busy_transfer
            UpdateBusy.PHONE_FILES -> R.string.update_busy_phone_files
            UpdateBusy.SETUP -> R.string.update_busy_setup
            UpdateBusy.OTHER -> R.string.update_busy_other
        },
    )

    companion object {
        const val CHANNEL_ID = "bridgey.updates.automatic"
        private const val RUN_NOTIFICATION_ID = 42_472
        private const val STARTED_BY_NOTIFICATION_ID = 42_473
        private const val STARTED_BY_LIFETIME_MILLIS = 15L * 60 * 1000
    }
}

/** Later on the automatic notice. Not exported: only Bridgey's own PendingIntent reaches it. */
class AutoUpdateLaterReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_LATER) return
        val app = context.applicationContext as? BridgeyApplication ?: return
        if (!app.isPrimaryUser) return
        app.updateAll.later()
    }

    companion object {
        const val ACTION_LATER = "dev.bridgey.android.action.AUTO_UPDATE_LATER"
    }
}
