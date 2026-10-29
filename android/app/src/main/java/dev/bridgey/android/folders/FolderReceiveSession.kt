package dev.bridgey.android.folders

import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import org.json.JSONObject

/** How a folder session talks to its device. Encrypted payloads, and the outer-only file acknowledgements. */
interface FolderLink {
    /** An encrypted message; [outerTransferId] repeats the folder transfer ID outside (offer, rejected, cancel). */
    fun send(kind: String, payload: JSONObject, outerTransferId: String? = null)

    /** files.accept, files.chunk.ack, files.complete.ack, files.cancel.ack and folders.cancel.ack: outer only. */
    fun sendOuter(kind: String, transferId: String, sequence: Long? = null)
}

/** What the session tells the app: the row, the phone's questions and the end. Called on the storage thread. */
interface FolderSessionListener {
    fun snapshot(snapshot: FolderSnapshot) = Unit
    fun question(question: FolderQuestion?) = Unit
    fun finished(snapshot: FolderSnapshot) = Unit

    /** A destination that received a folder, for the Save to… sheet's recent list. */
    fun usedDestination(destination: FolderDestination) = Unit

    /** A one-off "Other folder…" grant is no longer needed. */
    fun releaseOneOff(treeUri: String) = Unit

    /** A running transfer lost access to a place ("Bridgey lost access to Pictures"). */
    fun lostAccess(placeLabel: String) = Unit
}

class FolderEnvironment(
    val places: PlaceDirectory,
    val settings: () -> FolderReceiveSettings,
    val journals: FolderJournals?,
    val worker: FolderWorker,
    val scheduler: FolderScheduler,
    val clock: () -> Long = System::currentTimeMillis,
    /** State, codes, counts and the first 8 characters of IDs only: never names or paths. */
    val log: (String) -> Unit = {},
)

/**
 * The receiving side of one folder transfer (sections 4.4 to 4.7, 6.3 to 6.6): the manifest, where it lands,
 * what happens when it exists, the files, the result, cancels and resume. One per folder; the device session
 * holds at most one active at a time (`busy` otherwise).
 *
 * Every event runs on [FolderEnvironment.worker], one after another, so the state needs no locks and the
 * storage calls never run on the socket reader. Public methods only post events.
 */
class FolderReceiveSession(
    val offer: FolderOfferPayload,
    val peerId: String,
    val peerName: String,
    private val env: FolderEnvironment,
    private val link: FolderLink,
    private val listener: FolderSessionListener,
) {
    enum class Phase { MANIFEST, ASK_DESTINATION, ASK_CONFLICT_HERE, ASK_CONFLICT_ON_SENDER, RECEIVING, DONE }

    val id: String get() = offer.folderTransferId

    @Volatile var phase: Phase = Phase.MANIFEST
        private set

    val active: Boolean get() = phase != Phase.DONE

    private val assembler = ManifestAssembler(offer)
    private var entries: List<ManifestEntry> = emptyList()

    // The destination, once known.
    private var place: PlaceRef? = null
    private var store: TreeStore? = null
    private var targetDirId: String? = null
    private var targetLabel: String = ""
    private var targetDestination: FolderDestination? = null
    private var existing: FolderPolicy.Existing = FolderPolicy.Existing.NONE
    private var existingNode: TreeNode? = null
    private var newFolderName: String = offer.rootName
    private var offeredChoices: List<ConflictChoice> = emptyList()
    private var clashingFiles: Int? = null
    private var askReason: FolderPolicy.AskReason? = null

    // Receiving.
    private var choice: ConflictChoice = ConflictChoice.NONE
    private var rootName: String = offer.rootName
    private var rootId: String? = null
    private var journal: FolderJournals.Writer? = null
    private val dirIds = HashMap<String, String>()
    private val doneDirs = HashSet<Int>()
    private val failedDirs = HashSet<String>()
    private var nextDirScan = 0
    private val listings = HashMap<String, MutableMap<String, TreeNode>>()
    private val done = HashSet<Int>()
    private val dropped = HashSet<String>()
    private var lastEntry = -1
    private var current: Incoming? = null
    private val failures = ArrayList<FolderFailure>()
    private var failedCount = 0
    private var createdFolders = 0
    private var renamedFiles = 0
    private var replacedFiles = 0
    private var emptyFoldersSkipped = 0
    private var bytesDone = 0L
    private val recent = ArrayDeque<String>()

    // Timers and progress.
    private var timer: Cancellable? = null
    private var timerGeneration = 0
    private var deadline: Long? = null
    private var waiting: FolderWaiting? = FolderWaiting.MANIFEST
    private var lastEmitAt = 0L
    private var speedSampleAt = 0L
    private var speedSampleBytes = 0L
    private var bytesPerSecond = 0L

    private class Incoming(
        val transferId: String,
        val index: Int,
        val entry: ManifestEntry,
        val parentId: String,
        var fileId: String,
        val writeName: String,
        val finalName: String,
        val usesPart: Boolean,
        val replaceId: String?,
        val renamed: Boolean,
        val output: OutputStream,
    ) {
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        var nextSequence = 0L
    }

    // Events. Socket messages keep their order ([FolderWorker.post]); the rest go first ([FolderWorker.postControl]).

    fun start() = env.worker.post { onStart() }
    fun manifestPage(page: ManifestPagePayload, plaintextBytes: Int) = env.worker.post { onManifestPage(page, plaintextBytes) }
    fun resolve(payload: FolderResolvePayload) = env.worker.post { onResolve(payload.choice) }
    fun fileOffer(transferId: String, fields: FolderFileFields, name: String, size: Long, sha256: String) =
        env.worker.post { onFileOffer(transferId, fields, name, size, sha256) }

    fun chunk(transferId: String, sequence: Long, bytes: ByteArray) = env.worker.post { onChunk(transferId, sequence, bytes) }
    fun fileComplete(transferId: String, sha256: String) = env.worker.post { onFileComplete(transferId, sha256) }
    fun fileCancelled(transferId: String) = env.worker.post { onFileCancelled(transferId) }
    fun folderComplete(payload: FolderCompletePayload) = env.worker.post { onFolderComplete(payload) }
    fun cancelledBySender(payload: FolderCancelPayload) = env.worker.postControl { onCancelledBySender(payload) }
    fun answerDestination(answer: DestinationAnswer) = env.worker.postControl { onDestinationAnswer(answer) }
    fun answerConflict(answer: ConflictChoice) = env.worker.postControl { onConflictAnswer(answer) }

    /** Cancel on this phone: the row's Cancel, or Cancel in a question sheet. */
    fun cancelHere() = env.worker.postControl { onCancelHere() }

    /** A folder message that decrypted but is invalid: rejected before the accept, cancelled after it. */
    fun invalidMessage() = env.worker.postControl {
        when (phase) {
            Phase.DONE -> Unit
            Phase.MANIFEST -> reject(FolderCodes.INVALID_MESSAGE)
            else -> cancel(CancelReasons.ERROR, FolderCodes.INVALID_MESSAGE, if (rootId != null) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, here = false)
        }
    }

    /** The device disconnected. */
    fun interrupt() = env.worker.postControl { onInterrupted() }

    /** Whether a per-file transfer of this folder is being dropped (its chunks are ignored quietly). */
    fun owns(transferId: String): Boolean = transferId in ownedTransfers

    private val ownedTransfers = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** The coordinator registers a per-file transfer ID before posting its offer, so its chunks find this session. */
    fun claim(transferId: String) {
        ownedTransfers += transferId
    }

    // Manifest.

    private fun onStart() {
        log("offer resume=${offer.resume} into=${offer.into} files=${offer.fileCount} folders=${offer.folderCount} pages=${offer.pageCount}")
        // Files 2.0: a phone never asks a Mac for downloads, so an offer answering one is not for it. Uploads
        // (`into`) need browsing on, "Allow other devices to change files here" on, and a destination.
        if (offer.downloadRequestId != null) return reject(FolderCodes.POLICY)
        if (offer.into) {
            val current = env.settings()
            if (!current.allowBrowse) return reject(FolderCodes.POLICY)
            if (!current.allowReplaceFromOtherDevices) return reject(FolderCodes.READ_ONLY)
            if (offer.destination == null) return reject(FolderCodes.INVALID_MESSAGE)
        }
        emit(force = true)
        val immediate = assembler.completeWithoutPages()
        if (immediate != null) return manifestResult(immediate)
        startTimer(FolderTimeouts.FIRST_ANSWER_MILLIS) { reject(FolderCodes.TIMEOUT) }
    }

    private fun onManifestPage(page: ManifestPagePayload, bytes: Int) {
        if (phase != Phase.MANIFEST) return
        val result = assembler.add(page, bytes)
        if (result != ManifestAssembler.Result.NeedMore) manifestResult(result)
    }

    private fun manifestResult(result: ManifestAssembler.Result) {
        when (result) {
            is ManifestAssembler.Result.Rejected -> reject(result.code, entry = result.entry)
            is ManifestAssembler.Result.Complete -> {
                cancelTimer()
                entries = result.entries
                if (offer.resume) resume() else chooseDestination()
            }
            ManifestAssembler.Result.NeedMore -> Unit
        }
    }

    // Destination (3.2).

    private fun chooseDestination() {
        if (offer.into) return chooseUploadDestination(offer.destination!!)
        val settings = env.settings()
        val defaultPlace = env.places.place(settings.defaultPlaceId)
        when (val decision = FolderPolicy.destination(settings.mode, offer.destination, defaultPlace?.available == true)) {
            is FolderPolicy.Destination.Offered -> {
                val offered = decision.destination
                val chosen = env.places.place(offered.placeId)?.takeIf { it.available } ?: return reject(FolderCodes.PLACE_UNAVAILABLE)
                val opened = openStore(chosen) ?: return reject(FolderCodes.PLACE_UNAVAILABLE)
                val dirId = try {
                    resolveExistingPath(opened, offered.path)
                } catch (error: IOException) {
                    return reject(storageErrorCode(error).let { if (it == FolderCodes.IO_ERROR) FolderCodes.PLACE_UNAVAILABLE else it })
                } ?: return reject(FolderCodes.NOT_FOUND)
                prepare(chosen, opened, dirId, offered, FolderPolicy.Asker.SENDER)
            }
            FolderPolicy.Destination.Fixed -> {
                val chosen = defaultPlace!!
                val opened = openStore(chosen) ?: return askDestination(FolderPolicy.AskReason.DEFAULT_UNAVAILABLE)
                prepare(chosen, opened, opened.rootId, FolderDestination(chosen.placeId, ""), FolderPolicy.Asker.RECEIVER)
            }
            is FolderPolicy.Destination.AskHere -> askDestination(decision.reason)
        }
    }

    /** An upload into a browsed folder: the destination is the sender's, whatever this phone's folder mode. */
    private fun chooseUploadDestination(offered: FolderDestination) {
        val chosen = env.places.place(offered.placeId)?.takeIf { it.available } ?: return reject(FolderCodes.PLACE_UNAVAILABLE)
        val opened = openStore(chosen) ?: return reject(FolderCodes.PLACE_UNAVAILABLE)
        val dirId = try {
            resolveExistingPath(opened, offered.path)
        } catch (error: IOException) {
            return reject(storageErrorCode(error).let { if (it == FolderCodes.IO_ERROR) FolderCodes.PLACE_UNAVAILABLE else it })
        } ?: return reject(FolderCodes.NOT_FOUND)
        place = chosen
        store = opened
        targetDirId = dirId
        targetDestination = offered
        targetLabel = destinationLabel(chosen.label, offered.path)
        val free = runCatching { opened.freeBytes() }.getOrNull()
        val needed = offer.totalSize + FolderLimits.SPACE_MARGIN
        if (free != null && free < needed) return reject(FolderCodes.INSUFFICIENT_SPACE, neededBytes = needed, freeBytes = free)
        try {
            listing(dirId)
        } catch (error: IOException) {
            return reject(storageErrorCode(error).let { if (it == FolderCodes.IO_ERROR) FolderCodes.PLACE_UNAVAILABLE else it })
        }
        accept(ConflictChoice.NONE)
    }

    private fun askDestination(reason: FolderPolicy.AskReason) {
        askReason = reason
        phase = Phase.ASK_DESTINATION
        waiting = FolderWaiting.DESTINATION
        link.send(FolderKinds.WAITING, foldersWaitingJson(id, WaitingReasons.DESTINATION))
        startQuestionTimer()
        val defaultLabel = if (reason == FolderPolicy.AskReason.DEFAULT_UNAVAILABLE) {
            env.places.place(env.settings().defaultPlaceId)?.label
        } else {
            null
        }
        listener.question(baseQuestion(FolderQuestion.Kind.DESTINATION).copy(reason = reason, unavailableDefaultLabel = defaultLabel))
        log("waiting reason=destination")
        emit(force = true)
    }

    private fun onDestinationAnswer(answer: DestinationAnswer) {
        if (phase != Phase.ASK_DESTINATION) return
        listener.question(null)
        val chosen = when {
            answer.oneOffTree != null -> env.places.oneOff(answer.oneOffTree)
            answer.placeId != null -> env.places.place(answer.placeId)
            else -> null
        }?.takeIf { it.available } ?: return cancel(CancelReasons.ERROR, FolderCodes.PLACE_UNAVAILABLE, FolderEnd.CANCELLED, here = true)
        val opened = openStore(chosen) ?: return cancel(CancelReasons.ERROR, FolderCodes.PLACE_UNAVAILABLE, FolderEnd.CANCELLED, here = true)
        val dirId = runCatching { resolveExistingPath(opened, answer.path) }.getOrNull()
            ?: return cancel(CancelReasons.ERROR, FolderCodes.NOT_FOUND, FolderEnd.CANCELLED, here = true)
        val destination = FolderDestination(chosen.placeId, answer.path).takeIf { chosen.oneOffTree == null }
        prepare(chosen, opened, dirId, destination, FolderPolicy.Asker.RECEIVER)
    }

    private fun openStore(place: PlaceRef): TreeStore? = runCatching { place.open() }.getOrNull()

    /** Free space, the existence check and the clash count, then the conflict decision (3.3). */
    private fun prepare(chosen: PlaceRef, opened: TreeStore, dirId: String, destination: FolderDestination?, asker: FolderPolicy.Asker) {
        place = chosen
        store = opened
        targetDirId = dirId
        targetDestination = destination
        targetLabel = destinationLabel(chosen.label, destination?.path.orEmpty())
        val free = runCatching { opened.freeBytes() }.getOrNull()
        val needed = offer.totalSize + FolderLimits.SPACE_MARGIN
        if (free != null && free < needed) return reject(FolderCodes.INSUFFICIENT_SPACE, neededBytes = needed, freeBytes = free)
        val siblings = try {
            listing(dirId)
        } catch (error: IOException) {
            return reject(storageErrorCode(error).let { if (it == FolderCodes.IO_ERROR) FolderCodes.PLACE_UNAVAILABLE else it })
        }
        val hit = siblings[caseKey(offer.rootName)]
        existingNode = hit
        existing = when {
            hit == null -> FolderPolicy.Existing.NONE
            hit.isDirectory -> FolderPolicy.Existing.FOLDER
            else -> FolderPolicy.Existing.FILE
        }
        newFolderName = ConflictNames.firstFree(offer.rootName, isDirectory = true) { it in siblings }
        clashingFiles = if (existing == FolderPolicy.Existing.FOLDER) countClashes(opened, hit!!.id) else null
        when (val decision = FolderPolicy.conflict(existing, env.settings().policy, asker)) {
            is FolderPolicy.Conflict.Proceed -> accept(decision.choice)
            is FolderPolicy.Conflict.Ask -> {
                offeredChoices = decision.choices
                if (decision.where == FolderPolicy.Asker.SENDER) askSender() else askHere(confirmsRemoteReplace = false)
            }
        }
    }

    /** "12 of 124 files have the same names", or null when counting takes longer than 3 seconds. */
    private fun countClashes(opened: TreeStore, existingRootId: String): Int? {
        val deadline = env.clock() + CLASH_COUNT_MILLIS
        val existingDirs = HashMap<String, String>().apply { put("", existingRootId) }
        var files = 0
        return try {
            for (entry in entries) {
                if (env.clock() > deadline) return null
                val parentId = existingDirs[FolderPaths.parent(entry.path)] ?: continue
                val hit = listing(parentId, opened)[caseKey(FolderPaths.leaf(entry.path))] ?: continue
                if (entry.isDirectory) {
                    if (hit.isDirectory) existingDirs[entry.path] = hit.id
                } else {
                    files++
                }
            }
            if (env.clock() > deadline) null else files
        } catch (_: IOException) {
            null
        }
    }

    private fun askSender() {
        phase = Phase.ASK_CONFLICT_ON_SENDER
        waiting = FolderWaiting.CONFLICT_ON_SENDER
        val payload = FolderConflictPayload(
            folderTransferId = id,
            existing = if (existing == FolderPolicy.Existing.FILE) FolderConflictPayload.EXISTING_FILE else FolderConflictPayload.EXISTING_FOLDER,
            clashingFiles = clashingFiles,
            clashingFolders = null,
            newFolderName = newFolderName,
            choices = offeredChoices,
            timeoutSeconds = FolderTimeouts.QUESTION_SECONDS,
        )
        link.send(FolderKinds.CONFLICT, payload.toJson())
        // The sender counts the 180 seconds; this side gives up after the sender's own limit.
        deadline = env.clock() + FolderTimeouts.QUESTION_SECONDS * 1000L
        startTimer(FolderTimeouts.SENDER_QUESTION_WAIT_MILLIS) { timeOut() }
        log("conflict asked on sender existing=${payload.existing} clashes=${clashingFiles ?: -1}")
        emit(force = true)
    }

    private fun askHere(confirmsRemoteReplace: Boolean) {
        phase = Phase.ASK_CONFLICT_HERE
        waiting = FolderWaiting.CONFLICT_HERE
        link.send(FolderKinds.WAITING, foldersWaitingJson(id, WaitingReasons.CONFLICT))
        startQuestionTimer()
        listener.question(
            baseQuestion(FolderQuestion.Kind.CONFLICT).copy(
                existing = existing,
                destinationLabel = targetLabel,
                clashingFiles = clashingFiles,
                newFolderName = newFolderName,
                choices = offeredChoices,
                confirmsRemoteReplace = confirmsRemoteReplace,
            ),
        )
        log("waiting reason=conflict confirm=$confirmsRemoteReplace")
        emit(force = true)
    }

    private fun onResolve(answer: ConflictChoice) {
        // Valid only while this side waits on the sender's answer, and only for a choice it offered.
        if (phase != Phase.ASK_CONFLICT_ON_SENDER || !FolderPolicy.isOffered(answer, offeredChoices)) return
        cancelTimer()
        when {
            answer == ConflictChoice.CANCEL -> cancel(CancelReasons.USER, FolderCodes.DECLINED, FolderEnd.CANCELLED, here = false)
            FolderPolicy.replaceNeedsLocalConfirmation(answer, FolderPolicy.Asker.SENDER, env.settings().allowReplaceFromOtherDevices) ->
                askHere(confirmsRemoteReplace = true)
            else -> accept(answer)
        }
    }

    private fun onConflictAnswer(answer: ConflictChoice) {
        if (phase != Phase.ASK_CONFLICT_HERE) return
        if (answer != ConflictChoice.CANCEL && answer !in offeredChoices) return
        listener.question(null)
        cancelTimer()
        if (answer == ConflictChoice.CANCEL) cancel(CancelReasons.USER, FolderCodes.DECLINED, FolderEnd.CANCELLED, here = true) else accept(answer)
    }

    private fun accept(requested: ConflictChoice) {
        val opened = store ?: return reject(FolderCodes.PLACE_UNAVAILABLE)
        val parentId = targetDirId ?: return reject(FolderCodes.PLACE_UNAVAILABLE)
        val existingDir = existingNode?.takeIf { it.isDirectory }
        if (offer.into) {
            // No root folder: entries land in the destination itself; top-level clashes become copies.
            choice = ConflictChoice.NONE
            rootName = offer.rootName
            rootId = parentId
            return acceptPrepared(opened)
        }
        // An existing file allows only a new folder; Merge or Replace into a file never happens.
        choice = if ((requested == ConflictChoice.MERGE || requested == ConflictChoice.REPLACE) && existingDir == null) {
            if (existingNode != null) ConflictChoice.NEW_FOLDER else ConflictChoice.NONE
        } else {
            requested
        }
        try {
            when (choice) {
                ConflictChoice.MERGE, ConflictChoice.REPLACE -> {
                    rootName = existingDir!!.name
                    rootId = existingDir.id
                }
                else -> {
                    val siblings = listing(parentId)
                    rootName = ConflictNames.firstFree(offer.rootName, isDirectory = true) { it in siblings }
                    val created = opened.createDirectory(parentId, rootName)
                    siblings[caseKey(rootName)] = TreeNode(created, rootName, true)
                    listings[created] = HashMap()
                    rootId = created
                }
            }
        } catch (error: IOException) {
            return reject(storageErrorCode(error).let { if (it == FolderCodes.IO_ERROR) FolderCodes.PLACE_UNAVAILABLE else it })
        } catch (error: SecurityException) {
            return reject(FolderCodes.PLACE_UNAVAILABLE)
        }
        acceptPrepared(opened)
    }

    private fun acceptPrepared(opened: TreeStore) {
        dirIds[""] = rootId!!
        journal = runCatching {
            env.journals?.create(
                id,
                FolderJournals.Header(
                    peerId, offer.manifestSha256, env.clock(), place!!.placeId, choice, rootName, opened.uriOf(rootId!!), targetLabel, place!!.oneOffTree,
                ),
            )
        }.getOrNull()
        if (!offer.into) targetDestination?.let(listener::usedDestination)
        beginReceiving(bitmap = null)
    }

    private fun beginReceiving(bitmap: String?) {
        phase = Phase.RECEIVING
        waiting = null
        deadline = null
        listener.question(null)
        cancelTimer()
        val free = runCatching { store?.freeBytes() }.getOrNull()
        link.send(FolderKinds.ACCEPT, FolderAcceptPayload(id, rootName, targetLabel, choice, bitmap, free).toJson())
        log("accepted choice=${choice.wire} resume=${bitmap != null}")
        emit(force = true)
    }

    // Resume (4.7, 6.6).

    private fun resume() {
        val journals = env.journals ?: return reject(FolderCodes.RESUME_UNAVAILABLE)
        val record = journals.read(id)
        if (record == null || record.header.peerId != peerId || record.header.manifestSha256 != offer.manifestSha256 ||
            !FolderTimeouts.canResume(record.lastProgressMillis, env.clock())
        ) return reject(FolderCodes.RESUME_UNAVAILABLE)
        val chosen = (record.header.oneOffTree?.let(env.places::oneOff) ?: env.places.place(record.header.placeId))
            ?.takeIf { it.available } ?: return reject(FolderCodes.RESUME_UNAVAILABLE)
        val opened = openStore(chosen) ?: return reject(FolderCodes.RESUME_UNAVAILABLE)
        runCatching { journals.repair(record, opened) }
        val repaired = journals.read(id) ?: return reject(FolderCodes.RESUME_UNAVAILABLE)
        val root = opened.idOf(repaired.header.rootUri) ?: return reject(FolderCodes.RESUME_UNAVAILABLE)
        place = chosen
        store = opened
        targetLabel = repaired.header.destinationLabel
        choice = repaired.header.choice
        rootName = repaired.header.rootName
        rootId = root
        dirIds[""] = root
        repaired.dirs.forEach { (index, uri) ->
            val entry = entries.getOrNull(index)?.takeIf { it.isDirectory } ?: return@forEach
            val dirId = opened.idOf(uri) ?: return@forEach
            dirIds[entry.path] = dirId
            doneDirs += index
        }
        repaired.done.filter { entries.getOrNull(it)?.isDirectory == false }.forEach { index ->
            done += index
            bytesDone += entries[index].size
        }
        journal = journals.reopen(id)
        val bitmap = CompletedBitmap.encode(entries.size) { it in done || it in doneDirs }
        beginReceiving(bitmap)
    }

    // Files (4.6).

    private fun onFileOffer(transferId: String, fields: FolderFileFields, name: String, size: Long, sha256: String) {
        if (phase == Phase.DONE) return
        if (phase != Phase.RECEIVING) return entryFailed(fields.entry, transferId, FolderCodes.INVALID_MESSAGE)
        current?.let { previous -> failCurrent(previous, FolderCodes.INVALID_MESSAGE) }
        if (phase != Phase.RECEIVING) return
        val index = fields.entry
        val entry = entries.getOrNull(index)
        if (entry == null || entry.isDirectory || index <= lastEntry || fields.path != entry.path || name != FolderPaths.leaf(entry.path) ||
            size != entry.size || sha256 != entry.sha256
        ) return entryFailed(index, transferId, FolderCodes.INVALID_MESSAGE)
        lastEntry = index
        ensureDirs(index)
        if (phase != Phase.RECEIVING) return
        val parentPath = FolderPaths.parent(entry.path)
        val parentId = dirIds[parentPath]
        if (parentId == null || parentPath in failedDirs) return entryFailed(index, transferId, FolderCodes.IO_ERROR)
        val opened = store!!
        try {
            val siblings = listing(parentId)
            val leaf = FolderPaths.leaf(entry.path)
            val clash = siblings[caseKey(leaf)]
            var finalName = leaf
            var replaceId: String? = null
            var renamed = false
            when {
                clash == null -> Unit
                // A folder is never replaced by a file: keep both, renaming the incoming file.
                clash.isDirectory || choice != ConflictChoice.REPLACE -> {
                    finalName = ConflictNames.firstFree(leaf, isDirectory = false) { it in siblings }
                    renamed = true
                }
                else -> {
                    replaceId = clash.id
                    finalName = clash.name
                }
            }
            val usesPart = replaceId != null || entry.size > FolderLimits.PART_FILE_THRESHOLD
            val writeName = if (usesPart) ConflictNames.firstFree(".$finalName.bridgey-part", isDirectory = false) { it in siblings } else finalName
            if (replaceId == null) siblings[caseKey(finalName)] = TreeNode("", finalName, false)
            if (usesPart) siblings[caseKey(writeName)] = TreeNode("", writeName, false)
            val fileId = opened.createFile(parentId, writeName)
            if (usesPart) siblings[caseKey(writeName)] = TreeNode(fileId, writeName, false) else siblings[caseKey(finalName)] = TreeNode(fileId, finalName, false)
            journal?.part(index, opened.uriOf(fileId))
            val output = try {
                opened.openOutput(fileId)
            } catch (error: IOException) {
                runCatching { opened.delete(fileId) }
                throw error
            }
            current = Incoming(transferId, index, entry, parentId, fileId, writeName, finalName, usesPart, replaceId, renamed, output)
        } catch (error: IOException) {
            return storageFailure(index, transferId, error)
        } catch (error: SecurityException) {
            return storageFailure(index, transferId, PlaceUnavailableException(cause = error))
        }
        link.sendOuter("files.accept", transferId)
        emit(force = true)
    }

    private fun onChunk(transferId: String, sequence: Long, bytes: ByteArray) {
        if (transferId in dropped || phase != Phase.RECEIVING) return
        val incoming = current?.takeIf { it.transferId == transferId } ?: return
        if (sequence != incoming.nextSequence || incoming.received + bytes.size > incoming.entry.size) {
            return failCurrent(incoming, FolderCodes.INVALID_MESSAGE)
        }
        try {
            incoming.output.write(bytes)
        } catch (error: IOException) {
            return failCurrent(incoming, storageErrorCode(error))
        }
        incoming.digest.update(bytes)
        incoming.received += bytes.size
        incoming.nextSequence++
        bytesDone += bytes.size
        link.sendOuter("files.chunk.ack", transferId, sequence)
        emit()
    }

    private fun onFileComplete(transferId: String, sha256: String) {
        if (transferId in dropped || phase != Phase.RECEIVING) return
        val incoming = current?.takeIf { it.transferId == transferId } ?: return
        val opened = store!!
        try {
            incoming.output.close()
        } catch (error: IOException) {
            return failCurrent(incoming, storageErrorCode(error))
        }
        val actual = java.util.Base64.getEncoder().encodeToString(incoming.digest.digest())
        val expected = incoming.entry.sha256
        if (incoming.received != incoming.entry.size || sha256 != expected || actual != expected) {
            return failCurrent(incoming, FolderCodes.VERIFICATION_FAILED, closed = true)
        }
        val siblings = listings[incoming.parentId]
        try {
            var fileId = incoming.fileId
            if (incoming.usesPart) {
                val old = incoming.replaceId
                if (old != null) {
                    // Replace: only now, after verification, the old file goes.
                    journal?.replace(incoming.index, opened.uriOf(old), opened.uriOf(fileId), incoming.finalName)
                    opened.delete(old)
                    val renamed = runCatching { opened.rename(fileId, incoming.finalName) }
                    if (renamed.isFailure) {
                        // The old file is gone and the verified part stays: the journal's r line finishes the
                        // rename on the next start. Never delete the only copy.
                        current = null
                        bytesDone -= incoming.received
                        return entryFailed(incoming.index, transferId, storageErrorCode(renamed.exceptionOrNull()!!))
                    }
                    fileId = renamed.getOrThrow()
                } else {
                    fileId = opened.rename(fileId, incoming.finalName)
                }
                siblings?.remove(caseKey(incoming.writeName))
            }
            opened.publish(fileId)
            siblings?.set(caseKey(incoming.finalName), TreeNode(fileId, incoming.finalName, false))
        } catch (error: IOException) {
            return failCurrent(incoming, storageErrorCode(error), closed = true)
        } catch (error: SecurityException) {
            return failCurrent(incoming, FolderCodes.PLACE_UNAVAILABLE, closed = true)
        }
        runCatching { journal?.done(incoming.index) }
        current = null
        done += incoming.index
        if (incoming.replaceId != null) replacedFiles++
        if (incoming.renamed) renamedFiles++
        recent.addLast(incoming.finalName)
        while (recent.size > MAX_RECENT) recent.removeFirst()
        link.sendOuter("files.complete.ack", transferId)
        emit(force = done.size == entries.count { !it.isDirectory })
    }

    private fun onFileCancelled(transferId: String) {
        val incoming = current?.takeIf { it.transferId == transferId }
        if (incoming != null) {
            discard(incoming, closed = false)
            current = null
        }
        dropped += transferId
        link.sendOuter("files.cancel.ack", transferId)
        emit(force = true)
    }

    /** Before file entry k, every folder entry below k exists (4.6). */
    private fun ensureDirs(upTo: Int) {
        val opened = store ?: return
        while (nextDirScan < upTo && phase == Phase.RECEIVING) {
            val index = nextDirScan++
            val entry = entries[index]
            if (!entry.isDirectory || index in doneDirs) continue
            val parentPath = FolderPaths.parent(entry.path)
            val parentId = dirIds[parentPath]
            if (parentId == null || parentPath in failedDirs) {
                failedDirs += entry.path
                recordFailure(index, FolderCodes.IO_ERROR)
                continue
            }
            try {
                val siblings = listing(parentId)
                val leaf = FolderPaths.leaf(entry.path)
                val clash = siblings[caseKey(leaf)]
                // An upload never merges into an existing top-level folder: it lands as "Name (1)".
                val mergeInto = clash != null && clash.isDirectory && !(offer.into && parentPath.isEmpty())
                val dirId = if (mergeInto) {
                    clash!!.id
                } else {
                    // A file of that name (or an upload's top-level folder): keep both, renaming the incoming folder.
                    val name = if (clash == null) leaf else ConflictNames.firstFree(leaf, isDirectory = true) { it in siblings }
                    opened.createDirectory(parentId, name).also { created ->
                        siblings[caseKey(name)] = TreeNode(created, name, true)
                        listings[created] = HashMap()
                        createdFolders++
                    }
                }
                dirIds[entry.path] = dirId
                doneDirs += index
                runCatching { journal?.dir(index, opened.uriOf(dirId)) }
            } catch (error: Exception) {
                if (error !is IOException && error !is SecurityException) throw error
                val code = if (error is SecurityException) FolderCodes.PLACE_UNAVAILABLE else storageErrorCode(error)
                if (code != FolderCodes.IO_ERROR) return stopFolder(code)
                failedDirs += entry.path
                recordFailure(index, code)
            }
        }
    }

    private fun onFolderComplete(payload: FolderCompletePayload) {
        if (phase != Phase.RECEIVING) return
        current?.let { failCurrent(it, FolderCodes.INVALID_MESSAGE) }
        if (phase != Phase.RECEIVING) return
        ensureDirs(entries.size)
        if (phase != Phase.RECEIVING) return
        // Folders with nothing inside: the MediaStore fallback can only try to keep them.
        val opened = store!!
        val withFiles = HashSet<String>()
        entries.filter { !it.isDirectory }.forEach { file ->
            var parent = FolderPaths.parent(file.path)
            while (parent.isNotEmpty() && withFiles.add(parent)) parent = FolderPaths.parent(parent)
        }
        entries.forEachIndexed { index, entry ->
            if (entry.isDirectory && index in doneDirs && entry.path !in withFiles && entries.none { it.path.startsWith(entry.path + "/") }) {
                val dirId = dirIds[entry.path] ?: return@forEachIndexed
                if (!runCatching { opened.keepEmptyDirectory(dirId) }.getOrDefault(false)) emptyFoldersSkipped++
            }
        }
        val fileIndexes = entries.indices.filter { !entries[it].isDirectory }
        val dirIndexes = entries.indices.filter { entries[it].isDirectory }
        val complete = fileIndexes.all { it in done } && dirIndexes.all { it in doneDirs }
        val failed = (failures.map { FailedEntry(it.entry, it.code) } + payload.failed).take(FolderLimits.MAX_REPORTED_FAILURES)
        val result = FolderResultPayload(
            folderTransferId = id,
            complete = complete,
            savedFiles = done.size,
            savedBytes = done.sumOf { entries[it].size },
            createdFolders = createdFolders,
            renamedFiles = renamedFiles,
            replacedFiles = replacedFiles,
            failedCount = failedCount + payload.failedCount,
            failed = failed,
        )
        failedCount += payload.failedCount
        link.send(FolderKinds.RESULT, result.toJson())
        dropJournal()
        log("result complete=$complete saved=${done.size} failed=$failedCount renamed=$renamedFiles replaced=$replacedFiles")
        finish(if (complete) FolderEnd.COMPLETE else FolderEnd.INCOMPLETE, code = null, here = false)
    }

    // Failures.

    private fun storageFailure(index: Int, transferId: String, error: IOException) {
        val code = storageErrorCode(error)
        if (code == FolderCodes.IO_ERROR) entryFailed(index, transferId, code) else stopFolder(code)
    }

    private fun failCurrent(incoming: Incoming, code: String, closed: Boolean = false) {
        current = null
        discard(incoming, closed)
        if (code == FolderCodes.PLACE_UNAVAILABLE || code == FolderCodes.INSUFFICIENT_SPACE) {
            dropped += incoming.transferId
            return stopFolder(code)
        }
        entryFailed(incoming.index, incoming.transferId, code)
    }

    /** Deletes a file that did not finish; the cut-off file restarts on resume. */
    private fun discard(incoming: Incoming, closed: Boolean) {
        if (!closed) runCatching { incoming.output.close() }
        runCatching { store?.delete(incoming.fileId) }
        listings[incoming.parentId]?.let { siblings ->
            siblings.remove(caseKey(incoming.writeName))
            // The final name was reserved for this file; under Replace it still names the old file.
            if (incoming.replaceId == null) siblings.remove(caseKey(incoming.finalName))
        }
        runCatching { journal?.abandoned(incoming.index) }
        bytesDone -= incoming.received
    }

    private fun entryFailed(index: Int, transferId: String, code: String) {
        dropped += transferId
        link.send(FolderKinds.ENTRY_FAILED, foldersEntryFailedJson(id, index, transferId, code))
        recordFailure(index, code)
    }

    private fun recordFailure(index: Int, code: String) {
        failedCount++
        if (failures.size < FolderLimits.MAX_REPORTED_FAILURES) {
            failures += FolderFailure(index, entries.getOrNull(index)?.path?.let(FolderPaths::leaf).orEmpty(), code)
        }
        log("entry failed code=$code failures=$failedCount")
        if (failedCount >= FolderLimits.MAX_FAILURES_BEFORE_CANCEL && phase == Phase.RECEIVING) {
            cancel(CancelReasons.ERROR, FolderCodes.TOO_MANY_FAILURES, FolderEnd.INCOMPLETE, here = false)
        } else {
            emit(force = true)
        }
    }

    /** A folder-level storage failure: lost access or a full disk. Completed files stay. */
    private fun stopFolder(code: String) {
        if (code == FolderCodes.PLACE_UNAVAILABLE) place?.let { listener.lostAccess(it.label) }
        cancel(CancelReasons.ERROR, code, FolderEnd.INCOMPLETE, here = false)
    }

    // Cancel, timeouts and disconnects.

    private fun onCancelledBySender(payload: FolderCancelPayload) {
        if (phase == Phase.DONE) {
            link.sendOuter(FolderKinds.CANCEL_ACK, id)
            return
        }
        val accepted = rootId != null
        abandonCurrent()
        dropJournal()
        link.sendOuter(FolderKinds.CANCEL_ACK, id)
        log("cancelled by sender reason=${payload.reason}")
        finish(if (accepted) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, code = payload.code ?: FolderCodes.CANCELLED, here = false)
    }

    private fun onCancelHere() {
        if (phase == Phase.DONE) return
        val asking = phase == Phase.ASK_DESTINATION || phase == Phase.ASK_CONFLICT_HERE
        cancel(CancelReasons.USER, if (asking) FolderCodes.DECLINED else null, if (rootId != null) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, here = true)
    }

    private fun timeOut() {
        if (phase != Phase.ASK_DESTINATION && phase != Phase.ASK_CONFLICT_HERE && phase != Phase.ASK_CONFLICT_ON_SENDER) return
        cancel(CancelReasons.TIMEOUT, FolderCodes.TIMEOUT, FolderEnd.TIMED_OUT, here = false)
    }

    private fun onInterrupted() {
        if (phase == Phase.DONE) return
        abandonCurrent()
        val resumable = rootId != null && journal != null
        runCatching { journal?.close() }
        journal = null
        log("interrupted resumable=$resumable")
        finish(FolderEnd.INTERRUPTED, code = null, here = false, resumable = resumable)
    }

    private fun abandonCurrent() {
        current?.let { incoming ->
            dropped += incoming.transferId
            discard(incoming, closed = false)
        }
        current = null
    }

    /** Sends folders.cancel and ends. Completed files stay; the file in progress is deleted; the journal goes. */
    private fun cancel(reason: String, code: String?, end: FolderEnd, here: Boolean) {
        abandonCurrent()
        link.send(FolderKinds.CANCEL, FolderCancelPayload(id, reason, code).toJson(), outerTransferId = id)
        dropJournal()
        log("cancelled reason=$reason code=${code ?: "none"}")
        finish(end, code = code ?: FolderCodes.CANCELLED, here = here)
    }

    /** folders.rejected before anything was written. */
    private fun reject(code: String, entry: Int? = null, neededBytes: Long? = null, freeBytes: Long? = null) {
        if (phase == Phase.DONE) return
        link.send(FolderKinds.REJECTED, foldersRejectedJson(id, code, entry, neededBytes, freeBytes), outerTransferId = id)
        log("rejected code=$code")
        finish(FolderEnd.CANCELLED, code = code, here = false)
    }

    private fun dropJournal() {
        runCatching { journal?.close() }
        journal = null
        env.journals?.delete(id)
    }

    private fun finish(end: FolderEnd, code: String?, here: Boolean, resumable: Boolean = false) {
        phase = Phase.DONE
        cancelTimer()
        listener.question(null)
        waiting = null
        deadline = null
        val snapshot = snapshot().copy(end = end, endCode = code, endedHere = here, resumable = resumable, currentFile = null)
        listener.snapshot(snapshot)
        listener.finished(snapshot)
        if (!resumable) place?.oneOffTree?.let(listener::releaseOneOff)
        env.worker.shutdown()
    }

    private fun startQuestionTimer() {
        deadline = env.clock() + FolderTimeouts.QUESTION_SECONDS * 1000L
        startTimer(FolderTimeouts.QUESTION_SECONDS * 1000L) { timeOut() }
    }

    private fun startTimer(delayMillis: Long, action: () -> Unit) {
        cancelTimer()
        val generation = ++timerGeneration
        timer = env.scheduler.schedule(delayMillis) {
            env.worker.postControl { if (generation == timerGeneration && phase != Phase.DONE) action() }
        }
    }

    private fun cancelTimer() {
        timerGeneration++
        timer?.cancel()
        timer = null
    }

    // Helpers.

    private fun listing(dirId: String, opened: TreeStore = store!!): MutableMap<String, TreeNode> =
        listings.getOrPut(dirId) { opened.children(dirId).associateByTo(HashMap()) { caseKey(it.name) } }

    private fun baseQuestion(kind: FolderQuestion.Kind) = FolderQuestion(
        folderTransferId = id,
        deviceId = peerId,
        deviceName = peerName,
        rootName = offer.rootName,
        fileCount = offer.fileCount,
        totalBytes = offer.totalSize,
        kind = kind,
        deadlineMillis = deadline ?: (env.clock() + FolderTimeouts.QUESTION_SECONDS * 1000L),
    )

    private fun snapshot(): FolderSnapshot {
        val incoming = current
        return FolderSnapshot(
            folderTransferId = id,
            deviceId = peerId,
            deviceName = peerName,
            rootName = rootName,
            filesTotal = offer.fileCount,
            bytesTotal = offer.totalSize,
            filesDone = done.size,
            bytesDone = bytesDone.coerceAtLeast(0),
            destinationLabel = targetLabel.takeIf { rootId != null || phase == Phase.ASK_CONFLICT_HERE || phase == Phase.ASK_CONFLICT_ON_SENDER },
            choice = choice.takeIf { rootId != null },
            waiting = waiting,
            deadlineMillis = deadline,
            currentFile = incoming?.finalName,
            currentFileBytes = incoming?.received ?: 0,
            currentFileSize = incoming?.entry?.size ?: 0,
            failures = failures.takeLast(MAX_SHOWN_FAILURES),
            failedCount = failedCount,
            recent = recent.toList(),
            renamedFiles = renamedFiles,
            replacedFiles = replacedFiles,
            skipped = offer.skipped,
            emptyFoldersSkipped = emptyFoldersSkipped,
            bytesPerSecond = bytesPerSecond,
            rootUri = rootId?.let { root -> store?.uriOf(root)?.takeIf { it.startsWith("content://") } },
        )
    }

    private fun emit(force: Boolean = false) {
        val now = env.clock()
        if (!force && now - lastEmitAt < EMIT_INTERVAL_MILLIS) return
        if (speedSampleAt == 0L) {
            speedSampleAt = now
            speedSampleBytes = bytesDone
        } else if (now - speedSampleAt >= EMIT_INTERVAL_MILLIS) {
            val sample = (bytesDone - speedSampleBytes).coerceAtLeast(0) * 1000 / (now - speedSampleAt)
            bytesPerSecond = dev.bridgey.android.smoothedRate(bytesPerSecond.toDouble(), sample.toDouble(), (now - speedSampleAt) / 1000.0).toLong()
            speedSampleAt = now
            speedSampleBytes = bytesDone
        }
        lastEmitAt = now
        listener.snapshot(snapshot())
    }

    private fun log(message: String) = env.log("FOLDER ${id.take(8)} $message")

    companion object {
        const val CLASH_COUNT_MILLIS = 3_000L
        const val EMIT_INTERVAL_MILLIS = 250L
        const val MAX_RECENT = 200
        const val MAX_SHOWN_FAILURES = 50
    }
}
