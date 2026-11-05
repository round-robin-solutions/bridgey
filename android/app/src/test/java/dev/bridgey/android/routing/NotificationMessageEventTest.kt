package dev.bridgey.android.routing

import android.app.Application
import android.app.Notification
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.notificationMessageEventId
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@Suppress("DEPRECATION")
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class NotificationMessageEventTest {
    private fun builder() = Notification.Builder(ApplicationProvider.getApplicationContext<Application>(), "test")
    private fun id(notification: Notification, text: String = "hello", key: String = "conversation") =
        notificationMessageEventId(key, "test.messages", notification, "Alice", text, false, false)

    @Test fun repeatedMessageMetadataIgnoresAndroidRepostClocksAndSummaryChanges() {
        val style = Notification.MessagingStyle("You").addMessage("hello", 100, "Alice")
        val first = builder().setStyle(style).setCategory(Notification.CATEGORY_MESSAGE).setWhen(1_000).build()
        val repost = builder().setStyle(style).setCategory(Notification.CATEGORY_MESSAGE).setWhen(9_000).build()
        assertEquals(id(first), id(repost, "summary was restyled"))
        assertTrue(id(first)!!.matches(Regex("[a-f0-9]{64}")))
        assertNotEquals(id(first), id(first, key = "other-conversation"))
    }

    @Test fun anotherMessageWithTheSameTextStillHasANewIdentity() {
        val first = builder().setStyle(Notification.MessagingStyle("You").addMessage("hello", 100, "Alice"))
            .setCategory(Notification.CATEGORY_MESSAGE).build()
        val next = builder().setStyle(Notification.MessagingStyle("You").addMessage("hello", 100, "Alice")
            .addMessage("hello", 200, "Alice")).setCategory(Notification.CATEGORY_MESSAGE).build()
        assertNotEquals(id(first), id(next))
    }

    @Test fun plainMessageFallsBackToContentRatherThanRenderClocksAndCallsHaveNoEvent() {
        val first = builder().setCategory(Notification.CATEGORY_MESSAGE).setWhen(1_000).build()
        val repost = builder().setCategory(Notification.CATEGORY_MESSAGE).setWhen(9_000).build()
        assertEquals(id(first), id(repost))
        assertNotEquals(id(first), id(repost, "another message"))
        assertNull(id(builder().setCategory(Notification.CATEGORY_CALL).build()))
        assertNull(id(builder().setCategory(Notification.CATEGORY_PROGRESS).build()))
    }
}
