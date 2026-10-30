package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.AndroidUpdate
import dev.bridgey.android.DeviceConnection
import dev.bridgey.android.DeviceLinkState
import dev.bridgey.android.PairingState
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.updates.AutoCondition
import dev.bridgey.android.updates.AutoRunRecord
import dev.bridgey.android.updates.AutoUpdateView
import dev.bridgey.android.updates.LOCAL_DEVICE_ID
import dev.bridgey.android.updates.UpdateBusy
import dev.bridgey.android.updates.PeerUpdateInfo
import dev.bridgey.android.updates.RunFailure
import dev.bridgey.android.updates.RunItem
import dev.bridgey.android.updates.RunStep
import dev.bridgey.android.updates.UpdatePlatform
import dev.bridgey.android.updates.UpdateReason
import dev.bridgey.android.updates.UpdateRun
import dev.bridgey.android.updates.UpdateState
import dev.bridgey.android.updates.UpdateStatus
import dev.bridgey.android.updates.WireChannel
import dev.bridgey.android.updates.deviceUpdateRows
import dev.bridgey.android.updates.planUpdateAll
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
 * Update all on the phone, light and dark at 412 x 915 dp: the preview, a run in progress (one Mac
 * downloading, one taking longer than usual, one installing), the finished run, "needs you" (this
 * phone waits for Android's confirmation), and Settings > Updates > Your devices. PNGs only with
 * -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class UpdateAllScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 27, 16, 5, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private val beta2 = "0.9.0-rr.3-beta.2"
    private val beta3 = "0.9.0-rr.3-beta.3"

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun dark(): Boolean =
        ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES

    private fun theme() = if (dark()) "dark" else "light"

    private fun capture(name: String, content: @Composable () -> Unit) {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.enableEdgeToEdge()
                activity.setContent { BridgeyTheme { CompositionLocalProvider(LocalNow provides { now }) { content() } } }
                val density = activity.resources.displayMetrics.density
                val insets = WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, (40 * density).toInt(), 0, 0))
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, (24 * density).toInt()))
                    .build()
                ViewCompat.dispatchApplyWindowInsets(activity.window.decorView, insets)
            }
            repeat(4) { shadowOf(Looper.getMainLooper()).idle() }
            val directory = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/$name.png") }
        }
    }

    private fun mac(
        state: UpdateState,
        app: String = beta2,
        build: Long = 903002,
        channel: WireChannel = WireChannel.BETA,
        target: String? = beta3,
        targetBuild: Long? = 903003,
        remoteStart: Boolean = true,
    ) = UpdateStatus(UpdatePlatform.MACOS, "rr", app, build, channel, state, target, targetBuild, null, null, remoteStart, now - 20 * 60_000)

    private val local = UpdateStatus(UpdatePlatform.ANDROID, "rr", beta2, 903002, WireChannel.BETA, UpdateState.AVAILABLE, beta3, 903003, null, null, true, now - 5 * 60_000)

    private val peers = listOf(
        PeerUpdateInfo("m", "MacBook Pro", true, true, mac(UpdateState.AVAILABLE)),
        PeerUpdateInfo("w", "Work Mac", true, true, mac(UpdateState.AVAILABLE, app = "0.9.0-rr.2", build = 902000, channel = WireChannel.STABLE, target = "0.9.0-rr.3", targetBuild = 903000)),
        PeerUpdateInfo("s", "Studio Mac", false, true, null),
        PeerUpdateInfo("o", "Old iMac", true, false, null),
    )

    private val plan = planUpdateAll(local, "This phone", peers, now)

    private val trusted = listOf(TrustedDevice("m", "MacBook Pro"), TrustedDevice("w", "Work Mac"), TrustedDevice("s", "Studio Mac"), TrustedDevice("o", "Old iMac"))
    private val rings = deviceRings(
        trusted, emptyList(),
        listOf("m", "w", "o").map { id -> DeviceConnection(id, trusted.first { it.id == id }.name, DeviceLinkState()) },
        PairingState.Idle,
    )

    private fun item(
        id: String,
        name: String,
        step: RunStep,
        platform: UpdatePlatform = UpdatePlatform.MACOS,
        startedMinutesAgo: Long = 1,
        progress: Int? = null,
        channel: WireChannel = WireChannel.BETA,
        fromApp: String = beta2,
        targetApp: String = beta3,
        newApp: String? = null,
        failure: RunFailure? = null,
        needs: UpdateReason? = null,
    ) = RunItem(
        id, name, fromApp, 903002, targetApp, 903003, channel, platform, step, progress, needs, failure, newApp, "r-$id",
        startedAt = now - startedMinutesAgo * 60_000, stepSince = now - 30_000,
    )

    private fun run(vararg items: RunItem, restartAt: Long? = null) = UpdateRun("run", now - 5 * 60_000, items.toList(), restartAt = restartAt)

    private val progress = run(
        item("m", "MacBook Pro", RunStep.DOWNLOADING, progress = 42),
        item("x", "Mac mini", RunStep.CHECKING, startedMinutesAgo = 4),
        item("w", "Work Mac", RunStep.INSTALLING, channel = WireChannel.STABLE, fromApp = "0.9.0-rr.2", targetApp = "0.9.0-rr.3"),
        item(LOCAL_DEVICE_ID, "This phone", RunStep.DOWNLOADING, UpdatePlatform.ANDROID, progress = 64),
    )

    private val done = run(
        item("m", "MacBook Pro", RunStep.DONE, newApp = beta3),
        item("x", "Mac mini", RunStep.NOT_APPLIED),
        item("w", "Work Mac", RunStep.DONE, channel = WireChannel.STABLE, fromApp = "0.9.0-rr.2", targetApp = "0.9.0-rr.3", newApp = "0.9.0-rr.3"),
        item(LOCAL_DEVICE_ID, "This phone", RunStep.DONE, UpdatePlatform.ANDROID, newApp = beta3),
    )

    private val needsYou = run(
        item("m", "MacBook Pro", RunStep.DONE, newApp = beta3),
        item("w", "Work Mac", RunStep.RESTARTING, channel = WireChannel.STABLE, fromApp = "0.9.0-rr.2", targetApp = "0.9.0-rr.3"),
        item(LOCAL_DEVICE_ID, "This phone", RunStep.NEEDS_USER, UpdatePlatform.ANDROID, needs = UpdateReason.CONFIRM),
    )

    private fun uiState(run: UpdateRun?) = UpdateAllUiState(plan = plan, run = run, now = now, devices = deviceUpdateRows(local, "This phone", peers))

    /** The sheet over Home (with its Update all card) behind a scrim, as Bridgey shows it. */
    private fun sheet(name: String, run: UpdateRun?) = capture("android-update-all-$name-${theme()}") {
        val state = uiState(run)
        Box(Modifier.fillMaxSize()) {
            HomeScreen(
                state = HomeState(rings = rings, target = sendTarget(rings, null), activity = emptyList(), live = listOf(LiveCard.UpdateAll(state)), canSendClipboard = true, now = now),
                actions = HomeActions(),
                snackbar = remember { SnackbarHostState() },
                deviceName = { it.deviceName },
            )
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f)))
            Box(Modifier.align(Alignment.BottomCenter)) {
                FolderSheetSurface {
                    UpdateAllSheet(state, UpdateAllActions(), Modifier.padding(bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()))
                }
            }
        }
    }

    /** Home with the card alone: the entry point. */
    private fun home(name: String, run: UpdateRun?) = capture("android-update-all-$name-${theme()}") {
        HomeScreen(
            state = HomeState(rings = rings, target = sendTarget(rings, null), activity = emptyList(), live = listOf(LiveCard.UpdateAll(uiState(run))), canSendClipboard = true, now = now),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
        )
    }

    private fun settings(name: String, update: UpdateUiState, run: UpdateRun?) = capture("android-update-all-$name-${theme()}") {
        SettingsScreen(
            state = sampleSettingsState(now).copy(update = update, installedVersion = beta2, updateAll = uiState(run)),
            actions = SettingsActions(),
            section = SettingsSection.UPDATES,
        )
    }

    private val androidUpdate = AndroidUpdate(
        UpdateChannel.BETA, beta3, 903003, "https://github.com/round-robin-solutions/bridgey/releases/tag/v0.9.0-rr.3-beta.3",
        "", "https://github.com/round-robin-solutions/bridgey/releases/download/x.apk", "a".repeat(64), 15_200_000, 26,
    )
    private val updateState = UpdateUiState(channel = UpdateChannel.BETA, lastCheckedAt = now - 5 * 60_000, available = androidUpdate)

    @Test fun homeLight() = home("home", null)

    @Test @Config(qualifiers = "+night") fun homeDark() = home("home", null)

    @Test fun previewLight() = sheet("preview", null)

    @Test @Config(qualifiers = "+night") fun previewDark() = sheet("preview", null)

    @Test fun progressLight() = sheet("progress", progress)

    @Test @Config(qualifiers = "+night") fun progressDark() = sheet("progress", progress)

    @Test fun doneLight() = sheet("done", done)

    @Test @Config(qualifiers = "+night") fun doneDark() = sheet("done", done)

    @Test fun needsYouLight() = sheet("needs-you", needsYou)

    @Test @Config(qualifiers = "+night") fun needsYouDark() = sheet("needs-you", needsYou)

    @Test fun settingsLight() = settings("settings", updateState, null)

    @Test @Config(qualifiers = "+night") fun settingsDark() = settings("settings", updateState, null)

    // MARK: Update all devices automatically

    /** An automatic run: the Mac is done, this phone is ready and waits for a call, or counts down a minute. */
    private fun autoRun(hold: UpdateBusy? = null, restartAt: Long? = null) = UpdateRun(
        "auto", now - 3 * 60_000,
        listOf(
            item("m", "MacBook Pro", RunStep.DONE, newApp = beta3),
            item("w", "Work Mac", RunStep.DONE, channel = WireChannel.STABLE, fromApp = "0.9.0-rr.2", targetApp = "0.9.0-rr.3", newApp = "0.9.0-rr.3"),
            item(LOCAL_DEVICE_ID, "This phone", RunStep.READY, UpdatePlatform.ANDROID),
        ),
        restartAt = restartAt, auto = true, hold = hold,
    )

    private fun autoHome(name: String, run: UpdateRun) = capture("android-auto-update-$name-${theme()}") {
        HomeScreen(
            state = HomeState(rings = rings, target = sendTarget(rings, null), activity = emptyList(), live = listOf(LiveCard.UpdateAll(uiState(run))), canSendClipboard = true, now = now),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
        )
    }

    /** beta.3 is out and waits for the call on Work Mac; the last automatic run brought the devices to beta.2. */
    private val autoView = AutoUpdateView(
        on = true, channel = WireChannel.BETA,
        condition = AutoCondition.Waiting(UpdateBusy.CALL, "Work Mac"),
        lastRun = AutoRunRecord(now - 3 * 60 * 60_000, beta2, 2, 3, 1, later = false),
    )

    private fun autoSettings(name: String, view: AutoUpdateView, update: UpdateUiState = updateState) = capture("android-auto-update-$name-${theme()}") {
        SettingsScreen(
            state = sampleSettingsState(now).copy(
                update = update,
                installedVersion = beta2,
                updateAll = uiState(null).copy(auto = view),
            ),
            actions = SettingsActions(),
            section = SettingsSection.UPDATES,
        )
    }

    @Test fun autoHeldLight() = autoHome("held", autoRun(hold = UpdateBusy.CALL))

    @Test @Config(qualifiers = "+night") fun autoHeldDark() = autoHome("held", autoRun(hold = UpdateBusy.CALL))

    @Test fun autoCountdownLight() = autoHome("countdown", autoRun(restartAt = now + 42_000))

    @Test @Config(qualifiers = "+night") fun autoCountdownDark() = autoHome("countdown", autoRun(restartAt = now + 42_000))

    @Test fun autoSettingsLight() = autoSettings("settings", autoView)

    @Test @Config(qualifiers = "+night") fun autoSettingsDark() = autoSettings("settings", autoView)

    private val upToDate = UpdateUiState(channel = UpdateChannel.STABLE, lastCheckedAt = now - 4 * 60_000)

    @Test fun autoSettingsOffLight() = autoSettings("settings-off", AutoUpdateView(on = false, channel = WireChannel.STABLE), upToDate)

    @Test @Config(qualifiers = "+night") fun autoSettingsOffDark() = autoSettings("settings-off", AutoUpdateView(on = false, channel = WireChannel.STABLE), upToDate)

    @Test fun settingsNeedsYouLight() = settings("settings-needs-you", updateState.copy(awaitingConfirmation = true), needsYou)

    @Test @Config(qualifiers = "+night") fun settingsNeedsYouDark() = settings("settings-needs-you", updateState.copy(awaitingConfirmation = true), needsYou)
}
