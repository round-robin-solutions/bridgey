package dev.bridgey.android.sync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R
import dev.bridgey.android.ui.SettingsDeepLink
import dev.bridgey.android.ui.syncKeyName

/**
 * Settings sync, 8.4 and 8.5: another device turned a feature on here that needs a permission only this phone can give.
 * The one notification sync posts; every other change is an activity item only (Rahul, 2026-10-27).
 */
object SyncNotifier {
    private const val CHANNEL_ID = "bridgey_settings_sync_v1"

    fun needsPermission(context: Context, deviceName: String, key: SyncKey) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (!manager.areNotificationsEnabled()) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.sync_notification_channel), NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = context.getString(R.string.sync_notification_channel_detail)
            },
        )
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(SettingsDeepLink.EXTRA_SECTION, SettingsDeepLink.PERMISSIONS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val open = PendingIntent.getActivity(context, key.ordinal, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.sync_notification_title, syncKeyName(context, key), deviceName))
            .setContentText(context.getString(R.string.sync_notification_waiting))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
        builder.addAction(Notification.Action.Builder(null, context.getString(R.string.settings_sync_allow), open).build())
        // One notification per setting: a later change to the same setting replaces it.
        manager.notify(NOTIFICATION_BASE + key.ordinal, builder.build())
    }

    private const val NOTIFICATION_BASE = 74_000
}
