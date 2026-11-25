package dev.bridgey.android.control

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Phone control grants: off until chosen, per Mac, bound to its pinned key, never for agents, kept in a private file. */
class PhoneControlGrantsTest {
    private val dir: File = Files.createTempDirectory("grants").toFile()
    private val file = File(dir, PhoneControlGrants.FILE_NAME)
    private val mac = GrantSubject("mac-1", "key-A", agent = false)

    @Test fun everyMacStartsOff() {
        val grants = PhoneControlGrants(file)
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac))
        assertFalse(file.exists())
    }

    @Test fun aGrantIsKeptPerMacAndSurvivesARestart() {
        PhoneControlGrants(file).set(mac, PhoneControlGrantMode.ASK)
        PhoneControlGrants(file).set(GrantSubject("mac-2", "key-B", false), PhoneControlGrantMode.ALWAYS)
        val reloaded = PhoneControlGrants(file)
        assertEquals(PhoneControlGrantMode.ASK, reloaded.mode(mac))
        assertEquals(PhoneControlGrantMode.ALWAYS, reloaded.mode(GrantSubject("mac-2", "key-B", false)))
        assertEquals(PhoneControlGrantMode.OFF, reloaded.mode(GrantSubject("mac-3", "key-C", false)))
        assertFalse("the identity key itself is never stored", file.readText().contains("key-A"))
    }

    @Test fun aNewPinnedKeyHasNoGrant() {
        val grants = PhoneControlGrants(file)
        grants.set(mac, PhoneControlGrantMode.ALWAYS)
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac.copy(identityKey = "key-other")))
        assertEquals(PhoneControlGrantMode.OFF, grants.mode(mac.copy(identityKey = null)))
    }

    @Test fun agentsAndServersNeverGetOne() {
        val grants = PhoneControlGrants(file) { PhoneControlGrantMode.ALWAYS }
        val agent = GrantSubject("agent-1", "key-Z", agent = true)
        assertFalse(grants.set(agent, PhoneControlGrantMode.ALWAYS))
        assertEquals("not even through a default", PhoneControlGrantMode.OFF, grants.mode(agent))
    }

    @Test fun offRemovesTheEntryAndForgettingTheMacRemovesIt() {
        val grants = PhoneControlGrants(file)
        grants.set(mac, PhoneControlGrantMode.ASK)
        grants.set(mac, PhoneControlGrantMode.OFF)
        assertTrue(grants.granted().isEmpty())
        grants.set(mac, PhoneControlGrantMode.ALWAYS)
        grants.remove("mac-1")
        assertEquals(PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(mac))
    }

    @Test fun aLaterAllMyDevicesDefaultFitsWithoutChangingStoredGrants() {
        // The shape of a future switch: a default read for devices without an entry; explicit entries keep winning.
        var allMine = PhoneControlGrantMode.OFF
        val grants = PhoneControlGrants(file) { allMine }
        grants.set(GrantSubject("mac-2", "key-B", false), PhoneControlGrantMode.ASK)
        allMine = PhoneControlGrantMode.ALWAYS
        assertEquals(PhoneControlGrantMode.ALWAYS, grants.mode(mac))
        assertEquals(PhoneControlGrantMode.ASK, grants.mode(GrantSubject("mac-2", "key-B", false)))
    }

    @Test fun aDamagedFileGrantsNothing() {
        file.writeText("{not json")
        assertEquals(PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(mac))
        file.writeText("""{"version":1,"devices":{"mac-1":{"mode":"always","key":"short"}}}""")
        assertEquals(PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(mac))
        file.writeText("""{"version":2,"devices":{"mac-1":{"mode":"always","key":"${PhoneControlGrants.digest("key-A")}"}}}""")
        assertEquals(PhoneControlGrantMode.OFF, PhoneControlGrants(file).mode(mac))
    }

    @Test fun onlyMoreAccessCountsAsRaising() {
        assertTrue(PhoneControlGrantMode.OFF.raises(PhoneControlGrantMode.ASK))
        assertTrue(PhoneControlGrantMode.ASK.raises(PhoneControlGrantMode.ALWAYS))
        assertFalse(PhoneControlGrantMode.ALWAYS.raises(PhoneControlGrantMode.ASK))
        assertFalse(PhoneControlGrantMode.ASK.raises(PhoneControlGrantMode.OFF))
        assertFalse(PhoneControlGrantMode.ASK.raises(PhoneControlGrantMode.ASK))
    }
}
