package dev.bridgey.android

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FreshScreenshotTest {
    private val now = 1_790_000_000_000L

    private fun shot(
        id: Long,
        ageMillis: Long,
        relativePath: String? = "DCIM/Screenshots/",
        bucket: String? = "Screenshots",
        dataPath: String? = null,
        size: Long = 420_000,
        pending: Boolean = false,
        dateTakenMillis: Long = 0,
    ) = ScreenshotRow(
        id = id,
        relativePath = relativePath,
        bucket = bucket,
        dataPath = dataPath,
        dateAddedSeconds = (now - ageMillis) / 1000,
        dateTakenMillis = dateTakenMillis,
        size = size,
        pending = pending,
        mime = "image/png",
        name = "Screenshot_$id.png",
    )

    private fun pick(rows: List<ScreenshotRow>, clip: Long = 0, lastSent: Long? = null) =
        pickFreshScreenshot(rows, now, clip, lastSent)

    @Test
    fun screenshotsFolderMatchesOxygenOsPathsCaseInsensitively() {
        assertTrue(isScreenshotsFolder("DCIM/Screenshots/", null, null))
        assertTrue(isScreenshotsFolder("Pictures/Screenshots/", null, null))
        assertTrue(isScreenshotsFolder("pictures/SCREENSHOTS", null, null))
        assertTrue(isScreenshotsFolder(null, "screenshots", null))
        assertTrue(isScreenshotsFolder(null, null, "/storage/emulated/0/Pictures/Screenshots/Screenshot_1.png"))
        assertFalse(isScreenshotsFolder("DCIM/Camera/", "Camera", null))
        assertFalse(isScreenshotsFolder("Pictures/WhatsApp/", "WhatsApp", "/storage/emulated/0/Pictures/Screenshots.png"))
        assertFalse(isScreenshotsFolder("Pictures/Screenshots-old/", "Screenshots-old", null))
    }

    @Test
    fun onlyTheNewestScreenshotsFolderImageCounts() {
        val camera = shot(9, ageMillis = 2_000, relativePath = "DCIM/Camera/", bucket = "Camera")
        val screenshot = shot(5, ageMillis = 10_000)
        assertEquals(ScreenshotPick.Ready(screenshot), pick(listOf(camera, screenshot)))
        assertEquals(ScreenshotPick.None, pick(listOf(camera)))
        assertEquals(ScreenshotPick.None, pick(emptyList()))
    }

    @Test
    fun windowIsOneMinute() {
        assertEquals(60_000L, FRESH_SCREENSHOT_WINDOW_MILLIS)
        assertTrue(pick(listOf(shot(1, ageMillis = 59_000))) is ScreenshotPick.Ready)
        assertTrue(pick(listOf(shot(1, ageMillis = 60_000))) is ScreenshotPick.Ready)
        assertEquals(ScreenshotPick.None, pick(listOf(shot(1, ageMillis = 61_000))))
        // A little clock skew is fine; a screenshot far in the future is not trusted.
        assertTrue(pick(listOf(shot(1, ageMillis = -3_000))) is ScreenshotPick.Ready)
        assertEquals(ScreenshotPick.None, pick(listOf(shot(1, ageMillis = -30_000))))
    }

    @Test
    fun screenshotMustBeNewerThanTheClip() {
        val screenshot = shot(1, ageMillis = 20_000)
        assertEquals(ScreenshotPick.None, pick(listOf(screenshot), clip = now - 5_000))
        assertEquals(ScreenshotPick.None, pick(listOf(screenshot), clip = screenshot.timeMillis))
        assertEquals(ScreenshotPick.Ready(screenshot), pick(listOf(screenshot), clip = now - 30_000))
        // An empty clipboard has no timestamp: the screenshot goes.
        assertEquals(ScreenshotPick.Ready(screenshot), pick(listOf(screenshot), clip = 0))
    }

    @Test
    fun dateTakenGivesMillisecondsOnlyWhenItAgreesWithDateAdded() {
        val added = shot(1, ageMillis = 20_000)
        val precise = added.copy(dateTakenMillis = added.dateAddedSeconds * 1000 + 700)
        assertEquals(added.dateAddedSeconds * 1000 + 700, precise.timeMillis)
        // EXIF in the wrong time zone: ignore it.
        val wrongZone = added.copy(dateTakenMillis = added.dateAddedSeconds * 1000 + 5L * 60 * 60 * 1000)
        assertEquals(added.dateAddedSeconds * 1000, wrongZone.timeMillis)
        // A clip copied 300 ms before the screenshot, in the same second: the screenshot is newer.
        assertTrue(pick(listOf(precise), clip = added.dateAddedSeconds * 1000 + 400) is ScreenshotPick.Ready)
    }

    @Test
    fun alreadySentScreenshotIsNotSentAgainAndOlderOnesDoNotReplaceIt() {
        val newest = shot(7, ageMillis = 5_000)
        val older = shot(6, ageMillis = 30_000)
        assertEquals(ScreenshotPick.None, pick(listOf(newest, older), lastSent = 7))
        assertEquals(ScreenshotPick.Ready(newest), pick(listOf(newest, older), lastSent = 6))
    }

    @Test
    fun pendingOrEmptyScreenshotIsStillBeingWritten() {
        val pending = shot(3, ageMillis = 500, pending = true)
        val empty = shot(4, ageMillis = 400, size = 0)
        assertEquals(ScreenshotPick.Writing(pending), pick(listOf(pending)))
        assertEquals(ScreenshotPick.Writing(empty), pick(listOf(empty, pending)))
    }

    private class FakeSource(
        private val rows: List<ScreenshotRow>,
        private val later: (Int) -> ScreenshotRow?,
    ) : ScreenshotSource {
        var lookups = 0
        var since = 0L

        override fun recentImages(sinceMillis: Long): List<ScreenshotRow> {
            since = sinceMillis
            return rows
        }

        override fun image(id: Long): ScreenshotRow? = later(++lookups)
    }

    private fun finder(source: ScreenshotSource, slept: MutableList<Long> = mutableListOf()) =
        FreshScreenshotFinder(source, now = { now }, sleep = { slept += it })

    @Test
    fun finderReturnsAReadyScreenshotWithoutWaiting() = runBlocking {
        val ready = shot(1, ageMillis = 3_000)
        val slept = mutableListOf<Long>()
        val source = FakeSource(listOf(ready)) { error("no lookup expected") }
        assertEquals(ready, finder(source, slept).find(clipTimestampMillis = 0, lastSentId = null))
        assertTrue(slept.isEmpty())
        assertTrue(source.since <= now - FRESH_SCREENSHOT_WINDOW_MILLIS)
    }

    @Test
    fun finderWaitsForAScreenshotStillBeingWritten() = runBlocking {
        val pending = shot(2, ageMillis = 200, pending = true, size = 0)
        val slept = mutableListOf<Long>()
        val source = FakeSource(listOf(pending)) { lookup -> if (lookup < 4) pending else pending.copy(pending = false, size = 380_000) }
        val found = finder(source, slept).find(0, null)
        assertEquals(380_000L, found?.size)
        assertEquals(4, slept.size)
    }

    @Test
    fun finderGivesUpAfterAboutOneSecond() = runBlocking {
        val pending = shot(2, ageMillis = 200, pending = true)
        val slept = mutableListOf<Long>()
        val source = FakeSource(listOf(pending)) { pending }
        assertNull(finder(source, slept).find(0, null))
        assertEquals(SCREENSHOT_WRITE_WAIT_MILLIS, slept.sum())
    }

    @Test
    fun finderStopsWhenTheScreenshotIsDeletedWhileWaiting() = runBlocking {
        val pending = shot(2, ageMillis = 200, pending = true)
        assertNull(finder(FakeSource(listOf(pending)) { null }).find(0, null))
    }

    @Test
    fun finderSendsTheClipboardWhenMediaStoreFails() = runBlocking {
        val failing = object : ScreenshotSource {
            override fun recentImages(sinceMillis: Long): List<ScreenshotRow> = throw SecurityException("no access")
            override fun image(id: Long): ScreenshotRow? = null
        }
        assertNull(finder(failing).find(0, null))
    }

    @Test
    fun finderRespectsLastSentAndClipTime() = runBlocking {
        val ready = shot(1, ageMillis = 3_000)
        val source = FakeSource(listOf(ready)) { ready }
        assertNull(finder(source).find(0, lastSentId = 1))
        assertNull(finder(source).find(clipTimestampMillis = now - 1_000, lastSentId = null))
    }
}
