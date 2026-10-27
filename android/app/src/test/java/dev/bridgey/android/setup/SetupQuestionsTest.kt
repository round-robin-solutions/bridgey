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

    @Test
    fun everySettingTheOldAdvancedSetupShowedIsStillReachable() {
        val missing = SetupSetting.entries.filter { it !in SetupQuestions.coverage }
        assertEquals("settings nothing reaches: $missing", emptyList<SetupSetting>(), missing)
    }

    @Test
    fun coverageIsReal() {
        SetupQuestions.coverage.forEach { (setting, entry) ->
            val (where, how) = entry
            when (how) {
                Coverage.ANSWER -> assertTrue("$setting by $where", setting in q(where).covers)
                Coverage.SWITCH -> assertTrue("$setting", SetupFeatures.all.any { setting in it.settings })
                Coverage.PERMISSION -> assertNotNull("$setting", SetupQuestions.permission(PermissionKind.valueOf(where)))
                Coverage.MORE_OPTIONS -> assertNotNull("$setting on $where", SettingsSection.entries.firstOrNull { it.name == where })
            }
        }
        // Settings that left the path are under More options, not dropped.
        listOf(SetupSetting.CLIPBOARD_FILES, SetupSetting.FOCUS_FOLLOW, SetupSetting.FOLDER_MODE, SetupSetting.REDUCE_MOTION, SetupSetting.UPDATE_CHANNEL)
            .forEach { assertEquals(Coverage.MORE_OPTIONS, SetupQuestions.coverage.getValue(it).second) }
    }

    @Test
    fun answersOnlyChangeWhatTheirQuestionCovers() {
        SetupQuestions.all.forEach { question ->
            question.answers.flatMap { it.changes }.forEach { change ->
                assertTrue("${question.id} changes ${change.setting} without covering it", change.setting in question.covers)
            }
            question.settingsPage?.let { page -> assertNotNull(SettingsSection.entries.firstOrNull { it.name == page }) }
            question.feature?.let { assertNotNull("${question.id} follows ${question.feature}", SetupFeatures.feature(it)) }
        }
        SetupFeatures.all.forEach { feature -> assertNotNull(feature.page, SettingsSection.entries.firstOrNull { it.name == feature.page }) }
    }

    @Test
    fun theCatalogueIsWellFormed() {
        val ids = SetupQuestions.all.map { it.id }
        assertEquals(ids.distinct(), ids)
        assertEquals(SetupFeatures.all.map { it.id }.distinct(), SetupFeatures.all.map { it.id })
        val sections = SetupQuestions.all.map { it.section.ordinal }
        assertEquals(sections.sorted(), sections)
        SetupBundles.all.forEach { bundle ->
            bundle.answers.keys.forEach { assertNotNull("${bundle.id}: $it", SetupFeatures.feature(it)) }
        }
    }

    @Test
    fun namesMatchSettings() {
        val pageTitles = SettingsSection.entries.associate { it.name to it.titleRes }
        // Bundles: exactly their Settings page's title.
        SetupBundles.all.forEach { bundle -> assertTrue(bundle.id, bundle.title in pageTitles.values) }
        // Switches: the page title for features with a page of their own.
        listOf("clipboard" to "CLIPBOARD", "notifications" to "NOTIFICATIONS", "calls" to "CALLS", "files" to "FILES", "remote" to "REMOTE_CONTROL")
            .forEach { (id, page) -> assertEquals(id, pageTitles.getValue(page), SetupFeatures.feature(id)!!.title) }
    }

    @Test
    fun answersMapToTheirSettings() {
        assertEquals(mapOf(SetupSetting.FEATURE_CLIPBOARD to "true", SetupSetting.AUTO_CLIPBOARD to "true"), changes("clipboard", Answers.AUTO))
        assertEquals(mapOf(SetupSetting.FEATURE_CLIPBOARD to "true", SetupSetting.AUTO_CLIPBOARD to "false"), changes("clipboard", Answers.TAP))
        assertEquals(mapOf(SetupSetting.FEATURE_CALLS to "true", SetupSetting.DIRECT_CALLS to "true"), changes("calls", Answers.YES))
        assertEquals(mapOf(SetupSetting.FEATURE_CALLS to "true", SetupSetting.DIRECT_CALLS to "false"), changes("calls", Answers.SEE))
        assertEquals(mapOf(SetupSetting.ALLOW_BROWSE to "true", SetupSetting.ALLOW_REPLACE to "true"), changes("files_browse", Answers.CHANGE))
        assertEquals(mapOf(SetupSetting.HIDDEN_NOTIFICATION_APPS to "com.whatsapp"), changes("notification_apps", Answers.PICKED + "com.whatsapp"))
        assertEquals(mapOf(SetupSetting.CODES_LINK to "true"), changes("codes", Answers.YES))
        assertEquals(listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "NIGHTLY")), SetupQuestions.typedOnly.getValue("updates").getValue(Answers.NEWEST))
        // Switches and picks turn a feature's settings on; refusals turn them off.
        assertEquals(listOf(SettingChange.on(SetupSetting.FEATURE_FIND_DEVICE)), SetupFeatures.feature("find")!!.on)
        assertEquals(listOf(SettingChange.off(SetupSetting.FEATURE_NOTIFICATIONS)), SetupQuestions.permission(PermissionKind.NOTIFICATION_ACCESS)!!.offWhenRefused)
        assertEquals(listOf(SettingChange.off(SetupSetting.DIRECT_CALLS)), SetupQuestions.permission(PermissionKind.PHONE_CALLS)!!.offWhenRefused)
        assertEquals(listOf(SettingChange.off(SetupSetting.FEATURE_CAMERA)), SetupQuestions.permission(PermissionKind.CAMERA)!!.offWhenRefused)
    }

    @Test
    fun runtimePermissionsShareOneDialogAndSpecialAccessHasItsOwnScreen() {
        val runtime = SetupQuestions.permissions.filter { it.runtime }.map { it.kind }.toSet()
        assertEquals(
            setOf(PermissionKind.POST_NOTIFICATIONS, PermissionKind.PHONE_CALLS, PermissionKind.PHOTOS, PermissionKind.CAMERA, PermissionKind.SMS, PermissionKind.CONTACTS),
            runtime,
        )
    }

    @Test
    fun bundlesPickFeaturesAndTypingWins() {
        assertEquals(
            mapOf("clipboard" to Answers.TAP, "files" to Answers.PICK),
            SetupBundles.answers(setOf("clipboard"), mapOf("files" to Answers.PICK, "clipboard" to Answers.TAP)),
        )
    }
}
