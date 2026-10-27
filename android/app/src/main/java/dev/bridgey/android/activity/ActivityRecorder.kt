package dev.bridgey.android.activity

import dev.bridgey.android.FileTransferState
import dev.bridgey.android.TransferEnd
import dev.bridgey.android.TransferKind
import dev.bridgey.android.folders.ConflictChoice
import dev.bridgey.android.folders.FolderCodes
import dev.bridgey.android.folders.FolderEnd
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.DeviceConnection
import dev.bridgey.android.PairingState
import dev.bridgey.android.PeerActivity
import dev.bridgey.android.PeerEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/** How a finished transfer ends up in the stream. */
enum class TransferOutcome { SENT, RECEIVED, FAILED }

/**
 * Maps a file transfer's final state to a stream event, or null while it runs, when the user cancelled it, or
 * when it can be retried (then its card with Retry is the record). Reads the explicit [FileTransferState.outcome];
 * folders go through [folderRecord].
 */
fun transferOutcome(transfer: FileTransferState): TransferOutcome? {
    if (transfer.active || transfer.kind == TransferKind.FOLDER) return null
    return when (transfer.outcome) {
        TransferEnd.SENT -> TransferOutcome.SENT
        TransferEnd.RECEIVED -> TransferOutcome.RECEIVED
        TransferEnd.CANCELLED, TransferEnd.INTERRUPTED -> null
        TransferEnd.FAILED, null -> if (transfer.retryable) null else TransferOutcome.FAILED
    }
}

/** A finished folder as a stream item. */
data class FolderRecord(val kind: ActivityKind, val fileCount: Int, val bytes: Long, val destination: String?, val detail: String?)

/**
 * The stream item for a folder that ended, or null: while it runs, while it can resume, and when it ended
 * before anything was written for a reason the person chose (their own Cancel, or the Mac's).
 */
fun folderRecord(transfer: FileTransferState): FolderRecord? {
    if (transfer.kind != TransferKind.FOLDER || transfer.active) return null
    val folder = transfer.folder ?: return null
    val tokens = ArrayList<Pair<String, Int?>>()
    when (folder.choice) {
        ConflictChoice.MERGE -> tokens += FolderDetail.MERGED to folder.renamedFiles
        ConflictChoice.REPLACE -> tokens += FolderDetail.REPLACED to folder.replacedFiles
        ConflictChoice.NEW_FOLDER -> tokens += FolderDetail.SAVED_AS_COPY to null
        else -> Unit
    }
    val skipped = folder.skipped
    if (skipped.links > 0) tokens += FolderDetail.LINKS to skipped.links
    if (skipped.hidden > 0) tokens += FolderDetail.HIDDEN to skipped.hidden
    if (skipped.system > 0) tokens += FolderDetail.SYSTEM to skipped.system
    val others = skipped.total - skipped.links - skipped.hidden - skipped.system
    if (others > 0) tokens += FolderDetail.OTHER_SKIPPED to others
    if (folder.emptyFoldersSkipped > 0) tokens += FolderDetail.EMPTY_SKIPPED to folder.emptyFoldersSkipped
    if (folder.failedCount > 0) tokens += FolderDetail.FAILED to folder.failedCount
    fun reason(): String = when (folder.endCode) {
        FolderCodes.PLACE_UNAVAILABLE, FolderCodes.NOT_FOUND -> FolderDetail.LOST_ACCESS
        FolderCodes.INSUFFICIENT_SPACE -> FolderDetail.NO_SPACE
        FolderCodes.TIMEOUT -> FolderDetail.TIMEOUT
        else -> FolderDetail.CANCELLED
    }
    val kind = when (folder.end) {
        FolderEnd.COMPLETE -> if (folder.outgoing) ActivityKind.FOLDER_SENT else ActivityKind.FOLDER_RECEIVED
        FolderEnd.INCOMPLETE -> {
            if (folder.endCode != FolderCodes.TOO_MANY_FAILURES) tokens += reason() to null
            ActivityKind.FOLDER_INCOMPLETE
        }
        FolderEnd.TIMED_OUT -> {
            tokens += FolderDetail.TIMEOUT to null
            ActivityKind.FOLDER_INCOMPLETE
        }
        FolderEnd.CANCELLED -> {
            val code = reason()
            if (code == FolderDetail.CANCELLED) return null
            tokens += code to null
            ActivityKind.FOLDER_INCOMPLETE
        }
        FolderEnd.INTERRUPTED -> {
            if (folder.resumable || folder.choice == null) return null
            tokens += FolderDetail.CONNECTION_LOST to null
            ActivityKind.FOLDER_INCOMPLETE
        }
        null -> return null
    }
    return FolderRecord(kind, folder.filesDone, folder.bytesDone, folder.destinationLabel, FolderDetail.encode(tokens))
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
    /** Settings > Privacy > Show previews in activity. Off: no preview text or app names are kept. */
    private val showPreviews: () -> Boolean = { true },
) {
    private val recordedTransfers = LinkedHashSet<String>()

    fun start() {
        pairing.activityListener = { event -> recordPeerEvent(log, event, showPreviews()) }
        // Ping sent, Find Mac and Find phone arrive as PeerEvents tagged with their own device.
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
                    // The transfer's own device, not whichever device is selected now.
                    val ownDevice = transfer.deviceId ?: connected()?.deviceId
                    val ownName = transfer.deviceName.ifBlank { connected()?.peerName.orEmpty() }
                    folderRecord(transfer)?.let { folder ->
                        remember(transfer.id)
                        log.record(
                            folder.kind, ownDevice, ownName, fileName = transfer.name, bytes = folder.bytes,
                            fileCount = folder.fileCount, destination = folder.destination, detail = folder.detail,
                        )
                        return@forEach
                    }
                    val outcome = transferOutcome(transfer) ?: return@forEach
                    remember(transfer.id)
                    val kind = when (outcome) {
                        TransferOutcome.SENT -> ActivityKind.FILE_SENT
                        TransferOutcome.RECEIVED -> ActivityKind.FILE_RECEIVED
                        TransferOutcome.FAILED -> ActivityKind.FILE_FAILED
                    }
                    log.record(kind, ownDevice, ownName, transfer.name)
                }
            }
        }
    }

    private fun remember(id: String) {
        recordedTransfers += id
        while (recordedTransfers.size > 256) recordedTransfers.remove(recordedTransfers.first())
    }

    /** Called by the notification listener after it forwards a notification to the connected device. */
    fun notificationForwarded(devices: List<DeviceConnection>, isCall: Boolean, appName: String?, caller: String?) {
        // One item per device it went to, so each device's page shows it.
        devices.forEach { device ->
            recordNotification(log, device.deviceId, device.peerName, isCall, appName, caller, showPreviews())
        }
    }

    private fun connected(): PairingState.Connected? = pairing.state.value as? PairingState.Connected
}

/** Records a coordinator event; clipboard text becomes a preview only when previews are on. */
internal fun recordPeerEvent(log: ActivityLog, event: PeerEvent, previews: Boolean) {
    val kind = when (event.activity) {
        PeerActivity.CLIPBOARD_SENT -> ActivityKind.CLIPBOARD_SENT
        PeerActivity.CLIPBOARD_RECEIVED -> ActivityKind.CLIPBOARD_RECEIVED
        PeerActivity.CLIPBOARD_RECEIVE_FAILED -> ActivityKind.CLIPBOARD_RECEIVE_FAILED
        PeerActivity.PING_RECEIVED -> ActivityKind.PING_RECEIVED
        PeerActivity.CALL_STARTED -> ActivityKind.CALL_STARTED
        PeerActivity.PING_SENT -> ActivityKind.PING_SENT
        PeerActivity.FIND_REMOTE_STARTED -> ActivityKind.FIND_MAC
        PeerActivity.FIND_PHONE_STARTED -> ActivityKind.FIND_PHONE
        PeerActivity.CLIP_OFFER_SENT -> ActivityKind.CLIP_OFFER_SENT
        PeerActivity.CLIP_OFFER_RECEIVED -> ActivityKind.CLIP_OFFER_RECEIVED
        PeerActivity.CLIP_PASTED -> ActivityKind.CLIP_PASTED
        PeerActivity.CLIP_PASTE_FAILED -> ActivityKind.CLIP_PASTE_FAILED
    }
    if (kind.isClipOffer) {
        // Names only with previews on, and never for a clip marked sensitive.
        log.record(
            kind,
            event.deviceId,
            event.deviceName,
            fileName = event.clipName?.takeIf { previews && !event.sensitive && event.clipCount == 1 },
            automatic = event.automatic,
            bytes = event.clipBytes,
            content = event.clipContent,
            itemCount = event.clipCount,
        )
        return
    }
    log.record(
        kind,
        event.deviceId,
        event.deviceName,
        preview = if (previews) event.clipboardText else null,
        sensitive = event.sensitive,
        automatic = event.automatic,
    )
}

internal fun recordNotification(
    log: ActivityLog,
    deviceId: String,
    deviceName: String,
    isCall: Boolean,
    appName: String?,
    caller: String?,
    previews: Boolean,
) {
    if (isCall) {
        log.record(ActivityKind.CALL_SHOWN, deviceId, deviceName, preview = if (previews) caller else null)
    } else {
        log.record(ActivityKind.NOTIFICATIONS_SHOWN, deviceId, deviceName, appName = if (previews) appName else null)
    }
}
