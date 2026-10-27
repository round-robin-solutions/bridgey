package dev.bridgey.android.focus

import android.app.NotificationManager
import android.content.Context
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONObject

/** Draft, edition only (docs/protocol.md, "Focus and Do Not Disturb sync"): the peer understands focus.state. */
const val FOCUS_SYNC_FEATURE_KEY = "focus_sync_draft1"

/** A follower does not report the change it just made for this long, so two followers cannot loop. */
const val FOCUS_ECHO_WINDOW_MILLIS = 10_000L

/** focus.state plaintext limit. */
const val FOCUS_STATE_MAX_BYTES = 256

/** The phone's quiet mode, behind an interface so tests never touch the real Do Not Disturb. */
interface QuietMode {
    /** Do Not Disturb is on in any form (any interruption filter but "all"). */
    fun isActive(): Boolean

    /** Bridgey may change Do Not Disturb (notification policy access granted). */
    fun canChange(): Boolean

    /** Turns Do Not Disturb on (priority only) or back off. False if Android refused. */
    fun set(active: Boolean): Boolean
}

/** Do Not Disturb on for any interruption filter other than "all" (and "unknown", when Android cannot say). */
fun interruptionFilterIsQuiet(filter: Int): Boolean =
    filter != NotificationManager.INTERRUPTION_FILTER_ALL && filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN

/**
 * Android's Do Not Disturb. Setting it needs notification policy access. Since Android 15 an app
 * targeting API 35 or later that calls setInterruptionFilter gets its own implicit automatic rule
 * (named after the app, in Modes), so turning it off again only ends Bridgey's rule, never one the person
 * started; on older versions Bridgey only turns off what it turned on itself (see [FocusSync]).
 */
class AndroidQuietMode(context: Context) : QuietMode {
    private val manager = context.getSystemService(NotificationManager::class.java)

    override fun isActive(): Boolean = interruptionFilterIsQuiet(manager.currentInterruptionFilter)

    override fun canChange(): Boolean = manager.isNotificationPolicyAccessGranted

    override fun set(active: Boolean): Boolean = runCatching {
        manager.setInterruptionFilter(
            if (active) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL,
        )
    }.isSuccess
}

/** What happened to a received focus.state. */
enum class FocusApply { IGNORED, NO_CHANGE, TURNED_ON, TURNED_OFF, NEEDS_ACCESS, FAILED }

/** focus.state plaintext: `{ "version": 1, "active": bool }`, or null when malformed. */
fun parseFocusState(payload: JSONObject): Boolean? {
    if (jsonInteger(payload.opt("version")) != 1L) return null
    return payload.opt("active") as? Boolean
}

/** A focus.state plaintext as it arrives: at most 256 bytes of strict JSON. Null when malformed. */
fun decodeFocusState(plaintext: ByteArray): Boolean? =
    plaintext.takeIf { it.size <= FOCUS_STATE_MAX_BYTES }?.let(::strictJsonObject)?.let(::parseFocusState)

fun focusStatePayload(active: Boolean): JSONObject = JSONObject().put("version", 1).put("active", active)

/**
 * Focus and Do Not Disturb sync, the phone's side. Each direction is its own opt-in: [shareOn]
 * sends this phone's Do Not Disturb to every Mac that understands it ([peers]); [followOn] makes
 * Do Not Disturb follow the Macs' Focus. Bridgey only ever undoes the Do Not Disturb it turned on
 * itself: if the person had it on already, a Mac's Focus ending leaves it on.
 */
class FocusSync(
    private val quiet: QuietMode,
    private val clock: () -> Long,
    private val shareOn: () -> Boolean,
    private val followOn: () -> Boolean,
    /** Connected Macs whose latest features.update shows focus_sync_draft1. */
    private val peers: () -> Collection<String>,
    private val send: (deviceId: String, active: Boolean) -> Boolean,
) {
    /** The last state sent to each Mac in its current session. */
    private val lastSent = mutableMapOf<String, Boolean>()

    /** Each followed Mac's latest Focus state. */
    private val remoteActive = mutableMapOf<String, Boolean>()

    /** Bridgey turned Do Not Disturb on and has not handed it back. */
    var ownsQuiet = false
        private set

    /** The last change Bridgey made and when, for echo suppression. */
    private var applied: Pair<Boolean, Long>? = null

    /** focus_sync_draft1 for features.update: true while either direction is on. */
    fun advertised(): Boolean = shareOn() || followOn()

    /** A Mac's features.update showed the key on both sides: it hears this phone's state once. */
    @Synchronized fun peerReady(deviceId: String) {
        if (!shareOn()) return
        val active = quiet.isActive()
        if (send(deviceId, active)) lastSent[deviceId] = active
    }

    /** Android reported an interruption filter change. */
    @Synchronized fun localChanged() {
        val active = quiet.isActive()
        val now = clock()
        val echo = applied?.let { (state, at) -> state == active && now - at < FOCUS_ECHO_WINDOW_MILLIS } == true
        // The person turned off what Bridgey had turned on: it is theirs now, nothing to undo later.
        if (ownsQuiet && !active && !echo) ownsQuiet = false
        if (echo || !shareOn()) return
        peers().forEach { id ->
            if (lastSent[id] != active && send(id, active)) lastSent[id] = active
        }
    }

    /** The Share switch changed: when it turns on, every Mac hears the current state. */
    @Synchronized fun shareChanged() {
        if (!shareOn()) { lastSent.clear(); return }
        val active = quiet.isActive()
        peers().forEach { id -> if (send(id, active)) lastSent[id] = active }
    }

    /** The Follow switch changed: turning it off hands back the Do Not Disturb Bridgey turned on. */
    @Synchronized fun followChanged(): FocusApply {
        if (followOn()) return FocusApply.NO_CHANGE
        remoteActive.clear()
        return handBack()
    }

    /** A Mac's focus.state. */
    @Synchronized fun remote(deviceId: String, active: Boolean): FocusApply {
        if (!followOn()) return FocusApply.IGNORED
        remoteActive[deviceId] = active
        val wanted = remoteActive.values.any { it }
        return if (wanted) turnOn() else handBack()
    }

    /** The Mac was forgotten: its Focus no longer counts. */
    @Synchronized fun forget(deviceId: String): FocusApply {
        lastSent.remove(deviceId)
        if (remoteActive.remove(deviceId) == true && remoteActive.values.none { it }) return handBack()
        return FocusApply.NO_CHANGE
    }

    /** The session ended: the next one sends the state again. A followed Focus stays until the Mac says otherwise. */
    @Synchronized fun sessionEnded(deviceId: String) {
        lastSent.remove(deviceId)
    }

    private fun turnOn(): FocusApply {
        if (ownsQuiet) return FocusApply.NO_CHANGE
        // Already quiet by the person's own choice: leave it, and never turn it off later.
        if (quiet.isActive()) return FocusApply.NO_CHANGE
        if (!quiet.canChange()) return FocusApply.NEEDS_ACCESS
        if (!quiet.set(true)) return FocusApply.FAILED
        ownsQuiet = true
        applied = true to clock()
        return FocusApply.TURNED_ON
    }

    private fun handBack(): FocusApply {
        if (!ownsQuiet) return FocusApply.NO_CHANGE
        ownsQuiet = false
        if (!quiet.isActive()) return FocusApply.NO_CHANGE
        if (!quiet.canChange()) return FocusApply.NEEDS_ACCESS
        if (!quiet.set(false)) return FocusApply.FAILED
        applied = false to clock()
        return FocusApply.TURNED_OFF
    }
}
