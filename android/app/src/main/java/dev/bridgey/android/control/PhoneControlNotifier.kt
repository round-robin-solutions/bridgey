package dev.bridgey.android.control

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.R

/**
 * Ask each time: "MacBook Air wants to control this phone" with Allow and Don't allow, gone after a minute. Allow asks
 * for the phone to be unlocked first (Android 12 and later). Nothing is injected while it waits.
 */
object PhoneControlNotifier {
    const val ASK_CHANNEL_ID = "bridgey_phone_control_ask_v1"
    private const val ASK_NOTIFICATION_ID = 69_600

    fun channel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(ASK_CHANNEL_ID, context.getString(R.string.control_ask_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.control_ask_channel_detail)
            },
        )
    }

    fun showAsk(context: Context, macName: String, promptId: Long) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        channel(context)
        fun action(allow: Boolean, request: Int): PendingIntent = PendingIntent.getBroadcast(
            context, request, PhoneControlReceiver.answerIntent(context, promptId, allow),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val allow = Notification.Action.Builder(null, context.getString(R.string.control_ask_allow), action(true, ASK_NOTIFICATION_ID))
            .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setAuthenticationRequired(true) }
            .build()
        val deny = Notification.Action.Builder(null, context.getString(R.string.control_ask_deny), action(false, ASK_NOTIFICATION_ID + 1)).build()
        val notification = Notification.Builder(context, ASK_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.control_ask_title, macName))
            .setContentText(context.getString(R.string.control_ask_text))
            .setCategory(Notification.CATEGORY_REMINDER)
            .addAction(allow)
            .addAction(deny)
            .setOngoing(true)
            // Nothing private in it, and Android shows only public notifications in full while the screen is shared.
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setTimeoutAfter(PhoneControlLimits.PROMPT_LIFETIME_MILLIS)
            .build()
        runCatching { manager.notify(ASK_NOTIFICATION_ID, notification) }
    }

    fun dismissAsk(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(ASK_NOTIFICATION_ID)
    }
}

/** Allow and Don't allow on the prompt, and Stop control on the sharing notification. Not exported. */
class PhoneControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? BridgeyApplication ?: return
        if (!app.isPrimaryUser) return
        val hub = app.phoneControlOrNull ?: return
        when (intent.action) {
            ACTION_ANSWER -> {
                val promptId = intent.getLongExtra(EXTRA_PROMPT, 0)
                if (promptId > 0) hub.answer(promptId, intent.getBooleanExtra(EXTRA_ALLOW, false))
            }
            ACTION_STOP -> hub.stopLocally()
        }
    }

    companion object {
        const val ACTION_ANSWER = "dev.bridgey.android.action.PHONE_CONTROL_ANSWER"
        const val ACTION_STOP = "dev.bridgey.android.action.PHONE_CONTROL_STOP"
        private const val EXTRA_PROMPT = "dev.bridgey.android.extra.PHONE_CONTROL_PROMPT"
        private const val EXTRA_ALLOW = "dev.bridgey.android.extra.PHONE_CONTROL_ALLOW"

        fun answerIntent(context: Context, promptId: Long, allow: Boolean): Intent =
            Intent(context, PhoneControlReceiver::class.java).setAction(ACTION_ANSWER).putExtra(EXTRA_PROMPT, promptId).putExtra(EXTRA_ALLOW, allow)

        fun stopIntent(context: Context): Intent = Intent(context, PhoneControlReceiver::class.java).setAction(ACTION_STOP)
    }
}
