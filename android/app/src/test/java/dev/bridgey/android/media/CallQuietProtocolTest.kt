package dev.bridgey.android.media

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CallQuietProtocolTest {
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."),
        "protocol/test-vectors/call-media-v1.json").readText())

    @Test fun allSharedStateAndResultVectorsMatchBothPlatformContract() {
        assertEquals("bridgey.call-media.v1", vectors.getString("format"))
        listOf("state", "result").forEach { kind ->
            val cases = vectors.getJSONArray(kind)
            for (i in 0 until cases.length()) {
                val case = cases.getJSONObject(i)
                val text = if (case.has("plaintextString")) case.getString("plaintextString") else case.getJSONObject("plaintext").toString()
                val bytes = text.toByteArray(Charsets.UTF_8)
                val decoded = if (kind == "state") decodeCallQuietState(bytes)?.encode() else decodeCallQuietResult(bytes)?.encode()
                val name = "$kind: ${case.getString("name")}"
                assertEquals(name, case.getBoolean("valid"), decoded != null)
                if (decoded != null) {
                    val original = JSONObject(text)
                    assertEquals(name, original.getInt("revision"), decoded.getInt("revision"))
                    if (kind == "state") {
                        assertEquals(name, arrayStrings(original, "calls"), arrayStrings(decoded, "calls"))
                        assertEquals(name, original.getBoolean("uncertain"), decoded.getBoolean("uncertain"))
                    } else {
                        listOf("paused", "muted", "limited").forEach { assertEquals(name, original.getInt(it), decoded.getInt(it)) }
                        assertEquals(name, arrayStrings(original, "issues"), arrayStrings(decoded, "issues"))
                    }
                }
            }
        }
    }

    @Test fun rejectsEscapedEquivalentDuplicateKeysAndMalformedUtf8() {
        assertNull(decodeCallQuietState("""{"version":1,"ver\u0073ion":1,"revision":1,"calls":[],"uncertain":false}""".toByteArray()))
        assertNull(decodeCallQuietState(byteArrayOf(0x7b, 0x22, 0xc3.toByte(), 0x22, 0x3a, 0x31, 0x7d)))
    }

    private fun arrayStrings(value: JSONObject, key: String): Set<String> = value.getJSONArray(key).let { array ->
        (0 until array.length()).mapTo(mutableSetOf()) { array.getString(it) }
    }
}
