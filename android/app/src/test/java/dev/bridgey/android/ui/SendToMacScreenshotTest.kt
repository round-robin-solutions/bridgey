package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.routing.*
import dev.bridgey.android.sharing.*
import dev.bridgey.android.ui.theme.BridgeyTheme
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Rendered fixtures, not emulator or end-to-end acceptance evidence. */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w390dp-h844dp-port-xxhdpi")
class SendToMacScreenshotTest {
    @Before fun setup() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName(app, ComponentActivity::class.java))
    }
    private fun capture(name: String, phase: SharePhase = SharePhase.CHOOSING, longName: Boolean = false) {
        val dark = ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
        val macs = listOf(
            ShareMac("work", if (longName) "Work MacBook Pro with a very long device name" else "Work Mac", "session", true,
                ObservedPresence("session", DevicePresencePacket(1, PresenceState.ACTIVE, 0), SystemClock.elapsedRealtime())),
            ShareMac("personal", "Personal Mac", "s2", true),
            ShareMac("pro", "Rahul's MacBook Pro", null, false),
        )
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.enableEdgeToEdge()
                activity.setContent {
                    BridgeyTheme {
                        SendToMacSheet(ShareFlow(phase, "work", "session", when (phase) {
                            SharePhase.FAILED -> "Work Mac is offline. Try again when it reconnects."
                            SharePhase.SUCCEEDED -> "Opened on Work Mac"
                            else -> null
                        }), macs, "instagram.com", false, {}, {}, {}, {})
                    }
                }
            }
            repeat(6) { shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(100)) }
            val dir = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"
            scenario.onActivity { it.window.decorView.captureRoboImage("$dir/$name-${if (dark) "dark" else "light"}.png") }
        }
    }
    @Test fun chooserLight() = capture("chooser")
    @Test @Config(qualifiers = "+night") fun chooserDark() = capture("chooser")
    @Test fun graceLight() = capture("grace", SharePhase.GRACE)
    @Test @Config(qualifiers = "+night") fun failureDark() = capture("failure", SharePhase.FAILED)
    @Test fun openedLight() = capture("opened", SharePhase.SUCCEEDED)
    @Test @Config(qualifiers = "+night") fun longNameDark() = capture("long-name", longName = true)
}
