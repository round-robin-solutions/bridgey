package dev.bridgey.android.sms

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/*
 * Text messages (draft sms_draft1, docs/protocol.md "Text messages"): the phone's side of the wire.
 * Pure Kotlin and org.json only, so the decoders, encoders, page budgets, cursors and limits are
 * tested in plain JUnit against protocol/test-vectors/protocol-v1.json. Message bodies, numbers and
 * names are never logged.
 */

/** Same key as BridgeyFeature.SMS. */
const val SMS_FEATURE_KEY = "sms_draft1"

/** The sms.* kinds (the contract tests read this list). */
object SmsKinds {
    const val STATUS = "sms.status"
    const val CHANGED = "sms.changed"
    const val THREADS = "sms.threads"
    const val THREADS_PAGE = "sms.threads_page"
    const val MESSAGES = "sms.messages"
    const val MESSAGES_PAGE = "sms.messages_page"
    const val SYNC = "sms.sync"
    const val SYNC_PAGE = "sms.sync_page"
    const val SEND = "sms.send"
    const val SEND_STATUS = "sms.send_status"
    const val ATTACHMENT = "sms.attachment"
    const val ATTACHMENT_DATA = "sms.attachment_data"
    const val CONTACTS = "sms.contacts"
    const val CONTACTS_RESULT = "sms.contacts_result"

    /** What a Mac may send to the phone. */
    val fromMac = setOf(THREADS, MESSAGES, SYNC, SEND, ATTACHMENT, CONTACTS)
}

object SmsLimits {
    const val REQUEST_MAX_BYTES = 1_024
    const val SEND_MAX_BYTES = 8_192
    const val PAGE_MAX_BYTES = 40_960
    const val CONTACTS_RESULT_MAX_BYTES = 16_384
    const val THREADS_LIMIT = 50
    const val MESSAGES_LIMIT = 100
    const val SYNC_LIMIT = 200
    /** sms.send body, UTF-16 units. */
    const val BODY_MAX = 2_000
    /** A message body on a page, UTF-16 units; longer ones are cut and marked truncated. */
    const val MESSAGE_BODY_MAX = 4_000
    const val SNIPPET_MAX = 160
    const val ADDRESS_MAX = 64
    const val NAME_MAX = 128
    const val LABEL_MAX = 64
    const val CONTACT_LABEL_MAX = 32
    const val PARTICIPANTS_MAX = 10
    const val PARTS_MAX = 8
    const val SIMS_MAX = 4
    const val CONTACTS_MAX = 20
    const val QUERY_MAX = 64
    const val NOTIFICATION_ID_MAX = 512
    const val ATTACHMENT_MAX_BYTES = 28_672
    /** A sync more than this many messages behind starts again from the newest threads. */
    const val SYNC_RESET_GAP = 1_000L
    /** sms.changed: at most one every 2 seconds. */
    const val CHANGED_SPACING_MILLIS = 2_000L
    const val CHANGED_DEBOUNCE_MILLIS = 1_000L
}

data class SmsCursor(val sms: Long, val mms: Long) {
    fun toJson(): JSONObject = JSONObject().put("sms", sms).put("mms", mms)
}

/** A place in a conversation, ordered by date then id (both descending on a page). */
data class MessageKey(val date: Long, val id: String)

sealed interface SmsRequest {
    val requestId: String

    data class Threads(override val requestId: String, val limit: Int, val before: Long?) : SmsRequest
    data class Messages(override val requestId: String, val threadId: Long, val limit: Int, val before: MessageKey?) : SmsRequest
    data class Sync(override val requestId: String, val since: SmsCursor, val limit: Int) : SmsRequest
    data class Attachment(override val requestId: String, val partId: String) : SmsRequest
    data class Contacts(override val requestId: String, val query: String) : SmsRequest
}

sealed interface SendTarget {
    data class Thread(val threadId: Long) : SendTarget
    data class Address(val address: String) : SendTarget
    data class Notification(val notificationId: String) : SendTarget
}

data class SmsSendRequest(val requestId: String, val body: String, val target: SendTarget, val subId: Int?)

private val MESSAGE_ID = Regex("^[sm][0-9]{1,19}$")
private val PART_ID = Regex("^p[0-9]{1,19}$")
private val PHONE_NUMBER = Regex("^\\+?[0-9]{2,20}$")
private val NUMBER_SEPARATORS = setOf(' ', '-', '.', '(', ')')

fun isMessageId(value: String): Boolean = MESSAGE_ID.matches(value)

fun isPartId(value: String): Boolean = PART_ID.matches(value)

/** The provider _id inside an `s<n>`, `m<n>` or `p<n>` id. */
fun providerId(id: String): Long? = id.drop(1).toLongOrNull()

/** A UUID in its 36-character form, lowercased; null otherwise. */
internal fun smsRequestId(value: Any?): String? {
    val text = value as? String ?: return null
    if (text.length != 36 || runCatching { UUID.fromString(text) }.isFailure) return null
    return text.lowercase()
}

/** A JSON value that is absent or null. */
private fun JSONObject.absent(name: String): Boolean = !has(name) || isNull(name)

private fun JSONObject.long(name: String): Long? = jsonInteger(opt(name))

private fun decodeEnvelope(plaintext: ByteArray, maxBytes: Int): JSONObject? {
    if (plaintext.size > maxBytes) return null
    val payload = strictJsonObject(plaintext) ?: return null
    return payload.takeIf { jsonInteger(it.opt("version")) == 1L }
}

/**
 * sms.threads, sms.messages, sms.sync, sms.attachment and sms.contacts as the phone reads them: strict
 * JSON of at most 1,024 bytes, `version` 1, a UUID `requestId`, and the kind's own fields. Null when
 * malformed (the request is dropped).
 */
fun decodeSmsRequest(kind: String, plaintext: ByteArray): SmsRequest? {
    val payload = decodeEnvelope(plaintext, SmsLimits.REQUEST_MAX_BYTES) ?: return null
    val requestId = smsRequestId(payload.opt("requestId")) ?: return null
    fun limit(max: Int): Int? = payload.long("limit")?.takeIf { it in 1..max.toLong() }?.toInt()
    return when (kind) {
        SmsKinds.THREADS -> {
            val before = if (payload.absent("before")) null else payload.long("before")?.takeIf { it >= 0 } ?: return null
            SmsRequest.Threads(requestId, limit(SmsLimits.THREADS_LIMIT) ?: return null, before)
        }
        SmsKinds.MESSAGES -> {
            val threadId = payload.long("threadId")?.takeIf { it >= 1 } ?: return null
            val before = if (payload.absent("before")) {
                null
            } else {
                val key = payload.opt("before") as? JSONObject ?: return null
                val date = key.long("date")?.takeIf { it >= 0 } ?: return null
                val id = (key.opt("id") as? String)?.takeIf(::isMessageId) ?: return null
                MessageKey(date, id)
            }
            SmsRequest.Messages(requestId, threadId, limit(SmsLimits.MESSAGES_LIMIT) ?: return null, before)
        }
        SmsKinds.SYNC -> {
            val since = payload.opt("since") as? JSONObject ?: return null
            val sms = since.long("sms")?.takeIf { it >= 0 } ?: return null
            val mms = since.long("mms")?.takeIf { it >= 0 } ?: return null
            SmsRequest.Sync(requestId, SmsCursor(sms, mms), limit(SmsLimits.SYNC_LIMIT) ?: return null)
        }
        SmsKinds.ATTACHMENT -> {
            val partId = (payload.opt("partId") as? String)?.takeIf(::isPartId) ?: return null
            SmsRequest.Attachment(requestId, partId)
        }
        SmsKinds.CONTACTS -> {
            val query = (payload.opt("query") as? String)?.trim()?.takeIf { it.isNotEmpty() && it.length <= SmsLimits.QUERY_MAX } ?: return null
            SmsRequest.Contacts(requestId, query)
        }
        else -> null
    }
}

/** A phone number with spaces, dashes, dots and brackets removed: `+` and 2 to 20 digits. Null otherwise. */
fun normalizeSmsAddress(raw: String): String? {
    if (raw.length > SmsLimits.ADDRESS_MAX) return null
    val stripped = raw.filterNot { it in NUMBER_SEPARATORS }
    return stripped.takeIf(PHONE_NUMBER::matches)
}

/**
 * sms.send as the phone reads it: at most 8,192 bytes, `version` 1, a UUID `requestId`, a `body` of
 * 1 to 2,000 UTF-16 units that is not only spaces, exactly one of `threadId`, `address` and
 * `notificationId`, and an optional `subId`. Null when malformed.
 */
fun decodeSmsSend(plaintext: ByteArray): SmsSendRequest? {
    val payload = decodeEnvelope(plaintext, SmsLimits.SEND_MAX_BYTES) ?: return null
    val requestId = smsRequestId(payload.opt("requestId")) ?: return null
    val body = (payload.opt("body") as? String)?.takeIf { it.length in 1..SmsLimits.BODY_MAX && it.isNotBlank() } ?: return null
    val targets = mutableListOf<SendTarget>()
    if (!payload.absent("threadId")) {
        targets += SendTarget.Thread(payload.long("threadId")?.takeIf { it >= 1 } ?: return null)
    }
    if (!payload.absent("address")) {
        val address = payload.opt("address") as? String ?: return null
        targets += SendTarget.Address(normalizeSmsAddress(address) ?: return null)
    }
    if (!payload.absent("notificationId")) {
        val id = (payload.opt("notificationId") as? String)?.takeIf { it.isNotEmpty() && it.length <= SmsLimits.NOTIFICATION_ID_MAX } ?: return null
        targets += SendTarget.Notification(id)
    }
    val target = targets.singleOrNull() ?: return null
    val subId = if (payload.absent("subId")) null else payload.long("subId")?.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.toInt() ?: return null
    return SmsSendRequest(requestId, body, target, subId)
}

// MARK: Messages and threads

enum class SmsDirection(val wire: String) { IN("in"), OUT("out") }

enum class SmsStatus(val wire: String) { RECEIVED("received"), PENDING("pending"), SENT("sent"), DELIVERED("delivered"), FAILED("failed") }

data class SmsPart(val partId: String, val mimeType: String, val size: Long? = null)

data class SmsMessage(
    val id: String,
    val threadId: Long,
    val direction: SmsDirection,
    val status: SmsStatus,
    val date: Long,
    val address: String,
    val body: String,
    val subId: Int? = null,
    val read: Boolean = true,
    val parts: List<SmsPart> = emptyList(),
) {
    val key: MessageKey get() = MessageKey(date, id)

    /** The wire form: the body cut to 4,000 UTF-16 units (never inside a surrogate pair), at most 8 images. */
    fun toJson(): JSONObject {
        val cut = cutText(body, SmsLimits.MESSAGE_BODY_MAX)
        return JSONObject()
            .put("id", id)
            .put("threadId", threadId)
            .put("direction", direction.wire)
            .put("status", status.wire)
            .put("date", date)
            .put("address", address.take(SmsLimits.ADDRESS_MAX))
            .put("body", cut)
            .apply {
                if (cut.length < body.length) put("truncated", true)
                if (subId != null && subId >= 0) put("subId", subId)
                put("read", read)
                val images = parts.filter { isPartId(it.partId) && it.mimeType.startsWith("image/") && it.mimeType.length <= 64 }.take(SmsLimits.PARTS_MAX)
                if (images.isNotEmpty()) {
                    put("parts", JSONArray().apply {
                        images.forEach { part ->
                            put(JSONObject().put("partId", part.partId).put("mimeType", part.mimeType).apply { part.size?.takeIf { it >= 0 }?.let { put("size", it) } })
                        }
                    })
                }
            }
    }
}

data class SmsParticipant(val address: String, val name: String? = null)

data class SmsThread(
    val threadId: Long,
    val participants: List<SmsParticipant>,
    val snippet: String,
    val date: Long,
    val unread: Int,
    val subId: Int? = null,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("threadId", threadId)
        .put("participants", JSONArray().apply {
            participants.take(SmsLimits.PARTICIPANTS_MAX).forEach { participant ->
                put(JSONObject().put("address", participant.address.take(SmsLimits.ADDRESS_MAX)).apply {
                    participant.name?.takeIf { it.isNotBlank() }?.let { put("name", cutText(it, SmsLimits.NAME_MAX)) }
                })
            }
        })
        .put("snippet", cutText(snippet, SmsLimits.SNIPPET_MAX))
        .put("date", date)
        .put("unread", unread.coerceAtLeast(0))
        .apply { if (subId != null && subId >= 0) put("subId", subId) }
}

/** [text] cut to [max] UTF-16 units without splitting a surrogate pair. */
fun cutText(text: String, max: Int): String {
    if (text.length <= max) return text
    val end = if (Character.isHighSurrogate(text[max - 1])) max - 1 else max
    return text.substring(0, end)
}

/** Telephony.Sms `type` and `status` columns: drafts (type 3) and unknown types are not shown. */
fun smsDirectionStatus(type: Int, status: Int): Pair<SmsDirection, SmsStatus>? = when (type) {
    1 -> SmsDirection.IN to SmsStatus.RECEIVED
    2 -> SmsDirection.OUT to when {
        status == 0 -> SmsStatus.DELIVERED
        status >= 64 -> SmsStatus.FAILED
        else -> SmsStatus.SENT
    }
    4, 6 -> SmsDirection.OUT to SmsStatus.PENDING
    5 -> SmsDirection.OUT to SmsStatus.FAILED
    else -> null
}

/** Telephony.Mms `msg_box`: drafts (3) and unknown boxes are not shown. */
fun mmsDirectionStatus(box: Int): Pair<SmsDirection, SmsStatus>? = when (box) {
    1 -> SmsDirection.IN to SmsStatus.RECEIVED
    2 -> SmsDirection.OUT to SmsStatus.SENT
    4 -> SmsDirection.OUT to SmsStatus.PENDING
    5 -> SmsDirection.OUT to SmsStatus.FAILED
    else -> null
}

/** Newest first: by date, then by id, both descending. */
val NEWEST_FIRST: Comparator<SmsMessage> = compareByDescending<SmsMessage> { it.date }.thenByDescending { it.id }

/** True when [key] comes after [before] in newest-first order (it is older). */
fun isOlderThan(key: MessageKey, before: MessageKey): Boolean =
    key.date < before.date || (key.date == before.date && key.id < before.id)

/**
 * One conversation page from the candidates read from both tables: newest first, older than [before],
 * at most [limit]. [more] when either table may hold older messages.
 */
fun conversationPage(candidates: List<SmsMessage>, before: MessageKey?, limit: Int, tablesFull: Boolean): Pair<List<SmsMessage>, Boolean> {
    val older = candidates.filter { before == null || isOlderThan(it.key, before) }.sortedWith(NEWEST_FIRST)
    return older.take(limit) to (older.size > limit || tablesFull)
}

// MARK: Sync

sealed interface SyncPlan {
    /** The Mac's cursor is ahead of the phone, or too far behind: drop the cache and start again. */
    data object Reset : SyncPlan

    /** Read each table from the cursor in _id order. */
    data object Read : SyncPlan
}

/** [newer]: how many messages both tables hold after [since]. */
fun planSync(since: SmsCursor, current: SmsCursor, newer: Long): SyncPlan =
    if (since.sms > current.sms || since.mms > current.mms || newer > SmsLimits.SYNC_RESET_GAP) SyncPlan.Reset else SyncPlan.Read

/**
 * The messages for one sync page from each table's rows after the cursor (each in ascending _id
 * order): merged by date, keeping each table's own order, cut to [limit] and the byte [budget]. The
 * new cursor is the last included _id of each table, so the next page never skips a row.
 */
fun syncPage(
    since: SmsCursor,
    sms: List<SmsMessage>,
    mms: List<SmsMessage>,
    limit: Int,
    budget: Int,
    tablesFull: Boolean,
    encode: (SmsMessage) -> JSONObject = SmsMessage::toJson,
): SyncPageResult {
    val merged = ArrayList<SmsMessage>(sms.size + mms.size)
    var i = 0
    var j = 0
    while (i < sms.size || j < mms.size) {
        val takeSms = j >= mms.size || (i < sms.size && sms[i].date <= mms[j].date)
        merged += if (takeSms) sms[i++] else mms[j++]
    }
    val included = ArrayList<JSONObject>()
    var cursor = since
    var used = 0
    var cut = false
    for (message in merged) {
        if (included.size >= limit) { cut = true; break }
        val json = encode(message)
        val size = json.toString().toByteArray(Charsets.UTF_8).size + 1
        if (used + size > budget && included.isNotEmpty()) { cut = true; break }
        included += json
        used += size
        val id = providerId(message.id) ?: continue
        cursor = if (message.id.startsWith("s")) cursor.copy(sms = maxOf(cursor.sms, id)) else cursor.copy(mms = maxOf(cursor.mms, id))
    }
    return SyncPageResult(included, cursor, cut || tablesFull)
}

data class SyncPageResult(val messages: List<JSONObject>, val cursor: SmsCursor, val more: Boolean)

/** How much room the entries of a page have: the limit less the page without them, with room for `more`. */
fun pageRoom(empty: JSONObject, limit: Int = SmsLimits.PAGE_MAX_BYTES): Int =
    limit - empty.toString().toByteArray(Charsets.UTF_8).size - 32

/** The entries of a page that fit in [budget] bytes (at least one), in order. */
fun fitEntries(entries: List<JSONObject>, budget: Int): Pair<List<JSONObject>, Boolean> {
    val kept = ArrayList<JSONObject>()
    var used = 0
    for (entry in entries) {
        val size = entry.toString().toByteArray(Charsets.UTF_8).size + 1
        if (used + size > budget && kept.isNotEmpty()) return kept to true
        kept += entry
        used += size
    }
    return kept to false
}

// MARK: Payloads the phone sends

data class SimInfo(val subId: Int, val slot: Int, val label: String)

fun smsStatusPayload(read: Boolean, send: Boolean, contacts: Boolean, sims: List<SimInfo>, cursor: SmsCursor): JSONObject = JSONObject()
    .put("version", 1)
    .put("read", read)
    .put("send", send)
    .put("contacts", contacts)
    .put("sims", JSONArray().apply {
        sims.filter { it.subId >= 0 && it.slot in 0..3 }.take(SmsLimits.SIMS_MAX).forEach {
            put(JSONObject().put("subId", it.subId).put("slot", it.slot).put("label", cutText(it.label, SmsLimits.LABEL_MAX)))
        }
    })
    .put("cursor", cursor.toJson())

fun smsChangedPayload(cursor: SmsCursor): JSONObject = JSONObject().put("version", 1).put("cursor", cursor.toJson())

enum class SendState(val wire: String) { SENDING("sending"), SENT("sent"), DELIVERED("delivered"), FAILED("failed"), REFUSED("refused") }

enum class SendReason(val wire: String) {
    DISABLED("disabled"), PERMISSION("permission"), INVALID("invalid"), GROUP("group"), NO_SIM("no_sim"),
    RATE_LIMITED("rate_limited"), NOT_FOUND("not_found"), RADIO_OFF("radio_off"), NO_SERVICE("no_service"), FAILED("failed"),
}

enum class SendVia(val wire: String) { SMS("sms"), APP("app") }

fun smsSendStatusPayload(requestId: String, state: SendState, reason: SendReason? = null, via: SendVia? = null): JSONObject = JSONObject()
    .put("version", 1)
    .put("requestId", requestId)
    .put("status", state.wire)
    .apply {
        if (reason != null && (state == SendState.FAILED || state == SendState.REFUSED)) put("reason", reason.wire)
        if (via != null) put("via", via.wire)
    }

fun pageBase(requestId: String, error: String? = null): JSONObject =
    JSONObject().put("version", 1).put("requestId", requestId).apply { if (error != null) put("error", error) }

data class SmsContact(val name: String, val address: String, val label: String? = null) {
    fun toJson(): JSONObject = JSONObject()
        .put("name", cutText(name, SmsLimits.NAME_MAX))
        .put("address", address.take(SmsLimits.ADDRESS_MAX))
        .apply { label?.takeIf { it.isNotBlank() }?.let { put("label", cutText(it, SmsLimits.CONTACT_LABEL_MAX)) } }
}

// MARK: Sending rules

/**
 * At most one send per second and 30 in 10 minutes for each Mac (Android's own volume prompt still
 * applies on the phone).
 */
class SmsSendLimiter(private val clock: () -> Long) {
    private val sent = mutableMapOf<String, ArrayDeque<Long>>()

    @Synchronized fun allow(deviceId: String): Boolean {
        val now = clock()
        val times = sent.getOrPut(deviceId, ::ArrayDeque)
        while (times.isNotEmpty() && now - times.first() >= WINDOW_MILLIS) times.removeFirst()
        if (times.isNotEmpty() && now - times.last() < SPACING_MILLIS) return false
        if (times.size >= MAX_IN_WINDOW) return false
        times.addLast(now)
        return true
    }

    @Synchronized fun forget(deviceId: String) {
        sent.remove(deviceId)
    }

    companion object {
        const val SPACING_MILLIS = 1_000L
        const val WINDOW_MILLIS = 600_000L
        const val MAX_IN_WINDOW = 30
    }
}

/** Throttles sms.changed: a change waits [debounce] for others; sends are at least [spacing] apart. */
class ChangeThrottle(private val debounce: Long = SmsLimits.CHANGED_DEBOUNCE_MILLIS, private val spacing: Long = SmsLimits.CHANGED_SPACING_MILLIS) {
    private var lastSentAt: Long? = null

    /** How long to wait from [now] before sending for a change seen at [now]. */
    @Synchronized fun delayFor(now: Long): Long {
        val last = lastSentAt ?: return debounce
        return maxOf(debounce, spacing - (now - last))
    }

    @Synchronized fun sent(now: Long) {
        lastSentAt = now
    }
}

// MARK: Notification replies

/** A recent inbox message the notification may belong to. */
data class InboxCandidate(val threadId: Long, val address: String, val body: String, val date: Long, val name: String? = null)

/**
 * The conversation an SMS notification belongs to: the newest inbox message from 10 minutes before
 * the notification to a minute after whose body is the notification's text (or begins with it when
 * the app cut it with an ellipsis), else whose number or contact name is the notification's title.
 */
fun matchNotificationThread(title: String, text: String, postTime: Long, candidates: List<InboxCandidate>): Long? {
    val recent = candidates
        .filter { it.date in (postTime - MATCH_WINDOW_BEFORE_MILLIS)..(postTime + MATCH_WINDOW_AFTER_MILLIS) }
        .sortedByDescending { it.date }
    val wanted = text.trim()
    if (wanted.isNotEmpty()) {
        recent.firstOrNull { it.body.trim() == wanted }?.let { return it.threadId }
        val prefix = wanted.removeSuffix("…").removeSuffix("...").trimEnd()
        if (prefix.length >= 8 && prefix != wanted) recent.firstOrNull { it.body.trim().startsWith(prefix) }?.let { return it.threadId }
    }
    val heading = title.trim()
    if (heading.isEmpty()) return null
    val number = normalizeSmsAddress(heading)
    return recent.firstOrNull { candidate ->
        (number != null && sameNumber(normalizeSmsAddress(candidate.address), number)) ||
            (candidate.name != null && candidate.name.trim().equals(heading, ignoreCase = true)) ||
            candidate.address.trim() == heading
    }?.threadId
}

/** Two normalised numbers are the same phone when one ends with the other's last 9 or more digits. */
fun sameNumber(a: String?, b: String?): Boolean {
    if (a == null || b == null) return false
    val x = a.removePrefix("+")
    val y = b.removePrefix("+")
    if (x == y) return true
    val shorter = minOf(x.length, y.length)
    return shorter >= 9 && x.takeLast(shorter) == y.takeLast(shorter)
}

const val MATCH_WINDOW_BEFORE_MILLIS = 600_000L
const val MATCH_WINDOW_AFTER_MILLIS = 60_000L
