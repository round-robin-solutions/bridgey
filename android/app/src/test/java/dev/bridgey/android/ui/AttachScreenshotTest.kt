package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
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
import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.MediaItem
import dev.bridgey.android.folders.FolderSnapshot
import dev.bridgey.android.folders.FolderWaiting
import dev.bridgey.android.ui.attach.AttachActions
import dev.bridgey.android.ui.attach.AttachFolder
import dev.bridgey.android.ui.attach.AttachKeys
import dev.bridgey.android.ui.attach.AttachSheetContent
import dev.bridgey.android.ui.attach.AttachState
import dev.bridgey.android.ui.attach.AttachTab
import dev.bridgey.android.ui.attach.AttachTarget
import dev.bridgey.android.ui.attach.LocalMediaThumbnails
import dev.bridgey.android.ui.attach.MediaThumbnails
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
 * Files 2.0, second slice, light and dark at 412 x 915 dp: the attach sheet's tabs (Photos and videos with picks,
 * partial access, the permission card; Files with the documents card and a list; Folders), Settings › Files with
 * the browse switch, and the Stream's outgoing folder and download cards. PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class AttachScreenshotTest {
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

    private fun theme() = if (dark()) "dark" else "light"

    private fun capture(name: String, content: @Composable () -> Unit) {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.enableEdgeToEdge()
                activity.setContent {
                    BridgeyTheme {
                        CompositionLocalProvider(LocalNow provides { now }, LocalMediaThumbnails provides SampleThumbnails) { content() }
                    }
                }
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

    /** Photo-like gradients instead of real photos: every cell already cached, as on a reopened sheet. */
    private object SampleThumbnails : MediaThumbnails {
        private val palettes = listOf(
            0xFF2E5E8C to 0xFFE8B86D, 0xFF3C7A5A to 0xFFB8E0A0, 0xFF8C3E5E to 0xFFF0B5A0, 0xFF1F2A44 to 0xFF6FA8DC,
            0xFF6B4E9B to 0xFFF2D7A6, 0xFF9A6B2F to 0xFFF6E3B4, 0xFF214B5E to 0xFF9ED5D1, 0xFF4A4A4A to 0xFFD9D9D9,
        )
        private val cache = HashMap<Long, ImageBitmap>()

        override fun cached(item: MediaItem): ImageBitmap = cache.getOrPut(item.mediaId) {
            val (start, end) = palettes[(item.mediaId % palettes.size).toInt()]
            val bitmap = Bitmap.createBitmap(160, 160, Bitmap.Config.ARGB_8888)
            val paint = Paint().apply { shader = LinearGradient(0f, 0f, 160f, 160f, start.toInt(), end.toInt(), Shader.TileMode.CLAMP) }
            Canvas(bitmap).drawRect(0f, 0f, 160f, 160f, paint)
            Paint().apply { color = 0x33FFFFFF }.let { Canvas(bitmap).drawCircle(50f + item.mediaId % 5 * 12, 60f, 26f, it) }
            bitmap.asImageBitmap()
        }

        override suspend fun load(item: MediaItem): ImageBitmap = cached(item)
        override fun prefetch(items: List<MediaItem>) = Unit
    }

    private val media = (1..24L).map { id ->
        val video = id % 5 == 2L
        MediaItem(
            mediaId = id, name = if (video) "VID_$id.mp4" else "IMG_$id.jpg", size = if (video) 48_000_000 else 3_100_000,
            modifiedMillis = now - id * 3_600_000, sortMillis = now - id * 3_600_000,
            mimeType = if (video) "video/mp4" else "image/jpeg", width = 4000, height = 3000,
            durationMs = if (video) 12_000 + id * 7_000 else null, location = "Camera",
            uri = "content://media/external/images/media/$id",
        )
    }

    private val documents = listOf(
        DocumentItem("docs", "Invoices", "invoice-oct-2026.pdf", 248_000, now - 40 * 60_000, "application/pdf", "content://d/1", "Documents/Invoices"),
        DocumentItem("docs", "", "Trip itinerary.docx", 61_000, now - 5 * 3_600_000, "application/msword", "content://d/2", "Documents"),
        DocumentItem("dl", "", "boarding-pass.pdf", 112_000, now - 26 * 3_600_000, "application/pdf", "content://d/3", "Download/WhatsApp Documents"),
        DocumentItem("docs", "Work", "Q4 budget.xlsx", 830_000, now - 3 * 86_400_000L, "application/vnd.ms-excel", "content://d/4", "Documents/Work"),
        DocumentItem("default", "", "notes.txt", 4_000, now - 6 * 86_400_000L, "text/plain", "content://d/5", "Download/Bridgey"),
    )

    private val folders = listOf(
        AttachFolder("default", "Download/Bridgey", "Always there, no setup", true, isDefault = true),
        AttachFolder("q3Jx0bVv1eG7tq8Wm2l5wA", "Pictures", "Internal storage", true),
        AttachFolder("Zx9dP0aB1cD2eF3gH4iJ5k", "Documents", "Internal storage", true),
        AttachFolder("Kq7Lm8Nn9Oo0Pp1Qq2Rr3s", "Trip (USB drive)", "USB drive", false),
    )

    private val targets = listOf(AttachTarget("work", "MacBook Pro"), AttachTarget("personal", "Personal Mac"))

    private val base = AttachState(
        mediaAccess = MediaAccess.FULL,
        media = media,
        documents = documents,
        hasDocumentPlace = true,
        folders = folders,
        canSendFolders = true,
        targets = targets,
        targetId = "work",
    )

    private val trusted = listOf(TrustedDevice("work", "MacBook Pro"), TrustedDevice("personal", "Personal Mac"))
    private val peers = listOf(DiscoveredPeer("personal-svc", "personal", "Personal Mac", "macos", 1, "10.0.0.3", 42_458))
    private val rings get() = deviceRings(trusted, peers, PairingState.Connected("work", "MacBook Pro"))

    /** The sheet over the Stream behind a scrim, as Bridgey shows it. */
    private fun sheet(name: String, state: AttachState) = capture("$name-${theme()}") {
        Box(Modifier.fillMaxSize()) {
            val rings = rings
            HomeScreen(
                state = HomeState(rings = rings, target = sendTarget(rings, null), activity = emptyList(), live = emptyList(), canSendClipboard = true, now = now, canAttach = true),
                actions = HomeActions(),
                snackbar = remember { SnackbarHostState() },
                deviceName = { it.deviceName },
            )
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f)))
            Box(Modifier.align(Alignment.BottomCenter)) {
                FolderSheetSurface {
                    AttachSheetContent(state, AttachActions(), Modifier.padding(bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()))
                }
            }
        }
    }

    private val picked = listOf(media[0], media[3], media[1], media[6]).map(AttachKeys::media)

    @Test fun mediaLight() = sheet("android-attach-media", base.copy(selection = picked))

    @Test @Config(qualifiers = "+night") fun mediaDark() = sheet("android-attach-media", base.copy(selection = picked))

    @Test fun partialLight() = sheet("android-attach-partial", base.copy(mediaAccess = MediaAccess.PARTIAL, media = media.take(7)))

    @Test fun permissionLight() = sheet("android-attach-permission", base.copy(mediaAccess = MediaAccess.NONE, media = emptyList()))

    @Test @Config(qualifiers = "+night") fun permissionDark() = sheet("android-attach-permission", base.copy(mediaAccess = MediaAccess.NONE, media = emptyList()))

    @Test fun documentsCardLight() = sheet(
        "android-attach-documents-card",
        base.copy(tab = AttachTab.FILES, showDocumentsCard = true, hasDocumentPlace = false, documents = documents.takeLast(1)),
    )

    @Test @Config(qualifiers = "+night") fun documentsCardDark() = sheet(
        "android-attach-documents-card",
        base.copy(tab = AttachTab.FILES, showDocumentsCard = true, hasDocumentPlace = false, documents = documents.takeLast(1)),
    )

    @Test fun filesLight() = sheet(
        "android-attach-files",
        base.copy(tab = AttachTab.FILES, selection = listOf(AttachKeys.document(documents[0]), AttachKeys.document(documents[2]))),
    )

    @Test @Config(qualifiers = "+night") fun filesDark() = sheet(
        "android-attach-files",
        base.copy(tab = AttachTab.FILES, selection = listOf(AttachKeys.document(documents[0]), AttachKeys.document(documents[2]))),
    )

    @Test fun foldersLight() = sheet("android-attach-folders", base.copy(tab = AttachTab.FOLDERS, selection = listOf(AttachKeys.folder("q3Jx0bVv1eG7tq8Wm2l5wA"))))

    @Test @Config(qualifiers = "+night") fun foldersDark() = sheet("android-attach-folders", base.copy(tab = AttachTab.FOLDERS, selection = listOf(AttachKeys.folder("q3Jx0bVv1eG7tq8Wm2l5wA"))))

    @Test fun foldersUnsupportedLight() = sheet("android-attach-folders-unsupported", base.copy(tab = AttachTab.FOLDERS, canSendFolders = false))

    private fun settingsFiles() = capture("android-browse-settings-files-${theme()}") {
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
                installedVersion = "0.8.0",
                now = now,
                folders = FolderSettingsState(
                    places = folders.map { SheetPlace(it.placeId, it.label, it.available, it.isDefault, it.detail) },
                    defaultPlaceId = "default",
                    allowBrowse = true,
                    allowReplace = false,
                ),
            ),
            actions = SettingsActions(),
            section = SettingsSection.FILES,
        )
    }

    @Test fun settingsLight() = settingsFiles()

    @Test @Config(qualifiers = "+night") fun settingsDark() = settingsFiles()

    private fun outgoing(): List<LiveCard> {
        val sending = FolderSnapshot(
            folderTransferId = "4b0c9d5e-1111-4222-8333-944455556666", deviceId = "work", deviceName = "MacBook Pro", rootName = "Trip 2026",
            filesTotal = 86, bytesTotal = 1_240_000_000, filesDone = 31, bytesDone = 402_000_000, destinationLabel = "Received files",
            bytesPerSecond = 18_874_368, currentFile = "IMG_2201.HEIC", currentFileBytes = 1_200_000, currentFileSize = 3_100_000, outgoing = true,
        )
        val download = FolderSnapshot(
            folderTransferId = "5c1d0e6f-2222-4333-8444-a55566667777", deviceId = "work", deviceName = "MacBook Pro", rootName = "IMG_2210.HEIC",
            filesTotal = 3, bytesTotal = 21_000_000, filesDone = 1, bytesDone = 7_400_000, bytesPerSecond = 22_000_000, outgoing = true, download = true,
        )
        val waiting = FolderSnapshot(
            folderTransferId = "6d2e1f70-3333-4444-8555-b66677778888", deviceId = "personal", deviceName = "Personal Mac", rootName = "Invoices",
            filesTotal = 14, bytesTotal = 3_400_000, waiting = FolderWaiting.DESTINATION, deadlineMillis = now + 161_000, outgoing = true,
        )
        return listOf(sending, download, waiting).mapIndexed { index, folder ->
            LiveCard.Transfer(
                FileTransferState(
                    folder.folderTransferId, folder.rootName, "Sending folder", true, null, startedAtMillis = now - index * 60_000,
                    deviceId = folder.deviceId, deviceName = folder.deviceName, kind = TransferKind.FOLDER, folder = folder,
                ),
            )
        }
    }

    private fun streamOutgoing() = capture("android-stream-outgoing-${theme()}") {
        val rings = rings
        HomeScreen(
            state = HomeState(rings = rings, target = sendTarget(rings, null), activity = emptyList(), live = outgoing(), canSendClipboard = true, now = now, canAttach = true),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
        )
    }

    @Test fun streamOutgoingLight() = streamOutgoing()

    @Test @Config(qualifiers = "+night") fun streamOutgoingDark() = streamOutgoing()
}
