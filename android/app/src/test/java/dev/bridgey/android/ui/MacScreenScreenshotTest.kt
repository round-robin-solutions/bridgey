package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.display.DisplayControlReason
import dev.bridgey.android.display.DisplayOutcome
import dev.bridgey.android.display.DisplaySourceMessage
import dev.bridgey.android.display.DisplayStatus
import dev.bridgey.android.display.DisplayViewState
import dev.bridgey.android.display.Geometry
import dev.bridgey.android.display.InputCapabilities
import dev.bridgey.android.display.SourceKind
import dev.bridgey.android.ui.theme.BridgeyTheme
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * See Mac screens: the viewer while asking, waiting for the Mac, viewing and controlling (a gradient stands in for the
 * decoded picture), with the keyboard, after a refusal, and rotated. Light and dark at the design's phone size.
 * Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class MacScreenScreenshotTest {
    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun dark(): Boolean =
        ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES

    private val theme get() = if (dark()) "dark" else "light"
    private val directory get() = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"

    private fun capture(name: String, content: @Composable () -> Unit) {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.enableEdgeToEdge()
                activity.setContent { BridgeyTheme { content() } }
                val density = activity.resources.displayMetrics.density
                val insets = WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, (40 * density).toInt(), 0, 0))
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, (24 * density).toInt()))
                    .build()
                ViewCompat.dispatchApplyWindowInsets(activity.window.decorView, insets)
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/android-$name-$theme.png") }
        }
    }

    private val geometry = Geometry(1, 69_734_662, SourceKind.DISPLAY, 1920, 1246)
    private val stats = DisplaySourceMessage.Stats("s", 2, 28, 6, 4_000_000, 3_800_000, 30, 0)
    private val base = DisplayViewState(deviceId = "mac", macName = "MacBook Pro", displayName = "Built-in Retina Display")

    private fun viewer(name: String, state: DisplayViewState, keyboard: Boolean = false) = capture(name) {
        MacScreenScreen(state, MacScreenActions(), picture = { modifier ->
            Box(modifier.background(Brush.linearGradient(listOf(Color(0xFF2B5876), Color(0xFF4E4376)))))
        }, initialKeyboard = keyboard)
    }

    private fun streaming(control: DisplayViewState.ControlPhase = DisplayViewState.ControlPhase.OFF) = base.copy(
        phase = DisplayViewState.Phase.STREAMING, geometry = geometry, controlAllowed = true, control = control, stats = stats,
        input = if (control == DisplayViewState.ControlPhase.ACTIVE) InputCapabilities(pointer = true, keys = true, text = true) else InputCapabilities(),
    )

    @Test fun waitingLight() = viewer("mac-screen-waiting", base.copy(phase = DisplayViewState.Phase.WAITING))

    @Test fun viewingLight() = viewer("mac-screen-viewing", streaming())

    @Test @Config(qualifiers = "+night") fun viewingDark() = viewer("mac-screen-viewing", streaming())

    @Test fun controllingKeyboardLight() = viewer("mac-screen-controlling-keyboard", streaming(DisplayViewState.ControlPhase.ACTIVE), keyboard = true)

    @Test @Config(qualifiers = "+night") fun controlEndedDark() =
        viewer("mac-screen-control-focus", streaming().copy(controlNote = DisplayControlReason.FOCUS))

    @Test fun declinedLight() = viewer("mac-screen-declined", base.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.Refused(DisplayStatus.DECLINED)))

    @Test @Config(qualifiers = "+night") fun permissionDark() =
        viewer("mac-screen-permission", base.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.Refused(DisplayStatus.PERMISSION)))

    @Test @Config(qualifiers = "w915dp-h412dp-land-xxhdpi") fun rotatedLight() = viewer("mac-screen-rotated", streaming(DisplayViewState.ControlPhase.ACTIVE))
}
