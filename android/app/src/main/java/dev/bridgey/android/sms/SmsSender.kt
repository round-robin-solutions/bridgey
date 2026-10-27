package dev.bridgey.android.sms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.telephony.SmsManager
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/*
 * Sends one SMS with SmsManager from a chosen SIM and reports sent and delivered through
 * PendingIntents to [SmsResultReceiver] (not exported). Bridgey is never the default SMS app, so
 * Android writes the sent message to the provider itself. Bodies and numbers are never logged.
 */
class SmsSender(private val context: Context) {
    /** Outcomes for one send: sent (or failed with a reason), then delivered when the network says so. */
    fun interface Listener {
        fun update(state: SendState, reason: SendReason?)
    }

    /** False when nothing could be handed to Android (the listener has already heard why). SmsServer checks SEND_SMS first. */
    @android.annotation.SuppressLint("MissingPermission")
    fun send(address: String, body: String, subId: Int?, listener: Listener): Boolean {
        val manager = manager(subId)
        if (manager == null) {
            listener.update(SendState.FAILED, SendReason.NO_SIM)
            return false
        }
        val parts = runCatching { manager.divideMessage(body) }.getOrNull()?.takeIf { it.isNotEmpty() } ?: arrayListOf(body)
        val token = "${System.nanoTime()}-${counter.incrementAndGet()}"
        pending[token] = Pending(parts.size, listener)
        val sent = ArrayList<PendingIntent>(parts.size)
        val delivered = ArrayList<PendingIntent>(parts.size)
        parts.indices.forEach { index ->
            sent += resultIntent(ACTION_SENT, token, index)
            delivered += resultIntent(ACTION_DELIVERED, token, index)
        }
        return runCatching {
            if (parts.size == 1) {
                manager.sendTextMessage(address, null, parts[0], sent[0], delivered[0])
            } else {
                manager.sendMultipartTextMessage(address, null, parts, sent, delivered)
            }
            true
        }.getOrElse {
            pending.remove(token)
            listener.update(SendState.FAILED, SendReason.FAILED)
            false
        }
    }

    private fun manager(subId: Int?): SmsManager? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val base = context.getSystemService(SmsManager::class.java) ?: return@runCatching null
            if (subId != null) base.createForSubscriptionId(subId) else base
        } else {
            @Suppress("DEPRECATION")
            if (subId != null) SmsManager.getSmsManagerForSubscriptionId(subId) else SmsManager.getDefault()
        }
    }.getOrNull()

    private fun resultIntent(action: String, token: String, index: Int): PendingIntent {
        val intent = Intent(context, SmsResultReceiver::class.java).setAction(action).putExtra(EXTRA_TOKEN, token).putExtra(EXTRA_PART, index)
        // Mutable so Android can add the delivery report's PDU; the intent names Bridgey's own receiver.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getBroadcast(context, requestCodes.incrementAndGet(), intent, flags)
    }

    private class Pending(val parts: Int, val listener: Listener) {
        var sent = 0
        var delivered = 0
        var failed = false
    }

    companion object {
        const val ACTION_SENT = "dev.bridgey.android.sms.SENT"
        const val ACTION_DELIVERED = "dev.bridgey.android.sms.DELIVERED"
        const val EXTRA_TOKEN = "token"
        const val EXTRA_PART = "part"

        private val counter = AtomicInteger()
        private val requestCodes = AtomicInteger(40_000)
        private val pending = ConcurrentHashMap<String, Pending>()

        /** From [SmsResultReceiver]: one part was sent, or failed, or was delivered. */
        internal fun result(action: String?, token: String?, resultCode: Int, deliveryStatus: Int?) {
            val entry = pending[token ?: return] ?: return
            synchronized(entry) {
                when (action) {
                    ACTION_SENT -> {
                        if (entry.failed) return
                        if (resultCode != Activity.RESULT_OK) {
                            entry.failed = true
                            pending.remove(token)
                            entry.listener.update(SendState.FAILED, sentFailure(resultCode))
                            return
                        }
                        entry.sent++
                        if (entry.sent == entry.parts) entry.listener.update(SendState.SENT, null)
                    }
                    ACTION_DELIVERED -> {
                        // TP-Status 0 to 31: delivered; 32 to 63: the network is still trying; 64 and up: failed.
                        if (entry.failed || (deliveryStatus != null && deliveryStatus >= 32)) return
                        entry.delivered++
                        if (entry.delivered == entry.parts) {
                            pending.remove(token)
                            entry.listener.update(SendState.DELIVERED, null)
                        }
                    }
                }
            }
            // Delivery reports may never come; keep the table small.
            while (pending.size > 64) pending.keys.firstOrNull()?.let(pending::remove)
        }

        internal fun sentFailure(resultCode: Int): SendReason = when (resultCode) {
            SmsManager.RESULT_ERROR_RADIO_OFF -> SendReason.RADIO_OFF
            SmsManager.RESULT_ERROR_NO_SERVICE -> SendReason.NO_SERVICE
            else -> SendReason.FAILED
        }
    }
}

/** Sent and delivery results for [SmsSender]; not exported, only Bridgey's own PendingIntents reach it. */
class SmsResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = if (intent.action == SmsSender.ACTION_DELIVERED) deliveryStatus(intent) else null
        SmsSender.result(intent.action, intent.getStringExtra(SmsSender.EXTRA_TOKEN), resultCode, status)
    }

    /** The TP-Status of the delivery report, when Android attached it. */
    private fun deliveryStatus(intent: Intent): Int? = runCatching {
        val pdu = intent.getByteArrayExtra("pdu") ?: return null
        val format = intent.getStringExtra("format")
        @Suppress("DEPRECATION")
        val message = if (format != null) android.telephony.SmsMessage.createFromPdu(pdu, format) else android.telephony.SmsMessage.createFromPdu(pdu)
        message?.status
    }.getOrNull()
}
