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
import dev.bridgey.android.AndroidUpdate
import dev.bridgey.android.BackgroundClipboardStatus
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingState
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.UpdateChannel
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

/** A Settings state with every section filled in, as on a paired phone. */
internal fun sampleSettingsState(now: Long) = SettingsState(
    deviceName = "OnePlus 11",
    connectionStatus = "Connected to Work MacBook",
    connected = true,
    pairedCount = 3,
    globalFeatures = BridgeyFeature.entries.associateWith { it != BridgeyFeature.MEDIA && it != BridgeyFeature.REMOTE_INPUT },
    directCallsEnabled = false,
    autoClipboardEnabled = true,
    backgroundClipboardEnabled = false,
    backgroundClipboardStatus = BackgroundClipboardStatus.OFF,
    backgroundClipboardCommand = "",
    tileAddSupported = true,
    tileAdded = true,
    notificationAppsEnabled = 12,
    notificationAppsTotal = 48,
    appNotificationsEnabled = true,
    notificationAccessEnabled = true,
    reduceMotion = false,
    showPreviews = true,
    activityCount = 6,
    update = UpdateUiState(channel = UpdateChannel.BETA, lastCheckedAt = now - 10 * 60_000),
    installedVersion = "0.6.0-rr.1-beta.9",
    now = now,
    keepWifiAwakeSupported = true,
    folders = FolderSettingsState(
        places = listOf(
            SheetPlace("default", "Download/Bridgey", true, isDefault = true),
            SheetPlace("q3Jx0bVv1eG7tq8Wm2l5wA", "Pictures", true, storageTitle = "Internal storage"),
        ),
        defaultPlaceId = "default",
    ),
    rings = deviceRings(sampleTrusted, emptyList(), PairingState.Connected("work", "Work MacBook")),
    // Three Macs: Clipboard and Files on for two, everything else on for all; Links off on the Mac mini's side.
    devices = sampleTrusted.map { device ->
        SettingsDevice(
            device.id, device.name,
            on = BridgeyFeature.entries.associateWith { feature ->
                !(device.id == "mini" && (feature == BridgeyFeature.CLIPBOARD || feature == BridgeyFeature.FILES))
            },
            remoteOff = if (device.id == "mini") setOf(BridgeyFeature.LINKS) else emptySet(),
        )
    },
)

/** The sample's paired Macs. */
internal val sampleTrusted = listOf(TrustedDevice("work", "Work MacBook"), TrustedDevice("personal", "Personal Mac"), TrustedDevice("mini", "Mac mini"))

/**
 * Settings home and every section page at the design's 412 x 915 dp phone size, light and dark.
 * Always rendered (a crash fails the build); PNGs are written only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class SettingsPagesScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 26, 16, 5, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
    private val state get() = sampleSettingsState(now)

    private val update = AndroidUpdate(
        UpdateChannel.BETA, "0.6.0-rr.1-beta.10", 610, "https://github.com/round-robin-solutions/bridgey/releases/tag/v0.6.0-rr.1-beta.10",
        "- Settings are pages now.", "https://github.com/round-robin-solutions/bridgey/releases/download/x.apk", "a".repeat(64), 15_200_000, 26,
    )

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun dark(): Boolean =
        ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES

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
            val theme = if (dark()) "dark" else "light"
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/android-settings-$name-$theme.png") }
        }
    }

    private fun page(section: SettingsSection?, name: String = section?.name?.lowercase()?.replace('_', '-') ?: "home", state: SettingsState = this.state) =
        capture(name) { SettingsScreen(state = state, actions = SettingsActions(), section = section) }

    @Test fun homeLight() = page(null)

    @Test @Config(qualifiers = "+night") fun homeDark() = page(null)

    /** An update is ready (the dot), the phone may sleep Bridgey, and forwarding lacks access. */
    @Test fun homeAttentionLight() = page(null, "home-attention", attention())

    @Test @Config(qualifiers = "+night") fun homeAttentionDark() = page(null, "home-attention", attention())

    private fun attention() = state.copy(
        update = state.update.copy(available = update),
        batteryExempt = false,
        notificationAccessEnabled = false,
        connected = false,
        connectionStatus = "Not connected",
    )

    /** A group's page, from the top, with every card's More options closed. */
    private fun group(group: SettingsGroup, state: SettingsState = this.state) =
        capture("group-${group.name.lowercase()}") { SettingsScreen(state = state, actions = SettingsActions(), group = group) }

    @Test fun devicesLight() = group(SettingsGroup.DEVICES, connected())

    @Test @Config(qualifiers = "+night") fun devicesDark() = group(SettingsGroup.DEVICES, connected())

    @Test fun sharingLight() = group(SettingsGroup.SHARING)

    @Test @Config(qualifiers = "+night") fun sharingDark() = group(SettingsGroup.SHARING)

    @Test fun phoneLight() = group(SettingsGroup.PHONE)

    @Test @Config(qualifiers = "+night") fun phoneDark() = group(SettingsGroup.PHONE)

    @Test fun controlLight() = group(SettingsGroup.CONTROL, controls())

    @Test @Config(qualifiers = "+night") fun controlDark() = group(SettingsGroup.CONTROL, controls())

    @Test fun privacyLight() = group(SettingsGroup.PRIVACY)

    @Test @Config(qualifiers = "+night") fun privacyDark() = group(SettingsGroup.PRIVACY)

    @Test fun appLight() = group(SettingsGroup.APP)

    @Test @Config(qualifiers = "+night") fun appDark() = group(SettingsGroup.APP)

    private fun connected() = state.copy(connect = ConnectSettingsState(on = true, state = ConnectState.ONLINE, reachable = 2))

    private fun controls() = state.copy(globalFeatures = state.globalFeatures + (BridgeyFeature.REMOTE_INPUT to true))

    /** Each old page's card, the page opened at it with its More options open (as setup's links open it). */
    @Test fun clipboardLight() = page(SettingsSection.CLIPBOARD)

    @Test @Config(qualifiers = "+night") fun clipboardDark() = page(SettingsSection.CLIPBOARD)

    @Test fun filesLight() = page(SettingsSection.FILES)

    @Test @Config(qualifiers = "+night") fun filesDark() = page(SettingsSection.FILES)

    @Test fun notificationsLight() = page(SettingsSection.NOTIFICATIONS)

    @Test @Config(qualifiers = "+night") fun notificationsDark() = page(SettingsSection.NOTIFICATIONS)

    @Test fun updatesLight() = page(SettingsSection.UPDATES)

    @Test @Config(qualifiers = "+night") fun updatesDark() = page(SettingsSection.UPDATES)

    @Test fun connectAwayLight() = page(SettingsSection.AWAY, "connect-away", connected())

    @Test @Config(qualifiers = "+night") fun connectAwayDark() = page(SettingsSection.AWAY, "connect-away", connected())
}

/** Every group's whole page, every card's More options closed, on a very tall phone screen: what each group holds. */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h2400dp-port-xhdpi")
class SettingsGroupsFullScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 26, 16, 5, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun night(): Boolean =
        ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES

    private fun all() {
        val state = sampleSettingsState(now).copy(
            connect = ConnectSettingsState(on = true, state = ConnectState.ONLINE, reachable = 2),
            developerMenu = false,
        )
        SettingsGroup.entries.forEach { group ->
            ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.enableEdgeToEdge()
                    activity.setContent { BridgeyTheme { SettingsScreen(state = state, actions = SettingsActions(), group = group) } }
                    val density = activity.resources.displayMetrics.density
                    val insets = WindowInsetsCompat.Builder()
                        .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, (40 * density).toInt(), 0, 0))
                        .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, (24 * density).toInt()))
                        .build()
                    ViewCompat.dispatchApplyWindowInsets(activity.window.decorView, insets)
                }
                repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
                val directory = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"
                val theme = if (night()) "dark" else "light"
                scenario.onActivity { it.window.decorView.captureRoboImage("$directory/android-settings-group-${group.name.lowercase()}-full-$theme.png") }
            }
        }
    }

    @Test fun lightAll() = all()

    @Test @Config(qualifiers = "+night") fun darkAll() = all()
}
