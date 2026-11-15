package dev.bridgey.android.dialer

import dev.bridgey.android.ProtocolGoldenVectorsTest.Companion.normalize
import dev.bridgey.android.sms.SimInfo
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Calls window (dialer_draft1): protocol/test-vectors/dialer-v1.json, decoded here as the phone decodes
 * requests and written as the phone writes its answers; the Mac decodes the same file. Regenerate with
 * protocol/tools/dialer_vectors.py.
 */
class DialerProtocolTest {
    private val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
    private val vectors = JSONObject(File(root, "protocol/test-vectors/dialer-v1.json").readText())

    private fun plaintext(vector: JSONObject): ByteArray =
        (if (vector.has("plaintextString")) vector.getString("plaintextString") else vector.get("plaintext").toString()).toByteArray()

    private fun each(group: String, check: (JSONObject) -> Boolean) {
        val array = vectors.getJSONArray(group)
        assertTrue(array.length() > 5)
        val failed = (0 until array.length()).map(array::getJSONObject).filterNot { runCatching { check(it) }.getOrDefault(false) }.map { it.getString("name") }
        assertEquals("$group vectors that decode differently from the contract", emptyList<String>(), failed)
    }

    @Test fun requestsFromTheMac() = each("request") { vector ->
        val decoded: Any = when (val request = decodeDialerRequest(vector.getString("kind"), plaintext(vector))) {
            null -> "reject"
            is DialerRequest.Contacts -> mapOf("requestId" to request.requestId, "query" to request.query)
            is DialerRequest.Recents -> mapOf("requestId" to request.requestId, "limit" to request.limit.toLong())
            is DialerRequest.Call -> mapOf(
                "requestId" to request.requestId, "via" to request.via.wire, "address" to request.address,
                "subId" to request.subId?.toLong(), "dataId" to request.dataId,
            )
        }
        decoded == normalize(vector.get("expect"))
    }

    /** The phone's own answers: for every vector marked android, its writer produces exactly that plaintext. */
    @Test fun statusIsWrittenAsTheVectorsSay() = writes("status") { expect ->
        val sims = expect.getJSONArray("sims").let { list -> (0 until list.length()).map { list.getJSONObject(it) }.map { SimInfo(it.getInt("subId"), it.getInt("slot"), it.getString("label")) } }
        dialerStatusPayload(
            DialerStatus(
                expect.getBoolean("place"), expect.getBoolean("confirm"), Access.entries.first { it.wire == expect.getString("contacts") },
                Access.entries.first { it.wire == expect.getString("recents") }, expect.getBoolean("whatsapp"), sims,
            ),
        )
    }

    @Test fun contactsAreWrittenAsTheVectorsSay() = writes("contacts") { expect ->
        val list = expect.getJSONArray("contacts")
        val contacts = (0 until list.length()).map { list.getJSONObject(it) }.map { c ->
            val numbers = c.getJSONArray("numbers").let { n -> (0 until n.length()).map { n.getJSONObject(it) } }
                .map { DialerNumber(it.getString("address"), it.optString("label").takeIf { _ -> !it.isNull("label") }) }
            val whatsApp = c.getJSONArray("whatsapp").let { w -> (0 until w.length()).map { w.getJSONObject(it) } }
                .map { WhatsAppEntry(it.getString("address"), it.optLong("voice").takeIf { _ -> !it.isNull("voice") }, it.optLong("video").takeIf { _ -> !it.isNull("video") }) }
            DialerContact(c.getLong("id"), c.getString("name"), c.getBoolean("starred"), numbers, whatsApp)
        }
        dialerContactsPayload(expect.getString("requestId"), contacts, expect.optString("error").takeIf { !expect.isNull("error") })
    }

    @Test fun recentsAreWrittenAsTheVectorsSay() = writes("recents") { expect ->
        val list = expect.getJSONArray("calls")
        val calls = (0 until list.length()).map { list.getJSONObject(it) }.map { c ->
            RecentCall(
                c.getLong("id"), c.getString("address"), c.optString("name").takeIf { !c.isNull("name") },
                RecentType.entries.first { it.wire == c.getString("type") }, c.getLong("date"), c.getLong("duration"),
                c.optInt("subId").takeIf { !c.isNull("subId") },
            )
        }
        dialerRecentsPayload(expect.getString("requestId"), calls, expect.optString("error").takeIf { !expect.isNull("error") })
    }

    @Test fun callResultsAreWrittenAsTheVectorsSay() = writes("callResult") { expect ->
        dialerCallResultPayload(
            expect.getString("requestId"), CallOutcome.entries.first { it.wire == expect.getString("result") },
            expect.optString("reason").takeIf { !expect.isNull("reason") }?.let { r -> RefuseReason.entries.first { it.wire == r } },
        )
    }

    private fun writes(group: String, write: (JSONObject) -> JSONObject) {
        val array = vectors.getJSONArray(group)
        val written = (0 until array.length()).map(array::getJSONObject).filter { it.optBoolean("android") }
        assertTrue("$group has phone-written vectors", written.size >= 2)
        val failed = written.filterNot { vector ->
            runCatching { normalize(write(vector.getJSONObject("expect"))) == normalize(vector.getJSONObject("plaintext")) }.getOrDefault(false)
        }.map { it.getString("name") }
        assertEquals("$group vectors the phone writes differently", emptyList<String>(), failed)
    }

    /** A kind the phone decodes but the session never hands over is silently dropped (as sms.mark_read once was). */
    @Test fun everyRequestFromAMacIsRoutedToTheDialerServer() {
        val source = File(root, "android/app/src/main/java/dev/bridgey/android/PairingCoordinator.kt").readText()
        val routed = Regex("((?:\"dialer\\.[a-z_]+\",?\\s*)+)->\\s*receiveDialerMessage").find(source)?.groupValues?.get(1).orEmpty()
        val kinds = Regex("\"(dialer\\.[a-z_]+)\"").findAll(routed).map { it.groupValues[1] }.toSet()
        assertEquals(DialerKinds.fromMac, kinds)
    }

    @Test fun whatsAppIntentOpensOnlyWhatsAppCallRowsOfTheAskedKind() {
        val voice = whatsAppIntent(CallVia.WHATSAPP_VOICE, 4211, "vnd.android.cursor.item/vnd.com.whatsapp.voip.call")!!
        assertEquals("com.whatsapp", voice.packageName)
        assertEquals("content://com.android.contacts/data/4211", voice.dataUri)
        assertEquals("vnd.android.cursor.item/vnd.com.whatsapp.voip.call", voice.mimeType)
        val video = whatsAppIntent(CallVia.WHATSAPP_VIDEO, 4212, "vnd.android.cursor.item/vnd.com.whatsapp.video.call")!!
        assertEquals("vnd.android.cursor.item/vnd.com.whatsapp.video.call", video.mimeType)
        val business = whatsAppIntent(CallVia.WHATSAPP_VIDEO, 9, "vnd.android.cursor.item/vnd.com.whatsapp.w4b.video.call")!!
        assertEquals("com.whatsapp.w4b", business.packageName)
        // The wrong kind, another app's row, a phone number row, a missing row, or a phone call: nothing opens.
        assertNull(whatsAppIntent(CallVia.WHATSAPP_VIDEO, 4211, "vnd.android.cursor.item/vnd.com.whatsapp.voip.call"))
        assertNull(whatsAppIntent(CallVia.WHATSAPP_VOICE, 4212, "vnd.android.cursor.item/vnd.com.whatsapp.video.call"))
        assertNull(whatsAppIntent(CallVia.WHATSAPP_VOICE, 5, "vnd.android.cursor.item/phone_v2"))
        assertNull(whatsAppIntent(CallVia.WHATSAPP_VOICE, 5, "vnd.android.cursor.item/vnd.org.telegram.messenger.android.call"))
        assertNull(whatsAppIntent(CallVia.WHATSAPP_VOICE, 5, null))
        assertNull(whatsAppIntent(CallVia.PHONE, 5, "vnd.android.cursor.item/vnd.com.whatsapp.voip.call"))
        assertNull(whatsAppIntent(CallVia.WHATSAPP_VOICE, 0, "vnd.android.cursor.item/vnd.com.whatsapp.voip.call"))
    }

    @Test fun whatsAppNumbersComeFromTheJid() {
        assertEquals("+919876543210", whatsAppNumber("919876543210@s.whatsapp.net"))
        assertNull(whatsAppNumber("abc@s.whatsapp.net"))
        assertNull(whatsAppNumber(null))
        assertNull(whatsAppNumber("12@s.whatsapp.net"))
        assertEquals("+919876543210", DialerProvider.summaryNumber("Voice call +91 98765 43210"))
        assertNull(DialerProvider.summaryNumber("Voice call"))
    }

    @Test fun simChoiceKeepsTheMacsPickOnlyWhenThatSimIsActive() {
        val sims = listOf(SimInfo(1, 0, "Jio"), SimInfo(2, 1, "Airtel"))
        assertEquals(SimChoice.PhoneDefault, chooseSim(null, sims))
        assertEquals(SimChoice.Sim(2), chooseSim(2, sims))
        assertEquals(SimChoice.Missing, chooseSim(7, sims))
        // A phone that cannot list its SIMs passes the pick on; Telecom ignores an account it does not have.
        assertEquals(SimChoice.Sim(7), chooseSim(7, emptyList()))
    }

    @Test fun contactsAreGroupedStarredFirstWithoutRepeatedNumbers() {
        val rows = listOf(
            ContactRow(3, "Rohan", false, number = DialerNumber("100200")),
            ContactRow(7, "Anna Kapoor", true, number = DialerNumber("+91 98765 43210", "Mobile")),
            ContactRow(7, "Anna Kapoor", true, number = DialerNumber("+919876543210", "Mobile")),
            ContactRow(7, "Anna Kapoor", true, number = DialerNumber("+91 22 4000 1234", "Work")),
            ContactRow(7, "Anna Kapoor", true, whatsApp = "+919876543210" to WhatsAppCall(4211, video = false)),
            ContactRow(7, "Anna Kapoor", true, whatsApp = "+919876543210" to WhatsAppCall(4212, video = true)),
            ContactRow(9, null, false, number = DialerNumber("555 0100")),
            ContactRow(11, "Mahima", false, whatsApp = "+919812345678" to WhatsAppCall(9, video = true)),
        )
        val contacts = groupContacts(rows)
        assertEquals(listOf(7L, 3L, 9L, 11L), contacts.map { it.id })
        val anna = contacts.first()
        assertEquals(listOf("+91 98765 43210", "+91 22 4000 1234"), anna.numbers.map { it.address })
        assertEquals(listOf(WhatsAppEntry("+919876543210", voice = 4211, video = 4212)), anna.whatsApp)
        assertEquals("555 0100", contacts[2].name)
        assertTrue(contacts[3].numbers.isEmpty())
        assertEquals(2, groupContacts(rows, limit = 2).size)
    }

    @Test fun pagesStayUnderTheirLimits() {
        val many = (1..20).map { i -> DialerContact(i.toLong(), "n".repeat(128), numbers = (1..8).map { DialerNumber("+$it".padEnd(64, '5'), "l".repeat(32)) }) }
        val contacts = dialerContactsPayload("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", many)
        assertTrue(contacts.toString().toByteArray().size <= DialerLimits.CONTACTS_RESULT_MAX_BYTES)
        assertTrue(contacts.getJSONArray("contacts").length() in 1 until 20)
        val calls = (1..50L).map { RecentCall(it, "+1".padEnd(64, '5'), "n".repeat(128), RecentType.MISSED, 9_007_199_254_740_991L, 3600, 1) }
        val recents = dialerRecentsPayload("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", calls)
        assertTrue(recents.toString().toByteArray().size <= DialerLimits.RECENTS_RESULT_MAX_BYTES)
    }

    @Test fun callLogTypesMapToTheWire() {
        assertEquals(listOf("incoming", "outgoing", "missed", "voicemail", "rejected", "blocked", "incoming", "incoming"),
            listOf(1, 2, 3, 4, 5, 6, 7, 99).map { RecentType.fromCallLog(it).wire })
    }

    @Test fun limiterSpacesCallsAndCapsReads() {
        var now = 0L
        val limiter = DialerLimiter { now }
        assertTrue(limiter.allowCall("mac"))
        now += 2_999
        assertFalse("one every 3 seconds", limiter.allowCall("mac"))
        assertTrue("another Mac has its own budget", limiter.allowCall("other"))
        repeat(9) { now += 3_000; assertTrue(limiter.allowCall("mac")) }
        now += 3_000
        assertFalse("10 in 10 minutes", limiter.allowCall("mac"))
        now += DialerLimiter.CALL_WINDOW_MILLIS
        assertTrue(limiter.allowCall("mac"))
        repeat(DialerLimiter.CONTACTS_PER_WINDOW) { assertTrue(limiter.allowContacts("mac")) }
        assertFalse(limiter.allowContacts("mac"))
        repeat(DialerLimiter.RECENTS_PER_WINDOW) { assertTrue(limiter.allowRecents("mac")) }
        assertFalse(limiter.allowRecents("mac"))
        now += DialerLimiter.READ_WINDOW_MILLIS
        assertTrue(limiter.allowContacts("mac"))
        limiter.forget("mac")
        assertTrue(limiter.allowRecents("mac"))
    }
}
