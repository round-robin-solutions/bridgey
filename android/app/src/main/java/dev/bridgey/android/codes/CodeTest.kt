package dev.bridgey.android.codes

import kotlin.random.Random
import org.json.JSONObject

/*
 * Code reader test (Phase 0, lab builds only): reads recent SMS on the phone, runs the extractors,
 * asks the person to confirm the disagreements and a random audit, and keeps only totals. The report
 * never holds message text, codes, senders or bank names. Messages stay in memory for the run.
 */

enum class SenderKind(val wire: String) { HEADER("header"), NUMBER("number"), OTHER("other") }

enum class Script(val wire: String) { LATIN("latin"), DEVANAGARI("devanagari"), MIXED("mixed"), OTHER("other") }

/** "VM-HDFCBK" or "GOOGLE" is a header; "+91 98..." a number. The address itself is never kept. */
fun senderKind(address: String?): SenderKind {
    val value = address?.trim().orEmpty()
    if (value.isEmpty()) return SenderKind.OTHER
    val digits = value.count { it.isDigit() }
    if (digits >= 5 && value.all { it.isDigit() || it in "+-() " }) return SenderKind.NUMBER
    if (value.length in 3..15 && value.any { it.isLetter() } && value.all { it in 'A'..'Z' || it in 'a'..'z' || it.isDigit() || it == '-' }) {
        return SenderKind.HEADER
    }
    return SenderKind.OTHER
}

fun scriptOf(text: String): Script {
    val devanagari = text.count { it in 'ऀ'..'ॿ' }
    val latin = text.count { it in 'A'..'Z' || it in 'a'..'z' }
    return when {
        devanagari > 0 && latin > 0 -> Script.MIXED
        devanagari > 0 -> Script.DEVANAGARI
        latin > 0 -> Script.LATIN
        else -> Script.OTHER
    }
}

/** One SMS for the run: a run-local id, its text (memory only), and coarse facts for the splits. */
class TestMessage(val id: Int, val body: String, val sender: SenderKind, val script: Script)

enum class Extractor(val wire: String) {
    /** Context words and digit patterns, for comparison. */
    PATTERN("pattern"),
    /** The relay (Cloudflare Workers AI) with the verbatim guard, only if the person ticked it. */
    CLOUD("cloud"),
}

/** One extractor's answer for one message: a guarded code or none, or a failure (timeout, error). */
data class ExtractorAnswer(val code: String?, val latencyMs: Long, val failed: Boolean = false)

sealed interface Label {
    data class Code(val code: String) : Label
    data object NoCode : Label
    data object Skipped : Label
}

private fun same(a: String?, b: String?): Boolean = a.equals(b, ignoreCase = true)

/** The ground truth flow: agreements are provisional; disagreements and a random audit are asked. */
class CodeTestRun(
    val messages: List<TestMessage>,
    val answers: Map<Extractor, Map<Int, ExtractorAnswer>>,
) {
    private fun answersFor(id: Int): List<ExtractorAnswer> = answers.values.mapNotNull { it[id] }.filterNot { it.failed }

    /** Every extractor that ran on it gave the same code (or all gave none). */
    fun agreed(id: Int): Boolean {
        val list = answersFor(id)
        return list.isNotEmpty() && list.all { same(it.code, list.first().code) }
    }

    fun agreedCode(id: Int): String? = answersFor(id).firstOrNull()?.code

    /** The codes the extractors proposed, shown as buttons on the review screen. */
    fun candidates(id: Int): List<String> = answersFor(id).mapNotNull { it.code }.distinctBy { it.uppercase() }

    /** Disagreements first, then up to [auditPerSide] agreed "code" and agreed "no code" messages at random. */
    fun reviewQueue(random: Random, auditPerSide: Int = 20): List<Int> {
        val disagreements = messages.filter { answersFor(it.id).isNotEmpty() && !agreed(it.id) }.map { it.id }
        val agreedCode = messages.filter { agreed(it.id) && agreedCode(it.id) != null }.map { it.id }
        val agreedNone = messages.filter { agreed(it.id) && agreedCode(it.id) == null }.map { it.id }
        return (disagreements + agreedCode.shuffled(random).take(auditPerSide) + agreedNone.shuffled(random).take(auditPerSide)).distinct()
    }

    /** The answer to score against: the person's label, else the agreement; null when unknown. */
    fun truth(id: Int, labels: Map<Int, Label>): Truth? = when (val label = labels[id]) {
        is Label.Code -> Truth(label.code)
        Label.NoCode -> Truth(null)
        Label.Skipped, null -> if (agreed(id)) Truth(agreedCode(id)) else null
    }

    data class Truth(val code: String?)
}

data class PlatformFacts(
    val sdkInt: Int,
    val codeAccess: CodeAccessStatus,
    val companionLinked: Boolean,
    val appOpAllowed: Boolean,
    /** SMS notifications the listener saw during the run, and how many Android hid. */
    val smsNotificationsSeen: Int,
    val smsNotificationsHidden: Int,
)

data class DeviceFacts(val manufacturer: String, val model: String, val release: String, val appVersion: String)

/** Counts for one extractor (or one split of it). */
data class Score(
    var codesRight: Int = 0,
    var wrongCodes: Int = 0,
    var misses: Int = 0,
    var falseAlarms: Int = 0,
    var correctNone: Int = 0,
    var failures: Int = 0,
) {
    fun add(answer: ExtractorAnswer, truth: CodeTestRun.Truth) {
        when {
            answer.failed -> failures++
            truth.code != null && answer.code == null -> misses++
            truth.code != null && same(answer.code, truth.code) -> codesRight++
            truth.code != null -> wrongCodes++
            answer.code != null -> falseAlarms++
            else -> correctNone++
        }
    }

    fun toJson(): JSONObject = JSONObject()
        .put("codesRight", codesRight)
        .put("wrongCodes", wrongCodes)
        .put("misses", misses)
        .put("falseAlarms", falseAlarms)
        .put("correctNone", correctNone)
        .put("failures", failures)
}

/** Aggregates only. [toJson] is what Export shares. */
class CodeTestReport(
    val createdAtMillis: Long,
    val device: DeviceFacts,
    val platform: PlatformFacts,
    val messagesRead: Int,
    val codeLike: Int,
    val reviewed: Int,
    val provisional: Int,
    val unknown: Int,
    val scores: Map<Extractor, Score>,
    val byScript: Map<Extractor, Map<Script, Score>>,
    val bySender: Map<Extractor, Map<SenderKind, Score>>,
    val ran: Map<Extractor, Int>,
    val latency: Map<Extractor, Pair<Long, Long>>,
    val auditCodeChecked: Int,
    val auditCodeWrong: Int,
    val auditNoneChecked: Int,
    val auditNoneWrong: Int,
) {
    fun toJson(): JSONObject {
        val extractors = JSONObject()
        scores.forEach { (extractor, score) ->
            val entry = score.toJson()
                .put("ran", ran[extractor] ?: 0)
                .put("medianMs", latency[extractor]?.first ?: 0)
                .put("p95Ms", latency[extractor]?.second ?: 0)
                .put("byScript", JSONObject().apply { byScript[extractor].orEmpty().forEach { (k, v) -> put(k.wire, v.toJson()) } })
                .put("bySender", JSONObject().apply { bySender[extractor].orEmpty().forEach { (k, v) -> put(k.wire, v.toJson()) } })
            extractors.put(extractor.wire, entry)
        }
        return JSONObject()
            .put("version", 1)
            .put("createdAt", java.time.Instant.ofEpochMilli(createdAtMillis).toString())
            .put("device", JSONObject()
                .put("manufacturer", device.manufacturer)
                .put("model", device.model)
                .put("android", device.release)
                .put("sdk", platform.sdkInt)
                .put("app", device.appVersion))
            .put("platform", JSONObject()
                .put("codeAccess", platform.codeAccess.wire)
                .put("companionLinked", platform.companionLinked)
                .put("appOpAllowed", platform.appOpAllowed)
                .put("smsNotificationsSeen", platform.smsNotificationsSeen)
                .put("smsNotificationsHidden", platform.smsNotificationsHidden))
            .put("messages", JSONObject()
                .put("read", messagesRead)
                .put("codeLike", codeLike)
                .put("reviewed", reviewed)
                .put("provisional", provisional)
                .put("unknown", unknown))
            .put("audit", JSONObject()
                .put("agreedCodeChecked", auditCodeChecked)
                .put("agreedCodeWrong", auditCodeWrong)
                .put("agreedNoneChecked", auditNoneChecked)
                .put("agreedNoneWrong", auditNoneWrong))
            .put("extractors", extractors)
    }

    companion object {
        fun build(
            run: CodeTestRun,
            labels: Map<Int, Label>,
            platform: PlatformFacts,
            device: DeviceFacts,
            createdAtMillis: Long,
        ): CodeTestReport {
            val scores = mutableMapOf<Extractor, Score>()
            val byScript = mutableMapOf<Extractor, MutableMap<Script, Score>>()
            val bySender = mutableMapOf<Extractor, MutableMap<SenderKind, Score>>()
            val latency = mutableMapOf<Extractor, Pair<Long, Long>>()
            val ran = mutableMapOf<Extractor, Int>()
            var reviewed = 0
            var provisional = 0
            var unknown = 0
            var auditCodeChecked = 0
            var auditCodeWrong = 0
            var auditNoneChecked = 0
            var auditNoneWrong = 0
            for (message in run.messages) {
                val label = labels[message.id]
                when {
                    label is Label.Code || label == Label.NoCode -> reviewed++
                    run.agreed(message.id) -> provisional++
                    else -> unknown++
                }
                if ((label is Label.Code || label == Label.NoCode) && run.agreed(message.id)) {
                    val agreedCode = run.agreedCode(message.id)
                    val labelled = (label as? Label.Code)?.code
                    if (agreedCode != null) {
                        auditCodeChecked++
                        if (!same(agreedCode, labelled)) auditCodeWrong++
                    } else {
                        auditNoneChecked++
                        if (labelled != null) auditNoneWrong++
                    }
                }
                val truth = run.truth(message.id, labels) ?: continue
                run.answers.forEach { (extractor, answers) ->
                    val answer = answers[message.id] ?: return@forEach
                    scores.getOrPut(extractor, ::Score).add(answer, truth)
                    byScript.getOrPut(extractor, ::mutableMapOf).getOrPut(message.script, ::Score).add(answer, truth)
                    bySender.getOrPut(extractor, ::mutableMapOf).getOrPut(message.sender, ::Score).add(answer, truth)
                }
            }
            run.answers.forEach { (extractor, answers) ->
                ran[extractor] = answers.size
                scores.getOrPut(extractor, ::Score)
                val times = answers.values.filterNot { it.failed }.map { it.latencyMs }.sorted()
                if (times.isNotEmpty()) latency[extractor] = percentile(times, 0.5) to percentile(times, 0.95)
            }
            return CodeTestReport(
                createdAtMillis, device, platform,
                messagesRead = run.messages.size,
                codeLike = run.messages.count { looksLikeOtpTraffic(it.body) },
                reviewed = reviewed, provisional = provisional, unknown = unknown,
                scores = scores, byScript = byScript, bySender = bySender, ran = ran, latency = latency,
                auditCodeChecked = auditCodeChecked, auditCodeWrong = auditCodeWrong,
                auditNoneChecked = auditNoneChecked, auditNoneWrong = auditNoneWrong,
            )
        }

        /** Linear interpolation between ranks, as the research harness computes it. */
        fun percentile(sorted: List<Long>, q: Double): Long {
            if (sorted.isEmpty()) return 0
            val k = (sorted.size - 1) * q
            val low = k.toInt()
            val high = (low + 1).coerceAtMost(sorted.size - 1)
            return Math.round(sorted[low] + (sorted[high] - sorted[low]) * (k - low))
        }
    }
}

/**
 * Which messages the cloud extractor sees when ticked: only code-like ones (the same pre-check the Mac
 * uses), every one the pattern flagged first, then a random sample of the rest, at most [limit].
 */
fun cloudSelection(messages: List<TestMessage>, patternFlagged: Set<Int>, limit: Int, random: Random): List<Int> {
    val codeLike = messages.filter { looksLikeOtpTraffic(it.body) && it.body.trim().length <= CodeRelay.MAX_TEXT_LENGTH }.map { it.id }
    val flagged = codeLike.filter { it in patternFlagged }
    val rest = codeLike.filterNot { it in patternFlagged }.shuffled(random)
    return (flagged + rest).take(limit)
}
