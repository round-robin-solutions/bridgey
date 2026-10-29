package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.updates.AutoUpdateRules
import dev.bridgey.android.updates.WireChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Update all devices automatically as stored: no key means no choice (it follows the channel, so
 * people who picked a channel before keep their channel and get its default); a flip is stored and
 * survives a restart and every channel change.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class AutoUpdateSettingTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    private fun enabled(settings: BridgeySettings, channel: WireChannel) = AutoUpdateRules.enabled(settings.state.value.updatesAutoAll, channel)

    @Test fun noChoiceFollowsTheChannel() {
        val settings = BridgeySettings(context, "Phone")
        assertNull(settings.state.value.updatesAutoAll)
        assertFalse(enabled(settings, WireChannel.STABLE))
        assertTrue(enabled(settings, WireChannel.BETA))
        assertTrue(enabled(settings, WireChannel.NIGHTLY))
    }

    @Test fun aFlipIsKeptAcrossRestartsAndChannels() {
        BridgeySettings(context, "Phone").setUpdatesAutoAll(false)
        val reloaded = BridgeySettings(context, "Phone")
        assertEquals(false, reloaded.state.value.updatesAutoAll)
        WireChannel.entries.forEach { assertFalse(it.name, enabled(reloaded, it)) }
        reloaded.setUpdatesAutoAll(true)
        val again = BridgeySettings(context, "Phone")
        WireChannel.entries.forEach { assertTrue(it.name, enabled(again, it)) }
    }
}
