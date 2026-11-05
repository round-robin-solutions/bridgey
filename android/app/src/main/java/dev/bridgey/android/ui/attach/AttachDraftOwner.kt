package dev.bridgey.android.ui.attach

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Looper
import androidx.annotation.MainThread
import androidx.lifecycle.ViewModel
import dev.bridgey.android.PairingCoordinator
import java.util.UUID

/** Activity ViewModel survives rotation; the existing private preferences also recover a stopped process. */
internal class AttachDraftOwner(context: Context, pairing: PairingCoordinator) : ViewModel() {
    private val preferences = context.applicationContext.getSharedPreferences("bridgey.attach", Context.MODE_PRIVATE)
    private val resolver = context.applicationContext.contentResolver
    val store = AttachDraftStore(
        object : AttachDraftPersistence {
            override fun read(): String? = preferences.getString(KEY, null)
            // SharedPreferences flushes pending apply writes when an Activity stops. The value is bounded to 32 KiB.
            override fun write(value: String) { preferences.edit().putString(KEY, value).apply() }
        },
        object : AttachDraftReadGrants {
            override fun hasRead(uri: String): Boolean = runCatching {
                resolver.persistedUriPermissions.any { it.isReadPermission && it.uri.toString() == uri }
            }.getOrDefault(false)
            override fun retainRead(uri: String): Boolean = runCatching {
                resolver.takePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
                hasRead(uri)
            }.getOrDefault(false)
            override fun releaseRead(uri: String): Boolean = runCatching {
                resolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
                true
            }.getOrDefault(false)
            override fun hasOtherOwner(uri: String): Boolean =
                pairing.placesStore.places.value.any { it.treeUri == uri } || pairing.placesStore.defaultTree.value == uri ||
                    pairing.hasOutgoingFileSource(Uri.parse(uri))
        },
        PROCESS_ID,
    )
    private val changed = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == KEY || key == null) store.reload()
    }

    init { preferences.registerOnSharedPreferenceChangeListener(changed) }
    fun detach() { preferences.unregisterOnSharedPreferenceChangeListener(changed) }
    override fun onCleared() { detach() }

    companion object {
        private const val KEY = "pending_draft.v1"
        private val PROCESS_ID = UUID.randomUUID().toString()

        /**
         * Called by the folder sender on Main before it releases a one-off read grant. An open/background
         * draft or a file lease adopts the existing grant; preference listeners refresh any active owner.
         */
        @MainThread
        fun retainReleasedFolderGrant(context: Context, treeUri: String): Boolean {
            check(Looper.myLooper() == Looper.getMainLooper()) { "Attach draft ownership must change on Main" }
            val preferences = context.applicationContext.getSharedPreferences("bridgey.attach", Context.MODE_PRIVATE)
            val draft = AttachDraftCodec.decode(preferences.getString(KEY, null)) ?: return false
            val heldRead = runCatching {
                context.applicationContext.contentResolver.persistedUriPermissions.any {
                    it.isReadPermission && it.uri.toString() == treeUri
                }
            }.getOrDefault(false)
            val adopted = AttachDraftCodec.adoptingReleasedRead(draft, treeUri, heldRead) ?: return false
            preferences.edit().putString(KEY, adopted).apply()
            return true
        }
    }
}
