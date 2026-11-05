package dev.bridgey.android.ui.attach

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Looper
import androidx.annotation.MainThread
import androidx.lifecycle.ViewModel
import dev.bridgey.android.PairingCoordinator
import java.util.UUID

/** The Activity observes the application's owner; background transfers never depend on composition. */
@Suppress("UNUSED_PARAMETER")
internal class AttachDraftOwner(context: Context, pairing: PairingCoordinator) : ViewModel() {
    val store: AttachDraftStore = pairing.attachDraftStore
    fun detach() = Unit

    companion object {
        const val PREFERENCES = "bridgey.attach"
        const val KEY = "pending_draft.v1"
        private val PROCESS_ID = UUID.randomUUID().toString()

        @MainThread
        fun createStore(context: Context, pairing: PairingCoordinator, deferCleanup: Boolean): AttachDraftStore {
            check(Looper.myLooper() == Looper.getMainLooper()) { "Attach ownership must change on Main" }
            val app = context.applicationContext
            val preferences = app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val resolver = app.contentResolver
            return AttachDraftStore(
                object : AttachDraftPersistence {
                    override fun read(): String? = preferences.getString(KEY, null)
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
                            pairing.hasOutgoingFileSource(Uri.parse(uri)) || pairing.hasOutgoingFolderSource(uri)
                }, PROCESS_ID, deferCleanup,
            )
        }
    }
}
