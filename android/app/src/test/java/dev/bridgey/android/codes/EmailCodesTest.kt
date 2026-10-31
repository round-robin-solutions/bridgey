package dev.bridgey.android.codes

import dev.bridgey.android.LoggingPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Codes from email, phone side (docs/codes-from-email.md section 9). Synthetic mails only. */
class EmailCodesTest {
    private val own = "dev.bridgey.android"

    @Test fun theFourMailAppsAndNothingElse() {
        assertEquals(
            setOf("com.google.android.gm", "com.microsoft.office.outlook", "ch.protonmail.android", "com.readdle.spark"),
            EMAIL_APP_PACKAGES,
        )
        EMAIL_APP_PACKAGES.forEach { assertTrue(it, isEmailAppNotification(it, own, groupSummary = false, isCall = false)) }
        // Other mail apps (even ones that post CATEGORY_EMAIL) are not in the list.
        listOf("com.samsung.android.email.provider", "com.yahoo.mobile.client.android.mail", "com.whatsapp", "com.google.android.apps.messaging")
            .forEach { assertFalse(it, isEmailAppNotification(it, own, groupSummary = false, isCall = false)) }
    }

    @Test fun summariesCallsAndBridgeyItselfAreNotMail() {
        assertFalse(isEmailAppNotification("com.google.android.gm", own, groupSummary = true, isCall = false))
        assertFalse(isEmailAppNotification("com.microsoft.office.outlook", own, groupSummary = false, isCall = true))
        // A build whose own package were a mail package still never counts its own notifications.
        assertFalse(isEmailAppNotification("com.readdle.spark", "com.readdle.spark", groupSummary = false, isCall = false))
    }

    @Test fun bigTextGetsTheSubjectInFrontWhenItLacksIt() {
        val content = EmailNotificationContent(text = "Your GitHub code", bigText = "Use 482913 to sign in. It expires in 10 minutes.")
        assertEquals("Your GitHub code\nUse 482913 to sign in. It expires in 10 minutes.", emailExpandedText(content))
        // Gmail's big text usually starts with the subject already: no second copy.
        val withSubject = EmailNotificationContent(text = "Your GitHub code", bigText = "Your GitHub code\nUse 482913 to sign in.")
        assertEquals("Your GitHub code\nUse 482913 to sign in.", emailExpandedText(withSubject))
        val containsSubject = EmailNotificationContent(text = "sign-in code", bigText = "Microsoft account sign-in code 551203")
        assertEquals("Microsoft account sign-in code 551203", emailExpandedText(containsSubject))
    }

    @Test fun plainTextWhenThereIsNoBigText() {
        assertEquals("Code 7781 for Proton", emailExpandedText(EmailNotificationContent(text = "  Code 7781 for Proton  ")))
        assertNull(emailExpandedText(EmailNotificationContent(text = "", bigText = "  ")))
        assertNull(emailExpandedText(EmailNotificationContent(text = null)))
    }

    @Test fun inboxWithSeveralLinesIsASummaryAndGetsNoPreview() {
        val inbox = EmailNotificationContent(
            text = "2 new emails",
            bigText = "GitHub: code 482913",
            textLines = listOf("GitHub  Your code 482913", "Bank  Statement ready"),
        )
        assertNull(emailExpandedText(inbox))
        assertNull(emailPreview(inbox, redacted = false))
        // One line is one mail: the usual text rules apply, and the line is the last resort.
        val one = EmailNotificationContent(text = "Your code", textLines = listOf("GitHub  Your code 482913"))
        assertEquals("Your code", emailExpandedText(one))
        val onlyLine = EmailNotificationContent(text = "", textLines = listOf("GitHub  Your code 482913"))
        assertEquals("GitHub  Your code 482913", emailExpandedText(onlyLine))
    }

    @Test fun messagingStyleUsesTheNewestMessage() {
        val content = EmailNotificationContent(
            text = "2 messages",
            messages = listOf(StyleMessage("Old code 111111", 1_000), StyleMessage("New code 222222", 3_000), StyleMessage("Middle 333333", 2_000)),
        )
        assertEquals("New code 222222", emailExpandedText(content))
        // Same time: the later one in the list.
        val tie = EmailNotificationContent(text = "x", messages = listOf(StyleMessage("first 1234", 5), StyleMessage("second 5678", 5)))
        assertEquals("second 5678", emailExpandedText(tie))
    }

    @Test fun shortTextIsKeptWhole() {
        val text = "Code 482913 " + "a".repeat(300)
        assertEquals(text, capEmailPreview(text))
        val exactly = "x".repeat(594) + " 48291"
        assertEquals(600, exactly.length)
        assertEquals(exactly, capEmailPreview(exactly))
    }

    @Test fun longTextIsCutAtTheLastWhitespaceAtOrBefore600() {
        // A token straddles 600: the cut falls before it, never inside.
        val head = "Your code is 482913. " + "word ".repeat(114)
        val long = head + "abcdefghij123 tail"
        val capped = capEmailPreview(long)!!
        assertTrue(capped.length <= EMAIL_PREVIEW_MAX_LENGTH)
        assertEquals(head.trimEnd(), capped)
        assertFalse(capped.contains("abcdefghij"))
        // Whitespace exactly at 600 keeps the first 600 units.
        assertEquals("y".repeat(600), capEmailPreview("y".repeat(600) + " more"))
        assertNull("no whitespace at or before 600: never cut inside a token", capEmailPreview("z".repeat(700)))
        val edge = "a ".repeat(299) + "bb" + " rest of the mail"
        assertEquals(600, edge.indexOf(" rest"))
        assertEquals(edge.substring(0, 600), capEmailPreview(edge))
    }

    @Test fun theCutNeverSplitsASurrogatePair() {
        val emoji = "🔒" // one character, two UTF-16 units
        val text = "Code 482913 " + emoji.repeat(400)
        val capped = capEmailPreview(text)
        assertEquals("Code 482913", capped)
        capped!!.forEachIndexed { index, c ->
            if (Character.isHighSurrogate(c)) assertTrue(index + 1 < capped.length && Character.isLowSurrogate(capped[index + 1]))
        }
    }

    @Test fun previewOnlyWhenItLooksLikeOtpTraffic() {
        assertEquals(
            "Your sign-in code\nEnter 482913 to continue.",
            emailPreview(EmailNotificationContent(text = "Your sign-in code", bigText = "Enter 482913 to continue."), redacted = false),
        )
        assertEquals("Code 591-047", emailPreview(EmailNotificationContent(text = "Code 591-047"), redacted = false))
        assertNull(emailPreview(EmailNotificationContent(text = "Lunch on Friday?", bigText = "Are you free at noon? Let me know."), redacted = false))
        // The gate runs on what would be sent: a code only past the cut does not count.
        val late = "Hello " + "news ".repeat(130) + "code 482913"
        assertTrue(late.length > EMAIL_PREVIEW_MAX_LENGTH)
        assertNull(emailPreview(EmailNotificationContent(text = late), redacted = false))
    }

    @Test fun hiddenMailIsDetectedAndGetsNoPreview() {
        val hidden = EmailNotificationContent(text = DEFAULT_REDACTED_TEXT)
        assertTrue(isRedactedEmailNotification(hidden, null))
        assertTrue(isRedactedEmailNotification(EmailNotificationContent(text = "Subject", bigText = "Inhalt ausgeblendet"), "Inhalt ausgeblendet"))
        assertFalse(isRedactedEmailNotification(EmailNotificationContent(text = "Your code 482913"), null))
        assertNull(emailPreview(EmailNotificationContent(text = "Your code 482913"), redacted = true))
    }

    @Test fun onlyAMacWithTheKeyGetsTheEmailFields() {
        val preview = "Your code 482913"
        // A Mac without email_codes_draft1 (or with the phone's switch off) gets exactly the old payload.
        assertTrue(emailPayloadFields(emailApp = true, preview = preview, redacted = false, peerReadsEmail = false, switchOn = true).isEmpty())
        assertTrue(emailPayloadFields(emailApp = true, preview = preview, redacted = false, peerReadsEmail = true, switchOn = false).isEmpty())
        assertTrue(emailPayloadFields(emailApp = false, preview = null, redacted = null, peerReadsEmail = true, switchOn = true).isEmpty())
        assertEquals(
            mapOf("emailApp" to true, "redacted" to false, "preview" to preview),
            emailPayloadFields(emailApp = true, preview = preview, redacted = false, peerReadsEmail = true, switchOn = true),
        )
        // Hidden mail: the Mac hears it was hidden, and never gets a preview.
        assertEquals(
            mapOf("emailApp" to true, "redacted" to true),
            emailPayloadFields(emailApp = true, preview = preview, redacted = true, peerReadsEmail = true, switchOn = true),
        )
        // No code-shaped text: emailApp only.
        assertEquals(
            mapOf<String, Any>("emailApp" to true, "redacted" to false),
            emailPayloadFields(emailApp = true, preview = null, redacted = false, peerReadsEmail = true, switchOn = true),
        )
    }

    @Test fun advertisedOnlyWithNotificationsAndTheSwitchOn() {
        assertTrue(emailCodesAdvertised(notificationsOn = true, switchOn = true))
        assertFalse(emailCodesAdvertised(notificationsOn = false, switchOn = true))
        assertFalse(emailCodesAdvertised(notificationsOn = true, switchOn = false))
        assertEquals("email_codes_draft1", EMAIL_CODES_FEATURE_KEY)
        assertTrue(EMAIL_CODES_DEFAULT)
    }

    @Test fun mailNeverLogsTitleOrTextEvenWithContentLoggingOn() {
        val verbose = LoggingPolicy(notificationContent = true)
        val title = "GitHub"
        val text = "Your code 482913"
        EMAIL_APP_PACKAGES.forEach { pkg ->
            val line = forwardedNotificationLogLine(verbose, "Mail", pkg, smsDefaultApp = false, title = title, text = text)
            assertNotNull(line)
            assertEquals("NOTIFICATION sent app=\"Mail\"", line)
            assertFalse(line!!.contains("482913") || line.contains(title))
        }
        // SMS stays hidden too; other apps log content only because the person turned it on.
        assertEquals("NOTIFICATION sent app=\"Messages\"", forwardedNotificationLogLine(verbose, "Messages", "com.sms", true, "Bank", "OTP 1234"))
        assertEquals(
            "NOTIFICATION sent app=\"Chat\" title=\"Asha\" text=\"See you\"",
            forwardedNotificationLogLine(verbose, "Chat", "com.chat", false, "Asha", "See you"),
        )
    }
}
