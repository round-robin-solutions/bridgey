package dev.bridgey.android.sms

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.telecom.TelecomManager
import android.widget.Toast
import dev.bridgey.android.R

/**
 * Block on phone (sms.blocked_numbers): Android lets only the default dialer, the default SMS app
 * and the carrier add to the blocked list, but any app may open the system Blocked numbers screen.
 * With Bridgey in front it opens at once; otherwise Android does not let an app open a screen from
 * the background, so a notification opens it when tapped. The number is shown, never written.
 */
object BlockedNumbers {
    private const val CHANNEL_ID = "bridgey_blocked_numbers_v1"
    private const val NOTIFICATION_ID = 68_900
    private const val LIFETIME_MILLIS = 10 * 60_000L

    /** Android's own screen, or null when this phone or user has none. */
    fun intent(context: Context): Intent? {
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return null
        val intent = runCatching { telecom.createManageBlockedNumbersIntent() }.getOrNull() ?: return null
        if (intent.resolveActivity(context.packageManager) == null) return null
        return intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    /** [inFront]: an activity of Bridgey is started, so Android lets it open another app's screen. */
    fun open(context: Context, address: String?, inFront: Boolean): BlockedNumbersResult {
        val intent = intent(context) ?: return BlockedNumbersResult.UNAVAILABLE
        if (inFront && runCatching { context.startActivity(intent) }.isSuccess) {
            if (address != null) {
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    Toast.makeText(context, context.getString(R.string.sms_block_toast, address), Toast.LENGTH_LONG).show()
                }
            }
            return BlockedNumbersResult.OPENED
        }
        return if (notify(context, intent, address)) BlockedNumbersResult.NOTIFIED else BlockedNumbersResult.UNAVAILABLE
    }

    private fun notify(context: Context, intent: Intent, address: String?): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!manager.areNotificationsEnabled()) return false
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.sms_block_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.sms_block_channel_detail)
            },
        )
        val pending = PendingIntent.getActivity(context, NOTIFICATION_ID, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val text = if (address != null) context.getString(R.string.sms_block_notification_text, address) else context.getString(R.string.sms_block_notification_text_plain)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.sms_block_notification_title))
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setTimeoutAfter(LIFETIME_MILLIS)
            .build()
        return runCatching { manager.notify(NOTIFICATION_ID, notification) }.isSuccess
    }
}
