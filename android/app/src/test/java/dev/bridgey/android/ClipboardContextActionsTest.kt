package dev.bridgey.android

import android.app.Application
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PersistableBundle
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Synthetic clipboard data only; no live Bridgey application, connection, preferences or account. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ClipboardContextActionsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private fun clip(text: String, sensitive: Boolean = false) = LocalClip.Text(text, null, sensitive)
    private fun tracker() = ClipboardContextActions(ByteArray(32) { 7 })

    @Test fun wholeWebLinksOnly() {
        assertEquals(ClipboardContextTarget(ClipboardContextKind.LINK, "https://example.com/path?q=one"),
            classifyClipboardContext(" https://example.com/path?q=one "))
        assertEquals("https://example.com/path", classifyClipboardContext("HTTPS://example.com/path")!!.intent().dataString)
        for (value in listOf("javascript:alert(1)", "file:///private/file", "content://private/item", "intent://example",
            "Read https://example.com now", "https://", "https://example.com:99999", "https://user:password@example.com",
            "https://example.com/has space", "https://example.com/\u202Ehidden")) {
            assertNull(value, classifyClipboardContext(value))
        }
    }

    @Test fun phoneNumbersDoNotPlaceCallsOrInterpretCodes() {
        assertEquals(ClipboardContextTarget(ClipboardContextKind.CALL, "+919876543210"), classifyClipboardContext("+91 98765 43210"))
        assertEquals(ClipboardContextKind.CALL, classifyClipboardContext("9876543210")?.kind)
        for (value in listOf("1234", "123456", "12345678", "1234 5678", "*123#", "tel:1234567890",
            "1234567890123456", "Call 9876543210", "(9876543210")) assertNull(value, classifyClipboardContext(value))
        val intent = classifyClipboardContext("+91 98765 43210")!!.intent()
        assertEquals(Intent.ACTION_DIAL, intent.action)
        assertEquals("tel", intent.data?.scheme)
        assertEquals("+919876543210", intent.data?.schemeSpecificPart)
        assertNotEquals(Intent.ACTION_CALL, intent.action)
    }

    @Test fun emailIsOnlyAComposeIntentWithNoInjectedHeaders() {
        val target = classifyClipboardContext("alice+tag@example.com")!!
        val intent = target.intent()
        assertEquals(ClipboardContextKind.EMAIL, target.kind)
        assertEquals(Intent.ACTION_SENDTO, intent.action)
        assertEquals("mailto", intent.data?.scheme)
        assertEquals("alice+tag@example.com", intent.data?.schemeSpecificPart)
        for (value in listOf("alice@example.com?subject=Injected", "alice@example.com\nbcc:bob@example.com", "a..b@example.com",
            "a@example", "Contact alice@example.com")) assertNull(value, classifyClipboardContext(value))
    }

    @Test fun unknownSensitiveAndOversizeClipsHaveNoExtraAction() {
        val tracker = tracker()
        tracker.observe(clip("https://example.com"))
        assertNotNull(tracker.action.value)
        tracker.observe(null)
        assertNull(tracker.action.value)
        tracker.observe(clip("https://example.com", sensitive = true))
        assertNull(tracker.action.value)
        tracker.observe(clip("ordinary text"))
        assertNull(tracker.action.value)
        assertNull(classifyClipboardContext("https://example.com/" + "a".repeat(8_192)))
    }

    @Test fun oldActionCannotOpenAChangedOrSensitiveClipboard() {
        val tracker = tracker()
        val original = clip("https://example.com/original")
        tracker.observe(original)
        val expected = tracker.action.value!!
        assertNotNull(tracker.resolve(expected, original))
        assertNull(tracker.resolve(expected, clip("https://example.com/other")))
        assertNull(tracker.resolve(expected, clip("1234567890")))
        assertNull(tracker.resolve(expected, original.copy(sensitive = true)))
        assertNull(tracker.resolve(expected, null))
        assertNull(tracker.resolve(expected.copy(fingerprint = "bad"), original))
        assertNull(tracker.resolve(expected, clip(" https://example.com/original ")))
    }

    @Test fun backgroundDisableAndProcessRestartInvalidateKnowledge() {
        val tracker = tracker()
        tracker.observe(clip("https://example.com"))
        val expected = tracker.action.value!!
        tracker.clear()
        assertNull(tracker.action.value)
        val restarted = ClipboardContextActions(ByteArray(32) { 9 })
        assertNull(restarted.action.value)
        assertNull(restarted.resolve(expected, clip("https://example.com")))
        assertFalse(expected.toString().contains("example.com"))
    }

    @Test fun localExecutionRequiresFocusEnabledAndFreshMatchingClipboard() {
        val tracker = tracker()
        val original = clip("https://example.com/original")
        tracker.observe(original)
        val expected = tracker.action.value!!
        var reads = 0
        val launched = mutableListOf<Intent>()
        val reader = { reads += 1; original }
        assertEquals(ClipboardContextOpenResult.CHANGED, executeClipboardContext(tracker, expected, false, true, reader, launched::add))
        assertEquals(ClipboardContextOpenResult.CHANGED, executeClipboardContext(tracker, expected, true, false, reader, launched::add))
        assertEquals(0, reads)
        assertTrue(launched.isEmpty())
        assertEquals(ClipboardContextOpenResult.CHANGED, executeClipboardContext(tracker, expected, true, true,
            read = { clip("https://example.com/different") }, open = launched::add))
        assertTrue(launched.isEmpty())
        assertEquals(ClipboardContextOpenResult.OPENED, executeClipboardContext(tracker, expected, true, true, reader, launched::add))
        assertEquals(1, launched.size)
        assertEquals("https://example.com/original", launched.single().dataString)
        assertEquals(Intent.ACTION_VIEW, launched.single().action)
        assertTrue("removing the clipboard reader's task must not remove its destination",
            launched.single().flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test fun everyLocalDestinationLaunchesOutsideTheTemporaryReaderTask() {
        for (value in listOf("https://example.com", "+919876543210", "alice@example.com")) {
            val intent = classifyClipboardContext(value)!!.intent()
            assertTrue(value, intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        }
    }

    @Test fun missingHandlerOrDeniedClipboardDoesNotOpenOrSendAnything() {
        val tracker = tracker()
        val original = clip("alice@example.com")
        tracker.observe(original)
        val expected = tracker.action.value!!
        assertEquals(ClipboardContextOpenResult.NO_HANDLER, executeClipboardContext(tracker, expected, true, true,
            read = { original }, open = { throw android.content.ActivityNotFoundException("fixture") }))
        var opened = false
        assertEquals(ClipboardContextOpenResult.CHANGED, executeClipboardContext(tracker, expected, true, true,
            read = { throw SecurityException("fixture") }, open = { opened = true }))
        assertFalse(opened)
        assertNull(tracker.action.value)
    }

    @Test fun focusedReaderAvoidsUriProvidersMultipleItemsAndSensitiveActions() {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newPlainText("fixture", "https://example.com"))
        assertEquals("https://example.com", readClipboardContext(context)?.text)
        clipboard.setPrimaryClip(ClipData.newRawUri("fixture", Uri.parse("content://fixture/private")))
        assertNull(readClipboardContext(context))
        clipboard.setPrimaryClip(ClipData.newRawUri("fixture", Uri.parse("https://example.com/raw-link")))
        assertEquals("https://example.com/raw-link", readClipboardContext(context)?.text)
        clipboard.setPrimaryClip(ClipData.newPlainText("fixture", "https://example.com").apply {
            addItem(ClipData.Item("other"))
        })
        assertNull(readClipboardContext(context))
        clipboard.setPrimaryClip(ClipData.newPlainText("fixture", "https://example.com").apply {
            description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
        })
        val tracker = tracker()
        tracker.observe(readClipboardContext(context))
        assertNull(tracker.action.value)
    }

    @Test fun knownAndUnknownNotificationViewsContainLabelsOnly() {
        val pending = PendingIntent.getActivity(context, 42, Intent("fixture"), PendingIntent.FLAG_IMMUTABLE)
        val parent = FrameLayout(context)
        val plain = clipboardNotificationContent(context, "Connected", pending).apply(context, parent)
        assertNull(plain.findViewById<TextView>(R.id.notification_local_action))
        val known = clipboardNotificationContent(context, "Connected", pending, pending, ClipboardContextKind.EMAIL).apply(context, parent)
        assertEquals(context.getString(R.string.notification_email), known.findViewById<TextView>(R.id.notification_local_action).text)
        assertEquals(context.getString(R.string.notification_send_copied_text), known.findViewById<TextView>(R.id.notification_send).text)
        val collapsed = clipboardNotificationContent(context, "Connected", pending, pending, ClipboardContextKind.LINK, expanded = false).apply(context, parent)
        assertEquals(View.GONE, collapsed.findViewById<TextView>(R.id.notification_status).visibility)
        assertEquals(View.VISIBLE, collapsed.findViewById<TextView>(R.id.notification_local_action).visibility)
    }
}
