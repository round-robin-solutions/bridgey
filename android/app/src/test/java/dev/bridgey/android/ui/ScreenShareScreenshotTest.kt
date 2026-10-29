package dev.bridgey.android.ui

import android.app.Application
import android.app.Notification
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
import dev.bridgey.android.screen.ScreenNotifier
import dev.bridgey.android.screen.ScreenRequest
import dev.bridgey.android.screen.ScreenShareState
import dev.bridgey.android.screen.ScreenStats
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.setup.OemBattery
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.core.discovery.DiscoveredPeer
import java.util.Calendar
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Share screen with Macs, light and dark, at the design's phone size: the Settings switch, the device page's
 * Share screen and running share, the request and sharing notifications, and the setup question. Always
 * rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class ScreenShareScreenshotTest {
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

    private val trusted = listOf(TrustedDevice("work", "Work MacBook"))
    private val peers = listOf(DiscoveredPeer("work-svc", "work", "Work MacBook", "macos", 1, "10.0.0.3", 42_458))
    private val ring get() = deviceRings(trusted, peers, PairingState.Connected("work", "Work MacBook")).first()

    private fun device(name: String, screen: ScreenShareState?) = capture(name) {
        DeviceScreen(
            state = DeviceState(
                ring = ring,
                battery = RemoteBatteryStatus(76, isCharging = true),
                connected = true,
                available = setOf(BridgeyFeature.CLIPBOARD, BridgeyFeature.FILES, BridgeyFeature.LINKS, BridgeyFeature.PING, BridgeyFeature.FIND_DEVICE, BridgeyFeature.SCREEN),
                ringing = false,
                permissions = emptyList(),
                notificationAccess = true,
                notificationAppsEnabled = 12,
                autoClipboard = true,
                autoClipboardGlobalOn = true,
                activity = emptyList(),
                live = emptyList(),
                now = now,
                screen = screen,
            ),
            actions = DeviceActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
        )
    }

    @Test fun deviceShareLight() = device("screen-device-share", null)

    @Test @Config(qualifiers = "+night") fun deviceShareDark() = device("screen-device-share", null)

    private val sharing = ScreenShareState(
        ScreenShareState.Phase.SHARING, "work", "Work MacBook",
        ScreenStats(latencyMs = 46, rttMs = 6, bitrate = 4_000_000, sentBitrate = 2_100_000, fps = 30, dropped = 0),
    )

    @Test fun deviceSharingLight() = device("screen-device-sharing", sharing)

    @Test @Config(qualifiers = "+night") fun deviceSharingDark() = device("screen-device-sharing", sharing)

    private fun settings() = capture("screen-settings-media") {
        val state = sampleSettingsState(now).let { it.copy(globalFeatures = it.globalFeatures + (BridgeyFeature.SCREEN to true)) }
        SettingsScreen(state = state, actions = SettingsActions(), section = SettingsSection.MEDIA)
    }

    @Test fun settingsLight() = settings()

    @Test @Config(qualifiers = "+night") fun settingsDark() = settings()

    /** The Remote control bundle picks remote control, Mac actions and screen sharing; past the volume keys card. */
    private val atScreenQuestion: SetupState
        get() {
            val facts = facts()
            val started = SetupFlow.reduce(
                SetupFlow.reduce(SetupState(), SetupEvent.ChooseAdvanced, facts),
                SetupEvent.StartQuestions(SetupBundles.answers(setOf("remote"), emptyMap())), facts,
            )
            return SetupFlow.reduce(started, SetupEvent.NotNow, facts)
        }

    private fun facts() = SetupFacts(
        paired = true,
        current = SetupFeatures.all.flatMap { it.settings }.associateWith { "false" },
        granted = setOf(PermissionKind.POST_NOTIFICATIONS),
    )

    private fun question() = capture("screen-setup-question") {
        SetupScreen(
            SetupUiState(atScreenQuestion, sampleSettingsState(now), listOf("Work MacBook"), emptyList(), OemBattery.checklist("OnePlus", "OnePlus"), facts = facts()),
            SetupActions(),
        )
    }

    @Test fun setupQuestionIsTheScreenCard() {
        assertEquals(dev.bridgey.android.setup.SetupScreen.Question("screen"), atScreenQuestion.screen)
    }

    @Test fun setupQuestionLight() = question()

    @Test @Config(qualifiers = "+night") fun setupQuestionDark() = question()

    /** A notification through Android's own template, as the shade inflates it. */
    private fun notification(name: String, build: (android.content.Context) -> Notification) {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val density = activity.resources.displayMetrics.density
                val notification = build(activity)
                val views = Notification.Builder.recoverBuilder(activity, notification).createBigContentView()
                    ?: Notification.Builder.recoverBuilder(activity, notification).createContentView()
                val frame = FrameLayout(activity).apply {
                    setBackgroundColor(if (dark()) 0xFF1B1F27.toInt() else 0xFFF2F4F8.toInt())
                    setPadding((16 * density).toInt(), (16 * density).toInt(), (16 * density).toInt(), (16 * density).toInt())
                }
                val inflated = views.apply(activity, frame)
                frame.addView(inflated, FrameLayout.LayoutParams((380 * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
                activity.setContentView(frame, ViewGroup.LayoutParams((412 * density).toInt(), ViewGroup.LayoutParams.WRAP_CONTENT))
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            scenario.onActivity { (it.findViewById<ViewGroup>(android.R.id.content).getChildAt(0)).captureRoboImage("$directory/android-$name-$theme.png") }
        }
    }

    private val request = ScreenRequest("work", "Work MacBook", "8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e", now)

    private fun ask() = notification("screen-notification-request") { context ->
        ScreenNotifier.showAsk(context, request)
        shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.last()
    }

    @Test fun requestLight() = ask()

    @Test @Config(qualifiers = "+night") fun requestDark() = ask()

    private fun sharingNotification() = notification("screen-notification-sharing") { context -> ScreenNotifier.sharing(context, "Work MacBook", sharing = true) }

    @Test fun sharingLight() = sharingNotification()

    @Test @Config(qualifiers = "+night") fun sharingDark() = sharingNotification()
}
