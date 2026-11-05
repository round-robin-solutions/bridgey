package dev.bridgey.android.ui.attach

import java.net.URI
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Metadata only: no file bytes, display names, or copied provider content. Stored privately, not in a Bundle. */
internal data class AttachDraft(
    val visible: Boolean = false,
    val targetId: String? = null,
    val selection: List<String> = emptyList(),
    val files: List<String> = emptyList(),
    val folder: String? = null,
    /** Only read grants acquired by this draft; grants that already existed are never released here. */
    val ownedReads: Set<String> = emptySet(),
    /** Single-file transfer IDs that still need an acquired read grant, including retryable transfers. */
    val fileLeases: Map<String, Set<String>> = emptyMap(),
    val leaseProcess: String = "",
    val submitting: Boolean = false,
    /** Folder sends already have durable core journals; their read leases must survive a process restart too. */
    val folderLeases: Map<String, Set<String>> = emptyMap(),
) {
    val hasContent: Boolean get() = selection.isNotEmpty() || files.isNotEmpty() || folder != null
    val pendingUris: Set<String> get() = files.toSet() + listOfNotNull(folder)
}

internal interface AttachDraftPersistence {
    fun read(): String?
    fun write(value: String)
}

internal interface AttachDraftReadGrants {
    fun hasRead(uri: String): Boolean
    fun retainRead(uri: String): Boolean
    fun releaseRead(uri: String): Boolean
    /** Places and current queued/retryable transfers may also depend on a grant (Android does not refcount it). */
    fun hasOtherOwner(uri: String): Boolean
}

internal object AttachDraftCodec {
    const val MAX_BYTES = 32 * 1024
    private const val MAX_URI = 4096
    private const val MAX_LEASES = 256

    fun validUri(value: String): Boolean = value.length in 1..MAX_URI && runCatching {
        val uri = URI(value)
        uri.scheme.equals("content", ignoreCase = true) && !uri.rawAuthority.isNullOrBlank()
    }.getOrDefault(false)

    fun encode(value: AttachDraft): String? {
        if (value.targetId?.length?.let { it !in 1..128 } == true || value.leaseProcess.length > 64 ||
            value.files.size + value.selection.size + (if (value.folder == null) 0 else 1) > AttachSelection.MAX ||
            value.selection.any { it.length !in 1..MAX_URI } || value.files.distinct().size != value.files.size ||
            value.selection.distinct().size != value.selection.size || value.ownedReads.size > MAX_LEASES ||
            value.fileLeases.values.sumOf { it.size } + value.folderLeases.values.sumOf { it.size } > MAX_LEASES ||
            (value.pendingUris + value.ownedReads + value.fileLeases.keys + value.folderLeases.keys).any { !validUri(it) } ||
            (value.fileLeases.values + value.folderLeases.values).any { ids -> ids.isEmpty() || ids.any { it.length !in 1..128 } }) return null
        val encoded = JSONObject().put("version", 1).put("visible", value.visible)
            .put("target", value.targetId ?: JSONObject.NULL).put("selection", JSONArray(value.selection))
            .put("files", JSONArray(value.files)).put("folder", value.folder ?: JSONObject.NULL)
            .put("ownedReads", JSONArray(value.ownedReads.toList())).put("leaseProcess", value.leaseProcess).put("submitting", value.submitting)
            .put("fileLeases", JSONObject().apply { value.fileLeases.forEach { (uri, ids) -> put(uri, JSONArray(ids.toList())) } })
            .put("folderLeases", JSONObject().apply { value.folderLeases.forEach { (uri, ids) -> put(uri, JSONArray(ids.toList())) } }).toString()
        return encoded.takeIf { it.toByteArray(Charsets.UTF_8).size <= MAX_BYTES }
    }

    /** An existing core owner relinquishes a read grant only after this pending draft takes ownership. */
    fun adoptingReleasedRead(value: AttachDraft, uri: String, heldRead: Boolean): String? {
        if (!heldRead || uri !in value.pendingUris && uri !in value.fileLeases && uri !in value.folderLeases) return null
        return encode(value.copy(ownedReads = value.ownedReads + uri))
    }

    fun decode(encoded: String?): AttachDraft? = runCatching {
        if (encoded == null || encoded.toByteArray(Charsets.UTF_8).size > MAX_BYTES) return null
        val json = JSONObject(encoded)
        if (json.opt("version") != 1 || json.opt("visible") !is Boolean || json.opt("submitting") !is Boolean) return null
        fun strings(key: String): List<String> {
            val values = json.getJSONArray(key)
            require(values.length() <= MAX_LEASES)
            return (0 until values.length()).map { index -> (values.get(index) as? String) ?: error("invalid draft metadata") }
        }
        fun nullableString(key: String): String? {
            if (json.isNull(key)) return null
            return json.get(key) as? String ?: error("invalid draft metadata")
        }
        fun leases(key: String): Map<String, Set<String>> {
            val leases = json.getJSONObject(key)
            require(leases.length() <= MAX_LEASES)
            return leases.keys().asSequence().associateWith { uri ->
                val array = leases.getJSONArray(uri)
                require(array.length() <= MAX_LEASES)
                (0 until array.length()).map { array.get(it) as? String ?: error("invalid draft metadata") }.toSet()
            }
        }
        AttachDraft(json.getBoolean("visible"), nullableString("target"), strings("selection"), strings("files"),
            nullableString("folder"), strings("ownedReads").toSet(), leases("fileLeases"), json.getString("leaseProcess"), json.getBoolean("submitting"), leases("folderLeases"))
            .takeIf { encode(it) != null }
    }.getOrNull()
}

/**
 * One bounded draft in bridgey.attach (already excluded from backups and covered by Reset).
 * Preferences contain URI strings only; no unbounded URI list is written to Android saved-state Binder.
 */
internal class AttachDraftStore(
    private val persistence: AttachDraftPersistence,
    private val grants: AttachDraftReadGrants,
    private val processId: String,
) {
    private val mutableState = MutableStateFlow(AttachDraftCodec.decode(persistence.read()) ?: AttachDraft())
    val state = mutableState.asStateFlow()
    val value: AttachDraft get() = mutableState.value

    init {
        // Single-file queue/source ownership is process-local. Folder leases, backed by the existing
        // durable folder sender's journal, remain until a known nonretryable terminal state.
        if (value.leaseProcess != processId) {
            save(value.copy(fileLeases = emptyMap(), submitting = false, leaseProcess = processId))
        }
        releaseUnused()
    }

    private fun save(next: AttachDraft): Boolean {
        val currentProcess = next.copy(leaseProcess = processId)
        // Reserve ownership space for any borrowed grant whose core owner finishes while this draft waits.
        if (AttachDraftCodec.encode(currentProcess.copy(ownedReads = currentProcess.ownedReads + currentProcess.pendingUris + currentProcess.fileLeases.keys + currentProcess.folderLeases.keys)) == null) return false
        val encoded = AttachDraftCodec.encode(currentProcess) ?: return false
        persistence.write(encoded)
        mutableState.value = currentProcess
        return true
    }

    /** Other activity owners may finish a queued folder after this Activity was recreated. */
    fun reload() { mutableState.value = AttachDraftCodec.decode(persistence.read()) ?: AttachDraft() }

    fun open(targetId: String?): Boolean = save(value.copy(visible = true, targetId = if (value.hasContent || value.submitting) value.targetId else targetId))
    fun dismiss(): Boolean = save(value.copy(visible = false))
    fun target(id: String): Boolean = !value.submitting && save(value.copy(targetId = id))
    fun select(keys: List<String>): Boolean = !value.submitting && save(value.copy(selection = keys.distinct()))
    fun pendingAccessAvailable(): Boolean = value.pendingUris.all(grants::hasRead)
    fun beginSubmission(): Boolean = !value.submitting && save(value.copy(submitting = true))

    /** Refuse a non-persistable/oversized new result without discarding the prior draft or copying file contents. */
    fun addFiles(uris: List<String>): Boolean = retain(value.copy(files = (value.files + uris).distinct(), visible = true), uris)
    fun addFolder(uri: String): Boolean = retain(value.copy(folder = uri, visible = true), listOf(uri))

    private fun retain(next: AttachDraft, candidates: List<String>): Boolean {
        // Include worst-case ownership before touching grants, so a bound failure cannot leak a new permission.
        val bounded = AttachDraftCodec.encode(next.copy(ownedReads = next.ownedReads + candidates)) ?: return false
        // Leave room for the accepted transfer IDs before removing their URI from the pending list.
        if (bounded.toByteArray(Charsets.UTF_8).size > AttachDraftCodec.MAX_BYTES - 8 * 1024 || value.submitting) return false
        val acquired = mutableSetOf<String>()
        for (uri in candidates.distinct()) {
            if (grants.hasRead(uri)) continue
            if (!grants.retainRead(uri)) {
                rollback(acquired)
                return false
            }
            acquired += uri
        }
        if (!save(next.copy(ownedReads = next.ownedReads + acquired))) {
            rollback(acquired)
            return false
        }
        releaseUnused()
        return true
    }

    private fun rollback(acquired: Set<String>) {
        val retained = acquired.filter { grants.hasOtherOwner(it) || !grants.releaseRead(it) }.toSet()
        if (retained.isNotEmpty()) save(value.copy(ownedReads = value.ownedReads + retained))
    }

    /** Accepted files leave the draft individually; failed dispatches stay selected for another explicit Send. */
    fun fileQueued(uri: String, transferId: String, selectedKeys: Set<String> = emptySet()): Boolean {
        val leases = if (uri in value.files || uri in value.ownedReads) value.fileLeases +
            (uri to (value.fileLeases[uri].orEmpty() + transferId)) else value.fileLeases
        return save(value.copy(files = value.files.filterNot { it == uri },
            selection = value.selection.filterNot(selectedKeys::contains), fileLeases = leases, leaseProcess = processId))
    }

    /** Track the accepted folder too: its core cleanup can race with this Main-thread queue callback. */
    fun folderQueued(uri: String?, transferId: String, selectedKey: String? = null): Boolean {
        reload()
        return save(value.copy(
            folder = value.folder.takeUnless { it == uri },
            selection = value.selection.filterNot { it == selectedKey },
            folderLeases = if (uri == null) value.folderLeases else value.folderLeases +
                (uri to (value.folderLeases[uri].orEmpty() + transferId)),
        ))
    }

    fun adoptReleasedRead(uri: String): Boolean {
        reload()
        val encoded = AttachDraftCodec.adoptingReleasedRead(value, uri, grants.hasRead(uri)) ?: return false
        persistence.write(encoded)
        mutableState.value = requireNotNull(AttachDraftCodec.decode(encoded))
        return true
    }

    fun submissionFinished(): Boolean {
        reload()
        return save(value.copy(visible = value.visible && value.hasContent, submitting = false, targetId = value.targetId.takeIf { value.hasContent }))
    }

    /** A swipe/outside tap only dismisses; this is called solely by the explicit Cancel control. */
    fun cancel(): Boolean {
        if (value.submitting || !save(value.copy(visible = false, targetId = null, selection = emptyList(), files = emptyList(), folder = null))) return false
        releaseUnused()
        return true
    }

    fun transferStates(nonRetryableFinished: Set<String>) {
        val leases = value.fileLeases.mapValues { (_, ids) -> ids - nonRetryableFinished }.filterValues { it.isNotEmpty() }
        val folders = value.folderLeases.mapValues { (_, ids) -> ids - nonRetryableFinished }.filterValues { it.isNotEmpty() }
        if (leases != value.fileLeases || folders != value.folderLeases) save(value.copy(fileLeases = leases, folderLeases = folders))
        releaseUnused()
    }

    private fun releaseUnused() {
        val unused = value.ownedReads - value.pendingUris - value.fileLeases.keys - value.folderLeases.keys
        val released = unused.filter { !grants.hasOtherOwner(it) && (!grants.hasRead(it) || grants.releaseRead(it)) }.toSet()
        if (released.isNotEmpty()) save(value.copy(ownedReads = value.ownedReads - released))
    }
}
