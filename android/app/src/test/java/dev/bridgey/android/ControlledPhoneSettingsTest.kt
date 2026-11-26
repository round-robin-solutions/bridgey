package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Security review 1.0: a Mac controlling this phone could open Bridgey's settings and turn on Let other devices browse
 * this phone, Allow other devices to change files here or Let paired devices start updates, which never sync precisely
 * so that only the person here decides. While control runs they cannot be turned on; turning them off still works.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class ControlledPhoneSettingsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun aControllingMacCannotOpenThePhoneToItself() {
        val settings = BridgeySettings(context, "Phone")
        settings.setUpdatesRemoteStart(false)
        settings.setAllowBrowseFromOtherDevices(false)
        settings.setAllowReplaceFromOtherDevices(false)
        var controlled = true
        settings.raisingBlocked = { controlled }
        settings.setAllowBrowseFromOtherDevices(true)
        settings.setAllowReplaceFromOtherDevices(true)
        settings.setUpdatesRemoteStart(true)
        assertFalse(settings.state.value.allowBrowseFromOtherDevices)
        assertFalse(settings.state.value.allowReplaceFromOtherDevices)
        assertFalse(settings.state.value.updatesRemoteStart)
        // Once control ends, the person here can turn them on, and off again at any time.
        controlled = false
        settings.setAllowBrowseFromOtherDevices(true)
        settings.setUpdatesRemoteStart(true)
        assertTrue(settings.state.value.allowBrowseFromOtherDevices)
        assertTrue(settings.state.value.updatesRemoteStart)
        controlled = true
        settings.setAllowBrowseFromOtherDevices(false)
        settings.setUpdatesRemoteStart(false)
        assertFalse(settings.state.value.allowBrowseFromOtherDevices)
        assertFalse(settings.state.value.updatesRemoteStart)
    }
}
