package dev.bridgey.android.focus

import android.app.NotificationManager
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A fake Do Not Disturb: nothing here touches the phone's real one. */
private class FakeQuiet(var active: Boolean = false, var access: Boolean = true) : QuietMode {
    val sets = mutableListOf<Boolean>()
    override fun isActive() = active
    override fun canChange() = access
    override fun set(active: Boolean): Boolean {
        sets += active
        this.active = active
        return true
    }
}

class FocusSyncTest {
    private var now = 1_000_000L
    private var share = false
    private var follow = false
    private val peers = mutableListOf("mac-a")
    private val sent = mutableListOf<Pair<String, Boolean>>()
    private val quiet = FakeQuiet()
    private val sync = FocusSync(quiet, { now }, { share }, { follow }, { peers }, { id, active -> sent += id to active; true })

    @Test fun interruptionFiltersOtherThanAllAreQuiet() {
        assertFalse(interruptionFilterIsQuiet(NotificationManager.INTERRUPTION_FILTER_ALL))
        assertFalse(interruptionFilterIsQuiet(NotificationManager.INTERRUPTION_FILTER_UNKNOWN))
        assertTrue(interruptionFilterIsQuiet(NotificationManager.INTERRUPTION_FILTER_PRIORITY))
        assertTrue(interruptionFilterIsQuiet(NotificationManager.INTERRUPTION_FILTER_ALARMS))
        assertTrue(interruptionFilterIsQuiet(NotificationManager.INTERRUPTION_FILTER_NONE))
    }

    @Test fun payloadIsStrict() {
        assertEquals(true, parseFocusState(JSONObject("""{"version":1,"active":true}""")))
        assertEquals(false, parseFocusState(focusStatePayload(false)))
        assertNull(parseFocusState(JSONObject("""{"version":2,"active":true}""")))
        assertNull(parseFocusState(JSONObject("""{"version":1,"active":"yes"}""")))
        assertNull(parseFocusState(JSONObject("""{"version":1}""")))
    }

    @Test fun advertisedWhileEitherDirectionIsOn() {
        assertFalse(sync.advertised())
        share = true
        assertTrue(sync.advertised())
        share = false; follow = true
        assertTrue(sync.advertised())
    }

    @Test fun nothingIsSentOrAppliedWhileTheSwitchesAreOff() {
        quiet.active = true
        sync.localChanged()
        sync.peerReady("mac-a")
        assertTrue(sent.isEmpty())
        assertEquals(FocusApply.IGNORED, sync.remote("mac-a", true))
        assertTrue(quiet.sets.isEmpty())
    }

    @Test fun sharingSendsOnceReadyAndOnEachRealChange() {
        share = true
        sync.peerReady("mac-a")
        assertEquals(listOf("mac-a" to false), sent)
        quiet.active = true
        sync.localChanged()
        // Priority to alarms only is still "active": no second message.
        sync.localChanged()
        assertEquals(listOf("mac-a" to false, "mac-a" to true), sent)
    }

    @Test fun onlyPeersWithTheKeyHearIt() {
        share = true
        peers.clear()
        quiet.active = true
        sync.localChanged()
        assertTrue(sent.isEmpty())
    }

    @Test fun followTurnsOnAndHandsBackItsOwnDoNotDisturb() {
        follow = true
        assertEquals(FocusApply.TURNED_ON, sync.remote("mac-a", true))
        assertTrue(quiet.active)
        assertTrue(sync.ownsQuiet)
        assertEquals(FocusApply.TURNED_OFF, sync.remote("mac-a", false))
        assertFalse(quiet.active)
        assertEquals(listOf(true, false), quiet.sets)
    }

    @Test fun neverTurnsOffDoNotDisturbThePersonTurnedOn() {
        follow = true
        quiet.active = true
        assertEquals(FocusApply.NO_CHANGE, sync.remote("mac-a", true))
        assertEquals(FocusApply.NO_CHANGE, sync.remote("mac-a", false))
        assertTrue(quiet.active)
        assertTrue(quiet.sets.isEmpty())
    }

    @Test fun thePersonTurningItOffMakesItTheirs() {
        follow = true
        sync.remote("mac-a", true)
        now += FOCUS_ECHO_WINDOW_MILLIS + 1
        quiet.active = false
        sync.localChanged()
        assertFalse(sync.ownsQuiet)
        // The person then turns it on again themselves; the Mac's Focus ending leaves it alone.
        quiet.active = true
        assertEquals(FocusApply.NO_CHANGE, sync.remote("mac-a", false))
        assertTrue(quiet.active)
    }

    @Test fun aMacThatDidNotAdvertiseFocusSyncIsNotFollowed() {
        follow = true
        assertEquals(FocusApply.IGNORED, sync.remote("mac-b", true))
        assertTrue(quiet.sets.isEmpty())
        peers += "mac-b"
        assertEquals(FocusApply.TURNED_ON, sync.remote("mac-b", true))
    }

    @Test fun anyFollowedMacKeepsItOn() {
        follow = true
        peers += "mac-b"
        sync.remote("mac-a", true)
        sync.remote("mac-b", true)
        assertEquals(FocusApply.NO_CHANGE, sync.remote("mac-a", false))
        assertTrue(quiet.active)
        assertEquals(FocusApply.TURNED_OFF, sync.remote("mac-b", false))
    }

    @Test fun theChangeFollowedIsNotEchoedForTenSeconds() {
        share = true
        follow = true
        sync.peerReady("mac-a")
        sent.clear()
        sync.remote("mac-a", true)
        sync.localChanged()
        assertTrue("its own change goes back within 10 s", sent.isEmpty())
        // Turned off later: the Mac last heard "off", so nothing to say. Turned on by the person: shared.
        now += FOCUS_ECHO_WINDOW_MILLIS + 1
        quiet.active = false
        sync.localChanged()
        assertTrue(sent.isEmpty())
        quiet.active = true
        sync.localChanged()
        assertEquals(listOf("mac-a" to true), sent)
    }

    @Test fun withoutAccessNothingChanges() {
        follow = true
        quiet.access = false
        assertEquals(FocusApply.NEEDS_ACCESS, sync.remote("mac-a", true))
        assertFalse(quiet.active)
        assertTrue(quiet.sets.isEmpty())
    }

    @Test fun turningFollowOffHandsBack() {
        follow = true
        sync.remote("mac-a", true)
        follow = false
        assertEquals(FocusApply.TURNED_OFF, sync.followChanged())
        assertFalse(quiet.active)
    }

    @Test fun forgettingTheOnlyFocusedMacHandsBack() {
        follow = true
        sync.remote("mac-a", true)
        assertEquals(FocusApply.TURNED_OFF, sync.forget("mac-a"))
    }

    @Test fun aNewSessionHearsTheStateAgain() {
        share = true
        quiet.active = true
        sync.peerReady("mac-a")
        sync.sessionEnded("mac-a")
        sync.localChanged()
        assertEquals(listOf("mac-a" to true, "mac-a" to true), sent)
    }
}
