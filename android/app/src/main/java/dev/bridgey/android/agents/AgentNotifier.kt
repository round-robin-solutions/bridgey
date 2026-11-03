package dev.bridgey.android.agents

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Build
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R

/**
 * The agents' notifications: "Agent messages" (notify.post), "Agent questions" (asks, permission requests and
 * clipboard requests). Agent text is plain text (never HTML, never linkified). Each notification opens the
 * agent's page in Bridgey.
 */
class AgentNotifier(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    private fun channels() {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_MESSAGES, context.getString(R.string.agent_channel_messages), NotificationManager.IMPORTANCE_DEFAULT),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_QUESTIONS, context.getString(R.string.agent_channel_questions), NotificationManager.IMPORTANCE_HIGH),
        )
    }

    private fun openDevice(deviceId: String, requestCode: Int, askId: String? = null): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(ACTION_OPEN_AGENT)
            .putExtra(EXTRA_DEVICE_ID, deviceId)
            .apply { askId?.let { putExtra(EXTRA_ASK_ID, it) } }
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun broadcast(action: String, deviceId: String, id: String, requestCode: Int, extra: (Intent) -> Unit = {}, mutable: Boolean = false): PendingIntent {
        val intent = Intent(context, AgentActionReceiver::class.java)
            .setAction(action)
            .putExtra(EXTRA_DEVICE_ID, deviceId)
            .putExtra(EXTRA_ID, id)
            .also(extra)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE)
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    private fun code(vararg parts: String): Int = parts.joinToString("/").hashCode()

    private fun base(channel: String, deviceName: String): Notification.Builder = Notification.Builder(context, channel)
        .setSmallIcon(R.drawable.ic_bridgey_notification)
        .setSubText(deviceName)
        .setCategory(if (channel == CHANNEL_QUESTIONS) Notification.CATEGORY_MESSAGE else Notification.CATEGORY_STATUS)

    private fun fromLine(from: String?): String? = from?.let { context.getString(R.string.agent_from, it) }

    /** notify.post: a [NotifyPost.tag] replaces this device's earlier notification with that tag. */
    fun post(deviceId: String, deviceName: String, post: NotifyPost) {
        channels()
        val tag = "agent:$deviceId:${post.tag?.let { "tag:$it" } ?: post.notifyId}"
        val text = listOfNotNull(post.body, fromLine(post.from)).joinToString("\n\n")
        val notification = base(CHANNEL_MESSAGES, deviceName)
            .setContentTitle(post.title)
            .apply {
                if (text.isNotEmpty()) {
                    setContentText(post.body ?: fromLine(post.from))
                    setStyle(Notification.BigTextStyle().bigText(text))
                }
            }
            .setContentIntent(openDevice(deviceId, code(tag)))
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(tag, NOTIFY_ID, notification) }
    }

    /**
     * A question: one action per option and, with allowText, a Reply action with inline text. With requireUnlock the
     * actions need the phone unlocked (Android 12 and later); before that there are no actions, and the tap opens
     * Bridgey, which needs the unlock.
     */
    fun ask(deviceName: String, ask: AskRecord) {
        channels()
        val tag = askTag(ask.deviceId, ask.askId)
        val withActions = !ask.requireUnlock || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        val text = listOfNotNull(ask.body, fromLine(ask.from)).joinToString("\n\n")
        val builder = base(CHANNEL_QUESTIONS, deviceName)
            .setContentTitle(ask.title)
            .apply {
                if (text.isNotEmpty()) {
                    setContentText(ask.body ?: fromLine(ask.from))
                    setStyle(Notification.BigTextStyle().bigText(text))
                }
            }
            .setContentIntent(openDevice(ask.deviceId, code(tag, "open"), askId = ask.askId))
            .setDeleteIntent(broadcast(ACTION_ASK_DISMISSED, ask.deviceId, ask.askId, code(tag, "delete")))
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
            .setTimeoutAfter((ask.expiresAt - System.currentTimeMillis()).coerceAtLeast(1_000))
        if (withActions) {
            ask.options.forEach { option ->
                val pending = broadcast(ACTION_ASK_ANSWER, ask.deviceId, ask.askId, code(tag, "option", option.id), { it.putExtra(EXTRA_OPTION, option.id) })
                builder.addAction(action(option.label, pending, ask.requireUnlock))
            }
            if (ask.allowText) {
                val input = RemoteInput.Builder(REMOTE_INPUT_KEY).setLabel(ask.textHint ?: context.getString(R.string.agent_reply_hint)).build()
                // Inline reply needs a mutable PendingIntent: Android fills in the typed text.
                val pending = broadcast(ACTION_ASK_REPLY, ask.deviceId, ask.askId, code(tag, "reply"), mutable = true)
                builder.addAction(
                    Notification.Action.Builder(null, context.getString(R.string.agent_reply), pending)
                        .addRemoteInput(input)
                        .apply { if (ask.requireUnlock && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setAuthenticationRequired(true) }
                        .build(),
                )
            }
        }
        runCatching { manager.notify(tag, ASK_ID, builder.build()) }
    }

    private fun action(label: String, pending: PendingIntent, requireUnlock: Boolean): Notification.Action =
        Notification.Action.Builder(null, label, pending)
            .apply { if (requireUnlock && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setAuthenticationRequired(true) }
            .build()

    fun cancelAsk(deviceId: String, askId: String) {
        manager.cancel(askTag(deviceId, askId), ASK_ID)
    }

    /** "<device> wants your clipboard" with Send (opens Bridgey for a moment, to read it) and Deny. */
    fun clipboardRequest(deviceId: String, deviceName: String, requestId: String, expiresAt: Long) {
        channels()
        val tag = clipTag(deviceId, requestId)
        val send = Intent(context, AgentClipboardActivity::class.java)
            .putExtra(EXTRA_DEVICE_ID, deviceId)
            .putExtra(EXTRA_ID, requestId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        val sendPending = PendingIntent.getActivity(context, code(tag, "send"), send, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val deny = broadcast(ACTION_CLIP_DENY, deviceId, requestId, code(tag, "deny"))
        val notification = base(CHANNEL_QUESTIONS, deviceName)
            .setContentTitle(context.getString(R.string.agent_clipboard_title, deviceName))
            .setContentIntent(openDevice(deviceId, code(tag, "open")))
            .setDeleteIntent(deny)
            .setTimeoutAfter((expiresAt - System.currentTimeMillis()).coerceAtLeast(1_000))
            .addAction(Notification.Action.Builder(null, context.getString(R.string.agent_clipboard_deny), deny).build())
            .addAction(Notification.Action.Builder(null, context.getString(R.string.agent_clipboard_send), sendPending).build())
            .build()
        runCatching { manager.notify(tag, CLIP_ID, notification) }
    }

    fun cancelClipboardRequest(deviceId: String, requestId: String) {
        manager.cancel(clipTag(deviceId, requestId), CLIP_ID)
    }

    /** "<device> asks for: <grants>", opening the device's permissions. */
    fun grantRequest(deviceId: String, deviceName: String, grants: List<String>, note: String?) {
        channels()
        val tag = "agent-grants:$deviceId"
        val notification = base(CHANNEL_QUESTIONS, deviceName)
            .setContentTitle(context.getString(R.string.agent_request_title, deviceName, grants.joinToString(", ")))
            .apply { note?.let { setContentText(it); setStyle(Notification.BigTextStyle().bigText(it)) } }
            .setContentIntent(openDevice(deviceId, code(tag)))
            .setAutoCancel(true)
            .setTimeoutAfter(GRANT_WAITING_MILLIS)
            .build()
        runCatching { manager.notify(tag, GRANT_ID, notification) }
    }

    fun cancelGrantRequest(deviceId: String) {
        manager.cancel("agent-grants:$deviceId", GRANT_ID)
    }

    /** Every notification of a forgotten agent. */
    fun cancelAll(deviceId: String) {
        runCatching {
            manager.activeNotifications.filter { it.tag?.contains(":$deviceId") == true }.forEach { manager.cancel(it.tag, it.id) }
        }
    }

    companion object {
        const val CHANNEL_MESSAGES = "bridgey_agent_messages_v1"
        const val CHANNEL_QUESTIONS = "bridgey_agent_questions_v1"
        const val ACTION_OPEN_AGENT = "dev.bridgey.android.action.OPEN_AGENT"
        const val ACTION_ASK_ANSWER = "dev.bridgey.android.action.AGENT_ASK_ANSWER"
        const val ACTION_ASK_REPLY = "dev.bridgey.android.action.AGENT_ASK_REPLY"
        const val ACTION_ASK_DISMISSED = "dev.bridgey.android.action.AGENT_ASK_DISMISSED"
        const val ACTION_CLIP_DENY = "dev.bridgey.android.action.AGENT_CLIP_DENY"
        const val ACTION_EXPIRY = "dev.bridgey.android.action.AGENT_EXPIRY"
        const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.AGENT_DEVICE_ID"
        const val EXTRA_ASK_ID = "dev.bridgey.android.extra.AGENT_ASK_ID"
        const val EXTRA_ID = "dev.bridgey.android.extra.AGENT_ID"
        const val EXTRA_OPTION = "dev.bridgey.android.extra.AGENT_OPTION"
        const val REMOTE_INPUT_KEY = "agent_reply"
        private const val NOTIFY_ID = 71_001
        private const val ASK_ID = 71_002
        private const val CLIP_ID = 71_003
        private const val GRANT_ID = 71_004

        fun askTag(deviceId: String, askId: String) = "agent-ask:$deviceId:$askId"
        fun clipTag(deviceId: String, requestId: String) = "agent-clip:$deviceId:$requestId"
    }
}
