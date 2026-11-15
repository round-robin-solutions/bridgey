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
    const val MAX_LEASES = 256
    private val TRANSFER_ID = Regex("[A-Za-z0-9_.:-]{1,128}")
    fun validTransferId(value: String): Boolean = TRANSFER_ID.matches(value)

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
            (value.fileLeases.values + value.folderLeases.values).any { ids -> ids.isEmpty() || ids.any { !validTransferId(it) } }) return null
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
    deferCleanup: Boolean = false,
) {
    private val mutableState = MutableStateFlow(AttachDraftCodec.decode(persistence.read()) ?: AttachDraft())
    val state = mutableState.asStateFlow()
    val value: AttachDraft get() = mutableState.value

    private data class Receipt(val file: Boolean, val uri: String?, val acknowledged: Boolean = false)
    private data class Submission(val files: List<String>, val trees: List<String>, val places: Int)
    // Queue admission happens on Main. These bounded receipts outlive a fast terminal callback, but are
    // never replayed after process death; persisted pending items still require a new explicit Send.
    private val receipts = linkedMapOf<String, Receipt>()
    private val failedAcknowledgements = mutableSetOf<String>()
    private var invalidAcknowledgement = false
    private var submission: Submission? = null
    private var recoveryPending = deferCleanup

    init {
        // Single-file sources are process-local. Keep folders until core journal recovery reconciles
        // genuine owners; a preparing/queued ID alone is not proof that a durable journal exists.
        if (value.leaseProcess != processId) save(value.copy(fileLeases = emptyMap(), submitting = false))
        releaseUnused()
    }

    private fun save(next: AttachDraft): Boolean {
        val current = next.copy(leaseProcess = processId)
        if (encodeWithPotentialOwnership(current) == null) return false
        val encoded = AttachDraftCodec.encode(current) ?: return false
        persistence.write(encoded)
        mutableState.value = current
        return true
    }

    private fun encodeWithPotentialOwnership(draft: AttachDraft): String? = AttachDraftCodec.encode(draft.copy(
        ownedReads = draft.ownedReads + draft.pendingUris + draft.fileLeases.keys + draft.folderLeases.keys,
    ))

    /** Preferences may be updated by grant adoption. Ordinary reload preserves live admission receipts. */
    fun reload() {
        val restored = AttachDraftCodec.decode(persistence.read())
        mutableState.value = restored ?: AttachDraft()
        if (restored == null || !restored.submitting) clearSubmission()
    }

    private fun clearSubmission() {
        receipts.clear(); failedAcknowledgements.clear(); invalidAcknowledgement = false; submission = null
    }

    fun open(targetId: String?): Boolean = save(value.copy(visible = true, targetId = if (value.hasContent || value.submitting) value.targetId else targetId))
    fun dismiss(): Boolean = save(value.copy(visible = false))
    fun target(id: String): Boolean = !value.submitting && save(value.copy(targetId = id))
    fun select(keys: List<String>): Boolean = !value.submitting && save(value.copy(selection = keys.distinct()))
    fun pendingAccessAvailable(): Boolean = value.pendingUris.all(grants::hasRead)

    /** Preflight every prospective lease slot and worst-case 128-character ID before queue side effects. */
    fun beginSubmission(fileUris: List<String> = value.files, treeUris: List<String> = listOfNotNull(value.folder)): Boolean {
        if (value.submitting) return false
        val plan = Submission(fileUris.distinct(), treeUris, value.selection.count { it.startsWith(AttachKeys.FOLDER) })
        if (plan.files.size + plan.trees.size + plan.places > AttachSelection.MAX ||
            (plan.files + plan.trees).any { !AttachDraftCodec.validUri(it) } || !fitsSubmission(value, plan)) return false
        if (!save(value.copy(submitting = true))) return false
        clearSubmission()
        submission = plan
        return true
    }

    private fun fitsSubmission(base: AttachDraft, remaining: Submission): Boolean {
        val files = base.fileLeases.mapValues { it.value.toMutableSet() }.toMutableMap()
        val folders = base.folderLeases.mapValues { it.value.toMutableSet() }.toMutableMap()
        val used = (files.values + folders.values).flatten().toMutableSet()
        var serial = 0
        fun nextId(): String {
            var id: String
            do { id = ("admission-" + serial++).padEnd(128, 'x') } while (!used.add(id))
            return id
        }
        remaining.files.filter { needsFileLease(base, it) }.forEach { files.getOrPut(it) { mutableSetOf() }.add(nextId()) }
        remaining.trees.forEach { folders.getOrPut(it) { mutableSetOf() }.add(nextId()) }
        return encodeWithPotentialOwnership(base.copy(fileLeases = files, folderLeases = folders, submitting = true)) != null
    }

    private fun needsFileLease(draft: AttachDraft, uri: String): Boolean =
        uri in draft.files || uri in draft.ownedReads || uri in draft.fileLeases || uri in draft.folderLeases

    /** Root calls this before creating any source, transfer row, queue entry or network item. */
    fun reserveFiles(assignments: List<Pair<String, String>>): Boolean {
        val plan = submission ?: return false
        if (!value.submitting || assignments.isEmpty() || receipts.size + assignments.size > AttachSelection.MAX ||
            assignments.map { it.second }.distinct().size != assignments.size ||
            assignments.any { (uri, id) -> !AttachDraftCodec.validTransferId(id) || id in receipts || id in allLeaseIds() || uri !in plan.files } ||
            assignments.map { it.first }.distinct().size != assignments.size) return false
        val remaining = plan.copy(files = plan.files - assignments.map { it.first }.toSet())
        val files = value.fileLeases.toMutableMap()
        assignments.filter { needsFileLease(value, it.first) }.forEach { (uri, id) -> files[uri] = files[uri].orEmpty() + id }
        val next = value.copy(fileLeases = files)
        if (!fitsSubmission(next, remaining) || !save(next)) return false
        submission = remaining
        assignments.forEach { (uri, id) -> receipts[id] = Receipt(file = true, uri = uri) }
        return true
    }

    /** Place folders need a receipt but no one-off tree URI lease. */
    fun reserveFolder(uri: String?, id: String): Boolean {
        val plan = submission ?: return false
        if (!value.submitting || receipts.size >= AttachSelection.MAX || !AttachDraftCodec.validTransferId(id) ||
            id in receipts || id in allLeaseIds() || (if (uri == null) plan.places == 0 else uri !in plan.trees)) return false
        val remaining = if (uri == null) plan.copy(places = plan.places - 1) else plan.copy(trees = plan.trees.toMutableList().apply { remove(uri) })
        val folders = if (uri == null) value.folderLeases else value.folderLeases + (uri to (value.folderLeases[uri].orEmpty() + id))
        val next = value.copy(folderLeases = folders)
        if (!fitsSubmission(next, remaining) || !save(next)) return false
        submission = remaining
        receipts[id] = Receipt(file = false, uri = uri)
        return true
    }

    /** A failed core enqueue retires admission, preserving the pending content for an explicit retry. */
    fun rejectReserved(id: String): Boolean {
        val receipt = receipts[id]?.takeUnless { it.acknowledged } ?: return false
        val next = withoutIds(value, setOf(id), file = true, folder = true)
        if (!save(next)) return false
        receipts.remove(id); failedAcknowledgements.remove(id)
        submission = submission?.let { plan ->
            when { receipt.file -> plan.copy(files = plan.files + requireNotNull(receipt.uri))
                receipt.uri != null -> plan.copy(trees = plan.trees + receipt.uri)
                else -> plan.copy(places = plan.places + 1) }
        }
        releaseUnused()
        return true
    }

    /** Refuse a non-persistable/oversized new result without losing earlier selections or copying contents. */
    fun addFiles(uris: List<String>): Boolean = retain(value.copy(files = (value.files + uris).distinct(), visible = true), uris)
    fun addFolder(uri: String): Boolean = retain(value.copy(folder = uri, visible = true), listOf(uri))

    private fun retain(next: AttachDraft, candidates: List<String>): Boolean {
        val bounded = AttachDraftCodec.encode(next.copy(ownedReads = next.ownedReads + candidates)) ?: return false
        if (bounded.toByteArray(Charsets.UTF_8).size > AttachDraftCodec.MAX_BYTES - 8 * 1024 || value.submitting) return false
        val acquired = mutableSetOf<String>()
        for (uri in candidates.distinct()) {
            if (grants.hasRead(uri)) continue
            if (!grants.retainRead(uri)) { rollback(acquired); return false }
            acquired += uri
        }
        if (!save(next.copy(ownedReads = next.ownedReads + acquired))) { rollback(acquired); return false }
        releaseUnused()
        return true
    }

    private fun rollback(acquired: Set<String>) {
        val retained = acquired.filter { grants.hasOtherOwner(it) || !grants.releaseRead(it) }.toSet()
        if (retained.isNotEmpty()) save(value.copy(ownedReads = value.ownedReads + retained))
    }

    private fun acknowledgementFailed(id: String): Boolean {
        if (value.submitting) {
            if (AttachDraftCodec.validTransferId(id) && failedAcknowledgements.size < AttachSelection.MAX) failedAcknowledgements += id
            else invalidAcknowledgement = true
        }
        return false
    }

    /** Acknowledge existing admission only. A fast terminal callback must never recreate its retired lease. */
    fun fileQueued(uri: String, transferId: String, selectedKeys: Set<String> = emptySet()): Boolean {
        val receipt = receipts[transferId]
        if (!value.submitting || receipt == null || !receipt.file || receipt.uri != uri) return acknowledgementFailed(transferId)
        if (receipt.acknowledged) return true
        if (!save(value.copy(files = value.files.filterNot { it == uri }, selection = value.selection.filterNot(selectedKeys::contains))))
            return acknowledgementFailed(transferId)
        receipts[transferId] = receipt.copy(acknowledged = true)
        failedAcknowledgements.remove(transferId)
        releaseUnused()
        return true
    }

    fun folderQueued(uri: String?, transferId: String, selectedKey: String? = null): Boolean {
        val receipt = receipts[transferId]
        if (!value.submitting || receipt == null || receipt.file || receipt.uri != uri) return acknowledgementFailed(transferId)
        if (receipt.acknowledged) return true
        if (!save(value.copy(folder = value.folder.takeUnless { it == uri }, selection = value.selection.filterNot { it == selectedKey })))
            return acknowledgementFailed(transferId)
        receipts[transferId] = receipt.copy(acknowledged = true)
        failedAcknowledgements.remove(transferId)
        releaseUnused()
        return true
    }

    fun adoptReleasedRead(uri: String): Boolean {
        val encoded = AttachDraftCodec.adoptingReleasedRead(value, uri, grants.hasRead(uri)) ?: return false
        persistence.write(encoded)
        mutableState.value = requireNotNull(AttachDraftCodec.decode(encoded))
        return true
    }

    /** Retain the core's cleanup evidence while journal ownership is still being recovered. */
    fun deferCoreReadRelease(uri: String): Boolean {
        if (!AttachDraftCodec.validUri(uri) || !grants.hasRead(uri)) return false
        return save(value.copy(ownedReads = value.ownedReads + uri))
    }

    /** Unrecorded accepted content keeps the Send gate closed rather than silently inviting a duplicate. */
    fun submissionFinished(): Boolean {
        if (!value.submitting || submission == null || receipts.values.any { !it.acknowledged } || failedAcknowledgements.isNotEmpty() || invalidAcknowledgement) return false
        if (!save(value.copy(visible = value.visible && value.hasContent, submitting = false, targetId = value.targetId.takeIf { value.hasContent }))) return false
        clearSubmission()
        releaseUnused()
        return true
    }

    fun cancel(): Boolean {
        if (value.submitting || !save(value.copy(visible = false, targetId = null, selection = emptyList(), files = emptyList(), folder = null))) return false
        releaseUnused()
        return true
    }

    private fun allLeaseIds(): Set<String> = (value.fileLeases.values + value.folderLeases.values).flatten().toSet()
    private fun withoutIds(draft: AttachDraft, ids: Set<String>, file: Boolean, folder: Boolean): AttachDraft = draft.copy(
        fileLeases = if (file) draft.fileLeases.mapValues { (_, live) -> live - ids }.filterValues { it.isNotEmpty() } else draft.fileLeases,
        folderLeases = if (folder) draft.folderLeases.mapValues { (_, live) -> live - ids }.filterValues { it.isNotEmpty() } else draft.folderLeases,
    )

    fun transferStates(nonRetryableFinished: Set<String>) {
        val next = withoutIds(value, nonRetryableFinished, file = true, folder = true)
        if (next != value) save(next)
        releaseUnused()
    }

    /** Core invokes these only after its actual source/journal owners are authoritative. */
    fun reconcileFileOwners(liveIds: Set<String>) {
        val stale = value.fileLeases.values.flatten().toSet() - liveIds
        val next = withoutIds(value, stale, file = true, folder = false)
        if (next != value) save(next)
        releaseUnused()
    }
    fun reconcileFolderOwners(liveIds: Set<String>) {
        recoveryPending = false
        val stale = value.folderLeases.values.flatten().toSet() - liveIds
        val next = withoutIds(value, stale, file = false, folder = true)
        if (next != value) save(next)
        releaseUnused()
    }

    /** Migrate ownership before the retry's source/queue can start; absence means this URI was not draft-owned. */
    fun replaceFileTransfer(oldId: String, newId: String): Boolean {
        if (value.fileLeases.values.none { oldId in it }) return true
        if (oldId == newId) return true
        if (!AttachDraftCodec.validTransferId(newId) || newId in allLeaseIds() || newId in receipts) return false
        val files = value.fileLeases.mapValues { (_, ids) -> if (oldId in ids) ids - oldId + newId else ids }
        return save(value.copy(fileLeases = files))
    }

    private fun releaseUnused() {
        if (recoveryPending) return
        val unused = value.ownedReads - value.pendingUris - value.fileLeases.keys - value.folderLeases.keys
        val released = unused.filter { !grants.hasOtherOwner(it) && (!grants.hasRead(it) || grants.releaseRead(it)) }.toSet()
        if (released.isNotEmpty()) save(value.copy(ownedReads = value.ownedReads - released))
    }
}
