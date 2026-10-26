package dev.bridgey.android.codes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R

/**
 * The Mac's "Link this phone to the Mac" arrives as a notification: Android's companion dialog must
 * open on the phone, from Bridgey in the front, so one tap opens Bridgey and starts the link.
 */
object CodeLinkNotifier {
    const val ACTION_LINK = "dev.bridgey.android.action.LINK_COMPANION"
    private const val CHANNEL_ID = "bridgey_codes_v1"
    private const val NOTIFICATION_ID = 67_901

    fun show(context: Context, deviceId: String, macName: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.codes_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.codes_channel_detail)
            },
        )
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_LINK)
            .putExtra(EXTRA_DEVICE_ID, deviceId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pending = PendingIntent.getActivity(context, NOTIFICATION_ID, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.codes_link_notification_title, macName))
            .setContentText(context.getString(R.string.codes_link_notification_text))
            .setStyle(Notification.BigTextStyle().bigText(context.getString(R.string.codes_link_notification_text)))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setTimeoutAfter(5 * 60_000L)
            .build()
        runCatching { manager.notify(NOTIFICATION_ID, notification) }
    }

    fun dismiss(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.LINK_DEVICE_ID"
}
