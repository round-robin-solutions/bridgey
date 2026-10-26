package dev.bridgey.android.codes

import java.io.File
import kotlin.random.Random
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Code reader test's ground truth flow and report. Synthetic messages only. */
class CodeTestTest {
    private data class Sample(val id: String, val sender: String, val body: String, val codes: List<String>)

    private val samples = JSONObject(File(System.getProperty("bridgey.repoRoot"), "protocol/test-vectors/otp-samples.json").readText())
        .getJSONArray("samples").let { list ->
            (0 until list.length()).map { index ->
                val item = list.getJSONObject(index)
                val codes = item.getJSONArray("code")
                Sample(item.getString("id"), item.getString("sender"), item.getString("body"), (0 until codes.length()).map(codes::getString))
            }
        }

    private val messages = samples.mapIndexed { index, sample ->
        TestMessage(index, sample.body, senderKind(sample.sender), scriptOf(sample.body))
    }

    private fun patternAnswers() = messages.associate { message ->
        val code = PatternBaseline.extract(message.body)?.let { CodeGuard.accept(it, message.body) ?: it }
        message.id to ExtractorAnswer(code, 1)
    }

    /** A perfect "cloud": the expected code, guarded. */
    private fun perfectAnswers() = messages.associate { message ->
        val expected = samples[message.id].codes.firstOrNull()
        message.id to ExtractorAnswer(expected?.let { CodeGuard.accept(it, message.body) }, 400 + message.id.toLong())
    }

    private fun truthLabels(run: CodeTestRun, ids: List<Int>): Map<Int, Label> = ids.associateWith { id ->
        samples[id].codes.firstOrNull()?.let { Label.Code(CodeGuard.accept(it, samples[id].body)!!) } ?: Label.NoCode
    }

    private val platform = PlatformFacts(36, CodeAccessStatus.NOT_LINKED, companionLinked = false, appOpAllowed = false, smsNotificationsSeen = 5, smsNotificationsHidden = 2)
    private val device = DeviceFacts("OnePlus", "CPH2449", "16", "0.6.0-rr.1-beta.12")

    @Test
    fun senderKindAndScript() {
        assertEquals(SenderKind.HEADER, senderKind("VM-HDFCBK"))
        assertEquals(SenderKind.HEADER, senderKind("GOOGLE"))
        assertEquals(SenderKind.NUMBER, senderKind("+91 98100 12345"))
        assertEquals(SenderKind.OTHER, senderKind(null))
        assertEquals(SenderKind.OTHER, senderKind("Mom & Dad"))
        assertEquals(Script.LATIN, scriptOf("OTP is 482913"))
        assertEquals(Script.DEVANAGARI, scriptOf("आपका कोड 482913 है"))
        assertEquals(Script.MIXED, scriptOf("आपका OTP 482913 है"))
        assertEquals(Script.OTHER, scriptOf("482913"))
    }

    @Test
    fun reviewQueueTakesDisagreementsThenARandomAudit() {
        val run = CodeTestRun(messages, mapOf(Extractor.PATTERN to patternAnswers(), Extractor.CLOUD to perfectAnswers()))
        val queue = run.reviewQueue(Random(7), auditPerSide = 3)
        val disagreements = messages.filter { !run.agreed(it.id) }.map { it.id }
        assertTrue(disagreements.isNotEmpty())
        assertEquals(disagreements, queue.take(disagreements.size))
        assertEquals(disagreements.size + 6, queue.size)
        assertEquals(queue.size, queue.toSet().size)
        // Candidates are the distinct proposed codes.
        val otp03 = samples.indexOfFirst { it.id == "otp03" }
        assertEquals(setOf("XX3005", "591047"), run.candidates(otp03).toSet())
    }

    @Test
    fun reportCountsAgainstLabelsAndAgreements() {
        val run = CodeTestRun(messages, mapOf(Extractor.PATTERN to patternAnswers(), Extractor.CLOUD to perfectAnswers()))
        val queue = run.reviewQueue(Random(1), auditPerSide = 0)
        val report = CodeTestReport.build(run, truthLabels(run, queue), platform, device, 0)
        val pattern = report.scores.getValue(Extractor.PATTERN)
        val cloud = report.scores.getValue(Extractor.CLOUD)
        // The research harness: the pattern got 24 of 30 codes, 5 wrong, 1 missed, 1 false alarm.
        assertEquals(24, pattern.codesRight)
        assertEquals(5, pattern.wrongCodes)
        assertEquals(1, pattern.misses)
        assertEquals(1, pattern.falseAlarms)
        assertEquals(11, pattern.correctNone)
        assertEquals(30, cloud.codesRight)
        assertEquals(12, cloud.correctNone)
        assertEquals(0, cloud.wrongCodes + cloud.misses + cloud.falseAlarms)
        assertEquals(42, report.messagesRead)
        assertEquals(queue.size, report.reviewed)
        assertEquals(42 - queue.size, report.provisional)
        assertEquals(0, report.unknown)
        assertEquals(42, report.ran[Extractor.CLOUD])
        assertEquals(421L to 439L, report.latency[Extractor.CLOUD])
    }

    @Test
    fun auditFindsSharedBlindSpots() {
        // Both extractors agree there is no code in otp16 (the pattern misses it, and so does a weak cloud).
        val weak = perfectAnswers().toMutableMap()
        val otp16 = samples.indexOfFirst { it.id == "otp16" }
        weak[otp16] = ExtractorAnswer(null, 400)
        val run = CodeTestRun(messages, mapOf(Extractor.PATTERN to patternAnswers(), Extractor.CLOUD to weak))
        assertTrue(run.agreed(otp16))
        val labels = mapOf(otp16 to Label.Code("381940"))
        val report = CodeTestReport.build(run, labels, platform, device, 0)
        assertEquals(1, report.auditNoneChecked)
        assertEquals(1, report.auditNoneWrong)
        assertEquals(1, report.scores.getValue(Extractor.CLOUD).misses)
    }

    @Test
    fun exportHoldsNoTextCodesOrSenders() {
        val run = CodeTestRun(messages, mapOf(Extractor.PATTERN to patternAnswers(), Extractor.CLOUD to perfectAnswers()))
        val queue = run.reviewQueue(Random(3))
        val json = CodeTestReport.build(run, truthLabels(run, queue), platform, device, 1_793_000_000_000).toJson().toString()
        for (sample in samples) {
            assertFalse(sample.id, json.contains(sample.sender))
            sample.codes.forEach { code -> assertFalse("${sample.id} $code", json.contains(code.filter { it.isLetterOrDigit() })) }
            // No 12-character run of any message survives.
            sample.body.windowed(12, 12).forEach { assertFalse(sample.id, json.contains(it)) }
        }
        listOf("HDFC", "SBI", "Paytm", "Amazon", "Google").forEach { assertFalse(it, json.contains(it, ignoreCase = true)) }
        val parsed = JSONObject(json)
        assertEquals(setOf("version", "createdAt", "device", "platform", "messages", "audit", "extractors"), parsed.keys().asSequence().toSet())
        assertEquals("not_linked", parsed.getJSONObject("platform").getString("codeAccess"))
        assertEquals(2, parsed.getJSONObject("platform").getInt("smsNotificationsHidden"))
        assertTrue(parsed.getJSONObject("extractors").getJSONObject("pattern").getJSONObject("byScript").has("latin"))
    }

    @Test
    fun cloudSeesOnlyCodeLikeMessagesPatternFlaggedFirst() {
        val flagged = patternAnswers().filterValues { it.code != null }.keys
        val selection = cloudSelection(messages, flagged, limit = 10, random = Random(5))
        assertEquals(10, selection.size)
        assertTrue(selection.all { looksLikeOtpTraffic(messages[it].body) })
        assertEquals(selection.take(10).toSet(), selection.filter { it in flagged }.toSet())
        val all = cloudSelection(messages, flagged, limit = 500, random = Random(5))
        assertEquals(messages.count { looksLikeOtpTraffic(it.body) }, all.size)
    }

    @Test
    fun percentileMatchesTheHarness() {
        assertEquals(0L, CodeTestReport.percentile(emptyList(), 0.5))
        assertEquals(3L, CodeTestReport.percentile(listOf(1L, 3L, 5L), 0.5))
        assertEquals(5L, CodeTestReport.percentile(listOf(1L, 3L, 5L), 0.95))
    }
}
