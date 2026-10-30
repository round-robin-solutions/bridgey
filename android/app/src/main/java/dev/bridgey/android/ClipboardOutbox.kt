package dev.bridgey.android

import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.coroutineContext
import org.json.JSONObject

/** Where an offered item's bytes come from. */
internal sealed interface ClipSource {
    class Bytes(val data: ByteArray) : ClipSource

    /** A content:// URI from the clipboard, as it was when offered. */
    data class Content(val uri: String, val size: Long) : ClipSource
}

internal interface ClipSourceOpener {
    /** Throws SecurityException when access is gone (the clip changed), IOException when unreadable. */
    fun open(source: ClipSource): InputStream

    /** The size now, or null when the provider does not say. */
    fun currentSize(source: ClipSource): Long?
}

internal class OutgoingClip(
    val offer: ClipOffer,
    val sources: List<ClipSource>,
    val deviceId: String,
    /** [LocalClip.hash] of what was offered, to notice the clipboard changing while offline. */
    val clipHash: String? = null,
    /** Every device the offer went to (automatic clipboard offers to all connected Macs). */
    val deviceIds: Set<String> = setOf(deviceId),
)

/**
 * Serves this phone's current clipboard offer: eager pushes right after the offer, and fetches when
 * the Mac pastes. Each item streams once, hashing as it goes, so a big video is read one time.
 */
internal class ClipboardOutbox(
    private val scope: CoroutineScope,
    private val opener: ClipSourceOpener,
) {
    private class OutTransfer(val transferId: String, val link: ClipboardLink) {
        val accepted = CompletableDeferred<Boolean>()
        val completed = CompletableDeferred<Boolean>()
        var job: Job? = null
        /** Set while a fast stream runs (FastTransfer.kt). */
        @Volatile var pacer: dev.bridgey.android.TransferPacer? = null
    }

    private val lock = Any()
    private var current: OutgoingClip? = null
    /** The clipboard changed after [current] was offered, without a new offer. */
    private var currentChanged = false
    private var eagerJob: Job? = null
    private val transfers = ConcurrentHashMap<String, OutTransfer>()

    val currentOfferId: String? get() = synchronized(lock) { current?.offer?.offerId }

    fun handles(transferId: String?): Boolean = transferId != null && transfers.containsKey(transferId)

    /** A new offer went out: it replaces the previous one, then eager items are pushed in order. */
    fun publish(clip: OutgoingClip, link: ClipboardLink, eagerLimitBytes: Long) = publish(clip, listOf(link), eagerLimitBytes)

    /** The same offer went to several devices: each gets its own eager pushes. */
    fun publish(clip: OutgoingClip, links: List<ClipboardLink>, eagerLimitBytes: Long) {
        synchronized(lock) {
            stopLocked(notify = true)
            current = clip
            currentChanged = false
            val indices = eagerIndices(clip.offer.items, eagerLimitBytes)
            if (indices.isEmpty() || links.isEmpty()) return
            eagerJob = scope.launch {
                for (link in links) {
                    launch {
                        for (index in indices) {
                            if (synchronized(lock) { current !== clip || currentChanged }) break
                            stream(link, clip, index, UUID.randomUUID().toString())
                        }
                    }
                }
            }
        }
    }

    /** Something else is on the clipboard now (text, or a clip from the Mac): stop serving. */
    fun supersede(link: ClipboardLink?) {
        synchronized(lock) {
            stopLocked(notify = link != null)
            current = null
        }
    }

    /** The clipboard changed but nothing new was offered (for example a password): fetches say "changed". */
    fun invalidate(link: ClipboardLink?) {
        synchronized(lock) {
            if (current == null) return
            stopLocked(notify = link != null)
            currentChanged = true
        }
    }

    /**
     * The clipboard was read while no offer could be sent (for example while disconnected): if it
     * no longer holds what was offered, a later fetch gets "changed" instead of stale data.
     */
    fun noteLocalClip(hash: String?) {
        synchronized(lock) {
            val clip = current ?: return
            if (clip.clipHash == null || clip.clipHash != hash) currentChanged = true
        }
    }

    fun onFetch(link: ClipboardLink, request: ClipFetchRequest) {
        val clip = synchronized(lock) { current }
        val code = when {
            clip == null || clip.offer.offerId != request.offerId || link.deviceId !in clip.deviceIds ||
                request.index !in clip.offer.items.indices -> ClipErrorCode.EXPIRED
            synchronized(lock) { currentChanged } -> ClipErrorCode.CHANGED
            transfers.size >= ClipLimits.MAX_CONCURRENT_SENDS -> ClipErrorCode.BUSY
            transfers.containsKey(request.transferId) -> ClipErrorCode.BUSY
            else -> null
        }
        if (code != null) {
            link.send("clipboard.error", request.transferId, clipErrorPayload(request.offerId, request.index, request.transferId, code))
            return
        }
        scope.launch { stream(link, clip!!, request.index, request.transferId) }
    }

    fun onAccepted(transferId: String) {
        transfers[transferId]?.accepted?.complete(true)
    }

    fun onCompleteAcknowledged(transferId: String) {
        transfers[transferId]?.completed?.complete(true)
    }

    /** files.chunk.ack for a fast stream: its window moves. */
    fun onChunkAcknowledged(transferId: String, sequence: Long) {
        transfers[transferId]?.pacer?.acknowledged(transferId, sequence)
    }

    /** files.cancel or files.rejected from the Mac. */
    fun onCancelled(transferId: String) {
        transfers.remove(transferId)?.let { transfer ->
            transfer.accepted.complete(false)
            transfer.completed.complete(false)
            transfer.job?.cancel()
            transfer.pacer?.cancel()
        }
    }

    /** Transfers stop; the offer stays, so the Mac can still paste it after reconnecting. */
    fun disconnected(deviceId: String? = null) {
        synchronized(lock) {
            if (deviceId == null) {
                stopLocked(notify = false)
            } else {
                transfers.values.filter { it.link.deviceId == deviceId }.forEach { onCancelled(it.transferId) }
            }
        }
    }

    private fun stopLocked(notify: Boolean) {
        eagerJob?.cancel()
        eagerJob = null
        transfers.values.toList().forEach { transfer ->
            if (notify) transfer.link.send("files.cancel", transfer.transferId)
            onCancelled(transfer.transferId)
        }
    }

    /** One clipboard-purpose transfer: files.offer, accept, chunks, files.complete, ack. */
    private suspend fun stream(link: ClipboardLink, clip: OutgoingClip, index: Int, transferId: String) {
        val item = clip.offer.items[index]
        val source = clip.sources[index]
        val offerId = clip.offer.offerId
        fun sendError(code: String) {
            link.send("clipboard.error", transferId, clipErrorPayload(offerId, index, transferId, code))
        }
        val input = try {
            val size = opener.currentSize(source)
            if (size != null && size != item.size) return sendError(ClipErrorCode.CHANGED)
            opener.open(source)
        } catch (_: SecurityException) {
            return sendError(ClipErrorCode.CHANGED)
        } catch (_: IOException) {
            return sendError(ClipErrorCode.UNAVAILABLE)
        } catch (_: RuntimeException) {
            return sendError(ClipErrorCode.UNAVAILABLE)
        }
        val transfer = OutTransfer(transferId, link)
        transfer.job = coroutineContext[Job]
        transfers[transferId] = transfer
        try {
            input.use {
                if (!link.send("files.offer", transferId, clipTransferOfferPayload(transferId, offerId, item, item.sha256))) return
                if (withTimeoutOrNull(ClipLimits.ACCEPT_TIMEOUT_MILLIS) { transfer.accepted.await() } != true) return
                val digest = MessageDigest.getInstance("SHA-256")
                // A fast peer gets binary frames of 256 KiB in a byte window that follows the link (FastTransfer.kt).
                val pacer = if (link.fastTransfers) dev.bridgey.android.TransferPacer(fast = true).also { transfer.pacer = it } else null
                val job = coroutineContext[Job]
                val buffer = ByteArray(pacer?.chunkSize ?: ClipLimits.CHUNK_SIZE)
                var total = 0L
                var sequence = 0L
                while (true) {
                    coroutineContext.ensureActive()
                    val count = try {
                        readFully(input, buffer)
                    } catch (_: IOException) {
                        return sendError(ClipErrorCode.UNAVAILABLE)
                    } catch (_: SecurityException) {
                        return sendError(ClipErrorCode.CHANGED)
                    }
                    if (count <= 0) break
                    total += count
                    if (total > item.size) return sendError(ClipErrorCode.CHANGED)
                    digest.update(buffer, 0, count)
                    if (pacer != null) {
                        if (!pacer.waitForRoom(count) { job?.isActive == false }) return
                        pacer.didSend(transferId, sequence, count)
                        if (!link.sendFastChunk(transferId, sequence++, buffer, count)) return
                        continue
                    }
                    if (!link.send("files.chunk", transferId, buffer.copyOf(count), sequence++)) return
                }
                if (pacer != null && !pacer.waitForAll { job?.isActive == false }) return
                if (total != item.size) return sendError(ClipErrorCode.CHANGED)
                val sha256 = Base64.getEncoder().encodeToString(digest.digest())
                if (item.sha256 != null && item.sha256 != sha256) return sendError(ClipErrorCode.CHANGED)
                val completion = JSONObject().put("transferId", transferId).put("sha256", sha256).toString().toByteArray(Charsets.UTF_8)
                if (!link.send("files.complete", transferId, completion)) return
                withTimeoutOrNull(ClipLimits.COMPLETE_ACK_TIMEOUT_MILLIS) { transfer.completed.await() }
            }
        } finally {
            transfers.remove(transferId, transfer)
        }
    }

    /** Fills [buffer] unless the stream ends first, so every chunk but the last is full. */
    private fun readFully(input: InputStream, buffer: ByteArray): Int {
        var filled = 0
        while (filled < buffer.size) {
            val count = input.read(buffer, filled, buffer.size - filled)
            if (count < 0) break
            filled += count
        }
        return filled
    }
}
