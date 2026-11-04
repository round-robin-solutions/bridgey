package dev.bridgey.android.agents

import dev.bridgey.android.codes.CodeGuard
import dev.bridgey.android.codes.brokerServiceKey
import dev.bridgey.android.codes.codeGuardText

/*
 * Detect codes (codes_detect_draft1, docs/mesh-and-codes.md): who reads a code text message when no Mac does, and
 * what the phone takes back. Pure Kotlin, so the rule is tested without a phone.
 *
 * The rule, per message: a candidate goes out only while some agent has Read codes on (the codes are for agents) and
 * no connected Mac reads codes for this phone (a Mac gets the notification anyway); then to exactly one agent with
 * Detect codes on, the lowest device ID among those connected, so a code text reaches as few devices as possible.
 * Its answer counts once, from that agent, within 30 seconds, and only if the guard finds the code in the text this
 * phone sent. The service is this phone's own reading of the sender; an agent cannot name one.
 *
 * Message text and codes live here for 30 seconds at most, in memory, never logged.
 */

/** How long an answer to a candidate is waited for. */
const val DETECT_WAIT_MILLIS = 30_000L

/** Candidates waiting for an answer, all agents together. */
const val DETECT_PENDING_MAX = 20

/** At most this many candidates go to one agent in an hour. */
const val DETECT_PER_HOUR = 60

/** One connected device as the rule sees it. */
data class ReaderLink(
    val agent: Boolean,
    /** The device advertised sms_codes_draft1 (it reads codes in what this phone forwards). */
    val smsCodes: Boolean,
    /** This phone forwards notifications to it now (its Notifications switch on here and there). */
    val notifiedHere: Boolean,
    /** It advertised agents_mirror_draft1: it sends the codes it finds back (codes.found). */
    val mirror: Boolean,
)

/**
 * Macs that read code text messages from this phone now: any connected Mac with sms_codes_draft1 that this phone
 * sends notifications to, mirror or not (it sees the text anyway, so no agent needs to). A Mac whose Notifications
 * switch is off here receives nothing and does not count.
 */
fun macsReadingCodes(links: List<ReaderLink>): Int = links.count { !it.agent && it.smsCodes && it.notifiedHere }

/** Of those, the Macs that send codes back for agents (codes.result `readers` counts these). */
fun macsReportingCodes(links: List<ReaderLink>): Int = links.count { !it.agent && it.smsCodes && it.notifiedHere && it.mirror }

/**
 * Whether this phone reads a code text message over cloud itself: only when no Mac reads codes, some agent has Read
 * codes on, no agent with Detect codes is connected (servers come before the cloud), and the person chose "Use cloud
 * when no Mac is reading". Text messages only: the caller never passes mail.
 */
fun cloudReads(macReaders: Int, anyReader: Boolean, detectors: Int, cloudOn: Boolean): Boolean =
    cloudOn && anyReader && macReaders == 0 && detectors == 0

/** A typed tailnet name, address or address:port, to the host and port to dial (Bridgey's 42458 by default). */
fun tailnetTarget(typed: String): Pair<String, Int> {
    val text = typed.trim()
    val bracketed = Regex("^\\[([0-9A-Fa-f:.]+)](?::(\\d{1,5}))?$").find(text)
    if (bracketed != null) return bracketed.groupValues[1] to (bracketed.groupValues[2].toIntOrNull()?.takeIf { it in 1..65535 } ?: 42_458)
    if (text.count { it == ':' } == 1) {
        return text.substringBefore(':') to (text.substringAfter(':').toIntOrNull()?.takeIf { it in 1..65535 } ?: 42_458)
    }
    return text to 42_458
}

/** An agent's own map (agent_draft1 with notify_draft1 and ask_draft1): a server paired directly, not by invite. */
fun advertisesAgent(drafts: Map<String, Boolean>): Boolean =
    drafts[AGENT_FEATURE_KEY] == true && drafts[NOTIFY_FEATURE_KEY] == true && drafts[ASK_FEATURE_KEY] == true

/** One candidate sent to one agent, waiting for its codes.detected. */
data class PendingCandidate(
    val candidateId: String,
    val deviceId: String,
    val text: String,
    val sender: String,
    val source: CodeSource,
    val app: String,
    val notificationId: String,
    val postedAt: Long,
    val sentAt: Long,
)

sealed interface DetectAnswer {
    /** Not a candidate this phone is waiting for from that agent (unknown, answered already, late or another agent's). */
    data object Unknown : DetectAnswer

    /** A code the guard accepted, ready for the broker. */
    data class Found(val found: CodeFound) : DetectAnswer

    /** The agent's code is not in the message (refused by the guard). */
    data object Refused : DetectAnswer

    /** No code, or the agent could not read it. */
    data class Empty(val outcome: CodesDetectedOutcome) : DetectAnswer
}

class CodeDetections(private val clock: () -> Long = System::currentTimeMillis) {
    private val pending = LinkedHashMap<String, PendingCandidate>()
    /** Picked but not yet sent (or failed to send): they count towards [DETECT_PENDING_MAX] like pending ones. */
    private var reserved = 0
    private val recent = LinkedHashMap<String, Long>()
    private val perAgent = SlidingWindowLimiter(DETECT_PER_HOUR, 3_600_000L)

    /**
     * The agent that reads this message, or null when none should: [macReaders] connected Macs read codes for this
     * phone, [anyReader] is some agent with Read codes on, [detectors] the connected agents with Detect codes on, in
     * the order Rahul switched it on (the first one he allowed first). Device IDs are chosen by the devices
     * themselves, so they never decide. Picking takes the agent's rate slot and a pending slot at once; follow with
     * [sent] or [release].
     */
    @Synchronized fun pick(macReaders: Int, anyReader: Boolean, detectors: List<String>): String? {
        if (macReaders > 0 || !anyReader) return null
        val now = clock()
        prune(now)
        if (pending.size + reserved >= DETECT_PENDING_MAX) return null
        val target = detectors.firstOrNull { perAgent.retryAfter(it, now) == null } ?: return null
        perAgent.record(target, now)
        reserved++
        return target
    }

    /** The picked candidate could not be sent: its pending slot is free again (the rate slot stays used). */
    @Synchronized fun release() {
        if (reserved > 0) reserved--
    }

    /**
     * True the first time this notification shows this text within two minutes: Android posts a notification again
     * when it is updated, and a text already read is not sent twice.
     */
    @Synchronized fun firstSight(notificationId: String, text: String): Boolean {
        val now = clock()
        recent.entries.removeAll { now - it.value >= 120_000L }
        val key = notificationId + "\u0000" + text.hashCode()
        if (key in recent) return false
        recent[key] = now
        while (recent.size > 100) recent.remove(recent.keys.first())
        return true
    }

    @Synchronized fun sent(candidate: PendingCandidate) {
        if (reserved > 0) reserved--
        pending[candidate.candidateId] = candidate
    }

    /** codes.detected from [deviceId]: taken once, from the agent it went to, within [DETECT_WAIT_MILLIS]. */
    @Synchronized fun answer(deviceId: String, detected: CodesDetected): DetectAnswer {
        prune(clock())
        val candidate = pending[detected.candidateId]?.takeIf { it.deviceId == deviceId } ?: return DetectAnswer.Unknown
        pending.remove(detected.candidateId)
        if (detected.outcome != CodesDetectedOutcome.FOUND) return DetectAnswer.Empty(detected.outcome)
        val code = CodeGuard.accept(detected.code, codeGuardText(candidate.text)) ?: return DetectAnswer.Refused
        return DetectAnswer.Found(
            CodeFound(
                foundId = java.util.UUID.randomUUID().toString(),
                code = code,
                service = candidate.sender,
                serviceKey = brokerServiceKey(candidate.sender),
                source = candidate.source,
                app = candidate.app,
                notificationId = candidate.notificationId,
                postedAt = candidate.postedAt,
            ),
        )
    }

    @Synchronized fun forget(deviceId: String) {
        pending.entries.removeAll { it.value.deviceId == deviceId }
        perAgent.forget(deviceId)
    }

    @Synchronized fun pendingCount(): Int {
        prune(clock())
        return pending.size
    }

    private fun prune(now: Long) {
        pending.entries.removeAll { now - it.value.sentAt >= DETECT_WAIT_MILLIS }
    }
}
