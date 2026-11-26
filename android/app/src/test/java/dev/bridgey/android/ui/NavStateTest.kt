package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Bundle
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.MotionSpec
import dev.bridgey.android.ui.motion.MotionTokens
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * A page keeps what it held when another page opens above it and closes again: Settings search keeps its query when
 * back comes from a result. Each motion mode, since the page moves from behind to the top when the one above leaves.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class NavStateTest {
    class Host : ComponentActivity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            setContent {
                CompositionLocalProvider(LocalMotion provides motion) {
                    val stack = rememberBackStack(listOf(Route.Settings, Route.SettingsSearch))
                    routes = stack
                    MotionNavHost(stack) { route ->
                        if (route == Route.SettingsSearch) {
                            var query by rememberSaveable { mutableStateOf("") }
                            setQuery = { query = it }
                            // Read during composition, so a new query recomposes and reports.
                            val shown = query
                            SideEffect { shownQuery = shown }
                        }
                        Text(route.key)
                    }
                }
            }
        }
    }

    companion object {
        var motion: MotionSpec = MotionTokens.ExpressiveSnap
        var routes: BackStack? = null
        var setQuery: (String) -> Unit = {}
        var shownQuery: String? = null
    }

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, Host::class.java))
        routes = null
        shownQuery = null
    }

    /** Lets every page animation finish. */
    private fun settle() = repeat(4) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(500)) }

    private fun keepsTheQuery(spec: MotionSpec) {
        motion = spec
        ActivityScenario.launch(Host::class.java).use { scenario ->
            settle()
            scenario.onActivity {
                setQuery("resume")
                Snapshot.sendApplyNotifications()
            }
            settle()
            assertEquals("typed", "resume", shownQuery)
            scenario.onActivity { routes!!.push(Route.Permissions) }
            settle()
            scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            settle()
            assertEquals(listOf("settings", "settings_search"), routes!!.entries.map { it.key })
            assertEquals("after back", "resume", shownQuery)
        }
    }

    @Test fun keepsStateWithFullMotion() = keepsTheQuery(MotionTokens.ExpressiveSnap)

    @Test fun keepsStateWithReducedMotion() = keepsTheQuery(MotionTokens.reduced(MotionTokens.ExpressiveSnap))

    @Test fun keepsStateWithoutAnimations() = keepsTheQuery(MotionTokens.instant(MotionTokens.ExpressiveSnap))
}
