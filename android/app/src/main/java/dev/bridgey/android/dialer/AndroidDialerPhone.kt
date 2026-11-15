package dev.bridgey.android.dialer

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.telecom.TelecomManager
import android.widget.Toast
import dev.bridgey.android.R
import dev.bridgey.android.normalizedPhoneNumber
import dev.bridgey.android.sms.SimInfo

/**
 * The real phone behind [DialerServer]: [DialerProvider] for reading, Telecom for calls, WhatsApp's
 * own contact rows for WhatsApp calls, and a notification when the call has to wait for a tap.
 */
class AndroidDialerPhone(
    private val context: Context,
    private val provider: DialerProvider = DialerProvider(context),
    /** An activity of Bridgey is started, so Android lets it open another app's screen. */
    private val inFront: () -> Boolean = { false },
) : DialerPhone {
    override val canPlace: Boolean get() = provider.canPlace
    override val contactsAccess: Access get() = provider.contactsAccess
    override val recentsAccess: Access get() = provider.recentsAccess
    override fun whatsAppInstalled(): Boolean = provider.whatsAppInstalled()
    override fun sims(): List<SimInfo> = provider.sims()
    override fun contacts(query: String): List<DialerContact> = provider.contacts(query)
    override fun recents(limit: Int): List<RecentCall> = provider.recents(limit)
    override fun emergency(number: String): Boolean = provider.emergency(number)
    override fun dataRow(dataId: Long): Pair<String, String?>? = provider.dataRow(dataId)

    override fun placeCall(number: String, sim: SimChoice): Boolean = DialerCalls.place(context, provider, number, (sim as? SimChoice.Sim)?.subId)

    /**
     * Android opens another app's screen from the background only with an exemption: Bridgey in front,
     * Display over other apps allowed, or a companion device link (Codes from messages makes one).
     */
    override fun canOpenScreens(): Boolean {
        if (inFront()) return true
        if (runCatching { Settings.canDrawOverlays(context) }.getOrDefault(false)) return true
        return runCatching {
            val manager = context.getSystemService(CompanionDeviceManager::class.java) ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) manager.myAssociations.isNotEmpty()
            else @Suppress("DEPRECATION") manager.associations.isNotEmpty()
        }.getOrDefault(false)
    }

    override fun openWhatsApp(spec: WhatsAppIntentSpec): Boolean = DialerCalls.openWhatsApp(context, spec)

    override fun confirm(request: PendingCall, macName: String): Boolean = DialerCalls.notifyPending(context, request, macName)
}

/** Starting calls, shared by the server and the notification's activity. */
object DialerCalls {
    private const val CHANNEL_ID = "bridgey_dialer_calls_v1"
    private const val NOTIFICATION_ID = 41_790
    private const val LIFETIME_MILLIS = 2 * 60_000L

    internal const val EXTRA_KIND = "dialer.kind"
    internal const val EXTRA_NUMBER = "dialer.number"
    internal const val EXTRA_SUB_ID = "dialer.subId"
    internal const val EXTRA_DATA_ID = "dialer.dataId"
    internal const val EXTRA_VIA = "dialer.via"

    /** Through Telecom, on [subId]'s phone account when it matches one, else the phone's default. */
    @SuppressLint("MissingPermission")
    fun place(context: Context, provider: DialerProvider, number: String, subId: Int?): Boolean {
        if (context.checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) return false
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return false
        val extras = Bundle()
        subId?.let(provider::phoneAccount)?.let { extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, it) }
        return runCatching { telecom.placeCall(Uri.fromParts("tel", number, null), extras) }.isSuccess
    }

    fun whatsAppViewIntent(spec: WhatsAppIntentSpec): Intent = Intent(Intent.ACTION_VIEW)
        .setDataAndType(Uri.parse(spec.dataUri), spec.mimeType)
        .setPackage(spec.packageName)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    fun openWhatsApp(context: Context, spec: WhatsAppIntentSpec): Boolean =
        runCatching { context.startActivity(whatsAppViewIntent(spec)) }.isSuccess

    /** A notification whose tap starts [request]; the activity checks everything again. */
    fun notifyPending(context: Context, request: PendingCall, macName: String): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!manager.areNotificationsEnabled()) return false
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.dialer_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.dialer_channel_detail)
            },
        )
        val intent = Intent(context, DialerConfirmActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val (title, text) = when (request) {
            is PendingCall.Phone -> {
                intent.putExtra(EXTRA_KIND, "phone").putExtra(EXTRA_NUMBER, request.number)
                request.subId?.let { intent.putExtra(EXTRA_SUB_ID, it) }
                intent.data = Uri.fromParts("tel", request.number, null)
                context.getString(R.string.dialer_notification_title, macName) to request.number
            }
            is PendingCall.WhatsApp -> {
                val dataId = Uri.parse(request.spec.dataUri).lastPathSegment?.toLongOrNull() ?: return false
                intent.putExtra(EXTRA_KIND, "whatsapp").putExtra(EXTRA_DATA_ID, dataId)
                    .putExtra(EXTRA_VIA, if (request.video) CallVia.WHATSAPP_VIDEO.wire else CallVia.WHATSAPP_VOICE.wire)
                intent.data = Uri.parse("bridgey-dialer://whatsapp/$dataId")
                val title = context.getString(
                    if (request.video) R.string.dialer_notification_whatsapp_video else R.string.dialer_notification_whatsapp_voice, macName,
                )
                title to (request.name ?: context.getString(R.string.dialer_notification_whatsapp_contact))
            }
        }
        val pending = PendingIntent.getActivity(context, NOTIFICATION_ID, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(pending)
            .addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(context, android.R.drawable.sym_action_call),
                    context.getString(R.string.dialer_notification_call), pending,
                ).build(),
            )
            .setAutoCancel(true)
            .setTimeoutAfter(LIFETIME_MILLIS)
            .build()
        return runCatching { manager.notify(NOTIFICATION_ID, notification) }.isSuccess
    }

    internal fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }
}

/**
 * Only a tap on Bridgey's immutable notification enters here. It checks the request again: a number
 * that is still valid and not an emergency number, a row that is still a WhatsApp call row.
 */
class DialerConfirmActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DialerCalls.cancel(this)
        val provider = DialerProvider(this)
        val started = when (intent.getStringExtra(DialerCalls.EXTRA_KIND)) {
            "phone" -> {
                val number = intent.getStringExtra(DialerCalls.EXTRA_NUMBER)?.let(::normalizedPhoneNumber)
                when {
                    number == null || provider.emergency(number) -> false
                    provider.canPlace -> DialerCalls.place(this, provider, number, intent.takeIf { it.hasExtra(DialerCalls.EXTRA_SUB_ID) }?.getIntExtra(DialerCalls.EXTRA_SUB_ID, -1))
                    else -> runCatching { startActivity(Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null))) }.isSuccess
                }
            }
            "whatsapp" -> {
                val dataId = intent.getLongExtra(DialerCalls.EXTRA_DATA_ID, 0)
                val via = intent.getStringExtra(DialerCalls.EXTRA_VIA)?.let(CallVia::fromWire)
                val spec = via?.let { whatsAppIntent(it, dataId, provider.dataRow(dataId)?.first) }
                spec != null && DialerCalls.openWhatsApp(this, spec)
            }
            else -> false
        }
        if (!started) Toast.makeText(this, R.string.dialer_notification_failed, Toast.LENGTH_SHORT).show()
        finish()
    }
}
