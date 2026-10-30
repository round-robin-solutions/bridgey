package dev.bridgey.android.folders

import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.json.JSONObject

/** What the app hears about folders this phone sends. Called on worker threads. */
interface FolderSenderListener {
    fun snapshot(snapshot: FolderSnapshot) = Unit
    fun finished(snapshot: FolderSnapshot) = Unit

    /** A one-off "Browse…" tree grant is no longer needed. */
    fun releaseTree(treeUri: String) = Unit
}

/** places.download_started: what the phone is about to send. */
class DownloadTicket(val folderTransferId: String, val rootName: String, val fileCount: Int, val folderCount: Int, val totalSize: Long)

/** Thrown by [FolderSender.download] with a places.error code. */
class DownloadRefused(val code: String) : Exception(code)

/**
 * Folders sent from this phone (phone to Mac, Files 2.0): scanning and hashing in the background, one active
 * folder per device with the rest queued in order, the sessions, the sender journal, automatic resume when the
 * device comes back within 24 hours (also after an app restart), cancel, and one row per folder. Downloads the
 * Mac asked for (places.download) are the same, sent `into` its folder. Android-free, so it runs on the JVM.
 */
class FolderSender(
    private val journals: FolderSendJournals?,
    private val listener: FolderSenderListener,
    /** The device's link while it is connected and accepts folders (folders_receive_draft1), else null. */
    private val linkFor: (deviceId: String) -> FolderSendLink?,
    private val newWorker: (folderTransferId: String) -> FolderWorker,
    private val scheduler: FolderScheduler,
    /** Runs scanning and hashing off the socket and main threads. */
    private val prepare: (() -> Unit) -> Unit,
    /** Opens a journaled content URI after a restart. */
    private val openUri: (String) -> InputStream,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
    private val makeId: () -> String = { UUID.randomUUID().toString() },
    /** Settings > Files > Include hidden files and Include system files, read when a folder or download is scanned. */
    private val scanOptions: () -> FolderScanOptions = { FolderScanOptions() },
) {
    private enum class State { PREPARING, QUEUED, ACTIVE, INTERRUPTED, DONE }

    private inner class Item(
        val id: String,
        val deviceId: String,
        var deviceName: String,
        var rootName: String,
        val download: Boolean,
        val downloadRequestId: String?,
        val releaseTree: String?,
        val queuedAt: Long,
    ) {
        var state = State.PREPARING
        var plan: FolderSendPlan? = null
        var sources: List<String?> = emptyList()
        var completed: Set<Int> = emptySet()
        var journaled = false
        var everAccepted = false
        var session: FolderSendSession? = null
        var worker: FolderWorker? = null
        var filesTotal = 0
        var bytesTotal = 0L
        var skipped = SkippedCounts()
        var lastProgressAt = clock()
        var lastEmitAt = 0L
        var speedAt = 0L
        var speedBytes = 0L
        var bytesPerSecond = 0L
        var cancelled = false
        var interruptedAt = 0L
    }

    private val items = LinkedHashMap<String, Item>()
    private val fileOwners = ConcurrentHashMap<String, String>()

    fun owns(folderTransferId: String?): Boolean = folderTransferId != null && synchronized(this) { items.containsKey(folderTransferId) }

    fun ownsFile(transferId: String?): Boolean = transferId != null && fileOwners.containsKey(transferId)

    /** Whether a folder of this device is being sent or waits to resume (Files off mid-way still finishes it). */
    fun activeFor(deviceId: String): Boolean = synchronized(this) { items.values.any { it.deviceId == deviceId && it.state == State.ACTIVE } }

    // Starting.

    /** Sends the folder [root] to [deviceId]. Returns the folder transfer ID (the row's ID). */
    fun send(deviceId: String, deviceName: String, root: SendNode, releaseTree: String? = null): String {
        val item = synchronized(this) {
            Item(makeId(), deviceId, deviceName, PortableName.convert(root.name) ?: root.name, download = false, downloadRequestId = null,
                releaseTree = releaseTree, queuedAt = clock()).also { items[it.id] = it }
        }
        emit(item, force = true)
        prepare {
            val scan = FolderScanner.scanFolder(root, scanOptions(), cancelled = { item.cancelled })
            prepared(item, scan)
        }
        return item.id
    }

    /**
     * A download the device asked for: scanned now (for places.download_started), hashed in the background,
     * then sent `into` the folder the device chose. Throws [DownloadRefused] with a places.error code.
     */
    fun download(deviceId: String, deviceName: String, requestId: String, roots: List<SendNode>): DownloadTicket {
        val scan = FolderScanner.scanItems(roots, scanOptions())
        scan.problem?.let { throw DownloadRefused(if (it == FolderCodes.UNREADABLE) FolderCodes.PLACE_UNAVAILABLE else it) }
        val item = synchronized(this) {
            Item(makeId(), deviceId, deviceName, scan.rootName, download = true, downloadRequestId = requestId, releaseTree = null, queuedAt = clock())
                .also { items[it.id] = it }
        }
        item.filesTotal = scan.fileCount
        item.bytesTotal = scan.totalSize
        item.skipped = scan.skipped
        emit(item, force = true)
        prepare { prepared(item, scan) }
        return DownloadTicket(item.id, scan.rootName, scan.fileCount, scan.folderCount, scan.totalSize)
    }

    private fun prepared(item: Item, scan: FolderScanResult) {
        if (item.cancelled) return end(item, FolderEnd.CANCELLED, FolderCodes.CANCELLED, here = true)
        scan.problem?.let { return end(item, FolderEnd.CANCELLED, it, here = false) }
        item.filesTotal = scan.fileCount
        item.bytesTotal = scan.totalSize
        item.skipped = scan.skipped
        emit(item, force = true)
        val hashStarted = clock()
        val hashed = FolderHashing.hash(scan, cancelled = { item.cancelled }) ?: return end(item, FolderEnd.CANCELLED, FolderCodes.CANCELLED, here = true)
        log("FOLDER ${item.id.take(8)} hashed bytes=${scan.totalSize} ms=${clock() - hashStarted}")
        val nodes = hashed.nodes
        val plan = FolderSendPlan(item.id, hashed.rootName, hashed.entries, { index -> nodes[index].open() }, hashed.skipped,
            hashed.into, item.downloadRequestId, resume = false)
        if (plan.pages.isEmpty() && plan.entries.isNotEmpty()) return end(item, FolderEnd.CANCELLED, FolderCodes.LIMIT_EXCEEDED, here = false)
        synchronized(this) {
            item.plan = plan
            item.sources = nodes.map { it.source }
            item.filesTotal = plan.fileCount
            item.bytesTotal = plan.totalSize
            item.skipped = plan.skipped
            if (item.state == State.PREPARING) item.state = State.QUEUED
        }
        log("FOLDER ${item.id.take(8)} prepared files=${plan.fileCount} folders=${plan.folderCount}")
        emit(item, force = true)
        startNext(item.deviceId)
    }

    /** The device connected (or its feature state arrived): resume or start what waits for it. */
    fun deviceReady(deviceId: String) {
        expire()
        startNext(deviceId)
    }

    private fun startNext(deviceId: String) {
        val item = synchronized(this) {
            if (items.values.any { it.deviceId == deviceId && it.state == State.ACTIVE }) return
            // Interrupted folders first (they resume), then the queue in order.
            items.values.filter { it.deviceId == deviceId && (it.state == State.INTERRUPTED || it.state == State.QUEUED) && it.plan != null }
                .minWithOrNull(compareBy<Item>({ if (it.state == State.INTERRUPTED) 0 else 1 }, { it.queuedAt })) ?: return
        }
        val link = linkFor(deviceId) ?: return
        startSession(item, link)
    }

    private fun startSession(item: Item, link: FolderSendLink) {
        val worker = newWorker(item.id)
        val session: FolderSendSession
        synchronized(this) {
            val base = item.plan ?: return
            val resume = item.state == State.INTERRUPTED && item.journaled
            val plan = if (resume) base.resumed() else base
            session = FolderSendSession(
                plan = plan,
                alreadyCompleted = if (resume) item.completed else emptySet(),
                link = link,
                scheduler = scheduler,
                post = worker::postControl,
                events = Events(item),
                clock = clock,
                makeId = { makeId().also { fileOwners[it] = item.id } },
                log = { log("FOLDER ${item.id.take(8)} $it") },
            )
            item.session = session
            item.worker = worker
            item.state = State.ACTIVE
        }
        worker.postControl { session.start() }
    }

    private inner class Events(private val item: Item) : FolderSendEvents {
        override fun progress(session: FolderSendSession) {
            item.lastProgressAt = clock()
            emit(item)
        }

        override fun accepted(session: FolderSendSession, accept: FolderAcceptPayload) {
            item.everAccepted = true
            val journals = journals ?: return
            if (item.journaled) return
            val plan = item.plan ?: return
            runCatching {
                journals.create(
                    FolderSendJournals.Header(item.id, item.deviceId, item.deviceName, plan.rootName, plan.into, plan.downloadRequestId, plan.skipped,
                        clock(), item.releaseTree),
                    plan.entries, item.sources,
                )
                item.journaled = true
            }
        }

        override fun entriesCompleted(session: FolderSendSession, completed: Set<Int>) {
            val fresh = completed - item.completed
            item.completed = completed
            if (item.journaled) runCatching { journals?.markDone(item.id, fresh) }
        }

        override fun finished(session: FolderSendSession, outcome: FolderSendOutcome) {
            item.worker?.shutdown()
            val accepted = session.accepted || item.everAccepted
            when (outcome) {
                FolderSendOutcome.Interrupted -> synchronized(this@FolderSender) {
                    item.state = State.INTERRUPTED
                    item.interruptedAt = clock()
                    item.session = session
                    emit(item, force = true, end = FolderEnd.INTERRUPTED, resumable = true)
                }
                is FolderSendOutcome.Done -> end(item, if (outcome.result.complete) FolderEnd.COMPLETE else FolderEnd.INCOMPLETE, null, here = false)
                FolderSendOutcome.Unconfirmed -> end(item, FolderEnd.INCOMPLETE, FolderCodes.TIMEOUT, here = false)
                is FolderSendOutcome.Rejected -> end(item, FolderEnd.CANCELLED, outcome.code, here = false)
                FolderSendOutcome.FilesOff -> end(item, FolderEnd.CANCELLED, FolderCodes.POLICY, here = false)
                FolderSendOutcome.CancelledHere -> end(item, if (accepted) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, FolderCodes.CANCELLED, here = true)
                is FolderSendOutcome.CancelledByPeer ->
                    end(item, if (accepted) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, outcome.code ?: FolderCodes.CANCELLED, here = false)
                FolderSendOutcome.NoAnswer -> end(item, FolderEnd.TIMED_OUT, FolderCodes.TIMEOUT, here = false)
            }
            if (outcome != FolderSendOutcome.Interrupted) startNext(item.deviceId)
        }
    }

    // Routing (messages from the device this folder goes to).

    /** folders.* with a folderTransferId this phone sends. True when handled. */
    fun handle(deviceId: String, kind: String, json: JSONObject): Boolean {
        val id = json.optString("folderTransferId")
        val item = synchronized(this) { items[id]?.takeIf { it.deviceId == deviceId } } ?: return false
        val session = item.session ?: return true
        val worker = item.worker ?: return true
        when (kind) {
            FolderKinds.WAITING -> FolderWaitingPayload.parse(json)?.let { worker.postControl { session.receivedWaiting(it) } }
            FolderKinds.CONFLICT -> worker.postControl { session.receivedConflict(json) }
            FolderKinds.ACCEPT -> parseFolderAccept(json)?.let { worker.postControl { session.receivedAccept(it) } }
            FolderKinds.REJECTED -> FolderRejectedPayload.parse(json)?.let { payload ->
                if (payload.code == FolderCodes.RESUME_UNAVAILABLE) dropJournal(item)
                worker.postControl { session.receivedRejected(payload) }
            }
            FolderKinds.ENTRY_FAILED -> FolderEntryFailedPayload.parse(json)?.let { worker.postControl { session.receivedEntryFailed(it) } }
            FolderKinds.RESULT -> parseFolderResult(json)?.let { worker.postControl { session.receivedResult(it) } }
            FolderKinds.CANCEL -> FolderCancelPayload.parse(json)?.let { worker.postControl { session.receivedCancel(it) } }
            else -> return false
        }
        return true
    }

    /**
     * Outer-only messages: files.accept, files.chunk.ack, files.complete.ack, files.cancel, files.rejected for the
     * per-file transfers of a folder; folders.rejected (Files off) and folders.cancel.ack for the folder itself.
     */
    fun handleOuter(deviceId: String, kind: String, transferId: String, sequence: Long?): Boolean {
        synchronized(this) { items[transferId]?.takeIf { it.deviceId == deviceId } }?.let { item ->
            val session = item.session ?: return true
            val worker = item.worker ?: return true
            when (kind) {
                FolderKinds.REJECTED -> worker.postControl { session.receivedPolicyRejection() }
                FolderKinds.CANCEL_ACK -> worker.postControl { session.receivedCancelAck() }
                else -> return false
            }
            return true
        }
        val owner = fileOwners[transferId] ?: return false
        val item = synchronized(this) { items[owner]?.takeIf { it.deviceId == deviceId } } ?: return true
        val session = item.session ?: return true
        val worker = item.worker ?: return true
        when (kind) {
            "files.accept" -> Unit
            "files.chunk.ack" -> sequence?.let { worker.postControl { session.chunkAcknowledged(transferId, it) } }
            "files.complete.ack" -> worker.postControl { session.completeAcknowledged(transferId) }
            "files.cancel" -> worker.postControl { session.fileCancelledByPeer(transferId) }
            "files.rejected" -> worker.postControl { session.receivedPolicyRejection() }
            "files.cancel.ack" -> Unit
            else -> return false
        }
        return true
    }

    // Ending, cancel, disconnects.

    /** The device disconnected: its active folder stops where it is and resumes when it comes back. */
    fun deviceGone(deviceId: String?) {
        val active = synchronized(this) { items.values.filter { (deviceId == null || it.deviceId == deviceId) && it.state == State.ACTIVE } }
        active.forEach { item ->
            val session = item.session ?: return@forEach
            item.worker?.postControl { session.interrupt() }
        }
    }

    /** Cancel from the row. True when it was a folder sent from here. */
    fun cancel(id: String): Boolean {
        val item = synchronized(this) { items[id] } ?: return false
        item.cancelled = true
        when (item.state) {
            State.ACTIVE -> {
                val session = item.session
                val worker = item.worker
                if (session != null && worker != null) worker.postControl { session.cancel() } else end(item, FolderEnd.CANCELLED, FolderCodes.CANCELLED, here = true)
            }
            State.PREPARING -> Unit
            State.QUEUED -> end(item, FolderEnd.CANCELLED, FolderCodes.CANCELLED, here = true)
            State.INTERRUPTED -> end(item, if (item.everAccepted) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, FolderCodes.CANCELLED, here = true)
            State.DONE -> Unit
        }
        return true
    }

    /** Forget device: its folders stop and their journals go. */
    fun forget(deviceId: String) {
        val mine = synchronized(this) { items.values.filter { it.deviceId == deviceId }.toList() }
        mine.forEach { item ->
            item.cancelled = true
            item.worker?.shutdown()
            synchronized(this) { items.remove(item.id) }
            item.releaseTree?.let(listener::releaseTree)
        }
        journals?.deleteForPeer(deviceId)?.forEach { record -> record.header.releaseTree?.let(listener::releaseTree) }
    }

    /** On start: journaled folders come back as interrupted rows and resume when their device connects. */
    fun loadJournals() {
        val records = journals?.prune().orEmpty()
        records.forEach { record ->
            val header = record.header
            synchronized(this) {
                if (items.containsKey(header.folderTransferId)) return@forEach
                val item = Item(header.folderTransferId, header.peerId, header.peerName, header.rootName, header.downloadRequestId != null,
                    header.downloadRequestId, header.releaseTree, record.lastProgressMillis)
                val sources = record.sources
                item.plan = FolderSendPlan(header.folderTransferId, header.rootName, record.entries, { index ->
                    val uri = sources.getOrNull(index) ?: throw IOException("no source")
                    openUri(uri)
                }, header.skipped, header.into, header.downloadRequestId, resume = false)
                item.sources = sources
                item.completed = record.done
                item.journaled = true
                item.everAccepted = true
                item.state = State.INTERRUPTED
                item.interruptedAt = record.lastProgressMillis
                item.filesTotal = item.plan!!.fileCount
                item.bytesTotal = item.plan!!.totalSize
                item.skipped = header.skipped
                items[item.id] = item
            }
        }
        synchronized(this) { items.values.filter { it.state == State.INTERRUPTED }.toList() }.forEach { emit(it, force = true, end = FolderEnd.INTERRUPTED, resumable = true) }
    }

    /** Interrupted folders whose 24 hours ran out stay incomplete; their journals go. */
    private fun expire() {
        val stale = synchronized(this) {
            items.values.filter { it.state == State.INTERRUPTED && !FolderTimeouts.canResume(maxOf(it.interruptedAt, it.lastProgressAt), clock()) }.toList()
        }
        stale.forEach { end(it, if (it.everAccepted) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, FolderCodes.RESUME_UNAVAILABLE, here = false) }
    }

    private fun dropJournal(item: Item) {
        journals?.delete(item.id)
        item.journaled = false
    }

    private fun end(item: Item, end: FolderEnd, code: String?, here: Boolean) {
        synchronized(this) {
            if (item.state == State.DONE) return
            item.state = State.DONE
            items.remove(item.id)
        }
        item.worker?.shutdown()
        dropJournal(item)
        item.releaseTree?.let(listener::releaseTree)
        val snapshot = snapshot(item, end, code, here, resumable = false)
        listener.snapshot(snapshot)
        listener.finished(snapshot)
    }

    private fun emit(item: Item, force: Boolean = false, end: FolderEnd? = null, resumable: Boolean = false) {
        val now = clock()
        if (!force && end == null && now - item.lastEmitAt < EMIT_INTERVAL_MILLIS) return
        item.lastEmitAt = now
        listener.snapshot(snapshot(item, end, null, false, resumable))
    }

    private fun snapshot(item: Item, end: FolderEnd?, code: String?, here: Boolean, resumable: Boolean): FolderSnapshot {
        val session = item.session
        val now = clock()
        val bytesDone = session?.bytesDone ?: 0L
        if (item.speedAt == 0L || session == null) {
            item.speedAt = now
            item.speedBytes = bytesDone
        } else if (now - item.speedAt >= 500) {
            val sample = (bytesDone - item.speedBytes).coerceAtLeast(0) * 1000 / (now - item.speedAt)
            item.bytesPerSecond = dev.bridgey.android.smoothedRate(item.bytesPerSecond.toDouble(), sample.toDouble(), (now - item.speedAt) / 1000.0).toLong()
            item.speedAt = now
            item.speedBytes = bytesDone
        }
        val waiting = when {
            end != null -> null
            item.state == State.PREPARING || item.state == State.QUEUED -> FolderWaiting.MANIFEST
            session?.phase == FolderSendSession.Phase.WAITING -> if (session.waitingReason == WaitingReasons.CONFLICT) FolderWaiting.CONFLICT_ON_SENDER else FolderWaiting.DESTINATION
            else -> null
        }
        return FolderSnapshot(
            folderTransferId = item.id,
            deviceId = item.deviceId,
            deviceName = item.deviceName,
            rootName = session?.acceptedRootName?.takeIf { !item.download } ?: item.rootName,
            filesTotal = item.filesTotal,
            bytesTotal = item.bytesTotal,
            filesDone = session?.filesDone ?: item.completed.count { item.plan?.entries?.getOrNull(it)?.isDirectory == false },
            bytesDone = bytesDone,
            destinationLabel = session?.destinationLabel,
            waiting = waiting,
            deadlineMillis = session?.waitingDeadline.takeIf { waiting == FolderWaiting.DESTINATION || waiting == FolderWaiting.CONFLICT_ON_SENDER },
            currentFile = session?.currentFile.takeIf { end == null },
            currentFileBytes = session?.currentFileBytes ?: 0,
            currentFileSize = session?.currentFileSize ?: 0,
            failures = session?.failures?.takeLast(50).orEmpty(),
            failedCount = session?.failedCount ?: 0,
            recent = session?.recent?.toList().orEmpty(),
            skipped = item.skipped,
            bytesPerSecond = if (end == null) item.bytesPerSecond else 0,
            end = end,
            endCode = code,
            endedHere = here,
            resumable = resumable,
            outgoing = true,
            download = item.download,
        )
    }

    private companion object {
        const val EMIT_INTERVAL_MILLIS = 250L
    }
}
