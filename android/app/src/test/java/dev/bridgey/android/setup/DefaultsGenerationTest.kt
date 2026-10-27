package dev.bridgey.android.setup

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** Off until chosen on fresh installs; existing installs keep exactly their settings. */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class DefaultsGenerationTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Before
    fun clear() {
        listOf("bridgey", "bridgey.settings", DefaultsGeneration.PREFERENCES).forEach {
            context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }

    /** What BridgeyApplication does at launch. */
    private fun launch(): BridgeySettings {
        val identity = context.getSharedPreferences("bridgey", Context.MODE_PRIVATE)
        val generation = DefaultsGeneration.settle(context, priorInstall = identity.contains("device_id"))
        if (!identity.contains("device_id")) identity.edit().putString("device_id", "new-device").commit()
        return BridgeySettings(context, "Phone", generation)
    }

    @Test
    fun resolve() {
        assertEquals(DefaultsGeneration.OFF_UNTIL_CHOSEN, DefaultsGeneration.resolve(stored = null, priorInstall = false))
        assertEquals(DefaultsGeneration.FEATURES_ON, DefaultsGeneration.resolve(stored = null, priorInstall = true))
        assertEquals(DefaultsGeneration.OFF_UNTIL_CHOSEN, DefaultsGeneration.resolve(stored = DefaultsGeneration.OFF_UNTIL_CHOSEN, priorInstall = true))
        assertEquals(DefaultsGeneration.FEATURES_ON, DefaultsGeneration.resolve(stored = DefaultsGeneration.FEATURES_ON, priorInstall = false))
    }

    @Test
    fun aFreshInstallStartsWithEveryFeatureOff() {
        val settings = launch()
        assertTrue(BridgeyFeature.entries.none { settings.state.value.globalFeatures.getValue(it) })
        // Choosing turns one on, and it stays on at the next launch.
        settings.setGlobal(BridgeyFeature.CLIPBOARD, true)
        val next = launch()
        assertTrue(next.state.value.globalFeatures.getValue(BridgeyFeature.CLIPBOARD))
        assertFalse(next.state.value.globalFeatures.getValue(BridgeyFeature.FILES))
    }

    @Test
    fun anUpgradeFrom010Beta1KeepsEverySetting() {
        // 0.10 beta 1: a device ID, Files switched off by hand, everything else never touched (on by default).
        context.getSharedPreferences("bridgey", Context.MODE_PRIVATE).edit().putString("device_id", "old-device").commit()
        context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit().putBoolean("global.files", false).putBoolean("global.remote_input_draft1", true).commit()
        // Text messages never starts on, even with the old defaults.
        val before = BridgeyFeature.entries.associateWith { it != BridgeyFeature.FILES && it != BridgeyFeature.SMS }
        val settings = launch()
        assertEquals(before, settings.state.value.globalFeatures)
        assertEquals(DefaultsGeneration.FEATURES_ON, context.getSharedPreferences(DefaultsGeneration.PREFERENCES, Context.MODE_PRIVATE).getInt(DefaultsGeneration.KEY, 0))
        // Reset > Settings clears the switches, not the generation: back to this install's own defaults.
        context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit().clear().commit()
        val reset = launch()
        assertTrue(BridgeyFeature.entries.filter { it != BridgeyFeature.REMOTE_INPUT && it != BridgeyFeature.SMS }.all { reset.state.value.globalFeatures.getValue(it) })
        assertTrue(reset.state.value.globalFeatures.getValue(BridgeyFeature.SMS) == false)
    }
}
