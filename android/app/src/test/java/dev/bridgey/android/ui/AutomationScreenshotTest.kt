package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.glance.GlanceId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.compose
import androidx.glance.appwidget.provideContent
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingState
import dev.bridgey.android.RemoteBatteryStatus
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.actions.MacActionCatalog
import dev.bridgey.android.actions.MacActionEntry
import dev.bridgey.android.actions.MacVolume
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.controls.ControlMac
import dev.bridgey.android.health.DeviceHealth
import dev.bridgey.android.health.RouteClass
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.widget.MacWidgetContent
import dev.bridgey.android.widget.widgetModel
import dev.bridgey.core.discovery.DiscoveredPeer
import java.util.Calendar
import java.util.TimeZone
import kotlinx.coroutines.runBlocking
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Mac actions, the Connection tab, Media and quick actions, Open on Mac and the widget, light and
 * dark, at the design's phone size. Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class AutomationScreenshotTest {
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

    private val shortcut = "shortcut:3f2c9a10-1b2c-4d5e-8f90-a1b2c3d4e5f6"
    private val catalog = MacActionCatalog(
        listOf(
            MacActionEntry("lock", blocked = "permission_required"), MacActionEntry("sleep"), MacActionEntry("screensaver"),
            MacActionEntry("volume_down"), MacActionEntry("volume_mute"), MacActionEntry("volume_up"), MacActionEntry("volume_set"),
            MacActionEntry("app:com.apple.Safari", "Safari"), MacActionEntry("app:com.tinyspeck.slackmacgap", "Slack"),
            MacActionEntry(shortcut, "Focus for an hour"),
        ),
        MacVolume(40, muted = false),
    )

    private val trusted = listOf(TrustedDevice("work", "Work MacBook"), TrustedDevice("personal", "Personal Mac"))
    private val peers = listOf(DiscoveredPeer("work-svc", "work", "Work MacBook", "macos", 1, "10.0.0.3", 42_458))
    private val rings get() = deviceRings(trusted, peers, PairingState.Connected("work", "Work MacBook"))

    private val activity get() = listOf(
        ActivityItem(3, ActivityKind.CLIPBOARD_SENT, "work", "Work MacBook", null, "Room 2 at 4, bring the deck", null, false, false, 1, now - 20_000),
        ActivityItem(2, ActivityKind.FILE_RECEIVED, "work", "Work MacBook", "invoice-oct.pdf", null, null, false, false, 1, now - 3_600_000),
        ActivityItem(1, ActivityKind.LINK_SENT, "work", "Work MacBook", null, null, null, false, false, 1, now - 7_200_000),
    )

    private val health = DeviceHealth(
        device = "work", connected = true, route = RouteClass.SAME_NETWORK, dialledHere = true,
        connectedSinceMillis = now - 52 * 60_000, lastRttMillis = 14, medianRttMillis = 18, rttSamples = 10,
        lastDisconnectReason = "heartbeat_timeout", lastDisconnectAtMillis = now - 3 * 3_600_000, reconnectAttemptsToday = 3,
        discoverySeesNow = true, batteryOptimisationExempt = false,
    )

    private fun device(tab: DeviceTab, name: String, macActions: MacActionCatalog? = catalog) = capture(name) {
        val ring = rings.first()
        DeviceScreen(
            state = DeviceState(
                ring = ring,
                battery = RemoteBatteryStatus(76, isCharging = true),
                connected = true,
                available = BridgeyFeature.entries.toSet() - BridgeyFeature.MEDIA - BridgeyFeature.REMOTE_INPUT,
                ringing = false,
                permissions = emptyList(),
                notificationAccess = true,
                notificationAppsEnabled = 12,
                autoClipboard = true,
                autoClipboardGlobalOn = true,
                activity = activity,
                live = emptyList(),
                now = now,
                macActions = macActions,
                runningActions = setOf("sleep"),
                health = health,
            ),
            actions = DeviceActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
            initialTab = tab,
        )
    }

    @Test fun deviceActionsLight() = device(DeviceTab.ACTIVITY, "automation-device-actions")

    @Test @Config(qualifiers = "+night") fun deviceActionsDark() = device(DeviceTab.ACTIVITY, "automation-device-actions")

    @Test fun deviceActionsEmptyLight() = device(DeviceTab.ACTIVITY, "automation-device-actions-empty", MacActionCatalog(emptyList()))

    @Test fun deviceConnectionLight() = device(DeviceTab.CONNECTION, "automation-device-connection")

    @Test @Config(qualifiers = "+night") fun deviceConnectionDark() = device(DeviceTab.CONNECTION, "automation-device-connection")

    private fun mediaSettings() = capture("automation-settings-media") {
        SettingsScreen(state = sampleSettingsState(now), actions = SettingsActions(), section = SettingsSection.MEDIA)
    }

    @Test fun settingsMediaLight() = mediaSettings()

    @Test @Config(qualifiers = "+night") fun settingsMediaDark() = mediaSettings()

    private fun openOnMac(name: String, targets: List<OpenOnMacTarget>, phase: OpenOnMacPhase = OpenOnMacPhase.Confirm) = capture(name) {
        OpenOnMacSheet(OpenOnMacState("github.com", targets, targets.firstOrNull()?.deviceId, phase), OpenOnMacActions())
    }

    private val two = listOf(OpenOnMacTarget("work", "Work MacBook"), OpenOnMacTarget("personal", "Personal Mac"))

    @Test fun openOnMacPickLight() = openOnMac("automation-open-on-mac-pick", two)

    @Test @Config(qualifiers = "+night") fun openOnMacPickDark() = openOnMac("automation-open-on-mac-pick", two)

    @Test fun openOnMacOneLight() = openOnMac("automation-open-on-mac-one", two.take(1))

    @Test @Config(qualifiers = "+night") fun openOnMacDoneDark() =
        openOnMac("automation-open-on-mac-done", two.take(1), OpenOnMacPhase.Finished("Opened on Work MacBook", true))

    /** The widget renders through Glance's own RemoteViews translation, then inflates as a launcher would. */
    private fun widget() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val mac = ControlMac("work", "Work MacBook", true, BridgeyFeature.entries.toSet(), catalog.copy(entries = catalog.entries.filterNot { it.id == "lock" } + MacActionEntry("lock")), true, false)
        val model = widgetModel(mac)
        val preview = object : GlanceAppWidget() {
            override suspend fun provideGlance(context: android.content.Context, id: GlanceId) {
                provideContent { MacWidgetContent(context, model, "work") }
            }
        }
        val views = runBlocking { preview.compose(context, size = DpSize(320.dp, 170.dp)) }
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val density = activity.resources.displayMetrics.density
                val frame = FrameLayout(activity).apply {
                    setBackgroundColor(if (dark()) 0xFF000000.toInt() else 0xFFE6EBF2.toInt())
                    setPadding((24 * density).toInt(), (24 * density).toInt(), (24 * density).toInt(), (24 * density).toInt())
                }
                val inflated = views.apply(activity, frame)
                frame.addView(inflated, FrameLayout.LayoutParams((320 * density).toInt(), (170 * density).toInt()))
                activity.setContentView(frame, ViewGroup.LayoutParams((368 * density).toInt(), (218 * density).toInt()))
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            scenario.onActivity { (it.findViewById<ViewGroup>(android.R.id.content).getChildAt(0)).captureRoboImage("$directory/android-automation-widget-$theme.png") }
        }
    }

    @Test fun widgetLight() = widget()

    @Test @Config(qualifiers = "+night") fun widgetDark() = widget()
}
