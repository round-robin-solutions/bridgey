package dev.bridgey.android.codes

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * protocol/test-vectors/codes-reader-v1.json, written by the shared Rust reader (rust/codes/examples/vectors.rs), the
 * single source of truth for the code rules: this phone's guard, digit-box join, guard text, gate, service key and
 * sender give the same answers until the phone calls the Rust reader itself.
 */
class CodeReaderVectorsTest {
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/codes-reader-v1.json").readText())

    private fun cases(name: String) = vectors.getJSONArray(name).let { list -> (0 until list.length()).map(list::getJSONObject) }

    @Test fun guard() = cases("guard").forEach { v ->
        val text = v.getString("text")
        val expect = v.opt("expect").takeIf { it != JSONObject.NULL } as String?
        assertEquals(v.toString(), expect, CodeGuard.accept(v.getString("answer"), codeGuardText(joinCodeDigitBoxes(text))))
    }

    @Test fun readText() = cases("readText").forEach { v -> assertEquals(v.toString(), v.getString("expect"), joinCodeDigitBoxes(v.getString("text"))) }

    @Test fun guardText() = cases("guardText").forEach { v -> assertEquals(v.toString(), v.getString("expect"), codeGuardText(v.getString("text"))) }

    @Test fun gate() = cases("gate").forEach { v -> assertEquals(v.toString(), v.getBoolean("expect"), looksLikeCodeText(v.getString("text"))) }

    @Test fun serviceKey() = cases("serviceKey").forEach { v ->
        assertEquals(v.toString(), v.getString("expect"), codeServiceKey(v.getString("sender")))
        assertEquals(v.toString(), v.getString("brokerKey"), brokerServiceKey(v.getString("sender")))
    }

    @Test fun sender() = cases("sender").forEach { v -> assertEquals(v.toString(), v.getString("expect"), codeSender(v.getString("title"), v.getString("applicationName"))) }

    /** The SMS half of the Rust candidate rule (the phone only sends text messages to agents in this version). */
    @Test fun smsCandidates() = cases("candidate").forEach { v ->
        val fields = v.getJSONObject("fields")
        val sms = fields.optBoolean("smsDefaultApp", fields.getString("packageName") == "com.truecaller") && !fields.optBoolean("redacted", false)
        if (!sms) return@forEach
        val expect = v.optJSONObject("expect")?.getString("text")
        assertEquals(v.toString(), expect, smsCandidateText(fields.getString("text")))
    }
}
