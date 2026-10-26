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
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.FileTransferState
import dev.bridgey.android.PairingState
import dev.bridgey.android.TransferKind
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.folders.ConflictChoice
import dev.bridgey.android.folders.FolderFailure
import dev.bridgey.android.folders.FolderPolicy
import dev.bridgey.android.folders.FolderQuestion
import dev.bridgey.android.folders.FolderSnapshot
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
 * Files 2.0 on the phone, light and dark, at the design's 412 x 915 dp: the Save to… sheet, the conflict
 * question, the Stream with a folder live card (and opened), and the Files settings rows. PNGs only with
 * -Pscreenshots=<dir>; always rendered, so a crash fails the build.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class FolderScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 26, 9, 41, 20)
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
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            val directory = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/$name.png") }
        }
    }

    private val trusted = listOf(TrustedDevice("work", "MacBook Pro"), TrustedDevice("personal", "Personal Mac"))
    private val peers = listOf(DiscoveredPeer("personal-svc", "personal", "Personal Mac", "macos", 1, "10.0.0.3", 42_458))
    private val rings get() = deviceRings(trusted, peers, PairingState.Connected("work", "MacBook Pro"))
    private fun nameFor(item: ActivityItem) = rings.firstOrNull { it.deviceId == item.deviceId }?.name ?: item.deviceName

    private val activity get() = listOf(
        ActivityItem(
            9, ActivityKind.FOLDER_RECEIVED, "personal", "Personal Mac", "Holiday 2026", null, null, false, false, 1, at(9, 20),
            bytes = 1_240_000_000, fileCount = 48, destination = "Pictures", detail = "merged=3,links=2,hidden=12",
        ),
        ActivityItem(8, ActivityKind.CLIPBOARD_SENT, "work", "MacBook Pro", null, "Room 2 at 4, bring the deck", null, false, false, 1, at(9, 14)),
        ActivityItem(
            7, ActivityKind.FOLDER_INCOMPLETE, "work", "MacBook Pro", "Invoices", null, null, false, false, 1, at(9, 2),
            bytes = 0, fileCount = 0, destination = null, detail = "timeout",
        ),
        ActivityItem(6, ActivityKind.FILE_RECEIVED, "personal", "Personal Mac", "invoice-oct.pdf", null, null, false, false, 1, at(8, 50)),
        ActivityItem(5, ActivityKind.NOTIFICATIONS_SHOWN, "work", "MacBook Pro", null, null, "WhatsApp", false, false, 4, at(8, 41)),
    )

    private val folder = FolderSnapshot(
        folderTransferId = "4b0c9d5e-1111-4222-8333-944455556666",
        deviceId = "work",
        deviceName = "MacBook Pro",
        rootName = "Photos",
        filesTotal = 124,
        bytesTotal = 2_469_606_195,
        filesDone = 37,
        bytesDone = 851_443_712,
        destinationLabel = "Pictures/Trip",
        choice = ConflictChoice.MERGE,
        currentFile = "IMG_0412.HEIC",
        currentFileBytes = 1_900_000,
        currentFileSize = 3_400_000,
        failures = listOf(FolderFailure(12, "IMG_0101.HEIC", "verification_failed")),
        failedCount = 1,
        recent = (370..410).map { "IMG_0%03d.HEIC".format(it) },
        bytesPerSecond = 12_582_912,
    )

    private fun folderCard(expanded: Boolean) = LiveCard.Transfer(
        FileTransferState(
            folder.folderTransferId, "Photos", "Receiving folder", true, 34, startedAtMillis = at(9, 38),
            deviceId = "work", deviceName = "MacBook Pro", kind = TransferKind.FOLDER, folder = folder,
        ),
        expanded = expanded,
    )

    private fun stream(name: String, expanded: Boolean) = capture(name) {
        val rings = rings
        HomeScreen(
            state = HomeState(
                rings = rings,
                target = sendTarget(rings, null),
                activity = activity,
                live = listOf(folderCard(expanded)),
                canSendClipboard = true,
                now = now,
            ),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = ::nameFor,
        )
    }

    private val places = listOf(
        SheetPlace("default", "Download/Bridgey", true, isDefault = true),
        SheetPlace("q3Jx0bVv1eG7tq8Wm2l5wA", "Pictures", true, storageTitle = "Internal storage"),
        SheetPlace("Zx9dP0aB1cD2eF3gH4iJ5k", "Documents", true, storageTitle = "Internal storage"),
        SheetPlace("Kq7Lm8Nn9Oo0Pp1Qq2Rr3s", "Trip (USB drive)", false, storageTitle = "USB drive"),
    )
    private val recent = listOf(
        SheetRecent("q3Jx0bVv1eG7tq8Wm2l5wA", "Trip", "Pictures/Trip"),
        SheetRecent("Zx9dP0aB1cD2eF3gH4iJ5k", "Work/2026", "Documents/Work/2026"),
    )

    /** The sheet over the Stream behind a scrim, as Bridgey shows it while open. */
    private fun sheet(name: String, question: FolderQuestion) = capture(name) {
        Box(Modifier.fillMaxSize()) {
            val rings = rings
            HomeScreen(
                state = HomeState(rings = rings, target = sendTarget(rings, null), activity = activity, live = emptyList(), canSendClipboard = true, now = now),
                actions = HomeActions(),
                snackbar = remember { SnackbarHostState() },
                deviceName = ::nameFor,
            )
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f)))
            Box(Modifier.align(Alignment.BottomCenter)) {
                FolderSheetSurface {
                    FolderQuestionSheet(
                        question, places, recent, FolderSheetActions(),
                        Modifier.padding(bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()),
                    )
                }
            }
        }
    }

    private val saveTo get() = FolderQuestion(
        folder.folderTransferId, "work", "MacBook Pro", "Photos", 124, 2_469_606_195, FolderQuestion.Kind.DESTINATION,
        deadlineMillis = now + 161_000, reason = FolderPolicy.AskReason.MODE,
    )

    private val conflict get() = FolderQuestion(
        folder.folderTransferId, "work", "MacBook Pro", "Photos", 124, 2_469_606_195, FolderQuestion.Kind.CONFLICT,
        deadlineMillis = now + 161_000, existing = FolderPolicy.Existing.FOLDER, destinationLabel = "Pictures/Trip",
        clashingFiles = 12, newFolderName = "Photos (1)", choices = listOf(ConflictChoice.MERGE, ConflictChoice.REPLACE, ConflictChoice.NEW_FOLDER),
    )

    private fun settingsFiles() = capture("android-settings-files-${theme()}") {
        SettingsScreen(
            state = SettingsState(
                deviceName = "OnePlus 11",
                connectionStatus = "Connected to MacBook Pro",
                connected = true,
                pairedCount = 2,
                globalFeatures = BridgeyFeature.entries.associateWith { true },
                directCallsEnabled = true,
                autoClipboardEnabled = true,
                backgroundClipboardEnabled = true,
                backgroundClipboardStatus = dev.bridgey.android.BackgroundClipboardStatus.READY,
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
                update = UpdateUiState(channel = UpdateChannel.STABLE, lastCheckedAt = now - 10 * 60_000),
                installedVersion = "0.7.0",
                now = now,
                folders = FolderSettingsState(places = places, defaultPlaceId = "default"),
            ),
            actions = SettingsActions(),
            // The Files section label leads the page.
            listState = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = 13),
        )
    }

    @Test fun saveToLight() = sheet("android-save-to-light", saveTo)

    @Test @Config(qualifiers = "+night") fun saveToDark() = sheet("android-save-to-dark", saveTo)

    @Test fun conflictLight() = sheet("android-conflict-light", conflict)

    @Test @Config(qualifiers = "+night") fun conflictDark() = sheet("android-conflict-dark", conflict)

    @Test fun streamFolderLight() = stream("android-stream-folder-light", expanded = false)

    @Test @Config(qualifiers = "+night") fun streamFolderDark() = stream("android-stream-folder-dark", expanded = false)

    @Test fun streamFolderExpandedLight() = stream("android-stream-folder-expanded-light", expanded = true)

    @Test fun settingsFilesLight() = settingsFiles()

    @Test @Config(qualifiers = "+night") fun settingsFilesDark() = settingsFiles()

    @Test fun confirmReplaceLight() = sheet(
        "android-conflict-confirm-light",
        conflict.copy(confirmsRemoteReplace = true),
    )
}
