package dev.bridgey.android.activity

import dev.bridgey.android.FileTransferState
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.PairingState
import dev.bridgey.android.PeerActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/** How a finished transfer ends up in the stream. */
enum class TransferOutcome { SENT, RECEIVED, FAILED }

/**
 * Maps a transfer's final state to a stream event, or null while it runs, when the user
 * cancelled it, or when it can be retried (then its card with Retry is the record).
 * The status strings are PairingCoordinator's own.
 */
fun transferOutcome(transfer: FileTransferState): TransferOutcome? {
    if (transfer.active) return null
    val status = transfer.status
    return when {
        status.endsWith(" saved on Mac") -> TransferOutcome.SENT
        status.endsWith(" saved to Download/Bridgey") -> TransferOutcome.RECEIVED
        status.contains("cancel", ignoreCase = true) -> null
        transfer.retryable -> null
        else -> TransferOutcome.FAILED
    }
}

/**
 * Feeds the activity stream by watching the coordinator's existing state flows, plus the
 * coordinator's [PairingCoordinator.activityListener] for events that leave no state behind
 * (clipboard, ping or call from the Mac). Records only kinds, device and file names.
 */
class ActivityRecorder(
    private val log: ActivityLog,
    private val pairing: PairingCoordinator,
    private val scope: CoroutineScope,
) {
    private val recordedTransfers = LinkedHashSet<String>()

    fun start() {
        pairing.activityListener = { activity, deviceId, deviceName ->
            val kind = when (activity) {
                PeerActivity.CLIPBOARD_RECEIVED -> ActivityKind.CLIPBOARD_RECEIVED
                PeerActivity.PING_RECEIVED -> ActivityKind.PING_RECEIVED
                PeerActivity.CALL_STARTED -> ActivityKind.CALL_STARTED
            }
            log.record(kind, deviceId, deviceName)
        }
        scope.launch {
            pairing.clipboardStatus.drop(1).collect { status ->
                if (status == "Delivered") connected()?.let { log.record(ActivityKind.CLIPBOARD_SENT, it.deviceId, it.peerName) }
            }
        }
        scope.launch {
            pairing.pingStatus.drop(1).collect { status ->
                if (status == "Ping delivered") connected()?.let { log.record(ActivityKind.PING_SENT, it.deviceId, it.peerName) }
            }
        }
        scope.launch {
            var ringing = pairing.macRinging.value
            pairing.macRinging.collect { now ->
                if (now && !ringing) connected()?.let { log.record(ActivityKind.FIND_MAC, it.deviceId, it.peerName) }
                ringing = now
            }
        }
        scope.launch {
            var ringing = pairing.phoneRinging.value
            pairing.phoneRinging.collect { now ->
                if (now && !ringing) connected()?.let { log.record(ActivityKind.FIND_PHONE, it.deviceId, it.peerName) }
                ringing = now
            }
        }
        scope.launch {
            pairing.quickActions.status.drop(1).collect { status ->
                if (status?.startsWith("Link delivered") == true) {
                    connected()?.let { log.record(ActivityKind.LINK_SENT, it.deviceId, it.peerName) }
                }
            }
        }
        scope.launch {
            var previous = pairing.quickActions.receivedLink.value
            pairing.quickActions.receivedLink.collect { link ->
                if (link != null && link != previous) connected()?.let { log.record(ActivityKind.LINK_RECEIVED, it.deviceId, it.peerName) }
                previous = link
            }
        }
        scope.launch {
            var known = pairing.trustedDeviceIds.value
            pairing.trustedDevices.collect { devices ->
                devices.filter { it.id !in known }.forEach { log.record(ActivityKind.PAIRED, it.id, it.name) }
                known = devices.mapTo(HashSet()) { it.id }
            }
        }
        scope.launch {
            pairing.fileTransfers.collect { transfers ->
                transfers.values.forEach { transfer ->
                    if (transfer.id in recordedTransfers) return@forEach
                    val outcome = transferOutcome(transfer) ?: return@forEach
                    recordedTransfers += transfer.id
                    while (recordedTransfers.size > 256) recordedTransfers.remove(recordedTransfers.first())
                    val device = connected()
                    val kind = when (outcome) {
                        TransferOutcome.SENT -> ActivityKind.FILE_SENT
                        TransferOutcome.RECEIVED -> ActivityKind.FILE_RECEIVED
                        TransferOutcome.FAILED -> ActivityKind.FILE_FAILED
                    }
                    log.record(kind, device?.deviceId, device?.peerName.orEmpty(), transfer.name)
                }
            }
        }
    }

    /** Called by the notification listener after it forwards a notification to the connected device. */
    fun notificationForwarded(isCall: Boolean) {
        val device = connected() ?: return
        log.record(if (isCall) ActivityKind.CALL_SHOWN else ActivityKind.NOTIFICATIONS_SHOWN, device.deviceId, device.peerName)
    }

    private fun connected(): PairingState.Connected? = pairing.state.value as? PairingState.Connected
}
