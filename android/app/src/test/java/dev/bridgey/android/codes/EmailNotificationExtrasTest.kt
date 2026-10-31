package dev.bridgey.android.codes

import android.app.Application
import android.app.Notification
import android.app.Person
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.emailNotificationContent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The listener's reading of real notification extras (BigText, Inbox and Messaging styles) into the pure rules of
 * EmailCodes.kt, and a hidden mail feeding Code access like a hidden SMS. Synthetic mails only.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class EmailNotificationExtrasTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()

    private fun builder() = Notification.Builder(context, "mail").setSmallIcon(android.R.drawable.ic_dialog_email)

    private fun text(notification: Notification) = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()

    @Test fun bigTextStyleGivesSubjectAndBody() {
        val notification = builder()
            .setContentTitle("GitHub")
            .setContentText("Your GitHub sign-in code")
            .setStyle(Notification.BigTextStyle().bigText("Use 482913 to sign in. It expires in 10 minutes."))
            .build()
        val content = emailNotificationContent(notification, text(notification))
        assertEquals("Use 482913 to sign in. It expires in 10 minutes.", content.bigText)
        assertEquals("Your GitHub sign-in code\nUse 482913 to sign in. It expires in 10 minutes.", emailPreview(content, redacted = false))
    }

    @Test fun inboxStyleWithSeveralMailsIsASummary() {
        val notification = builder()
            .setContentTitle("2 new emails")
            .setContentText("GitHub, Bank")
            .setStyle(Notification.InboxStyle().addLine("GitHub  Your code 482913").addLine("Bank  Statement ready"))
            .build()
        val content = emailNotificationContent(notification, text(notification))
        assertEquals(2, content.textLines?.size)
        assertNull(emailPreview(content, redacted = false))
    }

    @Test fun messagingStyleGivesTheNewestMessage() {
        val sender = Person.Builder().setName("Spark").build()
        val notification = builder()
            .setStyle(
                Notification.MessagingStyle(Person.Builder().setName("Me").build())
                    .addMessage("Old code 111111", 1_000, sender)
                    .addMessage("Your new code is 222222", 2_000, sender),
            )
            .build()
        val content = emailNotificationContent(notification, text(notification))
        assertEquals("Your new code is 222222", emailPreview(content, redacted = false))
    }

    @Test fun hiddenMailCountsAsHiddenCodeAccess() {
        val monitor = CodeAccessMonitor(context)
        monitor.observeEmail(redacted = false)
        // A visible mail says nothing either way.
        assertEquals(1, monitor.emailSeen.get())
        assertEquals(0, monitor.emailHidden.get())
        monitor.observeEmail(redacted = true)
        assertEquals(CodeAccessStatus.HIDDEN, monitor.status.value)
        assertEquals(1, monitor.emailHidden.get())
        // The companion link lifts it, as for SMS.
        monitor.linkChanged()
        assertNotEquals(CodeAccessStatus.HIDDEN, monitor.status.value)
    }
}
