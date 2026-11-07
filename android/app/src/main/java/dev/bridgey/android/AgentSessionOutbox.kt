package dev.bridgey.android

import java.util.ArrayDeque
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/** One ephemeral reply for one captured session. Never persisted, retried, or moved to a replacement. */
internal data class AgentOutboundReply(val kind: String, val payload: ByteArray)

/**
 * AgentHub's bounded FIFO. Admission only copies/accounts bytes and wakes one lazy IO consumer; the writer never
 * holds this monitor, the session registry monitor, or the Hub monitor. Bounds include the one in-flight reply.
 * A true enqueue means accepted, not acknowledged socket delivery. The session closes this outbox and its socket
 * together, so closing the socket also releases a blocked writer.
 */
internal class AgentSessionOutbox(
    scope: CoroutineScope,
    private val maxCount: Int = 16,
    private val maxBytes: Int = 256 * 1_024,
    private val maxReplyBytes: Int = 48 * 1_024,
    private val write: (AgentOutboundReply) -> Boolean,
    private val onFailure: () -> Unit = {},
) {
    private val lock = Any()
    private val queued = ArrayDeque<AgentOutboundReply>()
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    private var closed = false
    private var inFlight: AgentOutboundReply? = null
    private var count = 0
    private var bytes = 0
    private val worker: Job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
        try {
            for (ignored in wakeups) {
                while (true) {
                    val next = synchronized(lock) {
                        if (closed) null else queued.pollFirst()?.also { inFlight = it }
                    } ?: break
                    val sent = try { write(next) } catch (_: Exception) { false }
                    synchronized(lock) {
                        if (inFlight === next) {
                            inFlight = null
                            count--
                            bytes -= next.payload.size
                        }
                    }
                    if (!sent) {
                        close()
                        onFailure()
                        return@launch
                    }
                }
            }
        } finally {
            close()
        }
    }

    fun enqueue(kind: String, payload: ByteArray): Boolean = synchronized(lock) {
        if (closed || worker.isCancelled || payload.size > maxReplyBytes || count >= maxCount || payload.size > maxBytes - bytes) return@synchronized false
        val reply = AgentOutboundReply(kind, payload.copyOf())
        queued.addLast(reply)
        count++
        bytes += reply.payload.size
        worker.start()
        wakeups.trySend(Unit).isSuccess
    }

    /** Drops every queued byte. The already-running write is stopped by the owning session closing its socket. */
    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            queued.clear()
            count = if (inFlight == null) 0 else 1
            bytes = inFlight?.payload?.size ?: 0
            wakeups.close()
        }
        worker.cancel()
    }

    internal fun pendingCount(): Int = synchronized(lock) { count }
    internal fun pendingBytes(): Int = synchronized(lock) { bytes }
}
