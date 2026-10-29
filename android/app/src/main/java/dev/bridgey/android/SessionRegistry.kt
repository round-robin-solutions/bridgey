package dev.bridgey.android

/**
 * What this phone knows about one connected device. Every device has its own copy, so one Mac's
 * features, battery or Find state never leak into another's.
 */
data class DeviceLinkState(
    val remoteFeatures: Map<BridgeyFeature, Boolean> = BridgeyFeature.entries.associateWith(::featureEnabledByLegacyPeer),
    /** The device advertised clipboard_files_draft1. */
    val remoteClipboardFiles: Boolean = false,
    /** The device advertised folders_draft1 and places_draft1 (draft folders protocol). */
    val remoteFolders: Boolean = false,
    val remotePlaces: Boolean = false,
    /** The device advertised folders_receive_draft1: it accepts folders from this phone (Files 2.0). */
    val remoteFoldersReceive: Boolean = false,
    /** The device advertised sms_codes_draft1: it reads codes and advertises for the companion link. */
    val remoteSmsCodes: Boolean = false,
    /** The device advertised links_open_draft1: Web links understands `action: "open"`. */
    val remoteLinksOpen: Boolean = false,
    /** The device advertised focus_sync_draft1: it understands focus.state. */
    val remoteFocusSync: Boolean = false,
    /** The device advertised updates_draft1: it sends updates.status and understands updates.start. */
    val remoteUpdates: Boolean = false,
    /** Its latest updates.status (version, channel, where its update stands), or null before the first. */
    val updateStatus: dev.bridgey.android.updates.UpdateStatus? = null,
    /** The device advertised settings_sync_draft1: it syncs settings with this phone (both its switches on). */
    val remoteSettingsSync: Boolean = false,
    val battery: RemoteBatteryStatus? = null,
    /** The device reported that it is ringing (Find device). */
    val ringing: Boolean = false,
)

/** A connected, authenticated device as the UI sees it. */
data class DeviceConnection(
    val deviceId: String,
    val peerName: String,
    val state: DeviceLinkState,
)

/**
 * Why a pairing did not finish. The words are in strings_pairing.xml (pairing_failed_*), with the other device's
 * name; the Mac shows the same ones.
 */
enum class PairingFailure {
    COULD_NOT_CONNECT,

    /** The handshake (before the code) took longer than 20 s. */
    TIMEOUT,

    /** The other end tapped Don't match. */
    MISMATCH_REMOTE,

    /** This end tapped Don't match. */
    MISMATCH_LOCAL,

    /** The code timer ran out: this end confirmed, the other did not. */
    TIMEOUT_REMOTE,

    /** The code timer ran out: the other end confirmed, this one did not. */
    TIMEOUT_LOCAL,
    TIMEOUT_NEITHER,
    CANCELLED_REMOTE,

    /** The other end runs a Bridgey without protocol 2 (0.9 or older). */
    OLD_VERSION,

    /** A committed offer got no answer: the other end closed or said nothing for 20 s (likely an older Bridgey). */
    NO_ANSWER,

    /** The other end did not tap Allow pairing within two minutes. */
    NOT_ALLOWED,
    CODE_REJECTED,
    IDENTITY_CHANGED,
    CONNECTION_LOST,
    BUSY,
    RATE_LIMITED,
    INVALID,
}

/**
 * Sessions keyed the way multi-device needs them: unauthenticated or pairing sessions on their
 * own, and one authenticated session per remote device id. Pure and thread-safe so it can be unit
 * tested; the coordinator owns sockets and threads.
 *
 * Duplicates: when two sockets authenticate as the same device (both sides dialled at once, or a
 * reconnect raced a stale socket), both ends must keep the same one or both die. The rule, applied
 * identically on the phone and the Mac: keep the socket dialled by the side with the lower device
 * id; if both were dialled by the same side, keep the newer one.
 */
internal class SessionRegistry<S : Any>(private val localDeviceId: String) {
    private class Entry<S>(val session: S, val initiatedLocally: Boolean) {
        var deviceId: String? = null
        var peerName: String = ""
        var state = DeviceLinkState()
    }

    sealed interface Admission<out S> {
        /** [session] is now the device's session; [replaced] (if any) must be closed. */
        data class Accepted<S>(val replaced: S?) : Admission<S>

        /** Another live session for the device wins; [session] must be closed. */
        data object Rejected : Admission<Nothing>
    }

    private val lock = Any()
    private val pending = LinkedHashMap<S, Entry<S>>()
    private val active = LinkedHashMap<String, Entry<S>>()

    fun addPending(session: S, initiatedLocally: Boolean) = synchronized(lock) {
        pending[session] = Entry(session, initiatedLocally)
    }

    /** Adds [session] as pending only when [admit], given the pending sessions, agrees; check and add are one step. */
    fun addPendingIf(session: S, initiatedLocally: Boolean, admit: (List<S>) -> Boolean): Boolean = synchronized(lock) {
        if (!admit(pending.keys.toList())) return@synchronized false
        pending[session] = Entry(session, initiatedLocally)
        true
    }

    fun pendingSessions(): List<S> = synchronized(lock) { pending.keys.toList() }

    fun isPending(session: S): Boolean = synchronized(lock) { session in pending }

    /** Moves an authenticated [session] to the device map, resolving duplicates. */
    fun authenticate(session: S, deviceId: String, peerName: String): Admission<S> = synchronized(lock) {
        val entry = pending.remove(session) ?: active.values.firstOrNull { it.session === session }
            ?: return Admission.Rejected
        entry.deviceId = deviceId
        entry.peerName = peerName
        val existing = active[deviceId]
        if (existing == null || existing.session === session) {
            active[deviceId] = entry
            return Admission.Accepted(null)
        }
        if (!prefers(entry, existing)) return Admission.Rejected
        // The survivor keeps what the device already reported (features, battery) until it updates.
        entry.state = existing.state
        active.remove(deviceId)
        active[deviceId] = entry
        Admission.Accepted(existing.session)
    }

    private fun prefers(candidate: Entry<S>, existing: Entry<S>): Boolean {
        val candidateLower = dialledByLowerId(candidate)
        val existingLower = dialledByLowerId(existing)
        return if (candidateLower != existingLower) candidateLower else true
    }

    private fun dialledByLowerId(entry: Entry<S>): Boolean {
        val remote = entry.deviceId ?: return false
        return if (entry.initiatedLocally) localDeviceId < remote else remote < localDeviceId
    }

    /**
     * Forgets [session]. Returns the device id when it was that device's live session (so the
     * device is now disconnected), or null when it was pending or already replaced.
     */
    fun remove(session: S): String? = synchronized(lock) {
        if (pending.remove(session) != null) return null
        val deviceId = active.entries.firstOrNull { it.value.session === session }?.key ?: return null
        active.remove(deviceId)
        deviceId
    }

    fun session(deviceId: String): S? = synchronized(lock) { active[deviceId]?.session }

    fun deviceIdOf(session: S): String? = synchronized(lock) {
        active.entries.firstOrNull { it.value.session === session }?.key
    }

    fun isActive(session: S): Boolean = synchronized(lock) { active.values.any { it.session === session } }

    fun connectedIds(): List<String> = synchronized(lock) { active.keys.toList() }

    fun connections(): List<DeviceConnection> = synchronized(lock) {
        active.values.map { DeviceConnection(it.deviceId!!, it.peerName, it.state) }
    }

    fun state(deviceId: String): DeviceLinkState? = synchronized(lock) { active[deviceId]?.state }

    fun update(deviceId: String, transform: (DeviceLinkState) -> DeviceLinkState): Boolean = synchronized(lock) {
        val entry = active[deviceId] ?: return false
        entry.state = transform(entry.state)
        true
    }

    /** The device outgoing actions aim at: [selected] while connected, else the latest connection. */
    fun target(selected: String?): String? = synchronized(lock) {
        selected?.takeIf(active::containsKey) ?: active.keys.lastOrNull()
    }

    /** Connected devices for a broadcast, in connection order, filtered by [include]. */
    fun broadcastTargets(include: (String, DeviceLinkState) -> Boolean): List<Pair<String, S>> = synchronized(lock) {
        active.values.filter { include(it.deviceId!!, it.state) }.map { it.deviceId!! to it.session }
    }

    fun clear(): List<S> = synchronized(lock) {
        val all = pending.keys.toList() + active.values.map { it.session }
        pending.clear()
        active.clear()
        all
    }
}

/** The foreground notification's status line: how many devices are connected, or the pairing step. */
internal fun connectionStatus(connections: List<DeviceConnection>, pairing: PairingState): String = when {
    pairing is PairingState.Verification -> if (connections.isEmpty()) {
        "Pairing confirmation required"
    } else {
        "${connectedSummary(connections)} · pairing confirmation required"
    }
    connections.size == 1 -> "Connected to ${connections.single().peerName}"
    connections.size > 1 -> connectedSummary(connections)
    pairing is PairingState.Connecting -> "Connecting to ${pairing.peerName}…"
    pairing is PairingState.WaitingForAllow -> "Waiting for ${pairing.peerName} to allow pairing"
    pairing is PairingState.Failed -> "Not connected"
    else -> "Not connected · waiting for paired device"
}

private fun connectedSummary(connections: List<DeviceConnection>): String =
    if (connections.size == 1) "Connected to ${connections.single().peerName}" else "Connected to ${connections.size} devices"
