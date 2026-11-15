package dev.bridgey.android.dialer

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.normalizedPhoneNumber
import dev.bridgey.android.sms.SimInfo
import dev.bridgey.android.sms.smsRequestId
import dev.bridgey.android.strictJsonObject
import org.json.JSONArray
import org.json.JSONObject

/*
 * Calls window (draft dialer_draft1, docs/protocol.md "Draft: Calls window"): the phone's side of the
 * wire. Pure Kotlin and org.json only, so decoders, encoders, limits, the SIM choice and the WhatsApp
 * intent are tested in plain JUnit against protocol/test-vectors/dialer-v1.json. Names and numbers are
 * never logged.
 */

const val DIALER_FEATURE_KEY = "dialer_draft1"

/** The dialer.* kinds (the contract tests read this list). */
object DialerKinds {
    const val STATUS = "dialer.status"
    const val CONTACTS = "dialer.contacts"
    const val CONTACTS_RESULT = "dialer.contacts_result"
    const val RECENTS = "dialer.recents"
    const val RECENTS_RESULT = "dialer.recents_result"
    const val CALL = "dialer.call"
    const val CALL_RESULT = "dialer.call_result"

    /** What a Mac may send to the phone. */
    val fromMac = setOf(CONTACTS, RECENTS, CALL)
}

object DialerLimits {
    const val REQUEST_MAX_BYTES = 1_024
    const val STATUS_MAX_BYTES = 2_048
    const val CONTACTS_RESULT_MAX_BYTES = 16_384
    const val RECENTS_RESULT_MAX_BYTES = 40_960
    const val CALL_RESULT_MAX_BYTES = 1_024
    const val QUERY_MAX = 64
    const val CONTACTS_MAX = 20
    const val NUMBERS_MAX = 8
    const val WHATSAPP_MAX = 4
    const val RECENTS_MAX = 50
    const val NAME_MAX = 128
    const val ADDRESS_MAX = 64
    const val LABEL_MAX = 32
    const val SIMS_MAX = 4
    const val SIM_LABEL_MAX = 64
}

/** A request from a Mac, decoded. */
sealed interface DialerRequest {
    val requestId: String

    data class Contacts(override val requestId: String, val query: String) : DialerRequest
    data class Recents(override val requestId: String, val limit: Int) : DialerRequest
    data class Call(override val requestId: String, val via: CallVia, val address: String?, val subId: Int?, val dataId: Long?) : DialerRequest
}

enum class CallVia(val wire: String) {
    PHONE("phone"), WHATSAPP_VOICE("whatsapp_voice"), WHATSAPP_VIDEO("whatsapp_video");

    val whatsApp: Boolean get() = this != PHONE

    companion object {
        fun fromWire(value: String): CallVia? = entries.firstOrNull { it.wire == value }
    }
}

private fun JSONObject.absent(name: String): Boolean = !has(name) || isNull(name)

private fun decodeObject(plaintext: ByteArray, maxBytes: Int): JSONObject? {
    if (plaintext.size > maxBytes) return null
    val payload = strictJsonObject(plaintext) ?: return null
    return payload.takeIf { jsonInteger(it.opt("version")) == 1L }
}

/** dialer.contacts, dialer.recents or dialer.call, or null when malformed (the dialer request vectors). */
fun decodeDialerRequest(kind: String, plaintext: ByteArray): DialerRequest? {
    val payload = decodeObject(plaintext, DialerLimits.REQUEST_MAX_BYTES) ?: return null
    val requestId = smsRequestId(payload.opt("requestId")) ?: return null
    return when (kind) {
        DialerKinds.CONTACTS -> {
            val raw = payload.opt("query") as? String ?: return null
            if (raw.length > DialerLimits.QUERY_MAX) return null
            val query = raw.trim().takeIf { it.isNotEmpty() } ?: return null
            DialerRequest.Contacts(requestId, query)
        }
        DialerKinds.RECENTS -> {
            val limit = jsonInteger(payload.opt("limit"))?.takeIf { it in 1..DialerLimits.RECENTS_MAX.toLong() } ?: return null
            DialerRequest.Recents(requestId, limit.toInt())
        }
        DialerKinds.CALL -> {
            val via = (payload.opt("via") as? String)?.let(CallVia::fromWire) ?: return null
            if (via == CallVia.PHONE) {
                if (!payload.absent("dataId")) return null
                val address = (payload.opt("address") as? String)?.let(::normalizedPhoneNumber) ?: return null
                val subId = if (payload.absent("subId")) null else {
                    jsonInteger(payload.opt("subId"))?.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
                }
                DialerRequest.Call(requestId, via, address, subId, null)
            } else {
                if (!payload.absent("address") || !payload.absent("subId")) return null
                val dataId = jsonInteger(payload.opt("dataId"))?.takeIf { it >= 1 } ?: return null
                DialerRequest.Call(requestId, via, null, null, dataId)
            }
        }
        else -> null
    }
}

// MARK: Status

enum class Access(val wire: String) { ON("on"), OFF("off"), UNAVAILABLE("unavailable") }

data class DialerStatus(
    /** CALL_PHONE: a call starts without a tap on the phone. */
    val place: Boolean,
    /** Ask on this phone first is on. */
    val confirm: Boolean,
    val contacts: Access,
    val recents: Access,
    val whatsApp: Boolean,
    val sims: List<SimInfo>,
)

fun dialerStatusPayload(status: DialerStatus): JSONObject = JSONObject()
    .put("version", 1)
    .put("place", status.place)
    .put("confirm", status.confirm)
    .put("contacts", status.contacts.wire)
    .put("recents", status.recents.wire)
    .put("whatsapp", status.whatsApp)
    .put("sims", JSONArray(status.sims.take(DialerLimits.SIMS_MAX).map {
        JSONObject().put("subId", it.subId).put("slot", it.slot.coerceIn(0, 3)).put("label", it.label.take(DialerLimits.SIM_LABEL_MAX))
    }))

// MARK: Contacts

data class DialerNumber(val address: String, val label: String? = null)

/** One WhatsApp contact row pair: the number WhatsApp knows and its call rows in ContactsContract.Data. */
data class WhatsAppEntry(val address: String, val voice: Long? = null, val video: Long? = null)

data class DialerContact(
    val id: Long,
    val name: String,
    val starred: Boolean = false,
    val numbers: List<DialerNumber> = emptyList(),
    val whatsApp: List<WhatsAppEntry> = emptyList(),
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name.take(DialerLimits.NAME_MAX))
        if (starred) put("starred", true)
        put("numbers", JSONArray(numbers.take(DialerLimits.NUMBERS_MAX).map { number ->
            JSONObject().put("address", number.address.take(DialerLimits.ADDRESS_MAX)).apply {
                number.label?.takeIf { it.isNotEmpty() }?.let { put("label", it.take(DialerLimits.LABEL_MAX)) }
            }
        }))
        val entries = whatsApp.filter { it.voice != null || it.video != null }.take(DialerLimits.WHATSAPP_MAX)
        if (entries.isNotEmpty()) {
            put("whatsapp", JSONArray(entries.map { entry ->
                JSONObject().put("address", entry.address.take(DialerLimits.ADDRESS_MAX)).apply {
                    entry.voice?.let { put("voice", it) }
                    entry.video?.let { put("video", it) }
                }
            }))
        }
    }
}

fun dialerContactsPayload(requestId: String, contacts: List<DialerContact>, error: String? = null): JSONObject {
    val base = JSONObject().put("version", 1).put("requestId", requestId)
    if (error != null) return base.put("contacts", JSONArray()).put("error", error)
    val kept = JSONArray()
    val emptySize = base.toString().toByteArray().size + ""","contacts":[]""".length
    var size = emptySize
    for (contact in contacts.take(DialerLimits.CONTACTS_MAX)) {
        if (contact.numbers.isEmpty() && contact.whatsApp.none { it.voice != null || it.video != null }) continue
        val json = contact.toJson()
        val add = json.toString().toByteArray().size + if (kept.length() > 0) 1 else 0
        if (size + add > DialerLimits.CONTACTS_RESULT_MAX_BYTES) break
        kept.put(json)
        size += add
    }
    return base.put("contacts", kept)
}

/** A row of Phone or WhatsApp data, as the provider returns it, before grouping by contact. */
data class ContactRow(
    val contactId: Long,
    val name: String?,
    val starred: Boolean,
    val number: DialerNumber? = null,
    val whatsApp: Pair<String, WhatsAppCall>? = null,
)

/** A WhatsApp call row: the data row and whether it is voice or video. */
data class WhatsAppCall(val dataId: Long, val video: Boolean)

/**
 * Phone rows (in the provider's match order) and WhatsApp rows, grouped into at most 20 contacts.
 * Starred contacts come first, then the provider's order; numbers that differ only in spacing are
 * one number. A contact keeps at most 8 numbers and 4 WhatsApp entries.
 */
fun groupContacts(rows: List<ContactRow>, limit: Int = DialerLimits.CONTACTS_MAX): List<DialerContact> {
    data class Building(val id: Long, var name: String, var starred: Boolean, val numbers: MutableList<DialerNumber>, val whatsApp: LinkedHashMap<String, WhatsAppEntry>, val seen: MutableSet<String>)
    val order = LinkedHashMap<Long, Building>()
    for (row in rows) {
        val building = order.getOrPut(row.contactId) {
            Building(row.contactId, row.name?.trim().orEmpty(), row.starred, mutableListOf(), LinkedHashMap(), mutableSetOf())
        }
        if (building.name.isEmpty()) row.name?.trim()?.takeIf { it.isNotEmpty() }?.let { building.name = it }
        building.starred = building.starred || row.starred
        row.number?.let { number ->
            val key = normalizedPhoneNumber(number.address) ?: number.address.filter { it.isDigit() || it == '+' }
            if (key.isNotEmpty() && building.numbers.size < DialerLimits.NUMBERS_MAX && building.seen.add(key)) building.numbers += number
        }
        row.whatsApp?.let { (address, call) ->
            val entry = building.whatsApp[address] ?: WhatsAppEntry(address)
            if (building.whatsApp.size < DialerLimits.WHATSAPP_MAX || address in building.whatsApp) {
                building.whatsApp[address] = if (call.video) entry.copy(video = call.dataId) else entry.copy(voice = call.dataId)
            }
        }
    }
    return order.values
        .filter { it.numbers.isNotEmpty() || it.whatsApp.isNotEmpty() }
        .map { b ->
            val name = b.name.ifEmpty { b.numbers.firstOrNull()?.address ?: b.whatsApp.keys.firstOrNull().orEmpty() }
            DialerContact(b.id, name.take(DialerLimits.NAME_MAX), b.starred, b.numbers, b.whatsApp.values.toList())
        }
        .filter { it.name.isNotEmpty() }
        .withIndex()
        .sortedWith(compareBy({ !it.value.starred }, { it.index }))
        .map { it.value }
        .take(limit)
}

/** The number in a WhatsApp jid ("919876543210@s.whatsapp.net"), with a leading +, or null. */
fun whatsAppNumber(jid: String?): String? {
    val digits = jid?.substringBefore('@')?.takeIf { it.isNotEmpty() && it.all(Char::isDigit) } ?: return null
    return "+$digits".takeIf { digits.length in 3..15 }
}

// MARK: WhatsApp

/** The two WhatsApp apps and the MIME types of the call rows they add to the phone's contacts. */
enum class WhatsAppApp(val packageName: String, val voiceType: String, val videoType: String) {
    WHATSAPP("com.whatsapp", "vnd.android.cursor.item/vnd.com.whatsapp.voip.call", "vnd.android.cursor.item/vnd.com.whatsapp.video.call"),
    BUSINESS("com.whatsapp.w4b", "vnd.android.cursor.item/vnd.com.whatsapp.w4b.voip.call", "vnd.android.cursor.item/vnd.com.whatsapp.w4b.video.call"),
    ;

    companion object {
        val callTypes: List<String> get() = entries.flatMap { listOf(it.voiceType, it.videoType) }

        /** The app and kind for a row's MIME type, or null when it is not a WhatsApp call row. */
        fun forType(mimeType: String?): Pair<WhatsAppApp, Boolean>? {
            for (app in entries) {
                if (mimeType == app.voiceType) return app to false
                if (mimeType == app.videoType) return app to true
            }
            return null
        }
    }
}

/** What to open for a WhatsApp call: ACTION_VIEW on the data row, with its MIME type, in that app. */
data class WhatsAppIntentSpec(val packageName: String, val dataUri: String, val mimeType: String)

/**
 * The intent for [via] on row [dataId] whose MIME type the provider reported as [rowMimeType], or null
 * when the row is not a WhatsApp call row of that kind (a Mac cannot open any other contact row).
 */
fun whatsAppIntent(via: CallVia, dataId: Long, rowMimeType: String?): WhatsAppIntentSpec? {
    if (!via.whatsApp || dataId < 1) return null
    val (app, video) = WhatsAppApp.forType(rowMimeType) ?: return null
    if (video != (via == CallVia.WHATSAPP_VIDEO)) return null
    return WhatsAppIntentSpec(app.packageName, "content://com.android.contacts/data/$dataId", rowMimeType!!)
}

// MARK: Recent calls

enum class RecentType(val wire: String) {
    INCOMING("incoming"), OUTGOING("outgoing"), MISSED("missed"), REJECTED("rejected"), BLOCKED("blocked"), VOICEMAIL("voicemail");

    companion object {
        /** CallLog.Calls.TYPE: 1 incoming, 2 outgoing, 3 missed, 4 voicemail, 5 rejected, 6 blocked, 7 answered elsewhere. */
        fun fromCallLog(type: Int): RecentType = when (type) {
            2 -> OUTGOING
            3 -> MISSED
            4 -> VOICEMAIL
            5 -> REJECTED
            6 -> BLOCKED
            else -> INCOMING
        }
    }
}

data class RecentCall(
    val id: Long,
    val address: String,
    val name: String? = null,
    val type: RecentType,
    val date: Long,
    val duration: Long,
    val subId: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("address", address.take(DialerLimits.ADDRESS_MAX))
        name?.takeIf { it.isNotEmpty() }?.let { put("name", it.take(DialerLimits.NAME_MAX)) }
        put("type", type.wire)
        put("date", date.coerceAtLeast(0))
        put("duration", duration.coerceAtLeast(0))
        subId?.let { put("subId", it) }
    }
}

fun dialerRecentsPayload(requestId: String, calls: List<RecentCall>, error: String? = null): JSONObject {
    val base = JSONObject().put("version", 1).put("requestId", requestId)
    if (error != null) return base.put("calls", JSONArray()).put("error", error)
    val kept = JSONArray()
    var size = base.toString().toByteArray().size + ""","calls":[]""".length
    for (call in calls.take(DialerLimits.RECENTS_MAX)) {
        if (call.id < 1) continue
        val json = call.toJson()
        val add = json.toString().toByteArray().size + if (kept.length() > 0) 1 else 0
        if (size + add > DialerLimits.RECENTS_RESULT_MAX_BYTES) break
        kept.put(json)
        size += add
    }
    return base.put("calls", kept)
}

// MARK: Placing a call

enum class CallOutcome(val wire: String) { STARTED("started"), CONFIRM("confirm"), REFUSED("refused") }

enum class RefuseReason(val wire: String) {
    DISABLED("disabled"), PERMISSION("permission"), INVALID("invalid"), EMERGENCY("emergency"), NO_SIM("no_sim"),
    RATE_LIMITED("rate_limited"), NOT_FOUND("not_found"), UNAVAILABLE("unavailable"), FAILED("failed"),
}

fun dialerCallResultPayload(requestId: String, outcome: CallOutcome, reason: RefuseReason? = null): JSONObject =
    JSONObject().put("version", 1).put("requestId", requestId).put("result", outcome.wire).apply {
        if (outcome == CallOutcome.REFUSED) put("reason", (reason ?: RefuseReason.FAILED).wire)
    }

/** Which SIM a call from the Mac uses: the Mac's pick when that SIM is active here, the phone's default when none. */
sealed interface SimChoice {
    /** No SIM named: the phone's default phone account (Android may ask on the phone). */
    data object PhoneDefault : SimChoice
    data class Sim(val subId: Int) : SimChoice
    /** The Mac named a SIM that is not active here. */
    data object Missing : SimChoice
}

/**
 * [requested]: the Mac's subId, or null. [sims]: the active SIMs (empty when the phone cannot list
 * them: then the request is passed on and Telecom's own account is used if it matches).
 */
fun chooseSim(requested: Int?, sims: List<SimInfo>): SimChoice = when {
    requested == null -> SimChoice.PhoneDefault
    sims.isEmpty() -> SimChoice.Sim(requested)
    sims.any { it.subId == requested } -> SimChoice.Sim(requested)
    else -> SimChoice.Missing
}

/**
 * Calls from one Mac: at most one every 3 seconds and 10 in 10 minutes; contact searches 30 and
 * recent-call reads 10 in 10 seconds. Times are the device's monotonic clock.
 */
class DialerLimiter(private val clock: () -> Long) {
    private val calls = HashMap<String, ArrayDeque<Long>>()
    private val contacts = HashMap<String, ArrayDeque<Long>>()
    private val recents = HashMap<String, ArrayDeque<Long>>()

    @Synchronized fun allowCall(deviceId: String): Boolean {
        val now = clock()
        val window = calls.getOrPut(deviceId, ::ArrayDeque)
        while (window.isNotEmpty() && now - window.first() >= CALL_WINDOW_MILLIS) window.removeFirst()
        if (window.isNotEmpty() && now - window.last() < CALL_SPACING_MILLIS) return false
        if (window.size >= CALLS_PER_WINDOW) return false
        window.addLast(now)
        return true
    }

    @Synchronized fun allowContacts(deviceId: String): Boolean = allow(contacts, deviceId, CONTACTS_PER_WINDOW)

    @Synchronized fun allowRecents(deviceId: String): Boolean = allow(recents, deviceId, RECENTS_PER_WINDOW)

    private fun allow(map: HashMap<String, ArrayDeque<Long>>, deviceId: String, max: Int): Boolean {
        val now = clock()
        val window = map.getOrPut(deviceId, ::ArrayDeque)
        while (window.isNotEmpty() && now - window.first() >= READ_WINDOW_MILLIS) window.removeFirst()
        if (window.size >= max) return false
        window.addLast(now)
        return true
    }

    @Synchronized fun forget(deviceId: String) {
        calls.remove(deviceId)
        contacts.remove(deviceId)
        recents.remove(deviceId)
    }

    companion object {
        const val CALL_SPACING_MILLIS = 3_000L
        const val CALL_WINDOW_MILLIS = 10 * 60_000L
        const val CALLS_PER_WINDOW = 10
        const val READ_WINDOW_MILLIS = 10_000L
        const val CONTACTS_PER_WINDOW = 30
        const val RECENTS_PER_WINDOW = 10
    }
}
