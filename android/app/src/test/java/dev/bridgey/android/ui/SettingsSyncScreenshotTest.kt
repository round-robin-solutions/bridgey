package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.lazy.rememberLazyListState
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
import com.github.takahirom.roborazzi.captureScreenRoboImage
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingState
import dev.bridgey.android.RemoteBatteryStatus
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.sync.SyncChange
import dev.bridgey.android.sync.SyncDetail
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.SyncRowStatus
import dev.bridgey.android.sync.SyncSwitches
import dev.bridgey.android.sync.SyncUiState
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
 * Settings sync: the General card, Choose what syncs, a feature that differs on a Mac (Apply to all), one waiting
 * for a permission here and one waiting on the Mac, the device page switch and the activity item, light and dark.
 * Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class SettingsSyncScreenshotTest {
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

    private fun capture(name: String, dialog: Boolean = false, content: @Composable () -> Unit) {
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
            val file = "$directory/android-settings-sync-$name-$theme.png"
            if (dialog) captureScreenRoboImage(file) else scenario.onActivity { it.window.decorView.captureRoboImage(file) }
        }
    }

    private val sync = SyncUiState(
        switches = SyncSwitches(excluded = setOf(SyncKey.LINKS, SyncKey.FOCUS_FOLLOW)),
        rows = mapOf(
            SyncKey.CALLS to SyncRowStatus(differentOn = listOf("Work MacBook")),
            SyncKey.NOTIFICATIONS to SyncRowStatus(waitingHere = true),
            SyncKey.REMOTE_INPUT to SyncRowStatus(waitingOn = listOf("Work MacBook")),
            SyncKey.REDUCE_MOTION to SyncRowStatus(differentOn = listOf("Work MacBook", "Personal Mac")),
        ),
    )

    private fun settings(section: SettingsSection, name: String, first: Int = 0) = capture(name) {
        SettingsScreen(
            state = sampleSettingsState(now).copy(
                sync = sync,
                globalFeatures = BridgeyFeature.entries.associateWith { it != BridgeyFeature.MEDIA },
                notificationAccessEnabled = false,
            ),
            actions = SettingsActions(),
            listState = rememberLazyListState(initialFirstVisibleItemIndex = first),
            section = section,
        )
    }

    @Test fun generalLight() = settings(SettingsSection.GENERAL, "general", first = 3)

    @Test @Config(qualifiers = "+night") fun generalDark() = settings(SettingsSection.GENERAL, "general", first = 3)

    @Test fun differentLight() = settings(SettingsSection.CALLS, "different")

    @Test @Config(qualifiers = "+night") fun differentDark() = settings(SettingsSection.CALLS, "different")

    @Test fun waitingLight() = settings(SettingsSection.NOTIFICATIONS, "waiting")

    @Test @Config(qualifiers = "+night") fun waitingDark() = settings(SettingsSection.NOTIFICATIONS, "waiting")

    @Test fun waitingOnMacLight() = settings(SettingsSection.REMOTE_CONTROL, "waiting-on-mac")

    @Test @Config(qualifiers = "+night") fun waitingOnMacDark() = settings(SettingsSection.REMOTE_CONTROL, "waiting-on-mac")

    private fun choose() = capture("choose", dialog = true) {
        ChooseWhatSyncsDialog(sync, SyncSettingsActions()) {}
    }

    /** First connect: the question over the Settings page it appears on. */
    private fun firstConnect() = capture("first-connect", dialog = true) {
        SettingsScreen(state = sampleSettingsState(now).copy(sync = sync), actions = SettingsActions(), section = SettingsSection.GENERAL)
        FirstConnectQuestion("Work MacBook", onUse = {}, onKeep = {})
    }

    @Test fun firstConnectLight() = firstConnect()

    @Test @Config(qualifiers = "+night") fun firstConnectDark() = firstConnect()

    @Test fun chooseLight() = choose()

    @Test @Config(qualifiers = "+night") fun chooseDark() = choose()

    private val trusted = listOf(TrustedDevice("work", "Work MacBook"), TrustedDevice("personal", "Personal Mac"))
    private val rings get() = deviceRings(trusted, emptyList(), PairingState.Connected("work", "Work MacBook"))

    private val activity get() = listOf(
        ActivityItem(
            4, ActivityKind.SETTINGS_SYNCED, "work", "Work MacBook", null, null, null, false, false, 1, now - 40_000,
            detail = SyncDetail.encode(listOf(SyncChange(SyncKey.CALLS, true), SyncChange(SyncKey.REDUCE_MOTION, false))),
        ),
        ActivityItem(3, ActivityKind.CLIPBOARD_SENT, "work", "Work MacBook", null, "Room 2 at 4, bring the deck", null, false, false, 1, now - 600_000),
        ActivityItem(
            2, ActivityKind.SETTINGS_SYNCED, "work", "Work MacBook", null, null, null, false, false, 1, now - 3_600_000,
            detail = SyncDetail.encode(listOf(SyncChange(SyncKey.FOLDER_CONFLICT, "merge"))),
        ),
        ActivityItem(1, ActivityKind.FILE_RECEIVED, "work", "Work MacBook", "invoice-oct.pdf", null, null, false, false, 1, now - 7_200_000),
    )

    private fun device(tab: DeviceTab, name: String, ringIndex: Int = 0, sync: DeviceSyncState) = capture(name) {
        val ring = rings[ringIndex]
        DeviceScreen(
            state = DeviceState(
                ring = ring,
                battery = RemoteBatteryStatus(76, isCharging = true),
                connected = true,
                available = BridgeyFeature.entries.toSet() - BridgeyFeature.MEDIA - BridgeyFeature.REMOTE_INPUT,
                ringing = false,
                permissions = listOf(
                    listOf(BridgeyFeature.CLIPBOARD), listOf(BridgeyFeature.FILES), listOf(BridgeyFeature.NOTIFICATIONS),
                ).map { PermissionRow(it, checked = true, globallyOff = false, remotelyOff = false) },
                notificationAccess = true,
                notificationAppsEnabled = 12,
                autoClipboard = true,
                autoClipboardGlobalOn = false,
                activity = activity,
                live = emptyList(),
                now = now,
                sync = sync,
            ),
            actions = DeviceActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
            initialTab = tab,
        )
    }

    @Test fun deviceLight() = device(DeviceTab.PERMISSIONS, "device", sync = DeviceSyncState(on = true, globalOn = true, offRemote = false))

    @Test @Config(qualifiers = "+night") fun deviceDark() =
        device(DeviceTab.PERMISSIONS, "device", sync = DeviceSyncState(on = true, globalOn = true, offRemote = false))

    @Test fun deviceOffOnMacLight() = device(DeviceTab.PERMISSIONS, "device-off-on-mac", sync = DeviceSyncState(on = true, globalOn = true, offRemote = true))

    @Test fun activityLight() = device(DeviceTab.ACTIVITY, "activity", sync = DeviceSyncState(on = true, globalOn = true, offRemote = false))

    @Test @Config(qualifiers = "+night") fun activityDark() =
        device(DeviceTab.ACTIVITY, "activity", sync = DeviceSyncState(on = true, globalOn = true, offRemote = false))
}
