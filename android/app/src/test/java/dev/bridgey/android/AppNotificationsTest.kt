package dev.bridgey.android

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** AppNotifications on Robolectric's NotificationManager and main looper, and no code going around it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class AppNotificationsTest {
    private lateinit var context: Context
    private lateinit var manager: NotificationManager

    @Before fun prepare() {
        context = ApplicationProvider.getApplicationContext()
        manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Test", NotificationManager.IMPORTANCE_LOW))
    }

    private fun notification(text: String): Notification =
        Notification.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.ic_dialog_info).setContentText(text).build()

    private fun shown(id: Int, tag: String? = null): String? =
        manager.activeNotifications.firstOrNull { it.id == id && it.tag == tag }?.notification?.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()

    private fun idle(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))

    @Test fun updatesAreCoalescedAndBuiltOnlyWhenTheyGoOut() {
        AppNotifications.post(context, 1, notification("connected"))
        assertEquals("a new notification is posted at once", "connected", shown(1))
        var built = 0
        repeat(20) { i -> AppNotifications.post(context, 1) { built++; notification("update $i") } }
        assertEquals("connected", shown(1))
        assertEquals("nothing built while it waits", 0, built)
        idle(1_000)
        assertEquals("update 19", shown(1))
        assertEquals("only the latest was built", 1, built)
    }

    @Test fun promptsGoOutAtOnceAndRemovalTakesTheWaitingUpdate() {
        AppNotifications.post(context, 2, notification("photo.jpg 10%"))
        AppNotifications.post(context, 2, notification("photo.jpg 90%"))
        AppNotifications.post(context, 3, notification("Work MacBook wants to control this phone"), urgency = NotificationUrgency.IMMEDIATE)
        assertEquals("Work MacBook wants to control this phone", shown(3))
        AppNotifications.cancel(context, 2)
        assertNull(shown(2))
        idle(5_000)
        assertNull("the waiting update did not bring it back", shown(2))
    }

    @Test fun cancelWhereReachesTaggedNotificationsShowingAndWaiting() {
        AppNotifications.post(context, 7, notification("one"), tag = "agent:mac-1:a")
        AppNotifications.post(context, 7, notification("one, again"), tag = "agent:mac-1:a")
        AppNotifications.post(context, 7, notification("other"), tag = "agent:mac-2:a")
        AppNotifications.cancelWhere(context) { tag, _ -> tag?.contains(":mac-1") == true }
        idle(5_000)
        assertNull(shown(7, "agent:mac-1:a"))
        assertEquals("other", shown(7, "agent:mac-2:a"))
    }

    @Test fun everyNotificationGoesThroughAppNotifications() {
        // Posting, removing or starting a foreground notification straight through Android would bypass the throttle.
        val direct = Regex("""\.notify\(\s*\S|(?<!AppNotifications\.)\b(start|stop)Foreground\(|\b(notificationManager|manager)\??(\.|::)cancel\b|NotificationManager::class\.java\)\??\.cancel""")
        val sources = File("src").walkTopDown().filter { it.isFile && it.extension == "kt" && "/test/" !in it.path }
        val found = sources.filter { it.name != "AppNotifications.kt" }.flatMap { file ->
            file.readLines().mapIndexedNotNull { i, line -> if (direct.containsMatchIn(line)) "${file.path}:${i + 1}: ${line.trim()}" else null }
        }.toList()
        assertTrue("notifications posted around AppNotifications:\n" + found.joinToString("\n"), found.isEmpty())
    }

    private companion object {
        const val CHANNEL = "test"
    }
}
