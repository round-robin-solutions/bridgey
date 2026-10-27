package dev.bridgey.android.folders

import java.io.File
import java.io.FileOutputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * The sender's journal of a folder sent from this phone (4.7, phone to Mac): the hashed manifest with each
 * file's content URI, so the folder resumes after a disconnect or an app restart without hashing again, and
 * the entries the receiver confirmed. `no_backup/folder-sends/<id>.plan` (written once at accept) and
 * `<id>.done` (appended, one entry index per line), both owner-only. Deleted when the folder ends, after 24 hours
 * without progress, and on Forget device. Holds names and URIs: never logged, never backed up.
 */
class FolderSendJournals(private val directory: File, private val clock: () -> Long = System::currentTimeMillis) {
    class Header(
        val folderTransferId: String,
        val peerId: String,
        val peerName: String,
        val rootName: String,
        val into: Boolean,
        val downloadRequestId: String?,
        val skipped: SkippedCounts,
        val createdAtMillis: Long,
        /** A one-off tree grant ("Browse…") to release when the folder ends. */
        val releaseTree: String?,
    )

    class Record(val header: Header, val entries: List<ManifestEntry>, val sources: List<String?>, val done: Set<Int>, val lastProgressMillis: Long)

    private fun plan(id: String) = File(directory, "$id.plan")
    private fun done(id: String) = File(directory, "$id.done")

    fun create(header: Header, entries: List<ManifestEntry>, sources: List<String?>) {
        ensureDirectory()
        val json = JSONObject()
            .put("v", 1).put("id", header.folderTransferId).put("peer", header.peerId).put("peerName", header.peerName)
            .put("root", header.rootName).put("into", header.into).put("download", header.downloadRequestId ?: JSONObject.NULL)
            .put("skipped", header.skipped.toJson()).put("created", header.createdAtMillis).put("release", header.releaseTree ?: JSONObject.NULL)
            .put("entries", JSONArray().apply {
                entries.forEachIndexed { index, entry ->
                    put(JSONArray().put(entry.type.wire).put(entry.path).put(entry.size).put(entry.sha256 ?: "").put(entry.modified ?: -1L)
                        .put(sources.getOrNull(index) ?: ""))
                }
            })
        val target = plan(header.folderTransferId)
        val temporary = File(directory, ".${target.name}.tmp")
        FileOutputStream(temporary).use { out ->
            out.write(json.toString().toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        ownerOnly(temporary)
        temporary.renameTo(target)
        done(header.folderTransferId).also { file ->
            if (!file.exists()) file.createNewFile()
            ownerOnly(file)
            file.setLastModified(clock())
        }
        target.setLastModified(clock())
    }

    fun markDone(id: String, entries: Collection<Int>) {
        val file = done(id)
        if (!plan(id).isFile || entries.isEmpty()) return
        FileOutputStream(file, true).use { out -> out.write(entries.joinToString("\n", postfix = "\n").toByteArray()) }
        file.setLastModified(clock())
    }

    fun read(id: String): Record? = runCatching {
        val json = JSONObject(plan(id).readText(Charsets.UTF_8))
        if (json.optInt("v") != 1) return null
        val array = json.getJSONArray("entries")
        val entries = ArrayList<ManifestEntry>(array.length())
        val sources = ArrayList<String?>(array.length())
        for (index in 0 until array.length()) {
            val item = array.getJSONArray(index)
            val type = if (item.getString(0) == "dir") ManifestEntry.Type.DIR else ManifestEntry.Type.FILE
            entries += ManifestEntry(type, item.getString(1), item.getLong(2), item.getString(3).ifEmpty { null }, item.getLong(4).takeIf { it >= 0 })
            sources += item.getString(5).ifEmpty { null }
        }
        val doneFile = done(id)
        val done = if (doneFile.isFile) doneFile.readLines().mapNotNullTo(HashSet()) { it.trim().toIntOrNull()?.takeIf { index -> index in entries.indices } } else emptySet()
        val header = Header(
            json.getString("id"), json.getString("peer"), json.optString("peerName"), json.getString("root"), json.optBoolean("into"),
            if (json.isNull("download")) null else json.optString("download"), SkippedCounts.parse(json.optJSONObject("skipped")),
            json.optLong("created"), if (json.isNull("release")) null else json.optString("release"),
        )
        val last = maxOf(plan(id).lastModified(), doneFile.lastModified())
        Record(header, entries, sources, done, last)
    }.getOrNull()

    fun all(): List<Record> = directory.listFiles { file -> file.name.endsWith(".plan") }.orEmpty()
        .mapNotNull { read(it.name.removeSuffix(".plan")) }

    fun delete(id: String) {
        plan(id).delete()
        done(id).delete()
    }

    /** Drops journals older than the resume window; returns what is left. */
    fun prune(): List<Record> = all().filter { record ->
        val keep = FolderTimeouts.canResume(record.lastProgressMillis, clock())
        if (!keep) delete(record.header.folderTransferId)
        keep
    }

    fun deleteForPeer(peerId: String): List<Record> = all().filter { it.header.peerId == peerId }.onEach { delete(it.header.folderTransferId) }

    private fun ownerOnly(target: File) {
        target.setReadable(false, false)
        target.setReadable(true, true)
        target.setWritable(false, false)
        target.setWritable(true, true)
        target.setExecutable(false, false)
    }

    private fun ensureDirectory() {
        if (!directory.isDirectory) directory.mkdirs()
        directory.setReadable(false, false)
        directory.setReadable(true, true)
        directory.setWritable(false, false)
        directory.setWritable(true, true)
        directory.setExecutable(false, false)
        directory.setExecutable(true, true)
    }
}
