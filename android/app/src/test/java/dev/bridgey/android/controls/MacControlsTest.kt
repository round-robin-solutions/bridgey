package dev.bridgey.android.controls

import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.actions.MacActionCatalog
import dev.bridgey.android.actions.MacActionEntry
import dev.bridgey.android.actions.MacVolume
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacControlsTest {
    private val work = "11111111-2222-3333-4444-555555555555"
    private val shortcut = "shortcut:3f2c9a10-1b2c-4d5e-8f90-a1b2c3d4e5f6"
    private val catalog = MacActionCatalog(
        listOf(
            MacActionEntry("lock", blocked = "permission_required"), MacActionEntry("sleep"), MacActionEntry("screensaver"),
            MacActionEntry("volume_up"), MacActionEntry("volume_set"), MacActionEntry("volume_mute"),
            MacActionEntry("app:com.apple.Safari", "Safari"), MacActionEntry(shortcut, "Focus on"),
        ),
        MacVolume(30, muted = true),
    )

    private fun mac(connected: Boolean = true, available: Set<BridgeyFeature> = BridgeyFeature.entries.toSet(), live: Boolean = true, ringing: Boolean = false) =
        ControlMac(work, "Work MacBook", connected, if (connected) available else emptySet(), catalog, live, ringing)

    @Test fun everyMacGetsItsControlsInAStableOrder() {
        val specs = controlSpecs(listOf(mac()))
        assertEquals(
            listOf("action:lock", "action:sleep", "action:screensaver", "volume", "action:volume_mute", "action:app:com.apple.Safari",
                "action:$shortcut", "ping", "find", "send"),
            specs.map { parseControlId(it.controlId)!!.second },
        )
        assertTrue(specs.all { it.deviceId == work && it.macName == "Work MacBook" })
        assertEquals("Safari", specs.first { it.label == ControlLabel.APP }.customTitle)
    }

    @Test fun statesFollowConnectionFeaturesAndPermissions() {
        val ready = controlSpecs(listOf(mac())).associateBy { parseControlId(it.controlId)!!.second }
        assertEquals(ControlState.UNAVAILABLE, ready.getValue("action:lock").state)
        assertTrue(ready.getValue("action:lock").blocked)
        assertEquals(ControlState.READY, ready.getValue("action:sleep").state)
        assertEquals(MacVolume(30, true), ready.getValue("volume").volume)
        assertTrue("Muted reads as checked", ready.getValue("action:volume_mute").checked)

        val offline = controlSpecs(listOf(mac(connected = false, live = false)))
        assertTrue(offline.all { it.state == ControlState.OFFLINE })

        val noActions = controlSpecs(listOf(mac(available = BridgeyFeature.entries.toSet() - BridgeyFeature.MAC_ACTIONS))).associateBy { parseControlId(it.controlId)!!.second }
        assertEquals(ControlState.UNAVAILABLE, noActions.getValue("action:sleep").state)
        assertEquals(ControlState.READY, noActions.getValue("ping").state)

        val stale = controlSpecs(listOf(mac(live = false))).associateBy { parseControlId(it.controlId)!!.second }
        assertEquals("A list from an earlier session cannot run", ControlState.UNAVAILABLE, stale.getValue("action:sleep").state)

        val ringing = controlSpecs(listOf(mac(ringing = true))).first { it.kind == ControlKind.FIND }
        assertTrue(ringing.checked)
    }

    @Test fun aMacWithoutAListStillHasPingFindAndSend() {
        val specs = controlSpecs(listOf(ControlMac(work, "Work MacBook", true, setOf(BridgeyFeature.PING), null, false, false)))
        assertEquals(listOf(ControlKind.PING, ControlKind.FIND, ControlKind.SEND_COPIED), specs.map { it.kind })
        assertEquals(listOf(ControlState.READY, ControlState.UNAVAILABLE, ControlState.UNAVAILABLE), specs.map { it.state })
    }

    @Test fun tapsMapToCommandsOnlyWhenReady() {
        val specs = controlSpecs(listOf(mac())).associateBy { parseControlId(it.controlId)!!.second }
        assertEquals(ControlCommand.Run(work, "sleep"), controlCommand(specs.getValue("action:sleep")))
        assertNull("Blocked", controlCommand(specs.getValue("action:lock")))
        assertEquals(ControlCommand.Run(work, "volume_set", 64), controlCommand(specs.getValue("volume"), floatValue = 64.7f))
        assertEquals(ControlCommand.Run(work, "volume_set", 100), controlCommand(specs.getValue("volume"), floatValue = 250f))
        assertNull(controlCommand(specs.getValue("volume")))
        assertEquals(ControlCommand.Run(work, "volume_mute"), controlCommand(specs.getValue("action:volume_mute"), booleanValue = false))
        assertEquals(ControlCommand.Find(work, start = true), controlCommand(specs.getValue("find"), booleanValue = true))
        assertEquals(ControlCommand.Ping(work), controlCommand(specs.getValue("ping")))
        assertNull("Send opens the clipboard reader instead", controlCommand(specs.getValue("send")))
        val offline = controlSpecs(listOf(mac(connected = false))).first { it.kind == ControlKind.PING }
        assertNull(controlCommand(offline))
    }

    @Test fun controlIdsRoundTrip() {
        assertEquals(work to "action:app:com.apple.Safari", parseControlId(controlId(work, actionElement("app:com.apple.Safari"))))
        assertNull(parseControlId("nothing"))
        assertNull(parseControlId("|ping"))
        assertNull(parseControlId("$work|"))
    }
}
