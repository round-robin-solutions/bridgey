package dev.bridgey.android

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Connect away from home as stored: no key means nobody chose, so it is on (Rahul, 2026-10-30); a choice is
 * stored and survives a restart and an upgrade, so an explicit off stays off.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class ConnectAwaySettingTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    @Before fun clean() {
        context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test fun aFreshInstallHasItOn() {
        val settings = BridgeySettings(context, "Phone")
        assertNull(settings.state.value.connectAwayChoice)
        assertTrue(settings.state.value.connectAway)
        assertFalse(settings.hasStored(BridgeySettings.KEY_CONNECT_AWAY))
    }

    @Test fun anExplicitOffSurvivesARestartAndAnUpgrade() {
        BridgeySettings(context, "Phone").setConnectAway(false)
        val reloaded = BridgeySettings(context, "Phone")
        assertEquals(false, reloaded.state.value.connectAwayChoice)
        assertFalse(reloaded.state.value.connectAway)
        reloaded.setConnectAway(true)
        assertEquals(true, BridgeySettings(context, "Phone").state.value.connectAwayChoice)
    }

    @Test fun anInstallFromBeforeThatNeverSetItTurnsOn() {
        // 0.10.0-rr.1-beta.13 stored nothing until the person chose; other settings are there.
        context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit().putBoolean("focus.share", true).commit()
        val settings = BridgeySettings(context, "Phone")
        assertNull(settings.state.value.connectAwayChoice)
        assertTrue(settings.state.value.connectAway)
    }
}
