package dev.bridgey.android.agents

import android.app.Activity
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import dev.bridgey.android.BridgeyApplication

/** Bridgey's own notification actions for agents (answers, swipes, Deny) and the grant expiry alarm. Not exported. */
class AgentActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? BridgeyApplication ?: return
        if (!app.isPrimaryUser) return
        val hub = app.pairing.agents
        val deviceId = intent.getStringExtra(AgentNotifier.EXTRA_DEVICE_ID)
        val id = intent.getStringExtra(AgentNotifier.EXTRA_ID)
        val pending = goAsync()
        Thread {
            try {
                when (intent.action) {
                    AgentNotifier.ACTION_EXPIRY -> hub.checkExpiry()
                    AgentNotifier.ACTION_ASK_ANSWER -> if (deviceId != null && id != null) {
                        hub.answer(deviceId, id, intent.getStringExtra(AgentNotifier.EXTRA_OPTION), null)
                    }
                    AgentNotifier.ACTION_ASK_REPLY -> if (deviceId != null && id != null) {
                        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(AgentNotifier.REMOTE_INPUT_KEY)?.toString()
                        hub.answer(deviceId, id, null, text)
                    }
                    AgentNotifier.ACTION_ASK_DISMISSED -> if (deviceId != null && id != null) hub.dismissed(deviceId, id)
                    AgentNotifier.ACTION_CLIP_DENY -> if (deviceId != null && id != null) hub.clipboardDeny(deviceId, id)
                }
            } finally {
                pending.finish()
            }
        }.start()
    }
}

/**
 * Send on "<device> wants your clipboard": Android lets an app read the clipboard only while it is in front, so this
 * invisible activity opens for a moment, reads it once it has focus, answers the request and closes.
 */
class AgentClipboardActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setDimAmount(0f)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val deviceId = intent.getStringExtra(AgentNotifier.EXTRA_DEVICE_ID)
        val requestId = intent.getStringExtra(AgentNotifier.EXTRA_ID)
        val app = application as? BridgeyApplication
        if (deviceId == null || requestId == null || app == null || !app.isPrimaryUser) return finish()
        val clip = runCatching { getSystemService(ClipboardManager::class.java).primaryClip }.getOrNull()
        val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val text = item?.coerceToText(this)?.toString().orEmpty()
        val html = item?.htmlText
        val hub = app.pairing.agents
        Thread { hub.clipboardSend(deviceId, requestId, text, html) }.start()
        Handler(Looper.getMainLooper()).post { finish() }
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
