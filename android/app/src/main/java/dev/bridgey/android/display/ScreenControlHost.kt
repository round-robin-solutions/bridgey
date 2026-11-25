package dev.bridgey.android.display

/*
 * The shared contract's host reducer (bridgey-screen-control-draft1), ported from rust/proto/src/screen_control.rs with
 * the same rules: this phone is the input host when a Mac controls it (docs/protocol.md "Mac controls the phone").
 * Pure: no capture, no injection, no permission. The adapter owns grants, permissions, capture and injection and passes
 * a fresh local authority snapshot plus the sender's authenticated binding; neither comes from packet JSON. Every
 * transition's release must be applied before dispatching another native input. Not thread safe: one owner.
 */

/** The pinned identity, not a display name or a self-reported platform. Host-local only. */
class PeerIdentity(device: ByteArray, keySha256: ByteArray) {
    private val deviceBytes = device.copyOf()
    private val keyBytes = keySha256.copyOf()

    fun valid(): Boolean = deviceBytes.size == 16 && keyBytes.size == 32 && deviceBytes.any { it != 0.toByte() } && keyBytes.any { it != 0.toByte() }

    override fun equals(other: Any?): Boolean = other is PeerIdentity && deviceBytes.contentEquals(other.deviceBytes) && keyBytes.contentEquals(other.keyBytes)
    override fun hashCode(): Int = 31 * deviceBytes.contentHashCode() + keyBytes.contentHashCode()
    override fun toString(): String = "PeerIdentity(..)"
}

/** `transport` is a host-issued generation of an authenticated encrypted transport; `connection` its 16-byte nonce. */
class ControlBinding(val peer: PeerIdentity, val transport: Long, connection: ByteArray) {
    private val connectionBytes = connection.copyOf()
    val connection: ByteArray get() = connectionBytes.copyOf()

    internal fun connectionMatches(bytes: ByteArray) = connectionBytes.contentEquals(bytes)
    internal val connectionValid: Boolean get() = connectionBytes.size == ScreenControl.CONNECTION_BYTES && connectionBytes.any { it != 0.toByte() }

    override fun equals(other: Any?): Boolean =
        other is ControlBinding && peer == other.peer && transport == other.transport && connectionBytes.contentEquals(other.connectionBytes)
    override fun hashCode(): Int = (peer.hashCode() * 31 + transport.hashCode()) * 31 + connectionBytes.contentHashCode()
    override fun toString(): String = "ControlBinding(transport=$transport)"
}

/**
 * Fresh LOCAL state, supplied on every input and on every permission, grant or lifecycle event. The adapter advances
 * [generation] whenever any of it changes. Persistent grants stay in the host's own storage; nothing here syncs them.
 */
data class ControlAuthority(
    val generation: Long,
    val binding: ControlBinding,
    val stream: Long,
    val trustedDevice: Boolean,
    val viewGrant: Boolean,
    val controlGrant: Boolean,
    val captureReady: Boolean,
    /** Permission AND the native target's eligibility for the attempted operation (keyboard: editor on the shared display). */
    val inputReady: Boolean,
    val unlocked: Boolean,
    val streamActive: Boolean,
    val host: Capabilities,
    val controller: Capabilities,
)

/** What the host holds down: bit per button, named key and contact. */
data class HeldInput(val buttons: Int = 0, val keys: Int = 0, val contacts: Int = 0) {
    val isEmpty: Boolean get() = buttons == 0 && keys == 0 && contacts == 0
    val heldButtons: List<ControlButton> get() = ControlButton.entries.filter { buttons and (1 shl it.ordinal) != 0 }
    val heldKeys: List<ControlKey> get() = ControlKey.entries.filter { keys and (1 shl it.ordinal) != 0 }
    val heldContacts: List<Int> get() = (0 until ScreenControl.MAX_CONTACTS).filter { contacts and (1 shl it) != 0 }
}

enum class ControlRejection {
    VERSION, UNSUPPORTED, IDENTITY, COUNTER, GRANT, PERMISSION, LOCKED, NO_STREAM, BUSY, AUTHORITY_REPLAY, BINDING, SESSION,
    REPLAY, GEOMETRY, GEOMETRY_NOT_ACKNOWLEDGED, COORDINATES, INVALID_INPUT, RATE, PACKET_SIZE, MALFORMED, CLOCK, EXHAUSTED,
}

enum class ControlStopReason {
    USER, AUTHORITY_CHANGED, PERMISSION_LOST, REVOKED, LOCKED, DISCONNECTED, TIMEOUT, SEQUENCE_GAP, SOURCE_CHANGED,
    GEOMETRY_INVALID, RATE_LIMITED, INVALID_INPUT, CLOCK, EXHAUSTED,
}

sealed interface ControlStatus {
    data object Accepted : ControlStatus
    data class Rejected(val reason: ControlRejection) : ControlStatus
    data class Stopped(val reason: ControlStopReason) : ControlStatus
}

/** Native code must release every indicated button, key and contact, even on rejection or stop. */
data class ControlTransition(val status: ControlStatus, val release: HeldInput = HeldInput()) {
    companion object {
        val ACCEPTED = ControlTransition(ControlStatus.Accepted)
        fun rejected(reason: ControlRejection) = ControlTransition(ControlStatus.Rejected(reason))
    }
}

class ControlSessionInfo(val session: Long, val transport: Long, connection: ByteArray, val stream: Long, val geometry: Geometry) {
    private val connectionBytes = connection.copyOf()
    val connection: ByteArray get() = connectionBytes.copyOf()

    fun withGeometry(geometry: Geometry) = ControlSessionInfo(session, transport, connectionBytes, stream, geometry)

    internal fun sameBinding(other: ControlSessionInfo) =
        session == other.session && transport == other.transport && connectionBytes.contentEquals(other.connectionBytes) && stream == other.stream

    override fun equals(other: Any?): Boolean = other is ControlSessionInfo && sameBinding(other) && geometry == other.geometry
    override fun hashCode(): Int = listOf(session, transport, connectionBytes.contentHashCode(), stream, geometry).hashCode()
    override fun toString(): String = "ControlSessionInfo(session=$session, stream=$stream, geometry=${geometry.generation})"
}

/** One selected controller per reducer. Session IDs are host-issued and monotonic, never secret capabilities. */
class ScreenControlHost {
    private class Bucket(private val rate: Long, now: Long) {
        private var tokens = rate * 1_000
        private var updated = now

        fun take(now: Long): Boolean {
            // The caller rejects clock reversal first. Refill at most one capacity.
            val refill = (now - updated).coerceIn(0, 1_000) * rate
            tokens = minOf(tokens + refill, rate * 1_000)
            updated = now
            if (tokens < 1_000) return false
            tokens -= 1_000
            return true
        }
    }

    private class Active(
        var info: ControlSessionInfo,
        val authority: ControlAuthority,
        val input: InputCapabilities,
        now: Long,
    ) {
        var acknowledged = false
        var sequence = 0L
        var lastValid = now
        var lastClock = now
        var held = HeldInput()
        val motion = Bucket(120, now)
        val discrete = Bucket(20, now)
        val control = Bucket(10, now)
    }

    private var highestAuthority = 0L
    private var observedAuthority: ControlAuthority? = null
    private var blockedAuthority = false
    private var lastSession = 0L
    private var active: Active? = null

    val info: ControlSessionInfo? get() = active?.info
    val held: HeldInput get() = active?.held ?: HeldInput()
    val acknowledged: Boolean get() = active?.acknowledged ?: false
    val isActive: Boolean get() = active != null

    /** Tests only: counters at their limits. */
    internal fun testingSetLastSession(value: Long) { lastSession = value }
    internal fun testingSetSequence(value: Long) { active?.sequence = value }

    /** A new control session bound to [authority]'s binding and stream and to [geometry]; input waits for its ACK. */
    fun begin(authority: ControlAuthority, geometry: Geometry, now: Long): Result<ControlSessionInfo> {
        if (active != null) return failure(ControlRejection.BUSY)
        val input = checkAuthority(authority).getOrElse { return Result.failure(it) }
        if (!geometry.valid() || geometry.kind != SourceKind.DISPLAY) return failure(ControlRejection.GEOMETRY)
        if (lastSession >= ScreenControl.MAX_SEQUENCE) return failure(ControlRejection.EXHAUSTED)
        lastSession += 1
        val info = ControlSessionInfo(lastSession, authority.binding.transport, authority.binding.connection, authority.stream, geometry)
        active = Active(info, authority, input, now)
        return Result.success(info)
    }

    /** Call at once on grant, permission, connection and lock events, not only on incoming packets. */
    fun synchronize(authority: ControlAuthority): ControlTransition {
        val obsolete = ScreenControl.validCounter(authority.generation) && authority.generation < highestAuthority
        val checked = checkAuthority(authority)
        val current = active ?: return checked.fold({ ControlTransition.ACCEPTED }, { ControlTransition.rejected(reasonOf(it)) })
        checked.exceptionOrNull()?.let {
            // An old asynchronous native callback cannot tear down a newer valid session.
            if (obsolete) return ControlTransition.rejected(reasonOf(it))
            return stop(stopReasonFor(reasonOf(it)))
        }
        if (authority != current.authority) return stop(ControlStopReason.AUTHORITY_CHANGED)
        return ControlTransition.ACCEPTED
    }

    /** New captured dimensions fence all input until an ordered ACK of the new generation. A new source stops. */
    fun geometryChanged(expected: ControlSessionInfo, geometry: Geometry): ControlTransition {
        val current = active ?: return ControlTransition.rejected(ControlRejection.NO_STREAM)
        if (!expected.sameBinding(current.info)) return ControlTransition.rejected(ControlRejection.SESSION)
        if (!geometry.valid()) return stop(ControlStopReason.GEOMETRY_INVALID)
        if (geometry.generation == current.info.geometry.generation && geometry != current.info.geometry) return stop(ControlStopReason.GEOMETRY_INVALID)
        if (geometry.generation <= current.info.geometry.generation) return ControlTransition.rejected(ControlRejection.GEOMETRY)
        if (geometry.source != current.info.geometry.source || geometry.kind != SourceKind.DISPLAY) return stop(ControlStopReason.SOURCE_CHANGED)
        val release = current.held
        current.held = HeldInput()
        current.info = current.info.withGeometry(geometry)
        current.acknowledged = false
        return ControlTransition(ControlStatus.Accepted, release)
    }

    /** Stop is never rate limited, and held state is returned exactly once. */
    fun stop(reason: ControlStopReason): ControlTransition {
        val current = active
        active = null
        // Also burns an observed authority whose asynchronous native begin is still pending.
        blockedAuthority = true
        return ControlTransition(ControlStatus.Stopped(reason), current?.held ?: HeldInput())
    }

    fun tick(now: Long): ControlTransition {
        val current = active ?: return ControlTransition.rejected(ControlRejection.NO_STREAM)
        if (now < current.lastClock) return stop(ControlStopReason.CLOCK)
        current.lastClock = now
        if (now - current.lastValid >= ScreenControl.IDLE_MILLIS) return stop(ControlStopReason.TIMEOUT)
        return ControlTransition.ACCEPTED
    }

    fun receive(authority: ControlAuthority, sender: ControlBinding, packet: ControlPacket, now: Long): ControlTransition {
        val authorityResult = synchronize(authority)
        if (authorityResult.status != ControlStatus.Accepted) return authorityResult
        val timeResult = tick(now)
        if (timeResult.status != ControlStatus.Accepted) return timeResult
        val current = active ?: return ControlTransition.rejected(ControlRejection.NO_STREAM)
        if (sender != current.authority.binding || packet.transport != sender.transport || !sender.connectionMatches(packet.connection)) {
            return ControlTransition.rejected(ControlRejection.BINDING)
        }
        if (packet.v != ScreenControl.VERSION) return ControlTransition.rejected(ControlRejection.VERSION)
        if (packet.session != current.info.session || packet.stream != current.info.stream) return ControlTransition.rejected(ControlRejection.SESSION)
        if (!ScreenControl.validCounter(packet.seq)) return ControlTransition.rejected(ControlRejection.COUNTER)
        if (packet.seq <= current.sequence) return ControlTransition.rejected(ControlRejection.REPLAY)
        val next = current.sequence + 1
        if (!ScreenControl.validCounter(next)) return stop(ControlStopReason.EXHAUSTED)
        if (packet.seq != next) return stop(ControlStopReason.SEQUENCE_GAP)
        // An authenticated ordered header is consumed even if its payload is rejected; invalid input never refreshes liveness.
        current.sequence = packet.seq
        if (packet.input == ControlInput.Stop) return stop(ControlStopReason.USER)
        if (packet.seq == ScreenControl.MAX_SEQUENCE) return stop(ControlStopReason.EXHAUSTED)
        if (packet.geometry != current.info.geometry.generation) {
            if (!current.held.isEmpty) return stop(ControlStopReason.GEOMETRY_INVALID)
            return ControlTransition.rejected(ControlRejection.GEOMETRY)
        }
        if (packet.input == ControlInput.GeometryAck || packet.input == ControlInput.Heartbeat) {
            if (!current.control.take(now)) return ControlTransition.rejected(ControlRejection.RATE)
            if (packet.input == ControlInput.GeometryAck) current.acknowledged = true
            current.lastValid = now
            return ControlTransition.ACCEPTED
        }
        if (!current.acknowledged) return ControlTransition.rejected(ControlRejection.GEOMETRY_NOT_ACKNOWLEDGED)
        val motion = packet.input.isMotion
        validate(packet.input, current.input, current.info.geometry, current.held)?.let { reason ->
            if (!motion && !current.held.isEmpty) return stop(ControlStopReason.INVALID_INPUT)
            return ControlTransition.rejected(reason)
        }
        val allowed = if (motion) current.motion.take(now) else current.discrete.take(now)
        if (!allowed) {
            // Never silently drop a key, button or touch transition and leave a native hold stuck.
            if (!motion) return stop(ControlStopReason.RATE_LIMITED)
            return ControlTransition.rejected(ControlRejection.RATE)
        }
        val held = current.held
        current.held = when (val input = packet.input) {
            is ControlInput.Button -> held.copy(buttons = setBit(held.buttons, input.button.ordinal, input.down))
            is ControlInput.Key -> held.copy(keys = setBit(held.keys, input.key.ordinal, input.down))
            is ControlInput.Touch -> when (input.phase) {
                TouchPhase.DOWN -> held.copy(contacts = setBit(held.contacts, input.contact, true))
                TouchPhase.UP -> held.copy(contacts = setBit(held.contacts, input.contact, false))
                TouchPhase.MOVE -> held
            }
            else -> held
        }
        current.lastValid = now
        return ControlTransition.ACCEPTED
    }

    private fun checkAuthority(authority: ControlAuthority): Result<InputCapabilities> {
        if (!ScreenControl.validCounter(authority.generation) || !ScreenControl.validCounter(authority.binding.transport) ||
            !ScreenControl.validCounter(authority.stream)
        ) return failure(ControlRejection.COUNTER)
        if (authority.generation < highestAuthority) return failure(ControlRejection.AUTHORITY_REPLAY)
        if (authority.generation > highestAuthority) {
            highestAuthority = authority.generation
            observedAuthority = authority
            blockedAuthority = false
        } else if (blockedAuthority || observedAuthority != authority) {
            // Reusing one generation for different state burns it, so an older enabled snapshot cannot restart it.
            blockedAuthority = true
            return failure(ControlRejection.AUTHORITY_REPLAY)
        }
        if (!authority.binding.peer.valid() || !authority.trustedDevice) return failure(ControlRejection.IDENTITY)
        if (!authority.binding.connectionValid) return failure(ControlRejection.BINDING)
        if (!authority.viewGrant || !authority.controlGrant) return failure(ControlRejection.GRANT)
        if (!authority.unlocked) return failure(ControlRejection.LOCKED)
        if (!authority.captureReady || !authority.inputReady) return failure(ControlRejection.PERMISSION)
        if (!authority.streamActive) return failure(ControlRejection.NO_STREAM)
        return Capabilities.negotiatedInput(authority.host, authority.controller)?.let { Result.success(it) } ?: failure(ControlRejection.UNSUPPORTED)
    }

    private class Refusal(val reason: ControlRejection) : Exception(reason.name, null, false, false)

    private fun <T> failure(reason: ControlRejection): Result<T> = Result.failure(Refusal(reason))

    companion object {
        /** The rejection inside a failed [begin] result. */
        fun reasonOf(error: Throwable): ControlRejection = (error as? Refusal)?.reason ?: ControlRejection.MALFORMED

        fun stopReasonFor(reason: ControlRejection): ControlStopReason = when (reason) {
            ControlRejection.GRANT, ControlRejection.IDENTITY -> ControlStopReason.REVOKED
            ControlRejection.PERMISSION -> ControlStopReason.PERMISSION_LOST
            ControlRejection.LOCKED -> ControlStopReason.LOCKED
            ControlRejection.NO_STREAM -> ControlStopReason.DISCONNECTED
            else -> ControlStopReason.AUTHORITY_CHANGED
        }

        private fun setBit(value: Int, bit: Int, on: Boolean): Int = if (on) value or (1 shl bit) else value and (1 shl bit).inv()

        fun validate(input: ControlInput, capabilities: InputCapabilities, geometry: Geometry, held: HeldInput): ControlRejection? {
            when (input) {
                is ControlInput.Pointer -> {
                    if (!capabilities.pointer) return ControlRejection.UNSUPPORTED
                    if (geometry.pixel(input.x, input.y) == null) return ControlRejection.COORDINATES
                }
                is ControlInput.Button -> {
                    if (!capabilities.pointer) return ControlRejection.UNSUPPORTED
                    if (geometry.pixel(input.x, input.y) == null) return ControlRejection.COORDINATES
                    if ((held.buttons and (1 shl input.button.ordinal) != 0) == input.down) return ControlRejection.INVALID_INPUT
                }
                is ControlInput.Scroll -> {
                    if (!capabilities.pointer) return ControlRejection.UNSUPPORTED
                    if (geometry.pixel(input.x, input.y) == null) return ControlRejection.COORDINATES
                    val bound = ScreenControl.MAX_SCROLL
                    if (input.dx !in -bound..bound || input.dy !in -bound..bound || (input.dx == 0 && input.dy == 0)) return ControlRejection.INVALID_INPUT
                }
                is ControlInput.Key -> {
                    if (!capabilities.keys) return ControlRejection.UNSUPPORTED
                    if ((held.keys and (1 shl input.key.ordinal) != 0) == input.down) return ControlRejection.INVALID_INPUT
                }
                is ControlInput.Text -> {
                    if (!capabilities.text) return ControlRejection.UNSUPPORTED
                    if (!ScreenControl.validText(input.text)) return ControlRejection.INVALID_INPUT
                }
                is ControlInput.Navigate -> if (!capabilities.navigation) return ControlRejection.UNSUPPORTED
                is ControlInput.Touch -> {
                    if (!capabilities.touch) return ControlRejection.UNSUPPORTED
                    if (input.contact >= ScreenControl.MAX_CONTACTS || geometry.pixel(input.x, input.y) == null) return ControlRejection.COORDINATES
                    val isHeld = held.contacts and (1 shl input.contact) != 0
                    if ((input.phase == TouchPhase.DOWN) == isHeld) return ControlRejection.INVALID_INPUT
                }
                ControlInput.GeometryAck, ControlInput.Heartbeat, ControlInput.Stop -> Unit
            }
            return null
        }
    }
}
