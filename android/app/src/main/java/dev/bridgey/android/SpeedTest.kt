package dev.bridgey.android

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.SystemClock
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/*
 * Speed test (draft files_fast_draft1; docs/transfer-speed.md, docs/protocol.md "Speed test"). Settings > Privacy >
 * Transfer speed: about 15 seconds over the real session with a chosen Mac: round trips first, then 7 seconds of test
 * bytes each way, paced and acknowledged exactly like file chunks. Shows megabytes a second each way, the round trip,
 * each side's Wi-Fi link where Android or macOS can read it, whether this phone held its Wi-Fi power-save lock, and a
 * verdict in plain words. The Mac has the same code in SpeedTest.swift.
 */

internal object SpeedKinds {
    const val START = "speed.start"
    const val READY = "speed.ready"
    const val TURN = "speed.turn"
    const val DONE = "speed.done"
    const val RESULT = "speed.result"
    const val CANCEL = "speed.cancel"
    const val PING = "speed.ping"
    const val PONG = "speed.pong"
    const val ACK = "speed.ack"
}

internal object SpeedLimits {
    const val MAXIMUM_PLAINTEXT = 1024
    const val SECONDS_PER_DIRECTION = 7
    const val PINGS = 10
    const val ANSWER_TIMEOUT_MILLIS = 5_000L
    const val STALL_TIMEOUT_MILLIS = 5_000L
    /** Throughput counts from here on, so TCP and the window have warmed up. */
    const val WARM_UP_MILLIS = 1_000L
}

/** One device's own view of its network for this test. No names, addresses or network names. */
data class SpeedLink(
    val platform: String,
    /** "wifi", "ethernet", "hotspot" (this phone is the Mac's access point) or "other". */
    val network: String,
    /** "2.4", "5" or "6" (GHz). */
    val band: String? = null,
    /** The Wi-Fi transmit rate in Mbit/s. */
    val linkMbps: Int? = null,
    /** 4 to 7 for Wi-Fi 4 to Wi-Fi 7. */
    val standard: Int? = null,
    val widthMhz: Int? = null,
    /** Phone only: the Wi-Fi power-save lock was held for the test, and the screen was on. */
    val lockHeld: Boolean? = null,
    val screenOn: Boolean? = null,
) {
    fun toJson(): JSONObject = JSONObject().put("platform", platform).put("network", network).apply {
        band?.let { put("band", it) }
        linkMbps?.let { put("linkMbps", it) }
        standard?.let { put("standard", it) }
        widthMhz?.let { put("widthMhz", it) }
        lockHeld?.let { put("lockHeld", it) }
        screenOn?.let { put("screenOn", it) }
    }

    companion object {
        fun decode(value: Any?): SpeedLink? {
            val json = value as? JSONObject ?: return null
            val platform = json.opt("platform") as? String ?: return null
            if (platform.toByteArray().size !in 1..16) return null
            val network = (json.opt("network") as? String)?.takeIf { it in setOf("wifi", "ethernet", "hotspot", "other") } ?: return null
            fun int(key: String, range: IntRange): Int? = jsonInteger(json.opt(key))?.takeIf { it in range.first.toLong()..range.last.toLong() }?.toInt()
            return SpeedLink(
                platform, network,
                band = (json.opt("band") as? String)?.takeIf { it in setOf("2.4", "5", "6") },
                linkMbps = int("linkMbps", 1..100_000),
                standard = int("standard", 4..7),
                widthMhz = int("widthMhz", 20..320),
                lockHeld = json.opt("lockHeld") as? Boolean,
                screenOn = json.opt("screenOn") as? Boolean,
            )
        }
    }
}

/** The JSON speed.* payloads, decoded strictly: version 1, a UUID test ID, numbers in range; anything else is null. */
internal sealed interface SpeedPayload {
    val testId: String

    data class Start(override val testId: String, val seconds: Int, val link: SpeedLink) : SpeedPayload
    data class Ready(override val testId: String, val status: String, val link: SpeedLink?) : SpeedPayload
    data class Turn(override val testId: String, val bytesPerSecond: Long) : SpeedPayload
    data class Done(override val testId: String, val bytesPerSecond: Long) : SpeedPayload
    data class Result(
        override val testId: String,
        val forward: Long?,
        val back: Long?,
        val roundTripMs: Double?,
        val loadedRoundTripMs: Double?,
    ) : SpeedPayload

    fun encode(): ByteArray {
        val json = JSONObject().put("version", 1).put("testId", testId)
        when (this) {
            is Start -> json.put("seconds", seconds).put("link", link.toJson())
            is Ready -> json.put("status", status).apply { link?.let { put("link", it.toJson()) } }
            is Turn -> json.put("bytesPerSecond", bytesPerSecond)
            is Done -> json.put("bytesPerSecond", bytesPerSecond)
            is Result -> {
                forward?.let { json.put("forwardBytesPerSecond", it) }
                back?.let { json.put("backBytesPerSecond", it) }
                roundTripMs?.let { json.put("roundTripMs", (it * 10).roundToLong() / 10.0) }
                loadedRoundTripMs?.let { json.put("loadedRoundTripMs", (it * 10).roundToLong() / 10.0) }
            }
        }
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    companion object {
        fun decode(kind: String, plaintext: ByteArray): SpeedPayload? {
            if (plaintext.size > SpeedLimits.MAXIMUM_PLAINTEXT) return null
            val json = strictJsonObject(plaintext) ?: return null
            if (jsonInteger(json.opt("version")) != 1L) return null
            val testId = (json.opt("testId") as? String)?.lowercase() ?: return null
            if (runCatching { UUID.fromString(testId) }.isFailure || testId.length != 36) return null
            fun rate(key: String): Long? = jsonInteger(json.opt(key))?.takeIf { it in 0..1_000_000_000_000L }
            fun millis(key: String): Double? = (json.opt(key) as? Number)?.toDouble()?.takeIf { json.opt(key) !is Boolean && it.isFinite() && it in 0.0..60_000.0 }
            return when (kind) {
                SpeedKinds.START -> {
                    val seconds = jsonInteger(json.opt("seconds"))?.takeIf { it in 2..15 } ?: return null
                    Start(testId, seconds.toInt(), SpeedLink.decode(json.opt("link")) ?: return null)
                }
                SpeedKinds.READY -> {
                    val status = (json.opt("status") as? String)?.takeIf { it in setOf("ready", "busy", "disabled") } ?: return null
                    Ready(testId, status, SpeedLink.decode(json.opt("link")))
                }
                SpeedKinds.TURN -> Turn(testId, rate("bytesPerSecond") ?: return null)
                SpeedKinds.DONE -> Done(testId, rate("bytesPerSecond") ?: return null)
                SpeedKinds.RESULT -> Result(testId, rate("forwardBytesPerSecond"), rate("backBytesPerSecond"), millis("roundTripMs"), millis("loadedRoundTripMs"))
                else -> null
            }
        }
    }
}

/** What the numbers mean, in plain words. Both apps use the same rules (SpeedTest.swift). */
data class SpeedVerdict(
    val route: Route,
    /** Where the estimate comes from; [Basis.NONE] (no estimate) when the route is not Wi-Fi or Ethernet. */
    val basis: Basis,
    /** The estimate for this route, in MB/s (0 without one). */
    val expectedLow: Int,
    val expectedHigh: Int,
    /** The better direction reached at least 70% of the low end (always true without an estimate). */
    val asExpected: Boolean,
    val advice: List<Advice>,
) {
    enum class Route { SAME_ROUTER, MAC_WIRED, HOTSPOT, UNKNOWN }
    enum class Basis { LINK_RATES, TYPICAL, NONE }
    enum class Advice { PHONE_24, MAC_24, SCREEN_OFF, WEAK_LINK, TRY_HOTSPOT }

    companion object {
        /**
         * Goodput over one Wi-Fi hop is about half to three quarters of the transmit rate: phones on Wi-Fi 6 (2x2,
         * 80 MHz, a 1,201 Mbit/s link) measured 900 Mbit/s down and 540 to 600 up (Aggarwal et al., INFOCOM 2021; see
         * docs/transfer-speed.md). Estimates, not measurements of this app.
         */
        private const val EFFICIENCY_LOW = 0.5
        private const val EFFICIENCY_HIGH = 0.75

        fun evaluate(mac: SpeedLink?, phone: SpeedLink, bestBytesPerSecond: Double): SpeedVerdict {
            val route = when {
                phone.network == "hotspot" -> Route.HOTSPOT
                mac?.network == "ethernet" && phone.network == "wifi" -> Route.MAC_WIRED
                mac?.network == "wifi" && phone.network == "wifi" -> Route.SAME_ROUTER
                else -> Route.UNKNOWN
            }
            // Not Wi-Fi or Ethernet on both sides (a cable, a VPN, an emulator): nothing to compare with.
            if (route == Route.UNKNOWN) return SpeedVerdict(route, Basis.NONE, 0, 0, true, emptyList())
            fun range(mbps: Double): Pair<Int, Int> =
                Math.round(mbps * EFFICIENCY_LOW / 8).toInt() to Math.round(mbps * EFFICIENCY_HIGH / 8).toInt()
            // Typical values when a link rate is not readable: Wi-Fi 6, 2x2, 80 MHz (the same source).
            val rate: Double? = when (route) {
                Route.SAME_ROUTER -> {
                    val a = mac?.linkMbps
                    val b = phone.linkMbps
                    // Through one access point every byte crosses the air twice: the two hops share the airtime.
                    if (a != null && b != null && a > 0 && b > 0) 1 / (1 / a.toDouble() + 1 / b.toDouble()) else null
                }
                Route.MAC_WIRED -> phone.linkMbps?.toDouble()
                else -> mac?.linkMbps?.toDouble()
            }
            val (low, high) = rate?.let(::range) ?: when (route) {
                Route.SAME_ROUTER -> 30 to 45
                Route.MAC_WIRED -> 50 to 75
                else -> 50 to 90
            }
            val asExpected = bestBytesPerSecond / 1_000_000 >= low * 0.7
            val advice = buildList {
                if (!asExpected) {
                    if (phone.band == "2.4") add(Advice.PHONE_24)
                    if (mac?.network == "wifi" && mac.band == "2.4") add(Advice.MAC_24)
                    if (phone.screenOn == false) add(Advice.SCREEN_OFF)
                    if (isEmpty()) add(Advice.WEAK_LINK)
                }
                if (route == Route.SAME_ROUTER) add(Advice.TRY_HOTSPOT)
            }
            return SpeedVerdict(route, if (rate != null) Basis.LINK_RATES else Basis.TYPICAL, low, high, asExpected, advice)
        }
    }
}

/** A finished test, as both apps show it. */
data class SpeedReport(
    val macToPhone: Double?,
    val phoneToMac: Double?,
    val roundTripMs: Double?,
    val loadedRoundTripMs: Double?,
    val mac: SpeedLink?,
    val phone: SpeedLink,
) {
    val verdict: SpeedVerdict = SpeedVerdict.evaluate(mac, phone, maxOf(macToPhone ?: 0.0, phoneToMac ?: 0.0))

    /** The text for Copy results: numbers and link facts only, never names, addresses or identifiers. */
    fun plainText(version: String): String {
        fun rate(value: Double?) = value?.let { "%.1f MB/s".format(java.util.Locale.US, it / 1_000_000) } ?: "n/a"
        fun link(value: SpeedLink?): String {
            value ?: return "unknown"
            return buildList {
                add(value.network)
                value.band?.let { add("$it GHz") }
                value.standard?.let { add("Wi-Fi $it") }
                value.widthMhz?.let { add("$it MHz") }
                value.linkMbps?.let { add("$it Mbit/s") }
                value.lockHeld?.let { add(if (it) "power-save lock held" else "power-save lock not held") }
                value.screenOn?.let { add(if (it) "screen on" else "screen off") }
            }.joinToString(", ")
        }
        fun ms(value: Double?) = value?.let { "%.0f ms".format(java.util.Locale.US, it) } ?: "n/a"
        return listOf(
            "Bridgey speed test (Android $version, API ${Build.VERSION.SDK_INT})",
            "Mac to phone: ${rate(macToPhone)}",
            "Phone to Mac: ${rate(phoneToMac)}",
            "Round trip: ${ms(roundTripMs)} idle, ${ms(loadedRoundTripMs)} during the test",
            "Mac link: ${link(mac)}",
            "Phone link: ${link(phone)}",
            "Route: ${verdict.route.name.lowercase()}; " + when (verdict.basis) {
                SpeedVerdict.Basis.NONE -> "no estimate"
                SpeedVerdict.Basis.LINK_RATES -> "estimate ${verdict.expectedLow} to ${verdict.expectedHigh} MB/s from the link rates; "
                SpeedVerdict.Basis.TYPICAL -> "estimate ${verdict.expectedLow} to ${verdict.expectedHigh} MB/s, typical for Wi-Fi 6; "
            } + if (verdict.basis == SpeedVerdict.Basis.NONE) "" else if (verdict.asExpected) "reached" else "below the estimate",
        ).joinToString("\n")
    }
}

/** This phone's side of a session's route, without location access: Wi-Fi rate, band and standard, or the hotspot. */
internal object PhoneSpeedLink {
    @Suppress("DEPRECATION")
    fun current(context: Context, localAddress: InetAddress?, lockHeld: Boolean, screenOn: Boolean): SpeedLink {
        val name = runCatching { localAddress?.let(NetworkInterface::getByInetAddress)?.name }.getOrNull().orEmpty()
        val network = when {
            name.startsWith("wlan0") -> "wifi"
            name.startsWith("ap") || name.startsWith("swlan") || name.startsWith("softap") || name.startsWith("wlan") -> "hotspot"
            name.startsWith("eth") -> "ethernet"
            else -> "other"
        }
        var link = SpeedLink(platform = "android", network = network, lockHeld = lockHeld, screenOn = screenOn)
        if (network == "wifi") {
            val info = runCatching { context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo }.getOrNull()
            if (info != null) {
                val frequency = info.frequency
                link = link.copy(
                    linkMbps = info.linkSpeed.takeIf { it > 0 },
                    band = when {
                        frequency in 2400..2500 -> "2.4"
                        frequency in 4900..5900 -> "5"
                        frequency in 5925..7125 -> "6"
                        else -> null
                    },
                    standard = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        when (info.wifiStandard) {
                            4 -> 4
                            5 -> 5
                            6 -> 6
                            8 -> 7
                            else -> null
                        }
                    } else null,
                )
            }
        }
        return link
    }
}

/** How the speed test reaches one Mac. Thread-safe; [sendData] is called from a worker thread. */
internal interface SpeedTestLink {
    fun sendEncrypted(kind: String, payload: ByteArray): Boolean
    fun sendOuter(kind: String, testId: String, sequence: Long?): Boolean
    fun sendData(testId: String, sequence: Long, plaintext: ByteArray): Boolean
    fun localLink(lockHeld: Boolean): SpeedLink
}

/** Where the test stands, for the screen. */
data class SpeedTestState(
    val phase: Phase = Phase.IDLE,
    val deviceId: String? = null,
    val deviceName: String = "",
    /** 0 to 1 over the whole test. */
    val progress: Float = 0f,
    val liveBytesPerSecond: Double = 0.0,
    val report: SpeedReport? = null,
    val failure: String? = null,
) {
    enum class Phase { IDLE, CONNECTING, ROUND_TRIPS, SENDING, RECEIVING, FINISHED, FAILED }

    val running: Boolean get() = phase in setOf(Phase.CONNECTING, Phase.ROUND_TRIPS, Phase.SENDING, Phase.RECEIVING)
}

/** Sends test bytes for a number of seconds in a paced window and measures what the other side acknowledged. */
internal class SpeedSender {
    val pacer = TransferPacer(fast = true)
    private val lock = Any()
    private var acked = -1L
    private var startAt = 0L
    private var warm: LongArray? = null
    private var last: LongArray? = null
    private var lastAckAt = SystemClock.elapsedRealtime()
    private val cancelled = AtomicBoolean(false)

    fun acknowledged(testId: String, sequence: Long) {
        val now = SystemClock.elapsedRealtime()
        synchronized(lock) {
            if (sequence <= acked) return
            acked = sequence
            val bytes = (sequence + 1) * pacer.chunkSize
            last = longArrayOf(now, bytes)
            lastAckAt = now
            if (warm == null && now - startAt >= SpeedLimits.WARM_UP_MILLIS) warm = longArrayOf(now, bytes)
        }
        pacer.acknowledged(testId, sequence)
    }

    fun cancel() {
        cancelled.set(true)
        pacer.cancel()
    }

    /** Bytes a second acknowledged after the warm-up, so far. */
    val rate: Double
        get() = synchronized(lock) {
            val w = warm ?: return 0.0
            val l = last ?: return 0.0
            if (l[0] <= w[0]) 0.0 else (l[1] - w[1]) * 1000.0 / (l[0] - w[0])
        }

    /** Blocking; returns true when every byte sent was acknowledged in time. */
    fun run(testId: String, seconds: Int, link: SpeedTestLink, progress: (Float, Double) -> Unit): Boolean {
        val chunk = ByteArray(pacer.chunkSize)
        synchronized(lock) {
            startAt = SystemClock.elapsedRealtime()
            lastAckAt = startAt
        }
        var sequence = 0L
        var lastReport = startAt
        while (!cancelled.get()) {
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - startAt
            if (elapsed >= seconds * 1000L) break
            if (now - synchronized(lock) { lastAckAt } > SpeedLimits.STALL_TIMEOUT_MILLIS) return false
            if (!pacer.waitForRoom(chunk.size, SpeedLimits.STALL_TIMEOUT_MILLIS) { cancelled.get() }) return false
            pacer.didSend(testId, sequence, chunk.size)
            if (!link.sendData(testId, sequence, chunk)) return false
            sequence++
            if (now - lastReport >= 250) {
                lastReport = now
                progress((elapsed / (seconds * 1000f)).coerceAtMost(1f), rate)
            }
        }
        return !cancelled.get() && pacer.waitForAll(SpeedLimits.STALL_TIMEOUT_MILLIS) { cancelled.get() }
    }
}

/** The phone's speed test: one at a time, started here or by a Mac. */
internal class SpeedTest(
    private val scope: CoroutineScope,
    private val power: TransferPowerLock,
    /** Nil when the device is not connected or does not advertise files_fast_draft1. */
    private val linkFor: (String) -> SpeedTestLink?,
    private val nameOf: (String) -> String,
) {
    private val mutableState = MutableStateFlow(SpeedTestState())
    val state: StateFlow<SpeedTestState> = mutableState.asStateFlow()

    private inner class Run(
        val testId: String,
        val deviceId: String,
        val initiator: Boolean,
        val seconds: Int,
        val link: SpeedTestLink,
        var local: SpeedLink,
    ) {
        var remote: SpeedLink? = null
        val pingsSent = HashMap<Long, Long>()
        val roundTrips = ArrayList<Double>()
        var sender: SpeedSender? = null
        var forward: Double? = null
        var back: Double? = null
        var loadedRoundTrip: Double? = null
        var receivedSequence = -1L
        var lastData = SystemClock.elapsedRealtime()
        var timer: Job? = null
        var watchdog: Job? = null
    }

    private val lock = Any()
    private var run: Run? = null

    /**
     * Starts a test with [deviceId]. Called from the screen, so the first messages go out on [scope], never on the
     * calling (main) thread: Android refuses socket writes there (NetworkOnMainThreadException).
     */
    fun start(deviceId: String) {
        scope.launch { begin(deviceId) }
    }

    private fun begin(deviceId: String): Unit = synchronized(lock) {
        if (run != null) return
        val link = linkFor(deviceId) ?: return fail(null, "unavailable")
        power.acquire(HOLDER)
        val testId = UUID.randomUUID().toString()
        val current = Run(testId, deviceId, true, SpeedLimits.SECONDS_PER_DIRECTION, link, link.localLink(power.held))
        run = current
        mutableState.value = SpeedTestState(SpeedTestState.Phase.CONNECTING, deviceId, nameOf(deviceId))
        if (!link.sendEncrypted(SpeedKinds.START, SpeedPayload.Start(testId, current.seconds, current.local).encode())) return fail(current, "unavailable")
        arm(current, SpeedLimits.ANSWER_TIMEOUT_MILLIS) { fail(current, "noAnswer") }
        BridgeyLogging.i(LogCategory.FILES, "SPEED start test=${testId.take(8)}")
    }

    /** Stop, from the screen: like [start], the cancel goes out on [scope]. */
    fun cancel() {
        scope.launch { stop() }
    }

    private fun stop(): Unit = synchronized(lock) {
        val current = run ?: return
        current.link.sendOuter(SpeedKinds.CANCEL, current.testId, null)
        end(current, SpeedTestState.Phase.FAILED, "cancelled")
    }

    fun disconnected(deviceId: String): Unit = synchronized(lock) {
        val current = run?.takeIf { it.deviceId == deviceId } ?: return
        end(current, SpeedTestState.Phase.FAILED, "disconnected")
    }

    /** speed.* messages: [plaintext] for the encrypted ones; [outerId] and [sequence] for the outer-only ones. */
    fun receive(deviceId: String, kind: String, plaintext: ByteArray?, outerId: String?, sequence: Long?): Unit = synchronized(lock) {
        val current = run
        when (kind) {
            SpeedKinds.PING -> {
                if (outerId != null && sequence != null) linkFor(deviceId)?.sendOuter(SpeedKinds.PONG, outerId, sequence)
                return
            }
            SpeedKinds.PONG -> {
                if (current == null || current.deviceId != deviceId || outerId != current.testId || sequence == null) return
                val sent = current.pingsSent.remove(sequence) ?: return
                current.roundTrips += (SystemClock.elapsedRealtime() - sent).toDouble()
                if (current.pingsSent.isEmpty() && current.roundTrips.size >= SpeedLimits.PINGS) startSending(current)
                return
            }
            SpeedKinds.ACK -> {
                if (current == null || current.deviceId != deviceId || outerId != current.testId || sequence == null) return
                current.sender?.acknowledged(current.testId, sequence)
                return
            }
            SpeedKinds.CANCEL -> {
                if (current == null || current.deviceId != deviceId || outerId != current.testId) return
                end(current, SpeedTestState.Phase.FAILED, "cancelledByMac")
                return
            }
        }
        val payload = plaintext?.let { SpeedPayload.decode(kind, it) } ?: return
        when (payload) {
            is SpeedPayload.Start -> {
                val link = linkFor(deviceId)
                if (current != null || link == null) {
                    link?.sendEncrypted(SpeedKinds.READY, SpeedPayload.Ready(payload.testId, if (current != null) "busy" else "disabled", null).encode())
                    return
                }
                power.acquire(HOLDER)
                val started = Run(payload.testId, deviceId, false, payload.seconds, link, link.localLink(power.held))
                started.remote = payload.link
                run = started
                mutableState.value = SpeedTestState(SpeedTestState.Phase.RECEIVING, deviceId, nameOf(deviceId))
                if (!link.sendEncrypted(SpeedKinds.READY, SpeedPayload.Ready(payload.testId, "ready", started.local).encode())) {
                    return fail(started, "unavailable")
                }
                watchData(started)
            }
            is SpeedPayload.Ready -> {
                if (current == null || !current.initiator || current.testId != payload.testId ||
                    mutableState.value.phase != SpeedTestState.Phase.CONNECTING
                ) return
                if (payload.status != "ready") return fail(current, payload.status)
                current.remote = payload.link
                mutableState.value = mutableState.value.copy(phase = SpeedTestState.Phase.ROUND_TRIPS, progress = 0.02f)
                scope.launch {
                    for (number in 1..SpeedLimits.PINGS) {
                        synchronized(lock) {
                            if (run !== current) return@launch
                            current.pingsSent[number.toLong()] = SystemClock.elapsedRealtime()
                        }
                        current.link.sendOuter(SpeedKinds.PING, current.testId, number.toLong())
                        delay(30)
                    }
                }
                arm(current, SpeedLimits.ANSWER_TIMEOUT_MILLIS) {
                    // Some pongs went missing: go on with what came back.
                    if (mutableState.value.phase == SpeedTestState.Phase.ROUND_TRIPS) {
                        current.pingsSent.clear()
                        startSending(current)
                    }
                }
            }
            is SpeedPayload.Turn -> {
                if (current == null || current.initiator || current.testId != payload.testId) return
                current.forward = payload.bytesPerSecond.toDouble()
                startSending(current)
            }
            is SpeedPayload.Done -> {
                if (current == null || !current.initiator || current.testId != payload.testId) return
                current.back = payload.bytesPerSecond.toDouble()
                finishInitiator(current)
            }
            is SpeedPayload.Result -> {
                if (current == null || current.initiator || current.testId != payload.testId) return
                // The Mac started it: forward is Mac to phone.
                val report = SpeedReport(
                    payload.forward?.toDouble(), payload.back?.toDouble(), payload.roundTripMs, payload.loadedRoundTripMs,
                    current.remote, current.local,
                )
                end(current, SpeedTestState.Phase.FINISHED, null, report)
            }
        }
    }

    /** Test bytes from the Mac: acknowledged at once, then thrown away. */
    fun receiveData(deviceId: String, payload: FastFramePayload) {
        val current = synchronized(lock) { run?.takeIf { it.deviceId == deviceId && it.testId == payload.id } } ?: return
        synchronized(lock) {
            if (payload.sequence <= current.receivedSequence) return
            current.receivedSequence = payload.sequence
            current.lastData = SystemClock.elapsedRealtime()
        }
        current.link.sendOuter(SpeedKinds.ACK, current.testId, payload.sequence)
    }

    private fun startSending(current: Run) {
        if (run !== current || current.sender != null) return
        current.timer?.cancel()
        val sender = SpeedSender()
        current.sender = sender
        val base = if (current.initiator) 0.05f else 0.5f
        mutableState.value = mutableState.value.copy(phase = SpeedTestState.Phase.SENDING, progress = base)
        scope.launch {
            val ok = sender.run(current.testId, current.seconds, current.link) { fraction, rate ->
                synchronized(lock) {
                    if (run === current) mutableState.value = mutableState.value.copy(progress = base + fraction * 0.45f, liveBytesPerSecond = rate)
                }
            }
            synchronized(lock) {
                if (run !== current) return@launch
                if (!ok) return@launch fail(current, "stalled")
                sent(current, sender.rate, sender.pacer.smoothedRoundTripNanos?.let { it / 1_000_000.0 })
            }
        }
    }

    private fun sent(current: Run, rate: Double, loaded: Double?) {
        current.loadedRoundTrip = loaded
        if (current.initiator) {
            current.forward = rate
            current.sender = null
            if (!current.link.sendEncrypted(SpeedKinds.TURN, SpeedPayload.Turn(current.testId, rate.toLong()).encode())) return fail(current, "unavailable")
            current.lastData = SystemClock.elapsedRealtime()
            mutableState.value = mutableState.value.copy(phase = SpeedTestState.Phase.RECEIVING, progress = 0.5f)
            watchData(current)
        } else {
            current.back = rate
            if (!current.link.sendEncrypted(SpeedKinds.DONE, SpeedPayload.Done(current.testId, rate.toLong()).encode())) return fail(current, "unavailable")
            mutableState.value = mutableState.value.copy(phase = SpeedTestState.Phase.RECEIVING, progress = 0.95f)
            arm(current, SpeedLimits.ANSWER_TIMEOUT_MILLIS) {
                end(current, SpeedTestState.Phase.FINISHED, null,
                    SpeedReport(current.forward, current.back, null, current.loadedRoundTrip, current.remote, current.local))
            }
        }
    }

    private fun finishInitiator(current: Run) {
        val sorted = current.roundTrips.sorted()
        val median = sorted.getOrNull(sorted.size / 2)
        current.link.sendEncrypted(
            SpeedKinds.RESULT,
            SpeedPayload.Result(current.testId, current.forward?.toLong(), current.back?.toLong(), median, current.loadedRoundTrip).encode(),
        )
        // This phone started it: forward is phone to Mac.
        val report = SpeedReport(current.back, current.forward, median, current.loadedRoundTrip, current.remote, current.local)
        BridgeyLogging.i(LogCategory.FILES, "SPEED done phoneToMac=${((current.forward ?: 0.0) / 1000).toLong()}kB/s macToPhone=${((current.back ?: 0.0) / 1000).toLong()}kB/s")
        end(current, SpeedTestState.Phase.FINISHED, null, report)
    }

    /** While the Mac sends: fail when its bytes stop. */
    private fun watchData(current: Run) {
        current.watchdog?.cancel()
        current.watchdog = scope.launch {
            while (true) {
                delay(500)
                synchronized(lock) {
                    if (run !== current) return@launch
                    val state = mutableState.value
                    if (state.phase == SpeedTestState.Phase.RECEIVING && current.sender == null) {
                        if (SystemClock.elapsedRealtime() - current.lastData > SpeedLimits.STALL_TIMEOUT_MILLIS + current.seconds * 1000L) {
                            return@launch fail(current, "stalled")
                        }
                        if (current.initiator) mutableState.value = state.copy(progress = (state.progress + 0.5f / (2 * current.seconds)).coerceAtMost(0.98f))
                    }
                }
            }
        }
    }

    private fun arm(current: Run, millis: Long, action: () -> Unit) {
        current.timer?.cancel()
        current.timer = scope.launch {
            delay(millis)
            synchronized(lock) { if (run === current) action() }
        }
    }

    private fun fail(current: Run?, reason: String) {
        if (current != null && reason != "cancelledByMac") current.link.sendOuter(SpeedKinds.CANCEL, current.testId, null)
        BridgeyLogging.i(LogCategory.FILES, "SPEED failed reason=$reason")
        if (current == null) {
            mutableState.value = SpeedTestState(SpeedTestState.Phase.FAILED, failure = reason)
            return
        }
        end(current, SpeedTestState.Phase.FAILED, reason)
    }

    private fun end(current: Run, phase: SpeedTestState.Phase, failure: String?, report: SpeedReport? = null) {
        if (run !== current) return
        current.timer?.cancel()
        current.watchdog?.cancel()
        current.sender?.cancel()
        run = null
        power.release(HOLDER)
        mutableState.value = mutableState.value.copy(
            phase = phase, failure = failure, report = report,
            progress = if (phase == SpeedTestState.Phase.FINISHED) 1f else mutableState.value.progress,
        )
    }

    private companion object {
        const val HOLDER = "speed-test"
    }
}
