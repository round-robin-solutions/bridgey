package dev.bridgey.android

import java.io.File
import org.json.JSONObject

/** A received offer as kept next to its data, so a paste still resolves after a process restart. */
internal data class ReceivedClipOffer(
    val offer: ClipOffer,
    val deviceId: String,
    val peerName: String,
    val receivedAt: Long,
) {
    fun encode(): String = JSONObject()
        .put("offer", offer.toJson(includeInline = false))
        .put("deviceId", deviceId)
        .put("peerName", peerName)
        .put("receivedAt", receivedAt)
        .toString()

    companion object {
        fun decode(text: String): ReceivedClipOffer? = runCatching {
            val json = JSONObject(text)
            ReceivedClipOffer(
                offer = ClipOffer.fromJson(json.getJSONObject("offer")) ?: return null,
                deviceId = json.getString("deviceId"),
                peerName = json.getString("peerName"),
                receivedAt = json.getLong("receivedAt"),
            )
        }.getOrNull()
    }
}

/**
 * The app-private clipboard cache in no-backup storage, one folder per received offer:
 *
 *     <root>/<offerId>/offer.json
 *     <root>/<offerId>/<index>/data         the item's bytes (partial until "complete" exists)
 *     <root>/<offerId>/<index>/complete     written after size and SHA-256 were verified
 *     <root>/<offerId>/<index>/handed-out   an app opened it, so it outlives its offer
 *
 * Rules: a superseded offer loses the items no app opened; nothing is kept longer than 24 hours;
 * the total is capped at 2 GB, oldest offers first; Clear activity and Forget device delete it all.
 * Never logged, never in diagnostics.
 */
internal class ClipboardCache(
    private val root: File,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxAgeMillis: Long = ClipLimits.CACHE_MAX_AGE_MILLIS,
    private val maxBytes: Long = ClipLimits.CACHE_MAX_BYTES,
) {
    private fun offerDir(offerId: String): File {
        require(isUuid(offerId))
        return File(root, offerId.lowercase())
    }

    private fun itemDir(offerId: String, index: Int): File {
        require(index in 0 until ClipLimits.MAX_ITEMS)
        return File(offerDir(offerId), index.toString())
    }

    fun dataFile(offerId: String, index: Int): File = File(itemDir(offerId, index), DATA)

    @Synchronized
    fun saveOffer(received: ReceivedClipOffer) {
        val dir = offerDir(received.offer.offerId)
        dir.mkdirs()
        val temporary = File(dir, "$OFFER.tmp")
        temporary.writeText(received.encode(), Charsets.UTF_8)
        if (!temporary.renameTo(File(dir, OFFER))) temporary.delete()
    }

    @Synchronized
    fun loadOffer(offerId: String): ReceivedClipOffer? = runCatching {
        val file = File(offerDir(offerId), OFFER)
        if (!file.isFile || file.length() > 256 * 1024) return null
        ReceivedClipOffer.decode(file.readText(Charsets.UTF_8))
    }.getOrNull()

    /** A new, empty data file for an item about to be received. */
    @Synchronized
    fun createData(offerId: String, index: Int): File {
        val dir = itemDir(offerId, index)
        dir.mkdirs()
        File(dir, COMPLETE).delete()
        return File(dir, DATA).apply {
            delete()
            createNewFile()
        }
    }

    @Synchronized
    fun writeComplete(offerId: String, index: Int, data: ByteArray) {
        createData(offerId, index).writeBytes(data)
        markComplete(offerId, index)
    }

    @Synchronized
    fun markComplete(offerId: String, index: Int) {
        File(itemDir(offerId, index), COMPLETE).createNewFile()
    }

    fun isComplete(offerId: String, index: Int): Boolean =
        runCatching { File(itemDir(offerId, index), COMPLETE).isFile && dataFile(offerId, index).isFile }.getOrDefault(false)

    @Synchronized
    fun markHandedOut(offerId: String, index: Int) {
        val dir = itemDir(offerId, index)
        dir.mkdirs()
        File(dir, HANDED_OUT).createNewFile()
    }

    fun isHandedOut(offerId: String, index: Int): Boolean =
        runCatching { File(itemDir(offerId, index), HANDED_OUT).isFile }.getOrDefault(false)

    /** Drops one item's data, for example after a failed or cancelled transfer. */
    @Synchronized
    fun discardItem(offerId: String, index: Int) {
        if (isHandedOut(offerId, index) && isComplete(offerId, index)) return
        itemDir(offerId, index).deleteRecursively()
    }

    /**
     * The offer was replaced: delete every item no app opened. Handed-out items stay until they age
     * out, so a file pasted into a draft message is still there when the message is sent.
     */
    @Synchronized
    fun supersede(offerId: String) {
        val dir = runCatching { offerDir(offerId) }.getOrNull() ?: return
        dir.listFiles()?.filter(File::isDirectory)?.forEach { item ->
            val kept = File(item, HANDED_OUT).isFile && File(item, COMPLETE).isFile
            if (!kept) item.deleteRecursively()
        }
        if (dir.listFiles()?.none(File::isDirectory) != false) dir.deleteRecursively()
    }

    /**
     * Age and size rules. [keep] are offers in use (the current one, and any with a transfer
     * running); they are never evicted. Oldest offers go first.
     */
    @Synchronized
    fun evict(keep: Set<String> = emptySet()) {
        val now = clock()
        val offers = root.listFiles()?.filter(File::isDirectory).orEmpty()
            .map { it to receivedAt(it) }
            .sortedBy { it.second }
        val kept = keep.mapTo(HashSet(), String::lowercase)
        val survivors = mutableListOf<Pair<File, Long>>()
        offers.forEach { (dir, at) ->
            if (dir.name !in kept && (now - at > maxAgeMillis || at > now + FUTURE_TOLERANCE_MILLIS)) dir.deleteRecursively()
            else survivors += dir to at
        }
        var total = survivors.sumOf { size(it.first) }
        survivors.forEach { (dir, _) ->
            if (total <= maxBytes) return
            if (dir.name in kept) return@forEach
            total -= size(dir)
            dir.deleteRecursively()
        }
    }

    /** At start-up: items that never completed are leftovers of an interrupted transfer. */
    @Synchronized
    fun removePartials() {
        root.listFiles()?.filter(File::isDirectory)?.forEach { offer ->
            offer.listFiles()?.filter(File::isDirectory)?.forEach { item ->
                if (!File(item, COMPLETE).isFile) item.deleteRecursively()
            }
            if (!File(offer, OFFER).isFile) offer.deleteRecursively()
        }
    }

    @Synchronized
    fun clear() {
        root.deleteRecursively()
    }

    /** [bytes] more fit under the size cap once every offer outside [keep] could be evicted. */
    @Synchronized
    fun canHold(bytes: Long, keep: Set<String>): Boolean {
        val kept = keep.mapTo(HashSet(), String::lowercase)
        val keptBytes = root.listFiles()?.filter { it.isDirectory && it.name in kept }?.sumOf(::size) ?: 0L
        return keptBytes + bytes <= maxBytes
    }

    /** Free bytes on the volume the cache lives on; null when unknown. */
    fun freeBytes(): Long? = runCatching {
        generateSequence(root) { it.parentFile }.first(File::exists).usableSpace
    }.getOrNull()?.takeIf { it > 0 }

    fun totalBytes(): Long = root.listFiles()?.filter(File::isDirectory)?.sumOf(::size) ?: 0L

    private fun receivedAt(dir: File): Long {
        val offer = File(dir, OFFER)
        val stored = runCatching { ReceivedClipOffer.decode(offer.readText(Charsets.UTF_8))?.receivedAt }.getOrNull()
        return stored ?: dir.lastModified()
    }

    private fun size(dir: File): Long = dir.walkTopDown().filter(File::isFile).sumOf(File::length)

    private companion object {
        const val OFFER = "offer.json"
        const val DATA = "data"
        const val COMPLETE = "complete"
        const val HANDED_OUT = "handed-out"
        const val FUTURE_TOLERANCE_MILLIS = 5L * 60 * 1000
    }
}
