package dev.bridgey.android.folders

import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import org.json.JSONObject

/** Timers on a fake clock: [advance] runs what falls due, in order. */
class FakeScheduler(private val clock: FakeClock) : FolderScheduler {
    private data class Task(val due: Long, val order: Int, val run: () -> Unit)
    private val tasks = ArrayList<Task>()
    private var order = 0

    override fun schedule(delayMillis: Long, task: () -> Unit): Cancellable {
        val entry = Task(clock.now + delayMillis, order++, task)
        tasks += entry
        return Cancellable { tasks.remove(entry) }
    }

    fun advance(millis: Long) {
        val target = clock.now + millis
        while (true) {
            val next = tasks.filter { it.due <= target }.minWithOrNull(compareBy({ it.due }, { it.order })) ?: break
            tasks.remove(next)
            clock.now = next.due
            next.run()
        }
        clock.now = target
    }

    val pending: Int get() = tasks.size
}

class FakeClock(var now: Long = 1_800_000_000_000L) {
    fun read(): Long = now
}

/** Everything the session sent, in order. */
class RecordingLink : FolderLink {
    data class Sent(val kind: String, val payload: JSONObject?, val outer: String?, val sequence: Long?)

    val sent = ArrayList<Sent>()

    override fun send(kind: String, payload: JSONObject, outerTransferId: String?) {
        sent += Sent(kind, JSONObject(payload.toString()), outerTransferId, null)
    }

    override fun sendOuter(kind: String, transferId: String, sequence: Long?) {
        sent += Sent(kind, null, transferId, sequence)
    }

    fun kinds(): List<String> = sent.map { it.kind }
    fun last(kind: String): JSONObject? = sent.lastOrNull { it.kind == kind }?.payload
    fun count(kind: String): Int = sent.count { it.kind == kind }
}

class MemoryPlaces : PlaceDirectory {
    class Entry(val placeId: String, var label: String, val store: MemoryTreeStore, var available: Boolean = true)

    val entries = ArrayList<Entry>()
    val oneOffs = HashMap<String, MemoryTreeStore>()

    override fun places(): List<PlaceRef> = entries.map { entry ->
        PlaceRef(entry.placeId, entry.label, entry.available, { if (!entry.available) throw PlaceUnavailableException() else entry.store })
    }

    override fun oneOff(treeUri: String): PlaceRef? = oneOffs[treeUri]?.let { store -> PlaceRef("-", "Other", true, { store }, oneOffTree = treeUri) }
}

fun sha(bytes: ByteArray): String = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(bytes))

/** A folder on the "Mac": paths to contents (null for a folder), turned into a manifest in protocol order. */
class TestFolder(val rootName: String, files: Map<String, ByteArray>, dirs: List<String> = emptyList()) {
    val contents: Map<String, ByteArray> = files
    val entries: List<ManifestEntry>

    init {
        val allDirs = LinkedHashSet<String>()
        (files.keys + dirs).forEach { path ->
            var parent = if (path in dirs) path else FolderPaths.parent(path)
            while (parent.isNotEmpty()) {
                allDirs += parent
                parent = FolderPaths.parent(parent)
            }
        }
        val list = allDirs.map { ManifestEntry(ManifestEntry.Type.DIR, it) } +
            files.map { (path, content) -> ManifestEntry(ManifestEntry.Type.FILE, path, content.size.toLong(), sha(content)) }
        entries = list.sortedWith { a, b -> FolderPaths.manifestOrder.compare(a.path, b.path) }
    }

    fun index(path: String): Int = entries.indexOfFirst { it.path == path }

    fun offer(id: String, destination: FolderDestination? = null, resume: Boolean = false, skipped: SkippedCounts = SkippedCounts()): FolderOfferPayload {
        val pages = (entries.size + 255) / 256
        return FolderOfferPayload(
            id, rootName, entries.count { !it.isDirectory }, entries.count { it.isDirectory }, entries.filter { !it.isDirectory }.sumOf { it.size },
            pages, ManifestDigest.compute(rootName, entries), destination, resume, skipped,
        )
    }

    fun pages(id: String): List<ManifestPagePayload> = entries.chunked(256).mapIndexed { index, chunk -> ManifestPagePayload(id, index, chunk) }
}

/** One phone with a default place and a "Pictures" place, a fake clock and a journal directory. */
class Phone(
    journalDir: File,
    var settings: FolderReceiveSettings = FolderReceiveSettings(),
) {
    val clock = FakeClock()
    val scheduler = FakeScheduler(clock)
    val places = MemoryPlaces()
    val downloads = MemoryTreeStore(supportsCreateFolder = false)
    val pictures = MemoryTreeStore()
    val journals = FolderJournals(journalDir, clock::read)
    val questions = ArrayList<FolderQuestion?>()
    val snapshots = ArrayList<FolderSnapshot>()
    var finished: FolderSnapshot? = null
    val released = ArrayList<String>()
    val lostAccess = ArrayList<String>()
    val used = ArrayList<FolderDestination>()

    init {
        places.entries += MemoryPlaces.Entry(DEFAULT_PLACE_ID, "Download/Bridgey", downloads)
        places.entries += MemoryPlaces.Entry(PICTURES, "Pictures", pictures)
    }

    val listener = object : FolderSessionListener {
        override fun snapshot(snapshot: FolderSnapshot) {
            snapshots += snapshot
        }

        override fun question(question: FolderQuestion?) {
            questions += question
        }

        override fun finished(snapshot: FolderSnapshot) {
            finished = snapshot
        }

        override fun usedDestination(destination: FolderDestination) {
            used += destination
        }

        override fun releaseOneOff(treeUri: String) {
            released += treeUri
        }

        override fun lostAccess(placeLabel: String) {
            lostAccess += placeLabel
        }
    }

    fun session(folder: TestFolder, link: RecordingLink, id: String = UUID.randomUUID().toString(), destination: FolderDestination? = null, resume: Boolean = false, peer: String = "mac-1"): FolderReceiveSession {
        finished = null
        val env = FolderEnvironment(places, { settings }, journals, InlineFolderWorker(), scheduler, clock::read)
        return FolderReceiveSession(folder.offer(id, destination, resume), peer, "MacBook Pro", env, link, listener)
    }

    /** Offer plus every manifest page. */
    fun deliver(folder: TestFolder, link: RecordingLink, destination: FolderDestination? = null, id: String = UUID.randomUUID().toString(), resume: Boolean = false, peer: String = "mac-1"): FolderReceiveSession {
        val session = session(folder, link, id, destination, resume, peer)
        session.start()
        folder.pages(session.id).forEach { session.manifestPage(it, it.toJson().toString().length) }
        return session
    }

    val lastQuestion: FolderQuestion? get() = questions.lastOrNull()

    companion object {
        const val PICTURES = "q3Jx0bVv1eG7tq8Wm2l5wA"
    }
}

/** Sends one file of [folder] the way the Mac does: offer, chunks, complete. Returns its transfer ID. */
fun FolderReceiveSession.sendFile(
    folder: TestFolder,
    path: String,
    transferId: String = UUID.randomUUID().toString(),
    chunkSize: Int = 24 * 1024,
    complete: Boolean = true,
    corrupt: Boolean = false,
    chunks: Int = Int.MAX_VALUE,
): String {
    val index = folder.index(path)
    val content = folder.contents.getValue(path)
    claim(transferId)
    fileOffer(transferId, FolderFileFields(id, index, path), FolderPaths.leaf(path), content.size.toLong(), sha(content))
    val data = if (corrupt) content.copyOf().also { if (it.isNotEmpty()) it[0] = (it[0] + 1).toByte() } else content
    data.toList().chunked(chunkSize).take(chunks).forEachIndexed { sequence, part -> chunk(transferId, sequence.toLong(), part.toByteArray()) }
    if (complete) fileComplete(transferId, sha(content))
    return transferId
}

fun FolderReceiveSession.sendAll(folder: TestFolder, except: Set<String> = emptySet()) {
    folder.entries.filter { !it.isDirectory && it.path !in except }.forEach { sendFile(folder, it.path) }
}

fun FolderReceiveSession.completeFolder(sent: Int, failed: List<FailedEntry> = emptyList()) =
    folderComplete(FolderCompletePayload(id, sent, failed.size, failed))
