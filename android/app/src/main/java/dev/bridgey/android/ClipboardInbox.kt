package dev.bridgey.android

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/** The connected peer, as the clipboard offer code sees it. Bound to one session. */
internal interface ClipboardLink {
    val deviceId: String
    val peerName: String

    /** Sends one message; [payload] is encrypted when present. False when the session is gone. */
    fun send(kind: String, transferId: String?, payload: ByteArray? = null, sequence: Long? = null): Boolean
}

/** What the inbox puts on this phone's clipboard. */
internal sealed interface IncomingClip {
    val offerId: String
    val sensitive: Boolean

    data class Text(override val offerId: String, val text: String, val html: String?, override val sensitive: Boolean) : IncomingClip
    data class Items(override val offerId: String, val items: List<IncomingClipItem>, override val sensitive: Boolean) : IncomingClip
}

internal data class IncomingClipItem(val index: Int, val mime: String, val displayName: String)

internal fun interface ClipWriter {
    fun write(clip: IncomingClip): Boolean
}

/** Events for the activity stream, notifications and loop prevention. Never logged. */
internal sealed interface ClipInboxEvent {
    data class Received(val received: ReceivedClipOffer) : ClipInboxEvent
    data class Pasted(val deviceId: String, val peerName: String, val item: ClipOfferItem) : ClipInboxEvent
    data class PasteFailed(val deviceId: String, val peerName: String, val code: String) : ClipInboxEvent
    data class TextWritten(val deviceId: String, val text: String) : ClipInboxEvent
    data class WriteFailed(val deviceId: String, val peerName: String) : ClipInboxEvent
}

/** A paste waiting on data from the other device, for the progress notification. */
data class ClipFetchProgress(
    val transferId: String,
    val peerName: String,
    val name: String,
    val received: Long,
    val size: Long,
    val startedAtMillis: Long,
)

internal data class ClipItemInfo(val name: String, val mime: String, val size: Long)

internal sealed interface ClipOpen {
    data class Cached(val file: File) : ClipOpen
    class Streaming(val stream: ClipStream) : ClipOpen
    data class Failed(val code: String) : ClipOpen
}

internal fun interface ClipStream {
    /** Copies the item into [output] as it arrives. Throws [ClipStreamException] when it fails. */
    fun copyTo(output: OutputStream)
}

internal class ClipStreamException(val code: String) : IOException(code)

/** What the content provider needs; [ClipboardInbox] in the app, a fake in tests. */
internal interface ClipProviderBackend {
    fun describe(offerId: String, index: Int): ClipItemInfo?

    /** [allowFetch] is false for thumbnail requests, which never pull a lazy item. */
    fun open(offerId: String, index: Int, allowFetch: Boolean): ClipOpen
}

/**
 * Receives clipboard offers from the connected Mac: writes them to the clipboard, keeps their data
 * in [ClipboardCache], fetches lazy items when an app opens them, and follows a transfer while it
 * arrives so a pasting app can read from the first chunk. Thread-safe: messages arrive on the
 * session's reader thread, opens on Binder threads.
 */
internal class ClipboardInbox(
    private val cache: ClipboardCache,
    private val writer: ClipWriter,
    private val clock: () -> Long = System::currentTimeMillis,
    private val timer: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "bridgey-clipboard-inbox").apply { isDaemon = true }
    },
    startWatchdog: Boolean = true,
) : ClipProviderBackend {
    /** Set while connected to a peer that takes clipboard offers; null otherwise. */
    @Volatile var link: ClipboardLink? = null

    @Volatile var listener: (ClipInboxEvent) -> Unit = {}

    private val lock = Any()
    private var current: ReceivedClipOffer? = null
    private val transfers = HashMap<String, Inbound>()
    private val byItem = HashMap<Pair<String, Int>, Inbound>()
    private val mutableProgress = MutableStateFlow<List<ClipFetchProgress>>(emptyList())
    val progress: StateFlow<List<ClipFetchProgress>> = mutableProgress.asStateFlow()

    init {
        if (startWatchdog) timer.scheduleWithFixedDelay({ runCatching { checkTimeouts() } }, 1, 1, TimeUnit.SECONDS)
    }

    val currentOfferId: String? get() = synchronized(lock) { current?.offer?.offerId }

    fun handles(transferId: String?): Boolean = transferId != null && synchronized(lock) { transfers.containsKey(transferId) }

    /** A new offer from [link]'s device: supersede the previous one and put this one on the clipboard. */
    fun accept(offer: ClipOffer, link: ClipboardLink) {
        val received = ReceivedClipOffer(offer, link.deviceId, link.peerName, clock())
        synchronized(lock) {
            supersedeLocked()
            current = received
            cache.saveOffer(received)
            offer.items.forEach { item -> item.inline?.let { cache.writeComplete(offer.offerId, item.index, it) } }
        }
        listener(ClipInboxEvent.Received(received))
        if (offer.isText && offer.totalSize <= ClipLimits.TEXT_IN_MEMORY_BYTES) {
            val missing = offer.items.filterNot { cache.isComplete(offer.offerId, it.index) }
            if (missing.isEmpty()) {
                writeText(received)
            } else {
                val started = synchronized(lock) {
                    missing.all { item -> (byItem[offer.offerId to item.index] ?: startFetchLocked(received, item, fetched = false)) != null }
                }
                if (!started) failText(received, ClipErrorCode.NOT_CONNECTED)
            }
        } else {
            writeItems(received)
        }
        evict()
    }

    /** This phone's clipboard changed (a local copy, or text from the Mac): drop the current offer. */
    fun supersede() {
        synchronized(lock) { supersedeLocked() }
    }

    /** Clear activity and Forget device: stop everything and delete the whole cache. */
    fun clearAll() {
        synchronized(lock) {
            supersedeLocked()
            transfers.values.toList().forEach { failLocked(it, ClipErrorCode.CANCELLED, notifyPeer = true) }
        }
        cache.clear()
        publishProgress()
    }

    fun disconnected() {
        link = null
        synchronized(lock) { transfers.values.toList().forEach { failLocked(it, ClipErrorCode.NOT_CONNECTED, notifyPeer = false) } }
        publishProgress()
    }

    /** Cancel from the progress notification. */
    fun cancel(transferId: String) {
        synchronized(lock) { transfers[transferId]?.let { failLocked(it, ClipErrorCode.CANCELLED, notifyPeer = true) } }
        publishProgress()
    }

    /** A clipboard-purpose files.offer: the answer to our fetch, or an eager push. Replies accept or cancel. */
    fun onTransferOffer(link: ClipboardLink, offer: ClipTransferOffer) {
        synchronized(lock) {
            val requested = transfers[offer.transferId]
            if (requested != null) {
                if (requested.state != State.REQUESTED || requested.offerId != offer.offerId ||
                    requested.item.index != offer.index || requested.item.size != offer.size ||
                    (offer.sha256 != null && requested.item.sha256 != null && offer.sha256 != requested.item.sha256)
                ) {
                    failLocked(requested, ClipErrorCode.INVALID, notifyPeer = true)
                    return
                }
                requested.begin()
                link.send("files.accept", offer.transferId)
                return
            }
            val received = current
            val item = received?.offer?.items?.getOrNull(offer.index)
            val wanted = received != null && item != null && received.offer.offerId == offer.offerId &&
                received.deviceId == link.deviceId && item.size == offer.size && item.inline == null &&
                !cache.isComplete(offer.offerId, offer.index) && byItem[offer.offerId to offer.index] == null &&
                (offer.sha256 == null || item.sha256 == null || offer.sha256 == item.sha256)
            if (!wanted) {
                link.send("files.cancel", offer.transferId)
                return
            }
            val inbound = register(offer.transferId, received!!, item!!, fetched = false)
            inbound.begin()
            link.send("files.accept", offer.transferId)
        }
    }

    /** One chunk. False when it does not belong or is out of order; the transfer then fails. */
    fun onChunk(transferId: String, sequence: Long, bytes: ByteArray): Boolean {
        val inbound = synchronized(lock) { transfers[transferId] } ?: return false
        if (!inbound.append(sequence, bytes)) {
            synchronized(lock) { failLocked(inbound, ClipErrorCode.INVALID, notifyPeer = true) }
            publishProgress()
            return false
        }
        if (inbound.waiting && inbound.progressDue(clock())) publishProgress()
        return true
    }

    /** files.complete: verify, keep, acknowledge. */
    fun onComplete(link: ClipboardLink, transferId: String, sha256: String) {
        val inbound = synchronized(lock) { transfers[transferId] } ?: return
        if (!inbound.finish(sha256)) {
            synchronized(lock) { failLocked(inbound, ClipErrorCode.INVALID, notifyPeer = true) }
            publishProgress()
            return
        }
        synchronized(lock) {
            cache.markComplete(inbound.offerId, inbound.item.index)
            unregister(inbound)
        }
        link.send("files.complete.ack", transferId)
        publishProgress()
        if (inbound.fetched && inbound.waiting) {
            listener(ClipInboxEvent.Pasted(inbound.received.deviceId, inbound.received.peerName, inbound.item))
        }
        val received = inbound.received
        if (received.offer.isText && received.offer.totalSize <= ClipLimits.TEXT_IN_MEMORY_BYTES &&
            synchronized(lock) { current?.offer?.offerId == received.offer.offerId } &&
            received.offer.items.all { cache.isComplete(received.offer.offerId, it.index) }
        ) {
            writeText(received)
        }
        evict()
    }

    /** clipboard.error from the sender. A busy sender gets the same fetch again shortly. */
    fun onError(transferId: String, code: String) {
        synchronized(lock) {
            val inbound = transfers[transferId] ?: return
            if (code == ClipErrorCode.BUSY && inbound.state == State.REQUESTED && inbound.busyRetries < ClipLimits.BUSY_RETRIES) {
                inbound.busyRetries += 1
                inbound.startedAt = clock()
                timer.schedule({ resendFetch(inbound) }, ClipLimits.BUSY_RETRY_MILLIS, TimeUnit.MILLISECONDS)
                return
            }
            failLocked(inbound, code, notifyPeer = false)
        }
        publishProgress()
    }

    /** files.cancel from the sender. */
    fun onCancelled(transferId: String) {
        synchronized(lock) { transfers[transferId]?.let { failLocked(it, ClipErrorCode.CANCELLED, notifyPeer = false) } }
        publishProgress()
    }

    override fun describe(offerId: String, index: Int): ClipItemInfo? {
        val received = resolve(offerId) ?: return null
        val item = received.offer.items.getOrNull(index) ?: return null
        return ClipItemInfo(clipDisplayName(item), item.mime, item.size)
    }

    override fun open(offerId: String, index: Int, allowFetch: Boolean): ClipOpen {
        if (!isUuid(offerId)) return ClipOpen.Failed(ClipErrorCode.EXPIRED)
        val received = resolve(offerId) ?: return ClipOpen.Failed(ClipErrorCode.EXPIRED)
        val item = received.offer.items.getOrNull(index) ?: return ClipOpen.Failed(ClipErrorCode.EXPIRED)
        if (cache.isComplete(offerId, index)) {
            if (allowFetch) cache.markHandedOut(offerId, index)
            return ClipOpen.Cached(cache.dataFile(offerId, index))
        }
        if (!allowFetch) return ClipOpen.Failed(ClipErrorCode.UNAVAILABLE)
        val inbound = synchronized(lock) {
            val existing = byItem[offerId to index] ?: startFetchLocked(received, item, fetched = true)
            existing?.also {
                it.waiting = true
                cache.markHandedOut(offerId, index)
            }
        }
        if (inbound == null) {
            listener(ClipInboxEvent.PasteFailed(received.deviceId, received.peerName, ClipErrorCode.NOT_CONNECTED))
            return ClipOpen.Failed(ClipErrorCode.NOT_CONNECTED)
        }
        publishProgress()
        // Opened now, so the reader keeps the data even if the cache file is replaced meanwhile.
        val input = runCatching { FileInputStream(inbound.file) }.getOrNull()
        return ClipOpen.Streaming(ClipStream { output -> inbound.copyTo(output, input) })
    }

    /** Fails fetches that got no answer in 15 s and transfers stalled for 30 s. */
    internal fun checkTimeouts() {
        val now = clock()
        synchronized(lock) {
            transfers.values.toList().forEach { inbound ->
                val stalled = when (inbound.state) {
                    State.REQUESTED -> now - inbound.startedAt > ClipLimits.FETCH_START_TIMEOUT_MILLIS
                    State.RECEIVING -> now - inbound.lastActivity > ClipLimits.STALL_TIMEOUT_MILLIS
                    else -> false
                }
                if (stalled) failLocked(inbound, ClipErrorCode.TIMEOUT, notifyPeer = true)
            }
        }
        publishProgress()
    }

    private fun resolve(offerId: String): ReceivedClipOffer? =
        synchronized(lock) { current?.takeIf { it.offer.offerId == offerId.lowercase() } } ?: cache.loadOffer(offerId)

    private fun writeItems(received: ReceivedClipOffer) {
        val offer = received.offer
        val items = if (offer.isText) listOf(offer.items.first()) else offer.items
        val clip = IncomingClip.Items(offer.offerId, items.map { IncomingClipItem(it.index, it.mime, clipDisplayName(it)) }, offer.sensitive)
        if (!writer.write(clip)) listener(ClipInboxEvent.WriteFailed(received.deviceId, received.peerName))
    }

    private fun writeText(received: ReceivedClipOffer) {
        val offer = received.offer
        val text = runCatching { cache.dataFile(offer.offerId, 0).readText(Charsets.UTF_8) }.getOrNull()
            ?: return failText(received, ClipErrorCode.UNAVAILABLE)
        val html = offer.items.getOrNull(1)?.let { runCatching { cache.dataFile(offer.offerId, it.index).readText(Charsets.UTF_8) }.getOrNull() }
        if (writer.write(IncomingClip.Text(offer.offerId, text, html, offer.sensitive))) {
            listener(ClipInboxEvent.TextWritten(received.deviceId, text))
        } else {
            // Binder refused the text: offer it as a .txt file instead.
            writeItems(received)
        }
    }

    private fun failText(received: ReceivedClipOffer, code: String) {
        listener(ClipInboxEvent.PasteFailed(received.deviceId, received.peerName, code))
    }

    private fun startFetchLocked(received: ReceivedClipOffer, item: ClipOfferItem, fetched: Boolean): Inbound? {
        val link = link?.takeIf { it.deviceId == received.deviceId } ?: return null
        val inbound = register(UUID.randomUUID().toString(), received, item, fetched)
        if (!link.send("clipboard.fetch", inbound.transferId, clipFetchPayload(received.offer.offerId, item.index, inbound.transferId))) {
            unregister(inbound)
            inbound.fail(ClipErrorCode.NOT_CONNECTED)
            return null
        }
        return inbound
    }

    private fun resendFetch(inbound: Inbound) {
        synchronized(lock) {
            if (transfers[inbound.transferId] !== inbound || inbound.state != State.REQUESTED) return
            val link = link?.takeIf { it.deviceId == inbound.received.deviceId }
            if (link == null || !link.send("clipboard.fetch", inbound.transferId,
                    clipFetchPayload(inbound.offerId, inbound.item.index, inbound.transferId))
            ) failLocked(inbound, ClipErrorCode.NOT_CONNECTED, notifyPeer = false)
        }
        publishProgress()
    }

    private fun register(transferId: String, received: ReceivedClipOffer, item: ClipOfferItem, fetched: Boolean): Inbound {
        val inbound = Inbound(transferId, received, item, fetched, cache.createData(received.offer.offerId, item.index), clock())
        transfers[transferId] = inbound
        byItem[received.offer.offerId to item.index] = inbound
        return inbound
    }

    private fun unregister(inbound: Inbound) {
        transfers.remove(inbound.transferId, inbound)
        byItem.remove(inbound.offerId to inbound.item.index, inbound)
    }

    private fun supersedeLocked() {
        val previous = current ?: return
        current = null
        transfers.values.filter { it.offerId == previous.offer.offerId }
            .forEach { failLocked(it, ClipErrorCode.SUPERSEDED, notifyPeer = true) }
        cache.supersede(previous.offer.offerId)
    }

    private fun failLocked(inbound: Inbound, code: String, notifyPeer: Boolean) {
        unregister(inbound)
        if (!inbound.fail(code)) return
        if (notifyPeer) link?.send("files.cancel", inbound.transferId)
        cache.discardItem(inbound.offerId, inbound.item.index)
        val reported = code != ClipErrorCode.SUPERSEDED && code != ClipErrorCode.CANCELLED
        val isText = inbound.received.offer.isText && inbound.received.offer.totalSize <= ClipLimits.TEXT_IN_MEMORY_BYTES
        if (reported && (inbound.waiting || isText)) {
            listener(ClipInboxEvent.PasteFailed(inbound.received.deviceId, inbound.received.peerName, code))
        }
    }

    private fun evict() {
        val keep = synchronized(lock) { (transfers.values.map { it.offerId } + listOfNotNull(current?.offer?.offerId)).toSet() }
        cache.evict(keep)
    }

    private fun publishProgress() {
        mutableProgress.value = synchronized(lock) {
            transfers.values.filter { it.waiting }.map {
                ClipFetchProgress(it.transferId, it.received.peerName, clipDisplayName(it.item), it.receivedBytes, it.item.size, it.createdAt)
            }.sortedBy(ClipFetchProgress::startedAtMillis)
        }
    }

    private enum class State { REQUESTED, RECEIVING, DONE, FAILED }

    /** One incoming item. Its data file exists from the start, so readers can follow it. */
    private inner class Inbound(
        val transferId: String,
        val received: ReceivedClipOffer,
        val item: ClipOfferItem,
        /** Started by a paste (a fetch), as opposed to an eager push. */
        val fetched: Boolean,
        val file: File,
        val createdAt: Long,
    ) {
        val offerId: String get() = received.offer.offerId
        private val monitor = Object()
        @Volatile var state = State.REQUESTED
        @Volatile var startedAt = createdAt
        @Volatile var lastActivity = createdAt
        @Volatile var waiting = false
        @Volatile var receivedBytes = 0L
        var busyRetries = 0
        private var failure: String? = null
        private var output: FileOutputStream? = null
        private val digest = MessageDigest.getInstance("SHA-256")
        private var nextSequence = 0L
        private var lastProgressAt = 0L

        fun begin() = synchronized(monitor) {
            output = FileOutputStream(file, false)
            state = State.RECEIVING
            lastActivity = clock()
        }

        fun append(sequence: Long, bytes: ByteArray): Boolean = synchronized(monitor) {
            val stream = output
            if (state != State.RECEIVING || stream == null || sequence != nextSequence ||
                bytes.size > ClipLimits.CHUNK_SIZE || receivedBytes + bytes.size > item.size
            ) return false
            if (runCatching { stream.write(bytes) }.isFailure) return false
            digest.update(bytes)
            receivedBytes += bytes.size
            nextSequence += 1
            lastActivity = clock()
            monitor.notifyAll()
            true
        }

        fun progressDue(now: Long): Boolean {
            if (now - lastProgressAt < 250 && receivedBytes < item.size) return false
            lastProgressAt = now
            return true
        }

        fun finish(sha256: String): Boolean = synchronized(monitor) {
            if (state != State.RECEIVING) return false
            runCatching { output?.flush(); output?.close() }
            output = null
            val actual = Base64.getEncoder().encodeToString(digest.digest())
            val ok = receivedBytes == item.size && sha256 == actual && (item.sha256 == null || item.sha256 == actual)
            if (ok) state = State.DONE
            monitor.notifyAll()
            ok
        }

        /** False when it had already ended. */
        fun fail(code: String): Boolean = synchronized(monitor) {
            if (state == State.FAILED || state == State.DONE) return false
            runCatching { output?.close() }
            output = null
            failure = code
            state = State.FAILED
            monitor.notifyAll()
            true
        }

        /** Streams the item into [target] as chunks arrive. */
        fun copyTo(target: OutputStream, opened: FileInputStream?) {
            val stream = opened ?: runCatching { FileInputStream(file) }.getOrNull()
                ?: throw ClipStreamException(synchronized(monitor) { failure } ?: ClipErrorCode.UNAVAILABLE)
            stream.use { input ->
                val buffer = ByteArray(64 * 1024)
                var position = 0L
                while (true) {
                    val (available, ended, code) = synchronized(monitor) {
                        while (receivedBytes <= position && (state == State.REQUESTED || state == State.RECEIVING)) {
                            monitor.wait(1_000)
                        }
                        Triple(receivedBytes, state, failure)
                    }
                    while (position < available) {
                        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), available - position).toInt())
                        if (count < 0) throw ClipStreamException(ClipErrorCode.INVALID)
                        target.write(buffer, 0, count)
                        position += count
                    }
                    when (ended) {
                        State.DONE -> if (position >= item.size) {
                            target.flush()
                            return
                        }
                        State.FAILED -> throw ClipStreamException(code ?: ClipErrorCode.UNAVAILABLE)
                        else -> Unit
                    }
                }
            }
        }
    }
}

/** Decodes a files.complete payload's hash for a clipboard transfer. */
internal fun parseClipCompletion(payload: JSONObject, transferId: String): String? {
    if (payload.optString("transferId") != transferId) return null
    return payload.optString("sha256").takeIf { decodeSha(it) != null }
}
