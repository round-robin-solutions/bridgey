package dev.bridgey.android.codes

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Synthetic messages only: protocol/test-vectors/otp-samples.json, shared with the Mac and the relay. */
class CodeCoreTest {
    private data class Sample(val id: String, val body: String, val codes: List<String>)

    private val root = File(System.getProperty("bridgey.repoRoot"), "protocol/test-vectors")
    private val samples = JSONObject(File(root, "otp-samples.json").readText()).getJSONArray("samples").let { list ->
        (0 until list.length()).map { index ->
            val item = list.getJSONObject(index)
            val codes = item.getJSONArray("code")
            Sample(item.getString("id"), item.getString("body"), (0 until codes.length()).map(codes::getString))
        }
    }

    private fun sample(id: String) = samples.first { it.id == id }

    @Test
    fun guardAcceptsEveryExpectedCodeAsWritten() {
        assertEquals(42, samples.size)
        for (item in samples) {
            for (code in item.codes) {
                val expected = code.replace("G-", "").filter { it != '-' && it != ' ' }
                assertEquals(item.id, expected, CodeGuard.accept(code, item.body))
            }
        }
    }

    @Test
    fun guardRefusesWhatIsNotLiterallyThereOrNotCodeShaped() {
        val otp = sample("otp01").body
        assertNull(CodeGuard.accept("482914", otp))
        assertNull(CodeGuard.accept("4829", otp))
        assertNull(CodeGuard.accept("123456", sample("neg12").body))
        assertNull(CodeGuard.accept("381-406 4sgLq1p5sV6", sample("otp26").body))
        val text = "Pay 2,499.00 now. Ref ABCDEF and 123 and 12345678901"
        assertNull(CodeGuard.accept("2,499.00", text))
        assertNull(CodeGuard.accept("ABCDEF", text))
        assertNull(CodeGuard.accept("123", text))
        assertNull(CodeGuard.accept("12345678901", text))
        assertNull(CodeGuard.accept(null, text))
        assertEquals("aB3dE9", CodeGuard.accept("ab3de9", "Your code is aB3dE9."))
        assertEquals("441902", CodeGuard.accept("441 902", "Use 441-902 to sign in"))
    }

    @Test
    fun preCheckMatchesTheMacAndTheRelay() {
        samples.filter { it.codes.isNotEmpty() }.forEach { assertTrue(it.id, looksLikeOtpTraffic(it.body)) }
        val rejected = samples.filter { it.codes.isEmpty() && !looksLikeOtpTraffic(it.body) }.map { it.id }
        assertEquals(listOf("neg03", "neg05", "neg07", "neg10"), rejected)
    }

    @Test
    fun patternBaselineMatchesTheResearchHarness() {
        val expected = JSONObject(File(root, "otp-pattern-baseline.json").readText()).getJSONObject("answers")
        for (item in samples) {
            val want = if (expected.isNull(item.id)) null else expected.getString(item.id)
            assertEquals(item.id, want, PatternBaseline.extract(item.body))
        }
    }

    @Test
    fun codeAccessStatusMapping() {
        // Android 14 and older never hide codes.
        assertEquals(CodeAccessStatus.ALLOWED, codeAccessStatus(34, linked = false, appOpAllowed = false, lastSmsRedacted = null))
        assertEquals(CodeAccessStatus.NOT_LINKED, codeAccessStatus(36, linked = false, appOpAllowed = false, lastSmsRedacted = null))
        assertEquals(CodeAccessStatus.ALLOWED, codeAccessStatus(36, linked = true, appOpAllowed = false, lastSmsRedacted = null))
        assertEquals(CodeAccessStatus.ALLOWED, codeAccessStatus(36, linked = false, appOpAllowed = true, lastSmsRedacted = null))
        // What was seen wins over what should be.
        assertEquals(CodeAccessStatus.HIDDEN, codeAccessStatus(36, linked = true, appOpAllowed = false, lastSmsRedacted = true))
        assertEquals(CodeAccessStatus.HIDDEN, codeAccessStatus(34, linked = false, appOpAllowed = false, lastSmsRedacted = true))
        assertEquals(CodeAccessStatus.ALLOWED, codeAccessStatus(36, linked = false, appOpAllowed = false, lastSmsRedacted = false))
        assertEquals(listOf("allowed", "hidden", "not_linked"), CodeAccessStatus.entries.map { it.wire })
    }

    @Test
    fun redactionIsAndroidsPlaceholder() {
        assertTrue(isRedactedNotificationText("Sensitive notification content hidden", null))
        assertTrue(isRedactedNotificationText("  Содержимое скрыто ", "Содержимое скрыто"))
        assertFalse(isRedactedNotificationText(sample("otp01").body, "Содержимое скрыто"))
        assertFalse(isRedactedNotificationText("", null))
    }

    @Test
    fun adbFallbackCommand() {
        assertEquals(
            "adb shell cmd appops set --user 0 in.roundrobin.bridgey RECEIVE_SENSITIVE_NOTIFICATIONS allow",
            codeAccessAdbCommand("in.roundrobin.bridgey"),
        )
    }

    @Test
    fun relayRequestAndAnswers() {
        val body = JSONObject(CodeRelay.requestBody("  OTP 482913 \n", " HDFC Bank ")!!)
        assertEquals(1, body.getInt("v"))
        assertEquals("OTP 482913", body.getString("text"))
        assertEquals("HDFC Bank", body.getString("sender"))
        assertEquals(3, body.length())
        assertFalse(JSONObject(CodeRelay.requestBody("OTP 482913", "  ")!!).has("sender"))
        assertNull(CodeRelay.requestBody("1".repeat(601), null))
        assertNull(CodeRelay.requestBody("   ", null))
        assertEquals(64, CodeRelay.prefixWhole("😀".repeat(40), 64).length)
        assertEquals(63, CodeRelay.prefixWhole("a" + "😀".repeat(40), 64).length)
        assertTrue(CodeRelay.isInstallId(CodeRelay.newInstallId()))
        assertFalse(CodeRelay.isInstallId("AB".repeat(32)))

        assertEquals(CodeRelay.Answer.Candidate("482913"), CodeRelay.parse(200, """{"is_otp":true,"code":"482913"}"""))
        assertEquals(CodeRelay.Answer.NoCode, CodeRelay.parse(200, """{"is_otp":false,"code":null}"""))
        assertEquals(CodeRelay.Answer.NoCode, CodeRelay.parse(200, """{"is_otp":true,"code":null}"""))
        assertEquals(CodeRelay.Answer.Failed("invalid_response"), CodeRelay.parse(200, """{"code":"1"}"""))
        assertEquals(CodeRelay.Answer.Failed("invalid_response"), CodeRelay.parse(200, "nope"))
        assertEquals(CodeRelay.Answer.NoCode, CodeRelay.parse(422, """{"error":"not_otp_like"}"""))
        assertEquals(CodeRelay.Answer.Failed("rate_limited"), CodeRelay.parse(429, "{}"))
        assertEquals(CodeRelay.Answer.Failed("timeout"), CodeRelay.parse(504, "{}"))
        assertEquals(CodeRelay.Answer.Failed("unavailable"), CodeRelay.parse(502, "{}"))
    }

    @Test
    fun strictGuardRefusesWordsAndDatesThatLookLikeCodes() {
        assertNull(CodeGuard.accept("5minMe", "Order #2231 25 min me aa jayega. 5 min me pahunch jayenge."))
        assertNull(CodeGuard.accept("30-10-26", "Your bill of Rs 499 is due on 30-10-26. Pay now."))
        assertNull(CodeGuard.accept("301026", "Your bill of Rs 499 is due on 30-10-26. Pay now."))
        assertNull(CodeGuard.accept("4 8 2 9 1 3", "Code 4 8 2 9 1 3"))
        assertNull(CodeGuard.accept("12 34", "Seat 12 34"))
        assertNull(CodeGuard.accept("48291", "Use 48 291 now"))
        assertNull(CodeGuard.accept("123456789", "Ref 123456789"))
        assertNull(CodeGuard.accept("AB-CDEF", "Use AB-CDEF"))
    }

    @Test
    fun strictGuardAcceptsRealSplitAndPrefixedCodes() {
        assertEquals("482913", CodeGuard.accept("482913", "Your code is 482 913."))
        assertEquals("482913", CodeGuard.accept("482 913", "Your code is 482 913."))
        assertEquals("591047", CodeGuard.accept("591047", "OTP: 591-047"))
        assertEquals("301842", CodeGuard.accept("PP301842", "Passport Seva code PP-301842"))
        assertEquals("482917", CodeGuard.accept("G-482917", "G-482917 is your Google verification code."))
        assertEquals("7392", CodeGuard.accept("7392", "Zepto login ke liye OTP 7392 hai. Order 25 min me aa jayega."))
        assertEquals("12345678", CodeGuard.accept("12345678", "PIN 12345678"))
        assertEquals("X7KP92", CodeGuard.accept("x7Kp92", "Code: X7KP92"))
        assertEquals("0042", CodeGuard.accept("0042", "OTP 0042 for login"))
    }
}
