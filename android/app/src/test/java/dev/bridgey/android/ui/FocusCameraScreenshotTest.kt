package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.Composable
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.util.Calendar
import java.util.TimeZone
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Focus sync rows on Settings > Notifications and the camera screen's chrome (a plain surface
 * stands in for the live preview), light and dark, at the design's phone size.
 * Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class FocusCameraScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 27, 9, 41, 20)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
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

    /** Follow on without Do Not Disturb access, so the access row and its warning show. */
    private fun focusSettings() = capture("focus-settings-notifications") {
        SettingsScreen(
            state = sampleSettingsState(now).copy(focus = FocusSettingsState(share = true, follow = true, access = false)),
            actions = SettingsActions(),
            listState = rememberLazyListState(initialFirstVisibleItemIndex = 2),
            section = SettingsSection.NOTIFICATIONS,
        )
    }

    @Test fun focusSettingsLight() = focusSettings()

    @Test @Config(qualifiers = "+night") fun focusSettingsDark() = focusSettings()

    private fun camera(name: String, state: CameraUiState) = capture(name) {
        CameraScreen(state, CameraUiActions()) {
            // Stands in for the live preview: a dim scene.
            Box(Modifier.fillMaxSize().background(Color(0xFF3B4250)))
        }
    }

    @Test fun cameraLight() = camera("camera-ready", CameraUiState("Work MacBook", CameraPhase.READY))

    @Test @Config(qualifiers = "+night") fun cameraDark() = camera("camera-ready", CameraUiState("Work MacBook", CameraPhase.READY))

    @Test fun cameraPermissionLight() = camera("camera-permission", CameraUiState("Work MacBook", CameraPhase.NEEDS_PERMISSION))

    @Test @Config(qualifiers = "+night") fun cameraPermissionDark() =
        camera("camera-permission", CameraUiState("Work MacBook", CameraPhase.NEEDS_PERMISSION, permanentlyDenied = true))
}
