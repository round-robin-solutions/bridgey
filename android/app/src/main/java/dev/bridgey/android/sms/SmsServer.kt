package dev.bridgey.android.sms

import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * An SMS notification the Mac may answer: what the listener saw, the app's own reply action (if it
 * has one) and the conversation, when found. Kept in memory while the notification is active.
 */
data class SmsNotificationTarget(
    val notificationId: String,
    val title: String,
    val text: String,
    val postTime: Long,
    val threadId: Long?,
    /** The forwarded action token of the app's free-form reply (RemoteInput), if any. */
    val replyToken: String?,
)

/** The SMS notifications active on the phone, newest kept, at most 256. */
object SmsNotificationTargets {
    private val targets = object : LinkedHashMap<String, SmsNotificationTarget>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, SmsNotificationTarget>?): Boolean = size > 256
    }

    @Synchronized fun record(target: SmsNotificationTarget) {
        targets.remove(target.notificationId)
        targets[target.notificationId] = target
    }

    @Synchronized fun get(notificationId: String): SmsNotificationTarget? = targets[notificationId]

    @Synchronized fun remove(notificationId: String) {
        targets.remove(notificationId)
    }

    @Synchronized fun clear() = targets.clear()
}

/**
 * The phone's side of Text messages for every Mac that shows sms_draft1: answers the Mac's page,
 * sync, image and contact requests from the provider, sends SMS, reports status and changes. Nothing
 * is kept on the phone; bodies, numbers and names are never logged.
 */
class SmsServer(
    private val provider: SmsProvider,
    private val sender: SmsSender,
    private val scope: CoroutineScope,
    /** This phone's Text messages switch is on for that Mac. */
    private val localEnabled: (deviceId: String) -> Boolean,
    /** Connected Macs where the feature is on at both ends. */
    private val peers: () -> List<String>,
    private val send: (deviceId: String, kind: String, payload: JSONObject) -> Boolean,
    /** Settings > Text messages > Send replies as SMS. */
    private val replyAsSms: () -> Boolean,
    /** Runs the app's own reply on the notification; true when Android took it. */
    private val performAppReply: (notificationId: String, token: String, text: String) -> Boolean,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val limiter = SmsSendLimiter(clock)
    private val throttle = ChangeThrottle()
    private val lastStatus = ConcurrentHashMap<String, String>()
    private val imageLocks = ConcurrentHashMap<String, Mutex>()
    private val handler by lazy { Handler(Looper.getMainLooper()) }
    private var observerRegistered = false
    private val announce = Runnable {
        scope.launch {
            val targets = peers()
            if (targets.isEmpty()) return@launch
            val payload = smsChangedPayload(provider.cursor())
            targets.forEach { send(it, SmsKinds.CHANGED, payload) }
            throttle.sent(clock())
        }
    }
    private val observer by lazy {
        object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) = providerChanged()
        }
    }

    /** A Mac's latest map shows the key and this phone's switch is on: it hears the status, and changes. */
    fun peerReady(deviceId: String) {
        lastStatus.remove(deviceId)
        scope.launch { sendStatus(deviceId) }
        updateObserver()
    }

    /** A Mac left (disconnected, or the feature went off at either end). */
    fun peerGone(deviceId: String) {
        lastStatus.remove(deviceId)
        imageLocks.remove(deviceId)
        updateObserver()
    }

    /** Permissions, SIMs or settings may have changed: each Mac hears a status that differs from its last. */
    fun refresh() {
        scope.launch { peers().forEach { sendStatus(it) } }
        updateObserver()
    }

    private fun sendStatus(deviceId: String) {
        val payload = smsStatusPayload(provider.canRead, provider.canSend, provider.canReadContacts, provider.sims(), provider.cursor())
        val text = payload.toString()
        if (lastStatus[deviceId] == text) return
        if (send(deviceId, SmsKinds.STATUS, payload)) lastStatus[deviceId] = text
    }

    /** The provider observer runs only while some Mac is listening and SMS may be read. */
    @Synchronized fun updateObserver() {
        val wanted = provider.canRead && peers().isNotEmpty()
        if (wanted == observerRegistered) return
        val resolver = provider.resolver
        runCatching {
            if (wanted) resolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, observer) else resolver.unregisterContentObserver(observer)
            observerRegistered = wanted
        }
        if (!wanted) handler.removeCallbacks(announce)
    }

    private fun providerChanged() {
        handler.removeCallbacks(announce)
        handler.postDelayed(announce, throttle.delayFor(clock()))
    }

    // MARK: Requests from a Mac

    /** One decrypted sms.* plaintext from [deviceId]; malformed ones are dropped. */
    fun receive(deviceId: String, kind: String, plaintext: ByteArray) {
        if (kind == SmsKinds.SEND) {
            val request = decodeSmsSend(plaintext) ?: return
            scope.launch { handleSend(deviceId, request) }
            return
        }
        val request = decodeSmsRequest(kind, plaintext) ?: return
        scope.launch {
            when (request) {
                is SmsRequest.Threads -> threads(deviceId, request)
                is SmsRequest.Messages -> messages(deviceId, request)
                is SmsRequest.Sync -> sync(deviceId, request)
                is SmsRequest.Attachment -> imageLocks.getOrPut(deviceId, ::Mutex).withLock { attachment(deviceId, request) }
                is SmsRequest.Contacts -> contacts(deviceId, request)
            }
        }
    }

    /** Why a page cannot be read, if it cannot. */
    private fun pageError(deviceId: String): String? = when {
        !localEnabled(deviceId) -> "disabled"
        !provider.canRead -> "permission"
        else -> null
    }

    private fun threads(deviceId: String, request: SmsRequest.Threads) {
        val error = pageError(deviceId)
        if (error != null) {
            send(deviceId, SmsKinds.THREADS_PAGE, pageBase(request.requestId, error).put("threads", JSONArray()).put("more", false))
            return
        }
        val (threads, more) = provider.threads(request.before, request.limit)
        val room = pageRoom(pageBase(request.requestId).put("threads", JSONArray()).put("more", true))
        val (kept, cut) = fitEntries(threads.map(SmsThread::toJson), room)
        send(deviceId, SmsKinds.THREADS_PAGE, pageBase(request.requestId).put("threads", JSONArray(kept)).put("more", more || cut))
    }

    private fun messages(deviceId: String, request: SmsRequest.Messages) {
        fun empty(error: String) = pageBase(request.requestId, error).put("threadId", request.threadId).put("messages", JSONArray()).put("more", false)
        val error = pageError(deviceId)
        if (error != null) {
            send(deviceId, SmsKinds.MESSAGES_PAGE, empty(error))
            return
        }
        val (messages, more) = provider.conversation(request.threadId, request.before, request.limit)
        if (messages.isEmpty() && request.before == null && provider.participants(request.threadId).isEmpty()) {
            send(deviceId, SmsKinds.MESSAGES_PAGE, empty("not_found"))
            return
        }
        val room = pageRoom(pageBase(request.requestId).put("threadId", request.threadId).put("messages", JSONArray()).put("more", true))
        val (kept, cut) = fitEntries(messages.map(SmsMessage::toJson), room)
        send(deviceId, SmsKinds.MESSAGES_PAGE, pageBase(request.requestId).put("threadId", request.threadId).put("messages", JSONArray(kept)).put("more", more || cut))
    }

    private fun sync(deviceId: String, request: SmsRequest.Sync) {
        val error = pageError(deviceId)
        if (error != null) {
            send(
                deviceId, SmsKinds.SYNC_PAGE,
                pageBase(request.requestId, error).put("messages", JSONArray()).put("cursor", request.since.toJson()).put("more", false).put("reset", false),
            )
            return
        }
        // Read before the rows, so a message written meanwhile is never skipped.
        val current = provider.cursor()
        if (planSync(request.since, current, provider.countNewer(request.since)) == SyncPlan.Reset) {
            send(deviceId, SmsKinds.SYNC_PAGE, pageBase(request.requestId).put("messages", JSONArray()).put("cursor", current.toJson()).put("more", false).put("reset", true))
            return
        }
        val (sms, mms, full) = provider.newer(request.since, request.limit)
        val room = pageRoom(pageBase(request.requestId).put("messages", JSONArray()).put("cursor", current.toJson()).put("more", true).put("reset", false))
        val page = syncPage(request.since, sms, mms, request.limit, room, full)
        val cursor = if (page.more) page.cursor else SmsCursor(maxOf(page.cursor.sms, current.sms), maxOf(page.cursor.mms, current.mms))
        send(
            deviceId, SmsKinds.SYNC_PAGE,
            pageBase(request.requestId).put("messages", JSONArray(page.messages)).put("cursor", cursor.toJson()).put("more", page.more).put("reset", false),
        )
    }

    private fun attachment(deviceId: String, request: SmsRequest.Attachment) {
        val base = pageBase(request.requestId).put("partId", request.partId)
        if (!localEnabled(deviceId)) {
            send(deviceId, SmsKinds.ATTACHMENT_DATA, base.put("error", "permission"))
            return
        }
        when (val image = provider.image(request.partId)) {
            is SmsProvider.ImageResult.Error -> send(deviceId, SmsKinds.ATTACHMENT_DATA, base.put("error", image.reason))
            is SmsProvider.ImageResult.Image -> send(
                deviceId, SmsKinds.ATTACHMENT_DATA,
                base.put("mimeType", "image/jpeg").put("width", image.width).put("height", image.height).put("data", provider.imageData(image)),
            )
        }
    }

    private fun contacts(deviceId: String, request: SmsRequest.Contacts) {
        val base = pageBase(request.requestId)
        if (!localEnabled(deviceId) || !provider.canReadContacts) {
            send(deviceId, SmsKinds.CONTACTS_RESULT, base.put("contacts", JSONArray()).put("error", "permission"))
            return
        }
        val room = pageRoom(pageBase(request.requestId).put("contacts", JSONArray()), SmsLimits.CONTACTS_RESULT_MAX_BYTES)
        val (kept, _) = fitEntries(provider.contacts(request.query).map(SmsContact::toJson), room)
        send(deviceId, SmsKinds.CONTACTS_RESULT, base.put("contacts", JSONArray(kept)))
    }

    // MARK: Sending

    private fun handleSend(deviceId: String, request: SmsSendRequest) {
        fun status(state: SendState, reason: SendReason? = null, via: SendVia? = null) =
            send(deviceId, SmsKinds.SEND_STATUS, smsSendStatusPayload(request.requestId, state, reason, via))
        if (!localEnabled(deviceId)) {
            status(SendState.REFUSED, SendReason.DISABLED)
            return
        }
        if (!limiter.allow(deviceId)) {
            status(SendState.REFUSED, SendReason.RATE_LIMITED)
            return
        }
        when (val target = request.target) {
            is SendTarget.Notification -> replyToNotification(request, target.notificationId, ::status)
            is SendTarget.Thread -> {
                val participants = if (provider.canRead) provider.participants(target.threadId) else emptyList()
                when {
                    !provider.canRead -> status(SendState.REFUSED, SendReason.PERMISSION)
                    participants.isEmpty() -> status(SendState.REFUSED, SendReason.NOT_FOUND)
                    participants.size > 1 -> status(SendState.REFUSED, SendReason.GROUP)
                    else -> sendSms(participants[0], request.body, request.subId, provider.lastSubId(target.threadId), ::status)
                }
            }
            is SendTarget.Address -> {
                val usual = if (provider.canRead) provider.threadForAddress(target.address)?.let(provider::lastSubId) else null
                sendSms(target.address, request.body, request.subId, usual, ::status)
            }
        }
    }

    private fun replyToNotification(
        request: SmsSendRequest,
        notificationId: String,
        status: (SendState, SendReason?, SendVia?) -> Boolean,
    ) {
        val target = SmsNotificationTargets.get(notificationId)
        if (target == null) {
            status(SendState.REFUSED, SendReason.NOT_FOUND, null)
            return
        }
        val token = target.replyToken
        fun viaApp(token: String) {
            val ok = performAppReply(notificationId, token, request.body)
            status(if (ok) SendState.SENT else SendState.FAILED, if (ok) null else SendReason.FAILED, SendVia.APP)
        }
        // The messaging app's own reply keeps its chat features, unless Send replies as SMS is on.
        if (token != null && !replyAsSms()) {
            viaApp(token)
            return
        }
        val threadId = target.threadId ?: if (provider.canRead) {
            matchNotificationThread(target.title, target.text, target.postTime, provider.recentInbox(target.postTime - MATCH_WINDOW_BEFORE_MILLIS))
        } else {
            null
        }
        val participants = threadId?.let { provider.participants(it) }.orEmpty()
        when {
            participants.size == 1 && provider.canSend -> sendSms(participants[0], request.body, null, threadId?.let(provider::lastSubId), status)
            token != null -> viaApp(token)
            participants.size > 1 -> status(SendState.REFUSED, SendReason.GROUP, null)
            !provider.canSend || !provider.canRead -> status(SendState.REFUSED, SendReason.PERMISSION, null)
            else -> status(SendState.REFUSED, SendReason.NOT_FOUND, null)
        }
    }

    /**
     * One SMS to [address]: from [chosen] (the Mac's pick; refused when that SIM is gone) or else
     * [usual] (the conversation's last SIM, ignored when gone), else the phone's default.
     */
    private fun sendSms(address: String, body: String, chosen: Int?, usual: Int?, status: (SendState, SendReason?, SendVia?) -> Boolean) {
        if (!provider.canSend) {
            status(SendState.REFUSED, SendReason.PERMISSION, null)
            return
        }
        if (provider.emergency(address)) {
            status(SendState.REFUSED, SendReason.INVALID, null)
            return
        }
        val sims = provider.sims()
        if (chosen != null && sims.isNotEmpty() && sims.none { it.subId == chosen }) {
            status(SendState.REFUSED, SendReason.NO_SIM, null)
            return
        }
        val subId = when {
            chosen != null -> chosen
            usual != null && (sims.isEmpty() || sims.any { it.subId == usual }) -> usual
            else -> null
        }
        status(SendState.SENDING, null, SendVia.SMS)
        sender.send(address, body, subId) { state, reason -> status(state, reason, SendVia.SMS) }
    }

}
