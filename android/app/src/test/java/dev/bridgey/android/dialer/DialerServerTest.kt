package dev.bridgey.android.dialer

import dev.bridgey.android.sms.SimInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The phone's side of the Calls window against a fake phone: grants, permissions, limits, SIMs and WhatsApp. */
class DialerServerTest {
    private class FakePhone : DialerPhone {
        override var canPlace = true
        override var contactsAccess = Access.ON
        override var recentsAccess = Access.ON
        var whatsApp = true
        var screens = true
        var sims = listOf(SimInfo(1, 0, "Jio"), SimInfo(2, 1, "Airtel"))
        var rows = mapOf(4211L to ("vnd.android.cursor.item/vnd.com.whatsapp.voip.call" to "Anna Kapoor"), 4212L to ("vnd.android.cursor.item/vnd.com.whatsapp.video.call" to "Anna Kapoor"))
        val placed = mutableListOf<Pair<String, SimChoice>>()
        val opened = mutableListOf<WhatsAppIntentSpec>()
        val waiting = mutableListOf<PendingCall>()
        var notificationsOn = true
        var contactsRead = 0

        override fun whatsAppInstalled() = whatsApp
        override fun sims() = sims
        override fun contacts(query: String): List<DialerContact> {
            contactsRead++
            return listOf(DialerContact(7, "Anna Kapoor", numbers = listOf(DialerNumber("100200"))))
        }
        override fun recents(limit: Int) = listOf(RecentCall(1, "100200", type = RecentType.MISSED, date = 5, duration = 0))
        override fun emergency(number: String) = number == "112" || number == "911"
        override fun dataRow(dataId: Long) = rows[dataId]
        override fun placeCall(number: String, sim: SimChoice): Boolean = placed.add(number to sim)
        override fun canOpenScreens() = screens
        override fun openWhatsApp(spec: WhatsAppIntentSpec): Boolean = opened.add(spec)
        override fun confirm(request: PendingCall, macName: String): Boolean = notificationsOn && waiting.add(request)
    }

    private val phone = FakePhone()
    private var allowed = mutableSetOf("mac")
    private var askFirst = false
    private var now = 0L
    private val sent = mutableListOf<Triple<String, String, JSONObject>>()
    private val recorded = mutableListOf<Pair<String, DialerActivity>>()
    private val server = DialerServer(
        phone = phone,
        scope = CoroutineScope(Dispatchers.Unconfined),
        localEnabled = { it in allowed },
        peers = { allowed.toList() },
        send = { id, kind, payload -> sent.add(Triple(id, kind, payload)) },
        askFirst = { askFirst },
        macName = { "Work Mac" },
        record = { id, activity -> recorded.add(id to activity) },
        clock = { now },
    )

    private fun call(address: String? = "+91 98765 43210", subId: Int? = null, via: CallVia = CallVia.PHONE, dataId: Long? = null) =
        server.place("mac", DialerRequest.Call("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", via, address, subId, dataId)).also { now += 3_000 }

    @Test fun aMacThatIsNotAllowedIsRefusedAndNothingHappens() {
        allowed.clear()
        assertEquals(CallOutcome.REFUSED to RefuseReason.DISABLED, call())
        assertEquals(CallOutcome.REFUSED to RefuseReason.DISABLED, call(via = CallVia.WHATSAPP_VOICE, address = null, dataId = 4211))
        server.handle("mac", DialerRequest.Contacts("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", "Ann"))
        server.handle("mac", DialerRequest.Recents("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", 20))
        assertTrue(phone.placed.isEmpty() && phone.opened.isEmpty() && phone.waiting.isEmpty() && recorded.isEmpty())
        assertEquals(0, phone.contactsRead)
        assertEquals(listOf("disabled", "disabled"), sent.map { it.third.getString("error") })
    }

    @Test fun aCallStartsOnTheChosenSimAndIsRecorded() {
        assertEquals(CallOutcome.STARTED to null, call(subId = 2))
        assertEquals(listOf("+91 98765 43210" to SimChoice.Sim(2)), phone.placed)
        assertEquals(listOf("mac" to DialerActivity.PHONE_STARTED), recorded)
        assertEquals(CallOutcome.STARTED to null, call(subId = null))
        assertEquals(SimChoice.PhoneDefault, phone.placed.last().second)
        assertEquals(CallOutcome.REFUSED to RefuseReason.NO_SIM, call(subId = 9))
        assertEquals(2, phone.placed.size)
    }

    @Test fun emergencyNumbersAreNeverPlaced() {
        assertEquals(CallOutcome.REFUSED to RefuseReason.EMERGENCY, call(address = "112"))
        askFirst = true
        assertEquals(CallOutcome.REFUSED to RefuseReason.EMERGENCY, call(address = "911"))
        assertTrue(phone.placed.isEmpty() && phone.waiting.isEmpty())
    }

    @Test fun withoutCallPhoneOrWithAskFirstTheCallWaitsForATap() {
        phone.canPlace = false
        assertEquals(CallOutcome.CONFIRM to null, call(subId = 1))
        assertEquals(PendingCall.Phone("+91 98765 43210", 1), phone.waiting.single())
        phone.canPlace = true
        askFirst = true
        assertEquals(CallOutcome.CONFIRM to null, call())
        assertTrue(phone.placed.isEmpty())
        assertEquals(listOf(DialerActivity.WAITING, DialerActivity.WAITING), recorded.map { it.second })
        phone.notificationsOn = false
        assertEquals("no notification, no silent call", CallOutcome.REFUSED to RefuseReason.PERMISSION, call())
    }

    @Test fun callsAreRateLimitedPerMac() {
        assertEquals(CallOutcome.STARTED to null, server.place("mac", DialerRequest.Call("r", CallVia.PHONE, "100200", null, null)))
        assertEquals(CallOutcome.REFUSED to RefuseReason.RATE_LIMITED, server.place("mac", DialerRequest.Call("r", CallVia.PHONE, "100200", null, null)))
        assertEquals(1, phone.placed.size)
    }

    @Test fun whatsAppOpensTheRowsKindAndOnlyWithContacts() {
        assertEquals(CallOutcome.STARTED to null, call(via = CallVia.WHATSAPP_VIDEO, address = null, dataId = 4212))
        assertEquals("vnd.android.cursor.item/vnd.com.whatsapp.video.call", phone.opened.single().mimeType)
        assertEquals(DialerActivity.WHATSAPP_STARTED, recorded.single().second)
        assertEquals(CallOutcome.REFUSED to RefuseReason.NOT_FOUND, call(via = CallVia.WHATSAPP_VIDEO, address = null, dataId = 4211))
        assertEquals(CallOutcome.REFUSED to RefuseReason.NOT_FOUND, call(via = CallVia.WHATSAPP_VOICE, address = null, dataId = 77))
        phone.whatsApp = false
        assertEquals(CallOutcome.REFUSED to RefuseReason.UNAVAILABLE, call(via = CallVia.WHATSAPP_VOICE, address = null, dataId = 4211))
        phone.whatsApp = true
        phone.contactsAccess = Access.OFF
        assertEquals(CallOutcome.REFUSED to RefuseReason.PERMISSION, call(via = CallVia.WHATSAPP_VOICE, address = null, dataId = 4211))
        phone.contactsAccess = Access.UNAVAILABLE
        assertEquals(CallOutcome.REFUSED to RefuseReason.UNAVAILABLE, call(via = CallVia.WHATSAPP_VOICE, address = null, dataId = 4211))
        assertEquals(1, phone.opened.size)
    }

    @Test fun whatsAppFromTheBackgroundWaitsForATap() {
        phone.screens = false
        assertEquals(CallOutcome.CONFIRM to null, call(via = CallVia.WHATSAPP_VOICE, address = null, dataId = 4211))
        val pending = phone.waiting.single() as PendingCall.WhatsApp
        assertEquals("Anna Kapoor", pending.name)
        assertEquals(false, pending.video)
        assertTrue(phone.opened.isEmpty())
    }

    @Test fun readsFollowPermissionsAndLimits() {
        server.handle("mac", DialerRequest.Contacts("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", "Ann"))
        assertEquals(1, sent.last().third.getJSONArray("contacts").length())
        phone.contactsAccess = Access.OFF
        server.handle("mac", DialerRequest.Contacts("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", "Ann"))
        assertEquals("permission", sent.last().third.getString("error"))
        phone.recentsAccess = Access.UNAVAILABLE
        server.handle("mac", DialerRequest.Recents("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", 20))
        assertEquals("unavailable", sent.last().third.getString("error"))
        phone.recentsAccess = Access.ON
        repeat(DialerLimiter.RECENTS_PER_WINDOW + 1) { server.handle("mac", DialerRequest.Recents("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293", 20)) }
        assertEquals("rate_limited", sent.last().third.getString("error"))
        assertEquals(1, phone.contactsRead)
    }

    @Test fun statusSaysWhatThePhoneAllows() {
        phone.canPlace = false
        askFirst = true
        val status = server.status()
        assertEquals(DialerStatus(false, true, Access.ON, Access.ON, true, phone.sims), status)
        phone.contactsAccess = Access.UNAVAILABLE
        assertEquals("no contacts, no WhatsApp rows", false, server.status().whatsApp)
        server.refresh()
        server.refresh()
        assertEquals("an unchanged status goes once", 1, sent.count { it.second == DialerKinds.STATUS })
    }
}
