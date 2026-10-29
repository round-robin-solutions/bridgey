package dev.bridgey.android.setup

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Each reset choice deletes exactly its items and leaves the rest. Robolectric's sandboxed
 * preferences and temporary directories only; the Keystore is a fake.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class LocalDataResetTest {
    @get:Rule val temp = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var roots: Map<ResetRoot, File>
    private val hooks = mutableListOf<ResetHook>()
    private val aliases = mutableSetOf<String>()

    /** Every preferences file Bridgey writes, with a value in each. */
    private val preferences = listOf(
        "bridgey", "bridgey.settings", "bridgey.ui", "bridgey.remote", "bridgey.screenshot", "bridgey.updates", "bridgey.places",
        "bridgey.setup", "bridgey_onboarding", "bridgey.trust", "bridgey.reconnect", "bridgey_codes", "bridgey.whats_new",
        "bridgey.attach",
        // v0.9 automation: each Mac's saved list of Mac actions, and the widgets' Macs.
        "bridgey.mac_actions", "bridgey.widgets",
        // Text messages: which permissions it asked for.
        "bridgey.sms.asked",
        // v0.10 settings sync: records, switches and choices; first-connect answers.
        "bridgey.sync", "bridgey.sync.answers",
    )

    /** Every file and directory, relative to its root. */
    private val files = listOf(
        ResetRoot.NO_BACKUP to "activity-stream.json",
        ResetRoot.NO_BACKUP to "diagnostics.json",
        ResetRoot.NO_BACKUP to "clipboard-cache/offer-1/0/data",
        ResetRoot.NO_BACKUP to "folder-transfers/abc.journal",
        ResetRoot.NO_BACKUP to "folder-sends/def.plan",
        ResetRoot.NO_BACKUP to "document-index.json",
        ResetRoot.CACHE to "diagnostics/Bridgey-Diagnostics.json",
        ResetRoot.CACHE to "updates/bridgey-610.apk",
        ResetRoot.CACHE to "perf-test/bench.bin",
        // v0.9: a camera photo waiting to be sent to a Mac.
        ResetRoot.CACHE to "camera/photo-1.jpg",
        ResetRoot.FILES to "kept.txt",
    )

    @Before
    fun seed() {
        roots = ResetRoot.entries.associateWith { temp.newFolder(it.name.lowercase()) }
        preferences.forEach { context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().putString("seed", it).commit() }
        files.forEach { (root, path) -> File(roots.getValue(root), path).apply { parentFile!!.mkdirs(); writeText(path) } }
        aliases += LocalDataReset.IDENTITY_ALIAS
        aliases += "someone.else"
    }

    private fun reset(choice: ResetChoice) {
        val environment = AndroidResetEnvironment(context, hooks = { hooks += it }, directories = roots::getValue, deleteAlias = { aliases -= it })
        LocalDataReset(environment).perform(choice)
    }

    private fun present(name: String) = context.getSharedPreferences(name, Context.MODE_PRIVATE).getString("seed", null) != null
    private fun exists(root: ResetRoot, path: String) = File(roots.getValue(root), path).exists()

    private fun assertState(deletedPreferences: Set<String>, deletedFiles: Set<String>) {
        preferences.forEach { assertEquals("preferences $it", it !in deletedPreferences, present(it)) }
        files.forEach { (root, path) -> assertEquals("file $path", path !in deletedFiles, exists(root, path)) }
    }

    @Test
    fun activityAndLogs() {
        reset(ResetChoice.ACTIVITY_AND_LOGS)
        assertState(emptySet(), setOf("activity-stream.json", "diagnostics.json", "diagnostics/Bridgey-Diagnostics.json"))
        assertEquals(
            listOf(ResetHook.CLEAR_ACTIVITY, ResetHook.CLEAR_DIAGNOSTICS, ResetHook.CLEAR_CONNECTION_HEALTH, ResetHook.CLEAR_TRANSFER_HISTORY),
            hooks,
        )
        assertTrue(LocalDataReset.IDENTITY_ALIAS in aliases)
    }

    @Test
    fun modelsAndCaches() {
        reset(ResetChoice.MODELS_AND_CACHES)
        assertState(
            setOf("bridgey.mac_actions"),
            setOf(
                "clipboard-cache/offer-1/0/data", "folder-transfers/abc.journal", "folder-sends/def.plan", "document-index.json",
                "updates/bridgey-610.apk", "perf-test/bench.bin", "camera/photo-1.jpg",
            ),
        )
        // The cache directory itself stays, as do exported diagnostics (Activity and logs owns them).
        assertTrue(roots.getValue(ResetRoot.CACHE).isDirectory)
        assertEquals(listOf(ResetHook.CLEAR_CLIPBOARD_CACHE, ResetHook.CLEAR_MAC_ACTION_CATALOGS), hooks)
    }

    @Test
    fun settings() {
        reset(ResetChoice.SETTINGS)
        assertState(
            setOf(
                "bridgey.settings", "bridgey.ui", "bridgey.remote", "bridgey.screenshot", "bridgey.attach", "bridgey.widgets", "bridgey.updates",
                "bridgey.places", "bridgey.setup", "bridgey_onboarding", "bridgey.sms.asked", "bridgey.sync",
            ),
            emptySet(),
        )
        // The Do Not Disturb that Follow turned on is handed back before the Focus switches go.
        assertEquals(listOf(ResetHook.RELEASE_FOCUS, ResetHook.RELEASE_FOLDER_GRANTS), hooks)
        assertTrue(LocalDataReset.needsRestart(ResetChoice.SETTINGS))
    }

    @Test
    fun everythingIncludingPairings() {
        reset(ResetChoice.EVERYTHING)
        assertState(preferences.toSet(), files.map { it.second }.toSet() - "kept.txt")
        assertFalse(LocalDataReset.IDENTITY_ALIAS in aliases)
        assertTrue("someone.else" in aliases)
        // Sessions close before anything is deleted.
        assertEquals(ResetHook.DISCONNECT, hooks.first())
        assertEquals(ResetHook.entries.toSet(), hooks.toSet())
        assertTrue(LocalDataReset.needsRestart(ResetChoice.EVERYTHING))
    }

    @Test
    fun itemsAndKeptListsDoNotOverlap() {
        val small = ResetChoice.entries - ResetChoice.EVERYTHING
        small.forEach { a ->
            small.filter { it != a }.forEach { b -> assertTrue(LocalDataReset.items(a).intersect(LocalDataReset.items(b).toSet()).isEmpty()) }
        }
        assertEquals(ResetItem.entries.toSet(), LocalDataReset.items(ResetChoice.EVERYTHING).toSet())
        ResetChoice.entries.forEach { assertTrue(LocalDataReset.kept(it).isNotEmpty()) }
        assertFalse(LocalDataReset.needsRestart(ResetChoice.ACTIVITY_AND_LOGS))
    }
}
