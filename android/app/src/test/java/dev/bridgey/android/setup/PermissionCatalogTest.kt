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
    ) = PermissionFacts(sdk, lab, granted, notifications, calls, screenshot, background, media)

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
    fun companionLinkIsOnlyOnAndroid15AndLater() {
        assertEquals(PermissionState.NOT_ON_THIS_DEVICE, states(facts(sdk = 34))[PermissionKind.COMPANION_LINK])
        assertEquals(PermissionState.NOT_ON_THIS_DEVICE, states(facts(sdk = 34, granted = setOf(PermissionKind.COMPANION_LINK)))[PermissionKind.COMPANION_LINK])
        assertEquals(PermissionState.NOT_ALLOWED, states(facts(sdk = 35))[PermissionKind.COMPANION_LINK])
    }

    @Test
    fun smsIsListedOnlyInLabBuilds() {
        assertFalse(PermissionKind.SMS in states(facts(lab = false)))
        assertEquals(PermissionState.NOT_NEEDED_YET, states(facts(lab = true))[PermissionKind.SMS])
        assertEquals(PermissionState.ALLOWED, states(facts(lab = true, granted = setOf(PermissionKind.SMS)))[PermissionKind.SMS])
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
