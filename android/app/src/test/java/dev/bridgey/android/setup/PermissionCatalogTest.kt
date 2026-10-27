package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PermissionCatalogTest {
    private fun facts(
        sdk: Int = 35,
        lab: Boolean = false,
        granted: Set<PermissionKind> = emptySet(),
        notifications: Boolean = true,
        calls: Boolean = true,
        screenshot: Boolean = true,
        background: Boolean = false,
        media: Boolean = false,
        camera: Boolean = true,
        focusFollow: Boolean = true,
        sms: Boolean = false,
        dualSim: Boolean = false,
    ) = PermissionFacts(sdk, lab, granted, notifications, calls, screenshot, background, media, camera, focusFollow, sms, dualSim)

    private fun states(facts: PermissionFacts) = PermissionCatalog.entries(facts).associate { it.kind to it.state }

    @Test
    fun everythingAllowed() {
        val all = states(facts(lab = true, granted = PermissionKind.entries.toSet()))
        assertEquals(PermissionKind.entries.toSet(), all.keys)
        assertTrue(all.values.all { it == PermissionState.ALLOWED })
    }

    @Test
    fun nothingAllowedWithEveryFeatureOn() {
        val none = states(facts(background = true))
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.NOTIFICATION_ACCESS])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.POST_NOTIFICATIONS])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.PHONE_CALLS])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.PHOTOS])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.COMPANION_LINK])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.BATTERY])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.INSTALL_PACKAGES])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.LOGS])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.CAMERA])
        assertEquals(PermissionState.NOT_ALLOWED, none[PermissionKind.DO_NOT_DISTURB])
    }

    @Test
    fun featureOffMeansNotNeededYet() {
        val off = states(facts(notifications = false, calls = false, screenshot = false, background = false))
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.NOTIFICATION_ACCESS])
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.COMPANION_LINK])
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.PHONE_CALLS])
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.PHOTOS])
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.LOGS])
        // Granted still reads Allowed when the feature is off.
        assertEquals(PermissionState.ALLOWED, states(facts(calls = false, granted = setOf(PermissionKind.PHONE_CALLS)))[PermissionKind.PHONE_CALLS])
    }

    @Test
    fun photosAreNeededForFiles2EvenWithFreshScreenshotsOff() {
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(screenshot = false, media = true))[PermissionKind.PHOTOS])
        assertEquals(PermissionState.NOT_NEEDED_YET, states(facts(screenshot = false, media = false))[PermissionKind.PHOTOS])
        assertEquals(PermissionState.ALLOWED, states(facts(screenshot = false, media = true, granted = setOf(PermissionKind.PHOTOS)))[PermissionKind.PHOTOS])
    }

    @Test
    fun cameraFollowsTakePhotosForTheMacAndDoNotDisturbFollowsTheMacsFocus() {
        val off = states(facts(camera = false, focusFollow = false))
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.CAMERA])
        assertEquals(PermissionState.NOT_NEEDED_YET, off[PermissionKind.DO_NOT_DISTURB])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(camera = true))[PermissionKind.CAMERA])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(focusFollow = true))[PermissionKind.DO_NOT_DISTURB])
        val granted = states(facts(camera = false, focusFollow = false, granted = setOf(PermissionKind.CAMERA, PermissionKind.DO_NOT_DISTURB)))
        assertEquals(PermissionState.ALLOWED, granted[PermissionKind.CAMERA])
        assertEquals(PermissionState.ALLOWED, granted[PermissionKind.DO_NOT_DISTURB])
        // The camera sits after Photos and videos, Do Not Disturb after the companion link.
        val order = PermissionKind.entries
        assertEquals(order.indexOf(PermissionKind.PHOTOS) + 1, order.indexOf(PermissionKind.CAMERA))
        assertEquals(order.indexOf(PermissionKind.COMPANION_LINK) + 1, order.indexOf(PermissionKind.DO_NOT_DISTURB))
    }

    @Test
    fun companionLinkIsOnlyOnAndroid15AndLater() {
        assertEquals(PermissionState.NOT_ON_THIS_DEVICE, states(facts(sdk = 34))[PermissionKind.COMPANION_LINK])
        assertEquals(PermissionState.NOT_ON_THIS_DEVICE, states(facts(sdk = 34, granted = setOf(PermissionKind.COMPANION_LINK)))[PermissionKind.COMPANION_LINK])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(sdk = 35))[PermissionKind.COMPANION_LINK])
    }

    /** Text messages: SMS and Contacts are listed in every build and needed only while it is on. */
    @Test
    fun smsAndContactsFollowTextMessages() {
        assertEquals(PermissionState.NOT_NEEDED_YET, states(facts(lab = false))[PermissionKind.SMS])
        assertEquals(PermissionState.NOT_NEEDED_YET, states(facts(lab = false))[PermissionKind.CONTACTS])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(sms = true))[PermissionKind.SMS])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(sms = true))[PermissionKind.CONTACTS])
        assertEquals(PermissionState.ALLOWED, states(facts(sms = true, granted = setOf(PermissionKind.SMS)))[PermissionKind.SMS])
        // Phone and calls lists the SIMs of a dual-SIM phone for Text messages.
        assertEquals(PermissionState.NOT_NEEDED_YET, states(facts(calls = false, sms = true))[PermissionKind.PHONE_CALLS])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(calls = false, sms = true, dualSim = true))[PermissionKind.PHONE_CALLS])
    }

    @Test
    fun listKeepsTheCatalogOrder() {
        assertEquals(PermissionKind.entries.toList(), PermissionCatalog.entries(facts(lab = true)).map { it.kind })
        assertTrue(PermissionCatalog.entries(facts()).first { it.kind == PermissionKind.BATTERY }.offersRequest)
        assertFalse(PermissionEntry(PermissionKind.BATTERY, PermissionState.ALLOWED).offersRequest)
        assertEquals(null, PermissionCatalog.forStep(QuickStep.PAIR))
        assertEquals(PermissionKind.BATTERY, PermissionCatalog.forStep(QuickStep.BATTERY))
    }
}
