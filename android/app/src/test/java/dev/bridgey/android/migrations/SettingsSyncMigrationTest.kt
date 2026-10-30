package dev.bridgey.android.migrations

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.sync.SettingsSyncController
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.SyncPermissions
import dev.bridgey.android.sync.SyncRecord
import dev.bridgey.android.sync.phoneSyncedSettings
import dev.bridgey.android.ui.UiPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The first build with settings sync (v0.10) on a phone from an earlier release: every setting the person stored
 * is stamped as chosen (`changedAt 1, version 1`), every other one as never chosen, and nothing in the older files
 * changes (docs/folders-and-settings-sync.md 8.4). Fixtures in `protocol/test-vectors/migrations/android/shared_prefs`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SettingsSyncMigrationTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()
    private val phone = MigrationFixtures.PHONE_ID

    private object Granted : SyncPermissions {
        override fun notificationAccess() = true
        override fun phoneCalls() = true
        override fun camera() = true
        override fun doNotDisturb() = true
    }

    private fun start(): Pair<SettingsSyncController, BridgeySettings> {
        val settings = BridgeySettings(context, "Default name")
        val ui = UiPreferences(context)
        val sync = SettingsSyncController(
            context.getSharedPreferences(SettingsSyncController.PREFERENCES, Context.MODE_PRIVATE),
            context.getSharedPreferences(SettingsSyncController.ANSWER_PREFERENCES, Context.MODE_PRIVATE), phone, CoroutineScope(Dispatchers.Unconfined),
        )
        sync.attach(phoneSyncedSettings(settings, ui, Granted))
        return sync to settings
    }

    private fun chosen(value: Any) = SyncRecord(value, 1, 1, phone)
    private fun unchosen(value: Any) = SyncRecord(value, 0, 0, "")

    @Test
    fun files2PhoneStampsWhatThePersonChose() {
        MigrationFixtures.installSharedPrefs(context, 13)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.FILES_2_SNAPSHOT)
        val (sync, settings) = start()
        assertEquals(chosen("fixed"), sync.record(SyncKey.FOLDER_DESTINATION))
        assertEquals(chosen("merge"), sync.record(SyncKey.FOLDER_CONFLICT))
        assertEquals(chosen(false), sync.record(SyncKey.ACTIVITY_PREVIEWS))
        assertEquals(chosen(true), sync.record(SyncKey.REDUCE_MOTION))
        assertEquals(chosen(false), sync.record(SyncKey.CLIPBOARD))
        assertEquals(chosen(false), sync.record(SyncKey.MEDIA))
        assertEquals(chosen(true), sync.record(SyncKey.REMOTE_INPUT))
        assertEquals(chosen(false), sync.record(SyncKey.AUTO_CLIPBOARD))
        assertEquals(chosen(false), sync.record(SyncKey.CLIPBOARD_FILES))
        // Never stored: an older install keeps its on-by-default features, not chosen.
        assertEquals(unchosen(true), sync.record(SyncKey.CALLS))
        assertEquals(unchosen(true), sync.record(SyncKey.FILES))
        assertEquals(unchosen(false), sync.record(SyncKey.FOCUS_SHARE))
        // Stored and relayed only on the phone.
        assertEquals(unchosen(false), sync.record(SyncKey.CODES))
        // Per-device overrides and the file access guards are untouched and never become records.
        assertFalse(settings.isEnabled(dev.bridgey.android.BridgeyFeature.FILES, MigrationFixtures.MAC_B))
        assertEquals(true, settings.state.value.allowReplaceFromOtherDevices)
        assertEquals(false, settings.state.value.allowBrowseFromOtherDevices)
    }

    @Test
    fun automationPhoneStampsFocusAndTheNewSwitches() {
        MigrationFixtures.installSharedPrefs(context, 13)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.FILES_2_SNAPSHOT)
        MigrationFixtures.installSharedPrefs(context, MigrationFixtures.AUTOMATION_SNAPSHOT)
        val (sync, _) = start()
        assertEquals(chosen(true), sync.record(SyncKey.FOCUS_SHARE))
        assertEquals(chosen(true), sync.record(SyncKey.FOCUS_FOLLOW))
        assertEquals(chosen(true), sync.record(SyncKey.MAC_ACTIONS))
        assertEquals(chosen(true), sync.record(SyncKey.CAMERA))
        assertEquals(unchosen("sender_picks"), sync.record(SyncKey.FOLDER_DESTINATION))
    }

    @Test
    fun beta1PhoneHasOnlyItsFeatureChoicesStamped() {
        MigrationFixtures.installSharedPrefs(context, 1)
        val (sync, _) = start()
        assertEquals(chosen(false), sync.record(SyncKey.CLIPBOARD))
        assertEquals(unchosen(false), sync.record(SyncKey.REDUCE_MOTION))
        assertEquals(unchosen(true), sync.record(SyncKey.ACTIVITY_PREVIEWS))
        assertEquals(unchosen("ask"), sync.record(SyncKey.FOLDER_CONFLICT))
    }

    @Test
    fun hiddenAndSystemFileChoicesAreStampedOnlyWhenThePersonMadeThem() {
        MigrationFixtures.installSharedPrefs(context, 13)
        val (fresh, _) = start()
        assertEquals(unchosen(false), fresh.record(SyncKey.FOLDER_INCLUDE_HIDDEN))
        assertEquals(unchosen(false), fresh.record(SyncKey.FOLDER_INCLUDE_SYSTEM))
        // The phone's own switches are the ones behind the keys, so a change there is a stamped edit.
        val (sync, settings) = start()
        settings.setFolderIncludeHidden(true)
        sync.localChanged()
        assertEquals(true, sync.record(SyncKey.FOLDER_INCLUDE_HIDDEN)!!.value)
        assertEquals(1L, sync.record(SyncKey.FOLDER_INCLUDE_HIDDEN)!!.version)
        assertEquals(unchosen(false), sync.record(SyncKey.FOLDER_INCLUDE_SYSTEM))
    }

    @Test
    fun connectAwayIsOnUntilChosenAndItsDefaultIsNeverStampedAsAChoice() {
        MigrationFixtures.installSharedPrefs(context, 13)
        val (sync, settings) = start()
        // Never set: on, not a choice, and a local scan stamps nothing.
        assertEquals(true, settings.state.value.connectAway)
        assertEquals(unchosen(true), sync.record(SyncKey.CONNECT_AWAY))
        sync.localChanged()
        assertEquals(unchosen(true), sync.record(SyncKey.CONNECT_AWAY))
        // An explicit off is a choice, and it survives a restart (an upgrade reads the same stored value).
        settings.setConnectAway(false)
        sync.localChanged()
        val off = sync.record(SyncKey.CONNECT_AWAY)!!
        assertEquals(false, off.value)
        assertEquals(1L, off.version)
        val (again, reloaded) = start()
        assertEquals(false, reloaded.state.value.connectAway)
        assertEquals(off, again.record(SyncKey.CONNECT_AWAY))
    }

    @Test
    fun theStampHappensOnceAndSurvivesARestart() {
        MigrationFixtures.installSharedPrefs(context, 13)
        start()
        // A later edit is a real stamp; the next start reads the stored records instead of stamping again.
        val (sync, settings) = start()
        settings.setGlobal(dev.bridgey.android.BridgeyFeature.CALLS, false)
        sync.localChanged()
        val edited = sync.record(SyncKey.CALLS)!!
        assertEquals(false, edited.value)
        assertEquals(1L, edited.version)
        val (again, _) = start()
        assertEquals(edited, again.record(SyncKey.CALLS))
    }
}
