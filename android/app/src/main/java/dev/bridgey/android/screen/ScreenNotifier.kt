package dev.bridgey.android.screen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.R

/**
 * Screen sharing notifications: "MacBook wants to see your screen" (Share, Not now), one per Mac, gone when
 * the request ends; and the ongoing "Your screen is being shared with MacBook" with Stop, which the service
 * shows for as long as it runs. Each has its own channel.
 */
object ScreenNotifier {
    const val ASK_CHANNEL_ID = "bridgey_screen_ask_v1"
    const val SHARING_CHANNEL_ID = "bridgey_screen_sharing_v1"
    const val SHARING_NOTIFICATION_ID = 69_500

    private fun askId(deviceId: String) = 69_000 + (deviceId.hashCode() and 0x1FF)

    fun channels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(ASK_CHANNEL_ID, context.getString(R.string.screen_ask_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.screen_ask_channel_detail)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(SHARING_CHANNEL_ID, context.getString(R.string.screen_sharing_channel), NotificationManager.IMPORTANCE_LOW).apply {
                description = context.getString(R.string.screen_sharing_channel_detail)
            },
        )
    }

    /** A Mac asked; Android needs a tap before its dialog can open. */
    fun showAsk(context: Context, request: ScreenRequest) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        channels(context)
        val share = PendingIntent.getActivity(
            context, askId(request.deviceId),
            ScreenConsentActivity.intent(context, request.deviceId, request.macName, request.requestId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val decline = PendingIntent.getBroadcast(
            context, askId(request.deviceId),
            ScreenActionReceiver.declineIntent(context, request.deviceId, request.requestId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, ASK_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.screen_ask_title, request.macName))
            .setContentText(context.getString(R.string.screen_ask_text))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(share)
            .addAction(Notification.Action.Builder(null, context.getString(R.string.screen_ask_share), share).build())
            .addAction(Notification.Action.Builder(null, context.getString(R.string.screen_ask_not_now), decline).build())
            .setAutoCancel(true)
            .setTimeoutAfter(ScreenLimits.REQUEST_LIFETIME_MILLIS)
            .build()
        runCatching { manager.notify(askId(request.deviceId), notification) }
    }

    fun dismissAsk(context: Context, deviceId: String) {
        if (deviceId.isNotEmpty()) context.getSystemService(NotificationManager::class.java)?.cancel(askId(deviceId))
    }

    /** The ongoing notification the service runs under. */
    fun sharing(context: Context, macName: String, sharing: Boolean): Notification {
        channels(context)
        val stop = PendingIntent.getBroadcast(
            context, SHARING_NOTIFICATION_ID, ScreenActionReceiver.stopIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, SHARING_NOTIFICATION_ID, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        return Notification.Builder(context, SHARING_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.screen_sharing_title, macName))
            .setContentText(context.getString(if (sharing) R.string.screen_sharing_text else R.string.screen_sharing_starting))
            .setCategory(Notification.CATEGORY_STATUS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setUsesChronometer(sharing)
            .apply { open?.let(::setContentIntent) }
            .addAction(Notification.Action.Builder(null, context.getString(R.string.screen_stop), stop).build())
            .build()
    }

    fun updateSharing(context: Context, macName: String, sharing: Boolean) {
        runCatching { context.getSystemService(NotificationManager::class.java)?.notify(SHARING_NOTIFICATION_ID, sharing(context, macName, sharing)) }
    }
}

/** Stop on the sharing notification, and Not now on a request. Not exported. */
class ScreenActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? BridgeyApplication ?: return
        if (!app.isPrimaryUser) return
        when (intent.action) {
            ACTION_STOP -> app.screenShare.stop(ScreenStopReason.USER)
            ACTION_DECLINE -> {
                val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID) ?: return
                val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return
                app.screenShare.declineRequest(deviceId, requestId)
            }
        }
    }

    companion object {
        const val ACTION_STOP = "dev.bridgey.android.action.SCREEN_STOP"
        const val ACTION_DECLINE = "dev.bridgey.android.action.SCREEN_DECLINE"
        const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.SCREEN_DEVICE_ID"
        const val EXTRA_REQUEST_ID = "dev.bridgey.android.extra.SCREEN_REQUEST_ID"

        fun stopIntent(context: Context): Intent = Intent(context, ScreenActionReceiver::class.java).setAction(ACTION_STOP)

        fun declineIntent(context: Context, deviceId: String, requestId: String): Intent =
            Intent(context, ScreenActionReceiver::class.java).setAction(ACTION_DECLINE)
                .putExtra(EXTRA_DEVICE_ID, deviceId).putExtra(EXTRA_REQUEST_ID, requestId)
    }
}
