package dev.bridgey.android.agents

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import dev.bridgey.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** What the hub needs from the session layer (PairingCoordinator). */
interface AgentTransport {
    /** One encrypted message to a connected device; false when it is not connected. */
    fun send(deviceId: String, kind: String, payload: ByteArray): Boolean

    /** Connected agent devices. */
    fun connectedAgents(): List<String>

    /** Connected Macs whose latest map shows agents_mirror_draft1 (this phone always advertises it to Macs). */
    fun mirrorMacs(): List<String>

    /** Every connected device as the Detect codes rule sees it (CodeDetections.ReaderLink). */
    fun readerLinks(): List<ReaderLink>

    /** The agent advertised codes_detect_draft1 in this session: it has the code model and can read candidates. */
    fun canDetect(deviceId: String): Boolean = false

    fun deviceName(deviceId: String): String

    /** Every paired agent device. */
    fun agentIds(): List<String>

    /** How the agent is reached now (lan, vpn, direct, relay), or null. */
    fun route(deviceId: String): String?

    /** Sends features.update (the grants changed) to a connected agent. */
    fun refreshFeatures(deviceId: String)

    /** Stops the phone ringing if [deviceId] started it. */
    fun stopRing(deviceId: String)
}

/** What the device page shows about an agent besides grants and activity. */
data class AgentInfo(val app: String?, val os: String?, val pairedAt: Long?, val lastSeenAt: Long?)

/**
 * Agent devices on this phone: grants with windows, rate limits, the activity list, notifications and questions,
 * clipboard requests, the codes broker and the mirror for the Macs. Grants are decided and enforced here; the
 * agent only learns what it was granted (agent.grants, features.update).
 */
class AgentHub(
    private val context: Context,
    private val scope: CoroutineScope,
    private val transport: AgentTransport,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val directory = File(context.noBackupFilesDir, "agents")
    private val preferences = context.getSharedPreferences("bridgey.agents", Context.MODE_PRIVATE)
    val grants = AgentGrantBook(SharedPreferencesGrantStore(context), clock)
    private val limits = AgentRateLimits(clock)
    val audit = AgentAuditLog(File(directory, "audit"), clock)
    private val asks = AgentAskBook(File(directory, "asks.json"), clock)
    val codes = CodesBroker(clock)
    private val detections = CodeDetections(clock)
    private val notifier = AgentNotifier(context)
    private val heldTimers = java.util.concurrent.ConcurrentHashMap<String, Job>()
    private val clipRequests = java.util.concurrent.ConcurrentHashMap<String, Pair<ClipboardRequest, Job>>()
    private var expiryJob: Job? = null
    private var scheduledAt: Long? = null
    private var stateJob: Job? = null
    private val mutableChanges = MutableStateFlow(0L)

    /** Bumped on every change the device page shows (grants, activity, hello). */
    val changes: StateFlow<Long> = mutableChanges.asStateFlow()

    init {
        scope.launch {
            // Questions whose expiry passed while Bridgey was not running.
            expireAsks()
            checkExpiry()
        }
    }

    private fun changed() {
        mutableChanges.value = mutableChanges.value + 1
        scheduleAgentsState()
    }

    fun info(deviceId: String): AgentInfo = AgentInfo(
        app = preferences.getString("$deviceId.app", null),
        os = preferences.getString("$deviceId.os", null),
        pairedAt = preferences.getLong("$deviceId.pairedAt", 0L).takeIf { it > 0 },
        lastSeenAt = preferences.getLong("$deviceId.lastSeen", 0L).takeIf { it > 0 },
    )

    /** Download/Bridgey/<device name>, the folder Send you files lands in (also the grant's scope). */
    fun filesFolder(deviceId: String): String = "Download/Bridgey/${agentFolderName(transport.deviceName(deviceId))}"

    fun views(deviceId: String): List<GrantView> = grants.views(deviceId, filesFolder(deviceId))

    fun isOn(deviceId: String, grant: AgentGrant): Boolean = grants.isOn(deviceId, grant).also { if (!it) checkExpirySoon() }

    // MARK: pairing and sessions

    /** A first pairing by invite finished: everything off, recorded. */
    fun paired(deviceId: String) {
        preferences.edit().putLong("$deviceId.pairedAt", clock()).apply()
        audit.record(deviceId, AuditAction.PAIR, AuditOutcome.OK)
        changed()
    }

    /** The agent's session authenticated: last seen, and the endings of questions it may have missed. */
    fun sessionStarted(deviceId: String) {
        preferences.edit().putLong("$deviceId.lastSeen", clock()).apply()
        asks.endedFor(deviceId).forEach(::sendEnding)
        changed()
    }

    fun sessionEnded(deviceId: String) {
        preferences.edit().putLong("$deviceId.lastSeen", clock()).apply()
        codes.releaseAll(deviceId).forEach { heldTimers.remove(it.query.queryId)?.cancel() }
        changed()
    }

    /** After features.update to the agent: the grants as it should show them. */
    fun sendGrants(deviceId: String) {
        transport.send(deviceId, AgentKinds.GRANTS, agentGrantsPayload(views(deviceId)))
    }

    /** The phone's features.update to an agent: what Rahul granted (all other keys false, notifications always false). */
    fun featureValues(deviceId: String): Map<String, Boolean> {
        val now = clock()
        return mapOf(
            "clipboard" to grants.isOn(deviceId, AgentGrant.CLIPBOARD, now),
            "files" to grants.isOn(deviceId, AgentGrant.FILES, now),
            "notifications" to false,
            "battery" to grants.isOn(deviceId, AgentGrant.BATTERY, now),
            "find_device" to grants.isOn(deviceId, AgentGrant.RING, now),
            "ping" to grants.isOn(deviceId, AgentGrant.RING, now),
            AGENT_FEATURE_KEY to true,
            NOTIFY_FEATURE_KEY to grants.isOn(deviceId, AgentGrant.NOTIFY, now),
            ASK_FEATURE_KEY to grants.isOn(deviceId, AgentGrant.ASK, now),
            CLIPBOARD_REQUEST_FEATURE_KEY to grants.isOn(deviceId, AgentGrant.CLIPBOARD_REQUEST, now),
            AGENT_CODES_FEATURE_KEY to grants.isOn(deviceId, AgentGrant.CODES, now),
            CODES_DETECT_FEATURE_KEY to grants.isOn(deviceId, AgentGrant.CODES_DETECT, now),
        )
    }

    fun forget(deviceId: String) {
        asks.forget(deviceId)
        grants.forget(deviceId)
        limits.forget(deviceId)
        codes.releaseAll(deviceId).forEach { heldTimers.remove(it.query.queryId)?.cancel() }
        detections.forget(deviceId)
        clipRequests.keys.filter { it.startsWith("$deviceId/") }.forEach { clipRequests.remove(it)?.second?.cancel() }
        notifier.cancelAll(deviceId)
        audit.clear(deviceId)
        preferences.edit().remove("$deviceId.app").remove("$deviceId.os").remove("$deviceId.pairedAt").remove("$deviceId.lastSeen").apply()
        changed()
    }

    // MARK: grants

    /**
     * Rahul switched [grant] on (for [window]) or off, on this phone or on [macName]. Sends features.update and
     * agent.grants to the agent and agents.state to the Macs.
     */
    fun setGrant(deviceId: String, grant: AgentGrant, on: Boolean, window: GrantWindow?, macName: String? = null) {
        if (!grants.set(deviceId, grant, on, window)) return
        val detail = buildString {
            append(grant.key).append(' ').append(if (on) window?.wire ?: "on" else "off")
            // As the spec words it, the same on every surface (the activity list is data, not UI text).
            macName?.let { append(", changed on ").append(it) }
        }
        audit.record(deviceId, AuditAction.GRANT_CHANGE, AuditOutcome.OK, detail)
        if (!on && grant == AgentGrant.RING) transport.stopRing(deviceId)
        if (!on && grant == AgentGrant.CODES && transport.agentIds().none { grants.isOn(it, AgentGrant.CODES) }) codes.clear()
        if (grants.views(deviceId, "").none { it.state == GrantShown.WAITING }) notifier.cancelGrantRequest(deviceId)
        grantsChanged(deviceId)
    }

    private fun grantsChanged(deviceId: String) {
        transport.refreshFeatures(deviceId)
        checkExpiry()
        changed()
    }

    /** Ends every window that is over; reschedules the next check (a coroutine while running, an alarm in Doze). */
    @Synchronized fun checkExpiry() {
        val ended = grants.expireDue()
        ended.forEach { expired ->
            audit.record(expired.deviceId, AuditAction.GRANT_EXPIRED, AuditOutcome.EXPIRED, "${expired.grant.key} ${expired.window?.wire.orEmpty()}".trim())
            if (expired.grant == AgentGrant.RING) transport.stopRing(expired.deviceId)
        }
        ended.map { it.deviceId }.distinct().forEach { deviceId ->
            transport.refreshFeatures(deviceId)
            BridgeyLogging.i(LogCategory.CONNECTION, "AGENT grants expired peer=${deviceId.take(8)}")
        }
        // A request nobody decided within 24 hours: the agent sees it off again.
        val unwaited = grants.takeWaitingCleared() - ended.map { it.deviceId }.toSet()
        unwaited.forEach(::sendGrants)
        if (ended.isNotEmpty() || unwaited.isNotEmpty()) changed()
        expireAsks()
        val next = listOfNotNull(grants.nextChangeAt(), asks.nextExpiry()).minOrNull()
        if (next == scheduledAt && expiryJob?.isActive == true) return
        scheduledAt = next
        expiryJob?.cancel()
        if (next != null) {
            val wait = (next - clock()).coerceAtLeast(0) + 50
            expiryJob = scope.launch {
                delay(wait)
                checkExpiry()
            }
            scheduleAlarm(next)
        }
    }

    private fun checkExpirySoon() {
        val next = grants.nextChangeAt() ?: return
        if (next <= clock()) scope.launch { checkExpiry() }
    }

    private fun scheduleAlarm(at: Long) {
        runCatching {
            val alarms = context.getSystemService(AlarmManager::class.java)
            val intent = Intent(context, AgentActionReceiver::class.java).setAction(AgentNotifier.ACTION_EXPIRY)
            val pending = PendingIntent.getBroadcast(context, 71_010, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            // Inexact is enough: every use checks the time too; this makes features.update go out near the end.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    /** A preset after an invite pairing: its grants on for [window] (asked like any switch). Codes is never in one. */
    fun applyPreset(deviceId: String, preset: GrantPreset, window: GrantWindow) {
        preset.grants.forEach { setGrant(deviceId, it, on = true, window = window) }
    }

    /** Clear activity on the device page. */
    fun clearActivity(deviceId: String) {
        audit.clear(deviceId)
        changed()
    }

    // MARK: messages from an agent

    /** One decrypted agent.* (and notify.*, ask.*, clipboard.request, codes.*) message from agent [deviceId]. */
    fun receive(deviceId: String, kind: String, messageId: String, plaintext: ByteArray) {
        checkExpiry()
        when (kind) {
            AgentKinds.HELLO -> hello(deviceId, plaintext)
            AgentKinds.GRANT_REQUEST -> grantRequest(deviceId, messageId, plaintext)
            AgentKinds.NOTIFY_POST -> notifyPost(deviceId, messageId, plaintext)
            AgentKinds.ASK_REQUEST -> askRequest(deviceId, messageId, plaintext)
            AgentKinds.ASK_CANCEL -> askCancel(deviceId, messageId, plaintext)
            AgentKinds.ASK_STATUS -> askStatus(deviceId, messageId, plaintext)
            AgentKinds.CLIPBOARD_REQUEST -> clipboardRequest(deviceId, messageId, plaintext)
            AgentKinds.CODES_QUERY -> codesQuery(deviceId, messageId, plaintext)
            AgentKinds.CODES_CANCEL -> decodeCodesCancel(plaintext)?.let { queryId ->
                codes.release(deviceId, queryId)?.let { heldTimers.remove(queryId)?.cancel() }
            }
            AgentKinds.CODES_DETECTED -> codesDetected(deviceId, plaintext)
        }
    }

    private fun result(deviceId: String, ref: String, kind: String, status: String, retryAfterMs: Long? = null, grant: AgentGrant? = null) {
        transport.send(deviceId, AgentKinds.REQUEST_RESULT, requestResultPayload(ref, kind, status, retryAfterMs, grant))
    }

    /**
     * The grant and rate check for an agent request of [kind] (ref [messageId]): true when it may go ahead;
     * otherwise refused with not_granted or rate_limited, and recorded as [action] when given.
     */
    fun admit(deviceId: String, messageId: String, kind: String, grant: AgentGrant, rate: AgentAction?, action: String? = null, detail: String? = null): Boolean {
        if (!isOn(deviceId, grant)) {
            result(deviceId, messageId, kind, AgentStatus.NOT_GRANTED, grant = grant)
            action?.let { audit.record(deviceId, it, AuditOutcome.NOT_GRANTED, detail) }
            transport.refreshFeatures(deviceId)
            changed()
            return false
        }
        val wait = rate?.let { limits.acquire(deviceId, it) }
        if (wait != null) {
            result(deviceId, messageId, kind, AgentStatus.RATE_LIMITED, retryAfterMs = wait)
            action?.let { audit.record(deviceId, it, AuditOutcome.RATE_LIMITED, detail) }
            changed()
            return false
        }
        return true
    }

    /** A kind an agent may not send (or this version does not know): refused, so the agent can say why. */
    fun unsupported(deviceId: String, messageId: String, kind: String) {
        result(deviceId, messageId, kind, AgentStatus.UNSUPPORTED)
    }

    fun invalid(deviceId: String, messageId: String, kind: String) {
        result(deviceId, messageId, kind, AgentStatus.INVALID)
    }

    fun record(deviceId: String, action: String, outcome: String, detail: String? = null) {
        audit.record(deviceId, action, outcome, detail)
        changed()
    }

    private fun hello(deviceId: String, plaintext: ByteArray) {
        val hello = decodeAgentHello(plaintext) ?: return
        if (hello.platform != AGENT_PLATFORM) return
        preferences.edit().putString("$deviceId.app", hello.app).putString("$deviceId.os", hello.os).apply()
        changed()
    }

    private fun grantRequest(deviceId: String, messageId: String, plaintext: ByteArray) {
        val request = decodeGrantRequest(plaintext) ?: return invalid(deviceId, messageId, AgentKinds.GRANT_REQUEST)
        val wait = limits.acquire(deviceId, AgentAction.GRANT_REQUEST)
        if (wait != null) {
            audit.record(deviceId, AuditAction.GRANT_REQUEST, AuditOutcome.RATE_LIMITED, request.grants.joinToString(" ") { it.key })
            changed()
            return result(deviceId, messageId, AgentKinds.GRANT_REQUEST, AgentStatus.RATE_LIMITED, retryAfterMs = wait)
        }
        val waiting = grants.markWaiting(deviceId, request.grants)
        audit.record(deviceId, AuditAction.GRANT_REQUEST, AuditOutcome.OK, request.grants.joinToString(" ") { it.key })
        result(deviceId, messageId, AgentKinds.GRANT_REQUEST, AgentStatus.OK)
        if (waiting.isNotEmpty()) {
            notifier.grantRequest(deviceId, transport.deviceName(deviceId), waiting.map { grantTitle(context, it) }, request.note)
            sendGrants(deviceId)
        }
        checkExpiry()
        changed()
    }

    private fun notifyPost(deviceId: String, messageId: String, plaintext: ByteArray) {
        val post = decodeNotifyPost(plaintext) ?: return invalid(deviceId, messageId, AgentKinds.NOTIFY_POST)
        val rate = if (post.priority == NotifyPriority.HIGH) AgentAction.NOTIFY_HIGH else AgentAction.NOTIFY
        if (!admit(deviceId, messageId, AgentKinds.NOTIFY_POST, AgentGrant.NOTIFY, rate, AuditAction.NOTIFY, post.title)) return
        notifier.post(deviceId, transport.deviceName(deviceId), post)
        audit.record(deviceId, AuditAction.NOTIFY, AuditOutcome.DELIVERED, post.title)
        transport.send(deviceId, AgentKinds.NOTIFY_RESULT, notifyResultPayload(post.notifyId))
        changed()
    }

    // MARK: questions

    private fun askRequest(deviceId: String, messageId: String, plaintext: ByteArray) {
        val request = decodeAskRequest(plaintext, clock()) ?: return invalid(deviceId, messageId, AgentKinds.ASK_REQUEST)
        // A retry after a reconnect: the ask's current state, never a second notification.
        asks.get(deviceId, request.askId)?.let { return sendState(it) }
        if (!isOn(deviceId, AgentGrant.ASK)) {
            admit(deviceId, messageId, AgentKinds.ASK_REQUEST, AgentGrant.ASK, null, AuditAction.ASK, request.title)
            return
        }
        if (asks.openCount(deviceId) >= ASKS_PENDING_PER_AGENT || asks.openCount() >= ASKS_PENDING_ON_PHONE) {
            return result(deviceId, messageId, AgentKinds.ASK_REQUEST, AgentStatus.BUSY)
        }
        if (!admit(deviceId, messageId, AgentKinds.ASK_REQUEST, AgentGrant.ASK, AgentAction.ASK, AuditAction.ASK, request.title)) return
        val record = AskRecord(
            deviceId = deviceId, askId = request.askId, title = request.title, body = request.body, options = request.options,
            allowText = request.allowText, textHint = request.textHint, requireUnlock = request.requireUnlock,
            expiresAt = request.expiresAt, from = request.from, postedAt = clock(),
            notificationId = "$deviceId/${request.askId}".hashCode(),
        )
        asks.add(record)
        notifier.ask(transport.deviceName(deviceId), record)
        audit.record(deviceId, AuditAction.ASK, AuditOutcome.DELIVERED, request.title)
        transport.send(deviceId, AgentKinds.ASK_POSTED, askRefPayload(request.askId))
        checkExpiry()
        changed()
    }

    /** The ask's latest message: ask.posted while open, else how it ended. */
    private fun sendState(record: AskRecord) {
        when (record.state) {
            AskState.OPEN -> transport.send(record.deviceId, AgentKinds.ASK_POSTED, askRefPayload(record.askId))
            AskState.CANCELLED -> transport.send(record.deviceId, AgentKinds.ASK_CANCELLED, askRefPayload(record.askId))
            else -> sendEnding(record)
        }
    }

    private fun sendEnding(record: AskRecord) {
        when (record.state) {
            AskState.ANSWERED -> askAnswerPayload(record.askId, record.option, record.text, record.endedAt ?: clock())
                ?.let { transport.send(record.deviceId, AgentKinds.ASK_ANSWER, it) }
            AskState.DISMISSED -> transport.send(record.deviceId, AgentKinds.ASK_DISMISSED, askRefPayload(record.askId))
            AskState.EXPIRED -> transport.send(record.deviceId, AgentKinds.ASK_EXPIRED, askRefPayload(record.askId))
            AskState.CANCELLED -> transport.send(record.deviceId, AgentKinds.ASK_CANCELLED, askRefPayload(record.askId))
            AskState.OPEN -> Unit
        }
    }

    private fun askCancel(deviceId: String, messageId: String, plaintext: ByteArray) {
        val askId = decodeAskRef(plaintext) ?: return invalid(deviceId, messageId, AgentKinds.ASK_CANCEL)
        val record = asks.get(deviceId, askId) ?: return result(deviceId, messageId, AgentKinds.ASK_CANCEL, AgentStatus.UNKNOWN)
        if (record.state != AskState.OPEN) return sendState(record)
        asks.end(deviceId, askId, AskState.CANCELLED)
        notifier.cancelAsk(deviceId, askId)
        transport.send(deviceId, AgentKinds.ASK_CANCELLED, askRefPayload(askId))
        changed()
    }

    private fun askStatus(deviceId: String, messageId: String, plaintext: ByteArray) {
        val askId = decodeAskRef(plaintext) ?: return invalid(deviceId, messageId, AgentKinds.ASK_STATUS)
        val record = asks.get(deviceId, askId) ?: return result(deviceId, messageId, AgentKinds.ASK_STATUS, AgentStatus.UNKNOWN)
        sendState(record)
    }

    /** An open ask, for the in-app answer dialog (older Android with requireUnlock, or a tap on the notification). */
    fun openAsk(deviceId: String, askId: String): AskRecord? = asks.get(deviceId, askId)?.takeIf { it.state == AskState.OPEN && clock() < it.expiresAt }

    /** Rahul answered on the notification or in Bridgey: [option], or [text] when the ask allows text. */
    fun answer(deviceId: String, askId: String, option: String?, text: String?) {
        val record = asks.get(deviceId, askId) ?: return
        if (record.state != AskState.OPEN) return
        if (clock() >= record.expiresAt) return expireAsks()
        val cleanText = text?.trim()?.takeIf { it.isNotEmpty() }?.let { if (it.codePointCount(0, it.length) > ASK_TEXT_MAX_CHARS) it.take(ASK_TEXT_MAX_CHARS) else it }
        val chosen = option?.takeIf { id -> record.options.any { it.id == id } }
        if (chosen == null && (cleanText == null || !record.allowText)) return
        val ended = asks.end(deviceId, askId, AskState.ANSWERED, option = chosen, text = if (chosen == null) cleanText else null) ?: return
        notifier.cancelAsk(deviceId, askId)
        // The answer's text never goes in the activity list.
        audit.record(deviceId, AuditAction.ANSWER, AuditOutcome.answered(chosen ?: "text"), record.title)
        sendEnding(ended)
        changed()
    }

    /** The question was swiped away (an expired one counts as expired). */
    fun dismissed(deviceId: String, askId: String) {
        val record = asks.get(deviceId, askId)?.takeIf { it.state == AskState.OPEN } ?: return
        if (clock() >= record.expiresAt) return expireAsks()
        val ended = asks.end(deviceId, askId, AskState.DISMISSED) ?: return
        audit.record(deviceId, AuditAction.ANSWER, AuditOutcome.DISMISSED, record.title)
        sendEnding(ended)
        changed()
    }

    private fun expireAsks() {
        asks.expiredOpen().forEach { record ->
            val ended = asks.end(record.deviceId, record.askId, AskState.EXPIRED) ?: return@forEach
            notifier.cancelAsk(record.deviceId, record.askId)
            audit.record(record.deviceId, AuditAction.ANSWER, AuditOutcome.EXPIRED, record.title)
            sendEnding(ended)
            changed()
        }
    }

    // MARK: clipboard requests

    private fun clipboardRequest(deviceId: String, messageId: String, plaintext: ByteArray) {
        val request = decodeClipboardRequest(plaintext, clock()) ?: return invalid(deviceId, messageId, AgentKinds.CLIPBOARD_REQUEST)
        if (!isOn(deviceId, AgentGrant.CLIPBOARD_REQUEST)) {
            admit(deviceId, messageId, AgentKinds.CLIPBOARD_REQUEST, AgentGrant.CLIPBOARD_REQUEST, null, AuditAction.CLIPBOARD_REQUEST)
            return
        }
        if (clipRequests.keys.any { it.startsWith("$deviceId/") }) return result(deviceId, messageId, AgentKinds.CLIPBOARD_REQUEST, AgentStatus.BUSY)
        if (!admit(deviceId, messageId, AgentKinds.CLIPBOARD_REQUEST, AgentGrant.CLIPBOARD_REQUEST, AgentAction.CLIP_GET, AuditAction.CLIPBOARD_REQUEST)) return
        val key = "$deviceId/${request.requestId}"
        val timer = scope.launch {
            delay((request.expiresAt - clock()).coerceAtLeast(0))
            clipboardAnswered(deviceId, request.requestId, ClipResponseStatus.EXPIRED)
        }
        clipRequests[key] = request to timer
        notifier.clipboardRequest(deviceId, transport.deviceName(deviceId), request.requestId, request.expiresAt)
    }

    /** Send on the clipboard request: [text] and [html] read in the foreground by AgentClipboardActivity. */
    fun clipboardSend(deviceId: String, requestId: String, text: String, html: String?) {
        val bounded = boundedClip(text, html)
        clipboardAnswered(deviceId, requestId, ClipResponseStatus.SENT, bounded.first, bounded.second)
    }

    fun clipboardDeny(deviceId: String, requestId: String) = clipboardAnswered(deviceId, requestId, ClipResponseStatus.DECLINED)

    private fun clipboardAnswered(deviceId: String, requestId: String, status: ClipResponseStatus, text: String? = null, html: String? = null) {
        val entry = clipRequests.remove("$deviceId/$requestId") ?: return
        entry.second.cancel()
        notifier.cancelClipboardRequest(deviceId, requestId)
        val expired = clock() >= entry.first.expiresAt
        val final = if (expired && status != ClipResponseStatus.EXPIRED) ClipResponseStatus.EXPIRED else status
        clipboardResponsePayload(requestId, final, text.takeIf { final == ClipResponseStatus.SENT }, html.takeIf { final == ClipResponseStatus.SENT })
            ?.let { transport.send(deviceId, AgentKinds.CLIPBOARD_RESPONSE, it) }
        val outcome = when (final) {
            ClipResponseStatus.SENT -> AuditOutcome.DELIVERED
            ClipResponseStatus.DECLINED -> AuditOutcome.DECLINED
            ClipResponseStatus.EXPIRED -> AuditOutcome.EXPIRED
        }
        // Never the clipboard's content.
        audit.record(deviceId, AuditAction.CLIPBOARD_REQUEST, outcome)
        changed()
    }

    fun clipboardPending(deviceId: String, requestId: String): Boolean = clipRequests.containsKey("$deviceId/$requestId")

    // MARK: codes

    private fun codesQuery(deviceId: String, messageId: String, plaintext: ByteArray) {
        val query = decodeCodesQuery(plaintext) ?: return invalid(deviceId, messageId, AgentKinds.CODES_QUERY)
        if (!admit(deviceId, messageId, AgentKinds.CODES_QUERY, AgentGrant.CODES, null, AuditAction.CODES_READ, query.service)) return
        val answer = codes.answer(query)
        if (answer.codes.isNotEmpty() || query.waitMs == 0L) return answerQuery(deviceId, query, answer, timedOut = false)
        if (!codes.hold(deviceId, query)) return result(deviceId, messageId, AgentKinds.CODES_QUERY, AgentStatus.BUSY)
        heldTimers.remove(query.queryId)?.cancel()
        heldTimers[query.queryId] = scope.launch {
            delay(query.waitMs)
            codes.release(deviceId, query.queryId)?.let { answerQuery(deviceId, query, CodesAnswer(emptyList()), timedOut = true) }
            heldTimers.remove(query.queryId)
        }
    }

    private fun answerQuery(deviceId: String, query: CodesQuery, answer: CodesAnswer, timedOut: Boolean) {
        transport.send(deviceId, AgentKinds.CODES_RESULT, codesResultPayload(query.queryId, answer.codes, readers(), timedOut))
        val newest = answer.codes.firstOrNull() ?: return
        val service = answer.service(query.service)
        // One entry per answered query with codes: the service and how many, never a code.
        val entry = audit.record(deviceId, AuditAction.CODES_READ, AuditOutcome.DELIVERED, "$service, ${answer.codes.size}")
        // The Mac dedupes on `at`: the same moment as this phone's own entry.
        val payload = codesReadPayload(deviceId, transport.deviceName(deviceId), service, newest.source, newest.app, entry.at, answer.codes.size)
        transport.mirrorMacs().forEach { mac -> transport.send(mac, AgentKinds.CODES_READ, payload) }
        changed()
    }

    /** A code from a Mac (codes.found) or an agent that detected it: kept only while some agent can read codes. */
    private fun addFound(found: CodeFound) {
        if (transport.agentIds().none { grants.isOn(it, AgentGrant.CODES) }) return
        codes.add(found).forEach { held ->
            heldTimers.remove(held.query.queryId)?.cancel()
            answerQuery(held.deviceId, held.query, codes.answer(held.query), timedOut = false)
        }
    }

    // MARK: Detect codes (codes_detect_draft1, docs/mesh-and-codes.md)

    /** Connected agents that can read candidates and hold Detect codes now, the one Rahul allowed first first. */
    fun detectors(): List<String> {
        val now = clock()
        return transport.connectedAgents()
            .filter { transport.canDetect(it) && grants.isOn(it, AgentGrant.CODES_DETECT, now) }
            .sortedWith(compareBy({ grants.record(it, AgentGrant.CODES_DETECT).grantedAt ?: Long.MAX_VALUE }, { it }))
    }

    /** How many devices find codes for agents now: Macs that send them back, and agents with Detect codes. */
    fun readers(): Int = macsReportingCodes(transport.readerLinks()) + detectors().size

    /**
     * A notification from the default SMS app (not hidden, not a summary, not a call). It goes to one agent with Detect
     * codes when no Mac reads codes and some agent has Read codes on (CodeDetections), as `codes.candidate`, with one
     * activity entry for that agent. The text is never logged or kept beyond the 30 second wait.
     */
    fun smsCandidate(notificationId: String, title: String, applicationName: String, text: String, postedAt: Long) {
        val joined = dev.bridgey.android.codes.smsCandidateText(text) ?: return
        if (!detections.firstSight(notificationId, joined)) return
        val anyReader = transport.agentIds().any { grants.isOn(it, AgentGrant.CODES) }
        val target = detections.pick(macsReadingCodes(transport.readerLinks()), anyReader, detectors()) ?: return
        val sender = dev.bridgey.android.codes.codeSender(title, applicationName).let { name ->
            val points = name.codePoints().limit(64).toArray()
            String(points, 0, points.size)
        }
        val candidate = PendingCandidate(java.util.UUID.randomUUID().toString(), target, joined, sender, CodeSource.SMS, "messages", notificationId.take(512), postedAt, clock())
        val payload = codesCandidatePayload(candidate.candidateId, candidate.source, candidate.app, candidate.sender, candidate.text, candidate.postedAt)
        if (!transport.send(target, AgentKinds.CODES_CANDIDATE, payload)) return detections.release()
        detections.sent(candidate)
        audit.record(target, AuditAction.CODES_DETECT, AuditOutcome.DELIVERED, applicationName.take(64))
        changed()
    }

    private fun codesDetected(deviceId: String, plaintext: ByteArray) {
        val detected = decodeCodesDetected(plaintext) ?: return
        if (!grants.isOn(deviceId, AgentGrant.CODES_DETECT)) return
        when (val answer = detections.answer(deviceId, detected)) {
            is DetectAnswer.Found -> addFound(answer.found)
            DetectAnswer.Refused -> {
                // The agent named a code that is not in the message: kept out, and on its activity list.
                audit.record(deviceId, AuditAction.CODES_DETECT, AuditOutcome.INVALID)
                changed()
            }
            else -> Unit
        }
    }

    // MARK: the Macs (agents_mirror_draft1)

    /** codes.found or agents.grant_set from Mac [macId]. */
    fun receiveFromMac(macId: String, macName: String, kind: String, plaintext: ByteArray) {
        when (kind) {
            AgentKinds.CODES_FOUND -> decodeCodesFound(plaintext)?.let(::addFound)
            AgentKinds.AGENTS_GRANT_SET -> {
                val set = decodeAgentsGrantSet(plaintext) ?: return
                if (set.deviceId !in transport.agentIds()) return
                // Detect codes sends message text to a server: only a tap on this phone turns it on or off.
                if (!grantSettableFromMac(set.grant)) return sendAgentsState(macId)
                setGrant(set.deviceId, set.grant, set.on, set.window, macName = macName)
                sendAgentsState(macId)
            }
        }
    }

    /** A Mac's map shows the mirror key: it hears the agents now. */
    fun macReady(macId: String) = sendAgentsState(macId)

    private fun scheduleAgentsState() {
        if (stateJob?.isActive == true) return
        stateJob = scope.launch {
            delay(1_000)
            transport.mirrorMacs().forEach(::sendAgentsState)
        }
    }

    private fun sendAgentsState(macId: String) {
        transport.send(macId, AgentKinds.AGENTS_STATE, agentsStatePayload())
    }

    /** agents.state: every agent with its grants and newest activity, cut down to fit 44 KiB (one frame once sealed). */
    internal fun agentsStatePayload(): ByteArray {
        val online = transport.connectedAgents().toSet()
        var activity = 50
        while (true) {
            val agents = JSONArray(transport.agentIds().map { id ->
                val info = info(id)
                JSONObject()
                    .put("deviceId", id)
                    .put("name", transport.deviceName(id))
                    .put("platform", AGENT_PLATFORM)
                    .put("app", info.app.orEmpty())
                    .put("os", info.os.orEmpty())
                    .put("pairedAt", info.pairedAt ?: 0)
                    .put("online", id in online)
                    .apply {
                        info.lastSeenAt?.let { put("lastSeenAt", it) }
                        transport.route(id)?.let { put("route", it) }
                    }
                    .put("grants", JSONArray(views(id).map(::grantJson)))
                    .put("activity", JSONArray(audit.entries(id).take(activity).map(::auditJson)))
            })
            val bytes = JSONObject().put("version", 1).put("agents", agents).toString().toByteArray(Charsets.UTF_8)
            if (bytes.size <= AGENTS_STATE_MAX_BYTES || activity == 0) return bytes
            activity /= 2
        }
    }

    companion object {
        const val AGENTS_STATE_MAX_BYTES = 45_056
    }
}

/** The folder name for an agent's files: its name without path separators or control characters. */
fun agentFolderName(name: String): String =
    cleanAgentText(name).replace(Regex("[/\\\\:*?\"<>|]"), "_").trim('.', ' ').take(64).ifEmpty { "Agent" }

/** Text at most 32 KiB together with HTML: HTML goes first when too long, then the text is cut. */
internal fun boundedClip(text: String, html: String?): Pair<String, String?> {
    val textBytes = text.toByteArray(Charsets.UTF_8).size
    val htmlBytes = html?.toByteArray(Charsets.UTF_8)?.size ?: 0
    if (textBytes + htmlBytes <= CLIPBOARD_RESPONSE_MAX_BYTES) return text to html
    if (textBytes <= CLIPBOARD_RESPONSE_MAX_BYTES) return text to null
    var cut = text.take(CLIPBOARD_RESPONSE_MAX_BYTES / 4)
    var end = cut.length
    while (end < text.length && text.substring(0, end + 1).toByteArray(Charsets.UTF_8).size <= CLIPBOARD_RESPONSE_MAX_BYTES) end++
    cut = text.substring(0, end)
    if (cut.isNotEmpty() && cut.last().isHighSurrogate()) cut = cut.dropLast(1)
    return cut to null
}

fun grantTitle(context: Context, grant: AgentGrant): String = context.getString(
    when (grant) {
        AgentGrant.FILES -> R.string.agent_grant_files
        AgentGrant.CLIPBOARD -> R.string.agent_grant_clipboard
        AgentGrant.CLIPBOARD_REQUEST -> R.string.agent_grant_clipboard_request
        AgentGrant.NOTIFY -> R.string.agent_grant_notify
        AgentGrant.ASK -> R.string.agent_grant_ask
        AgentGrant.RING -> R.string.agent_grant_ring
        AgentGrant.BATTERY -> R.string.agent_grant_battery
        AgentGrant.CODES -> R.string.agent_grant_codes
        AgentGrant.CODES_DETECT -> R.string.agent_grant_codes_detect
        AgentGrant.NOTIFICATIONS -> R.string.agent_grant_notifications
    },
)

/** Grants in SharedPreferences ("bridgey.agents.grants"), one JSON text per device. */
private class SharedPreferencesGrantStore(context: Context) : GrantStore {
    private val preferences = context.getSharedPreferences("bridgey.agents.grants", Context.MODE_PRIVATE)
    override fun load(): Map<String, String> = preferences.all.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }.toMap()
    override fun save(deviceId: String, json: String) {
        preferences.edit().putString(deviceId, json).apply()
    }
    override fun remove(deviceId: String) {
        preferences.edit().remove(deviceId).apply()
    }
}
