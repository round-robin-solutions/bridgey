package dev.bridgey.android.setup

import android.content.Context
import java.io.File

/** Settings > Privacy > Reset Bridgey on this device: the four choices, smallest first. */
enum class ResetChoice { ACTIVITY_AND_LOGS, MODELS_AND_CACHES, SETTINGS, EVERYTHING }

/** Where a reset item lives. Every real storage location is named here. */
sealed interface ResetTarget {
    /** A SharedPreferences file (`shared_prefs/<name>.xml`). */
    data class Preferences(val name: String) : ResetTarget

    /** A file or directory under [root]. [except] lists children of a directory that stay. */
    data class Path(val root: ResetRoot, val path: String, val except: Set<String> = emptySet()) : ResetTarget

    /** An Android Keystore alias. */
    data class KeystoreAlias(val alias: String) : ResetTarget

    /** State a running Bridgey holds in memory or in the system (sessions, grants, links). */
    data class Live(val hook: ResetHook) : ResetTarget
}

enum class ResetRoot { FILES, NO_BACKUP, CACHE }

/** What a reset asks the running app to do, besides deleting files. */
enum class ResetHook {
    /** Close every session before pairings go (so no Mac is told anything half-way). */
    DISCONNECT,
    CLEAR_ACTIVITY,
    CLEAR_DIAGNOSTICS,
    CLEAR_TRANSFER_HISTORY,
    CLEAR_CLIPBOARD_CACHE,
    /** Release Android's persisted folder grants (Places). */
    RELEASE_FOLDER_GRANTS,
    /** Remove the companion association (Codes from messages link). */
    REMOVE_COMPANION_LINK,
    /** v0.9: connection health counters (round trips, last disconnect, reconnect attempts), kept in memory. */
    CLEAR_CONNECTION_HEALTH,
    /** v0.9: the Macs' action lists held in memory, so Device Controls and widgets stop offering them. */
    CLEAR_MAC_ACTION_CATALOGS,
    /** v0.9: hand back the Do Not Disturb that Follow the Mac's Focus turned on, before the setting goes. */
    RELEASE_FOCUS,
}

/** One line in a confirm dialog, with the places it deletes. Copy: strings_setup.xml `reset_item_<key>`. */
enum class ResetItem(val key: String, val targets: List<ResetTarget>) {
    ACTIVITY(
        "activity",
        listOf(
            ResetTarget.Live(ResetHook.CLEAR_ACTIVITY),
            ResetTarget.Path(ResetRoot.NO_BACKUP, "activity-stream.json"),
            ResetTarget.Path(ResetRoot.NO_BACKUP, "activity-stream.json.tmp"),
        ),
    ),
    DIAGNOSTICS(
        "diagnostics",
        listOf(
            ResetTarget.Live(ResetHook.CLEAR_DIAGNOSTICS),
            // Connection health is part of the diagnostics report.
            ResetTarget.Live(ResetHook.CLEAR_CONNECTION_HEALTH),
            ResetTarget.Path(ResetRoot.NO_BACKUP, "diagnostics.json"),
            ResetTarget.Path(ResetRoot.NO_BACKUP, "diagnostics.json.tmp"),
        ),
    ),
    TRANSFER_HISTORY("transfers", listOf(ResetTarget.Live(ResetHook.CLEAR_TRANSFER_HISTORY))),
    LOG_FILES("logs", listOf(ResetTarget.Path(ResetRoot.CACHE, "diagnostics"))),
    UPDATE_APKS("updates", listOf(ResetTarget.Path(ResetRoot.CACHE, "updates"))),
    CLIPBOARD_CACHE(
        "clipboard",
        listOf(ResetTarget.Live(ResetHook.CLEAR_CLIPBOARD_CACHE), ResetTarget.Path(ResetRoot.NO_BACKUP, "clipboard-cache")),
    ),
    /** Folders this phone receives (folder-transfers) and, since Files 2.0, sends (folder-sends). */
    FOLDER_JOURNALS(
        "folders",
        listOf(ResetTarget.Path(ResetRoot.NO_BACKUP, "folder-transfers"), ResetTarget.Path(ResetRoot.NO_BACKUP, "folder-sends")),
    ),
    /** v0.9: each Mac's last list of Mac actions (Device Controls, widgets, the Lock tile). The Mac sends it again. */
    MAC_ACTION_CATALOGS(
        "mac_actions",
        listOf(ResetTarget.Live(ResetHook.CLEAR_MAC_ACTION_CATALOGS), ResetTarget.Preferences("bridgey.mac_actions")),
    ),
    /**
     * Everything else in the cache directory (the performance test's files and, since v0.9, camera photos
     * waiting to be sent, for example), and the Files 2.0 recent-documents index (rebuilt from the granted places).
     */
    OTHER_CACHES(
        "caches",
        listOf(
            ResetTarget.Path(ResetRoot.CACHE, "", except = setOf("diagnostics", "updates")),
            ResetTarget.Path(ResetRoot.NO_BACKUP, "document-index.json"),
            ResetTarget.Path(ResetRoot.NO_BACKUP, ".document-index.json.tmp"),
        ),
    ),
    /**
     * Feature switches, per-device settings, logging switches, folder choices, this phone's name and (v0.9) the
     * Focus switches. A Do Not Disturb that Follow turned on is handed back first. Settings sync (v0.10): its records,
     * switches and choices, so this phone takes the other devices' chosen values when it next connects.
     */
    FEATURE_SETTINGS(
        "features",
        listOf(
            ResetTarget.Live(ResetHook.RELEASE_FOCUS), ResetTarget.Preferences("bridgey.settings"),
            ResetTarget.Preferences(dev.bridgey.android.sync.SettingsSyncController.PREFERENCES),
        ),
    ),
    APP_PREFERENCES(
        "app",
        listOf(
            ResetTarget.Preferences("bridgey.ui"), ResetTarget.Preferences("bridgey.remote"), ResetTarget.Preferences("bridgey.screenshot"),
            // Files 2.0: the attach sheet's last tab and target, and its one-time cards.
            ResetTarget.Preferences("bridgey.attach"),
            // v0.9: which Mac each home screen widget controls.
            ResetTarget.Preferences("bridgey.widgets"),
            // Text messages: which permissions it has asked for (to tell a refusal for good apart).
            ResetTarget.Preferences("bridgey.sms.asked"),
        ),
    ),
    UPDATE_CHANNEL("channel", listOf(ResetTarget.Preferences("bridgey.updates"))),
    FOLDER_PLACES("places", listOf(ResetTarget.Live(ResetHook.RELEASE_FOLDER_GRANTS), ResetTarget.Preferences("bridgey.places"))),
    SETUP("setup", listOf(ResetTarget.Preferences(SetupStore.PREFERENCES), ResetTarget.Preferences(SetupStore.LEGACY_ONBOARDING_PREFERENCES))),
    TRUSTED_DEVICES(
        "trusted",
        listOf(
            ResetTarget.Live(ResetHook.DISCONNECT), ResetTarget.Preferences("bridgey.trust"),
            // Settings sync's first-connect answers belong with the pairings: Reset > Settings keeps them.
            ResetTarget.Preferences(dev.bridgey.android.sync.SettingsSyncController.ANSWER_PREFERENCES),
        ),
    ),
    IDENTITY(
        "identity",
        listOf(ResetTarget.Preferences("bridgey"), ResetTarget.KeystoreAlias(LocalDataReset.IDENTITY_ALIAS)),
    ),
    RECONNECT_ADDRESSES("reconnect", listOf(ResetTarget.Preferences("bridgey.reconnect"))),
    CODES_LINK("codes", listOf(ResetTarget.Live(ResetHook.REMOVE_COMPANION_LINK), ResetTarget.Preferences("bridgey_codes"))),
    WHATS_NEW("whats_new", listOf(ResetTarget.Preferences(SetupStore.WHATS_NEW_PREFERENCES))),
}

/** What a kept line in the dialog says. Copy: strings_setup.xml `reset_keep_<key>`. */
enum class ResetKept(val key: String) { SETTINGS("settings"), PAIRINGS("pairings"), HISTORY("history"), CACHES("caches"), APP("app") }

/** The phone's storage and the running app, as the reset sees them. Tests pass temporary directories. */
interface ResetEnvironment {
    fun directory(root: ResetRoot): File
    fun deletePreferences(name: String)
    fun deleteKeystoreAlias(alias: String)
    fun run(hook: ResetHook)
}

/**
 * The reset itself: [items] for the dialogs, [perform] to delete. Live hooks run first, sessions
 * before anything else, so nothing writes a file back after it is deleted. Settings and Everything
 * then need a restart (the app holds settings in memory); the caller restarts Bridgey.
 */
class LocalDataReset(private val environment: ResetEnvironment) {
    fun perform(choice: ResetChoice) {
        val targets = items(choice).flatMap { it.targets }
        val hooks = targets.filterIsInstance<ResetTarget.Live>().map { it.hook }.distinct()
            .sortedBy { if (it == ResetHook.DISCONNECT) 0 else 1 }
        hooks.forEach { runCatching { environment.run(it) } }
        targets.forEach { target ->
            when (target) {
                is ResetTarget.Preferences -> environment.deletePreferences(target.name)
                is ResetTarget.Path -> delete(target)
                is ResetTarget.KeystoreAlias -> runCatching { environment.deleteKeystoreAlias(target.alias) }
                is ResetTarget.Live -> Unit
            }
        }
    }

    private fun delete(target: ResetTarget.Path) {
        val root = environment.directory(target.root)
        val file = if (target.path.isEmpty()) root else File(root, target.path)
        // Never follow a path out of the app's own directories.
        if (!file.canonicalPath.startsWith(root.canonicalPath)) return
        if (target.path.isEmpty()) {
            file.listFiles()?.filterNot { it.name in target.except }?.forEach { it.deleteRecursively() }
        } else {
            file.deleteRecursively()
        }
    }

    companion object {
        const val IDENTITY_ALIAS = "bridgey.identity.p256.v1"

        fun items(choice: ResetChoice): List<ResetItem> = when (choice) {
            ResetChoice.ACTIVITY_AND_LOGS -> listOf(ResetItem.ACTIVITY, ResetItem.DIAGNOSTICS, ResetItem.TRANSFER_HISTORY, ResetItem.LOG_FILES)
            ResetChoice.MODELS_AND_CACHES -> listOf(
                ResetItem.UPDATE_APKS, ResetItem.CLIPBOARD_CACHE, ResetItem.FOLDER_JOURNALS, ResetItem.MAC_ACTION_CATALOGS, ResetItem.OTHER_CACHES,
            )
            ResetChoice.SETTINGS -> listOf(ResetItem.FEATURE_SETTINGS, ResetItem.APP_PREFERENCES, ResetItem.UPDATE_CHANNEL, ResetItem.FOLDER_PLACES, ResetItem.SETUP)
            ResetChoice.EVERYTHING -> (
                items(ResetChoice.ACTIVITY_AND_LOGS) + items(ResetChoice.MODELS_AND_CACHES) + items(ResetChoice.SETTINGS) +
                    listOf(ResetItem.TRUSTED_DEVICES, ResetItem.IDENTITY, ResetItem.RECONNECT_ADDRESSES, ResetItem.CODES_LINK, ResetItem.WHATS_NEW)
                )
        }

        fun kept(choice: ResetChoice): List<ResetKept> = when (choice) {
            ResetChoice.ACTIVITY_AND_LOGS -> listOf(ResetKept.SETTINGS, ResetKept.PAIRINGS)
            ResetChoice.MODELS_AND_CACHES -> listOf(ResetKept.SETTINGS, ResetKept.PAIRINGS, ResetKept.HISTORY)
            ResetChoice.SETTINGS -> listOf(ResetKept.PAIRINGS, ResetKept.HISTORY, ResetKept.CACHES)
            ResetChoice.EVERYTHING -> listOf(ResetKept.APP)
        }

        /** Settings and Everything restart Bridgey; Everything returns to first-run setup. */
        fun needsRestart(choice: ResetChoice): Boolean = choice == ResetChoice.SETTINGS || choice == ResetChoice.EVERYTHING
    }
}

/**
 * The real phone: the app's directories, its preferences and the Android Keystore. Tests pass
 * temporary [directories] and a fake [deleteAlias]; they never touch the Keystore.
 */
class AndroidResetEnvironment(
    private val context: Context,
    private val hooks: (ResetHook) -> Unit,
    private val directories: (ResetRoot) -> File = { root ->
        when (root) {
            ResetRoot.FILES -> context.filesDir
            ResetRoot.NO_BACKUP -> context.noBackupFilesDir
            ResetRoot.CACHE -> context.cacheDir
        }
    },
    private val deleteAlias: (String) -> Unit = ::deleteAndroidKeystoreAlias,
) : ResetEnvironment {
    override fun directory(root: ResetRoot): File = directories(root)

    override fun deletePreferences(name: String) {
        // Clear first: the process may still hold the file's values in memory until it restarts.
        context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        context.deleteSharedPreferences(name)
    }

    override fun deleteKeystoreAlias(alias: String) = deleteAlias(alias)

    override fun run(hook: ResetHook) = hooks(hook)
}

private fun deleteAndroidKeystoreAlias(alias: String) {
    val store = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    if (store.containsAlias(alias)) store.deleteEntry(alias)
}
