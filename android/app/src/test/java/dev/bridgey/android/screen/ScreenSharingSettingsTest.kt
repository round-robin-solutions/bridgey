package dev.bridgey.android.screen

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.SyncPermissions
import dev.bridgey.android.sync.phoneSyncedSettings
import dev.bridgey.android.ui.UiPreferences
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Share screen with Macs under unattended access: it cannot be turned on while a Mac controls the phone, and turning it
 * on from another device through settings sync is not this phone's consent to be seen without asking.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ScreenSharingSettingsTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()
    private val mac = "e2acaa6d-7980-4e5c-b5cb-9c8742216271"

    private object Granted : SyncPermissions {
        override fun notificationAccess() = true
        override fun phoneCalls() = true
        override fun camera() = true
        override fun doNotDisturb() = true
    }

    @Test
    fun itCannotBeTurnedOnWhileAMacControlsThePhone() {
        val settings = BridgeySettings(context, "Test phone")
        settings.setGlobal(BridgeyFeature.SCREEN, false)
        settings.raisingBlocked = { true }
        settings.setGlobal(BridgeyFeature.SCREEN, true)
        assertFalse(settings.state.value.globalFeatures[BridgeyFeature.SCREEN] == true)
        settings.setForDevice(mac, BridgeyFeature.SCREEN, true)
        assertFalse(settings.state.value.deviceFeatures[mac]?.get(BridgeyFeature.SCREEN) == true)
        settings.raisingBlocked = { false }
        settings.setGlobal(BridgeyFeature.SCREEN, true)
        settings.raisingBlocked = { true }
        settings.setGlobal(BridgeyFeature.SCREEN, false)
        assertFalse("turning it off always works", settings.state.value.globalFeatures[BridgeyFeature.SCREEN] == true)
    }

    @Test
    fun aSyncedOnIsMarkedAndALocalChoiceClearsIt() {
        val settings = BridgeySettings(context, "Test phone")
        settings.setGlobal(BridgeyFeature.SCREEN, false)
        val synced = phoneSyncedSettings(settings, UiPreferences(context), Granted).getValue(SyncKey.SCREEN)
        synced.write(true)
        assertTrue(settings.state.value.globalFeatures[BridgeyFeature.SCREEN] == true)
        assertTrue("on because a Mac said so", settings.screenOnBySync)
        settings.setGlobal(BridgeyFeature.SCREEN, true)
        assertFalse("turned on here", settings.screenOnBySync)
        synced.write(true)
        assertFalse("a synced on over this phone's own on changes nothing", settings.screenOnBySync)
        synced.write(false)
        synced.write(true)
        assertTrue(settings.screenOnBySync)
        synced.write(false)
        assertFalse(settings.screenOnBySync)
    }
}
