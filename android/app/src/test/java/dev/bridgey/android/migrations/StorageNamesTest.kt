package dev.bridgey.android.migrations

import dev.bridgey.android.activity.ActivityLog
import dev.bridgey.android.browse.TreeDocumentIndex
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Names that older releases wrote data under. Renaming one silently starts a new, empty store, so the
 * names are pinned here. The Keystore alias cannot be read back under Robolectric, so it is pinned
 * in the source. A change here needs a migration and a fixture (docs/upgrade-policy.md).
 */
class StorageNamesTest {
    private val sources = File(System.getProperty("bridgey.repoRoot"), "android/app/src/main/java/dev/bridgey/android")

    private fun assertSource(file: String, vararg fragments: String) {
        val text = File(sources, file).readText()
        fragments.forEach { assertTrue("$file still contains $it", text.contains(it)) }
    }

    @Test
    fun identityAndTrust() {
        assertSource(
            "PairingCoordinator.kt",
            "private val alias = \"bridgey.identity.p256.v1\"",
            "getSharedPreferences(\"bridgey.trust\", Context.MODE_PRIVATE)",
            "\"peer.\$deviceId.name\"",
            "\"peer.\$deviceId.identityKey\"",
        )
    }

    @Test
    fun deviceIdAndService() {
        assertSource(
            "BridgeyApplication.kt",
            "getSharedPreferences(\"bridgey\", MODE_PRIVATE)",
            "getString(\"device_id\", null)",
            "PREFERENCE_ENABLED = \"bridgey_enabled\"",
            "File(noBackupFilesDir, ActivityLog.FILE_NAME)",
        )
        assertSource("MainActivity.kt", "getSharedPreferences(\"bridgey_onboarding\", MODE_PRIVATE)", "getBoolean(\"completed\", false)")
    }

    @Test
    fun filesAndOtherPreferences() {
        assertEquals("activity-stream.json", ActivityLog.FILE_NAME)
        assertSource(
            "PairingCoordinator.kt",
            "CLIPBOARD_CACHE_DIRECTORY = \"clipboard-cache\"",
            "FOLDER_JOURNAL_DIRECTORY = \"folder-transfers\"",
            // Files 2.0 (0.8.0-rr.1)
            "FOLDER_SEND_JOURNAL_DIRECTORY = \"folder-sends\"",
        )
        assertEquals("document-index.json", TreeDocumentIndex.FILE_NAME)
        assertSource("browse/TreeDocumentIndex.kt", "File(context.applicationContext.noBackupFilesDir, FILE_NAME)")
        assertSource("BridgeySettings.kt", "KEY_FILES_ALLOW_BROWSE = \"files.allow_browse\"", "KEY_FOLDER_ALLOW_REPLACE = \"files.folder_allow_replace\"")
        // 0.10: the Mac's settings.folders.includeHidden and .includeSystem, same meaning and defaults (off).
        assertSource("BridgeySettings.kt", "KEY_FOLDER_INCLUDE_HIDDEN = \"files.folder_include_hidden\"", "KEY_FOLDER_INCLUDE_SYSTEM = \"files.folder_include_system\"")
        assertSource(
            "AttachUi.kt",
            "getSharedPreferences(\"bridgey.attach\", Context.MODE_PRIVATE)",
            "KEY_TAB = \"tab\"", "KEY_TARGET = \"target\"",
            "KEY_DOCUMENTS_CARD = \"documents_card_dismissed\"", "KEY_MEDIA_ASKED = \"media_asked\"",
        )
        assertSource("BridgeySettings.kt", "getSharedPreferences(\"bridgey.settings\", Context.MODE_PRIVATE)")
        assertSource("ReconnectAndroid.kt", "getSharedPreferences(\"bridgey.reconnect\", Context.MODE_PRIVATE)", "KEY = \"address_book_v1\"")
        assertSource("ui/UiPreferences.kt", "getSharedPreferences(\"bridgey.ui\", Context.MODE_PRIVATE)")
        assertSource("AppUpdater.kt", "getSharedPreferences(\"bridgey.updates\", Context.MODE_PRIVATE)", "KEY_CHANNEL = \"channel\"")
    }

    @Test
    fun automationPreferences() {
        assertSource("actions/MacActions.kt", "getSharedPreferences(\"bridgey.mac_actions\", Context.MODE_PRIVATE)", "PREFIX = \"catalog.\"")
        assertSource("widget/MacWidget.kt", "PREFERENCES = \"bridgey.widgets\"", "\"widget.\$appWidgetId\"")
        assertSource("BridgeySettings.kt", "KEY_FOCUS_SHARE = \"focus.share\"", "KEY_FOCUS_FOLLOW = \"focus.follow\"")
        assertSource("BridgeySettings.kt", "MAC_ACTIONS(\"mac_actions_draft1\"", "CAMERA(\"camera_draft1\"")
        // Camera photos wait in the cache folder (Reset > Models and caches removes them with the other caches).
        assertSource("camera/CameraActivity.kt", "CACHE_FOLDER = \"camera\"")
    }
}
