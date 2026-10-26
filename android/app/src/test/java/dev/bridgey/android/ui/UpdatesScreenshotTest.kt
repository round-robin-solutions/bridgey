package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.AndroidUpdate
import dev.bridgey.android.R
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateError
import dev.bridgey.android.UpdateUiState
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
 * Settings > Updates in every state, on the Settings page at the design's 412 x 915 dp phone
 * size, light and dark. PNGs are written only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class UpdatesScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 26, 16, 5, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
    private val installed = "0.6.0-rr.1-beta.9"

    /** Notes as rrrelease.py publishes them in the feed: Markdown, wrapped lines, a heading. */
    private val notes = listOf(
        "- Settings > Updates is one status card: what you have, what is ready, and one main button.",
        "- Release notes show as a list with Show all, and the full notes are one tap away.",
        "- Skip this version moved into the ⋮ menu.",
        "- Reconnects after Doze no longer wait for the next",
        "  discovery round.",
        "## Fixes",
        "- Several Macs at once no longer fight over the clipboard.",
        "- The Files screen remembers where you were.",
    ).joinToString("\n")

    private val update = AndroidUpdate(
        UpdateChannel.BETA, "0.6.0-rr.1-beta.10", 610, "https://github.com/round-robin-solutions/bridgey/releases/tag/v0.6.0-rr.1-beta.10",
        notes, "https://github.com/round-robin-solutions/bridgey/releases/download/x.apk", "a".repeat(64), 15_200_000, 26,
    )
    private val base = UpdateUiState(channel = UpdateChannel.BETA, lastCheckedAt = now - 7 * 60_000)

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

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
            val directory = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/$name.png") }
        }
    }

    private fun updates(name: String, state: UpdateUiState) = capture("android-updates-$name-${if (dark()) "dark" else "light"}") {
        SettingsPage(stringResource(R.string.settings_title), onBack = {}) {
            item(key = "updates.label") { SectionLabel(stringResource(R.string.settings_updates), Modifier.padding(top = 20.dp)) }
            item(key = "updates") { UpdatesCard(state, installed, now, SettingsActions()) }
        }
    }

    private fun dark(): Boolean =
        ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES

    @Test fun upToDateLight() = updates("up-to-date", base)

    @Test @Config(qualifiers = "+night") fun upToDateDark() = updates("up-to-date", base)

    @Test fun availableLight() = updates("available", base.copy(available = update))

    @Test @Config(qualifiers = "+night") fun availableDark() = updates("available", base.copy(available = update))

    @Test fun downloadingLight() = updates("downloading", base.copy(available = update, downloadProgress = 0.42f))

    @Test @Config(qualifiers = "+night") fun downloadingDark() = updates("downloading", base.copy(available = update, downloadProgress = 0.42f))

    @Test fun readyLight() = updates("ready", base.copy(available = update, awaitingConfirmation = true))

    @Test @Config(qualifiers = "+night") fun readyDark() = updates("ready", base.copy(available = update, awaitingConfirmation = true))

    @Test fun errorLight() = updates("error", base.copy(available = update, error = UpdateError.DOWNLOAD))

    @Test @Config(qualifiers = "+night") fun errorDark() = updates("error", base.copy(available = update, error = UpdateError.DOWNLOAD))

    @Test fun laterLight() = updates("later", base.copy(available = update, deferred = true))

    @Test @Config(qualifiers = "+night") fun laterDark() = updates("later", base.copy(available = update, deferred = true))

    @Test fun checkingLight() = updates("checking", base.copy(checking = true))

    @Test @Config(qualifiers = "+night") fun checkingDark() = updates("checking", base.copy(checking = true))
}
