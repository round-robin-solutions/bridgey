package dev.bridgey.android.dialer

import dev.bridgey.android.sms.SimInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/** What the Calls window needs from the phone; [AndroidDialerPhone] is the real one, tests use a fake. */
interface DialerPhone {
    val canPlace: Boolean
    val contactsAccess: Access
    val recentsAccess: Access
    fun whatsAppInstalled(): Boolean
    fun sims(): List<SimInfo>
    fun contacts(query: String): List<DialerContact>
    fun recents(limit: Int): List<RecentCall>
    fun emergency(number: String): Boolean
    /** The MIME type and contact name of a data row, or null. */
    fun dataRow(dataId: Long): Pair<String, String?>?
    /** Starts the call through Telecom on [sim]; true when Telecom took it. */
    fun placeCall(number: String, sim: SimChoice): Boolean
    /** Android lets Bridgey open another app's screen now (in front, or an exemption). */
    fun canOpenScreens(): Boolean
    fun openWhatsApp(spec: WhatsAppIntentSpec): Boolean
    /** A notification that starts the call when tapped; false when notifications are off. */
    fun confirm(request: PendingCall, macName: String): Boolean
}

/** A call waiting for a tap on the phone (Ask on this phone first, no CALL_PHONE, or WhatsApp from the background). */
sealed interface PendingCall {
    data class Phone(val number: String, val subId: Int?) : PendingCall
    data class WhatsApp(val spec: WhatsAppIntentSpec, val name: String?, val video: Boolean) : PendingCall
}

/** What the activity stream records for a call from a Mac. */
enum class DialerActivity { PHONE_STARTED, WHATSAPP_STARTED, WAITING }

/**
 * The phone's side of the Calls window for every Mac that shows dialer_draft1: answers contact
 * searches and recent calls, places calls and reports status. Each request is checked against this
 * phone's switch and that Mac's grant again before anything happens. Nothing is kept; names and
 * numbers are never logged (only outcomes reach diagnostics).
 */
class DialerServer(
    private val phone: DialerPhone,
    private val scope: CoroutineScope,
    /** The Calls window switch is on and this Mac is allowed. */
    private val localEnabled: (deviceId: String) -> Boolean,
    /** Connected Macs where the feature is on at both ends. */
    private val peers: () -> List<String>,
    private val send: (deviceId: String, kind: String, payload: JSONObject) -> Boolean,
    /** Settings > Calls > Ask on this phone first. */
    private val askFirst: () -> Boolean,
    private val macName: (deviceId: String) -> String,
    /** An entry in the activity stream; never silent. */
    private val record: (deviceId: String, activity: DialerActivity) -> Unit,
    /** Outcome only, for diagnostics. */
    private val diagnose: (outcome: String) -> Unit = {},
    clock: () -> Long = { android.os.SystemClock.elapsedRealtime() },
) {
    private val limiter = DialerLimiter(clock)
    private val lastStatus = ConcurrentHashMap<String, String>()

    fun status(): DialerStatus {
        val contacts = phone.contactsAccess
        return DialerStatus(
            place = phone.canPlace,
            confirm = askFirst(),
            contacts = contacts,
            recents = phone.recentsAccess,
            whatsApp = contacts == Access.ON && phone.whatsAppInstalled(),
            sims = phone.sims(),
        )
    }

    /** A Mac's latest map shows the key and this phone allows it: it hears the status. */
    fun peerReady(deviceId: String) {
        lastStatus.remove(deviceId)
        scope.launch { sendStatus(deviceId) }
    }

    fun peerGone(deviceId: String) {
        lastStatus.remove(deviceId)
    }

    fun forget(deviceId: String) {
        lastStatus.remove(deviceId)
        limiter.forget(deviceId)
    }

    /** Permissions, SIMs or a switch may have changed: each Mac hears a status that differs from its last. */
    fun refresh() {
        scope.launch { peers().forEach(::sendStatus) }
    }

    private fun sendStatus(deviceId: String) {
        val payload = dialerStatusPayload(status())
        val text = payload.toString()
        if (lastStatus[deviceId] == text) return
        if (send(deviceId, DialerKinds.STATUS, payload)) lastStatus[deviceId] = text
    }

    /** One decrypted dialer.* plaintext from [deviceId]; malformed ones are dropped. */
    fun receive(deviceId: String, kind: String, plaintext: ByteArray) {
        val request = decodeDialerRequest(kind, plaintext) ?: return
        scope.launch { handle(deviceId, request) }
    }

    internal fun handle(deviceId: String, request: DialerRequest) {
        when (request) {
            is DialerRequest.Contacts -> contacts(deviceId, request)
            is DialerRequest.Recents -> recents(deviceId, request)
            is DialerRequest.Call -> call(deviceId, request)
        }
    }

    private fun readError(deviceId: String, access: Access, allowed: Boolean): String? = when {
        !localEnabled(deviceId) -> "disabled"
        access == Access.UNAVAILABLE -> "unavailable"
        access != Access.ON -> "permission"
        !allowed -> "rate_limited"
        else -> null
    }

    private fun contacts(deviceId: String, request: DialerRequest.Contacts) {
        val error = readError(deviceId, phone.contactsAccess, localEnabled(deviceId) && limiter.allowContacts(deviceId))
        val contacts = if (error == null) runCatching { phone.contacts(request.query) }.getOrDefault(emptyList()) else emptyList()
        send(deviceId, DialerKinds.CONTACTS_RESULT, dialerContactsPayload(request.requestId, contacts, error))
    }

    private fun recents(deviceId: String, request: DialerRequest.Recents) {
        val error = readError(deviceId, phone.recentsAccess, localEnabled(deviceId) && limiter.allowRecents(deviceId))
        val calls = if (error == null) runCatching { phone.recents(request.limit) }.getOrDefault(emptyList()) else emptyList()
        send(deviceId, DialerKinds.RECENTS_RESULT, dialerRecentsPayload(request.requestId, calls, error))
    }

    private fun call(deviceId: String, request: DialerRequest.Call) {
        val (outcome, reason) = place(deviceId, request)
        diagnose(if (outcome == CallOutcome.REFUSED) "refused_${reason?.wire}" else outcome.wire)
        send(deviceId, DialerKinds.CALL_RESULT, dialerCallResultPayload(request.requestId, outcome, reason))
    }

    /** Decides and acts; the result goes back to the Mac. */
    internal fun place(deviceId: String, request: DialerRequest.Call): Pair<CallOutcome, RefuseReason?> {
        fun refused(reason: RefuseReason) = CallOutcome.REFUSED to reason
        if (!localEnabled(deviceId)) return refused(RefuseReason.DISABLED)
        if (!limiter.allowCall(deviceId)) return refused(RefuseReason.RATE_LIMITED)
        val mac = macName(deviceId)
        fun waiting(pending: PendingCall): Pair<CallOutcome, RefuseReason?> {
            if (!phone.confirm(pending, mac)) return refused(RefuseReason.PERMISSION)
            record(deviceId, DialerActivity.WAITING)
            return CallOutcome.CONFIRM to null
        }
        if (request.via == CallVia.PHONE) {
            val number = request.address ?: return refused(RefuseReason.INVALID)
            if (phone.emergency(number)) return refused(RefuseReason.EMERGENCY)
            val sims = phone.sims()
            val sim = chooseSim(request.subId, sims)
            if (sim == SimChoice.Missing) return refused(RefuseReason.NO_SIM)
            if (!phone.canPlace || askFirst()) return waiting(PendingCall.Phone(number, (sim as? SimChoice.Sim)?.subId))
            if (!phone.placeCall(number, sim)) return refused(RefuseReason.FAILED)
            record(deviceId, DialerActivity.PHONE_STARTED)
            return CallOutcome.STARTED to null
        }
        when (phone.contactsAccess) {
            Access.UNAVAILABLE -> return refused(RefuseReason.UNAVAILABLE)
            Access.OFF -> return refused(RefuseReason.PERMISSION)
            Access.ON -> Unit
        }
        if (!phone.whatsAppInstalled()) return refused(RefuseReason.UNAVAILABLE)
        val dataId = request.dataId ?: return refused(RefuseReason.INVALID)
        val row = phone.dataRow(dataId)
        val spec = whatsAppIntent(request.via, dataId, row?.first) ?: return refused(RefuseReason.NOT_FOUND)
        val pending = PendingCall.WhatsApp(spec, row?.second, request.via == CallVia.WHATSAPP_VIDEO)
        if (askFirst() || !phone.canOpenScreens()) return waiting(pending)
        if (!phone.openWhatsApp(spec)) return waiting(pending)
        record(deviceId, DialerActivity.WHATSAPP_STARTED)
        return CallOutcome.STARTED to null
    }
}
