package dev.bridgey.android.setup

import dev.bridgey.android.ui.SettingsSection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The coverage table and the answers-to-settings mapping. */
class SetupQuestionsTest {
    private fun q(id: String) = SetupQuestions.question(id)!!
    private fun changes(id: String, key: String) = SetupQuestions.changes(q(id), key).associate { it.setting to it.value }

    /** The permission behind a setting that only a permission turns on. */
    private val byPermission = mapOf(
        SetupSetting.NOTIFICATION_ACCESS to PermissionKind.NOTIFICATION_ACCESS,
        SetupSetting.APP_NOTIFICATIONS to PermissionKind.POST_NOTIFICATIONS,
        SetupSetting.CODES_LINK to PermissionKind.COMPANION_LINK,
        SetupSetting.BATTERY_EXEMPTION to PermissionKind.BATTERY,
    )

    @Test
    fun everySettingTheOldAdvancedSetupShowedIsCovered() {
        val missing = SetupSetting.entries.filter { it !in SetupQuestions.coverage }
        assertEquals("settings no question covers: $missing", emptyList<SetupSetting>(), missing)
    }

    @Test
    fun answerCoverageIsBackedByARealAnswer() {
        SetupQuestions.coverage.forEach { (setting, entry) ->
            val (id, how) = entry
            if (how != Coverage.ANSWER) return@forEach
            val question = q(id)
            val bySetting = question.answers.any { answer -> answer.changes.any { it.setting == setting } }
            val byAsking = question.answers.any { it.permission != null && it.permission == byPermission[setting] }
            val special = (setting == SetupSetting.PAIRING && id == "pair") || (setting == SetupSetting.OEM_CHECKLIST && id == "background") ||
                (setting == SetupSetting.HIDDEN_NOTIFICATION_APPS && question.multiPick)
            assertTrue("$setting is not set by any answer of $id", bySetting || byAsking || special)
        }
    }

    @Test
    fun moreOptionsOpenARealSettingsPage() {
        SetupQuestions.all.forEach { question ->
            val page = question.settingsPage ?: return@forEach
            assertNotNull("${question.id}: $page", SettingsSection.entries.firstOrNull { it.name == page })
        }
        SetupQuestions.coverage.filterValues { it.second == Coverage.MORE_OPTIONS }.forEach { (setting, entry) ->
            assertNotNull("$setting needs More options on ${entry.first}", q(entry.first).settingsPage)
        }
    }

    @Test
    fun answersOnlyChangeWhatTheirQuestionCovers() {
        SetupQuestions.all.forEach { question ->
            question.answers.flatMap { it.changes + it.onDenied }.forEach { change ->
                assertTrue("${question.id} changes ${change.setting} without covering it", change.setting in question.covers)
            }
        }
    }

    @Test
    fun theCatalogueIsWellFormed() {
        val ids = SetupQuestions.all.map { it.id }
        assertEquals(ids.distinct(), ids)
        SetupQuestions.all.forEach { question ->
            assertEquals(question.answers.map { it.key }.distinct(), question.answers.map { it.key })
            question.offKey?.let { assertNotNull("${question.id} off answer $it", question.answer(it)) }
            assertTrue(question.id, question.answers.isNotEmpty() || question.id == "pair")
        }
        // The agreed section order.
        val sections = SetupQuestions.all.map { it.section.ordinal }
        assertEquals(sections.sorted(), sections)
        SetupBundles.all.forEach { bundle ->
            bundle.answers.forEach { (id, key) -> assertNotNull("${bundle.id}: $id=$key", SetupQuestions.question(id)?.answer(key)) }
        }
    }

    @Test
    fun answersMapToTheirSettings() {
        assertEquals(mapOf(SetupSetting.FEATURE_CLIPBOARD to "true", SetupSetting.AUTO_CLIPBOARD to "true"), changes("clipboard", Answers.AUTO))
        assertEquals(mapOf(SetupSetting.FEATURE_CLIPBOARD to "true", SetupSetting.AUTO_CLIPBOARD to "false"), changes("clipboard", Answers.TAP))
        assertEquals(mapOf(SetupSetting.FEATURE_CLIPBOARD to "false"), changes("clipboard", Answers.NO))
        assertEquals(mapOf(SetupSetting.CLIPBOARD_FILES to "false"), changes("clipboard_files", Answers.TEXT))
        assertEquals(PermissionKind.PHOTOS, q("clipboard_screenshot").answer(Answers.YES)!!.permission)

        val notifications = q("notifications").answer(Answers.YES)!!
        assertEquals(PermissionKind.NOTIFICATION_ACCESS, notifications.permission)
        assertEquals(listOf(SettingChange.off(SetupSetting.FEATURE_NOTIFICATIONS)), notifications.onDenied)
        assertEquals(mapOf(SetupSetting.HIDDEN_NOTIFICATION_APPS to "com.whatsapp,org.telegram.messenger"),
            changes("notification_apps", Answers.PICKED + "com.whatsapp,org.telegram.messenger"))

        val calls = q("calls").answer(Answers.YES)!!
        assertEquals(mapOf(SetupSetting.FEATURE_CALLS to "true", SetupSetting.DIRECT_CALLS to "true"), calls.changes.associate { it.setting to it.value })
        assertEquals(PermissionKind.PHONE_CALLS, calls.permission)
        assertEquals(listOf(SettingChange.off(SetupSetting.DIRECT_CALLS)), calls.onDenied)
        assertEquals(mapOf(SetupSetting.FEATURE_CALLS to "true", SetupSetting.DIRECT_CALLS to "false"), changes("calls", Answers.SEE))

        assertEquals(mapOf(SetupSetting.ALLOW_BROWSE to "true", SetupSetting.ALLOW_REPLACE to "false"), changes("files_browse", Answers.BROWSE))
        assertEquals(mapOf(SetupSetting.ALLOW_BROWSE to "true", SetupSetting.ALLOW_REPLACE to "true"), changes("files_browse", Answers.CHANGE))
        assertEquals(mapOf(SetupSetting.FOLDER_MODE to "RECEIVER_ASKS"), changes("files_folder", Answers.ASK))
        assertEquals(mapOf(SetupSetting.FOLDER_MODE to "FIXED"), changes("files_folder", Answers.FIXED))

        assertEquals(mapOf(SetupSetting.FOCUS_SHARE to "true", SetupSetting.FOCUS_FOLLOW to "true"), changes("focus", Answers.BOTH))
        assertEquals(mapOf(SetupSetting.FOCUS_SHARE to "false", SetupSetting.FOCUS_FOLLOW to "true"), changes("focus", Answers.FOLLOW))
        assertEquals(mapOf(SetupSetting.FOCUS_SHARE to "true", SetupSetting.FOCUS_FOLLOW to "false"), changes("focus", Answers.SHARE))
        assertEquals(PermissionKind.DO_NOT_DISTURB, q("focus").answer(Answers.FOLLOW)!!.permission)
        assertEquals(null, q("focus").answer(Answers.SHARE)!!.permission)

        assertEquals(mapOf(SetupSetting.FEATURE_FIND_DEVICE to "true", SetupSetting.FEATURE_PING to "true"), changes("find", Answers.YES))
        assertEquals(mapOf(SetupSetting.LOGGING_CONNECTION to "false"), changes("stats", Answers.NO))
        assertEquals(mapOf(SetupSetting.UPDATE_CHANNEL to "STABLE"), changes("updates", Answers.STEADY))
        assertEquals(mapOf(SetupSetting.UPDATE_CHANNEL to "BETA"), changes("updates", Answers.EARLY))
        assertEquals(mapOf(SetupSetting.UPDATE_CHANNEL to "NIGHTLY"), changes("updates", Answers.NEWEST))
        assertEquals(mapOf(SetupSetting.REDUCE_MOTION to "true"), changes("motion", Answers.YES))
    }

    @Test
    fun bundlesAreNamedLikeTheirSettingsPages() {
        val titles = SettingsSection.entries.map { it.titleRes }.toSet()
        SetupBundles.all.forEach { assertTrue(it.id, it.title in titles) }
        // Typing wins over a bundle, and the result is in question order.
        assertEquals(
            listOf("clipboard" to Answers.TAP, "clipboard_files" to Answers.YES, "files" to Answers.YES),
            SetupBundles.answers(setOf("clipboard"), mapOf("files" to Answers.YES, "clipboard" to Answers.TAP)).toList(),
        )
    }
}
