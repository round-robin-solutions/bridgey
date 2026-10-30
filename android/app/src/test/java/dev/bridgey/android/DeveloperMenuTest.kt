package dev.bridgey.android

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.settingsRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** About > Version: five quick taps turn on the Developer and experimental menu, which stays on until hidden. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class DeveloperMenuTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()
    private var clock = 1_000_000L

    private fun menu() = DeveloperMenu(context.getSharedPreferences(DeveloperMenu.PREFERENCES, Context.MODE_PRIVATE)) { clock }

    @Test
    fun fiveQuickTapsTurnItOnWithACountdownForTheLastThree() {
        val menu = menu()
        val taps = (1..5).map { clock += 400; menu.tap() }
        assertEquals(
            listOf(DeveloperMenu.Tap.Counting, DeveloperMenu.Tap.Remaining(3), DeveloperMenu.Tap.Remaining(2), DeveloperMenu.Tap.Remaining(1), DeveloperMenu.Tap.Unlocked),
            taps,
        )
        assertTrue(menu.enabled.value)
        clock += 400
        assertEquals("once on, a tap opens it", DeveloperMenu.Tap.Open, menu.tap())
    }

    @Test
    fun aPauseStartsTheCountAgain() {
        val menu = menu()
        repeat(4) { clock += 400; menu.tap() }
        clock += DeveloperMenu.WINDOW_MILLIS + 1
        assertEquals(DeveloperMenu.Tap.Counting, menu.tap())
        assertFalse(menu.enabled.value)
    }

    @Test
    fun itStaysOnAcrossRestartsUntilHiddenInTheMenu() {
        val first = menu()
        repeat(5) { clock += 100; first.tap() }
        assertTrue("a new instance (the app restarted) reads it back", menu().enabled.value)
        menu().turnOff()
        val after = menu()
        assertFalse(after.enabled.value)
        clock += 100
        assertEquals("hidden: counting starts again", DeveloperMenu.Tap.Counting, after.tap())
    }

    @Test
    fun itNeverSyncs() {
        // Settings sync only sends the keys it lists; none of them is the menu's.
        val synced = dev.bridgey.android.sync.SyncKey.entries.flatMap { listOf(it.key, it.token) }
        assertTrue(synced.none { it.contains("developer") })
        assertEquals(Route.SettingsPane(SettingsSection.DEVELOPER), settingsRoute(SettingsSection.DEVELOPER))
        assertEquals(settingsRoute(SettingsSection.DEVELOPER), Route.fromKey("settings:developer"))
    }
}
