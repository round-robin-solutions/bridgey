package dev.bridgey.android

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.telephony.PhoneNumberUtils
import android.telephony.TelephonyManager
import org.json.JSONObject

internal enum class RemoteCallResult(val wireKind: String) {
    STARTED("calls.started"),
    CONFIRMATION_REQUIRED("calls.confirmation_required"),
    REJECTED("calls.rejected"),
}

internal fun normalizedPhoneNumber(value: String): String? {
    val trimmed = value.trim()
    if (trimmed.isEmpty() || trimmed.any { it !in '0'..'9' && it !in "+-(). " }) return null
    if (trimmed.count { it == '+' } > 1 || ('+' in trimmed && !trimmed.startsWith('+'))) return null
    val normalized = buildString {
        if (trimmed.startsWith('+')) append('+')
        trimmed.forEach { if (it in '0'..'9') append(it) }
    }
    val digits = normalized.count { it in '0'..'9' }
    return normalized.takeIf { digits in 3..15 }
}

/**
 * The number a calls.request payload asks to dial, or null (answered `calls.rejected`). `number` must be a JSON string:
 * org.json on a phone would turn a JSON number into text, which the contract does not allow and the JVM tests could
 * not see, so the type is checked here.
 */
internal fun callRequestNumber(plaintext: ByteArray): String? =
    (runCatching { JSONObject(plaintext.toString(Charsets.UTF_8)) }.getOrNull()?.opt("number") as? String)?.let(::normalizedPhoneNumber)

internal class RemoteCallRequest(private val context: Context) {
    fun execute(number: String, directEnabled: Boolean): RemoteCallResult {
        val normalized = normalizedPhoneNumber(number) ?: return RemoteCallResult.REJECTED
        val uri = Uri.fromParts("tel", normalized, null)
        val canCallDirectly = directEnabled &&
            context.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED &&
            !isEmergencyNumber(normalized)
        if (canCallDirectly) {
            return runCatching {
                context.getSystemService(TelecomManager::class.java).placeCall(uri, android.os.Bundle.EMPTY)
                RemoteCallResult.STARTED
            }.getOrDefault(RemoteCallResult.REJECTED)
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return RemoteCallResult.REJECTED
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.channel_calls), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.channel_calls_detail)
            },
        )
        val dialIntent = Intent()
        dialIntent.setClass(context, ConfirmCallActivity::class.java)
        dialIntent.data = uri // Distinct PendingIntent identity for each validated number.
        dialIntent.putExtra("number", normalized)
        dialIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pendingIntent = PendingIntent.getActivity(
            context,
            normalized.hashCode(),
            dialIntent,
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = android.app.Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(dev.bridgey.android.R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.call_request_title))
            .setContentText(normalized)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .addAction(
                android.app.Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(context, android.R.drawable.sym_action_call),
                    context.getString(R.string.call_request_open),
                    pendingIntent,
                ).build(),
            )
            .build()
        manager.notify(NOTIFICATION_ID, notification)
        return RemoteCallResult.CONFIRMATION_REQUIRED
    }

    @Suppress("DEPRECATION")
    private fun isEmergencyNumber(number: String): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= 29) {
            context.getSystemService(TelephonyManager::class.java).isEmergencyNumber(number)
        } else {
            PhoneNumberUtils.isEmergencyNumber(number)
        }
    }.getOrDefault(true)

    companion object {
        private const val CHANNEL_ID = "bridgey_call_requests"
        private const val NOTIFICATION_ID = 41_770
    }
}

/** Only an explicit user tap on Bridgey's immutable notification can enter here. */
class ConfirmCallActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        val number = intent.getStringExtra("number")?.let(::normalizedPhoneNumber)
        if (number != null) {
            runCatching { startActivity(Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null))) }
                .onFailure { android.widget.Toast.makeText(this, R.string.call_request_no_dialer, android.widget.Toast.LENGTH_SHORT).show() }
        }
        finish()
    }
}
