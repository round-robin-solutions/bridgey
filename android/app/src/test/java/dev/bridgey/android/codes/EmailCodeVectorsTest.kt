package dev.bridgey.android.codes

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone's preview gate (the shared [looksLikeCodeText]) gives the answers of `looks_like_email_code` in the Phase 0 email eval
 * (outputs/bridgey/research/otp-tiny-model/email/email_guard.py), stored as `phoneGate` in
 * protocol/test-vectors/email-codes-v1.json. The Mac checks its rules against the same file.
 */
class EmailCodeVectorsTest {
    private val vectors = JSONObject(
        File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/email-codes-v1.json").readText(),
    ).getJSONArray("vectors")

    @Test fun thePhoneGateMatchesTheEvalReference() {
        assertTrue(vectors.length() > 400)
        val failures = (0 until vectors.length()).filter { index ->
            val vector = vectors.getJSONObject(index)
            looksLikeCodeText(vector.getString("text")) != vector.getBoolean("phoneGate")
        }
        assertEquals("vectors that differ from email_guard.py (indexes only; texts are not printed)", emptyList<Int>(), failures)
    }

    @Test fun digitBoxCodesAreJoinedBeforeTheGate() {
        assertEquals("Your code is 482913", joinCodeDigitBoxes("Your code is 4 8 2 9 1 3"))
        assertEquals("OTP 602731.", joinCodeDigitBoxes("OTP 6-0-2-7-3-1."))
        assertEquals("Due 31-10-26", joinCodeDigitBoxes("Due 31-10-26"))
        assertTrue(looksLikeCodeText("Your verification code: 4 8 2 9 1 3"))
        assertTrue(looksLikeCodeText("Sign in with 7Q3-9XT"))
        assertFalse(looksLikeCodeText("Lunch on Friday at 1 2 or 3?"))
        assertEquals(
            "Your code\n4 8 2 9 1 3",
            emailPreview(EmailNotificationContent(text = "Your code", bigText = "4 8 2 9 1 3"), redacted = false),
        )
    }
}
