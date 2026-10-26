package dev.bridgey.android.folders

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject

/** What the app hears from folder transfers on this phone. Called on storage threads. */
interface FolderReceiverListener {
    fun snapshot(snapshot: FolderSnapshot) = Unit
    fun finished(snapshot: FolderSnapshot) = Unit
    fun usedDestination(destination: FolderDestination) = Unit
    fun releaseOneOff(treeUri: String) = Unit
    fun lostAccess(placeLabel: String) = Unit
}

/**
 * Folder transfers to this phone, across devices (the coordinator's hooks): starts a [FolderReceiveSession] per
 * offer (at most one active per device session: `busy`), routes the per-file transfers of a folder to it, serves
 * places.* per device and collects the questions the phone asks its user. Android-free, so the routing rules
 * run on the JVM.
 */
class FolderReceiver(
    private val places: PlaceDirectory,
    private val settings: () -> FolderReceiveSettings,
    private val journals: FolderJournals?,
    private val listener: FolderReceiverListener,
    private val newWorker: (folderTransferId: String) -> FolderWorker,
    private val scheduler: FolderScheduler,
    private val runPlaces: (() -> Unit) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private val sessions = ConcurrentHashMap<String, FolderReceiveSession>()
    private val byTransfer = ConcurrentHashMap<String, FolderReceiveSession>()
    private val placesServers = ConcurrentHashMap<String, PlacesServer>()

    /** Folder IDs that ended here: late messages for them are dropped quietly. */
    private val ended = java.util.Collections.synchronizedSet(LinkedHashSet<String>())
    private val mutableQuestions = MutableStateFlow<List<FolderQuestion>>(emptyList())

    /** The questions waiting for this phone's user, oldest first. */
    val questions: StateFlow<List<FolderQuestion>> = mutableQuestions.asStateFlow()

    fun session(folderTransferId: String): FolderReceiveSession? = sessions[folderTransferId]

    fun activeFor(deviceId: String): FolderReceiveSession? = sessions.values.firstOrNull { it.peerId == deviceId && it.active }

    /** A decrypted folders.offer. Answers rejected for invalid or busy offers; otherwise starts a session. */
    fun offer(deviceId: String, deviceName: String, link: FolderLink, json: JSONObject) {
        val parsed = FolderOfferPayload.parse(json)
        if (parsed is FolderOfferPayload.Companion.Result.Invalid) {
            val id = json.optString("folderTransferId").takeIf(::isWireId)
            log("FOLDER offer rejected code=${parsed.code}")
            if (id != null) link.send(FolderKinds.REJECTED, foldersRejectedJson(id, parsed.code), outerTransferId = id)
            return
        }
        val offer = (parsed as FolderOfferPayload.Companion.Result.Valid).offer
        val id = offer.folderTransferId
        synchronized(this) {
            val busy = activeFor(deviceId)
            if (busy != null || sessions.containsKey(id)) {
                log("FOLDER offer rejected code=busy")
                link.send(FolderKinds.REJECTED, foldersRejectedJson(id, FolderCodes.BUSY), outerTransferId = id)
                return
            }
            ended.remove(id)
            val session = FolderReceiveSession(
                offer, deviceId, deviceName,
                FolderEnvironment(places, settings, journals, newWorker(id), scheduler, clock, log),
                link,
                SessionListener(id),
            )
            sessions[id] = session
            session.start()
        }
    }

    private inner class SessionListener(private val id: String) : FolderSessionListener {
        override fun snapshot(snapshot: FolderSnapshot) = listener.snapshot(snapshot)

        override fun question(question: FolderQuestion?) {
            mutableQuestions.update { list ->
                val others = list.filterNot { it.folderTransferId == id }
                if (question == null) others else others + question
            }
        }

        override fun finished(snapshot: FolderSnapshot) {
            sessions.remove(id)
            byTransfer.entries.removeIf { it.value.id == id }
            synchronized(ended) {
                ended += id
                while (ended.size > 64) ended.remove(ended.first())
            }
            mutableQuestions.update { list -> list.filterNot { it.folderTransferId == id } }
            listener.finished(snapshot)
        }

        override fun usedDestination(destination: FolderDestination) = listener.usedDestination(destination)
        override fun releaseOneOff(treeUri: String) = listener.releaseOneOff(treeUri)
        override fun lostAccess(placeLabel: String) = listener.lostAccess(placeLabel)
    }

    /** Messages for a folder that ended here are dropped quietly; unknown ones too (the session is gone). */
    private fun sessionFor(deviceId: String, folderTransferId: String?): FolderReceiveSession? =
        folderTransferId?.let(sessions::get)?.takeIf { it.peerId == deviceId }

    fun manifest(deviceId: String, json: JSONObject, plaintextBytes: Int) {
        val page = ManifestPagePayload.parse(json) ?: return invalid(deviceId, json)
        sessionFor(deviceId, page.folderTransferId)?.manifestPage(page, plaintextBytes)
    }

    fun resolve(deviceId: String, json: JSONObject) {
        val payload = FolderResolvePayload.parse(json) ?: return invalid(deviceId, json)
        sessionFor(deviceId, payload.folderTransferId)?.resolve(payload)
    }

    fun complete(deviceId: String, json: JSONObject) {
        val payload = FolderCompletePayload.parse(json) ?: return invalid(deviceId, json)
        sessionFor(deviceId, payload.folderTransferId)?.folderComplete(payload)
    }

    /** A payload that decrypted but is invalid: the folder ends with invalid_message; the device session stays. */
    fun invalid(deviceId: String, json: JSONObject) {
        log("FOLDER invalid message")
        sessionFor(deviceId, json.optString("folderTransferId"))?.invalidMessage()
    }

    /** folders.cancel from the device. Answered with an outer-only ack even when the folder already ended. */
    fun cancel(deviceId: String, link: FolderLink, json: JSONObject) {
        val payload = FolderCancelPayload.parse(json) ?: return
        val session = sessionFor(deviceId, payload.folderTransferId)
        if (session == null) {
            link.sendOuter(FolderKinds.CANCEL_ACK, payload.folderTransferId)
            return
        }
        session.cancelledBySender(payload)
    }

    /**
     * A files.offer carrying folder fields. Returns false when it has none (the single-file path handles it).
     * A file of a folder that is not active here is dropped quietly ([handles] stays true for its chunks).
     */
    fun fileOffer(deviceId: String, transferId: String, payload: JSONObject): Boolean {
        val fields = FolderFileFields.parse(payload) ?: return false
        val session = sessionFor(deviceId, fields.folderTransferId)
        if (session == null) {
            droppedTransfers += transferId
            synchronized(droppedTransfers) { while (droppedTransfers.size > 256) droppedTransfers.remove(droppedTransfers.first()) }
            return true
        }
        session.claim(transferId)
        byTransfer[transferId] = session
        session.fileOffer(
            transferId, fields, payload.optString("name"), payload.optLong("size", -1), payload.optString("sha256"),
        )
        return true
    }

    private val droppedTransfers = java.util.Collections.synchronizedSet(LinkedHashSet<String>())

    /** Whether a per-file transfer belongs to a folder here (its chunks, completion and cancel come here). */
    fun handles(transferId: String?): Boolean = transferId != null && (byTransfer.containsKey(transferId) || transferId in droppedTransfers)

    fun chunk(transferId: String, sequence: Long, bytes: ByteArray) {
        byTransfer[transferId]?.chunk(transferId, sequence, bytes)
    }

    fun fileComplete(transferId: String, sha256: String) {
        byTransfer[transferId]?.fileComplete(transferId, sha256)
    }

    /** files.cancel for a file inside a folder; answered by the session (or here when it is gone). */
    fun fileCancel(transferId: String, link: FolderLink) {
        val session = byTransfer[transferId]
        if (session == null) link.sendOuter("files.cancel.ack", transferId) else session.fileCancelled(transferId)
    }

    fun places(deviceId: String, link: FolderLink, kind: String, json: JSONObject) {
        val server = placesServers.getOrPut(deviceId) {
            PlacesServer(places, settings, { answerKind, answer -> currentLinks[deviceId]?.send(answerKind, answer) }, runPlaces, clock, log)
        }
        currentLinks[deviceId] = link
        server.handle(kind, json)
    }

    private val currentLinks = ConcurrentHashMap<String, FolderLink>()

    /** The device session ended: its folders are interrupted (journals stay) and its places limits reset. */
    fun deviceGone(deviceId: String?) {
        sessions.values.filter { deviceId == null || it.peerId == deviceId }.forEach(FolderReceiveSession::interrupt)
        if (deviceId == null) {
            placesServers.clear()
            currentLinks.clear()
        } else {
            placesServers.remove(deviceId)
            currentLinks.remove(deviceId)
        }
    }

    fun answerDestination(folderTransferId: String, answer: DestinationAnswer) {
        sessions[folderTransferId]?.answerDestination(answer)
    }

    fun answerConflict(folderTransferId: String, choice: ConflictChoice) {
        sessions[folderTransferId]?.answerConflict(choice)
    }

    /** Cancel from the row or a question sheet. True when it was a folder. */
    fun cancel(folderTransferId: String): Boolean {
        val session = sessions[folderTransferId] ?: return false
        session.cancelHere()
        return true
    }
}
