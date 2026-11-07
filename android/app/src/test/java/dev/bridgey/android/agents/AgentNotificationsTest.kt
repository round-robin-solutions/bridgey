package dev.bridgey.android.agents

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AgentNotificationsTest {
    private val id = "00000000-0000-4000-8000-000000000001"
    private fun query(limit: Any = 20) = JSONObject().put("version", 1).put("queryId", id).put("limit", limit).toString().toByteArray()

    @Test fun requestsAreStrictBoundedAndReadOnly() {
        assertEquals(20, decodeAgentNotificationsQuery(query())!!.limit)
        assertEquals(1, decodeAgentNotificationsQuery(query(1))!!.limit)
        for (limit in listOf(0, 21, -1, 1.5, "20", JSONObject.NULL)) assertNull(decodeAgentNotificationsQuery(query(limit)))
        assertNull(decodeAgentNotificationsQuery(query().toString(Charsets.UTF_8).replace(id, "not-an-id").toByteArray()))
        assertNull(decodeAgentNotificationsQuery(query() + ByteArray(1_025)))
        assertTrue(agentMaySend(AgentKinds.NOTIFICATIONS_QUERY))
        assertTrue(phoneMaySendToAgent(AgentKinds.NOTIFICATIONS_RESULT))
        assertFalse(phoneMaySendToAgent("notifications.post"))
        assertFalse(agentMaySend("notifications.dismiss"))
        assertFalse(agentMaySend("notifications.action"))
    }

    @Test fun allTenGrantsCanBeRequestedButRemainOff() {
        val request = JSONObject().put("version", 1).put("requestId", id)
            .put("keys", org.json.JSONArray(AgentGrant.entries.map { it.key }))
        assertEquals(AgentGrant.entries.toList(), decodeGrantRequest(request.toString().toByteArray())!!.grants)
        request.getJSONArray("keys").put("notifications")
        assertNull(decodeGrantRequest(request.toString().toByteArray()))
    }

    private fun item(index: Int, text: String = "Synthetic fixture") = AgentNotification("id-$index", "example.app", "Example", "Title", text, 1)

    @Test fun unicodeAndEscapingCannotExceedEncryptedFrameBudget() {
        val source = (1..20).map { item(it, "😀\"\n".repeat(2_000)) }
        val bytes = agentNotificationsResultPayload(id, AgentNotificationsSnapshot(true, source), 20)
        assertTrue(bytes.size <= AGENT_NOTIFICATIONS_MAX_BYTES)
        val result = JSONObject(bytes.toString(Charsets.UTF_8))
        assertTrue(result.getBoolean("truncated"))
        assertEquals("ok", result.getString("status"))
        assertTrue(result.getJSONArray("notifications").length() > 0)
    }

    @Test fun deniedSourceNeverCarriesContentAndLimitIsHonest() {
        val source = (1..4).map { item(it) }
        val unavailable = JSONObject(agentNotificationsResultPayload(id, AgentNotificationsSnapshot(false, source), 20).toString(Charsets.UTF_8))
        assertEquals("unavailable", unavailable.getString("status"))
        assertEquals(0, unavailable.getJSONArray("notifications").length())
        val limited = JSONObject(agentNotificationsResultPayload(id, AgentNotificationsSnapshot(true, source), 2).toString(Charsets.UTF_8))
        assertEquals(2, limited.getJSONArray("notifications").length())
        assertTrue(limited.getBoolean("truncated"))
    }
}
