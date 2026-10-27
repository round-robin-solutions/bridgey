package dev.bridgey.android.sync

import android.content.SharedPreferences
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/** The two sync switches and "Choose what syncs", all on this device only. */
data class SyncSwitches(
    /** Settings > General > Sync settings with paired devices. On by default, fresh installs too (8.4). */
    val enabled: Boolean = true,
    /** Each device page's "Sync settings with this device"; absent means on. */
    val devices: Map<String, Boolean> = emptyMap(),
    /** Settings this device keeps to itself. */
    val excluded: Set<SyncKey> = emptySet(),
) {
    fun on(deviceId: String): Boolean = enabled && devices[deviceId] != false
}

/** One setting's sync line in Settings, with device names. */
data class SyncRowStatus(
    val waitingHere: Boolean = false,
    val differentOn: List<String> = emptyList(),
    val waitingOn: List<String> = emptyList(),
)

/** What Settings and the device pages show about sync. */
data class SyncUiState(
    val switches: SyncSwitches = SyncSwitches(),
    val rows: Map<SyncKey, SyncRowStatus> = emptyMap(),
    /** Connected devices whose latest features.update shows sync off (or an older build): "Off on <device>". */
    val offOn: Set<String> = emptySet(),
) {
    /** The sync mark shows on rows that sync. */
    fun syncs(key: SyncKey): Boolean = switches.enabled && key !in switches.excluded
    fun row(key: SyncKey): SyncRowStatus? = rows[key]?.takeIf { syncs(key) }
}

/**
 * Settings sync on the phone: the stored records and switches (`bridgey.sync`), when snapshots and updates go to
 * each Mac, what arrives from them, and what Settings shows. The coordinator owns the sessions and calls in; the
 * rules live in [SettingsSyncEngine].
 */
class SettingsSyncController(
    private val preferences: SharedPreferences,
    private val localDeviceId: String,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val debounceMillis: Long = SETTINGS_DEBOUNCE_MILLIS,
) {
    /** The coordinator's side: sessions, names and the peer's latest feature map. */
    interface Transport {
        fun send(deviceId: String, kind: String, payload: JSONObject, messageId: String): Boolean
        fun peerName(deviceId: String): String?
        /** Connected and authenticated devices. */
        fun connected(): Collection<String>
        /** The device's latest features.update shows settings_sync_draft1 true. */
        fun remoteOn(deviceId: String): Boolean
    }

    /** What a received settings.* message means for the session. */
    enum class Receipt { HANDLED, IGNORED }

    @Volatile var transport: Transport? = null

    /** A device's snapshot or update changed settings here: one activity item. */
    @Volatile var onSynced: (deviceId: String, deviceName: String, changes: List<SyncChange>) -> Unit = { _, _, _ -> }

    /** A device turned a feature on here; [waiting] when it needs a permission on this phone. */
    @Volatile var onTurnedOn: (deviceId: String, deviceName: String, key: SyncKey, waiting: Boolean) -> Unit = { _, _, _, _ -> }

    /** A switch changed: the coordinator sends features.update again. */
    @Volatile var onSwitchesChanged: () -> Unit = {}

    /** Diagnostics: event names, codes and counts only. */
    @Volatile var diagnostics: (event: String, outcome: String?, deviceId: String?) -> Unit = { _, _, _ -> }

    private val mutableSwitches = MutableStateFlow(loadSwitches())
    val switches: StateFlow<SyncSwitches> = mutableSwitches.asStateFlow()
    private val mutableUi = MutableStateFlow(SyncUiState(mutableSwitches.value))
    val ui: StateFlow<SyncUiState> = mutableUi.asStateFlow()

    @Volatile private var engine: SettingsSyncEngine? = null
    private var settings: Map<SyncKey, SyncedSetting> = emptyMap()
    private val lock = Any()
    private var flushJob: Job? = null
    private val rate = HashMap<String, ArrayDeque<Long>>()
    private val rateWarned = HashMap<String, Long>()
    private val stopped = HashSet<String>()

    /** Starts syncing with the settings this phone has. Call once, before sessions start. */
    fun attach(settings: Map<SyncKey, SyncedSetting>) = synchronized(lock) {
        this.settings = settings
        engine = SettingsSyncEngine(localDeviceId, clock, PreferencesStore(), settings) { mutableSwitches.value.excluded }
        publish()
    }

    fun record(key: SyncKey): SyncRecord? = engine?.record(key)

    /** settings_sync_draft1 for [deviceId]'s features.update. */
    fun advertised(deviceId: String): Boolean = engine != null && mutableSwitches.value.on(deviceId)

    fun setEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_ENABLED, enabled).apply()
        mutableSwitches.value = mutableSwitches.value.copy(enabled = enabled)
        switchesChanged()
    }

    fun setDeviceEnabled(deviceId: String, enabled: Boolean) {
        preferences.edit().putBoolean(KEY_DEVICE_PREFIX + deviceId, enabled).apply()
        mutableSwitches.value = mutableSwitches.value.copy(devices = mutableSwitches.value.devices + (deviceId to enabled))
        switchesChanged()
    }

    /** Choose what syncs: [sync] false keeps [key] on this phone. */
    fun setSyncs(key: SyncKey, sync: Boolean) {
        val excluded = if (sync) mutableSwitches.value.excluded - key else mutableSwitches.value.excluded + key
        preferences.edit().putStringSet(KEY_EXCLUDED, excluded.mapTo(HashSet()) { it.key }).apply()
        mutableSwitches.value = mutableSwitches.value.copy(excluded = excluded)
        // A setting that syncs again goes out as it is now; the peers decide by its stamp.
        scheduleFlush(immediately = true)
        publish()
    }

    /** Forget device: its switch and its session state go. */
    fun forget(deviceId: String) {
        preferences.edit().remove(KEY_DEVICE_PREFIX + deviceId).apply()
        mutableSwitches.value = mutableSwitches.value.copy(devices = mutableSwitches.value.devices - deviceId)
        sessionEnded(deviceId)
    }

    /** A synced setting may have changed here (Settings, setup, shortcuts): stamp it and send it after 500 ms. */
    fun localChanged() {
        val current = engine ?: return
        if (current.observeLocal()) scheduleFlush(immediately = false)
        publish()
    }

    /** A permission may have changed: the waiting list goes to the Macs when it differs. */
    fun permissionsChanged() {
        scheduleFlush(immediately = true)
        publish()
    }

    /** Apply to all: this phone's value goes to every Mac that syncs. */
    fun applyToAll(key: SyncKey) {
        val current = engine ?: return
        current.applyToAll(key)
        diagnostics("apply_to_all", key.token, null)
        scheduleFlush(immediately = true)
        publish()
    }

    /** The device's features.update arrived, or a switch changed: start or stop syncing with it. */
    fun peerChanged(deviceId: String) {
        val current = engine ?: return
        val link = transport ?: return
        val available = deviceId in link.connected() && advertised(deviceId) && link.remoteOn(deviceId) && deviceId !in synchronized(lock) { stopped }
        when {
            available && !current.isActive(deviceId) -> {
                val messageId = UUID.randomUUID().toString()
                val snapshot = current.start(deviceId, messageId)
                send(deviceId, SettingsSyncKinds.SNAPSHOT, settingsPayload(snapshot.records, snapshot.waiting, snapshot = true), messageId)
                diagnostics("snapshot_sent", "${snapshot.records.size}", deviceId)
            }
            !available && current.isActive(deviceId) -> current.stop(deviceId)
        }
        publish()
    }

    fun sessionEnded(deviceId: String) {
        engine?.stop(deviceId)
        synchronized(lock) {
            stopped.remove(deviceId)
            rate.remove(deviceId)
            rateWarned.remove(deviceId)
        }
        publish()
    }

    /**
     * A decrypted settings.* plaintext from [deviceId]. Ignored unless both sides advertise the key; over the rate
     * limit it is dropped (answered rate_limited once per window). Malformed payloads are answered settings.error.
     */
    fun receive(deviceId: String, kind: String, messageId: String, plaintext: ByteArray): Receipt {
        val current = engine ?: return Receipt.IGNORED
        if (!current.isActive(deviceId)) return Receipt.IGNORED
        if (!allow(deviceId)) return Receipt.IGNORED
        when (kind) {
            SettingsSyncKinds.SNAPSHOT, SettingsSyncKinds.UPDATE -> receiveRecords(current, deviceId, kind, messageId, plaintext)
            SettingsSyncKinds.ACK -> decodeSettingsAck(plaintext)?.let { current.receiveAck(deviceId, it) }
            SettingsSyncKinds.ERROR -> {
                val code = decodeSettingsError(plaintext) ?: return Receipt.IGNORED
                // Only a schema the Mac cannot read stops sync (until the next session); the others are logged.
                if (code == SettingsErrorCodes.UNSUPPORTED_SCHEMA) {
                    synchronized(lock) { stopped += deviceId }
                    current.stop(deviceId)
                }
                diagnostics("error_received", knownCode(code), deviceId)
            }
            else -> return Receipt.IGNORED
        }
        publish()
        return Receipt.HANDLED
    }

    private fun receiveRecords(current: SettingsSyncEngine, deviceId: String, kind: String, messageId: String, plaintext: ByteArray) {
        val decoded = decodeSettingsPayload(plaintext)
        val records = when (decoded) {
            SettingsPayloadDecoding.Invalid -> {
                send(deviceId, SettingsSyncKinds.ERROR, settingsErrorPayload(SettingsErrorCodes.INVALID_MESSAGE))
                diagnostics("payload_rejected", SettingsErrorCodes.INVALID_MESSAGE, deviceId)
                return
            }
            is SettingsPayloadDecoding.UnsupportedSchema -> {
                send(deviceId, SettingsSyncKinds.ERROR, settingsErrorPayload(SettingsErrorCodes.UNSUPPORTED_SCHEMA))
                diagnostics("payload_rejected", SettingsErrorCodes.UNSUPPORTED_SCHEMA, deviceId)
                return
            }
            is SettingsPayloadDecoding.Records -> decoded
        }
        val receipt = if (kind == SettingsSyncKinds.SNAPSHOT) {
            current.receiveSnapshot(deviceId, records.records, records.waiting)
        } else {
            current.receiveUpdate(deviceId, records.records, records.waiting)
        } ?: return
        send(deviceId, SettingsSyncKinds.ACK, settingsAckPayload(messageId, receipt.applied, receipt.kept))
        if (receipt.changes.isNotEmpty()) {
            val name = transport?.peerName(deviceId).orEmpty()
            diagnostics(if (kind == SettingsSyncKinds.SNAPSHOT) "snapshot_applied" else "update_applied", "${receipt.changes.size}", deviceId)
            onSynced(deviceId, name, receipt.changes)
            val waiting = current.waitingHere().toSet()
            receipt.changes.filter { it.key.feature && it.value == true }.forEach { change ->
                onTurnedOn(deviceId, name, change.key, change.key in waiting)
            }
        }
        // Relays what won here to the other Macs, and answers what this phone kept.
        scheduleFlush(immediately = true)
    }

    private fun switchesChanged() {
        onSwitchesChanged()
        transport?.connected()?.forEach(::peerChanged)
        publish()
    }

    private fun allow(deviceId: String): Boolean = synchronized(lock) {
        val now = clock()
        val window = rate.getOrPut(deviceId) { ArrayDeque() }
        while (window.isNotEmpty() && now - window.first() >= SETTINGS_RATE_WINDOW_MILLIS) window.removeFirst()
        if (window.size < SETTINGS_RATE_LIMIT) {
            window.addLast(now)
            return true
        }
        val warned = rateWarned[deviceId]
        if (warned == null || now - warned >= SETTINGS_RATE_WINDOW_MILLIS) {
            rateWarned[deviceId] = now
            send(deviceId, SettingsSyncKinds.ERROR, settingsErrorPayload(SettingsErrorCodes.RATE_LIMITED))
            diagnostics("rate_limited", null, deviceId)
        }
        false
    }

    private fun scheduleFlush(immediately: Boolean) {
        synchronized(lock) {
            flushJob?.cancel()
            flushJob = scope.launch {
                if (!immediately) delay(debounceMillis)
                flush()
            }
        }
    }

    /** Sends each ready Mac what it has not seen. Public for tests that run without a dispatcher. */
    fun flush() {
        val current = engine ?: return
        current.flush { UUID.randomUUID().toString() }.forEach { (deviceId, out) ->
            val (messageId, outgoing) = out
            send(deviceId, SettingsSyncKinds.UPDATE, settingsPayload(outgoing.records, outgoing.waiting, snapshot = false), messageId)
        }
        publish()
    }

    private fun send(deviceId: String, kind: String, payload: JSONObject, messageId: String = UUID.randomUUID().toString()) {
        transport?.send(deviceId, kind, payload, messageId)
    }

    private fun publish() {
        val link = transport
        val names = { id: String -> link?.peerName(id)?.takeIf(String::isNotBlank) ?: id.take(8) }
        val status = engine?.status().orEmpty()
        mutableUi.value = SyncUiState(
            switches = mutableSwitches.value,
            rows = status.mapValues { (_, value) -> SyncRowStatus(value.waitingHere, value.differentOn.map(names), value.waitingOn.map(names)) },
            offOn = link?.connected()?.filterTo(HashSet()) { !link.remoteOn(it) }.orEmpty(),
        )
    }

    private fun loadSwitches(): SyncSwitches {
        val devices = preferences.all.mapNotNull { (key, value) ->
            if (!key.startsWith(KEY_DEVICE_PREFIX) || value !is Boolean) return@mapNotNull null
            key.removePrefix(KEY_DEVICE_PREFIX).takeIf(String::isNotBlank)?.let { it to value }
        }.toMap()
        val excluded = preferences.getStringSet(KEY_EXCLUDED, emptySet()).orEmpty().mapNotNullTo(HashSet(), SyncKey::from)
        return SyncSwitches(preferences.getBoolean(KEY_ENABLED, true), devices, excluded)
    }

    private fun knownCode(code: String): String = code.takeIf {
        it == SettingsErrorCodes.UNSUPPORTED_SCHEMA || it == SettingsErrorCodes.INVALID_MESSAGE || it == SettingsErrorCodes.RATE_LIMITED
    } ?: "other"

    private inner class PreferencesStore : SyncRecordStore {
        override fun load(): Map<SyncKey, SyncRecord>? {
            if (!preferences.getBoolean(KEY_STAMPED, false)) return null
            return SyncKey.entries.mapNotNull { key ->
                val json = preferences.getString(KEY_RECORD_PREFIX + key.key, null) ?: return@mapNotNull null
                runCatching { SyncRecord.parse(key, JSONObject(json)) }.getOrNull()?.let { key to it }
            }.toMap()
        }

        override fun save(records: Map<SyncKey, SyncRecord>) {
            val editor = preferences.edit()
            records.forEach { (key, record) -> editor.putString(KEY_RECORD_PREFIX + key.key, record.toJson().toString()) }
            editor.putBoolean(KEY_STAMPED, true).apply()
        }
    }

    companion object {
        const val PREFERENCES = "bridgey.sync"
        const val KEY_ENABLED = "enabled"
        const val KEY_DEVICE_PREFIX = "device."
        const val KEY_EXCLUDED = "excluded"
        const val KEY_STAMPED = "stamped"
        const val KEY_RECORD_PREFIX = "record."
    }
}
