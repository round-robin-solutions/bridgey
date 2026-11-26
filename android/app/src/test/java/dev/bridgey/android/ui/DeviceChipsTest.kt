package dev.bridgey.android.ui

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.PermissionOrder
import dev.bridgey.android.sync.SyncSwitches
import dev.bridgey.android.sync.SyncUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The Devices chips read and write the same stored values as the device page's switches they replace: a chip shows what
 * the switch showed (on for the device, not off everywhere, not off on the device's side) and tapping it stores the
 * same "device.<id>.<feature>" keys through BridgeySettings.setForDevice.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class DeviceChipsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()
    private val now = 1_793_000_000_000L

    private fun state(settings: BridgeySettings, remote: Map<BridgeyFeature, Boolean>? = null, syncOn: Boolean = true) =
        sampleSettingsState(now).copy(
            globalFeatures = settings.state.value.globalFeatures,
            autoClipboardEnabled = settings.state.value.autoClipboardGlobal,
            sync = SyncUiState(switches = SyncSwitches(enabled = syncOn)),
            devices = listOf(settingsDevice(settings, "work", "Work MacBook", remote, sync = true, syncOffRemote = false)),
        )

    /** What the device page's switch showed for [features] on "work" (MainActivity's PermissionRow, then DeviceScreen). */
    private fun oldSwitch(settings: BridgeySettings, features: List<BridgeyFeature>, remote: Map<BridgeyFeature, Boolean>?): Pair<Boolean, Boolean> {
        val checked = features.any { settings.isEnabled(it, "work") }
        val globallyOff = features.all { settings.state.value.globalFeatures[it] == false }
        val remotelyOff = remote != null && features.all { remote[it] == false }
        return (checked && !globallyOff && !remotelyOff) to (!globallyOff && !remotelyOff)
    }

    @Test fun chipsShowWhatTheSwitchesShowed() {
        val settings = BridgeySettings(context, "Phone")
        settings.setForDevice("work", BridgeyFeature.FILES, false)
        settings.setForDevice("work", BridgeyFeature.DIALER, true)
        settings.setGlobal(BridgeyFeature.MEDIA, false)
        val remote = BridgeyFeature.entries.associateWith { it != BridgeyFeature.LINKS }
        val state = state(settings, remote)
        PermissionOrder.forEach { features ->
            val chip = featureChips(state, features) { _, _, _ -> }.single()
            assertEquals("$features", oldSwitch(settings, features, remote), chip.checked to chip.enabled)
        }
        assertEquals(listOf("Work MacBook"), remotelyOffNames(state, listOf(BridgeyFeature.LINKS)))
        assertTrue(remotelyOffNames(state, listOf(BridgeyFeature.CLIPBOARD)).isEmpty())
    }

    @Test fun tappingAChipStoresWhatTheSwitchStored() {
        val settings = BridgeySettings(context, "Phone")
        PermissionOrder.forEach { features ->
            val before = featureChips(state(settings), features) { id, f, on -> setDeviceChoice(settings, id, f, on) }.single()
            if (!before.enabled) return@forEach
            before.onChange(!before.checked)
            features.forEach { feature ->
                assertEquals("$feature", !before.checked, settings.state.value.deviceFeatures["work"]?.get(feature))
                assertEquals("$feature", !before.checked, prefs().getBoolean("device.work.${feature.key}", before.checked))
            }
            // The chip reads the new value back, as the switch did.
            val after = featureChips(state(settings), features) { _, _, _ -> }.single()
            assertEquals("$features", !before.checked, after.checked)
        }
    }

    @Test fun findAndPingAreOneChip() {
        val settings = BridgeySettings(context, "Phone")
        val chip = featureChips(state(settings), listOf(BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING)) { id, f, on -> setDeviceChoice(settings, id, f, on) }.single()
        chip.onChange(false)
        assertFalse(settings.isEnabled(BridgeyFeature.FIND_DEVICE, "work"))
        assertFalse(settings.isEnabled(BridgeyFeature.PING, "work"))
    }

    @Test fun automaticClipboardChipFollowsClipboardAndStoresThePerDeviceKey() {
        val settings = BridgeySettings(context, "Phone")
        settings.setAutoClipboardGlobal(true)
        val chip = autoClipboardChips(state(settings)) { id, on -> settings.setAutoClipboardForDevice(id, on) }.single()
        assertTrue(chip.enabled)
        assertEquals(settings.isAutoClipboardEnabled("work"), chip.checked)
        chip.onChange(false)
        assertFalse(settings.isAutoClipboardEnabled("work"))
        // Clipboard off for the device: the switch was hidden, the chip is shown off and cannot be tapped.
        settings.setForDevice("work", BridgeyFeature.CLIPBOARD, false)
        val off = autoClipboardChips(state(settings)) { _, _ -> }.single()
        assertFalse(off.enabled)
        assertFalse(off.checked)
    }

    @Test fun syncChipFollowsTheSyncSwitch() {
        val settings = BridgeySettings(context, "Phone")
        var stored: Pair<String, Boolean>? = null
        val on = syncChips(state(settings, syncOn = true)) { id, value -> stored = id to value }.single()
        assertTrue(on.enabled && on.checked)
        on.onChange(false)
        assertEquals("work" to false, stored)
        val off = syncChips(state(settings, syncOn = false)) { _, _ -> }.single()
        assertFalse(off.enabled || off.checked)
    }

    /** BridgeySettings' own preference file. */
    private fun prefs() = context.getSharedPreferences("bridgey.settings", android.content.Context.MODE_PRIVATE)
}
