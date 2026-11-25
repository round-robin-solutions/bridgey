package dev.bridgey.android

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/*
 * Resuming a file from its last verified chunk (draft files_resume_draft1; docs/protocol.md "Resuming files",
 * docs/file-resume.md). The receiver keeps the partial of an interrupted file with a private record; the next offer of
 * the same content from the same device is answered with files.resume (a whole number of 1 MiB blocks and their
 * SHA-256), the sender checks that hash against the ones it kept while hashing the file and answers files.resume.ack,
 * and chunks follow from there. This file has no Android or network code; the session code in PairingCoordinator.kt
 * runs the exchange. rust/client/src/resume.rs is the reference, the Mac has the same rules in FileResume.swift, and
 * protocol/test-vectors/files-resume-v1.json checks all three.
 */

/** The feature key: a capability, advertised on protocol 2 sessions. */
internal const val FILES_RESUME_FEATURE_KEY = "files_resume_draft1"

internal object FileResume {
    /** A resume offset is a whole number of these, or the whole file. Only larger files are offered resumable. */
    const val BLOCK = 1_048_576L
    /** A kept partial lives until 24 hours after it last grew. */
    const val LIFETIME_MILLIS = 24L * 60 * 60 * 1000
    const val PER_DEVICE = 4
    const val TOTAL = 16
    const val MAX_KEPT_BYTES = 20L * 1024 * 1024 * 1024
    /** The record follows a resumable file at least this often while it comes in. */
    const val CHECKPOINT_EVERY = 64L * 1024 * 1024
    const val MAX_MESSAGE = 1024
    /** How long a sender waits for the answer to a resumable offer; every files.resume.wait starts it again. */
    const val ANSWER_WINDOW_MILLIS = 120_000L
    /** How often a receiver that is still re-reading its partial sends files.resume.wait. */
    const val WAIT_EVERY_MILLIS = 30_000L
    /** The folder single files land in (MediaStore RELATIVE_PATH): the only place partials are kept and swept. */
    const val RECEIVE_DIR = "Download/Bridgey/"

    /** Only files larger than one block are offered resumable. */
    fun resumable(size: Long): Boolean = size > BLOCK

    private fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    /** Strict base64 of exactly 32 bytes (a SHA-256), or null. */
    fun hash32(text: String?): ByteArray? =
        text?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() }?.takeIf { it.size == 32 }

    /** A strict JSON object for this transfer (version 1, the transfer ID exactly), at most 1,024 bytes. */
    private fun message(plain: ByteArray, transferId: String): JSONObject? {
        if (plain.size > MAX_MESSAGE) return null
        val o = strictJsonObject(plain) ?: return null
        if (jsonInteger(o.opt("version")) != 1L) return null
        if (o.opt("transferId") !is String || o.getString("transferId") != transferId) return null
        return o
    }

    /** files.resume: the receiver holds the first [offset] bytes and this is their SHA-256. */
    fun resumePayload(transferId: String, offset: Long, prefix: ByteArray): ByteArray =
        JSONObject().put("version", 1).put("transferId", transferId).put("offset", offset).put("prefixSha256", b64(prefix))
            .toString().toByteArray(Charsets.UTF_8)

    /** A files.resume for this transfer of [size] bytes: the offset and the prefix hash, or null when it breaks a rule. */
    fun parseResume(plain: ByteArray, transferId: String, size: Long): Pair<Long, ByteArray>? {
        val o = message(plain, transferId) ?: return null
        val offset = jsonInteger(o.opt("offset"))?.takeIf { it in 1..size && (it % BLOCK == 0L || it == size) } ?: return null
        val prefix = (o.opt("prefixSha256") as? String)?.let(::hash32) ?: return null
        return offset to prefix
    }

    /** files.resume.ack: the sender continues from [offset] (the receiver's) or from byte zero, saying why. */
    fun ackPayload(transferId: String, offset: Long, reason: String?): ByteArray =
        JSONObject().put("version", 1).put("transferId", transferId).put("offset", offset).apply { reason?.let { put("reason", it) } }
            .toString().toByteArray(Charsets.UTF_8)

    /** A files.resume.ack answering a proposal of [proposed] bytes: [proposed] or 0, or null for anything else. */
    fun parseAck(plain: ByteArray, transferId: String, proposed: Long): Long? {
        val o = message(plain, transferId) ?: return null
        return jsonInteger(o.opt("offset"))?.takeIf { it == proposed || it == 0L }
    }

    /**
     * The sender's answer to a files.resume for its file of [size] bytes with SHA-256 [sha256]: the offset to go on
     * from (the receiver's, or 0) and, for 0, why (`invalid` or `mismatch`).
     */
    fun senderAnswer(plain: ByteArray, transferId: String, size: Long, sha256: ByteArray, blocks: BlockHashes): Pair<Long, String?> {
        val (offset, prefix) = parseResume(plain, transferId, size) ?: return 0L to "invalid"
        val ours = if (offset == size) sha256 else blocks.prefix(offset)
        return if (ours != null && MessageDigest.isEqual(ours, prefix)) offset to null else 0L to "mismatch"
    }
}

/** A sender's prefix hashes at every 1 MiB boundary of a file, from the pass that hashed it for the offer. */
internal class BlockHashes(private val hashes: List<ByteArray>) {
    val count: Int get() = hashes.size

    /** The SHA-256 of the first [offset] bytes, when [offset] is a block boundary inside the file. */
    fun prefix(offset: Long): ByteArray? {
        if (offset <= 0 || offset % FileResume.BLOCK != 0L) return null
        return hashes.getOrNull((offset / FileResume.BLOCK - 1).toInt())
    }
}

/**
 * A running SHA-256 that remembers the prefix hash at every block boundary it passes: the last one (a receiver's
 * checkpoint) or all of them (a sender's, to answer a files.resume without reading the file again).
 */
internal class RunningHash private constructor(
    private val digest: MessageDigest,
    length: Long,
    private var last: Pair<Long, ByteArray>,
    private val all: MutableList<ByteArray>?,
) {
    var length: Long = length
        private set

    constructor(keepAll: Boolean) : this(sha256(), 0L, 0L to emptyHash(), if (keepAll) mutableListOf() else null)

    fun update(bytes: ByteArray, offset: Int = 0, count: Int = bytes.size) {
        var at = offset
        var left = count
        while (left > 0) {
            val toBoundary = FileResume.BLOCK - length % FileResume.BLOCK
            val n = minOf(toBoundary, left.toLong()).toInt()
            digest.update(bytes, at, n)
            length += n
            at += n
            left -= n
            if (length % FileResume.BLOCK == 0L) {
                val prefix = snapshot()
                last = length to prefix
                all?.add(prefix)
            }
        }
    }

    /** The SHA-256 of everything so far, without ending the hash. */
    private fun snapshot(): ByteArray = (digest.clone() as MessageDigest).digest()

    /** What a receiver may record of a file of [size] bytes: the whole file once it is all here, else the last block. */
    fun checkpoint(size: Long): Pair<Long, ByteArray> = if (length == size) size to snapshot() else last

    fun finish(): ByteArray = digest.digest()

    fun blocks(): BlockHashes = BlockHashes(all?.toList() ?: emptyList())

    companion object {
        fun sha256(): MessageDigest = MessageDigest.getInstance("SHA-256")
        private fun emptyHash(): ByteArray = sha256().digest()

        /** Continues from a verified prefix of [length] bytes whose running hash is [digest] (not finished). */
        fun resumed(digest: MessageDigest, length: Long, prefix: ByteArray): RunningHash = RunningHash(digest, length, length to prefix, null)

        /** Hashes [input] to its end, keeping every block's prefix hash: the whole SHA-256, the size and the blocks. */
        fun of(input: InputStream, buffer: ByteArray = ByteArray(256 * 1024), keepGoing: () -> Unit = {}): Triple<ByteArray, Long, BlockHashes> {
            val running = RunningHash(keepAll = true)
            while (true) {
                keepGoing()
                val n = input.read(buffer)
                if (n < 0) break
                running.update(buffer, 0, n)
            }
            val size = running.length
            val blocks = running.blocks()
            return Triple(running.finish(), size, blocks)
        }

        /**
         * The SHA-256 of the first [length] bytes of [input] and the running hash to continue from there, reading in
         * 256 KiB pieces. Throws when [input] is shorter. [keepGoing] runs between pieces (it may throw to stop).
         */
        fun prefixOf(input: InputStream, length: Long, keepGoing: () -> Unit = {}): Pair<MessageDigest, ByteArray> {
            val digest = sha256()
            val buffer = ByteArray(256 * 1024)
            var left = length
            while (left > 0) {
                keepGoing()
                val n = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                if (n < 0) throw IOException("shorter than its record")
                digest.update(buffer, 0, n)
                left -= n
            }
            return digest to (digest.clone() as MessageDigest).digest()
        }
    }
}

/**
 * One kept partial: whose file it is (the authenticated device and the offer's size and SHA-256), how much of it is
 * verified, and where it is ([part]: the pending MediaStore entry's URI on Android).
 */
internal data class ResumeRecord(
    val peer: String,
    val size: Long,
    val sha256: String,
    /** Verified bytes: on stable storage before this record named them. */
    val length: Long,
    /** Base64 SHA-256 of those bytes. */
    val prefix: String,
    /** The receive folder (MediaStore RELATIVE_PATH) and the partial in it. */
    val dir: String,
    val part: String,
    /** The offered name (made safe), only to notice a changed source. */
    val name: String,
    /** When it last grew or was kept (Unix ms). */
    val updated: Long,
) {
    fun expired(now: Long): Boolean =
        // A stamp far in the future means the clock went back: it counts as expired too.
        now >= updated + FileResume.LIFETIME_MILLIS || updated > now + FileResume.LIFETIME_MILLIS

    fun toJson(): JSONObject = JSONObject().put("peer", peer).put("size", size).put("sha256", sha256).put("length", length)
        .put("prefix", prefix).put("dir", dir).put("part", part).put("name", name).put("updated", updated)

    companion object {
        /** A record read back, or null when anything in it is out of place (it is then dropped, never followed). */
        fun fromJson(o: JSONObject, validPart: (String) -> Boolean): ResumeRecord? {
            fun string(key: String) = o.opt(key) as? String
            fun number(key: String) = jsonInteger(o.opt(key))?.takeIf { it >= 0 }
            val r = ResumeRecord(
                peer = string("peer")?.lowercase() ?: return null,
                size = number("size") ?: return null,
                sha256 = string("sha256") ?: return null,
                length = number("length") ?: return null,
                prefix = string("prefix") ?: return null,
                dir = string("dir") ?: return null,
                part = string("part") ?: return null,
                name = string("name").orEmpty(),
                updated = number("updated") ?: return null,
            )
            val uuid = runCatching { UUID.fromString(r.peer) }.isSuccess
            val ok = uuid && FileResume.hash32(r.sha256) != null && FileResume.hash32(r.prefix) != null && r.length <= r.size && validPart(r.part)
            return r.takeIf { ok }
        }
    }
}

/**
 * The receiver's kept partials: pure bookkeeping, the same rules as rust/client's resume::Store. Methods return the
 * parts to delete; the caller deletes them and saves [encode]. Not thread-safe: the caller holds a lock.
 */
internal class ResumeStore(records: List<ResumeRecord> = emptyList()) {
    private val list = records.toMutableList()
    /** Parts a transfer is using now: never swept, evicted or claimed twice. */
    private val claimed = mutableSetOf<String>()

    val records: List<ResumeRecord> get() = list.toList()

    fun isClaimed(part: String): Boolean = part in claimed

    fun encode(): ByteArray =
        JSONObject().put("version", 1).put("records", JSONArray(list.map(ResumeRecord::toJson))).toString().toByteArray(Charsets.UTF_8)

    private fun take(keep: (ResumeRecord) -> Boolean): List<String> {
        val gone = list.filterNot(keep).map(ResumeRecord::part)
        list.retainAll(keep)
        return gone
    }

    /** At start: drops what can no longer be resumed (expired, nothing verified, the part missing or shorter). */
    fun sweep(now: Long, partLength: (String) -> Long?): List<String> =
        take { r -> !r.expired(now) && r.length > 0 && (partLength(r.part) ?: -1L) >= r.length }

    private fun expire(now: Long): List<String> = take { r -> r.part in claimed || !r.expired(now) }

    /**
     * A resumable offer from [peer]: the partial to resume, claimed until released, and the parts to delete. Only a
     * record from the same device with the same size and SHA-256 matches, in [dir]. Unclaimed records from that device
     * with the same name but other content go: its source changed.
     */
    fun claim(peer: String, size: Long, sha256: String, name: String, dir: String, now: Long): Pair<ResumeRecord?, List<String>> {
        val device = peer.lowercase()
        val gone = expire(now).toMutableList()
        fun same(r: ResumeRecord) = r.peer == device && r.size == size && r.sha256 == sha256
        val found = list.firstOrNull { it.part !in claimed && same(it) && it.length > 0 && it.dir == dir }
        gone += take { r ->
            val free = r.part !in claimed && r.part != found?.part
            val stale = r.peer == device && (same(r) || (name.isNotEmpty() && r.name == name))
            !(free && stale)
        }
        found?.let { claimed += it.part }
        return found to gone
    }

    /** Saves a record, new or updated (matched by its part), stamped [now] and claimed. Over the limits the oldest go. */
    fun save(record: ResumeRecord, now: Long): List<String> {
        val r = record.copy(peer = record.peer.lowercase(), updated = now)
        claimed += r.part
        val i = list.indexOfFirst { it.part == r.part }
        if (i >= 0) list[i] = r else list += r
        val gone = expire(now).toMutableList()
        while (true) {
            val overPeer = list.count { it.peer == r.peer } > FileResume.PER_DEVICE
            if (!overPeer && list.size <= FileResume.TOTAL && list.sumOf { it.length } <= FileResume.MAX_KEPT_BYTES) break
            val oldest = list.filter { it.part !in claimed && (!overPeer || it.peer == r.peer) }.minByOrNull { it.updated } ?: break
            list.remove(oldest)
            gone += oldest.part
        }
        return gone
    }

    /** The transfer using this partial ended: its record stays for a later attempt ([keep]) or goes. True when one went. */
    fun release(part: String, keep: Boolean): Boolean {
        claimed -= part
        return !keep && list.removeAll { it.part == part }
    }

    /** The device was forgotten: its partials go (those in use go when their transfer ends). */
    fun forget(peer: String): List<String> {
        val device = peer.lowercase()
        return take { r -> r.peer != device || r.part in claimed }
    }

    companion object {
        fun decode(bytes: ByteArray?, validPart: (String) -> Boolean): ResumeStore {
            val o = bytes?.let(::strictJsonObject)?.takeIf { jsonInteger(it.opt("version")) == 1L } ?: return ResumeStore()
            val array = o.optJSONArray("records") ?: return ResumeStore()
            val records = (0 until minOf(array.length(), FileResume.TOTAL * 2)).mapNotNull { i ->
                array.optJSONObject(i)?.let { ResumeRecord.fromJson(it, validPart) }
            }
            return ResumeStore(records)
        }
    }
}

/** The records in one private file (never SharedPreferences, never beside received files), written atomically. */
internal class ResumeRecordFile(private val file: File) {
    fun read(): ByteArray? = runCatching { file.takeIf(File::exists)?.readBytes() }.getOrNull()

    fun write(bytes: ByteArray) {
        runCatching {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            java.io.FileOutputStream(temporary).use { out ->
                out.write(bytes)
                out.fd.sync()
            }
            if (!temporary.renameTo(file)) {
                file.delete()
                temporary.renameTo(file)
            }
        }
    }
}
