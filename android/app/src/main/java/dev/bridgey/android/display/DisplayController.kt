package dev.bridgey.android.display

/** What the viewer asks for, before it is numbered. Positions are fractions of the full shared display. */
sealed interface DisplayAction {
    data class Pointer(val x: Double, val y: Double) : DisplayAction
    data class Button(val button: ControlButton, val down: Boolean, val x: Double, val y: Double) : DisplayAction

    /** Pixels of the stream the content moves, positive right and down (the content follows the fingers). */
    data class Scroll(val dx: Int, val dy: Int, val x: Double, val y: Double) : DisplayAction
    data class Key(val key: ControlKey, val down: Boolean) : DisplayAction
    data class Text(val text: String) : DisplayAction
}

/**
 * The controller's side of one control session (docs/protocol.md "Mac screen to phone", Control): it owns the binding
 * (session, transport, connection, stream), the acknowledged geometry and the packet sequence. It numbers packets
 * only when they go: pointer motion and scroll are coalesced first, key and button transitions are kept in order and
 * never dropped once numbered, and every class keeps under the host's budgets (a little below them, so a burst on the
 * network never reaches the host's limit). geometry_ack goes first and after every geometry change, which also drops
 * everything not yet sent. Stop is never rate limited. Thread safe.
 */
class DisplayController(private val clock: () -> Long, private val rates: Rates = Rates()) {
    /** Packets a second; the host allows 120, 20 and 10. */
    data class Rates(val motion: Int = 100, val discrete: Int = 16, val control: Int = 8)

    class Binding(val transport: Long, connection: ByteArray, val stream: Long) {
        val connection: ByteArray = connection.copyOf()
    }

    private sealed interface Entry {
        data class Pointer(val x: Double, val y: Double) : Entry
        data class Scroll(var dx: Long, var dy: Long, var x: Double, var y: Double) : Entry
        data class Discrete(val input: ControlInput) : Entry
    }

    private class Bucket(private val rate: Int, now: Long) {
        private var tokens = rate * 1_000L
        private var updated = now

        fun take(now: Long): Boolean {
            val elapsed = (now - updated).coerceIn(0, 1_000)
            tokens = minOf(rate * 1_000L, tokens + elapsed * rate)
            updated = maxOf(updated, now)
            if (tokens < 1_000) return false
            tokens -= 1_000
            return true
        }
    }

    private val lock = Any()
    private var session = 0L
    private var binding: Binding? = null
    private var geometry = 0L
    private var input = InputCapabilities()
    private var sequence = 0L
    private val queue = ArrayDeque<Entry>()
    private var motion = Bucket(rates.motion, 0)
    private var discrete = Bucket(rates.discrete, 0)
    private var control = Bucket(rates.control, 0)
    private var lastHeartbeat = 0L
    private val heldButtons = mutableSetOf<ControlButton>()
    private val heldKeys = mutableSetOf<ControlKey>()

    /** Input refused here: unsupported, invalid, an unmatched transition or a full queue. */
    @Volatile var dropped = 0
        private set

    val active: Boolean get() = synchronized(lock) { binding != null }

    /** The negotiated input of the running session (all false when none). */
    val negotiated: InputCapabilities get() = synchronized(lock) { if (binding == null) InputCapabilities() else input }

    /** The geometry generation input is bound to now, 0 without a session. */
    val acknowledgedGeometry: Long get() = synchronized(lock) { if (binding == null) 0 else geometry }

    /** The host answered `active`: a new session, starting with geometry_ack for [geometryGeneration]. */
    fun begin(session: Long, input: InputCapabilities, binding: Binding, geometryGeneration: Long): List<ControlPacket> = synchronized(lock) {
        clearLocked()
        if (!ScreenControl.validCounter(session) || !ScreenControl.validCounter(geometryGeneration) ||
            !ScreenControl.validCounter(binding.transport) || !ScreenControl.validCounter(binding.stream) ||
            binding.connection.size != ScreenControl.CONNECTION_BYTES || binding.connection.all { it == 0.toByte() }
        ) return emptyList()
        val now = clock()
        this.session = session
        this.binding = binding
        this.input = input
        geometry = geometryGeneration
        sequence = 0
        motion = Bucket(rates.motion, now)
        discrete = Bucket(rates.discrete, now)
        control = Bucket(rates.control, now)
        lastHeartbeat = now
        listOfNotNull(packetLocked(ControlInput.GeometryAck))
    }

    /**
     * A new geometry generation: everything not sent yet is dropped (the host has already released held buttons and
     * keys) and the new generation is acknowledged before anything else goes.
     */
    fun geometryChanged(generation: Long): List<ControlPacket> = synchronized(lock) {
        if (binding == null || generation <= geometry) return emptyList()
        queue.clear()
        heldButtons.clear()
        heldKeys.clear()
        geometry = generation
        // Stop and geometry_ack keep the session's liveness; acknowledging is never held back by the budget.
        lastHeartbeat = clock()
        listOfNotNull(packetLocked(ControlInput.GeometryAck))
    }

    /** Queues one action; false when there is no session or it was refused. Nothing is numbered until [flush]. */
    fun submit(action: DisplayAction): Boolean = synchronized(lock) {
        if (binding == null) return false
        val accepted = when (action) {
            is DisplayAction.Pointer -> input.pointer && valid(action.x, action.y) && run {
                val last = queue.lastOrNull()
                when {
                    last is Entry.Pointer -> queue[queue.size - 1] = Entry.Pointer(action.x, action.y)
                    // Behind a full queue a position is out of date before it could go: the next one replaces it.
                    queue.size >= MAX_QUEUE -> return@run false
                    else -> queue.addLast(Entry.Pointer(action.x, action.y))
                }
                true
            }
            is DisplayAction.Scroll -> input.pointer && valid(action.x, action.y) && (action.dx != 0 || action.dy != 0) && run {
                val last = queue.lastOrNull()
                when {
                    last is Entry.Scroll -> { last.dx += action.dx; last.dy += action.dy; last.x = action.x; last.y = action.y }
                    queue.size >= MAX_QUEUE -> return@run false
                    else -> queue.addLast(Entry.Scroll(action.dx.toLong(), action.dy.toLong(), action.x, action.y))
                }
                true
            }
            is DisplayAction.Button -> input.pointer && valid(action.x, action.y) && run {
                val held = action.button in heldButtons
                if (held == action.down || (action.down && queue.size >= MAX_QUEUE)) return@run false
                if (action.down) heldButtons += action.button else heldButtons -= action.button
                queue.addLast(Entry.Discrete(ControlInput.Button(action.button, action.down, action.x, action.y)))
                true
            }
            is DisplayAction.Key -> input.keys && action.key in SENDABLE_KEYS && run {
                val held = action.key in heldKeys
                if (held == action.down || (action.down && queue.size >= MAX_QUEUE)) return@run false
                if (action.down) heldKeys += action.key else heldKeys -= action.key
                queue.addLast(Entry.Discrete(ControlInput.Key(action.key, action.down)))
                true
            }
            is DisplayAction.Text -> input.text && ScreenControl.validText(action.text) && queue.size < MAX_QUEUE && run {
                queue.addLast(Entry.Discrete(ControlInput.Text(action.text)))
                true
            }
        }
        if (!accepted) dropped++
        accepted
    }

    /** One press and release of [key], as two transitions. */
    fun press(key: ControlKey, shift: Boolean = false): Boolean = synchronized(lock) {
        if (binding == null || !input.keys) return false
        if (shift && !submit(DisplayAction.Key(ControlKey.SHIFT, true))) return false
        val down = submit(DisplayAction.Key(key, true))
        if (down) submit(DisplayAction.Key(key, false))
        if (shift) submit(DisplayAction.Key(ControlKey.SHIFT, false))
        down
    }

    /** The packets that may go now, numbered in order; a heartbeat every 2 seconds. */
    fun flush(): List<ControlPacket> = synchronized(lock) {
        if (binding == null) return emptyList()
        val now = clock()
        val out = mutableListOf<ControlPacket>()
        while (queue.isNotEmpty()) {
            val head = queue.first()
            val bucket = if (head is Entry.Discrete) discrete else motion
            if (!bucket.take(now)) break
            val input = when (head) {
                is Entry.Pointer -> { queue.removeFirst(); ControlInput.Pointer(head.x, head.y) }
                is Entry.Discrete -> { queue.removeFirst(); head.input }
                is Entry.Scroll -> {
                    // Within the contract's bounds per packet; the rest stays at the head for the next one.
                    val dx = head.dx.coerceIn(-ScreenControl.MAX_SCROLL.toLong(), ScreenControl.MAX_SCROLL.toLong())
                    val dy = head.dy.coerceIn(-ScreenControl.MAX_SCROLL.toLong(), ScreenControl.MAX_SCROLL.toLong())
                    head.dx -= dx
                    head.dy -= dy
                    if (head.dx == 0L && head.dy == 0L) queue.removeFirst()
                    if (dx == 0L && dy == 0L) continue
                    ControlInput.Scroll(dx.toInt(), dy.toInt(), head.x, head.y)
                }
            }
            out += packetLocked(input) ?: return out
        }
        if (now - lastHeartbeat >= ScreenControl.HEARTBEAT_MILLIS && control.take(now)) {
            lastHeartbeat = now
            packetLocked(ControlInput.Heartbeat)?.let(out::add)
        }
        out
    }

    /** The person ended control: the stop packet (never rate limited), then nothing more. Null without a session. */
    fun stop(): ControlPacket? = synchronized(lock) {
        if (binding == null) return null
        val packet = packetLocked(ControlInput.Stop)
        clearLocked()
        packet
    }

    /** Control ended elsewhere (the host, a disconnect, the stream, permission loss): pending input is dropped. */
    fun end() = synchronized(lock) { clearLocked() }

    /** Actions waiting for their budget (tests and the log). */
    val pending: Int get() = synchronized(lock) { queue.size }

    private fun packetLocked(input: ControlInput): ControlPacket? {
        val current = binding ?: return null
        if (sequence >= ScreenControl.MAX_SEQUENCE) {
            // Exhausted: the session stops rather than wrapping.
            clearLocked()
            return null
        }
        sequence += 1
        return ControlPacket(session, current.transport, current.connection, current.stream, geometry, sequence, input)
    }

    private fun clearLocked() {
        binding = null
        session = 0
        geometry = 0
        sequence = 0
        input = InputCapabilities()
        queue.clear()
        heldButtons.clear()
        heldKeys.clear()
    }

    private fun valid(x: Double, y: Double) = ScreenControl.validCoordinate(x) && ScreenControl.validCoordinate(y)

    companion object {
        const val MAX_QUEUE = 64

        /** The Mac host takes the named keys and Shift; Control, Option and Command never go. */
        val SENDABLE_KEYS: Set<ControlKey> = ControlKey.entries.toSet() - setOf(ControlKey.CONTROL, ControlKey.ALT, ControlKey.META)
    }
}
