package dev.bridgey.android.control

import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

/** Whether a Mac may control this phone (docs/protocol.md "Mac controls the phone"). Off until chosen. */
enum class PhoneControlGrantMode(val wire: String) {
    OFF("off"),
    ASK("ask"),
    ALWAYS("always"),
    ;

    /** A change that gives a Mac more than it had: refused while any Mac controls this phone. */
    fun raises(to: PhoneControlGrantMode): Boolean = to.ordinal > ordinal

    companion object {
        fun fromWire(value: Any?): PhoneControlGrantMode? = entries.firstOrNull { it.wire == value }
    }
}

/** Who a grant is for: the pinned device, its identity key, and whether it is an agent or a server. */
data class GrantSubject(val deviceId: String, val identityKey: String?, val agent: Boolean)

/**
 * Phone control grants, per Mac, in this phone's private storage: a file in the no-backup folder (outside Android backup
 * and device transfer), separate from pairing and from settings sync, never synced or sent. Each grant is bound to the
 * Mac's pinned identity key, so a Mac that pairs again with a different key has none. Agents and servers never have one.
 *
 * A device with no entry gets [fallback]: Off today. A later "all my devices" switch is a stored default read there for
 * non-agent devices; explicit per-device entries keep winning. Thread safe.
 */
class PhoneControlGrants(
    private val file: File,
    private val fallback: (GrantSubject) -> PhoneControlGrantMode = { PhoneControlGrantMode.OFF },
) {
    private data class Entry(val mode: PhoneControlGrantMode, val keyDigest: String)

    private val lock = Any()
    private var entries: Map<String, Entry> = load()

    @Volatile var revision = 0
        private set

    /** The grant [subject] has now. Off for an agent, a device without a key or a different key. */
    fun mode(subject: GrantSubject): PhoneControlGrantMode {
        if (subject.agent) return PhoneControlGrantMode.OFF
        val key = subject.identityKey?.takeIf { it.isNotEmpty() } ?: return PhoneControlGrantMode.OFF
        val entry = synchronized(lock) { entries[subject.deviceId] }
        if (entry == null) return fallback(subject).takeUnless { subject.agent } ?: PhoneControlGrantMode.OFF
        return if (entry.keyDigest == digest(key)) entry.mode else PhoneControlGrantMode.OFF
    }

    /** Sets [mode] for [subject]; false for an agent or a device without a pinned key. Off removes the entry. */
    fun set(subject: GrantSubject, mode: PhoneControlGrantMode): Boolean {
        if (subject.agent) return false
        val key = subject.identityKey?.takeIf { it.isNotEmpty() } ?: return false
        synchronized(lock) {
            entries = if (mode == PhoneControlGrantMode.OFF) entries - subject.deviceId else entries + (subject.deviceId to Entry(mode, digest(key)))
            save()
            revision++
        }
        return true
    }

    /** The Mac was forgotten: its grant goes with it. */
    fun remove(deviceId: String) {
        synchronized(lock) {
            if (deviceId !in entries) return
            entries = entries - deviceId
            save()
            revision++
        }
    }

    /** Device IDs with an explicit grant (for the log and Settings). */
    fun granted(): Set<String> = synchronized(lock) { entries.keys.toSet() }

    private fun load(): Map<String, Entry> = runCatching {
        if (!file.isFile) return emptyMap()
        val json = JSONObject(file.readText(Charsets.UTF_8))
        if (json.optInt("version") != 1) return emptyMap()
        val devices = json.optJSONObject("devices") ?: return emptyMap()
        devices.keys().asSequence().mapNotNull { id ->
            val item = devices.optJSONObject(id) ?: return@mapNotNull null
            val mode = PhoneControlGrantMode.fromWire(item.opt("mode"))?.takeIf { it != PhoneControlGrantMode.OFF } ?: return@mapNotNull null
            val key = item.optString("key").takeIf { it.length == 64 } ?: return@mapNotNull null
            id to Entry(mode, key)
        }.toMap()
    }.getOrDefault(emptyMap())

    private fun save() {
        val devices = JSONObject()
        entries.forEach { (id, entry) -> devices.put(id, JSONObject().put("mode", entry.mode.wire).put("key", entry.keyDigest)) }
        val text = JSONObject().put("version", 1).put("devices", devices).toString()
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(text, Charsets.UTF_8)
        if (!temp.renameTo(file)) {
            file.writeText(text, Charsets.UTF_8)
            temp.delete()
        }
    }

    companion object {
        const val FILE_NAME = "phone-control-grants.json"

        fun digest(identityKey: String): String =
            MessageDigest.getInstance("SHA-256").digest(identityKey.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}
