package dev.bridgey.android.migrations

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.actions.MacActionIds
import dev.bridgey.android.actions.MacVolume
import dev.bridgey.android.actions.SharedPreferencesCatalogStore
import dev.bridgey.android.migrations.MigrationFixtures.MAC_A
import dev.bridgey.android.migrations.MigrationFixtures.MAC_B
import dev.bridgey.android.migrations.MigrationFixtures.MAC_C
import dev.bridgey.android.widget.WidgetTargets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * v0.9 automation stores on the phone: the Mac actions and camera switches and the Focus switches in
 * `bridgey.settings`, each Mac's saved list of Mac actions (`bridgey.mac_actions`) and which Mac each widget
 * shows (`bridgey.widgets`). Fixtures in `protocol/test-vectors/migrations/android/shared_prefs/automation`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class AutomationMigrationTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()

    private fun install() {
        MigrationFixtures.installSharedPrefs(context, 13)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.FILES_2_SNAPSHOT)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.AUTOMATION_SNAPSHOT)
    }

    @Test
    fun automationSwitchesAndFocusSurvive() {
        install()
        val settings = BridgeySettings(context, "Default name")
        val state = settings.state.value
        assertEquals("Test Phone", state.deviceName)
        assertTrue(state.focusShare)
        assertTrue(state.focusFollow)
        assertTrue(settings.isEnabled(BridgeyFeature.MAC_ACTIONS, MAC_A))
        assertFalse("Mac actions was turned off for Mac B", settings.isEnabled(BridgeyFeature.MAC_ACTIONS, MAC_B))
        assertFalse("the camera was turned off for Mac A", settings.isEnabled(BridgeyFeature.CAMERA, MAC_A))
        assertTrue(settings.isEnabled(BridgeyFeature.CAMERA, MAC_B))
        // Older switches in the same file stay as they were.
        assertTrue(settings.isEnabled(BridgeyFeature.REMOTE_INPUT, MAC_A))
        assertFalse(state.clipboardFilesEnabled)
    }

    @Test
    fun aPhoneFromBeforeAutomationGetsTheDefaults() {
        MigrationFixtures.installSharedPrefs(context, 13)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.FILES_2_SNAPSHOT)
        val settings = BridgeySettings(context, "Default name")
        // Mac actions and the camera are on by default here (the Mac is the gate); Focus is off both ways.
        assertTrue(settings.isEnabled(BridgeyFeature.MAC_ACTIONS, MAC_A))
        assertTrue(settings.isEnabled(BridgeyFeature.CAMERA, MAC_A))
        assertFalse(settings.state.value.focusShare)
        assertFalse(settings.state.value.focusFollow)
        assertTrue(SharedPreferencesCatalogStore(context).load().isEmpty())
        assertNull(WidgetTargets.get(context, 7))
    }

    @Test
    fun savedCatalogsLoadAndBadOnesAreDroppedOneByOne() {
        install()
        val catalogs = SharedPreferencesCatalogStore(context).load()
        // Mac B's list is cut short and Mac C's is a version this build does not know: each is dropped on its own.
        assertEquals(setOf(MAC_A), catalogs.keys)
        val catalog = catalogs.getValue(MAC_A)
        // An identifier this build does not know (a newer Mac's action) is dropped from the list on its own.
        assertEquals(
            listOf(
                MacActionIds.LOCK, MacActionIds.SLEEP, MacActionIds.VOLUME_DOWN, MacActionIds.VOLUME_MUTE, MacActionIds.VOLUME_UP,
                MacActionIds.VOLUME_SET, "app:com.apple.Safari", "shortcut:3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b",
            ),
            catalog.entries.map { it.id },
        )
        assertEquals("permission_required", catalog.entry(MacActionIds.LOCK)?.blocked)
        assertEquals("Safari", catalog.apps.single().title)
        assertEquals("Morning routine", catalog.shortcuts.single().title)
        assertEquals(MacVolume(40, false), catalog.volume)
        assertFalse(MAC_C in catalogs)
    }

    @Test
    fun widgetTargetsSurvive() {
        install()
        assertEquals(MAC_A, WidgetTargets.get(context, 7))
        assertEquals(MAC_B, WidgetTargets.get(context, 12))
        assertNull(WidgetTargets.get(context, 99))
    }
}
