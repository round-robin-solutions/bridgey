package dev.bridgey.android

/**
 * What this phone knows about one connected device. Every device has its own copy, so one Mac's
 * features, battery or Find state never leak into another's.
 */
data class DeviceLinkState(
    val remoteFeatures: Map<BridgeyFeature, Boolean> = BridgeyFeature.entries.associateWith(::featureEnabledByLegacyPeer),
    /** The device advertised clipboard_files_draft1. */
    val remoteClipboardFiles: Boolean = false,
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

/** Why a pairing attempt ended; the UI shows [message]. */
enum class PairingFailure(val message: String) {
    COULD_NOT_CONNECT("Could not reach the device. Check that both are on the same Wi-Fi and Bridgey is open."),
    TIMEOUT("Pairing timed out. Start again and confirm the code on both devices within two minutes."),
    CANCELLED_REMOTE("Pairing was cancelled on the other device, or its code was rejected there."),
    CODE_REJECTED("The devices could not verify each other. Check that the codes match and try again."),
    IDENTITY_CHANGED("This device's identity changed. Forget it on both devices, then pair again."),
    CONNECTION_LOST("The connection was lost before pairing finished. Try again."),
    BUSY("Another pairing is waiting for confirmation. Finish or cancel it first."),
    INVALID("The other device sent something unexpected. Update Bridgey on both devices and try again."),
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

/** Per-device reconnect backoff for the side that dials (the lower device id). */
internal class ReconnectBackoff(private val delayFor: (Int) -> Long = ::reconnectDelayMillis) {
    private val attempts = HashMap<String, Int>()
    private val notBefore = HashMap<String, Long>()

    @Synchronized fun mayDial(deviceId: String, nowMillis: Long): Boolean = (notBefore[deviceId] ?: 0L) <= nowMillis

    /** A dial started: the next one waits for the backoff. */
    @Synchronized fun dialed(deviceId: String, nowMillis: Long) {
        val attempt = attempts[deviceId] ?: 0
        attempts[deviceId] = attempt + 1
        notBefore[deviceId] = nowMillis + delayFor(attempt)
    }

    @Synchronized fun connected(deviceId: String) {
        attempts.remove(deviceId)
        notBefore.remove(deviceId)
    }

    /** Milliseconds until [deviceId] may be dialled again, or 0. */
    @Synchronized fun waitMillis(deviceId: String, nowMillis: Long): Long = ((notBefore[deviceId] ?: 0L) - nowMillis).coerceAtLeast(0)
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
    pairing is PairingState.Failed -> "Not connected"
    else -> "Not connected · waiting for paired device"
}

private fun connectedSummary(connections: List<DeviceConnection>): String =
    if (connections.size == 1) "Connected to ${connections.single().peerName}" else "Connected to ${connections.size} devices"
