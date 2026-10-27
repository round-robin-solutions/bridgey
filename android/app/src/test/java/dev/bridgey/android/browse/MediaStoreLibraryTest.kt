package dev.bridgey.android.browse

import android.Manifest
import android.database.MatrixCursor
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = android.app.Application::class)
class MediaStoreLibraryTest {
    @Test
    fun accessFollowsEveryAndroidVersion() {
        fun access(sdk: Int, vararg granted: String) = MediaAccessRules.access(sdk) { it in granted }
        assertEquals(MediaAccess.FULL, access(32, Manifest.permission.READ_EXTERNAL_STORAGE))
        assertEquals(MediaAccess.NONE, access(32))
        assertEquals(MediaAccess.FULL, access(33, Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO))
        assertEquals(MediaAccess.PARTIAL, access(33, Manifest.permission.READ_MEDIA_IMAGES))
        assertEquals(MediaAccess.PARTIAL, access(34, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        assertEquals(MediaAccess.NONE, access(33, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
        assertEquals(MediaAccess.NONE, access(35))
        // READ_EXTERNAL_STORAGE means nothing for media from Android 13.
        assertEquals(MediaAccess.NONE, access(33, Manifest.permission.READ_EXTERNAL_STORAGE))
    }

    @Test
    fun requestAsksForPhotosAndVideosOnce() {
        assertTrue(Manifest.permission.READ_MEDIA_VIDEO in MediaAccessRules.request(34))
        assertTrue(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED in MediaAccessRules.request(34))
        assertEquals(listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO), MediaAccessRules.request(33).toList())
        assertEquals(listOf(Manifest.permission.READ_EXTERNAL_STORAGE), MediaAccessRules.request(29).toList())
    }

    @Test
    fun rowsMapToItemsWithTypedUris() {
        val cursor = MatrixCursor(MediaQuery.projection)
        // id, name, size, modified (s), taken (ms), added (s), mime, width, height, duration, bucket, media type
        cursor.addRow(arrayOf<Any?>(12L, "IMG_1.jpg", 2_000_000L, 1_790_000_000L, 1_789_999_000_123L, 1_790_000_001L, "image/jpeg", 4000, 3000, null, "Camera", MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE))
        cursor.addRow(arrayOf<Any?>(13L, "VID_1.mp4", 9_000_000L, 1_790_000_100L, null, 1_790_000_100L, "video/mp4", 1920, 1080, 42_000L, "Camera", MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO))
        cursor.addRow(arrayOf<Any?>(14L, null, 0L, null, null, null, null, 0, 0, 0L, null, MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE))
        val items = MediaQuery.read(cursor)
        assertEquals(3, items.size)
        val photo = items[0]
        assertEquals(1_789_999_000_123L, photo.sortMillis)
        assertEquals(1_790_000_000_000L, photo.modifiedMillis)
        assertEquals(4000, photo.width)
        assertNull(photo.durationMs)
        assertTrue(photo.uri.startsWith(MediaStore.Images.Media.EXTERNAL_CONTENT_URI.toString()))
        val video = items[1]
        assertTrue(video.isVideo)
        assertEquals(1_790_000_100_000L, video.sortMillis)
        assertEquals(42_000L, video.durationMs)
        assertTrue(video.uri.startsWith(MediaStore.Video.Media.EXTERNAL_CONTENT_URI.toString()))
        val bare = items[2]
        assertEquals("image/*", bare.mimeType)
        assertNull(bare.width)
    }

    @Test
    fun queryOrdersNewestFirstAndSkipsEmptyFiles() {
        assertTrue(MediaQuery.SORT.startsWith("COALESCE(datetaken, date_added * 1000) DESC"))
        assertTrue(MediaQuery.SORT.endsWith("_id DESC"))
        assertTrue(MediaQuery.SELECTION.contains("_size > 0"))
    }
}
