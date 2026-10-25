package dev.bridgey.android

import android.app.Application
import android.content.ContentResolver
import android.graphics.Point
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executor
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

/** The clipboard provider as a pasting app sees it, streaming from a fake source. */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class ClipboardContentProviderTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()
    private val authority get() = clipboardAuthority(context.packageName)
    private val offerId = UUID.randomUUID().toString()
    private val video = ByteArray(200_000) { (it % 253).toByte() }

    private class FakeBackend(val opened: (Int, Boolean) -> ClipOpen) : ClipProviderBackend {
        val calls = mutableListOf<Pair<Int, Boolean>>()
        override fun describe(offerId: String, index: Int) = when (index) {
            0 -> ClipItemInfo("video.mp4", "video/mp4", 200_000)
            1 -> ClipItemInfo("image.png", "image/png", 4)
            else -> null
        }
        override fun open(offerId: String, index: Int, allowFetch: Boolean): ClipOpen {
            calls += index to allowFetch
            return opened(index, allowFetch)
        }
    }

    private lateinit var backend: FakeBackend

    private fun install(opened: (Int, Boolean) -> ClipOpen) {
        backend = FakeBackend(opened)
        ClipboardContentProvider.backendOverride = backend
        // The copy runs inline so Robolectric's file-backed pipe holds the whole item before it is read.
        ClipboardContentProvider.executor = Executor { it.run() }
        Robolectric.setupContentProvider(ClipboardContentProvider::class.java, authority)
    }

    @Before fun reset() {
        ClipboardContentProvider.pipeFactory = ReliableClipPipeFactory
    }

    @After fun tearDown() {
        ClipboardContentProvider.backendOverride = null
        ClipboardContentProvider.pipeFactory = ReliableClipPipeFactory
    }

    private fun uri(index: Int, name: String) = clipItemUri(authority, offerId, index, name)

    @Test
    fun reportsTheNameSizeAndTypeChatAppsShow() {
        install { _, _ -> ClipOpen.Failed(ClipErrorCode.EXPIRED) }
        val resolver = context.contentResolver
        assertEquals("video/mp4", resolver.getType(uri(0, "video.mp4")))
        resolver.query(uri(0, "video.mp4"), null, null, null, null)!!.use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals("video.mp4", cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)))
            assertEquals(200_000L, cursor.getLong(cursor.getColumnIndexOrThrow(OpenableColumns.SIZE)))
        }
        assertEquals(null, resolver.query(uri(7, "x"), null, null, null, null))
        assertTrue(backend.calls.isEmpty())
    }

    @Test
    fun streamsALazyItemThroughAPipe() {
        install { _, _ ->
            ClipOpen.Streaming(ClipStream { output ->
                video.toList().chunked(24 * 1024).forEach { output.write(it.toByteArray()) }
            })
        }
        val read = context.contentResolver.openInputStream(uri(0, "video.mp4"))!!.use { it.readBytes() }
        assertArrayEquals(video, read)
        assertEquals(listOf(0 to true), backend.calls)
    }

    @Test
    fun servesCachedItemsAsFiles() {
        val cached = File(context.cacheDir, "cached-image").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        install { _, _ -> ClipOpen.Cached(cached) }
        context.contentResolver.openFileDescriptor(uri(1, "image.png"), "r")!!.use { descriptor ->
            assertEquals(4L, descriptor.statSize)
            assertArrayEquals(byteArrayOf(1, 2, 3, 4), ParcelFileDescriptor.AutoCloseInputStream(descriptor.dup()).readBytes())
        }
    }

    @Test
    fun aFailedTransferClosesThePipeWithAnError() {
        val failures = mutableListOf<String>()
        val received = ByteArrayOutputStream()
        install { _, _ ->
            ClipOpen.Streaming(ClipStream { output ->
                output.write(video, 0, 1000)
                throw ClipStreamException(ClipErrorCode.NOT_CONNECTED)
            })
        }
        ClipboardContentProvider.pipeFactory = ClipPipeFactory {
            val (read, write) = ParcelFileDescriptor.createPipe()
            object : ClipPipe {
                override val readSide = read
                override val output: OutputStream = received
                override fun finish() = Unit
                override fun fail(message: String) {
                    failures += message
                    write.close()
                }
            }
        }
        context.contentResolver.openFileDescriptor(uri(0, "video.mp4"), "r")!!.close()
        assertEquals(1000, received.size())
        assertEquals(listOf("The other device is not connected"), failures)
    }

    @Test
    fun anUnavailableItemIsReportedAsNotFound() {
        install { _, _ -> ClipOpen.Failed(ClipErrorCode.CHANGED) }
        try {
            context.contentResolver.openInputStream(uri(0, "video.mp4"))
            fail()
        } catch (error: FileNotFoundException) {
            assertEquals("The copy changed on the other device", error.message)
        }
    }

    @Test
    fun thumbnailRequestsNeverFetch() {
        install { _, _ -> ClipOpen.Failed(ClipErrorCode.UNAVAILABLE) }
        val options = Bundle().apply { putParcelable(ContentResolver.EXTRA_SIZE, Point(96, 96)) }
        try {
            context.contentResolver.openTypedAssetFileDescriptor(uri(1, "image.png"), "image/*", options)
            fail()
        } catch (_: FileNotFoundException) {
        }
        assertEquals(listOf(1 to false), backend.calls)
    }

    @Test
    fun writesAreRefused() {
        install { _, _ -> ClipOpen.Failed(ClipErrorCode.UNAVAILABLE) }
        try {
            context.contentResolver.openOutputStream(uri(0, "video.mp4"))
            fail()
        } catch (_: FileNotFoundException) {
        } catch (_: UnsupportedOperationException) {
        }
    }
}
