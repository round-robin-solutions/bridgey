package dev.bridgey.android.ui.search

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.R
import dev.bridgey.android.ui.SettingsActions
import dev.bridgey.android.ui.SettingsScreen
import dev.bridgey.android.ui.SettingsCard
import dev.bridgey.android.ui.SettingsGroup
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.MotionSpec
import dev.bridgey.android.ui.motion.MotionTokens
import dev.bridgey.android.ui.sampleSettingsState
import dev.bridgey.android.ui.settingsRoute
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * A search result opens its page scrolled to the row, which then highlights. Privacy > Logging > Remote control sessions
 * sits inside the Logging card's More options, below the fold on a phone-sized screen: the card opens them first. Each
 * motion mode, since the full one waits for the page to arrive and animates the scroll.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-mdpi")
class SettingsSearchJumpTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName(app, ComponentActivity::class.java))
    }

    private fun jump(motion: MotionSpec): Pair<SettingsSearchHost, LazyListState> {
        val host = SettingsSearchHost()
        val list = LazyListState()
        val route = settingsRoute(SettingsGroup.PRIVACY).key
        host.open(route, context.getString(R.string.logging_remote), scope = SettingsCard.LOGGING.key, expand = SettingsCard.LOGGING.key)
        val token = host.pending!!.token
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    BridgeyTheme {
                        CompositionLocalProvider(LocalSettingsSearch provides host, LocalSearchRoute provides route, LocalMotion provides motion) {
                            SettingsScreen(state = sampleSettingsState(1_793_000_000_000L), actions = SettingsActions(), listState = list, group = SettingsGroup.PRIVACY)
                        }
                    }
                }
            }
            // The full motion first waits 280 ms for the page with a coroutine delay, which runs on real time (Compose's
            // UI dispatcher has no delay of its own), so step the looper and let real time pass too: up to 10 s of each.
            var steps = 0
            while (host.arrived != token && steps++ < 200) {
                shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
                Thread.sleep(50)
            }
            assertEquals("the row was found and the highlight started", token, host.arrived)
        }
        return host to list
    }

    private fun scrollsToTheRow(motion: MotionSpec) {
        val (host, list) = jump(motion)
        assertTrue("the list scrolled (first visible item ${list.firstVisibleItemIndex})", list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 0)
        // The row ends on screen, below the page bar (status bar and the 56 dp bar), on this 915 px tall screen.
        val row = host.rowBounds!!
        assertTrue("the row is on screen, below the page bar: $row", row.top >= 80f && row.bottom <= 915f && row.height > 0f)
    }

    @Test fun fullMotion() = scrollsToTheRow(MotionTokens.ExpressiveSnap)

    @Test fun reducedMotion() = scrollsToTheRow(MotionTokens.reduced(MotionTokens.ExpressiveSnap))

    @Test fun noAnimations() = scrollsToTheRow(MotionTokens.instant(MotionTokens.ExpressiveSnap))
}
