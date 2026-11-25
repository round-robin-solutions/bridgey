package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.control.PhoneControlGrantMode
import dev.bridgey.android.ui.theme.BridgeyTheme
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Settings > Remote control with Let Macs control this phone: Bridgey control off with Macs to choose, and on with one
 * Mac allowed without asking. Light and dark. Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h1400dp-port-xxhdpi")
class PhoneControlScreenshotTest {
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

    private val macs = listOf(
        PhoneControlMac("work", "Work MacBook", PhoneControlGrantMode.ASK, sharing = true),
        PhoneControlMac("air", "MacBook Air", PhoneControlGrantMode.OFF, sharing = false),
    )

    private fun page(name: String, state: PhoneControlSettingsState) = capture(name) {
        SettingsScreen(state = sampleSettingsState(1_793_000_000_000L).copy(phoneControl = state), actions = SettingsActions(), section = SettingsSection.REMOTE_CONTROL)
    }

    @Test fun serviceOffLight() = page("phone-control-settings-off", PhoneControlSettingsState(serviceEnabled = false, restrictedPossible = true, macs = macs))

    @Test @Config(qualifiers = "+night") fun serviceOnDark() = page(
        "phone-control-settings-on",
        PhoneControlSettingsState(serviceEnabled = true, macs = macs.map { if (it.id == "air") it.copy(mode = PhoneControlGrantMode.ALWAYS, sharing = true) else it }),
    )

    @Test fun androidTwelveLight() = page("phone-control-settings-android12", PhoneControlSettingsState(serviceEnabled = true, typing = false, macs = macs.take(1)))
}
