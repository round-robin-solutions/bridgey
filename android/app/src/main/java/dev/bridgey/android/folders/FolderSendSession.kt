package dev.bridgey.android.folders

import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/** How a sending folder session talks to its device (phone to Mac). Calls may block on the socket. */
interface FolderSendLink {
    /** An encrypted JSON message; [outerTransferId] repeats an ID outside (offer, cancel, files.offer, files.complete). */
    fun send(kind: String, payload: JSONObject, outerTransferId: String? = null): Boolean

    /** files.chunk: [bytes] encrypted, with the outer transfer ID and sequence. */
    fun sendChunk(transferId: String, sequence: Long, bytes: ByteArray): Boolean

    /** An outer-only message (files.cancel, folders.cancel.ack). */
    fun sendOuter(kind: String, transferId: String): Boolean
}

/** Everything a folder needs to go out: the hashed manifest, its sources and what the offer says. */
class FolderSendPlan(
    val folderTransferId: String,
    val rootName: String,
    val entries: List<ManifestEntry>,
    /** Opens file entry i for reading. */
    val open: (Int) -> InputStream,
    val skipped: SkippedCounts,
    val into: Boolean,
    val downloadRequestId: String?,
    val resume: Boolean,
) {
    val fileCount: Int = entries.count { !it.isDirectory }
    val folderCount: Int = entries.count { it.isDirectory }
    val totalSize: Long = entries.filter { !it.isDirectory }.sumOf { it.size }
    val manifestSha256: String = ManifestDigest.compute(rootName, entries)
    val pages: List<ManifestPagePayload> = ManifestPager.pages(folderTransferId, entries).orEmpty()

    fun offer(): FolderOfferPayload = FolderOfferPayload(
        folderTransferId, rootName, fileCount, folderCount, totalSize, pages.size, manifestSha256, null, resume, skipped, into, downloadRequestId,
    )

    fun resumed(): FolderSendPlan = FolderSendPlan(folderTransferId, rootName, entries, open, skipped, into, downloadRequestId, true)
}

/** How a folder sent from this phone ended. */
sealed interface FolderSendOutcome {
    data class Done(val result: FolderResultPayload) : FolderSendOutcome

    /** folders.complete went out but no folders.result came within 30 s. */
    data object Unconfirmed : FolderSendOutcome
    data class Rejected(val code: String) : FolderSendOutcome

    /** The outer-only folders.rejected: Files is off on the other device. */
    data object FilesOff : FolderSendOutcome
    data object CancelledHere : FolderSendOutcome
    data class CancelledByPeer(val code: String?) : FolderSendOutcome

    /** No first answer in 15 s, or the other device's question ran out. */
    data object NoAnswer : FolderSendOutcome
    data object Interrupted : FolderSendOutcome
}

interface FolderSendEvents {
    fun progress(session: FolderSendSession) = Unit

    /** A file finished; [completed] holds every entry known to be on the other device. */
    fun entriesCompleted(session: FolderSendSession, completed: Set<Int>) = Unit
    fun accepted(session: FolderSendSession, accept: FolderAcceptPayload) = Unit
    fun finished(session: FolderSendSession, outcome: FolderSendOutcome) = Unit
}

/**
 * The sending side of one folder transfer, phone to Mac (port of the Mac's FolderSendSession, sections 4.4
 * to 4.8): offer and manifest, the receiver's answers, pipelined files (at most 64 chunks unacknowledged
 * across the folder, at most 32 files awaiting files.complete.ack, one file's chunks at a time), the result,
 * cancels and interruptions. Driven from one thread (the owner's worker); timers come back through [post].
 */
class FolderSendSession(
    val plan: FolderSendPlan,
    alreadyCompleted: Set<Int>,
    private val link: FolderSendLink,
    private val scheduler: FolderScheduler,
    private val post: (() -> Unit) -> Unit,
    private val events: FolderSendEvents,
    private val clock: () -> Long = System::currentTimeMillis,
    private val makeId: () -> String = { UUID.randomUUID().toString() },
    private val log: (String) -> Unit = {},
) {
    enum class Phase { OFFERED, WAITING, SENDING, COMPLETING, CANCELLING, FINISHED }

    val id: String get() = plan.folderTransferId

    var phase: Phase = Phase.OFFERED
        private set

    /** The receiver's waiting reason and deadline while it asks its user. */
    var waitingReason: String? = null
        private set
    var waitingDeadline: Long? = null
        private set

    var acceptedRootName: String? = null
        private set
    var destinationLabel: String? = null
        private set
    var result: FolderResultPayload? = null
        private set

    private val completed = HashSet(alreadyCompleted)
    private val pending = ArrayDeque<Int>()
    private var current: CurrentFile? = null
    private val flights = LinkedHashMap<String, Flight>()
    private val senderFailures = ArrayList<FailedEntry>()
    private var senderFailureCount = 0
    val failures = ArrayList<FolderFailure>()
    var failedCount = 0
        private set
    private var sentFiles = 0
    private var waitTimer: Cancellable? = null
    private var watchdog: Cancellable? = null
    private var timerGeneration = 0
    private var lastAckProgress = clock()
    private var cancelAttemptsLeft = 0
    private var cancelReason = CancelReasons.USER
    private var cancelCode: String? = null
    private var pendingOutcome: FolderSendOutcome? = null
    private var completedBytes = 0L
    val recent = ArrayDeque<String>()

    var filesDone = 0
        private set
    val bytesDone: Long get() = (completedBytes + flights.values.sumOf { it.ackedBytes }).coerceAtMost(plan.totalSize)
    val currentFile: String? get() = current?.let { FolderPaths.leaf(plan.entries[it.entry].path) }
    val currentFileBytes: Long get() = current?.sent ?: 0
    val currentFileSize: Long get() = current?.size ?: 0
    val accepted: Boolean get() = acceptedRootName != null

    private class CurrentFile(val entry: Int, val transferId: String, val size: Long, val input: InputStream) {
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256")
        var sent = 0L
        var sequence = 0L
    }

    private class Flight(val entry: Int, val size: Long) {
        var chunksSent = 0L
        var acked = -1L
        var completeSent = false
        val unacked: Long get() = (chunksSent - (acked + 1)).coerceAtLeast(0)
        val ackedBytes: Long get() = minOf(size, (acked + 1) * CHUNK_SIZE)
    }

    /** Per-file transfer IDs of this folder, for routing files.* answers. */
    fun owns(transferId: String): Boolean = flights.containsKey(transferId) || transferId in ownedIds

    private val ownedIds = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    // Offer and answers.

    fun start() {
        if (phase != Phase.OFFERED) return
        link.send(FolderKinds.OFFER, plan.offer().toJson(), outerTransferId = id)
        plan.pages.forEach { page -> link.send(FolderKinds.MANIFEST, page.toJson()) }
        refreshCompletedCounts()
        armWait(FolderTimeouts.FIRST_ANSWER_MILLIS)
        log("offer files=${plan.fileCount} folders=${plan.folderCount} pages=${plan.pages.size} resume=${plan.resume} into=${plan.into}")
        events.progress(this)
    }

    private val beforeAccept: Boolean get() = phase == Phase.OFFERED || phase == Phase.WAITING

    fun receivedWaiting(payload: FolderWaitingPayload) {
        if (payload.folderTransferId != id || !beforeAccept) return
        phase = Phase.WAITING
        waitingReason = payload.reason
        waitingDeadline = clock() + payload.timeoutSeconds * 1000L
        armWait(FolderTimeouts.SENDER_QUESTION_WAIT_MILLIS)
        log("waiting reason=${payload.reason}")
        events.progress(this)
    }

    /** The phone never picks a destination on a Mac, so it is never asked; it answers with the safe choice. */
    fun receivedConflict(json: JSONObject) {
        if (!beforeAccept) return
        val choices = json.optJSONArray("choices")
        val safe = (0 until (choices?.length() ?: 0)).any { choices!!.optString(it) == ConflictChoice.NEW_FOLDER.wire }
        val choice = if (safe) ConflictChoice.NEW_FOLDER else ConflictChoice.CANCEL
        link.send(FolderKinds.RESOLVE, FolderResolvePayload(id, choice).toJson())
        if (choice == ConflictChoice.CANCEL) return finish(FolderSendOutcome.CancelledHere)
        armWait(FolderTimeouts.FIRST_ANSWER_MILLIS)
    }

    fun receivedAccept(payload: FolderAcceptPayload) {
        if (payload.folderTransferId != id || !beforeAccept) return
        cancelTimers()
        payload.completedBitmap?.let { CompletedBitmap.decode(it, plan.entries.size) }?.let(completed::addAll)
        acceptedRootName = payload.rootName
        destinationLabel = payload.destinationLabel
        waitingReason = null
        waitingDeadline = null
        events.accepted(this, payload)
        phase = Phase.SENDING
        pending.clear()
        plan.entries.indices.filterTo(pending) { !plan.entries[it].isDirectory && it !in completed }
        refreshCompletedCounts()
        lastAckProgress = clock()
        armWatchdog()
        log("accepted resumeSkips=${completed.size}")
        events.progress(this)
        pump()
    }

    fun receivedRejected(payload: FolderRejectedPayload) {
        if (payload.folderTransferId != id || phase == Phase.FINISHED) return
        finish(FolderSendOutcome.Rejected(payload.code))
    }

    fun receivedPolicyRejection() {
        if (phase != Phase.FINISHED) finish(FolderSendOutcome.FilesOff)
    }

    fun receivedCancel(payload: FolderCancelPayload) {
        if (payload.folderTransferId != id) return
        link.sendOuter(FolderKinds.CANCEL_ACK, id)
        if (phase == Phase.FINISHED) return
        if (phase == Phase.CANCELLING) return finish(pendingOutcome ?: FolderSendOutcome.CancelledHere)
        stopCurrentFile(sendCancel = false)
        finish(FolderSendOutcome.CancelledByPeer(payload.code))
    }

    fun receivedCancelAck() {
        if (phase == Phase.CANCELLING) finish(pendingOutcome ?: FolderSendOutcome.CancelledHere)
    }

    fun receivedEntryFailed(payload: FolderEntryFailedPayload) {
        if (payload.folderTransferId != id || (phase != Phase.SENDING && phase != Phase.COMPLETING)) return
        if (payload.entry !in plan.entries.indices) return
        if (current?.entry == payload.entry) stopCurrentFile(sendCancel = false)
        flights.entries.firstOrNull { it.value.entry == payload.entry }?.key?.let(flights::remove)
        pending.remove(payload.entry)
        recordFailure(payload.entry, payload.code, senderSide = false)
        lastAckProgress = clock()
        events.progress(this)
        pump()
    }

    fun receivedResult(payload: FolderResultPayload) {
        if (payload.folderTransferId != id || phase != Phase.COMPLETING) return
        result = payload
        finish(FolderSendOutcome.Done(payload))
    }

    // Files inside the folder.

    fun chunkAcknowledged(transferId: String, sequence: Long) {
        val flight = flights[transferId] ?: return
        if (sequence <= flight.acked) return
        flight.acked = minOf(sequence, flight.chunksSent - 1)
        lastAckProgress = clock()
        events.progress(this)
        pump()
    }

    fun completeAcknowledged(transferId: String) {
        val flight = flights[transferId]?.takeIf { it.completeSent } ?: return
        flights.remove(transferId)
        completed += flight.entry
        filesDone++
        completedBytes += flight.size
        recent.addLast(FolderPaths.leaf(plan.entries[flight.entry].path))
        while (recent.size > RECENT_LIMIT) recent.removeFirst()
        lastAckProgress = clock()
        events.entriesCompleted(this, completed.toSet())
        events.progress(this)
        pump()
    }

    /** files.accept: tolerated, the sender does not wait for it inside a folder. */
    fun fileAccepted(transferId: String) = Unit

    fun fileCancelledByPeer(transferId: String) {
        link.sendOuter("files.cancel.ack", transferId)
        val flight = flights[transferId] ?: return
        if (current?.transferId == transferId) stopCurrentFile(sendCancel = false)
        flights.remove(transferId)
        recordFailure(flight.entry, FolderCodes.CANCELLED, senderSide = false)
        events.progress(this)
        pump()
    }

    // Cancel and interruption.

    fun cancel(reason: String = CancelReasons.USER, code: String? = null, outcome: FolderSendOutcome = FolderSendOutcome.CancelledHere) {
        if (phase == Phase.FINISHED || phase == Phase.CANCELLING) return
        stopCurrentFile(sendCancel = false)
        cancelTimers()
        pending.clear()
        cancelReason = reason
        cancelCode = code
        pendingOutcome = outcome
        cancelAttemptsLeft = CANCEL_ATTEMPTS
        phase = Phase.CANCELLING
        sendCancelAttempt()
        events.progress(this)
    }

    fun interrupt() {
        if (phase == Phase.FINISHED) return
        stopCurrentFile(sendCancel = false)
        finish(FolderSendOutcome.Interrupted)
    }

    // Internals.

    private fun timer(delayMillis: Long, action: () -> Unit): Cancellable {
        val generation = timerGeneration
        return scheduler.schedule(delayMillis) { post { if (generation == timerGeneration && phase != Phase.FINISHED) action() } }
    }

    private fun cancelTimers() {
        timerGeneration++
        waitTimer?.cancel()
        watchdog?.cancel()
        waitTimer = null
        watchdog = null
    }

    private fun armWait(delayMillis: Long) {
        waitTimer?.cancel()
        waitTimer = timer(delayMillis) {
            if (beforeAccept) cancel(CancelReasons.TIMEOUT, FolderCodes.TIMEOUT, FolderSendOutcome.NoAnswer)
        }
    }

    private fun sendCancelAttempt() {
        if (phase != Phase.CANCELLING) return
        if (cancelAttemptsLeft <= 0) return finish(pendingOutcome ?: FolderSendOutcome.CancelledHere)
        cancelAttemptsLeft--
        link.send(FolderKinds.CANCEL, FolderCancelPayload(id, cancelReason, cancelCode).toJson(), outerTransferId = id)
        waitTimer?.cancel()
        waitTimer = timer(CANCEL_RETRY_MILLIS) { sendCancelAttempt() }
    }

    private val unackedChunks: Long get() = flights.values.sumOf { it.unacked }

    private fun pump() {
        if (phase != Phase.SENDING) return
        var budget = CHUNK_WINDOW * 2
        while (phase == Phase.SENDING && budget > 0) {
            budget--
            val file = current
            if (file == null) {
                val next = pending.firstOrNull() ?: break
                if (flights.size >= FILES_AWAITING_COMPLETION) break
                pending.removeFirst()
                startFile(next)
                continue
            }
            if (file.sent < file.size) {
                if (unackedChunks >= CHUNK_WINDOW) break
                sendChunk(file)
            } else {
                finishFile(file)
            }
        }
        if (phase == Phase.SENDING && current == null && pending.isEmpty() && flights.isEmpty()) {
            sendComplete()
        } else if (phase == Phase.SENDING && budget == 0) {
            // Give acknowledgements a turn on the worker, then carry on.
            post { pump() }
        }
    }

    private fun startFile(index: Int) {
        val entry = plan.entries[index]
        val sha = entry.sha256 ?: return
        val input = try {
            plan.open(index)
        } catch (_: IOException) {
            return recordFailure(index, FolderCodes.UNREADABLE, senderSide = true)
        } catch (_: SecurityException) {
            return recordFailure(index, FolderCodes.UNREADABLE, senderSide = true)
        }
        val transferId = makeId()
        ownedIds += transferId
        val name = FolderPaths.leaf(entry.path)
        val offer = JSONObject().put("transferId", transferId).put("name", name).put("mimeType", mimeType(name)).put("size", entry.size)
            .put("sha256", sha).put("folderTransferId", id).put("entry", index).put("path", entry.path)
        link.send("files.offer", offer, outerTransferId = transferId)
        current = CurrentFile(index, transferId, entry.size, input)
        flights[transferId] = Flight(index, entry.size)
    }

    private val buffer = ByteArray(CHUNK_SIZE.toInt())

    private fun sendChunk(file: CurrentFile) {
        val wanted = minOf(CHUNK_SIZE, file.size - file.sent).toInt()
        var count = 0
        try {
            while (count < wanted) {
                val read = file.input.read(buffer, count, wanted - count)
                if (read < 0) break
                count += read
            }
        } catch (_: IOException) {
            return abandonCurrentFile(FolderCodes.UNREADABLE)
        }
        if (count == 0) return abandonCurrentFile(FolderCodes.SOURCE_CHANGED)
        val data = buffer.copyOf(count)
        file.digest.update(data)
        link.sendChunk(file.transferId, file.sequence, data)
        file.sequence++
        file.sent += count
        flights[file.transferId]?.chunksSent = file.sequence
        events.progress(this)
    }

    private fun finishFile(file: CurrentFile) {
        val extra = runCatching { file.input.read() }.getOrDefault(-1)
        runCatching { file.input.close() }
        val digest = java.util.Base64.getEncoder().encodeToString(file.digest.digest())
        current = null
        if (extra >= 0 || digest != plan.entries[file.entry].sha256) {
            // Changed since the manifest: the receiver drops what it has of it.
            link.sendOuter("files.cancel", file.transferId)
            flights.remove(file.transferId)
            recordFailure(file.entry, FolderCodes.SOURCE_CHANGED, senderSide = true)
            events.progress(this)
            return
        }
        link.send("files.complete", JSONObject().put("transferId", file.transferId).put("sha256", digest), outerTransferId = file.transferId)
        flights[file.transferId]?.completeSent = true
        sentFiles++
    }

    private fun abandonCurrentFile(code: String) {
        val file = current ?: return
        runCatching { file.input.close() }
        current = null
        link.sendOuter("files.cancel", file.transferId)
        flights.remove(file.transferId)
        recordFailure(file.entry, code, senderSide = true)
        events.progress(this)
    }

    private fun stopCurrentFile(sendCancel: Boolean) {
        val file = current ?: return
        runCatching { file.input.close() }
        current = null
        if (sendCancel) link.sendOuter("files.cancel", file.transferId)
    }

    private fun recordFailure(entry: Int, code: String, senderSide: Boolean) {
        failedCount++
        if (failures.size < FolderLimits.MAX_REPORTED_FAILURES) failures += FolderFailure(entry, FolderPaths.leaf(plan.entries[entry].path), code)
        if (senderSide) {
            senderFailureCount++
            if (senderFailures.size < FolderLimits.MAX_REPORTED_FAILURES) senderFailures += FailedEntry(entry, code)
        }
        log("entry failed code=$code failures=$failedCount")
    }

    private fun sendComplete() {
        link.send(FolderKinds.COMPLETE, FolderCompletePayload(id, sentFiles, senderFailureCount, senderFailures).toJson())
        cancelTimers()
        phase = Phase.COMPLETING
        waitTimer = timer(FolderTimeouts.RESULT_MILLIS) { if (phase == Phase.COMPLETING) finish(FolderSendOutcome.Unconfirmed) }
        events.progress(this)
    }

    private fun armWatchdog() {
        watchdog?.cancel()
        watchdog = timer(WATCHDOG_MILLIS) {
            if (phase != Phase.SENDING) return@timer
            val limit = if (unackedChunks > 0) CHUNK_ACK_TIMEOUT_MILLIS else COMPLETE_ACK_TIMEOUT_MILLIS
            if (flights.isNotEmpty() && clock() - lastAckProgress >= limit) {
                log("stalled")
                interrupt()
                return@timer
            }
            armWatchdog()
        }
    }

    private fun refreshCompletedCounts() {
        val doneFiles = completed.filter { it in plan.entries.indices && !plan.entries[it].isDirectory }
        filesDone = doneFiles.size
        completedBytes = doneFiles.sumOf { plan.entries[it].size }
    }

    private fun finish(outcome: FolderSendOutcome) {
        if (phase == Phase.FINISHED) return
        phase = Phase.FINISHED
        cancelTimers()
        current?.let { runCatching { it.input.close() } }
        current = null
        log("finished outcome=${outcome.javaClass.simpleName}")
        events.finished(this, outcome)
    }

    companion object {
        const val CHUNK_SIZE = 24L * 1024
        const val CHUNK_WINDOW = 64
        const val FILES_AWAITING_COMPLETION = 32
        const val RECENT_LIMIT = 200
        const val CHUNK_ACK_TIMEOUT_MILLIS = 10_000L
        const val COMPLETE_ACK_TIMEOUT_MILLIS = 60_000L
        const val WATCHDOG_MILLIS = 1_000L
        const val CANCEL_RETRY_MILLIS = 5_000L
        const val CANCEL_ATTEMPTS = 3

        fun mimeType(name: String): String {
            val extension = name.substringAfterLast('.', "").lowercase()
            if (extension.isEmpty()) return "application/octet-stream"
            return runCatching { android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) }.getOrNull()
                ?: "application/octet-stream"
        }
    }
}
