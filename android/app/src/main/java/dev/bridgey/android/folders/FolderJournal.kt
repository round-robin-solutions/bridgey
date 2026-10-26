package dev.bridgey.android.folders

import java.io.File
import java.io.FileOutputStream
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * The receiver's journal (6.6): one append-only text file per folder transfer in
 * `noBackupFilesDir/folder-transfers/<folderTransferId>.journal`, owner-only. Lines:
 *
 * ```
 * v1 <peerDeviceId> <manifestSha256> <createdAtMs> <placeId> <choice> <rootName> <rootDocumentUri> <destinationLabel> <oneOffTree>
 * d <entry> <documentUri>                         folder created (or reused by Merge)
 * p <entry> <uri>                                 file being written (a part file, or a small file under its final name)
 * r <entry> <oldUri> <partUri> <finalName>        replace: verified, old file being deleted, part not yet renamed
 * f <entry>                                       file verified and final
 * ```
 *
 * Free text (names, labels, URIs) is URL-encoded so a line always splits on spaces. Edition detail beyond 6.6:
 * the header carries the destination label and a one-off tree ("-" when none), and `r` lines carry the part
 * and the final name, so a crash between the delete and the rename can be finished. The file's modification
 * time is the last progress: the journal is kept until 24 hours after it ([FolderTimeouts.canResume]).
 * Lines are written with a plain write before files.complete.ack goes out; fsync every 100 lines and at the end.
 */
class FolderJournals(private val directory: File, private val clock: () -> Long = System::currentTimeMillis) {
    data class Header(
        val peerId: String,
        val manifestSha256: String,
        val createdAtMillis: Long,
        val placeId: String,
        val choice: ConflictChoice,
        val rootName: String,
        val rootUri: String,
        val destinationLabel: String,
        val oneOffTree: String?,
    )

    data class Replace(val oldUri: String, val partUri: String, val finalName: String)

    data class Record(
        val folderTransferId: String,
        val header: Header,
        val lastProgressMillis: Long,
        val dirs: Map<Int, String>,
        val done: Set<Int>,
        /** `p` lines without a later `f` or `r`: unfinished files to delete. */
        val openParts: Map<Int, String>,
        /** `r` lines without a later `f`: renames to finish. */
        val openReplaces: Map<Int, Replace>,
    )

    private fun file(id: String): File = File(directory, "$id.journal")

    fun create(folderTransferId: String, header: Header): Writer {
        directory.mkdirs()
        val target = file(folderTransferId)
        target.delete()
        val writer = Writer(target, clock)
        writer.line(
            listOf(
                "v1", enc(header.peerId), enc(header.manifestSha256), header.createdAtMillis.toString(), enc(header.placeId),
                header.choice.wire, enc(header.rootName), enc(header.rootUri), enc(header.destinationLabel), header.oneOffTree?.let(::enc) ?: "-",
            ).joinToString(" "),
        )
        writer.sync()
        return writer
    }

    /** Continues an existing journal (resume). */
    fun reopen(folderTransferId: String): Writer? = file(folderTransferId).takeIf(File::isFile)?.let { Writer(it, clock) }

    fun read(folderTransferId: String): Record? {
        val target = file(folderTransferId)
        if (!target.isFile) return null
        return runCatching { parse(folderTransferId, target.readLines(Charsets.UTF_8), target.lastModified()) }.getOrNull()
    }

    fun all(): List<Record> = directory.listFiles { candidate -> candidate.name.endsWith(".journal") }.orEmpty()
        .mapNotNull { read(it.name.removeSuffix(".journal")) ?: run { it.delete(); null } }

    fun delete(folderTransferId: String) {
        file(folderTransferId).delete()
    }

    /** Forget device: its journals go at once. Returns the removed records (their one-off grants can be released). */
    fun deleteForPeer(peerId: String): List<Record> = all().filter { it.header.peerId == peerId }.onEach { delete(it.folderTransferId) }

    /**
     * On start (and before a resume): drops journals older than the resume window, deletes unfinished files,
     * finishes interrupted replaces. [storeFor] opens the record's storage, or null when it is gone.
     * Returns the records that were dropped.
     */
    fun recover(storeFor: (Record) -> TreeStore?): List<Record> {
        val dropped = ArrayList<Record>()
        all().forEach { record ->
            if (!FolderTimeouts.canResume(record.lastProgressMillis, clock())) {
                delete(record.folderTransferId)
                dropped += record
                return@forEach
            }
            val store = runCatching { storeFor(record) }.getOrNull() ?: return@forEach
            repair(record, store)
        }
        return dropped
    }

    /** Deletes the record's unfinished files and finishes its interrupted replaces; the journal says so. */
    fun repair(record: Record, store: TreeStore) {
        if (record.openParts.isEmpty() && record.openReplaces.isEmpty()) return
        val writer = reopen(record.folderTransferId) ?: return
        record.openReplaces.forEach { (entry, replace) ->
            runCatching { store.idOf(replace.oldUri)?.let { runCatching { store.delete(it) } } }
            val part = store.idOf(replace.partUri)
            if (part != null && runCatching { store.publish(store.rename(part, replace.finalName)) }.isSuccess) writer.done(entry)
        }
        record.openParts.forEach { (entry, uri) ->
            if (entry in record.openReplaces) return@forEach
            store.idOf(uri)?.let { id -> runCatching { store.delete(id) } }
            writer.abandoned(entry)
        }
        writer.close()
    }

    private fun parse(id: String, lines: List<String>, modified: Long): Record? {
        val head = lines.firstOrNull()?.split(' ') ?: return null
        if (head.size < 10 || head[0] != "v1") return null
        val header = Header(
            peerId = dec(head[1]),
            manifestSha256 = dec(head[2]),
            createdAtMillis = head[3].toLongOrNull() ?: return null,
            placeId = dec(head[4]),
            choice = ConflictChoice.fromWire(head[5]) ?: return null,
            rootName = dec(head[6]),
            rootUri = dec(head[7]),
            destinationLabel = dec(head[8]),
            oneOffTree = head[9].takeIf { it != "-" }?.let(::dec),
        )
        val dirs = LinkedHashMap<Int, String>()
        val done = LinkedHashSet<Int>()
        val parts = LinkedHashMap<Int, String>()
        val replaces = LinkedHashMap<Int, Replace>()
        lines.drop(1).forEach { line ->
            val parts0 = line.split(' ')
            val entry = parts0.getOrNull(1)?.toIntOrNull() ?: return@forEach
            when (parts0[0]) {
                "d" -> parts0.getOrNull(2)?.let { dirs[entry] = dec(it) }
                "p" -> parts0.getOrNull(2)?.let { parts[entry] = dec(it) }
                "r" -> if (parts0.size >= 5) replaces[entry] = Replace(dec(parts0[2]), dec(parts0[3]), dec(parts0[4]))
                "f" -> {
                    done += entry
                    parts.remove(entry)
                    replaces.remove(entry)
                }
                "x" -> parts.remove(entry)
            }
        }
        return Record(id, header, modified, dirs, done, parts, replaces)
    }

    /** Appends to one journal. Not thread safe: the folder session's storage thread owns it. */
    class Writer internal constructor(private val file: File, private val clock: () -> Long) {
        private val output = FileOutputStream(file, true)
        private var unsynced = 0

        init {
            ownerOnly(file)
        }

        fun dir(entry: Int, uri: String) = line("d $entry ${enc(uri)}")
        fun part(entry: Int, uri: String) = line("p $entry ${enc(uri)}")
        fun replace(entry: Int, oldUri: String, partUri: String, finalName: String) =
            line("r $entry ${enc(oldUri)} ${enc(partUri)} ${enc(finalName)}")

        fun done(entry: Int) = line("f $entry")

        /** An unfinished file was deleted (failure or repair). */
        fun abandoned(entry: Int) = line("x $entry")

        internal fun line(text: String) {
            output.write((text + "\n").toByteArray(Charsets.UTF_8))
            file.setLastModified(clock())
            if (++unsynced >= 100) sync()
        }

        fun sync() {
            runCatching { output.fd.sync() }
            unsynced = 0
        }

        fun close() {
            sync()
            runCatching { output.close() }
        }
    }

    private companion object {
        /** "~" stands for an empty field; URLEncoder always encodes a real "~" as %7E. */
        fun enc(value: String): String = if (value.isEmpty()) "~" else URLEncoder.encode(value, "UTF-8")
        fun dec(value: String): String = if (value == "~") "" else URLDecoder.decode(value, "UTF-8")

        fun ownerOnly(target: File) {
            target.setReadable(false, false)
            target.setReadable(true, true)
            target.setWritable(false, false)
            target.setWritable(true, true)
            target.setExecutable(false, false)
        }
    }
}
