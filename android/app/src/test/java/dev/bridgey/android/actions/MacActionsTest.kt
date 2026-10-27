package dev.bridgey.android.actions

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MAC = "11111111-2222-3333-4444-555555555555"
private const val OTHER = "99999999-2222-3333-4444-555555555555"
private const val SHORTCUT = "shortcut:3f2c9a10-1b2c-4d5e-8f90-a1b2c3d4e5f6"

private class FakeTimer : ActionTimer {
    class Task(val delay: Long, val block: () -> Unit) { var cancelled = false }
    val tasks = mutableListOf<Task>()
    override fun schedule(delayMillis: Long, block: () -> Unit): () -> Unit {
        val task = Task(delayMillis, block)
        tasks += task
        return { task.cancelled = true }
    }
    fun fireAll() = tasks.filter { !it.cancelled }.forEach { it.cancelled = true; it.block() }
}

private fun entry(id: String, title: String? = null, blocked: String? = null) = JSONObject().put("id", id).apply {
    title?.let { put("title", it) }
    blocked?.let { put("blocked", it) }
}

private fun catalog(vararg entries: JSONObject, volume: JSONObject? = JSONObject().put("level", 40).put("muted", false)) =
    JSONObject().put("version", 1).put("actions", JSONArray(entries.toList())).apply { volume?.let { put("volume", it) } }

class MacActionsTest {
    private val sent = mutableListOf<Triple<String, String, JSONObject>>()
    private val timer = FakeTimer()
    private var available = true
    private var sendWorks = true
    private var ids = 0
    private val store = MemoryCatalogStore()
    private val client = MacActionsClient(
        store = store,
        timer = timer,
        available = { available },
        send = { device, kind, payload -> sent += Triple(device, kind, payload); sendWorks },
        newRequestId = { "00000000-0000-4000-8000-00000000000${ids++}" },
    )

    private fun loadCatalog(device: String = MAC) = client.receive(
        device, "actions.catalog",
        catalog(entry("lock", blocked = "permission_required"), entry("sleep"), entry("volume_set"), entry("volume_mute"),
            entry("app:com.apple.Safari", "Safari"), entry(SHORTCUT, "Focus on")),
    )

    private fun result(requestId: String, action: String, status: String, reason: String? = null, volume: JSONObject? = null) =
        JSONObject().put("version", 1).put("requestId", requestId).put("action", action).put("status", status).apply {
            reason?.let { put("reason", it) }
            volume?.let { put("volume", it) }
        }

    @Test fun catalogKeepsOnlyAllowedIdentifiersAndValidTitles() {
        val parsed = parseMacActionCatalog(
            catalog(
                entry("lock"), entry("lock"), entry("shell"), entry("app:"), entry("app:com.evil;rm -rf"), entry("app:com.apple.Safari"),
                entry("app:com.apple.Notes", "Notes"), entry("app:com.apple.Mail", "x".repeat(65)), entry("app:com.apple.Maps", "Maps\nnow"),
                entry("shortcut:not-a-uuid", "Bad"), entry(SHORTCUT.uppercase(), "Upper"), entry(SHORTCUT, "Focus on"),
                entry("volume_set", blocked = "something"), JSONObject().put("id", 7), entry("app:com.apple.Music", "  "),
            ),
        )!!
        assertEquals(listOf("lock", "app:com.apple.Notes", SHORTCUT, "volume_set"), parsed.entries.map { it.id })
        assertNull(parsed.entry("volume_set")!!.blocked)
        assertEquals(MacVolume(40, false), parsed.volume)
        assertEquals("Focus on", parsed.entry(SHORTCUT)!!.title)
        assertNull("System entries never carry a title", parsed.entry("lock")!!.title)
    }

    @Test fun malformedCatalogsAreRejectedWhole() {
        assertNull(parseMacActionCatalog(JSONObject().put("version", 2).put("actions", JSONArray())))
        assertNull(parseMacActionCatalog(JSONObject().put("version", 1)))
        assertNull(parseMacActionCatalog(JSONObject().put("version", 1).put("actions", "lock")))
        val tooMany = JSONArray((0..64).map { entry("app:com.example.a$it", "App $it") })
        assertNull(parseMacActionCatalog(JSONObject().put("version", 1).put("actions", tooMany)))
        val atLimit = JSONArray((0 until 64).map { entry("app:com.example.a$it", "App $it") })
        assertEquals(64, parseMacActionCatalog(JSONObject().put("version", 1).put("actions", atLimit))!!.entries.size)
    }

    @Test fun badVolumeIsDroppedButTheCatalogStays() {
        listOf(JSONObject().put("level", 101).put("muted", false), JSONObject().put("level", "40").put("muted", false),
            JSONObject().put("level", 40)).forEach { volume ->
            val parsed = parseMacActionCatalog(catalog(entry("volume_up"), volume = volume))!!
            assertNull(parsed.volume)
            assertTrue(parsed.has("volume_up"))
        }
    }

    @Test fun runSendsOnlyIdentifiersFromTheLiveCatalog() {
        assertFalse("No catalog yet", client.run(MAC, "lock"))
        assertTrue(sent.isEmpty())
        assertEquals(MacActionOutcome.NOT_SENT, client.status.value!!.outcome)
        loadCatalog()
        assertFalse("Not in the list", client.run(MAC, "screensaver"))
        assertFalse("Unknown", client.run(MAC, "app:com.apple.Terminal"))
        assertTrue(sent.isEmpty())
        assertTrue(client.run(MAC, "app:com.apple.Safari"))
        val (device, kind, payload) = sent.single()
        assertEquals(MAC, device)
        assertEquals("actions.run", kind)
        assertEquals(1, payload.getInt("version"))
        assertEquals("app:com.apple.Safari", payload.getString("action"))
        assertFalse("No value for anything but volume_set", payload.has("value"))
        assertEquals(1L, payload.getLong("sequence"))
        assertEquals(setOf(MAC to "app:com.apple.Safari"), client.running.value)
    }

    @Test fun volumeSetNeedsAnIntegerInRangeAndOthersTakeNoValue() {
        loadCatalog()
        assertFalse(client.run(MAC, "volume_set"))
        assertFalse(client.run(MAC, "volume_set", 101))
        assertFalse(client.run(MAC, "volume_set", -1))
        assertFalse(client.run(MAC, "sleep", 3))
        assertTrue(client.run(MAC, "volume_set", 55))
        assertEquals(55, sent.single().third.getInt("value"))
    }

    @Test fun sequenceIncreasesAndOnePendingRunPerAction() {
        loadCatalog()
        assertTrue(client.run(MAC, "sleep"))
        assertFalse("Already waiting", client.run(MAC, "sleep"))
        assertTrue(client.run(MAC, "volume_mute"))
        assertEquals(listOf(1L, 2L), sent.map { it.third.getLong("sequence") })
        assertTrue(sent.map { it.third.getString("requestId") }.toSet().size == 2)
    }

    @Test fun resultsMatchRequestDeviceAndActionAndUpdateVolume() {
        loadCatalog()
        client.run(MAC, "volume_mute")
        val id = sent.single().third.getString("requestId")
        client.receive(OTHER, "actions.result", result(id, "volume_mute", "done"))
        client.receive(MAC, "actions.result", result(id, "sleep", "done"))
        client.receive(MAC, "actions.result", result("00000000-0000-4000-8000-000000000099", "volume_mute", "done"))
        client.receive(MAC, "actions.result", result(id, "volume_mute", "maybe"))
        assertEquals(MacActionOutcome.RUNNING, client.status.value!!.outcome)
        client.receive(MAC, "actions.result", result(id, "volume_mute", "done", volume = JSONObject().put("level", 40).put("muted", true)))
        assertEquals(MacActionOutcome.DONE, client.status.value!!.outcome)
        assertTrue(client.running.value.isEmpty())
        assertEquals(MacVolume(40, true), client.catalogs.value[MAC]!!.volume)
        assertEquals("Persisted for controls", MacVolume(40, true), store.saved[MAC]!!.volume)
        assertTrue("The timeout was cancelled", timer.tasks.single().cancelled)
    }

    @Test fun refusalsCarryAKnownReason() {
        loadCatalog()
        client.run(MAC, "lock")
        client.receive(MAC, "actions.result", result(sent.last().third.getString("requestId"), "lock", "refused", "permission_required"))
        assertEquals(MacActionStatus(MAC, "lock", MacActionOutcome.REFUSED, "permission_required", client.status.value!!.serial), client.status.value)
        client.run(MAC, "lock")
        client.receive(MAC, "actions.result", result(sent.last().third.getString("requestId"), "lock", "refused", "<script>"))
        assertEquals("failed", client.status.value!!.reason)
    }

    @Test fun timeoutsAreTenSecondsAndSeventyForShortcuts() {
        loadCatalog()
        client.run(MAC, "sleep")
        client.run(MAC, SHORTCUT)
        assertEquals(listOf(10_000L, 70_000L), timer.tasks.map { it.delay })
        timer.fireAll()
        assertEquals(MacActionOutcome.NOT_CONFIRMED, client.status.value!!.outcome)
        assertTrue(client.running.value.isEmpty())
        // A late result after the timeout changes nothing.
        client.receive(MAC, "actions.result", result(sent.first().third.getString("requestId"), "sleep", "done"))
        assertEquals(MacActionOutcome.NOT_CONFIRMED, client.status.value!!.outcome)
    }

    @Test fun aFailedSendIsReportedAndNotLeftPending() {
        loadCatalog()
        sendWorks = false
        assertFalse(client.run(MAC, "sleep"))
        assertEquals(MacActionOutcome.NOT_SENT, client.status.value!!.outcome)
        assertTrue(client.running.value.isEmpty())
    }

    @Test fun catalogsAreIgnoredWhileUnavailableAndRevocationForgetsThem() {
        available = false
        loadCatalog()
        assertNull(client.catalogs.value[MAC])
        available = true
        loadCatalog()
        assertNotNull(client.usableCatalog(MAC))
        client.revoked(MAC)
        assertNull(client.catalogs.value[MAC])
        assertNull(store.saved[MAC])
    }

    @Test fun sessionEndKeepsTheCatalogForOfflineDisplayButStopsRuns() {
        loadCatalog()
        client.run(MAC, "sleep")
        client.sessionEnded(MAC)
        assertEquals(MacActionOutcome.NOT_CONFIRMED, client.status.value!!.outcome)
        assertNotNull(client.catalogs.value[MAC])
        assertNull(client.usableCatalog(MAC))
        assertFalse(client.run(MAC, "sleep"))
        // A new client (app restart) loads the last catalog from the store.
        val restarted = MacActionsClient(store, timer, { true }, { _, _, _ -> true })
        assertTrue(restarted.catalogs.value[MAC]!!.has("sleep"))
        assertNull("Not live until the Mac sends it again", restarted.usableCatalog(MAC))
    }
}
