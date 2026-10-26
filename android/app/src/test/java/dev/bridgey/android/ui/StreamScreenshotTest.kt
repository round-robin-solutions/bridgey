package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingState
import dev.bridgey.android.RemoteBatteryStatus
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.core.discovery.DiscoveredPeer
import java.util.Calendar
import java.util.TimeZone
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Renders the Stream screens on the JVM at the design's 412 x 915 dp phone size, light and dark,
 * with the mockup's sample content. Always rendered (a crash fails the build); PNGs are written
 * only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class StreamScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 25, 9, 41, 20)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun at(hour: Int, minute: Int): Long = Calendar.getInstance(zone).apply {
        timeInMillis = now
        set(Calendar.HOUR_OF_DAY, hour)
        set(Calendar.MINUTE, minute)
        set(Calendar.SECOND, 0)
    }.timeInMillis

    private val trusted = listOf(
        TrustedDevice("work", "Work MacBook"),
        TrustedDevice("personal", "Personal Mac"),
        TrustedDevice("mini", "Mac mini"),
    )
    private val peers = listOf(DiscoveredPeer("personal-svc", "personal", "Personal Mac", "macos", 1, "10.0.0.3", 42_458))
    private val rings get() = deviceRings(trusted, peers, PairingState.Connected("work", "Work MacBook"))

    private val activity get() = listOf(
        ActivityItem(7, ActivityKind.CLIPBOARD_SENT, "work", "Work MacBook", null, "Room 2 at 4, bring the deck", null, false, false, 1, now - 20_000),
        ActivityItem(6, ActivityKind.CALL_SHOWN, "work", "Work MacBook", null, "Mum", null, false, false, 1, at(9, 40)),
        ActivityItem(5, ActivityKind.FILE_RECEIVED, "personal", "Personal Mac", "invoice-oct.pdf", null, null, false, false, 1, at(9, 12)),
        ActivityItem(4, ActivityKind.CLIPBOARD_RECEIVED, "work", "Work MacBook", null, null, null, true, false, 1, at(9, 5)),
        ActivityItem(3, ActivityKind.LINK_SENT, "mini", "Mac mini", null, null, null, false, false, 1, at(8, 58)),
        ActivityItem(2, ActivityKind.NOTIFICATIONS_SHOWN, "work", "Work MacBook", null, null, "WhatsApp", false, false, 4, at(8, 55)),
        ActivityItem(1, ActivityKind.PING_RECEIVED, "work", "Work MacBook", null, null, null, false, false, 1, at(8, 30) - 24 * 60 * 60 * 1000L),
    )

    private fun nameFor(item: ActivityItem) = rings.firstOrNull { it.deviceId == item.deviceId }?.name ?: item.deviceName

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

    private fun home() = capture(if (dark()) "home-dark" else "home-light") {
        val rings = rings
        HomeScreen(
            state = HomeState(
                rings = rings,
                target = sendTarget(rings, null),
                activity = activity,
                live = emptyList(),
                canSendClipboard = true,
                now = now,
            ),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = ::nameFor,
        )
    }

    private fun device(tab: DeviceTab) = capture("device-${tab.name.lowercase()}-${if (dark()) "dark" else "light"}") {
        val ring = rings.first()
        val available = BridgeyFeature.entries.toSet() - BridgeyFeature.MEDIA
        DeviceScreen(
            state = DeviceState(
                ring = ring,
                battery = RemoteBatteryStatus(76, isCharging = true),
                connected = true,
                available = available,
                ringing = false,
                permissions = listOf(
                    listOf(BridgeyFeature.CLIPBOARD),
                    listOf(BridgeyFeature.FILES),
                    listOf(BridgeyFeature.NOTIFICATIONS),
                    listOf(BridgeyFeature.CALLS),
                    listOf(BridgeyFeature.MEDIA),
                    listOf(BridgeyFeature.REMOTE_INPUT),
                    listOf(BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING),
                    listOf(BridgeyFeature.LINKS),
                    listOf(BridgeyFeature.BATTERY),
                ).map { features ->
                    PermissionRow(features, checked = true, globallyOff = false, remotelyOff = BridgeyFeature.MEDIA in features)
                },
                notificationAccess = true,
                notificationAppsEnabled = 12,
                autoClipboard = true,
                autoClipboardGlobalOn = true,
                activity = activity,
                live = emptyList(),
                now = now,
            ),
            actions = DeviceActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = ::nameFor,
            initialTab = tab,
        )
    }

    private fun settingsState() = SettingsState(
        deviceName = "OnePlus 11",
        connectionStatus = "Connected to Work MacBook",
        connected = true,
        pairedCount = 3,
        globalFeatures = BridgeyFeature.entries.associateWith { it != BridgeyFeature.MEDIA },
        directCallsEnabled = true,
        autoClipboardEnabled = true,
        backgroundClipboardEnabled = true,
        backgroundClipboardStatus = dev.bridgey.android.BackgroundClipboardStatus.WAITING_FOR_SETUP,
        backgroundClipboardCommand = "adb shell pm grant in.roundrobin.bridgey android.permission.READ_LOGS && " +
            "adb shell appops set in.roundrobin.bridgey SYSTEM_ALERT_WINDOW allow && " +
            "adb shell am force-stop in.roundrobin.bridgey",
        tileAddSupported = true,
        tileAdded = false,
        notificationAppsEnabled = 12,
        notificationAppsTotal = 48,
        appNotificationsEnabled = true,
        notificationAccessEnabled = true,
        reduceMotion = false,
        showPreviews = true,
        activityCount = 6,
        update = UpdateUiState(channel = UpdateChannel.STABLE, lastCheckedAt = now - 10 * 60_000),
        installedVersion = "0.6.0",
        now = now,
    )

    private fun settings() = capture(if (dark()) "settings-dark" else "settings-light") {
        SettingsScreen(state = settingsState(), actions = SettingsActions())
    }

    /** Scrolled so the Clipboard section (its label is item index 4) leads the page. */
    private fun settingsClipboard() = capture(if (dark()) "settings-clipboard-dark" else "settings-clipboard-light") {
        SettingsScreen(
            state = settingsState(),
            actions = SettingsActions(),
            listState = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = 4),
        )
    }

    private val remoteActive = dev.bridgey.android.remote.RemoteSessionState.Active(
        "work", dev.bridgey.android.remote.RemoteMode.TOUCHPAD, "0b9a54a2-6a4c-4b9e-8f45-3c2a1d0e9f11",
    )

    private fun remote(
        name: String,
        mode: dev.bridgey.android.remote.RemoteMode,
        session: dev.bridgey.android.remote.RemoteSessionState = remoteActive,
        keyboard: Boolean = false,
        volumeKeys: Boolean = false,
    ) = capture("$name-${if (dark()) "dark" else "light"}") {
        RemoteScreen(
            state = RemoteScreenState("Work MacBook", session, pointerSpeed = 3, volumeKeys = volumeKeys),
            actions = RemoteActions(),
            initialMode = mode,
            initialKeyboard = keyboard,
        )
    }

    /** Scrolled so the Remote control section (its label is item index 16) leads the page. */
    private fun settingsRemote() = capture(if (dark()) "settings-remote-dark" else "settings-remote-light") {
        SettingsScreen(
            state = settingsState().copy(globalFeatures = settingsState().globalFeatures + (BridgeyFeature.REMOTE_INPUT to true), remoteVolumeKeys = true),
            actions = SettingsActions(),
            listState = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = 16),
        )
    }

    @Test fun remoteTouchpadLight() = remote("remote-touchpad", dev.bridgey.android.remote.RemoteMode.TOUCHPAD)

    @Test @Config(qualifiers = "+night") fun remoteTouchpadDark() = remote("remote-touchpad", dev.bridgey.android.remote.RemoteMode.TOUCHPAD)

    @Test fun remoteKeyboardLight() = remote("remote-keyboard", dev.bridgey.android.remote.RemoteMode.TOUCHPAD, keyboard = true)

    @Test @Config(qualifiers = "+night") fun remoteKeyboardDark() = remote("remote-keyboard", dev.bridgey.android.remote.RemoteMode.TOUCHPAD, keyboard = true)

    @Test fun remoteSlidesLight() = remote("remote-slides", dev.bridgey.android.remote.RemoteMode.PRESENTATION, volumeKeys = true)

    @Test @Config(qualifiers = "+night") fun remoteSlidesDark() = remote("remote-slides", dev.bridgey.android.remote.RemoteMode.PRESENTATION, volumeKeys = true)

    @Test fun remoteNotAllowedLight() = remote(
        "remote-not-allowed", dev.bridgey.android.remote.RemoteMode.TOUCHPAD,
        session = dev.bridgey.android.remote.RemoteSessionState.Ended("work", dev.bridgey.android.remote.RemoteStopReason.PERMISSION_REQUIRED),
    )

    @Test @Config(qualifiers = "+night") fun remoteNotAllowedDark() = remote(
        "remote-not-allowed", dev.bridgey.android.remote.RemoteMode.TOUCHPAD,
        session = dev.bridgey.android.remote.RemoteSessionState.Ended("work", dev.bridgey.android.remote.RemoteStopReason.PERMISSION_REQUIRED),
    )

    @Test fun settingsRemoteLight() = settingsRemote()

    @Test @Config(qualifiers = "+night") fun settingsRemoteDark() = settingsRemote()

    private fun dark(): Boolean =
        ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES

    @Test fun homeLight() = home()

    @Test @Config(qualifiers = "+night") fun homeDark() = home()

    @Test fun deviceActivityLight() = device(DeviceTab.ACTIVITY)

    @Test @Config(qualifiers = "+night") fun deviceActivityDark() = device(DeviceTab.ACTIVITY)

    @Test fun devicePermissionsLight() = device(DeviceTab.PERMISSIONS)

    @Test @Config(qualifiers = "+night") fun devicePermissionsDark() = device(DeviceTab.PERMISSIONS)

    @Test fun settingsLight() = settings()

    @Test @Config(qualifiers = "+night") fun settingsDark() = settings()

    @Test fun settingsClipboardLight() = settingsClipboard()

    @Test @Config(qualifiers = "+night") fun settingsClipboardDark() = settingsClipboard()
}
