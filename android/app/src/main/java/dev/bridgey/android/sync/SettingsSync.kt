package dev.bridgey.android.sync

import dev.bridgey.android.JSON_MAX_SAFE_INTEGER
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONArray
import org.json.JSONObject

/*
 * Settings sync (draft settings_sync_draft1, docs/folders-and-settings-sync.md sections 4.9, 8.2, 8.4 and 8.5):
 * the wire format, the merge rules and the per-peer bookkeeping, kept free of Android so the unit tests and the
 * golden vectors run on the JVM. The Mac has the same rules in SettingsSync.swift.
 */

/** Draft, edition only: the device syncs settings and feature switches with that peer (both switches on). */
const val SETTINGS_SYNC_FEATURE_KEY = "settings_sync_draft1"

const val SETTINGS_SCHEMA = 1
const val SETTINGS_PAYLOAD_MAX_BYTES = 16_384
const val SETTINGS_REPLY_MAX_BYTES = 8_192
const val SETTINGS_MAX_RECORDS = 32
const val SETTINGS_MAX_WAITING = 32
const val SETTINGS_CHANGED_BY_MAX_BYTES = 128
const val SETTINGS_DEBOUNCE_MILLIS = 500L

/** At most this many settings.* messages per peer per [SETTINGS_RATE_WINDOW_MILLIS]; more are dropped. */
const val SETTINGS_RATE_LIMIT = 20
const val SETTINGS_RATE_WINDOW_MILLIS = 10_000L

/** The settings.* kinds (the contract scan reads this object). */
object SettingsSyncKinds {
    const val SNAPSHOT = "settings.snapshot"
    const val UPDATE = "settings.update"
    const val ACK = "settings.ack"
    const val ERROR = "settings.error"
}

object SettingsErrorCodes {
    const val UNSUPPORTED_SCHEMA = "unsupported_schema"
    const val INVALID_MESSAGE = "invalid_message"
    const val RATE_LIMITED = "rate_limited"
}

/**
 * The schema 1 allowlist, in schema order (also the order of activity tokens). [values] is set for string keys;
 * the rest are booleans. [token] names the key in an activity item's detail. [feature] marks the switches whose
 * remote turn-on posts a notification. Anything not listed here never syncs.
 */
enum class SyncKey(val key: String, val token: String, val default: Any, val values: List<String>? = null, val feature: Boolean = false) {
    FOLDER_DESTINATION("files.folder_destination", "folder_destination", "sender_picks", listOf("sender_picks", "receiver_asks", "fixed")),
    FOLDER_CONFLICT("files.folder_conflict", "folder_conflict", "ask", listOf("ask", "merge", "replace", "new_folder")),
    ACTIVITY_PREVIEWS("activity.previews", "previews", true),
    REDUCE_MOTION("display.reduce_motion", "reduce_motion", false),
    CLIPBOARD("feature.clipboard", "clipboard", false, feature = true),
    FILES("feature.files", "files", false, feature = true),
    NOTIFICATIONS("feature.notifications", "notifications", false, feature = true),
    BATTERY("feature.battery", "battery", false, feature = true),
    FIND_DEVICE("feature.find_device", "find_device", false, feature = true),
    PING("feature.ping", "ping", false, feature = true),
    LINKS("feature.links", "links", false, feature = true),
    MEDIA("feature.media", "media", false, feature = true),
    CALLS("feature.calls", "calls", false, feature = true),
    REMOTE_INPUT("feature.remote_input", "remote_input", false, feature = true),
    MAC_ACTIONS("feature.mac_actions", "mac_actions", false, feature = true),
    CAMERA("feature.camera", "camera", false, feature = true),
    AUTO_CLIPBOARD("clipboard.automatic", "auto_clipboard", true, feature = true),
    CLIPBOARD_FILES("clipboard.files", "clipboard_files", true, feature = true),
    FOCUS_SHARE("focus.share", "focus_share", false, feature = true),
    FOCUS_FOLLOW("focus.follow", "focus_follow", false, feature = true),
    CODES("codes.enabled", "codes", false, feature = true),
    /** Share screen with Macs here; Show phone screens on the Mac. Each share is still asked on the phone. */
    SCREEN("feature.screen", "screen", false, feature = true),
    SMS("feature.sms", "sms", false, feature = true),
    /** Update all devices automatically. It follows the release channel until chosen; a synced value is a choice. */
    AUTO_UPDATE_ALL("updates.auto_all", "auto_update_all", false),
    /** Connect away from home (connect_draft1): both ends need it on, so it follows the other devices. */
    CONNECT_AWAY("connect.away", "connect_away", false, feature = true),
    /** Appended, so the order of the earlier keys never changes. The same two switches as the Mac's Files card. */
    FOLDER_INCLUDE_HIDDEN("files.folder_include_hidden", "folder_include_hidden", false),
    FOLDER_INCLUDE_SYSTEM("files.folder_include_system", "folder_include_system", false),
    ;

    fun accepts(value: Any?): Boolean = if (values != null) value is String && value in values else value is Boolean

    /** The activity token value: 0/1 for switches, the position in [values] for choices. */
    fun index(value: Any): Int? = when {
        values != null -> values.indexOf(value).takeIf { it >= 0 }
        value is Boolean -> if (value) 1 else 0
        else -> null
    }

    fun valueAt(index: Int): Any? = if (values != null) values.getOrNull(index) else when (index) { 0 -> false; 1 -> true; else -> null }

    companion object {
        private val byKey = entries.associateBy { it.key }
        fun from(key: String): SyncKey? = byKey[key]
        fun fromToken(token: String): SyncKey? = entries.firstOrNull { it.token == token }
    }
}

/** Who changed a record and when: compared by [compareRecords]. */
data class SyncStamp(val changedAt: Long, val version: Long, val changedBy: String)

/** One synced setting as a device holds it. [value] is a Boolean or one of its key's strings. */
data class SyncRecord(val value: Any, val changedAt: Long, val version: Long, val changedBy: String) {
    val stamp: SyncStamp get() = SyncStamp(changedAt, version, changedBy)

    /** Someone chose this value (an edit, Apply to all or an upgrade stamp); version 0 was never chosen. */
    val chosen: Boolean get() = version > 0

    fun toJson(): JSONObject = JSONObject().put("value", value).put("changedAt", changedAt).put("version", version).put("changedBy", changedBy)

    companion object {
        fun unchosen(value: Any) = SyncRecord(value, 0, 0, "")

        /** A record from the wire for [key], or null when any field is missing, of the wrong type or out of range. */
        fun parse(key: SyncKey, json: Any?): SyncRecord? {
            val obj = json as? JSONObject ?: return null
            val value = obj.opt("value")?.takeIf { key.accepts(it) } ?: return null
            val changedAt = jsonInteger(obj.opt("changedAt"))?.takeIf { it in 0..JSON_MAX_SAFE_INTEGER } ?: return null
            val version = jsonInteger(obj.opt("version"))?.takeIf { it in 0..JSON_MAX_SAFE_INTEGER } ?: return null
            val changedBy = (obj.opt("changedBy") as? String)?.takeIf { it.toByteArray(Charsets.UTF_8).size <= SETTINGS_CHANGED_BY_MAX_BYTES } ?: return null
            return SyncRecord(value, changedAt, version, changedBy)
        }
    }
}

/** Positive when [a] wins: the later changedAt, then the higher version, then the larger changedBy in UTF-8 byte order. */
fun compareRecords(a: SyncStamp, b: SyncStamp): Int {
    if (a.changedAt != b.changedAt) return a.changedAt.compareTo(b.changedAt)
    if (a.version != b.version) return a.version.compareTo(b.version)
    return compareUtf8(a.changedBy, b.changedBy)
}

fun compareRecords(a: SyncRecord, b: SyncRecord): Int = compareRecords(a.stamp, b.stamp)

/** Unsigned byte order of the UTF-8 encodings (Kotlin's String order compares UTF-16 units, which differs above U+FFFF). */
fun compareUtf8(a: String, b: String): Int {
    val x = a.toByteArray(Charsets.UTF_8)
    val y = b.toByteArray(Charsets.UTF_8)
    for (i in 0 until minOf(x.size, y.size)) {
        val d = (x[i].toInt() and 0xFF) - (y[i].toInt() and 0xFF)
        if (d != 0) return d
    }
    return x.size - y.size
}

/** The record a local edit (or Apply to all) makes: timestamps never go backwards, the version always grows. */
fun stampLocal(current: SyncRecord, value: Any, now: Long, deviceId: String): SyncRecord {
    val changedAt = if (current.changedAt >= JSON_MAX_SAFE_INTEGER) JSON_MAX_SAFE_INTEGER else maxOf(now, current.changedAt + 1)
    return SyncRecord(value, changedAt, (current.version + 1).coerceAtMost(JSON_MAX_SAFE_INTEGER), deviceId)
}

/** What a snapshot record does here (8.4): never overwrite a chosen value. */
enum class SnapshotOutcome { ADOPT, DIFFERENT, SAME }

/** [same] says whether two values mean the same on this device (the Mac reads `sender_picks` as `fixed`). */
fun snapshotOutcome(local: SyncRecord, remote: SyncRecord, same: (Any, Any) -> Boolean = { a, b -> a == b }): SnapshotOutcome = when {
    local.stamp == remote.stamp -> SnapshotOutcome.SAME
    !local.chosen && remote.chosen -> SnapshotOutcome.ADOPT
    local.chosen && remote.chosen && !same(local.value, remote.value) -> SnapshotOutcome.DIFFERENT
    else -> SnapshotOutcome.SAME
}

/** A settings.snapshot or settings.update plaintext as it arrives. */
sealed interface SettingsPayloadDecoding {
    data class Records(
        val records: Map<SyncKey, SyncRecord>,
        val waiting: List<SyncKey>,
        val skipped: Int,
        /** First connect (8.4): the sender has no answer for the receiver yet, and none for any device. */
        val first: Boolean = false,
        val new: Boolean = false,
        /** The asker's person answered "Use the same settings as <device>?". */
        val answered: Boolean = false,
    ) : SettingsPayloadDecoding
    data class UnsupportedSchema(val schema: Long) : SettingsPayloadDecoding
    data object Invalid : SettingsPayloadDecoding
}

fun decodeSettingsPayload(plaintext: ByteArray): SettingsPayloadDecoding {
    if (plaintext.size > SETTINGS_PAYLOAD_MAX_BYTES) return SettingsPayloadDecoding.Invalid
    val payload = strictJsonObject(plaintext) ?: return SettingsPayloadDecoding.Invalid
    val schema = jsonInteger(payload.opt("schema")) ?: return SettingsPayloadDecoding.Invalid
    val entries = payload.opt("records") as? JSONObject ?: return SettingsPayloadDecoding.Invalid
    if (schema != SETTINGS_SCHEMA.toLong()) return SettingsPayloadDecoding.UnsupportedSchema(schema)
    if (entries.length() > SETTINGS_MAX_RECORDS) return SettingsPayloadDecoding.Invalid
    val waitingArray = payload.opt("waiting") as? JSONArray
    if (waitingArray != null && waitingArray.length() > SETTINGS_MAX_WAITING) return SettingsPayloadDecoding.Invalid
    val records = LinkedHashMap<SyncKey, SyncRecord>()
    var skipped = 0
    entries.keys().forEach { name ->
        val key = SyncKey.from(name)
        val record = key?.let { SyncRecord.parse(it, entries.opt(name)) }
        if (key == null || record == null) skipped++ else records[key] = record
    }
    val waiting = waitingArray?.let { array -> (0 until array.length()).mapNotNull { (array.opt(it) as? String)?.let(SyncKey::from) }.toSet() }.orEmpty()
    return SettingsPayloadDecoding.Records(
        SyncKey.entries.filter { it in records }.associateWith { records.getValue(it) },
        SyncKey.entries.filter { it in waiting },
        skipped,
        first = payload.opt("first") == true,
        new = payload.opt("new") == true,
        answered = payload.opt("answered") == true,
    )
}

fun settingsPayload(records: Map<SyncKey, SyncRecord>, waiting: Collection<SyncKey>, snapshot: Boolean, out: SyncOutgoing? = null): JSONObject {
    val values = JSONObject()
    SyncKey.entries.forEach { key -> records[key]?.let { values.put(key.key, it.toJson()) } }
    val payload = JSONObject().put("schema", SETTINGS_SCHEMA)
    if (snapshot) payload.put("maxSchema", SETTINGS_SCHEMA)
    payload.put("records", values).put("waiting", JSONArray(SyncKey.entries.filter { it in waiting }.map { it.key }))
    if (out?.first == true) payload.put("first", true)
    if (out?.new == true) payload.put("new", true)
    if (out?.answered == true) payload.put("answered", true)
    return payload
}

fun settingsPayload(out: SyncOutgoing, snapshot: Boolean): JSONObject = settingsPayload(out.records, out.waiting, snapshot, out)

/** Who asks "Use the same settings as <device>?" on a first connect, seen from this device (vectors settingsAsker). */
enum class SyncAsker { LOCAL, REMOTE, NONE }

fun settingsAsker(localFirst: Boolean, localNew: Boolean, localIsPhone: Boolean, remoteFirst: Boolean, remoteNew: Boolean): SyncAsker = when {
    !localFirst || !remoteFirst -> SyncAsker.NONE
    localNew && !remoteNew -> SyncAsker.LOCAL
    !localNew && remoteNew -> SyncAsker.REMOTE
    localNew && remoteNew -> if (localIsPhone) SyncAsker.LOCAL else SyncAsker.REMOTE
    else -> SyncAsker.NONE
}

/** The first-connect answer kept per device: Use these, Keep mine, the other device asked, or nobody had to. */
object SyncAnswers {
    const val USE = "use"
    const val KEEP = "keep"
    const val PEER = "peer"
    const val AUTO = "auto"
}

/** First-connect answers between launches. Kept through Reset > Settings; Forget removes one. */
interface SyncAnswerStore {
    fun load(): Map<String, String>
    fun save(answers: Map<String, String>)
}

fun settingsAckPayload(ackOf: String, applied: Collection<SyncKey>, kept: Collection<SyncKey>): JSONObject = JSONObject()
    .put("schema", SETTINGS_SCHEMA)
    .put("ackOf", ackOf)
    .put("applied", JSONArray(SyncKey.entries.filter { it in applied }.map { it.key }))
    .put("kept", JSONArray(SyncKey.entries.filter { it in kept }.map { it.key }))

fun settingsErrorPayload(code: String): JSONObject = JSONObject().put("schema", SETTINGS_SCHEMA).put("code", code).put("maxSchema", SETTINGS_SCHEMA)

/** A settings.ack: the acknowledged message and the keys the peer applied. Null when malformed. */
data class SettingsAck(val ackOf: String, val applied: List<SyncKey>, val kept: List<SyncKey>)

fun decodeSettingsAck(plaintext: ByteArray): SettingsAck? {
    if (plaintext.size > SETTINGS_REPLY_MAX_BYTES) return null
    val payload = strictJsonObject(plaintext) ?: return null
    val ackOf = (payload.opt("ackOf") as? String)?.takeIf { it.isNotEmpty() && it.length <= 128 } ?: return null
    fun keys(name: String): List<SyncKey> {
        val array = payload.opt(name) as? JSONArray ?: return emptyList()
        return (0 until minOf(array.length(), SETTINGS_MAX_RECORDS)).mapNotNull { (array.opt(it) as? String)?.let(SyncKey::from) }
    }
    return SettingsAck(ackOf, keys("applied"), keys("kept"))
}

/** A settings.error's code (at most 64 bytes), or null when malformed. */
fun decodeSettingsError(plaintext: ByteArray): String? {
    if (plaintext.size > SETTINGS_REPLY_MAX_BYTES) return null
    return (strictJsonObject(plaintext)?.opt("code") as? String)?.takeIf { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= 64 }
}

/** One synced setting as this device holds it. Keys this device has no setting for are stored and relayed only. */
interface SyncedSetting {
    /** The current value, in its wire form. */
    fun read(): Any

    /** True when the setting already does what [value] means here. */
    fun matches(value: Any): Boolean = read() == value

    /** Applies a value from another device. */
    fun write(value: Any)

    /** The person stored this setting before (setup, Settings), so the upgrade stamp counts it as chosen. */
    fun stored(): Boolean

    /** On here but waiting for a permission only this device can give. */
    fun waitingForPermission(): Boolean = false

    /**
     * For a setting that follows something else until the person chooses (Update all devices automatically follows
     * the release channel): true while it follows, false once chosen; null for every other setting. While it follows,
     * nothing here is a choice to send, and only a chosen value from another device is applied (it then counts as
     * this device's choice too).
     */
    fun followsDefault(): Boolean? = null
}

/** Where records live between launches. */
interface SyncRecordStore {
    /** Null when this install has not stamped its records yet (the first launch of a build with sync). */
    fun load(): Map<SyncKey, SyncRecord>?
    fun save(records: Map<SyncKey, SyncRecord>)
}

/** One applied change: the setting and its new value. */
data class SyncChange(val key: SyncKey, val value: Any)

/** What happened to a received snapshot or update. */
data class SyncReceipt(
    /** Keys the receiver took (adopted or won), for the ack. */
    val applied: List<SyncKey>,
    /** Keys where the receiver kept its own record (it won, or both chose differently). */
    val kept: List<SyncKey>,
    /** Applied keys whose value changed here, for the activity stream. */
    val changes: List<SyncChange>,
    /** First connect: this device must ask "Use the same settings as <device>?" before anything moves. */
    val question: Boolean = false,
)

/** A settings.update to send to one peer. */
data class SyncOutgoing(
    val records: Map<SyncKey, SyncRecord>,
    val waiting: List<SyncKey>,
    val first: Boolean = false,
    val new: Boolean = false,
    val answered: Boolean = false,
)

/** Per setting, what the other devices say: shown under the row in Settings. */
data class SyncKeyStatus(
    /** On here but waiting for a permission on this device. */
    val waitingHere: Boolean = false,
    /** Ready peers that hold a different value (Apply to all settles it). */
    val differentOn: List<String> = emptyList(),
    /** Peers where this setting is on but waits for a permission there. */
    val waitingOn: List<String> = emptyList(),
)

/**
 * The records and the per-peer bookkeeping. Thread-safe; the controller sends what it returns.
 *
 * Per peer and per session: [Peer.sent] and [Peer.received] hold the stamp of every record sent to and received
 * from that peer, and a record goes out only when it matches neither, so updates cannot ping-pong and winning
 * records reach every other peer (relaying). A peer is ready once its snapshot arrived; nothing but the snapshot
 * goes to it before that, so a relayed edit can never overwrite a value it chose while offline.
 */
class SettingsSyncEngine(
    private val localDeviceId: String,
    private val clock: () -> Long,
    private val store: SyncRecordStore,
    private val settings: Map<SyncKey, SyncedSetting>,
    /** Keys this device keeps to itself ("Choose what syncs"). */
    private val excluded: () -> Set<SyncKey> = { emptySet() },
    private val answers: SyncAnswerStore = object : SyncAnswerStore {
        private var saved: Map<String, String> = emptyMap()
        override fun load() = saved
        override fun save(answers: Map<String, String>) { saved = answers }
    },
    /** When both devices are new, the phone asks (8.4). */
    private val isPhone: Boolean = true,
) {
    private class Peer {
        var ready = false
        /** First connect: this device asks its person (true), or waits for the other device's answer (false). */
        var asking = false
        var waitingForAnswer = false
        /** The next update tells the other device the person answered. */
        var sendAnswered = false
        /** What this device's snapshot said, so both sides pick the asker from the same facts. */
        var sentFirst = false
        var sentNew = false
        val sent = HashMap<SyncKey, SyncStamp>()
        val received = HashMap<SyncKey, SyncStamp>()
        val known = HashMap<SyncKey, SyncRecord>()
        var waiting: List<SyncKey> = emptyList()
        var waitingSent: List<SyncKey>? = null
        val inflight = LinkedHashMap<String, Map<SyncKey, SyncRecord>>()
    }

    private val records: MutableMap<SyncKey, SyncRecord> = load()
    private val peers = LinkedHashMap<String, Peer>()
    private val answered: MutableMap<String, String> = LinkedHashMap(answers.load())

    @Synchronized fun answer(peerId: String): String? = answered[peerId]

    /** Devices whose first-connect question is open. */
    @Synchronized fun questions(): List<String> = peers.filter { it.value.asking }.keys.toList()

    /** Forget device: its first-connect answer goes too. */
    @Synchronized fun forget(peerId: String) {
        peers.remove(peerId)
        if (answered.remove(peerId) != null) answers.save(answered)
    }

    private fun remember(peerId: String, answer: String) {
        answered[peerId] = answer
        answers.save(answered)
    }

    private fun load(): MutableMap<SyncKey, SyncRecord> {
        val stored = store.load()
        val result = LinkedHashMap<SyncKey, SyncRecord>()
        SyncKey.entries.forEach { key ->
            val setting = settings[key]
            result[key] = stored?.get(key) ?: when {
                // The first launch with sync (or with this key): what the person stored before counts as chosen (8.4).
                setting != null && setting.stored() -> SyncRecord(setting.read(), 1, 1, localDeviceId)
                setting != null -> SyncRecord.unchosen(setting.read())
                else -> SyncRecord.unchosen(key.default)
            }
        }
        if (stored == null || stored.keys != result.keys) store.save(result)
        return result
    }

    @Synchronized fun record(key: SyncKey): SyncRecord = records.getValue(key)

    @Synchronized fun records(): Map<SyncKey, SyncRecord> = LinkedHashMap(records)

    /** Stamps every setting that changed here since its record (Settings, setup, shortcuts). True when any did. */
    @Synchronized fun observeLocal(): Boolean {
        var changed = false
        settings.forEach { (key, setting) ->
            val current = records.getValue(key)
            when (setting.followsDefault()) {
                // Following the channel: not a choice, so nothing to send.
                true -> return@forEach
                // Chosen here: send it unless the record already holds this choice.
                false -> if (current.chosen && setting.matches(current.value)) return@forEach
                null -> if (setting.matches(current.value)) return@forEach
            }
            records[key] = stampLocal(current, setting.read(), clock(), localDeviceId)
            changed = true
        }
        if (changed) store.save(records)
        return changed
    }

    /**
     * Apply to all: this device's value becomes a new edit, stamped above every record the peers hold for the key, so
     * it wins on each of them even when one's clock runs ahead.
     */
    @Synchronized fun applyToAll(key: SyncKey) {
        val current = records.getValue(key)
        val newest = peers.values.mapNotNull { it.known[key] }.fold(current) { a, b -> if (compareRecords(b, a) > 0) b else a }
        val setting = settings[key]
        val value = setting?.read() ?: current.value
        records[key] = stampLocal(newest, value, clock(), localDeviceId)
        store.save(records)
        // Apply to all is a choice: a setting that followed its default here keeps this value from now on.
        if (setting?.followsDefault() == true) setting.write(value)
    }

    /** Keys that are on here but wait for a permission (never the excluded ones). */
    @Synchronized fun waitingHere(): List<SyncKey> {
        val hidden = excluded()
        return SyncKey.entries.filter { it !in hidden && settings[it]?.waitingForPermission() == true }
    }

    @Synchronized fun isActive(peerId: String): Boolean = peerId in peers

    @Synchronized fun isReady(peerId: String): Boolean = peers[peerId]?.ready == true

    @Synchronized fun activePeers(): List<String> = peers.keys.toList()

    /** Sync became available with [peerId]: its snapshot, sent as [messageId] (its ack says what the peer adopted). */
    @Synchronized fun start(peerId: String, messageId: String): SyncOutgoing {
        val peer = Peer().also { peers[peerId] = it }
        val hidden = excluded()
        val out = SyncKey.entries.filter { it !in hidden }.associateWith { records.getValue(it) }
        out.forEach { (key, record) -> peer.sent[key] = record.stamp }
        peer.inflight[messageId] = out
        val waiting = waitingHere()
        peer.waitingSent = waiting
        peer.sentFirst = peerId !in answered
        peer.sentNew = answered.isEmpty()
        return SyncOutgoing(out, waiting, first = peer.sentFirst, new = peer.sentNew)
    }

    /** Sync went off for [peerId], or its session ended: the next start sends a fresh snapshot. */
    @Synchronized fun stop(peerId: String) {
        peers.remove(peerId)
    }

    @Synchronized fun receiveSnapshot(
        peerId: String,
        incoming: Map<SyncKey, SyncRecord>,
        waiting: List<SyncKey>,
        remoteFirst: Boolean = false,
        remoteNew: Boolean = false,
    ): SyncReceipt? {
        val peer = peers[peerId] ?: return null
        peer.waiting = waiting
        val hidden = excluded()
        val asker = settingsAsker(peer.sentFirst, peer.sentNew, isPhone, remoteFirst, remoteNew)
        if (asker == SyncAsker.NONE) {
            if (peerId !in answered) remember(peerId, SyncAnswers.AUTO)
        } else {
            // First connect: nothing moves either way until the person answers on the asking device.
            incoming.forEach { (key, remote) ->
                if (key in hidden) return@forEach
                peer.received[key] = remote.stamp
                peer.known[key] = remote
            }
            if (asker == SyncAsker.REMOTE) {
                peer.waitingForAnswer = true
            } else if (differing(peer).isEmpty()) {
                // Nothing differs: no question.
                remember(peerId, SyncAnswers.USE)
                peer.ready = true
                peer.sendAnswered = true
            } else {
                peer.asking = true
            }
            return SyncReceipt(emptyList(), emptyList(), emptyList(), question = peer.asking)
        }
        val applied = ArrayList<SyncKey>()
        val kept = ArrayList<SyncKey>()
        val changes = ArrayList<SyncChange>()
        incoming.forEach { (key, remote) ->
            if (key in hidden) return@forEach
            peer.received[key] = remote.stamp
            peer.known[key] = remote
            val local = records.getValue(key)
            when (snapshotOutcome(local, remote) { a, b -> sameHere(key, a, b) }) {
                SnapshotOutcome.ADOPT -> {
                    take(key, remote, changes)
                    applied += key
                }
                SnapshotOutcome.DIFFERENT -> {
                    // Both chose: neither side pushes its value over the other's until Apply to all or a new edit.
                    peer.sent[key] = local.stamp
                    kept += key
                }
                SnapshotOutcome.SAME -> Unit
            }
        }
        peer.ready = true
        if (applied.isNotEmpty()) store.save(records)
        return SyncReceipt(applied, kept, changes)
    }

    /**
     * The person answered "Use the same settings as <device>?": [use] takes that device's value for every setting
     * that differs, features included; otherwise both keep theirs and Settings shows where they differ.
     */
    @Synchronized fun answer(peerId: String, use: Boolean): SyncReceipt? {
        val peer = peers[peerId]?.takeIf { it.asking } ?: return null
        val changes = ArrayList<SyncChange>()
        val applied = ArrayList<SyncKey>()
        differing(peer).forEach { key ->
            if (use) {
                take(key, peer.known.getValue(key), changes)
                applied += key
                // Sent back once in the answered update, so the other device knows this side now holds it.
                peer.received.remove(key)
            } else {
                pinKept(peer, key)
            }
        }
        store.save(records)
        remember(peerId, if (use) SyncAnswers.USE else SyncAnswers.KEEP)
        peer.asking = false
        peer.ready = true
        peer.sendAnswered = true
        return SyncReceipt(applied, emptyList(), changes)
    }

    /**
     * Keep mine: a differing value nobody chose here becomes chosen (`changedAt 1, version 1`), so a later snapshot does
     * not quietly take the other device's value; it is not sent, so neither side pushes over the other.
     */
    private fun pinKept(peer: Peer, key: SyncKey) {
        if (!records.getValue(key).chosen) records[key] = SyncRecord(localValue(key), 1, 1, localDeviceId)
        // Keep mine on a setting that follows its default: what it does here becomes its choice.
        settings[key]?.takeIf { it.followsDefault() == true }?.write(records.getValue(key).value)
        peer.sent[key] = records.getValue(key).stamp
    }

    /**
     * What [key] does here: the setting's own value while it follows its default (its record is not stamped then),
     * else the record's.
     */
    private fun localValue(key: SyncKey): Any =
        settings[key]?.takeIf { it.followsDefault() == true }?.read() ?: records.getValue(key).value

    /**
     * A setting that follows its default here, against a value nobody chose there: each device follows its own
     * default (Update all devices automatically, its own channel), so it is not a difference to ask about or show.
     */
    private fun bothFollow(key: SyncKey, remote: SyncRecord): Boolean = settings[key]?.followsDefault() == true && !remote.chosen

    /** Non-excluded keys whose value on [peer] does something else here. */
    private fun differing(peer: Peer): List<SyncKey> {
        val hidden = excluded()
        return SyncKey.entries.filter { key ->
            key !in hidden && peer.known[key]?.let { !bothFollow(key, it) && !sameHere(key, localValue(key), it.value) } == true
        }
    }

    @Synchronized fun receiveUpdate(
        peerId: String,
        incoming: Map<SyncKey, SyncRecord>,
        waiting: List<SyncKey>,
        answeredThere: Boolean = false,
    ): SyncReceipt? {
        val peer = peers[peerId] ?: return null
        peer.waiting = waiting
        val hidden = excluded()
        if (peer.waitingForAnswer && answeredThere) {
            // The other device's person answered: from now on sync runs, and this side never pushes over the answer.
            differing(peer).forEach { key -> pinKept(peer, key) }
            store.save(records)
            remember(peerId, SyncAnswers.PEER)
            peer.waitingForAnswer = false
            peer.ready = true
        }
        if (!peer.ready) {
            incoming.forEach { (key, remote) ->
                if (key in hidden) return@forEach
                peer.received[key] = remote.stamp
                peer.known[key] = remote
            }
            return SyncReceipt(emptyList(), emptyList(), emptyList())
        }
        val applied = ArrayList<SyncKey>()
        val kept = ArrayList<SyncKey>()
        val changes = ArrayList<SyncChange>()
        incoming.forEach { (key, remote) ->
            if (key in hidden) return@forEach
            peer.received[key] = remote.stamp
            peer.known[key] = remote
            val order = compareRecords(remote, records.getValue(key))
            when {
                order > 0 -> {
                    take(key, remote, changes)
                    applied += key
                }
                order < 0 -> kept += key
            }
        }
        if (applied.isNotEmpty()) store.save(records)
        return SyncReceipt(applied, kept, changes)
    }

    /** A settings.ack from [peerId]: the keys it applied now hold what was sent. */
    @Synchronized fun receiveAck(peerId: String, ack: SettingsAck) {
        val peer = peers[peerId] ?: return
        val sent = peer.inflight.remove(ack.ackOf) ?: return
        ack.applied.forEach { key -> sent[key]?.let { peer.known[key] = it } }
    }

    /**
     * What each ready peer has not seen yet: records whose stamp it neither sent nor received, and the waiting list
     * when it changed. Marks them sent under [messageIds] (one new ID per peer).
     */
    @Synchronized fun flush(messageId: () -> String): Map<String, Pair<String, SyncOutgoing>> {
        val hidden = excluded()
        val waiting = waitingHere()
        val out = LinkedHashMap<String, Pair<String, SyncOutgoing>>()
        peers.forEach { (id, peer) ->
            if (!peer.ready) return@forEach
            val pending = SyncKey.entries.filter { it !in hidden }.mapNotNull { key ->
                val record = records.getValue(key)
                key.takeIf { record.stamp != peer.sent[key] && record.stamp != peer.received[key] }?.let { it to record }
            }.toMap()
            if (pending.isEmpty() && waiting == peer.waitingSent && !peer.sendAnswered) return@forEach
            val messageIdForPeer = messageId()
            pending.forEach { (key, record) -> peer.sent[key] = record.stamp }
            peer.waitingSent = waiting
            if (pending.isNotEmpty()) {
                peer.inflight[messageIdForPeer] = pending
                while (peer.inflight.size > 64) peer.inflight.remove(peer.inflight.keys.first())
            }
            out[id] = messageIdForPeer to SyncOutgoing(pending, waiting, answered = peer.sendAnswered)
            peer.sendAnswered = false
        }
        return out
    }

    /** Per key, what the ready peers say (only keys with something to show). */
    @Synchronized fun status(): Map<SyncKey, SyncKeyStatus> {
        val hidden = excluded()
        val waitingHere = waitingHere().toSet()
        return SyncKey.entries.filter { it !in hidden }.mapNotNull { key ->
            val local = localValue(key)
            // Any value that differs shows, chosen or not, until Apply to all or an edit settles it.
            val different = peers.filter { (_, peer) ->
                peer.ready && peer.known[key]?.let { known -> !bothFollow(key, known) && !sameHere(key, local, known.value) } == true
            }.keys.toList()
            val waitingOn = peers.filter { (_, peer) -> key in peer.waiting }.keys.toList()
            val status = SyncKeyStatus(key in waitingHere, different, waitingOn)
            if (status == SyncKeyStatus()) null else key to status
        }.toMap()
    }

    private fun take(key: SyncKey, remote: SyncRecord, changes: MutableList<SyncChange>) {
        val setting = settings[key]
        val before = setting?.read()
        // The record first, so the setting's observer sees a match and never stamps it again.
        records[key] = remote
        val follows = setting?.followsDefault() == true
        // A setting that follows its default takes only a chosen value, which then becomes its choice here.
        if (setting != null && (if (follows) remote.chosen else !setting.matches(remote.value))) setting.write(remote.value)
        // Only settings this device has count as changes here; the rest are stored and relayed.
        if (setting != null && setting.read() != before) changes += SyncChange(key, remote.value)
    }

    private fun sameHere(key: SyncKey, a: Any, b: Any): Boolean {
        if (a == b) return true
        val setting = settings[key] ?: return false
        // Two values that do the same thing here (the Mac reads sender_picks as fixed) are not different.
        return setting.matches(a) && setting.matches(b)
    }
}

/** The activity detail of a settings_synced item: `<token>=<index>` for each change, in schema order. */
object SyncDetail {
    private val pattern = Regex("^[a-z_]{1,24}=[0-9]{1,2}(,[a-z_]{1,24}=[0-9]{1,2}){0,31}$")

    fun encode(changes: List<SyncChange>): String? = SyncKey.entries.mapNotNull { key ->
        changes.lastOrNull { it.key == key }?.let { change -> key.index(change.value)?.let { "${key.token}=$it" } }
    }.joinToString(",").takeIf { it.isNotEmpty() && pattern.matches(it) }

    fun decode(value: String?): List<SyncChange> {
        if (value == null || !pattern.matches(value)) return emptyList()
        return value.split(',').mapNotNull { token ->
            val key = SyncKey.fromToken(token.substringBefore('=')) ?: return@mapNotNull null
            key.valueAt(token.substringAfter('=').toInt())?.let { SyncChange(key, it) }
        }
    }

    fun clean(value: String?): String? = value?.takeIf { pattern.matches(it) }
}
