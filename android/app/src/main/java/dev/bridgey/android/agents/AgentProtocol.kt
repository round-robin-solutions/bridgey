package dev.bridgey.android.agents

import dev.bridgey.android.BIDI_CONTROLS
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONArray
import org.json.JSONObject

/*
 * Agent devices (draft agent_draft1, docs/protocol.md "Draft: agent devices"): the wire messages between an agent
 * (the `bridgey` command), this phone and its Macs. Pure Kotlin, so protocol/test-vectors/agent-v1.json runs in plain
 * JUnit. Decoders return null for anything malformed (the message is dropped, or refused with `invalid`).
 */

const val AGENT_FEATURE_KEY = "agent_draft1"
const val NOTIFY_FEATURE_KEY = "notify_draft1"
const val ASK_FEATURE_KEY = "ask_draft1"
const val CLIPBOARD_REQUEST_FEATURE_KEY = "clipboard_request_draft1"
const val AGENT_CODES_FEATURE_KEY = "agent_codes_draft1"
const val AGENT_NOTIFICATIONS_FEATURE_KEY = "agent_notifications_draft1"
const val AGENTS_MIRROR_FEATURE_KEY = "agents_mirror_draft1"

/** Detect codes (docs/mesh-and-codes.md): an agent that can run the code model; the phone, while the grant is on. */
const val CODES_DETECT_FEATURE_KEY = "codes_detect_draft1"

/** The platform an agent device pairs with (the invite's `p`, agent.hello's `platform`). */
const val AGENT_PLATFORM = "cli"

/** Every agent kind this phone sends or handles (the contract scanner reads this list). */
object AgentKinds {
    const val HELLO = "agent.hello"
    const val GRANTS = "agent.grants"
    const val GRANT_REQUEST = "agent.grant_request"
    const val REQUEST_RESULT = "agent.request_result"
    const val NOTIFY_POST = "notify.post"
    const val NOTIFY_RESULT = "notify.result"
    const val ASK_REQUEST = "ask.request"
    const val ASK_POSTED = "ask.posted"
    const val ASK_ANSWER = "ask.answer"
    const val ASK_DISMISSED = "ask.dismissed"
    const val ASK_EXPIRED = "ask.expired"
    const val ASK_CANCEL = "ask.cancel"
    const val ASK_CANCELLED = "ask.cancelled"
    const val ASK_STATUS = "ask.status"
    const val CLIPBOARD_REQUEST = "clipboard.request"
    const val CLIPBOARD_RESPONSE = "clipboard.response"
    const val CODES_QUERY = "codes.query"
    const val CODES_RESULT = "codes.result"
    const val CODES_CANCEL = "codes.cancel"
    const val CODES_FOUND = "codes.found"
    const val CODES_READ = "codes.read"
    const val AGENTS_STATE = "agents.state"
    const val AGENTS_GRANT_SET = "agents.grant_set"
    const val CODES_CANDIDATE = "codes.candidate"
    const val CODES_DETECTED = "codes.detected"
    const val NOTIFICATIONS_QUERY = "agent.notifications.query"
    const val NOTIFICATIONS_RESULT = "agent.notifications.result"
}

/** The agent kinds an agent sends to the phone; the phone's agent handler reads only these from an agent. */
internal val AGENT_TO_PHONE_KINDS = setOf(
    AgentKinds.HELLO, AgentKinds.GRANT_REQUEST, AgentKinds.NOTIFY_POST, AgentKinds.ASK_REQUEST, AgentKinds.ASK_CANCEL,
    AgentKinds.ASK_STATUS, AgentKinds.CLIPBOARD_REQUEST, AgentKinds.CODES_QUERY, AgentKinds.CODES_CANCEL,
    AgentKinds.CODES_DETECTED, AgentKinds.NOTIFICATIONS_QUERY,
)

/** The mirror kinds a Mac sends to the phone. */
internal val MAC_TO_PHONE_MIRROR_KINDS = setOf(AgentKinds.CODES_FOUND, AgentKinds.AGENTS_GRANT_SET)

/**
 * What an agent may send at all (anything else from an agent is dropped): the session itself, the agent kinds,
 * and the existing kinds its grants cover (Set your clipboard, Ring this phone, Send you files).
 */
internal fun agentMaySend(kind: String): Boolean = kind in AGENT_TO_PHONE_KINDS || kind in AGENT_SESSION_KINDS || kind in AGENT_GRANTED_KINDS

private val AGENT_SESSION_KINDS = setOf(
    "heartbeat.ping", "heartbeat.pong", "features.update",
    "pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm", "pairing.cancel",
    "connect.setup", "connect.setup.ack", "connect.addresses",
)
private val AGENT_GRANTED_KINDS = setOf(
    "clipboard.update", "clipboard.rich", "find.start", "find.stop", "ping.request",
    "files.offer", "files.chunk", "files.complete", "files.cancel", "files.cancel.ack",
)

/**
 * What this phone may send to an agent (Session.write drops anything else): answers to its requests, the agent
 * messages, battery while See battery is on (checked where it is sent), and the session itself. The phone never
 * pushes its own clipboard, notifications, files, texts, settings, focus or updates to an agent.
 */
internal fun phoneMaySendToAgent(kind: String): Boolean = kind in PHONE_TO_AGENT_KINDS

private val PHONE_TO_AGENT_KINDS = setOf(
    "heartbeat.ping", "heartbeat.pong", "features.update",
    "pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm", "pairing.cancel",
    "connect.setup", "connect.setup.ack", "connect.addresses",
    AgentKinds.GRANTS, AgentKinds.REQUEST_RESULT, AgentKinds.NOTIFY_RESULT, AgentKinds.ASK_POSTED, AgentKinds.ASK_ANSWER,
    AgentKinds.ASK_DISMISSED, AgentKinds.ASK_EXPIRED, AgentKinds.ASK_CANCELLED, AgentKinds.CLIPBOARD_RESPONSE,
    AgentKinds.CODES_RESULT, AgentKinds.CODES_CANDIDATE, AgentKinds.NOTIFICATIONS_RESULT,
    "clipboard.ack", "find.started", "find.stopped", "ping.ack", "battery.update",
    "files.accept", "files.rejected", "files.chunk.ack", "files.complete.ack", "files.cancel", "files.cancel.ack",
)

/** Refusal codes of agent.request_result. */
object AgentStatus {
    const val OK = "ok"
    const val NOT_GRANTED = "not_granted"
    const val RATE_LIMITED = "rate_limited"
    const val INVALID = "invalid"
    const val BUSY = "busy"
    const val UNKNOWN = "unknown"
    const val UNSUPPORTED = "unsupported"
}

/** The grants, in the order of the wording table (docs/agent-cli-wording.md). [wireKey] is the features.update key. */
enum class AgentGrant(val key: String, val wireKey: String) {
    FILES("files", "files"),
    CLIPBOARD("clipboard", "clipboard"),
    CLIPBOARD_REQUEST("clipboard_request", CLIPBOARD_REQUEST_FEATURE_KEY),
    NOTIFY("notify", NOTIFY_FEATURE_KEY),
    ASK("ask", ASK_FEATURE_KEY),
    RING("ring", "find_device"),
    BATTERY("battery", "battery"),
    CODES("codes", AGENT_CODES_FEATURE_KEY),

    /** Detect codes: this phone sends the agent its code text messages when no Mac reads them. Never in a preset. */
    CODES_DETECT("codes_detect", CODES_DETECT_FEATURE_KEY),

    /** On-demand reads only; ordinary notification broadcasts remain blocked for agents. */
    NOTIFICATIONS("notifications", AGENT_NOTIFICATIONS_FEATURE_KEY),
    ;

    val grantable: Boolean get() = true

    companion object {
        fun of(key: String?): AgentGrant? = entries.firstOrNull { it.key == key }
    }
}

/** How long a grant lasts once switched on. */
enum class GrantWindow(val wire: String) {
    HOUR("1h"),
    TODAY("today"),
    WEEK("7d"),
    FOREVER("forever"),
    ;

    /** When a grant switched on at [nowMillis] ends; null for [FOREVER]. [TODAY] ends at the next local midnight. */
    fun expiresAt(nowMillis: Long, zone: java.time.ZoneId): Long? = when (this) {
        HOUR -> nowMillis + 3_600_000L
        WEEK -> nowMillis + 7L * 24 * 3_600_000L
        FOREVER -> null
        TODAY -> java.time.Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
    }

    companion object {
        fun of(wire: String?): GrantWindow? = entries.firstOrNull { it.wire == wire }
    }
}

enum class GrantShown(val wire: String) { ON("on"), OFF("off"), WAITING("waiting") }

/** One grant as agent.grants and agents.state carry it. */
data class GrantView(
    val grant: AgentGrant,
    val state: GrantShown,
    val window: GrantWindow? = null,
    val grantedAt: Long? = null,
    val expiresAt: Long? = null,
    val scope: String? = null,
)

internal fun grantJson(view: GrantView): JSONObject = JSONObject()
    .put("key", view.grant.key)
    .put("state", view.state.wire)
    .apply {
        view.window?.let { put("window", it.wire) }
        view.grantedAt?.let { put("grantedAt", it) }
        view.expiresAt?.let { put("expiresAt", it) }
        view.scope?.let { put("scope", it) }
    }

/** agent.grants (at most 8 KiB: ten grants never come close). */
fun agentGrantsPayload(grants: List<GrantView>): ByteArray = JSONObject()
    .put("version", 1)
    .put("grants", JSONArray(grants.map(::grantJson)))
    .toString().toByteArray(Charsets.UTF_8)

fun requestResultPayload(ref: String, requestKind: String, status: String, retryAfterMs: Long? = null, grant: AgentGrant? = null): ByteArray =
    JSONObject()
        .put("version", 1)
        .put("ref", ref)
        .put("requestKind", requestKind)
        .put("status", status)
        .apply {
            retryAfterMs?.let { put("retryAfterMs", it) }
            grant?.let { put("grant", it.key) }
        }
        .toString().toByteArray(Charsets.UTF_8)

fun notifyResultPayload(notifyId: String): ByteArray =
    JSONObject().put("version", 1).put("notifyId", notifyId).put("status", "posted").toString().toByteArray(Charsets.UTF_8)

/** ask.posted, ask.dismissed, ask.expired and ask.cancelled: the ask's ID only. */
fun askRefPayload(askId: String): ByteArray = JSONObject().put("version", 1).put("askId", askId).toString().toByteArray(Charsets.UTF_8)

const val ASK_TEXT_MAX_CHARS = 1_000

/** ask.answer with an option or a text (at most 1,000 characters), or null when neither or both. */
fun askAnswerPayload(askId: String, option: String?, text: String?, answeredAt: Long): ByteArray? {
    if ((option == null) == (text == null)) return null
    if (text != null && text.codePointCount(0, text.length) > ASK_TEXT_MAX_CHARS) return null
    return JSONObject()
        .put("version", 1)
        .put("askId", askId)
        .apply {
            option?.let { put("option", it) }
            text?.let { put("text", it) }
        }
        .put("answeredAt", answeredAt)
        .toString().toByteArray(Charsets.UTF_8)
}

/** Text and HTML in clipboard.response together at most 32 KiB (UTF-8). */
const val CLIPBOARD_RESPONSE_MAX_BYTES = 32 * 1024

enum class ClipResponseStatus(val wire: String) { SENT("sent"), DECLINED("declined"), EXPIRED("expired") }

/** clipboard.response; null for `sent` without text or over 32 KiB. */
fun clipboardResponsePayload(requestId: String, status: ClipResponseStatus, text: String? = null, html: String? = null): ByteArray? {
    if (status == ClipResponseStatus.SENT) {
        if (text == null) return null
        val bytes = text.toByteArray(Charsets.UTF_8).size + (html?.toByteArray(Charsets.UTF_8)?.size ?: 0)
        if (bytes > CLIPBOARD_RESPONSE_MAX_BYTES) return null
    }
    return JSONObject()
        .put("version", 1)
        .put("requestId", requestId)
        .put("status", status.wire)
        .apply {
            if (status == ClipResponseStatus.SENT) {
                put("text", text)
                html?.let { put("html", it) }
            }
        }
        .toString().toByteArray(Charsets.UTF_8)
}

/** One code in codes.result. */
data class CodeOut(
    val code: String,
    val service: String,
    val source: CodeSource,
    val app: String,
    val postedAt: Long,
    val latest: Boolean,
    val replaced: Boolean,
    val via: List<String>,
)

enum class CodeSource(val wire: String) {
    SMS("sms"),
    EMAIL("email"),
    ;

    companion object {
        fun of(wire: String?): CodeSource? = entries.firstOrNull { it.wire == wire }
    }
}

const val CODES_RESULT_MAX = 20

fun codesResultPayload(queryId: String, codes: List<CodeOut>, readers: Int, timedOut: Boolean): ByteArray = JSONObject()
    .put("version", 1)
    .put("queryId", queryId)
    .put("codes", JSONArray(codes.take(CODES_RESULT_MAX).map { code ->
        JSONObject()
            .put("code", code.code)
            .put("service", code.service)
            .put("source", code.source.wire)
            .put("app", code.app)
            .put("postedAt", code.postedAt)
            .put("latest", code.latest)
            .put("replaced", code.replaced)
            .put("via", JSONArray(code.via))
    }))
    .put("readers", readers)
    .put("timedOut", timedOut)
    .toString().toByteArray(Charsets.UTF_8)

/** codes.read to a Mac: who read which service's codes, never the code. */
fun codesReadPayload(deviceId: String, deviceName: String, service: String, source: CodeSource, app: String, at: Long, count: Int): ByteArray =
    JSONObject()
        .put("version", 1)
        .put("deviceId", deviceId)
        .put("deviceName", deviceName)
        .put("service", service)
        .put("source", source.wire)
        .put("app", app)
        .put("at", at)
        .put("count", count)
        .toString().toByteArray(Charsets.UTF_8)

// MARK: decoding (agent to phone, Mac to phone)

private val UUID_TEXT = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
private val OPTION_ID = Regex("^[a-z0-9_-]{1,32}$")
private val CODE_TEXT = Regex("^[A-Za-z0-9-]{4,12}$")
internal val CODE_APPS = setOf("messages", "gmail", "outlook", "proton", "spark")

internal fun isUuid(value: String?): Boolean = value != null && UUID_TEXT.matches(value)

private fun chars(text: String): Int = text.codePointCount(0, text.length)

/**
 * Agent text shown on this phone: plain text without control or bidi characters. A body keeps its line breaks.
 */
internal fun cleanAgentText(text: String, keepLines: Boolean = false): String =
    text.filterNot { (it.isISOControl() && !(keepLines && it == '\n')) || it in BIDI_CONTROLS }.trim()

/** Version 1, a strict object, at most [maxBytes]. */
private fun agentPayload(plaintext: ByteArray, maxBytes: Int): JSONObject? {
    if (plaintext.size > maxBytes) return null
    val payload = strictJsonObject(plaintext) ?: return null
    if (jsonInteger(payload.opt("version")) != 1L) return null
    return payload
}

/** A string field: absent is null when [optional]; present must be a string of at most [max] characters. */
private class Field(val ok: Boolean, val value: String?)

private fun JSONObject.text(name: String, max: Int, optional: Boolean, min: Int = 0): Field {
    val value = opt(name)
    if (value == null || value == JSONObject.NULL) return Field(optional, null)
    if (value !is String) return Field(false, null)
    val count = chars(value)
    return Field(count in min..max, value)
}

private fun JSONObject.bool(name: String): Boolean? = opt(name) as? Boolean

data class AgentHello(val platform: String, val app: String, val os: String)

const val AGENT_HELLO_MAX_BYTES = 1_024

fun decodeAgentHello(plaintext: ByteArray): AgentHello? {
    val payload = agentPayload(plaintext, AGENT_HELLO_MAX_BYTES) ?: return null
    val platform = payload.text("platform", 16, optional = false, min = 1).takeIf { it.ok }?.value ?: return null
    val app = payload.text("app", 64, optional = false).takeIf { it.ok }?.value ?: return null
    val os = payload.text("os", 64, optional = false).takeIf { it.ok }?.value ?: return null
    return AgentHello(cleanAgentText(platform), cleanAgentText(app), cleanAgentText(os))
}

data class GrantRequest(val requestId: String, val grants: List<AgentGrant>, val note: String?)

fun decodeGrantRequest(plaintext: ByteArray): GrantRequest? {
    val payload = agentPayload(plaintext, 1_024) ?: return null
    val requestId = payload.optString("requestId").takeIf { payload.opt("requestId") is String && isUuid(it) } ?: return null
    val keys = payload.opt("keys") as? JSONArray ?: return null
    if (keys.length() !in 1..AgentGrant.entries.size) return null
    val names = (0 until keys.length()).map { keys.opt(it) as? String ?: return null }
    // Unknown names from a newer agent are skipped; requests never enable a grant.
    val grants = names.mapNotNull(AgentGrant::of).filter { it.grantable }.distinct()
    if (grants.isEmpty()) return null
    val note = payload.text("note", 120, optional = true).takeIf { it.ok } ?: return null
    return GrantRequest(requestId, grants, note.value?.let(::cleanAgentText)?.ifEmpty { null })
}

enum class NotifyPriority(val wire: String) { NORMAL("normal"), HIGH("high") }

data class NotifyPost(
    val notifyId: String,
    val title: String,
    val body: String?,
    val priority: NotifyPriority,
    val tag: String?,
    val from: String?,
)

const val NOTIFY_POST_MAX_BYTES = 4_096

fun decodeNotifyPost(plaintext: ByteArray): NotifyPost? {
    val payload = agentPayload(plaintext, NOTIFY_POST_MAX_BYTES) ?: return null
    val notifyId = (payload.opt("notifyId") as? String)?.takeIf(::isUuid) ?: return null
    val title = payload.text("title", 120, optional = false, min = 1).takeIf { it.ok }?.value?.let(::cleanAgentText)?.ifEmpty { null } ?: return null
    val body = payload.text("body", 1_000, optional = true).takeIf { it.ok } ?: return null
    val priority = NotifyPriority.entries.firstOrNull { it.wire == payload.opt("priority") } ?: return null
    val tag = payload.text("tag", 64, optional = true).takeIf { it.ok } ?: return null
    val from = payload.text("from", 64, optional = true).takeIf { it.ok } ?: return null
    return NotifyPost(
        notifyId, title,
        body.value?.let { cleanAgentText(it, keepLines = true) }?.ifEmpty { null },
        priority,
        tag.value?.let(::cleanAgentText)?.ifEmpty { null },
        from.value?.let(::cleanAgentText)?.ifEmpty { null },
    )
}

data class AskOption(val id: String, val label: String)

data class AskRequest(
    val askId: String,
    val title: String,
    val body: String?,
    val options: List<AskOption>,
    val allowText: Boolean,
    val textHint: String?,
    val requireUnlock: Boolean,
    val expiresAt: Long,
    val from: String?,
)

const val ASK_MAX_AHEAD_MILLIS = 24L * 3_600_000

/** ask.request, checked against [nowMillis]: the expiry must be ahead, at most 24 hours. */
fun decodeAskRequest(plaintext: ByteArray, nowMillis: Long): AskRequest? {
    val payload = agentPayload(plaintext, 4_096) ?: return null
    val askId = (payload.opt("askId") as? String)?.takeIf(::isUuid) ?: return null
    val title = payload.text("title", 120, optional = false, min = 1).takeIf { it.ok }?.value?.let(::cleanAgentText)?.ifEmpty { null } ?: return null
    val body = payload.text("body", 1_000, optional = true).takeIf { it.ok } ?: return null
    val list = payload.opt("options") as? JSONArray ?: return null
    if (list.length() > 3) return null
    val options = (0 until list.length()).map { index ->
        val entry = list.opt(index) as? JSONObject ?: return null
        val id = (entry.opt("id") as? String)?.takeIf(OPTION_ID::matches) ?: return null
        val label = entry.text("label", 20, optional = false, min = 1).takeIf { it.ok }?.value?.let(::cleanAgentText)?.ifEmpty { null } ?: return null
        AskOption(id, label)
    }
    if (options.map { it.id }.toSet().size != options.size) return null
    val allowText = payload.bool("allowText") ?: return null
    if (allowText && options.size > 2) return null
    if (!allowText && options.isEmpty()) return null
    val textHint = payload.text("textHint", 40, optional = true).takeIf { it.ok } ?: return null
    val requireUnlock = payload.bool("requireUnlock") ?: return null
    val expiresAt = jsonInteger(payload.opt("expiresAt")) ?: return null
    if (expiresAt <= nowMillis || expiresAt > nowMillis + ASK_MAX_AHEAD_MILLIS) return null
    val from = payload.text("from", 64, optional = true).takeIf { it.ok } ?: return null
    return AskRequest(
        askId, title,
        body.value?.let { cleanAgentText(it, keepLines = true) }?.ifEmpty { null },
        options, allowText,
        textHint.value?.let(::cleanAgentText)?.ifEmpty { null },
        requireUnlock, expiresAt,
        from.value?.let(::cleanAgentText)?.ifEmpty { null },
    )
}

/** ask.cancel and ask.status: the ask's ID. */
fun decodeAskRef(plaintext: ByteArray): String? {
    val payload = agentPayload(plaintext, 256) ?: return null
    return (payload.opt("askId") as? String)?.takeIf(::isUuid)
}

data class ClipboardRequest(val requestId: String, val expiresAt: Long)

const val CLIPBOARD_REQUEST_MAX_AHEAD_MILLIS = 10L * 60_000

fun decodeClipboardRequest(plaintext: ByteArray, nowMillis: Long): ClipboardRequest? {
    val payload = agentPayload(plaintext, 256) ?: return null
    val requestId = (payload.opt("requestId") as? String)?.takeIf(::isUuid) ?: return null
    val expiresAt = jsonInteger(payload.opt("expiresAt")) ?: return null
    if (expiresAt <= nowMillis || expiresAt > nowMillis + CLIPBOARD_REQUEST_MAX_AHEAD_MILLIS) return null
    return ClipboardRequest(requestId, expiresAt)
}

data class CodesQuery(
    val queryId: String,
    val service: String?,
    val sinceMs: Long,
    val newerThan: Long?,
    val waitMs: Long,
    val latestOnly: Boolean,
)

const val CODES_SINCE_MAX_MILLIS = 3_600_000L
const val CODES_WAIT_MAX_MILLIS = 600_000L

fun decodeCodesQuery(plaintext: ByteArray): CodesQuery? {
    val payload = agentPayload(plaintext, 1_024) ?: return null
    val queryId = (payload.opt("queryId") as? String)?.takeIf(::isUuid) ?: return null
    val service = payload.text("service", 64, optional = true).takeIf { it.ok } ?: return null
    val since = jsonInteger(payload.opt("sinceMs"))?.takeIf { it in 0..CODES_SINCE_MAX_MILLIS } ?: return null
    val newerThan = when (val value = payload.opt("newerThan")) {
        null, JSONObject.NULL -> null
        else -> jsonInteger(value) ?: return null
    }
    val wait = jsonInteger(payload.opt("waitMs"))?.takeIf { it in 0..CODES_WAIT_MAX_MILLIS } ?: return null
    val latestOnly = payload.bool("latestOnly") ?: return null
    return CodesQuery(queryId, service.value?.trim()?.ifEmpty { null }, since, newerThan, wait, latestOnly)
}

fun decodeCodesCancel(plaintext: ByteArray): String? {
    val payload = agentPayload(plaintext, 256) ?: return null
    return (payload.opt("queryId") as? String)?.takeIf(::isUuid)
}

data class CodeFound(
    val foundId: String,
    val code: String,
    val service: String,
    val serviceKey: String,
    val source: CodeSource,
    val app: String,
    val notificationId: String,
    val postedAt: Long,
)

fun decodeCodesFound(plaintext: ByteArray): CodeFound? {
    val payload = agentPayload(plaintext, 1_024) ?: return null
    val foundId = (payload.opt("foundId") as? String)?.takeIf(::isUuid) ?: return null
    val code = (payload.opt("code") as? String)?.takeIf(CODE_TEXT::matches) ?: return null
    val service = payload.text("service", 64, optional = false, min = 1).takeIf { it.ok }?.value?.let(::cleanAgentText)?.ifEmpty { null } ?: return null
    val serviceKey = payload.text("serviceKey", 64, optional = false, min = 1).takeIf { it.ok }?.value ?: return null
    val source = CodeSource.of(payload.opt("source") as? String) ?: return null
    val app = (payload.opt("app") as? String)?.takeIf { it in CODE_APPS } ?: return null
    val notificationId = payload.text("notificationId", 512, optional = false).takeIf { it.ok }?.value ?: return null
    val postedAt = jsonInteger(payload.opt("postedAt")) ?: return null
    return CodeFound(foundId, code, service, serviceKey, source, app, notificationId, postedAt)
}

data class GrantSet(val requestId: String, val deviceId: String, val grant: AgentGrant, val on: Boolean, val window: GrantWindow?)

fun decodeAgentsGrantSet(plaintext: ByteArray): GrantSet? {
    val payload = agentPayload(plaintext, 512) ?: return null
    val requestId = (payload.opt("requestId") as? String)?.takeIf(::isUuid) ?: return null
    val deviceId = payload.text("deviceId", 128, optional = false, min = 1).takeIf { it.ok }?.value ?: return null
    val grant = AgentGrant.of(payload.opt("key") as? String) ?: return null
    val on = payload.bool("on") ?: return null
    val window = when (val value = payload.opt("window")) {
        null, JSONObject.NULL -> null
        else -> GrantWindow.of(value as? String) ?: return null
    }
    if (on && (window == null || !grant.grantable)) return null
    return GrantSet(requestId, deviceId, grant, on, window.takeIf { on })
}

/** The kind of a message that carries a request ID the agent can match an agent.request_result to. */
internal val AGENT_REQUEST_KINDS = setOf(
    AgentKinds.GRANT_REQUEST, AgentKinds.NOTIFY_POST, AgentKinds.ASK_REQUEST, "clipboard.update", "clipboard.rich",
    AgentKinds.CLIPBOARD_REQUEST, "find.start", "ping.request", "files.offer", AgentKinds.CODES_QUERY, AgentKinds.ASK_STATUS,
)

// MARK: Detect codes (codes_detect_draft1, docs/mesh-and-codes.md)

/** What an agent with Detect codes found in one candidate. [code] only with [CodesDetectedOutcome.FOUND]. */
data class CodesDetected(val candidateId: String, val outcome: CodesDetectedOutcome, val code: String?, val reason: String?)

enum class CodesDetectedOutcome(val wire: String) {
    FOUND("found"),
    NONE("none"),
    FAILED("failed"),
    ;

    companion object {
        fun of(wire: String?): CodesDetectedOutcome? = entries.firstOrNull { it.wire == wire }
    }
}

private val DETECTED_CODE = Regex("^[A-Za-z0-9]{4,12}$")

fun decodeCodesDetected(plaintext: ByteArray): CodesDetected? {
    val payload = agentPayload(plaintext, 512) ?: return null
    val candidateId = (payload.opt("candidateId") as? String)?.takeIf(::isUuid) ?: return null
    val outcome = CodesDetectedOutcome.of(payload.opt("outcome") as? String) ?: return null
    val code = when (val value = payload.opt("code")) {
        null, JSONObject.NULL -> null
        is String -> value.takeIf(DETECTED_CODE::matches) ?: return null
        else -> return null
    }
    if ((outcome == CodesDetectedOutcome.FOUND) != (code != null)) return null
    val reason = payload.text("reason", 32, optional = true)
    if (!reason.ok) return null
    return CodesDetected(candidateId, outcome, code, reason.value?.takeIf { outcome == CodesDetectedOutcome.FAILED })
}

/** codes.candidate: one text message for an agent with Detect codes to read (the text already joined and gated). */
fun codesCandidatePayload(candidateId: String, source: CodeSource, app: String, sender: String, text: String, postedAt: Long): ByteArray = JSONObject()
    .put("version", 1)
    .put("candidateId", candidateId)
    .put("source", source.wire)
    .put("app", app)
    .put("sender", sender)
    .put("text", text)
    .put("postedAt", postedAt)
    .toString()
    .toByteArray(Charsets.UTF_8)

/** A single bounded snapshot, never a subscription or an action on another app. */
data class AgentNotificationsQuery(val queryId: String, val limit: Int)

fun decodeAgentNotificationsQuery(plaintext: ByteArray): AgentNotificationsQuery? {
    val payload = agentPayload(plaintext, 1_024) ?: return null
    val id = payload.optString("queryId").takeIf { payload.opt("queryId") is String && isUuid(it) } ?: return null
    val limit = if (!payload.has("limit")) 20 else jsonInteger(payload.opt("limit"))?.takeIf { it in 1..20 }?.toInt() ?: return null
    return AgentNotificationsQuery(id, limit)
}
