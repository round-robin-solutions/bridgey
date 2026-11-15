package dev.bridgey.android.media

import android.util.AtomicFile
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import java.io.File
import org.json.JSONObject

/** Minimal no-backup crash recovery for the one media-stream mute owned by this feature. */
internal class CallMediaMuteJournal(file: File) {
    data class Record(val boot: Int, val previous: CallMediaMusicState, val applied: CallMediaMusicState?, val manualFix: Boolean = false)
    private val atomic = AtomicFile(file)

    /** Synchronous atomic/durable write BEFORE changing persistent Android stream mute state. */
    fun prepare(boot: Int, before: CallMediaMusicState): Boolean = write(Record(boot, before, null))
    fun applied(boot: Int, before: CallMediaMusicState, after: CallMediaMusicState): Boolean = write(Record(boot, before, after))
    fun clear() { atomic.delete() }
    fun exists(): Boolean = atomic.baseFile.exists() || File(atomic.baseFile.path + ".bak").exists()
    fun requireManualFix() { read()?.let { write(it.copy(manualFix = true)) } }

    fun read(): Record? = runCatching {
        val bytes = atomic.openRead().use { input ->
            val buffer = ByteArray(MAX_BYTES + 1)
            var size = 0
            while (size < buffer.size) {
                val read = input.read(buffer, size, buffer.size - size)
                if (read < 0) break
                if (read == 0) return@runCatching null
                size += read
            }
            buffer.copyOf(size)
        }
        if (bytes.size > MAX_BYTES) return@runCatching null
        val value = strictJsonObject(bytes) ?: return@runCatching null
        if (jsonInteger(value.opt("version")) != 1L) return@runCatching null
        val boot = jsonInteger(value.opt("boot"))?.takeIf { it in 0L..Int.MAX_VALUE.toLong() }?.toInt() ?: return@runCatching null
        val before = parseState(value.optJSONObject("previous") ?: return@runCatching null) ?: return@runCatching null
        val after = value.optJSONObject("applied")?.let(::parseState)
        if (value.has("applied") && after == null) return@runCatching null
        val manual = if (value.has("manualFix")) value.opt("manualFix") as? Boolean ?: return@runCatching null else false
        Record(boot, before, after, manual)
    }.getOrNull()

    private fun write(record: Record): Boolean {
        val value = JSONObject().put("version", 1).put("boot", record.boot).put("previous", state(record.previous)).put("manualFix", record.manualFix)
        record.applied?.let { value.put("applied", state(it)) }
        var output: java.io.FileOutputStream? = null
        return try {
            atomic.baseFile.parentFile?.mkdirs()
            val stream = atomic.startWrite()
            output = stream
            stream.write(value.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(stream)
            atomic.baseFile.setReadable(false, false); atomic.baseFile.setReadable(true, true)
            atomic.baseFile.setWritable(false, false); atomic.baseFile.setWritable(true, true)
            true
        } catch (_: Exception) {
            output?.let { runCatching { atomic.failWrite(it) } }
            false
        }
    }

    private fun state(value: CallMediaMusicState) = JSONObject().put("volume", value.volume).put("muted", value.muted).put("route", value.route)
    private fun parseState(value: JSONObject): CallMediaMusicState? {
        val volume = jsonInteger(value.opt("volume"))?.takeIf { it in 0L..1_000L }?.toInt() ?: return null
        val muted = value.opt("muted") as? Boolean ?: return null
        val route = (value.opt("route") as? String)?.takeIf { it.length in 1..512 } ?: return null
        return CallMediaMusicState(volume, muted, route, 0, false, false)
    }

    companion object { private const val MAX_BYTES = 2_048 }
}
