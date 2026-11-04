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
    private val recent = LinkedHashMap<String, Long>()
    private val perAgent = SlidingWindowLimiter(DETECT_PER_HOUR, 3_600_000L)

    /**
     * The agent that reads this message, or null when none should: [macReaders] connected Macs read codes for this
     * phone, [anyReader] is some agent with Read codes on, [detectors] the connected agents with Detect codes on.
     */
    @Synchronized fun pick(macReaders: Int, anyReader: Boolean, detectors: List<String>): String? {
        if (macReaders > 0 || !anyReader) return null
        prune(clock())
        if (pending.size >= DETECT_PENDING_MAX) return null
        val now = clock()
        return detectors.sorted().firstOrNull { perAgent.retryAfter(it, now) == null }
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
        pending[candidate.candidateId] = candidate
        perAgent.record(candidate.deviceId, candidate.sentAt)
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
