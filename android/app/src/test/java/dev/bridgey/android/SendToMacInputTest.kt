package dev.bridgey.android

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SendToMacInputTest {
    private val app get() = ApplicationProvider.getApplicationContext<Application>()
    @Test fun onlyShareActionsAreAcceptedAndOnlyHttpLinksOpen() {
        val send = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "Instagram https://example.com/reel")
        assertEquals("https://example.com/reel", sharedMacContent(send, app.packageName)?.link)
        assertNull(sharedMacContent(Intent(Intent.ACTION_VIEW).putExtra(Intent.EXTRA_TEXT, "https://example.com"), app.packageName))
        for (text in listOf("plain text", "javascript:alert(1)", "file:///private/key", "bridgey://pair")) {
            val parsed = sharedMacContent(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, text), app.packageName)!!
            assertNull(parsed.link)
            assertEquals(BridgeyFeature.CLIPBOARD, parsed.feature)
        }
    }
    @Test fun externalContentFilesWorkButInternalAndFileUrisFailClosed() {
        val uris = arrayListOf(Uri.parse("content://photos/a"), Uri.parse("content://documents/b"))
        val parsed = sharedMacContent(Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris), app.packageName)!!
        assertEquals(uris, parsed.files)
        assertEquals(BridgeyFeature.FILES, parsed.feature)
        for (uri in listOf("file:///private/key", "content://${app.packageName}.fileprovider/key", "content://${app.packageName}.clipboard/a")) {
            assertNull(uri, sharedMacContent(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, Uri.parse(uri)), app.packageName))
        }
        // Reject the entire mixed batch rather than silently sending a filtered subset.
        assertNull(sharedMacContent(Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM,
            arrayListOf(uris.first(), Uri.parse("file:///private/key"))), app.packageName))
    }
}
