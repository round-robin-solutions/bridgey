package dev.bridgey.android.migrations

import dev.bridgey.android.activity.ActivityLog
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
        )
        assertSource("BridgeySettings.kt", "getSharedPreferences(\"bridgey.settings\", Context.MODE_PRIVATE)")
        assertSource("ReconnectAndroid.kt", "getSharedPreferences(\"bridgey.reconnect\", Context.MODE_PRIVATE)", "KEY = \"address_book_v1\"")
        assertSource("ui/UiPreferences.kt", "getSharedPreferences(\"bridgey.ui\", Context.MODE_PRIVATE)")
        assertSource("AppUpdater.kt", "getSharedPreferences(\"bridgey.updates\", Context.MODE_PRIVATE)", "KEY_CHANNEL = \"channel\"")
    }
}
