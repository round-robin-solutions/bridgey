package dev.bridgey.android.migrations

import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.activity.ActivityLog
import dev.bridgey.android.migrations.MigrationFixtures.BASE_MILLIS
import dev.bridgey.android.migrations.MigrationFixtures.HOUR
import dev.bridgey.android.migrations.MigrationFixtures.MAC_A
import dev.bridgey.android.migrations.MigrationFixtures.MAC_B
import java.io.File
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * The activity stream file (`noBackupFilesDir/activity-stream.json`) written by Beta 2, 4, 5 and 10
 * (each added fields or kinds) loads in this build with every item and field it had.
 */
class ActivityMigrationTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val now = BASE_MILLIS + 24 * HOUR
    private val direct = Executor { it.run() }

    private fun load(fixture: String): Pair<File, ActivityLog> {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        MigrationFixtures.file("activity/$fixture").copyTo(file, overwrite = true)
        return file to ActivityLog(file, direct) { now }
    }

    private fun item(
        id: Long,
        kind: ActivityKind,
        minutes: Long,
        deviceId: String? = MAC_A,
        deviceName: String = "Test Mac A",
        fileName: String? = null,
        preview: String? = null,
        appName: String? = null,
        sensitive: Boolean = false,
        automatic: Boolean = false,
        count: Int = 1,
        bytes: Long? = null,
        content: String? = null,
        fileCount: Int? = null,
        destination: String? = null,
        detail: String? = null,
    ) = ActivityItem(id, kind, deviceId, deviceName, fileName, preview, appName, sensitive, automatic, count, BASE_MILLIS + minutes * 60_000, bytes, content, fileCount, destination, detail)

    /** The items every fixture has, in the shape of [release]. */
    private fun expected(release: Int): List<ActivityItem> {
        val items = mutableListOf<ActivityItem>()
        if (release >= 10) {
            items += item(12, ActivityKind.FOLDER_RECEIVED, 120, fileName = "Trip", bytes = 52_428_800, fileCount = 12, destination = "Pictures/Trip", detail = "merged=12,links=3")
            items += item(11, ActivityKind.FOLDER_INCOMPLETE, 90, fileName = "Scans", bytes = 1_048_576, fileCount = 4, destination = "Download/Bridgey/Scans", detail = "failed=1,timeout")
        }
        if (release >= 5) {
            items += item(10, ActivityKind.CLIP_OFFER_RECEIVED, 60, bytes = 2_100_000, content = "image")
            items += item(9, ActivityKind.CLIP_PASTED, 50, fileName = "video.mp4", bytes = 340_000_000, content = "file")
        }
        if (release >= 4) {
            items += item(8, ActivityKind.CLIPBOARD_SENT, 40, preview = "Automatic copy from the phone", automatic = true)
            items += item(7, ActivityKind.CLIPBOARD_RECEIVE_FAILED, 30)
        }
        items += item(6, ActivityKind.CLIPBOARD_SENT, 20, preview = "Meeting notes for Tuesday")
        items += item(5, ActivityKind.CLIPBOARD_RECEIVED, 15, sensitive = true)
        items += item(4, ActivityKind.NOTIFICATIONS_SHOWN, 10, appName = "Chat App", count = 4)
        items += item(3, ActivityKind.FILE_RECEIVED, 5, fileName = "report.pdf")
        items += item(2, ActivityKind.CALL_SHOWN, 2, preview = "Test Caller")
        items += item(1, ActivityKind.PAIRED, 0, deviceId = MAC_B, deviceName = "Test Mac B")
        return items
    }

    @Test
    fun everyShippedShapeLoadsCompletely() {
        for (release in listOf(2, 4, 5, 10)) {
            val (_, log) = load("activity-stream.beta.$release.json")
            assertEquals("beta.$release", expected(release), log.items.value)
        }
    }

    @Test
    fun anUpgradedStreamIsRewrittenInTheCurrentShapeWithoutLosingItems() {
        for (release in listOf(2, 4, 5, 10)) {
            val (file, log) = load("activity-stream.beta.$release.json")
            log.record(ActivityKind.PING_RECEIVED, MAC_A, "Test Mac A")
            val reloaded = ActivityLog(file, direct) { now }.items.value
            assertEquals("beta.$release", ActivityKind.PING_RECEIVED, reloaded.first().kind)
            assertEquals("beta.$release keeps ids unique", (expected(release).maxOf { it.id }) + 1, reloaded.first().id)
            assertEquals("beta.$release", expected(release), reloaded.drop(1))
        }
    }

    @Test
    fun malformedAndUnknownEntriesAreDroppedOneByOne() {
        val (_, log) = load("activity-stream.malformed.json")
        val items = log.items.value
        assertEquals(listOf(47L, 44L, 43L, 40L), items.map { it.id })

        val ping = items[0]
        assertEquals(ActivityKind.PING_RECEIVED, ping.kind)
        assertNull("an explicit null device stays null", ping.deviceId)

        val folderItem = items[1]
        assertEquals("Trip", folderItem.fileName)
        assertNull("a negative file count is dropped", folderItem.fileCount)
        assertNull("a blank destination is dropped", folderItem.destination)
        assertNull("an invalid detail is dropped", folderItem.detail)

        val offer = items[2]
        assertNull("an empty device id is no device", offer.deviceId)
        assertEquals(9_999, offer.count)
        assertNull("a negative size is dropped", offer.bytes)
        assertNull("an unknown content kind is dropped", offer.content)
        assertNull("offers keep no preview", offer.preview)

        val clip = items[3]
        assertEquals("Test Mac A", clip.deviceName)
        assertEquals("line one line two", clip.preview)
        assertEquals(1, clip.count)
        assertTrue(clip.automatic)
        assertFalse(clip.sensitive)
        assertNull("clipboard text keeps no file name", clip.fileName)
        assertNull(clip.appName)
        assertNull(clip.bytes)
        assertNull(clip.content)
        assertNull(clip.fileCount)
        assertNull(clip.destination)
        assertNull(clip.detail)
    }

    @Test
    fun anUnreadableFileStartsAnEmptyStreamWithoutCrashing() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        file.writeText("{ not json")
        assertTrue(ActivityLog(file, direct) { now }.items.value.isEmpty())
        file.writeText("""{"items": []}""")
        assertTrue(ActivityLog(file, direct) { now }.items.value.isEmpty())
        file.writeBytes(ByteArray(600 * 1024) { ' '.code.toByte() })
        assertTrue("over 512 KiB is not read", ActivityLog(file, direct) { now }.items.value.isEmpty())
    }
}
