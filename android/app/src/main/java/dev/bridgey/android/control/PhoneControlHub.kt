package dev.bridgey.android.control

import dev.bridgey.android.display.Capabilities
import dev.bridgey.android.display.ControlAuthority
import dev.bridgey.android.display.ControlBinding
import dev.bridgey.android.display.ControlButton
import dev.bridgey.android.display.ControlInput
import dev.bridgey.android.display.ControlKey
import dev.bridgey.android.display.ControlPacket
import dev.bridgey.android.display.ControlSessionInfo
import dev.bridgey.android.display.ControlStatus
import dev.bridgey.android.display.ControlStopReason
import dev.bridgey.android.display.ControlTransition
import dev.bridgey.android.display.Geometry
import dev.bridgey.android.display.HeldInput
import dev.bridgey.android.display.InputCapabilities
import dev.bridgey.android.display.PeerIdentity
import dev.bridgey.android.display.ScreenControlHost
import dev.bridgey.android.display.TouchPhase
import dev.bridgey.android.screen.ScreenKinds
import java.security.MessageDigest
import java.util.concurrent.Executor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/** How control messages reach the Mac: in the stream's own sequence, bound to the session the stream started on. */
interface ControlStreamLink {
    val streamId: String

    /** The session's 16-byte contract nonce (ScreenControl.connectionNonce). */
    val connection: ByteArray

    /** Sends screen.geometry or screen.control with the next stream sequence; false when the stream or session is gone. */
    fun send(kind: String, payload: (sequence: Long) -> JSONObject): Boolean
}

/** The accessibility service while it is connected: gestures, global actions, typing and the indicator. */
interface ControlService : GestureSink {
    /** Typing works (Android 13 and later, with the accessibility input method). */
    val canType: Boolean
    fun showIndicator(macName: String, onStop: () -> Unit)
    fun hideIndicator()

    /** Ask each time on the screen itself, with Don't allow and Allow; [answer] runs on any thread. */
    fun showPrompt(macName: String, answer: (Boolean) -> Unit)
    fun hidePrompt()

    /** The bar for a screenshot share (unattended access): "MacBook Air is viewing this phone" with Stop. Control's bar wins. */
    fun showViewing(macName: String, onStop: () -> Unit) {}
    fun hideViewing() {}
}

/** What the hub needs from the rest of the app; a fake in tests. */
interface PhoneControlEnvironment {
    val sdkInt: Int
    /** This build has phone control (not the Play build). */
    val built: Boolean
    fun identityKey(deviceId: String): String?
    fun isAgent(deviceId: String): Boolean
    fun trusted(deviceId: String): Boolean
    /** Share screen with Macs is on here for that Mac. */
    fun viewGrant(deviceId: String): Boolean
    /** The Mac's latest map shows phone_control_draft1 (and screen_draft1). */
    fun macAdvertises(deviceId: String): Boolean
    fun unlocked(): Boolean
    /** Another display than the one shared is on: typing could land where the Mac cannot see. */
    fun otherDisplayActive(): Boolean
    /** The accessibility service, when it is connected. */
    fun service(): ControlService?
    /** The service is turned on in Android settings (it may still be connecting). */
    fun serviceEnabled(): Boolean
    fun showPrompt(deviceId: String, macName: String, promptId: Long)
    fun dismissPrompt()
    /** The sharing notification says whether a Mac controls the phone now. */
    fun controlling(macName: String?)
    /** A grant changed: features.update goes to that Mac. */
    fun grantsChanged(deviceId: String)
    /** Unattended access changed: features.update goes to every connected Mac. */
    fun unattendedChanged() {}
    fun record(event: String, deviceId: String, detail: String) {}
    fun log(message: String) {}
}

/** What Settings and the UI show. */
data class PhoneControlViewState(
    val phase: Phase = Phase.OFF,
    val deviceId: String? = null,
    val macName: String? = null,
) {
    enum class Phase { OFF, ASKING, ACTIVE }

    val active: Boolean get() = phase == Phase.ACTIVE
}

/**
 * The Mac controls the phone (draft phone_control_draft1, docs/protocol.md "Mac controls the phone"). Lives beside the
 * screen share: a control-capable stream gets a context here; control inside it goes through the shared contract's
 * HostSession with a fresh local authority on every packet, every release is applied before anything else, and accepted
 * input becomes gestures through [GestureExecutor]. Everything runs on [executor], one thread; public methods post to it.
 */
class PhoneControlHub(
    private val environment: PhoneControlEnvironment,
    val grants: PhoneControlGrants,
    private val executor: Executor,
    private val timers: ControlTimers,
    private val clock: () -> Long,
    private val touchSlop: Double = 0.0,
    /** Wall time of each accepted input, kept in memory for latency checks (never positions, keys or text). */
    private val wallClock: () -> Long = System::currentTimeMillis,
) {
    private val mutableState = MutableStateFlow(PhoneControlViewState())
    val state: StateFlow<PhoneControlViewState> = mutableState.asStateFlow()

    private enum class Phase { OFF, ASKING, ACTIVE }

    private class Live(
        val link: ControlStreamLink,
        val deviceId: String,
        val macName: String,
        val stream: Long,
        val transport: Long,
        var geometry: Geometry,
        var displayWidth: Int,
        var displayHeight: Int,
    ) {
        var started = false
        var phase = Phase.OFF
        var sessionAllowed = false
        var controller: Capabilities? = null
        var info: ControlSessionInfo? = null
        var promptId = 0L
        var cancelPrompt: () -> Unit = {}
        var cancelTick: () -> Unit = {}
        var allowedSent: Boolean? = null
        var ineligible: PhoneControlReason? = null
        var accepted = 0
        var rejected = 0
    }

    private var live: Live? = null
    private val host = ScreenControlHost()
    private var authorityGeneration = 0L
    private var lastAuthority: ControlAuthority? = null
    private var streamCounter = 0L
    private var transportCounter = 0L
    private var promptCounter = 0L
    private var gestures: GestureExecutor? = null
    private val arrivals = ArrayDeque<Pair<Long, Long>>()
    private var gesturesService: ControlService? = null

    /** Set the moment Stop is pressed, so input already queued behind it on [executor] is dropped. */
    @Volatile private var localStopPending = false

    /** Raised to Ask or Allow without asking: refused while a Mac controls this phone, so it cannot grant itself. */
    @Volatile var controllingNow = false
        private set

    private fun log(message: String) = environment.log(message)

    private fun subject(deviceId: String) = GrantSubject(deviceId, environment.identityKey(deviceId), environment.isAgent(deviceId))

    fun mode(deviceId: String): PhoneControlGrantMode = if (!environment.built) PhoneControlGrantMode.OFF else grants.mode(subject(deviceId))

    /** The choice made for a Mac, or null for Default (it follows [unattended]). */
    fun choice(deviceId: String): PhoneControlGrantMode? = if (!environment.built) null else grants.choice(subject(deviceId))

    /** Settings > Remote control > Unattended access: on by default. */
    val unattended: Boolean get() = grants.unattended

    /**
     * A Mac allowed without asking may see this phone with nobody here: the share skips Bridgey's own question, and when
     * nobody approves Android's video prompt it falls back to accessibility screenshots (ScreenShareHub).
     */
    fun unattendedView(deviceId: String): Boolean =
        environment.built && !environment.isAgent(deviceId) && environment.viewGrant(deviceId) && mode(deviceId) == PhoneControlGrantMode.ALWAYS

    /** phone_control_draft1 in features.update to that Mac. */
    fun advertised(deviceId: String): Boolean =
        environment.built && !environment.isAgent(deviceId) && environment.viewGrant(deviceId) && mode(deviceId) != PhoneControlGrantMode.OFF

    /** A share with this Mac may be controlled: it then asks Android for the whole display. */
    fun controlCapable(deviceId: String): Boolean = advertised(deviceId) && environment.macAdvertises(deviceId)

    /**
     * Settings: a Mac's choice, null for Default. Raising what it may do is refused while any Mac controls this phone (a
     * Mac could otherwise open this screen and allow itself); Default counts as what the switch gives. Lowering always
     * works and ends control at once.
     */
    fun setGrant(deviceId: String, mode: PhoneControlGrantMode?): Boolean {
        val subject = subject(deviceId)
        val before = this.mode(deviceId)
        val after = PhoneControlGrants.resolve(mode, grants.unattended, subject.agent, !subject.identityKey.isNullOrEmpty())
        if (before.raises(after) && controllingNow) return false
        if (!grants.set(subject, mode)) return false
        environment.grantsChanged(deviceId)
        environment.record("phone_control_grant", deviceId, mode?.wire ?: "default")
        policyChanged()
        return true
    }

    /**
     * Settings: Unattended access. Turning it on is refused while any Mac controls this phone, as raising a grant is;
     * turning it off always works and ends control by a Mac on Default at once.
     */
    fun setUnattended(on: Boolean): Boolean {
        if (on == grants.unattended) return true
        if (on && controllingNow) return false
        grants.setUnattended(on)
        environment.unattendedChanged()
        environment.record("phone_control_unattended", "", if (on) "on" else "off")
        policyChanged()
        return true
    }

    fun forget(deviceId: String) {
        grants.remove(deviceId)
        policyChanged()
    }

    // MARK: The stream

    /** The control of one control-capable share, for its ScreenStream. Android's display ID is the default display. */
    fun attach(link: ControlStreamLink, deviceId: String, macName: String, displayId: Int = 0): dev.bridgey.android.screen.StreamControl =
        object : dev.bridgey.android.screen.StreamControl {
            override fun offer(width: Int, height: Int, displayWidth: Int, displayHeight: Int): JSONObject =
                streamStarting(link, deviceId, macName, displayId, width, height, displayWidth, displayHeight).toJson()
            override fun started() = streamStarted(link)
            override fun resized(width: Int, height: Int, displayWidth: Int, displayHeight: Int) = geometryChanged(link, width, height, displayWidth, displayHeight)
            override fun mac(message: MacControlMessage) = macControl(link, message)
            override fun ended() = streamEnded(link)
        }

    /**
     * A control-capable share started with [deviceId]: the control object for its screen.start. [width] by [height] is the
     * stream, [displayWidth] by [displayHeight] the real display in its current rotation.
     */
    fun streamStarting(
        link: ControlStreamLink, deviceId: String, macName: String, displayId: Int,
        width: Int, height: Int, displayWidth: Int, displayHeight: Int,
    ): PhoneControlOffer {
        val stream = ++streamCounter
        val transport = ++transportCounter
        val geometry = phoneStreamGeometry(1, displayId, width, height)
        val created = Live(link, deviceId, macName, stream, transport, geometry, displayWidth, displayHeight)
        executor.execute {
            live?.let { end(it, ControlStopReason.SOURCE_CHANGED, tell = false) }
            live = created
            created.allowedSent = allowedNow(created)
        }
        return PhoneControlOffer(stream, transport, geometry, phoneHostCapabilities(environment.sdkInt), allowedNow(created))
    }

    /** The Mac answered screen.started: frames flow and control may begin. */
    fun streamStarted(link: ControlStreamLink) = executor.execute {
        val current = live?.takeIf { it.link === link } ?: return@execute
        current.started = true
        syncAvailable(current)
    }

    /** The capture changed size (rotation): a new geometry generation, input fenced until the Mac acknowledges it. */
    fun geometryChanged(link: ControlStreamLink, width: Int, height: Int, displayWidth: Int, displayHeight: Int) = executor.execute {
        val current = live?.takeIf { it.link === link } ?: return@execute
        val old = current.geometry
        if (old.width == width && old.height == height && current.displayWidth == displayWidth && current.displayHeight == displayHeight) return@execute
        val geometry = old.copy(generation = old.generation + 1, width = width, height = height)
        current.geometry = geometry
        current.displayWidth = displayWidth
        current.displayHeight = displayHeight
        val info = current.info
        if (current.phase == Phase.ACTIVE && info != null) {
            val transition = host.geometryChanged(info, geometry)
            if (transition.status is ControlStatus.Stopped) {
                controlStopped(current, transition, reasonFor((transition.status as ControlStatus.Stopped).reason, current))
            } else {
                // Positions map differently now: every finger lifts, whatever the contract still held.
                release(transition.release, force = true)
                current.info = host.info
            }
        }
        current.link.send(ScreenKinds.GEOMETRY) { screenGeometryPayload(current.link.streamId, it, geometry) }
        log("CONTROL geometry generation=${geometry.generation} size=${width}x$height display=${displayWidth}x$displayHeight")
    }

    /** The stream ended (either side, a disconnect, the screen off): control ends without a message. */
    fun streamEnded(link: ControlStreamLink) = executor.execute {
        val current = live?.takeIf { it.link === link } ?: return@execute
        end(current, ControlStopReason.DISCONNECTED, tell = false)
        live = null
    }

    // MARK: From the Mac

    fun macControl(link: ControlStreamLink, message: MacControlMessage) = executor.execute {
        val current = live?.takeIf { it.link === link && it.link.streamId == message.streamId } ?: return@execute
        when (message.action) {
            PhoneControlAction.BEGIN -> begin(current, message.capabilities ?: return@execute)
            PhoneControlAction.END -> when (current.phase) {
                Phase.OFF -> Unit
                Phase.ASKING -> {
                    stopAsking(current)
                    send(current, PhoneControlUpdate.Ended(PhoneControlReason.USER))
                }
                Phase.ACTIVE -> controlStopped(current, host.stop(ControlStopReason.USER), PhoneControlReason.USER)
            }
        }
    }

    /** screen.input from [deviceId], with the nonce of the session it arrived on (the packet cannot name its sender). */
    fun input(deviceId: String, plaintext: ByteArray, arrival: ByteArray) = executor.execute {
        if (localStopPending) return@execute
        val current = live?.takeIf { it.deviceId == deviceId && it.phase == Phase.ACTIVE } ?: return@execute
        val packet = ControlPacket.decode(plaintext)
        if (packet == null) {
            // Malformed input from the controlling Mac ends control and lifts what it held.
            controlStopped(current, host.stop(ControlStopReason.INVALID_INPUT), PhoneControlReason.INVALID)
            return@execute
        }
        val authority = authority(current, packet.input, fresh = false) ?: return@execute
        val sender = ControlBinding(authority.binding.peer, current.transport, arrival)
        val transition = host.receive(authority, sender, packet, clock())
        when (val status = transition.status) {
            ControlStatus.Accepted -> {
                release(transition.release, force = false)
                current.accepted++
                arrivals.addLast(packet.seq to wallClock())
                while (arrivals.size > 64) arrivals.removeFirst()
                if (!inject(current, packet.input)) {
                    controlStopped(current, host.stop(ControlStopReason.RATE_LIMITED), PhoneControlReason.RATE)
                }
            }
            is ControlStatus.Rejected -> {
                release(transition.release, force = false)
                current.rejected++
            }
            is ControlStatus.Stopped -> controlStopped(current, transition, reasonFor(status.reason, current))
        }
    }

    // MARK: On the phone

    /** Allow or Don't allow on the prompt; only the current prompt counts. */
    fun answer(promptId: Long, allowed: Boolean) = executor.execute {
        val current = live?.takeIf { it.phase == Phase.ASKING && it.promptId == promptId } ?: return@execute
        stopAsking(current)
        if (!allowed) {
            send(current, PhoneControlUpdate.Refused(PhoneControlReason.DECLINED))
            environment.record("phone_control_declined", current.deviceId, "prompt")
            return@execute
        }
        current.sessionAllowed = true
        refusal(current)?.let {
            current.sessionAllowed = false
            send(current, PhoneControlUpdate.Refused(it))
            return@execute
        }
        startSession(current)
    }

    /** The prompt showing now, answered by a test runner (the stress build) as its buttons would. */
    fun answerPending(allowed: Boolean) = executor.execute {
        val current = live?.takeIf { it.phase == Phase.ASKING } ?: return@execute
        answer(current.promptId, allowed)
    }

    /** Stop on the indicator or the notification: wins over everything queued. */
    fun stopLocally() {
        localStopPending = true
        executor.execute {
            localStopPending = false
            stopNow()
        }
    }

    private fun stopNow() {
        val current = live ?: return
        when (current.phase) {
            Phase.OFF -> Unit
            Phase.ASKING -> {
                stopAsking(current)
                send(current, PhoneControlUpdate.Refused(PhoneControlReason.DECLINED))
            }
            Phase.ACTIVE -> controlStopped(current, host.stop(ControlStopReason.USER), PhoneControlReason.LOCAL_STOP)
        }
    }

    /**
     * Anything control depends on changed: a grant, Share screen with Macs, the accessibility service, the lock, the
     * displays. Control re-checks its authority at once, and the Mac hears whether it may ask.
     */
    fun policyChanged() = executor.execute {
        val service = environment.service()
        if (service !== gesturesService) {
            // A new or lost service: Android has already cancelled the old one's gestures.
            gestures?.reset()
            gestures = null
            gesturesService = null
        }
        val current = live ?: return@execute
        when (current.phase) {
            Phase.ASKING -> refusal(current)?.let {
                stopAsking(current)
                send(current, PhoneControlUpdate.Refused(it))
            }
            Phase.ACTIVE -> {
                val authority = authority(current, null, fresh = false)
                if (authority == null) {
                    controlStopped(current, host.stop(ControlStopReason.DISCONNECTED), PhoneControlReason.FAILED)
                } else {
                    val transition = host.synchronize(authority)
                    val status = transition.status
                    if (status is ControlStatus.Stopped) controlStopped(current, transition, reasonFor(status.reason, current))
                    else release(transition.release, force = false)
                }
            }
            Phase.OFF -> Unit
        }
        syncAvailable(current)
    }

    /** Live numbers for the stress build's status (milliseconds). */
    fun stats(done: (JSONObject) -> Unit) = executor.execute {
        val current = live
        val gestures = this.gestures
        fun summary(samples: Collection<Long>): JSONObject {
            val sorted = samples.sorted()
            if (sorted.isEmpty()) return JSONObject().put("count", 0)
            fun at(p: Double) = sorted[((sorted.size - 1) * p).toInt()]
            return JSONObject().put("count", sorted.size).put("median", at(0.5)).put("p90", at(0.9)).put("max", sorted.last())
        }
        done(
            JSONObject()
                .put("phase", current?.phase?.name?.lowercase() ?: "none")
                .put("geometry", current?.geometry?.let { JSONObject().put("generation", it.generation).put("width", it.width).put("height", it.height) } ?: JSONObject.NULL)
                .put("display", current?.let { JSONObject().put("width", it.displayWidth).put("height", it.displayHeight) } ?: JSONObject.NULL)
                .put("accepted", current?.accepted ?: 0)
                .put("rejected", current?.rejected ?: 0)
                .put("gestures", gestures?.gestures ?: 0)
                .put("cancelled", gestures?.cancelled ?: 0)
                .put("typingDropped", gestures?.droppedText ?: 0)
                .put("fingers", org.json.JSONArray(gestures?.fingersDown?.toList() ?: emptyList<Int>()))
                .put("dispatchMs", summary(gestures?.dispatchLatency ?: emptyList()))
                .put("completeMs", summary(gestures?.completeLatency ?: emptyList()))
                .put("session", current?.info?.session ?: 0)
                .put("arrivals", org.json.JSONArray(arrivals.map { (seq, at) -> org.json.JSONArray().put(seq).put(at) }))
                .put("service", environment.service() != null)
                .put("serviceEnabled", environment.serviceEnabled()),
        )
    }

    // MARK: Control

    private fun begin(current: Live, controller: Capabilities) {
        if (current.phase != Phase.OFF) return
        current.controller = controller
        refusal(current)?.let {
            send(current, PhoneControlUpdate.Refused(it))
            log("CONTROL refused reason=${it.wire}")
            return
        }
        if (Capabilities.negotiatedInput(phoneHostCapabilities(environment.sdkInt), controller) == null) {
            send(current, PhoneControlUpdate.Refused(PhoneControlReason.FAILED))
            return
        }
        when (mode(current.deviceId)) {
            PhoneControlGrantMode.OFF -> send(current, PhoneControlUpdate.Refused(PhoneControlReason.DISABLED))
            PhoneControlGrantMode.ALWAYS -> startSession(current)
            PhoneControlGrantMode.ASK -> {
                current.phase = Phase.ASKING
                current.sessionAllowed = false
                current.promptId = ++promptCounter
                val id = current.promptId
                environment.showPrompt(current.deviceId, current.macName, id)
                environment.service()?.showPrompt(current.macName) { allowed -> answer(id, allowed) }
                current.cancelPrompt = timers.schedule(PhoneControlLimits.PROMPT_LIFETIME_MILLIS) {
                    if (live === current && current.phase == Phase.ASKING && current.promptId == id) {
                        stopAsking(current)
                        send(current, PhoneControlUpdate.Refused(PhoneControlReason.DECLINED))
                    }
                }
                publish(current)
                send(current, PhoneControlUpdate.Waiting)
                log("CONTROL asking")
            }
        }
    }

    /** Why control cannot start now, from this phone's own state; null when it can. */
    private fun refusal(current: Live): PhoneControlReason? = when {
        !current.started -> PhoneControlReason.FAILED
        mode(current.deviceId) == PhoneControlGrantMode.OFF || !environment.viewGrant(current.deviceId) -> PhoneControlReason.DISABLED
        environment.service() == null -> PhoneControlReason.PERMISSION
        !environment.unlocked() -> PhoneControlReason.LOCKED
        else -> null
    }

    private fun startSession(current: Live) {
        val service = environment.service() ?: run {
            send(current, PhoneControlUpdate.Refused(PhoneControlReason.PERMISSION))
            return
        }
        val authority = authority(current, null, fresh = true) ?: run {
            send(current, PhoneControlUpdate.Refused(PhoneControlReason.FAILED))
            return
        }
        val result = host.begin(authority, current.geometry, clock())
        val info = result.getOrElse {
            val reason = refusalFor(ScreenControlHost.reasonOf(it))
            send(current, PhoneControlUpdate.Refused(reason))
            log("CONTROL begin refused reason=${reason.wire}")
            current.phase = Phase.OFF
            publish(current)
            return
        }
        val input = Capabilities.negotiatedInput(authority.host, authority.controller) ?: InputCapabilities()
        current.info = info
        current.phase = Phase.ACTIVE
        controllingNow = true
        executorFor(service)
        service.showIndicator(current.macName) { stopLocally() }
        environment.controlling(current.macName)
        publish(current)
        send(current, PhoneControlUpdate.Active(info.session, input))
        environment.record("phone_control_started", current.deviceId, if (current.sessionAllowed) "allowed" else "unattended")
        log("CONTROL active session=${info.session} touch=${input.touch} text=${input.text}")
        scheduleTick(current)
    }

    private fun scheduleTick(current: Live) {
        current.cancelTick()
        current.cancelTick = timers.schedule(1_000) {
            if (live !== current || current.phase != Phase.ACTIVE) return@schedule
            val transition = host.tick(clock())
            val status = transition.status
            if (status is ControlStatus.Stopped) controlStopped(current, transition, reasonFor(status.reason, current)) else scheduleTick(current)
        }
    }

    /** Control ended (the stream goes on): fingers lift first, then screen.control ended with the reason. */
    private fun controlStopped(current: Live, transition: ControlTransition, reason: PhoneControlReason) {
        release(transition.release, force = true)
        val wasActive = current.phase == Phase.ACTIVE
        current.phase = Phase.OFF
        current.info = null
        current.sessionAllowed = false
        current.cancelTick()
        controllingNow = false
        if (wasActive) {
            gesturesService?.hideIndicator()
            environment.controlling(null)
            send(current, PhoneControlUpdate.Ended(reason))
            environment.record("phone_control_ended", current.deviceId, reason.wire)
            log("CONTROL ended reason=${reason.wire} accepted=${current.accepted} rejected=${current.rejected}")
        }
        publish(current)
    }

    /** The stream is over: control ends without telling the Mac (the stream's own stop says it). */
    private fun end(current: Live, reason: ControlStopReason, tell: Boolean) {
        if (current.phase == Phase.ASKING) stopAsking(current)
        if (current.phase == Phase.ACTIVE) {
            val transition = host.stop(reason)
            release(transition.release, force = true)
            current.phase = Phase.OFF
            current.info = null
            current.cancelTick()
            controllingNow = false
            gesturesService?.hideIndicator()
            environment.controlling(null)
            if (tell) send(current, PhoneControlUpdate.Ended(PhoneControlReason.FAILED))
            environment.record("phone_control_ended", current.deviceId, "stream_ended")
            log("CONTROL ended with the stream")
        }
        mutableState.value = PhoneControlViewState()
    }

    private fun stopAsking(current: Live) {
        current.cancelPrompt()
        current.cancelPrompt = {}
        environment.dismissPrompt()
        environment.service()?.hidePrompt()
        if (current.phase == Phase.ASKING) current.phase = Phase.OFF
        publish(current)
    }

    private fun publish(current: Live) {
        mutableState.value = when (current.phase) {
            Phase.OFF -> PhoneControlViewState()
            Phase.ASKING -> PhoneControlViewState(PhoneControlViewState.Phase.ASKING, current.deviceId, current.macName)
            Phase.ACTIVE -> PhoneControlViewState(PhoneControlViewState.Phase.ACTIVE, current.deviceId, current.macName)
        }
    }

    private fun allowedNow(current: Live): Boolean =
        environment.built && environment.serviceEnabled() && mode(current.deviceId) != PhoneControlGrantMode.OFF && environment.viewGrant(current.deviceId)

    /** screen.control available when whether control may be asked for changed. */
    private fun syncAvailable(current: Live) {
        if (!current.started) return
        val allowed = allowedNow(current) && environment.service() != null
        if (current.allowedSent == allowed) return
        current.allowedSent = allowed
        send(current, PhoneControlUpdate.Available(allowed))
    }

    private fun send(current: Live, update: PhoneControlUpdate) {
        if (live !== current) return
        current.link.send(ScreenKinds.CONTROL) { phoneControlPayload(current.link.streamId, it, update) }
    }

    // MARK: Input

    private fun executorFor(service: ControlService): GestureExecutor {
        gestures?.takeIf { gesturesService === service }?.let { return it }
        gestures?.reset()
        // Android calls back on its own thread; the executor only ever runs on this hub's.
        val posting = object : GestureSink by service {
            override fun dispatch(gesture: PlannedGesture, done: (Boolean) -> Unit): Boolean =
                service.dispatch(gesture) { completed -> executor.execute { done(completed) } }
        }
        val created = GestureExecutor(posting, timers, clock, GestureExecutor.Config(touchSlop = touchSlop), ::log)
        gestures = created
        gesturesService = service
        return created
    }

    /** Releases first: held fingers lift where they are, held keys go up. [force]: lift every finger, scroll included. */
    private fun release(release: HeldInput, force: Boolean) {
        val gestures = gestures ?: return
        if (!force && release.isEmpty) return
        gestures.release()
        release.heldKeys.filter { it != ControlKey.SHIFT }.forEach { gestures.submit(ControlItem.Key(it, down = false, shift = false)) }
    }

    /** False when the input could not be queued (the caller ends control rather than drop a transition). */
    private fun inject(current: Live, input: ControlInput): Boolean {
        val service = environment.service() ?: return true
        val gestures = executorFor(service)
        fun point(x: Double, y: Double) = phonePoint(current.geometry, current.displayWidth, current.displayHeight, x, y)
        val item: ControlItem = when (input) {
            is ControlInput.Touch -> ControlItem.Finger(input.contact, input.phase, point(input.x, input.y) ?: return true)
            is ControlInput.Button -> {
                if (input.button != ControlButton.PRIMARY) return true
                ControlItem.Finger(GestureExecutor.BUTTON_FINGER, if (input.down) TouchPhase.DOWN else TouchPhase.UP, point(input.x, input.y) ?: return true)
            }
            is ControlInput.Pointer -> {
                if (ControlButton.PRIMARY !in host.held.heldButtons) return true
                ControlItem.Finger(GestureExecutor.BUTTON_FINGER, TouchPhase.MOVE, point(input.x, input.y) ?: return true)
            }
            is ControlInput.Scroll -> {
                val anchor = point(input.x, input.y) ?: return true
                val delta = scrollDelta(current.geometry, current.displayWidth, current.displayHeight, input.dx, input.dy)
                ControlItem.Scroll(anchor, delta.x, delta.y, current.displayWidth, current.displayHeight)
            }
            is ControlInput.Navigate -> ControlItem.Navigate(input.action)
            is ControlInput.Text -> ControlItem.Text(input.text)
            is ControlInput.Key -> {
                // Shift is a modifier for the keys after it, not an event of its own.
                if (input.key == ControlKey.SHIFT) return true
                ControlItem.Key(input.key, input.down, ControlKey.SHIFT in host.held.heldKeys)
            }
            ControlInput.GeometryAck, ControlInput.Heartbeat, ControlInput.Stop -> return true
        }
        return gestures.submit(item)
    }

    // MARK: Authority

    /**
     * Fresh local authority. Its generation advances whenever anything in it changes; [fresh] forces a new one (a new
     * control session). For keys and text it also checks that typing cannot land outside the shared display.
     */
    private fun authority(current: Live, input: ControlInput?, fresh: Boolean): ControlAuthority? {
        val identity = environment.identityKey(current.deviceId) ?: return null
        val service = environment.service()
        var ready = service != null
        current.ineligible = if (ready) null else PhoneControlReason.PERMISSION
        val keyboard = input is ControlInput.Key || input is ControlInput.Text
        val typingSupported = environment.sdkInt >= PhoneControlLimits.TYPING_SDK
        if (ready && keyboard && typingSupported) {
            when {
                input is ControlInput.Key && input.key in BLOCKED_KEYS -> {
                    ready = false
                    current.ineligible = PhoneControlReason.INVALID
                }
                environment.otherDisplayActive() -> {
                    ready = false
                    current.ineligible = PhoneControlReason.FOCUS
                }
                service?.canType != true -> {
                    ready = false
                    current.ineligible = PhoneControlReason.PERMISSION
                }
            }
        }
        val mode = mode(current.deviceId)
        val controlGrant = mode == PhoneControlGrantMode.ALWAYS || (mode == PhoneControlGrantMode.ASK && current.sessionAllowed)
        var body = ControlAuthority(
            generation = 0,
            binding = ControlBinding(PeerIdentity(deviceDigest(current.deviceId), sha256(identity)), current.transport, current.link.connection),
            stream = current.stream,
            trustedDevice = environment.trusted(current.deviceId) && !environment.isAgent(current.deviceId),
            viewGrant = environment.viewGrant(current.deviceId),
            controlGrant = controlGrant,
            captureReady = current.started,
            inputReady = ready,
            unlocked = environment.unlocked(),
            streamActive = current.started,
            host = phoneHostCapabilities(environment.sdkInt),
            controller = current.controller ?: return null,
        )
        if (fresh || body != lastAuthority) {
            authorityGeneration += 1
            lastAuthority = body
        }
        body = body.copy(generation = authorityGeneration)
        return body
    }

    private fun reasonFor(reason: ControlStopReason, current: Live): PhoneControlReason = when (reason) {
        ControlStopReason.USER -> PhoneControlReason.USER
        ControlStopReason.REVOKED -> PhoneControlReason.DISABLED
        ControlStopReason.PERMISSION_LOST -> current.ineligible ?: PhoneControlReason.PERMISSION
        ControlStopReason.LOCKED -> PhoneControlReason.LOCKED
        ControlStopReason.DISCONNECTED -> PhoneControlReason.FAILED
        ControlStopReason.TIMEOUT -> PhoneControlReason.TIMEOUT
        ControlStopReason.SEQUENCE_GAP, ControlStopReason.INVALID_INPUT, ControlStopReason.GEOMETRY_INVALID,
        ControlStopReason.CLOCK, ControlStopReason.EXHAUSTED -> PhoneControlReason.INVALID
        ControlStopReason.RATE_LIMITED -> PhoneControlReason.RATE
        ControlStopReason.SOURCE_CHANGED -> PhoneControlReason.SOURCE_CHANGED
        ControlStopReason.AUTHORITY_CHANGED -> refusal(current) ?: current.ineligible ?: PhoneControlReason.FAILED
    }

    private fun refusalFor(reason: dev.bridgey.android.display.ControlRejection): PhoneControlReason = when (reason) {
        dev.bridgey.android.display.ControlRejection.GRANT, dev.bridgey.android.display.ControlRejection.IDENTITY -> PhoneControlReason.DISABLED
        dev.bridgey.android.display.ControlRejection.PERMISSION -> PhoneControlReason.PERMISSION
        dev.bridgey.android.display.ControlRejection.LOCKED -> PhoneControlReason.LOCKED
        else -> PhoneControlReason.FAILED
    }

    companion object {
        /** Never typed on the phone: the Mac host refuses them too, and they would make shortcuts out of text. */
        val BLOCKED_KEYS = setOf(ControlKey.CONTROL, ControlKey.ALT, ControlKey.META)

        /** The pinned device as 16 bytes: the first half of SHA-256 of its ID, as the Mac does. */
        fun deviceDigest(deviceId: String): ByteArray = sha256(deviceId).copyOf(16)

        private fun sha256(text: String): ByteArray = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
    }
}
