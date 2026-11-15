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
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.setup.PermissionCatalog
import dev.bridgey.android.setup.PermissionFacts
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupState
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
 * Calls window: its rows on the Calls page (on, Phone and contacts allowed, call history not yet, one Mac
 * allowed and one not) and the Permissions page with Call history, light and dark at the design's phone
 * size. Synthetic names only. Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class DialerScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.NOVEMBER, 15, 9, 41, 20)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private val theme: String
        get() {
            val night = ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
            return if (night) "dark" else "light"
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
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/android-$name-$theme.png") }
        }
    }

    private val state get() = sampleSettingsState(now).let { sample ->
        sample.copy(
            globalFeatures = sample.globalFeatures + (BridgeyFeature.CALL_QUIET to false) + (BridgeyFeature.DIALER to true),
            dialer = DialerSettingsState(
                placeAllowed = true, contactsAllowed = true, callLogAllowed = false, askFirst = false,
                macs = listOf(DialerMac("mac-1", "Work Mac", allowed = true), DialerMac("mac-2", "MacBook Air", allowed = false)),
            ),
        )
    }

    /** The Calls page scrolled to the Calls window: the switch, permissions, Ask first and the Macs. */
    private fun settingsPage() = capture("calls-window-settings") {
        val list = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = 1)
        SettingsScreen(state = state, actions = SettingsActions(), section = SettingsSection.CALLS, listState = list)
    }

    @Test fun settingsPageLight() = settingsPage()

    @Test @Config(qualifiers = "+night") fun settingsPageDark() = settingsPage()

    private fun permissions() = capture("calls-window-permissions") {
        val entries = PermissionCatalog.entries(
            PermissionFacts(
                sdkInt = 35, labBuild = false,
                granted = setOf(PermissionKind.NOTIFICATION_ACCESS, PermissionKind.POST_NOTIFICATIONS, PermissionKind.PHONE_CALLS, PermissionKind.CONTACTS, PermissionKind.BATTERY),
                dialerOn = true,
            ),
        )
        val first = setOf(PermissionKind.PHONE_CALLS, PermissionKind.CONTACTS, PermissionKind.CALL_LOG)
        PermissionsScreen(entries.filter { it.kind in first } + entries.filterNot { it.kind in first }, onBack = {}, onManage = {})
    }

    @Test fun permissionsLight() = permissions()

    @Test @Config(qualifiers = "+night") fun permissionsDark() = permissions()

    @Test fun theCallsWindowAsksForCallHistoryOnlyWhenOn() {
        val off = PermissionCatalog.entries(PermissionFacts(sdkInt = 35, labBuild = false, granted = emptySet(), callsOn = false))
        org.junit.Assert.assertEquals(dev.bridgey.android.setup.PermissionState.NOT_NEEDED_YET, off.first { it.kind == PermissionKind.CALL_LOG }.state)
        val on = PermissionCatalog.entries(PermissionFacts(sdkInt = 35, labBuild = false, granted = emptySet(), callsOn = false, dialerOn = true))
        org.junit.Assert.assertEquals(dev.bridgey.android.setup.PermissionState.NOT_ALLOWED, on.first { it.kind == PermissionKind.CALL_LOG }.state)
        org.junit.Assert.assertEquals(dev.bridgey.android.setup.PermissionState.NOT_ALLOWED, on.first { it.kind == PermissionKind.CONTACTS }.state)
        org.junit.Assert.assertEquals(dev.bridgey.android.setup.PermissionState.NOT_ALLOWED, on.first { it.kind == PermissionKind.PHONE_CALLS }.state)
    }
}
