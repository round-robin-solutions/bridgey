package dev.bridgey.android.folders

/**
 * Receiver side of the manifest (4.5): collects the pages of one offer in order and validates the whole
 * manifest against the offer. Any failure names the first bad entry, answered as folders.rejected
 * (`invalid_manifest`).
 */
class ManifestAssembler(private val offer: FolderOfferPayload) {
    sealed interface Result {
        /** More pages are expected. */
        data object NeedMore : Result
        data class Complete(val entries: List<ManifestEntry>) : Result
        data class Rejected(val code: String, val entry: Int?) : Result
    }

    private val entries = ArrayList<ManifestEntry>()
    private val directories = HashSet<String>()
    private val siblingKeys = HashMap<String, HashSet<String>>()
    private var nextPage = 0
    private var bytes = 0L
    private var files = 0
    private var folders = 0
    private var total = 0L
    private var finished: Result? = null

    val expectedEntries: Int get() = offer.fileCount + offer.folderCount

    /** An empty folder has no pages: the manifest is complete as soon as the offer arrives. */
    fun completeWithoutPages(): Result? {
        if (offer.pageCount != 0) return null
        val result = if (ManifestDigest.compute(offer.rootName, emptyList()) == offer.manifestSha256) Result.Complete(emptyList())
        else Result.Rejected(FolderCodes.INVALID_MANIFEST, null)
        return result.also { finished = it }
    }

    /** [pageBytes] is the plaintext size of the page, for the 4 MiB cap. */
    fun add(page: ManifestPagePayload, pageBytes: Int): Result {
        finished?.let { return it }
        fun reject(code: String = FolderCodes.INVALID_MANIFEST, entry: Int? = null) = Result.Rejected(code, entry).also { finished = it }
        if (page.folderTransferId != offer.folderTransferId || page.page != nextPage) return reject()
        bytes += pageBytes
        if (bytes > FolderLimits.MAX_MANIFEST_BYTES) return reject(FolderCodes.LIMIT_EXCEEDED)
        for (entry in page.entries) {
            val index = entries.size
            if (index >= expectedEntries) return reject(entry = index)
            if (!FolderPaths.isValidManifestPath(entry.path)) return reject(entry = index)
            val previous = entries.lastOrNull()
            if (previous != null && FolderPaths.manifestOrder.compare(previous.path, entry.path) >= 0) return reject(entry = index)
            val parent = FolderPaths.parent(entry.path)
            if (parent.isNotEmpty() && parent !in directories) return reject(entry = index)
            val keys = siblingKeys.getOrPut(parent) { HashSet() }
            if (!keys.add(caseKey(FolderPaths.leaf(entry.path)))) return reject(entry = index)
            if (entry.isDirectory) {
                directories += entry.path
                folders++
                if (folders > offer.folderCount) return reject(entry = index)
            } else {
                files++
                if (files > offer.fileCount) return reject(entry = index)
                if (entry.size !in 0..FolderLimits.MAX_FILE_SIZE) return reject(entry = index)
                val hash = entry.sha256
                if (hash == null || runCatching { java.util.Base64.getDecoder().decode(hash).size == 32 }.getOrDefault(false).not()) {
                    return reject(entry = index)
                }
                total += entry.size
                if (total > offer.totalSize) return reject(entry = index)
            }
            entries += entry
        }
        nextPage++
        if (nextPage < offer.pageCount) return Result.NeedMore
        if (entries.size != expectedEntries || files != offer.fileCount || folders != offer.folderCount || total != offer.totalSize) {
            return reject(entry = entries.size.takeIf { it < expectedEntries })
        }
        if (ManifestDigest.compute(offer.rootName, entries) != offer.manifestSha256) return reject()
        return Result.Complete(entries.toList()).also { finished = it }
    }
}

/**
 * Sender side: splits a manifest into pages of at most 256 entries and 32 KiB of plaintext. Null when the
 * manifest needs more than 128 pages or 4 MiB.
 */
object ManifestPager {
    fun pages(folderTransferId: String, entries: List<ManifestEntry>): List<ManifestPagePayload>? {
        val pages = ArrayList<ManifestPagePayload>()
        var current = ArrayList<ManifestEntry>()
        var currentBytes = 0
        var totalBytes = 0
        val overhead = ManifestPagePayload(folderTransferId, FolderLimits.MAX_PAGES, emptyList()).toJson().toString().length + 16
        fun flush() {
            if (current.isEmpty()) return
            pages += ManifestPagePayload(folderTransferId, pages.size, current)
            totalBytes += currentBytes + overhead
            current = ArrayList()
            currentBytes = 0
        }
        for (entry in entries) {
            val size = utf8Length(ManifestPagePayload.entryJson(entry).toString()) + 1
            if (current.size == FolderLimits.MAX_ENTRIES_PER_PAGE || overhead + currentBytes + size > FolderLimits.MAX_PAGE_BYTES) flush()
            current += entry
            currentBytes += size
        }
        flush()
        if (pages.size > FolderLimits.MAX_PAGES || totalBytes > FolderLimits.MAX_MANIFEST_BYTES) return null
        return pages
    }
}
