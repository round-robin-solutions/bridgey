package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Text messages in setup: its bundle, follow-up, permissions and coverage. */
class SetupMessagesTest {
    @Test
    fun theBundlePicksTextMessagesAndAsksHowRepliesGo() {
        val bundle = SetupBundles.all.first { it.id == "messages" }
        assertEquals(mapOf("messages" to Answers.PICK), bundle.answers)
        val question = SetupQuestions.question("messages")!!
        assertEquals("messages", question.feature)
        assertEquals(
            listOf(SettingChange.on(SetupSetting.FEATURE_SMS), SettingChange.off(SetupSetting.SMS_REPLY_AS_SMS)),
            SetupQuestions.changes(question, Answers.APP),
        )
        assertEquals(
            listOf(SettingChange.on(SetupSetting.FEATURE_SMS), SettingChange.on(SetupSetting.SMS_REPLY_AS_SMS)),
            SetupQuestions.changes(question, Answers.SMS),
        )
        assertEquals("MESSAGES", question.settingsPage)
    }

    @Test
    fun textMessagesStaysOffWithoutSmsAccess() {
        val sms = SetupQuestions.permission(PermissionKind.SMS)!!
        assertEquals(listOf(SettingChange.off(SetupSetting.FEATURE_SMS)), sms.offWhenRefused)
        assertTrue(sms.runtime)
        // Contacts only adds names: refusing it changes nothing.
        assertTrue(SetupQuestions.permission(PermissionKind.CONTACTS)!!.offWhenRefused.isEmpty())
    }

    @Test
    fun simsAreAskedForOnlyOnDualSimPhones() {
        val phone = SetupQuestions.permission(PermissionKind.PHONE_CALLS)!!
        val on = mapOf(SetupSetting.FEATURE_SMS to "true", SetupSetting.FEATURE_CALLS to "false")
        assertFalse(phone.needed(Effective(SetupFacts(current = on, dualSim = false))))
        assertTrue(phone.needed(Effective(SetupFacts(current = on, dualSim = true))))
        assertTrue("messages" in phone.features)
    }

    /** Android 15: the phone-to-Mac link lets a notification reply find its conversation (Rahul, 2026-10-27). */
    @Test
    fun textMessagesAsksForTheLinkCodesUses() {
        val link = SetupQuestions.permission(PermissionKind.COMPANION_LINK)!!
        val both = mapOf(SetupSetting.FEATURE_SMS to "true", SetupSetting.FEATURE_NOTIFICATIONS to "true", SetupSetting.CODES_LINK to "false")
        assertTrue("messages" in link.features)
        assertTrue(link.needed(Effective(SetupFacts(current = both, codesLinkApplies = true))))
        assertFalse("Android 14 and older hide nothing", link.needed(Effective(SetupFacts(current = both, codesLinkApplies = false))))
        assertFalse("without notifications there is nothing to reply to",
            link.needed(Effective(SetupFacts(current = both + (SetupSetting.FEATURE_NOTIFICATIONS to "false"), codesLinkApplies = true))))
        // One link for codes and Text messages: once made, the page has nothing left to ask for it.
        val state = SetupState(picked = setOf("messages", "notifications"))
        val facts = SetupFacts(current = both, codesLinkApplies = true, granted = setOf(PermissionKind.SMS, PermissionKind.CONTACTS, PermissionKind.NOTIFICATION_ACCESS, PermissionKind.BATTERY))
        assertTrue(SetupFlow.neededPermissions(state, facts).any { it.kind == PermissionKind.COMPANION_LINK })
        assertTrue(SetupFlow.permissionsPage(state, facts))
        assertFalse(SetupFlow.permissionsPage(state, facts.copy(granted = facts.granted + PermissionKind.COMPANION_LINK)))
        // Refusing it keeps Text messages on.
        assertFalse(link.offWhenRefused.any { it.setting == SetupSetting.FEATURE_SMS })
    }

    @Test
    fun offByDefaultAndCovered() {
        assertEquals("false", SetupSetting.FEATURE_SMS.default)
        assertEquals("messages" to Coverage.ANSWER, SetupQuestions.coverage[SetupSetting.FEATURE_SMS])
        assertEquals("messages" to Coverage.ANSWER, SetupQuestions.coverage[SetupSetting.SMS_REPLY_AS_SMS])
        assertEquals("MESSAGES", SetupFeatures.feature("messages")!!.page)
    }
}
