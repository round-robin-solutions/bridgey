package dev.bridgey.android.control

import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

/** Whether a Mac may see and control this phone without someone here (docs/protocol.md "Mac controls the phone"). */
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
 * and device transfer), separate from pairing and from settings sync, never synced or sent. Each choice is bound to the
 * Mac's pinned identity key. Thread safe.
 *
 * Unattended access (Rahul, 26 Nov): one switch, on by default. A Mac without a choice of its own (Default) follows it:
 * Allow without asking while it is on, Off while it is off. A choice made for a Mac (Off, Ask each time, Allow without
 * asking) stays as it is whatever the switch says. Agents and servers never get anything. A missing file is the defaults.
 * Everything else fails closed: an entry that does not decode is Off for that Mac whatever its key, and a file that
 * cannot be read turns the switch off and keeps every device ID it still names as Off, so turning the switch back on
 * never gives a lost Off away.
 */
class PhoneControlGrants(private val file: File) {
    /** [keyDigest] null: an entry that did not decode, Off for that Mac with any key. */
    private data class Entry(val mode: PhoneControlGrantMode, val keyDigest: String?)

    private class Stored(val unattended: Boolean, val entries: Map<String, Entry>)

    private val lock = Any()
    private var entries: Map<String, Entry>
    @Volatile var unattended: Boolean
        private set

    init {
        val stored = load()
        entries = stored.entries
        unattended = stored.unattended
    }

    @Volatile var revision = 0
        private set

    /** The grant [subject] has now: its own choice, else the switch. Off for an agent or a device without a key. */
    fun mode(subject: GrantSubject): PhoneControlGrantMode =
        resolve(choice(subject), unattended, subject.agent, !subject.identityKey.isNullOrEmpty())

    /** The choice made for [subject], or null for Default (none made, or made for another key). */
    fun choice(subject: GrantSubject): PhoneControlGrantMode? {
        val key = subject.identityKey?.takeIf { it.isNotEmpty() } ?: return null
        val entry = synchronized(lock) { entries[subject.deviceId] } ?: return null
        if (entry.keyDigest == null) return PhoneControlGrantMode.OFF
        return entry.mode.takeIf { entry.keyDigest == digest(key) }
    }

    /**
     * Sets [mode] for [subject]; null goes back to Default. False for an agent or a device without a pinned key.
     */
    fun set(subject: GrantSubject, mode: PhoneControlGrantMode?): Boolean {
        if (subject.agent) return false
        val key = subject.identityKey?.takeIf { it.isNotEmpty() } ?: return false
        synchronized(lock) {
            entries = if (mode == null) entries - subject.deviceId else entries + (subject.deviceId to Entry(mode, digest(key)))
            save()
            revision++
        }
        return true
    }

    /** Settings > Remote control > Unattended access. */
    fun setUnattended(on: Boolean) {
        synchronized(lock) {
            unattended = on
            save()
            revision++
        }
    }

    /** The Mac was forgotten: its choice goes with it. */
    fun remove(deviceId: String) {
        synchronized(lock) {
            if (deviceId !in entries) return
            entries = entries - deviceId
            save()
            revision++
        }
    }

    /** Device IDs with a choice of their own (for the log and Settings). */
    fun granted(): Set<String> = synchronized(lock) { entries.keys.toSet() }

    private fun load(): Stored {
        if (!file.isFile) return Stored(UNATTENDED_DEFAULT, emptyMap())
        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrDefault("")
        // Unreadable: the switch is off and every device the file still names stays Off.
        val damaged = { Stored(false, DEVICE_ID.findAll(text).associate { it.value.lowercase() to Entry(PhoneControlGrantMode.OFF, null) }) }
        return runCatching {
            val json = JSONObject(text)
            if (json.optInt("version") != 1) return damaged()
            // Beta 6 files have no switch: it is on, as on a new install. A switch that is not a boolean reads as off.
            val unattended = when (val stored = json.opt("unattended")) {
                null -> UNATTENDED_DEFAULT
                is Boolean -> stored
                else -> false
            }
            val devices = json.optJSONObject("devices") ?: return Stored(unattended, emptyMap())
            val loaded = devices.keys().asSequence().map { id ->
                // An entry that does not decode (an unknown mode, a bad key, not an object) is Off, never Default.
                val item = devices.optJSONObject(id)
                val mode = item?.let { PhoneControlGrantMode.fromWire(it.opt("mode")) }
                val key = item?.optString("key")?.takeIf { DIGEST.matches(it) }
                id to if (mode != null && key != null) Entry(mode, key) else Entry(PhoneControlGrantMode.OFF, null)
            }.toMap()
            Stored(unattended, loaded)
        }.getOrElse { damaged() }
    }

    private fun save() {
        val devices = JSONObject()
        entries.forEach { (id, entry) ->
            devices.put(id, JSONObject().put("mode", entry.mode.wire).apply { entry.keyDigest?.let { put("key", it) } })
        }
        val text = JSONObject().put("version", 1).put("unattended", unattended).put("devices", devices).toString()
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

        /** Unattended access on a new install and on files from before the switch. */
        const val UNATTENDED_DEFAULT = true

        private val DIGEST = Regex("[0-9a-f]{64}")
        private val DEVICE_ID = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

        fun digest(identityKey: String): String =
            MessageDigest.getInstance("SHA-256").digest(identityKey.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

        /**
         * What a Mac may do here: never anything for an agent, a server or a device without a pinned key; else its own
         * choice; else Allow without asking while unattended access is on, Off while it is off.
         */
        fun resolve(choice: PhoneControlGrantMode?, unattended: Boolean, agent: Boolean, keyKnown: Boolean): PhoneControlGrantMode = when {
            agent || !keyKnown -> PhoneControlGrantMode.OFF
            choice != null -> choice
            unattended -> PhoneControlGrantMode.ALWAYS
            else -> PhoneControlGrantMode.OFF
        }
    }
}
