package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Bundle
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.SetupBackHandler
import dev.bridgey.android.SetupStateSaver
import dev.bridgey.android.setup.Answers
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupScreen
import dev.bridgey.android.setup.SetupState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Setup's back handling inside the real nav host: system back goes to the previous step, leaves
 * only from the first screen (asking first when something was chosen), keeps working after the
 * app was in the background, and the step survives the activity being recreated.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class SetupBackTest {
    /** Home with setup above it, as on first run; setup reports its state here. */
    class Host : ComponentActivity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            setContent {
                val stack = rememberBackStack(listOf(Route.Home, Route.Setup))
                routes = stack
                MotionNavHost(stack) { route ->
                    if (route == Route.Setup) {
                        var flow by rememberSaveable(stateSaver = SetupStateSaver) { mutableStateOf(initial) }
                        state = flow
                        SetupBackHandler(flow, { flow = SetupFlow.reduce(flow, it, SetupFacts(paired = true)) }, { stack.pop() })
                        // A handler deeper in the page, as a settings row might add: setup still decides while it is off.
                        BackHandler(enabled = false) { deeper++ }
                    }
                    Text(route.key)
                }
            }
        }
    }

    companion object {
        var initial = SetupState()
        var state: SetupState? = null
        var routes: BackStack? = null
        var deeper = 0
    }

    private val midway: SetupState
        get() = SetupState(
            screen = SetupScreen.Question("calls"),
            path = dev.bridgey.android.setup.SetupPath.ADVANCED,
            answers = mapOf("clipboard" to Answers.NO),
            trail = listOf("clipboard", "notifications", "calls"),
        )

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, Host::class.java))
        state = null
        routes = null
        deeper = 0
    }

    private fun idle() = repeat(3) { shadowOf(Looper.getMainLooper()).idle() }

    private fun ActivityScenario<Host>.back() {
        onActivity { it.onBackPressedDispatcher.onBackPressed() }
        idle()
    }

    private val screen get() = state!!.screen
    private val routeKeys get() = routes!!.entries.map { it.key }

    @Test
    fun backGoesToThePreviousStepAndLeavesOnlyFromTheFirstScreen() {
        initial = midway
        ActivityScenario.launch(Host::class.java).use { scenario ->
            idle()
            scenario.back()
            assertEquals(SetupScreen.Question("notifications"), screen)
            scenario.back()
            assertEquals(SetupScreen.Question("clipboard"), screen)
            scenario.back()
            assertEquals(SetupScreen.Intro, screen)
            scenario.back()
            assertEquals(SetupScreen.Welcome, screen)
            assertEquals(listOf("home", "setup"), routeKeys)
            // The first screen, with choices made: ask once, and Back closes the question.
            scenario.back()
            assertTrue(state!!.confirmLeave)
            assertEquals(listOf("home", "setup"), routeKeys)
            scenario.back()
            assertFalse(state!!.confirmLeave)
            assertEquals(0, deeper)
        }
    }

    @Test
    fun withNothingChosenBackOnTheFirstScreenLeaves() {
        initial = SetupState()
        ActivityScenario.launch(Host::class.java).use { scenario ->
            idle()
            scenario.back()
            idle()
            assertEquals(listOf("home"), routeKeys)
        }
    }

    @Test
    fun backStillStepsAfterTheAppWasInTheBackground() {
        initial = midway
        ActivityScenario.launch(Host::class.java).use { scenario ->
            idle()
            // As when a permission's system screen opens and closes.
            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            idle()
            scenario.back()
            assertEquals(SetupScreen.Question("notifications"), screen)
            assertEquals(listOf("home", "setup"), routeKeys)
        }
    }

    @Test
    fun theStepSurvivesRecreation() {
        initial = SetupState()
        ActivityScenario.launch(Host::class.java).use { scenario ->
            idle()
            initial = midway.copy(screen = SetupScreen.Question("clipboard"), trail = listOf("clipboard"))
            // Saved state wins over the new start: rotate with the setup at "calls".
            scenario.recreate()
            idle()
            assertEquals(SetupScreen.Welcome, screen)
        }
        initial = midway
        ActivityScenario.launch(Host::class.java).use { scenario ->
            idle()
            scenario.back()
            assertEquals(SetupScreen.Question("notifications"), screen)
            initial = SetupState()
            scenario.recreate()
            idle()
            assertEquals(SetupScreen.Question("notifications"), screen)
            assertEquals(listOf("home", "setup"), routeKeys)
            scenario.back()
            assertEquals(SetupScreen.Question("clipboard"), screen)
        }
    }
}
