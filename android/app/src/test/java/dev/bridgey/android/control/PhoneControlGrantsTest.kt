package dev.bridgey.android.control

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phone control grants: Unattended access on by default, a Mac on Default follows it, a Mac's own choice wins, bound to
 * its pinned key, never for agents, kept in a private file.
 */
class PhoneControlGrantsTest {
    private val dir: File = Files.createTempDirectory("grants").toFile()
    private val file = File(dir, PhoneControlGrants.FILE_NAME)
    private val mac = GrantSubject("mac-1", "key-A", agent = false)
    private val other = GrantSubject("mac-2", "key-B", agent = false)

    @Test fun unattendedAccessIsOnByDefaultAndAMacOnDefaultFollowsIt() {
        val grants = PhoneControlGrants(file)
        assertTrue(grants.unattended)
        assertNull(grants.choice(mac))
        assertEquals(PhoneControlGrantMode.ALWAYS, grants.mode(mac))
        assertFalse("nothing is written until something changes", file.exists())
        grants.setUnattended(false)
        assertEquals("off means the old default", PhoneControlGrantMode.OFF, grants.mode(mac))
        assertFalse(PhoneControlGrants(file).unattended)
    }

    @Test fun theResolutionTable() {
        val modes = listOf(null) + PhoneControlGrantMode.entries
        for (switch in listOf(true, false)) for (choice in modes) {
            val expected = choice ?: if (switch) PhoneControlGrantMode.ALWAYS else PhoneControlGrantMode.OFF
            assertEquals("switch=$switch choice=$choice", expected, PhoneControlGrants.resolve(choice, switch, agent = false, keyKnown = true))
            assertEquals("an agent, switch=$switch choice=$choice", PhoneControlGrantMode.OFF, PhoneControlGrants.resolve(choice, switch, agent = true, keyKnown = true))
            assertEquals("no pinned key, switch=$switch choice=$choice", PhoneControlGrantMode.OFF, PhoneControlGrants.resolve(choice, switch, agent = false, keyKnown = false))
        }
    }

    @Test fun aChoiceIsKeptPerMacSurvivesARestartAndIgnoresTheSwitch() {
        PhoneControlGrants(file).set(mac, PhoneControlGrantMode.ASK)
        PhoneControlGrants(file).set(other, PhoneControlGrantMode.OFF)
        val reloaded = PhoneControlGrants(file)
        assertEquals(PhoneControlGrantMode.ASK, reloaded.mode(mac))
        assertEquals("an explicit Off stays Off with the switch on", PhoneControlGrantMode.OFF, reloaded.mode(other))
        assertEquals(PhoneControlGrantMode.OFF, reloaded.choice(other))
        assertEquals(PhoneControlGrantMode.ALWAYS, reloaded.mode(GrantSubject("mac-3", "key-C", false)))
        reloaded.setUnattended(false)
        assertEquals(PhoneControlGrantMode.ASK, PhoneControlGrants(file).mode(mac))
        assertEquals(PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(GrantSubject("mac-3", "key-C", false)))
        reloaded.set(other, PhoneControlGrantMode.ALWAYS)
        assertEquals("an explicit Allow stays with the switch off", PhoneControlGrantMode.ALWAYS, PhoneControlGrants(file).mode(other))
        assertFalse("the identity key itself is never stored", file.readText().contains("key-A"))
    }

    @Test fun defaultRemovesTheChoice() {
        val grants = PhoneControlGrants(file)
        grants.set(mac, PhoneControlGrantMode.OFF)
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac))
        grants.set(mac, null)
        assertNull(grants.choice(mac))
        assertEquals(PhoneControlGrantMode.ALWAYS, grants.mode(mac))
        assertTrue(grants.granted().isEmpty())
    }

    @Test fun aChoiceMadeForAnotherKeyIsDefault() {
        val grants = PhoneControlGrants(file)
        grants.set(mac, PhoneControlGrantMode.OFF)
        assertNull(grants.choice(mac.copy(identityKey = "key-other")))
        assertEquals("paired again with a new key: like a new Mac", PhoneControlGrantMode.ALWAYS, grants.mode(mac.copy(identityKey = "key-other")))
        grants.setUnattended(false)
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac.copy(identityKey = "key-other")))
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac.copy(identityKey = null)))
    }

    @Test fun agentsAndServersNeverGetOne() {
        val grants = PhoneControlGrants(file)
        val agent = GrantSubject("agent-1", "key-Z", agent = true)
        assertTrue(grants.unattended)
        assertFalse(grants.set(agent, PhoneControlGrantMode.ALWAYS))
        assertEquals("not even through the switch", PhoneControlGrantMode.OFF, grants.mode(agent))
        // A device marked an agent after a choice was stored for it still gets nothing.
        grants.set(mac, PhoneControlGrantMode.ALWAYS)
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac.copy(agent = true)))
    }

    @Test fun forgettingTheMacRemovesItsChoice() {
        val grants = PhoneControlGrants(file)
        grants.set(mac, PhoneControlGrantMode.OFF)
        grants.remove("mac-1")
        assertNull(PhoneControlGrants(file).choice(mac))
    }

    @Test fun theSwitchAndChoicesAreWrittenToThePrivateFile() {
        val grants = PhoneControlGrants(file)
        grants.set(mac, PhoneControlGrantMode.OFF)
        grants.setUnattended(false)
        val json = JSONObject(file.readText())
        assertEquals(1, json.getInt("version"))
        assertFalse(json.getBoolean("unattended"))
        assertEquals("off", json.getJSONObject("devices").getJSONObject("mac-1").getString("mode"))
        assertEquals(PhoneControlGrants.digest("key-A"), json.getJSONObject("devices").getJSONObject("mac-1").getString("key"))
    }

    @Test fun aDamagedFileFailsClosed() {
        val id = "5d1c8e0a-3b7f-4c2d-9e6a-1f0b2c3d4e5f"
        val macWithId = GrantSubject(id, "key-A", agent = false)
        file.writeText("""{"version":1,"unattended":true,"devices":{"$id":{"mode":"off","key":"${PhoneControlGrants.digest("key-A")}"}""")
        PhoneControlGrants(file).let {
            assertFalse("an unreadable file never turns the switch on", it.unattended)
            assertEquals(PhoneControlGrantMode.OFF, it.mode(macWithId))
            assertEquals(PhoneControlGrantMode.OFF, it.mode(mac))
            // Turning the switch back on does not give the lost Off away: the IDs the file still names stay Off.
            it.setUnattended(true)
            assertEquals(PhoneControlGrantMode.OFF, it.mode(macWithId))
            assertEquals(PhoneControlGrantMode.OFF, it.mode(macWithId.copy(identityKey = "key-other")))
            assertEquals("a device the file did not name follows the switch", PhoneControlGrantMode.ALWAYS, it.mode(mac))
        }
        assertEquals("and that is written back", PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(macWithId))
        file.writeText("""{"version":2,"unattended":true,"devices":{"$id":{"mode":"always","key":"${PhoneControlGrants.digest("key-A")}"}}}""")
        PhoneControlGrants(file).let {
            assertFalse(it.unattended)
            assertEquals(PhoneControlGrantMode.OFF, it.mode(macWithId))
        }
    }

    @Test fun aBadEntryIsOffForThatMacNeverDefault() {
        file.writeText("""{"version":1,"devices":{"mac-1":{"mode":"always","key":"short"},"mac-2":{"mode":"sometimes","key":"${PhoneControlGrants.digest("key-B")}"},"mac-3":"always"}}""")
        val grants = PhoneControlGrants(file)
        assertTrue("the switch itself is fine", grants.unattended)
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac))
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac.copy(identityKey = "key-other")))
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(other))
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(GrantSubject("mac-3", "key-C", false)))
        assertEquals(PhoneControlGrantMode.ALWAYS, grants.mode(GrantSubject("mac-4", "key-D", false)))
        grants.setUnattended(true)
        assertEquals("kept as Off through a save", PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(mac))
        grants.set(mac, null)
        assertEquals("choosing Default is the person's own choice", PhoneControlGrantMode.ALWAYS, grants.mode(mac))
    }

    @Test fun aSwitchThatIsNotABooleanReadsOff() {
        file.writeText("""{"version":1,"unattended":"yes","devices":{}}""")
        assertFalse(PhoneControlGrants(file).unattended)
        file.writeText("""{"version":1,"unattended":null,"devices":{}}""")
        assertFalse("null is not on", PhoneControlGrants(file).unattended)
        file.writeText("""{"version":1,"devices":{}}""")
        assertTrue("missing is on (files from before the switch)", PhoneControlGrants(file).unattended)
    }

    @Test fun onlyMoreAccessCountsAsRaising() {
        assertTrue(PhoneControlGrantMode.OFF.raises(PhoneControlGrantMode.ASK))
        assertTrue(PhoneControlGrantMode.ASK.raises(PhoneControlGrantMode.ALWAYS))
        assertFalse(PhoneControlGrantMode.ALWAYS.raises(PhoneControlGrantMode.ASK))
        assertFalse(PhoneControlGrantMode.ASK.raises(PhoneControlGrantMode.OFF))
        assertFalse(PhoneControlGrantMode.ASK.raises(PhoneControlGrantMode.ASK))
    }
}
