package dev.bridgey.android.folders

import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/**
 * Phone to Mac (Files 2.0): one item a folder sent from this phone is made of. Folders list their children
 * (one storage query); files open for reading. [source] is a content URI the sender journal keeps so a folder
 * resumes after the app restarts; it never leaves the phone.
 */
interface SendNode {
    val name: String
    val isDirectory: Boolean
    val size: Long
    val modifiedMillis: Long?
    val source: String?

    @Throws(IOException::class)
    fun children(): List<SendNode>

    @Throws(IOException::class)
    fun open(): InputStream
}

/** A [TreeStore] item as a [SendNode]: a granted folder, a place, or Download/Bridgey. */
class TreeSendNode(private val store: TreeStore, private val entry: TreeEntry) : SendNode {
    override val name: String get() = entry.name
    override val isDirectory: Boolean get() = entry.isDirectory
    override val size: Long get() = entry.size ?: 0
    override val modifiedMillis: Long? get() = entry.modifiedMillis
    override val source: String? get() = entry.uri ?: store.uriOf(entry.id).takeIf { it.startsWith("content://") }

    override fun children(): List<SendNode> = store.entries(entry.id).map { TreeSendNode(store, it) }

    override fun open(): InputStream = store.openInput(entry.id)

    companion object {
        /** The folder [dirId] of [store] itself, named [name]. */
        fun folder(store: TreeStore, dirId: String, name: String): SendNode = TreeSendNode(store, TreeEntry(dirId, name, true))
    }
}

/** The scanned folder (or download items) in manifest order; files have no hash until [FolderHashing] ran. */
class FolderScanResult(
    val rootName: String,
    val into: Boolean,
    val entries: List<ManifestEntry>,
    /** The node of each entry (folders included), parallel to [entries]. */
    val nodes: List<SendNode>,
    val skipped: SkippedCounts,
    val renamed: Int,
    /** Why the folder is refused before anything is sent, or null. */
    val problem: String?,
) {
    val fileCount: Int get() = entries.count { !it.isDirectory }
    val folderCount: Int get() = entries.count { it.isDirectory }
    val totalSize: Long get() = entries.filter { !it.isDirectory }.sumOf { it.size }
}

/**
 * Turns a folder on the phone (or a list of download items) into a manifest, like the Mac's FolderScanner:
 * portable names, case clashes numbered, hidden and system files skipped and counted (both off, as the Mac's
 * defaults), limits of 5.4. A whole folder keeps its own name as the root; `into` items are the top-level
 * entries themselves.
 */
object FolderScanner {
    private val placeholderHash = java.util.Base64.getEncoder().encodeToString(ByteArray(32))

    fun scanFolder(root: SendNode, includeHidden: Boolean = false, includeSystem: Boolean = false, cancelled: () -> Boolean = { false }): FolderScanResult {
        val rootName = PortableName.convert(root.name) ?: "_"
        val children = try {
            root.children()
        } catch (_: IOException) {
            return FolderScanResult(rootName, false, emptyList(), emptyList(), SkippedCounts(), 0, FolderCodes.UNREADABLE)
        } catch (_: SecurityException) {
            return FolderScanResult(rootName, false, emptyList(), emptyList(), SkippedCounts(), 0, FolderCodes.PLACE_UNAVAILABLE)
        }
        return Walk(includeHidden, includeSystem, cancelled).run(children, rootName, into = false, renamedRoot = rootName != root.name)
    }

    /** Download items: each lands directly in the receiver's folder (`into`). [rootName] is for display. */
    fun scanItems(items: List<SendNode>, cancelled: () -> Boolean = { false }): FolderScanResult {
        val rootName = items.firstOrNull()?.name?.let(PortableName::convert) ?: "_"
        // Items the user picked on purpose: hidden ones are sent too; system clutter inside folders is not.
        return Walk(includeHidden = true, includeSystem = false, cancelled = cancelled, topLevelExplicit = true)
            .run(items, rootName, into = true, renamedRoot = false)
    }

    private class Walk(
        val includeHidden: Boolean,
        val includeSystem: Boolean,
        val cancelled: () -> Boolean,
        val topLevelExplicit: Boolean = false,
    ) {
        val entries = ArrayList<ManifestEntry>()
        val nodes = ArrayList<SendNode>()
        var links = 0
        var hidden = 0
        var system = 0
        var unreadable = 0
        var tooLarge = 0
        var tooLong = 0
        var renamed = 0
        var files = 0
        var folders = 0
        var total = 0L
        var deepest = 0

        fun run(children: List<SendNode>, rootName: String, into: Boolean, renamedRoot: Boolean): FolderScanResult {
            if (renamedRoot) renamed++
            walk(children, "", 0)
            var problem: String? = when {
                cancelled() -> FolderCodes.CANCELLED
                files > FolderLimits.MAX_FILES || folders > FolderLimits.MAX_FOLDERS || deepest > FolderLimits.MAX_DEPTH ||
                    total > FolderLimits.MAX_TOTAL_SIZE -> FolderCodes.LIMIT_EXCEEDED
                else -> null
            }
            if (problem == null) {
                val sized = entries.map { if (it.isDirectory) it else it.copy(sha256 = placeholderHash) }
                if (ManifestPager.pages("00000000-0000-0000-0000-000000000000", sized) == null) problem = FolderCodes.LIMIT_EXCEEDED
            }
            val skipped = SkippedCounts(links = links, hidden = hidden, system = system, unreadable = unreadable, tooLarge = tooLarge, tooLong = tooLong)
            return FolderScanResult(rootName, into, entries.toList(), nodes.toList(), skipped, renamed, problem)
        }

        private data class Candidate(val node: SendNode, val name: String)

        private fun walk(children: List<SendNode>, relative: String, depth: Int) {
            if (cancelled()) return
            val keeping = files <= FolderLimits.MAX_FILES && folders <= FolderLimits.MAX_FOLDERS
            val candidates = ArrayList<Candidate>()
            for (node in children) {
                val kind = SystemFiles.classify(node.name)
                if (kind == SystemFiles.Kind.PARTIAL) continue
                val explicit = topLevelExplicit && depth == 0
                if (!explicit && !SystemFiles.included(kind, includeHidden, includeSystem)) {
                    if (kind == SystemFiles.Kind.SYSTEM) system++ else hidden++
                    continue
                }
                if (!node.isDirectory && node.size > FolderLimits.MAX_FILE_SIZE) {
                    tooLarge++
                    continue
                }
                val converted = PortableName.convert(node.name)
                if (converted == null) {
                    unreadable++
                    continue
                }
                candidates += Candidate(node, converted)
            }
            val resolved = ConflictNames.resolveSiblings(candidates.map { it.name to it.node.isDirectory })
            val ordered = resolved.map { (index, final) -> candidates[index] to final }
                .sortedWith { a, b -> FolderPaths.compareUtf8(a.second, b.second) }
            for ((candidate, final) in ordered) {
                if (cancelled()) return
                val node = candidate.node
                val path = if (relative.isEmpty()) final else "$relative/$final"
                if (utf8Length(path) > FolderLimits.MAX_PATH_BYTES) {
                    tooLong++
                    continue
                }
                if (final != java.text.Normalizer.normalize(node.name, java.text.Normalizer.Form.NFC)) renamed++
                val entryDepth = depth + 1
                deepest = maxOf(deepest, entryDepth)
                if (node.isDirectory) {
                    val grandchildren = try {
                        node.children()
                    } catch (_: IOException) {
                        unreadable++
                        continue
                    } catch (_: SecurityException) {
                        unreadable++
                        continue
                    }
                    folders++
                    if (keeping && entryDepth <= FolderLimits.MAX_DEPTH) {
                        entries += ManifestEntry(ManifestEntry.Type.DIR, path)
                        nodes += node
                    }
                    if (entryDepth > FolderLimits.MAX_DEPTH + 1) continue
                    walk(grandchildren, path, entryDepth)
                } else {
                    files++
                    total += node.size
                    if (keeping && entryDepth <= FolderLimits.MAX_DEPTH) {
                        entries += ManifestEntry(ManifestEntry.Type.FILE, path, node.size, null, node.modifiedMillis)
                        nodes += node
                    }
                }
            }
        }
    }
}

/**
 * Reads every file once with SHA-256. A file that cannot be read is dropped and counted; a changed size keeps what was
 * read. Files are hashed [THREADS] at a time (live test 2026-10-30: one at a time, preparing a Phone files download of
 * 100 photos of 5 MB took 8.4 s on the emulator before the first byte went out, while four readers through shared
 * storage take about half the time of one). The result keeps manifest order.
 */
object FolderHashing {
    const val READ_SIZE = 256 * 1024
    const val THREADS = 4

    private class Hashed(val size: Long, val sha256: String)

    /** Null when cancelled. [progress] gets bytes hashed so far and the total (from any of the hashing threads). */
    fun hash(
        scan: FolderScanResult,
        progress: (Long, Long) -> Unit = { _, _ -> },
        cancelled: () -> Boolean = { false },
        threads: Int = THREADS,
    ): FolderScanResult? {
        val total = scan.totalSize.coerceAtLeast(1)
        val done = java.util.concurrent.atomic.AtomicLong()
        val stop = java.util.concurrent.atomic.AtomicBoolean(false)
        val files = scan.entries.indices.filter { !scan.entries[it].isDirectory }
        val results = arrayOfNulls<Hashed>(scan.entries.size)
        val next = java.util.concurrent.atomic.AtomicInteger()
        val reportLock = Any()

        fun hashOne(index: Int, buffer: ByteArray): Hashed? {
            val digest = MessageDigest.getInstance("SHA-256")
            var read = 0L
            return try {
                scan.nodes[index].open().use { input ->
                    while (true) {
                        if (stop.get() || cancelled()) {
                            stop.set(true)
                            return null
                        }
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                        read += count
                        val sofar = done.addAndGet(count.toLong())
                        synchronized(reportLock) { progress(sofar.coerceAtMost(total), total) }
                        if (read > FolderLimits.MAX_FILE_SIZE) throw IOException("too large")
                    }
                }
                Hashed(read, java.util.Base64.getEncoder().encodeToString(digest.digest()))
            } catch (_: IOException) {
                null
            } catch (_: SecurityException) {
                null
            }
        }

        val worker = Runnable {
            val buffer = ByteArray(READ_SIZE)
            while (!stop.get()) {
                val slot = next.getAndIncrement()
                if (slot >= files.size) break
                results[files[slot]] = hashOne(files[slot], buffer)
            }
        }
        val count = threads.coerceIn(1, files.size.coerceAtLeast(1))
        val pool = List(count - 1) { Thread(worker, "bridgey-hash-$it").apply { start() } }
        worker.run()
        pool.forEach(Thread::join)
        if (stop.get() || cancelled()) return null

        val entries = ArrayList<ManifestEntry>(scan.entries.size)
        val nodes = ArrayList<SendNode>(scan.nodes.size)
        var unreadable = 0
        for ((index, entry) in scan.entries.withIndex()) {
            if (entry.isDirectory) {
                entries += entry
                nodes += scan.nodes[index]
                continue
            }
            val hashed = results[index]
            if (hashed == null) {
                unreadable++
                continue
            }
            entries += entry.copy(size = hashed.size, sha256 = hashed.sha256)
            nodes += scan.nodes[index]
        }
        progress(total, total)
        val skipped = scan.skipped.copy(unreadable = scan.skipped.unreadable + unreadable)
        return FolderScanResult(scan.rootName, scan.into, entries, nodes, skipped, scan.renamed, scan.problem)
    }
}
