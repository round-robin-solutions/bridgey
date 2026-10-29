package dev.bridgey.android.updates

import org.json.JSONObject

/*
 * Update all devices automatically (Round Robin edition). With the setting on, a device that finds a
 * newer build on its own channel runs Update all by itself: connected devices first, this one last. It
 * waits while the person is busy on any device, lets only one device start when several find the same
 * build, and puts its own restart off with Later (three times, then only when the screen is off and
 * the phone charges). Everything here is pure (clock injected) so the rules are unit tested;
 * AutoUpdateController wires it to the updater, the session and the activity stream. The Mac has the
 * same rules in AutoUpdate.swift.
 */

/** How often a device checks its channel with the setting on: Beta and Nightly. */
const val AUTO_CHECK_FAST_MILLIS = 30L * 60 * 1000

/** Stable, with the setting on. */
const val AUTO_CHECK_STABLE_MILLIS = 6L * 60 * 60 * 1000

/** Without the setting: the daily check the updater always had. */
const val AUTO_CHECK_OFF_MILLIS = 24L * 60 * 60 * 1000

/** Waking up (screen on) and network changes check too, at most this often (counting every other check). */
const val AUTO_EVENT_CHECK_GAP_MILLIS = 10L * 60 * 1000

/** While someone is busy, look again this often. */
const val AUTO_RECHECK_MILLIS = 5L * 60 * 1000

/** This device's own restart in an automatic run waits this long, with Later. */
const val AUTO_COUNTDOWN_MILLIS = 60_000L

/** Later puts the automatic restart off this long. */
const val AUTO_LATER_MILLIS = 60L * 60 * 1000

/** After this many Laters for one build, it waits until the screen is off and the phone charges. */
const val AUTO_MAX_LATER = 3

/** A device that leaves the run to a lower device ID starts its own after this long. */
const val AUTO_YIELD_MILLIS = 15L * 60 * 1000

/** After accepting another device's start, this device does not start its own run for this long. */
const val AUTO_PEER_REQUEST_MILLIS = 10L * 60 * 1000

/**
 * After an automatic run for a build ends, another automatic run for that same build waits this long.
 * Without it a device that does not answer, or refuses for its rate, would be started again every few
 * seconds; a newer build starts afresh.
 */
const val AUTO_RETRY_MILLIS = 60L * 60 * 1000

object AutoUpdateRules {
    /** On by default for Beta and Nightly, off for Stable. */
    fun defaultOn(channel: WireChannel): Boolean = channel != WireChannel.STABLE

    /** The setting: the person's own choice when they made one, otherwise the channel's default. */
    fun enabled(stored: Boolean?, channel: WireChannel): Boolean = stored ?: defaultOn(channel)

    /** Every 30 minutes on Beta and Nightly and every 6 hours on Stable with the setting on; daily without it. */
    fun checkInterval(enabled: Boolean, channel: WireChannel): Long = when {
        !enabled -> AUTO_CHECK_OFF_MILLIS
        channel == WireChannel.STABLE -> AUTO_CHECK_STABLE_MILLIS
        else -> AUTO_CHECK_FAST_MILLIS
    }

    /** Waking up or a network change: check unless any check (scheduled or not) ran in the last 10 minutes. */
    fun eventCheckAllowed(lastCheckedAt: Long, lastEventCheckAt: Long, now: Long): Boolean {
        val last = maxOf(lastCheckedAt, lastEventCheckAt)
        return last <= 0 || now < last || now - last >= AUTO_EVENT_CHECK_GAP_MILLIS
    }
}

/** A connected device that supports Update all, as the automatic run sees it. */
data class AutoPeer(val deviceId: String, val name: String, val status: UpdateStatus)

/** What the decision depends on, read fresh each time. */
data class AutoFacts(
    val now: Long,
    /** Update all devices automatically is on here. */
    val enabled: Boolean,
    /** This device's own device ID: the lowest ID among devices with the setting on starts the run. */
    val localId: String,
    val localName: String,
    /** This device's own updates.status. */
    val local: UpdateStatus,
    /** What the person is doing on this device. */
    val localBusy: UpdateBusy?,
    val peers: List<AutoPeer>,
    /** An Update all run is going here. */
    val runActive: Boolean,
    /** This device is updating because another device asked. */
    val updatingForPeer: Boolean,
    /** The screen is off and the phone charges. */
    val idle: Boolean,
)

/** What the automatic run remembers between decisions (stored, so a restart keeps Later and the waits). */
data class AutoMemory(
    /** The build the Laters, the wait and the yield belong to. A newer build starts afresh. */
    val targetBuild: Long? = null,
    /** When this device first knew of [targetBuild]: devices that reported "up to date" before that are asked to check again. */
    val foundAt: Long? = null,
    val laterCount: Int = 0,
    val laterUntil: Long? = null,
    val yieldingSince: Long? = null,
    /** While someone is busy: the next look, and what was logged for this wait. */
    val waitUntil: Long? = null,
    val waiting: UpdateBusy? = null,
    val waitingDevice: String? = null,
    /** When the last automatic run for [targetBuild] ended: the next one for that build waits [AUTO_RETRY_MILLIS]. */
    val ranAt: Long? = null,
) {
    /** The person chose Later on the automatic notice: an hour, and after three Laters only when idle. */
    fun later(now: Long): AutoMemory = copy(laterCount = laterCount + 1, laterUntil = now + AUTO_LATER_MILLIS)

    /** An automatic run for [targetBuild] ended (done, failed, or put off). */
    fun ran(now: Long): AutoMemory = if (targetBuild == null) this else copy(ranAt = now)

    /** This memory for [target]: a different build starts afresh. */
    fun forTarget(target: Long, now: Long): AutoMemory = if (targetBuild != target) AutoMemory(targetBuild = target, foundAt = now) else this

    fun toJson(): JSONObject = JSONObject().apply {
        targetBuild?.let { put("targetBuild", it) }
        foundAt?.let { put("foundAt", it) }
        put("laterCount", laterCount)
        laterUntil?.let { put("laterUntil", it) }
        yieldingSince?.let { put("yieldingSince", it) }
        waitUntil?.let { put("waitUntil", it) }
        waiting?.let { put("waiting", it.wire) }
        waitingDevice?.let { put("waitingDevice", it) }
        ranAt?.let { put("ranAt", it) }
    }

    companion object {
        /** A stored memory; anything unreadable starts afresh. */
        fun fromJson(json: JSONObject?): AutoMemory = json?.let {
            runCatching {
                fun long(key: String): Long? = if (it.has(key)) it.getLong(key) else null
                AutoMemory(
                    targetBuild = long("targetBuild"),
                    foundAt = long("foundAt"),
                    laterCount = it.optInt("laterCount", 0).coerceIn(0, 100),
                    laterUntil = long("laterUntil"),
                    yieldingSince = long("yieldingSince"),
                    waitUntil = long("waitUntil"),
                    waiting = if (it.has("waiting")) UpdateBusy.fromWire(it.getString("waiting")) else null,
                    waitingDevice = if (it.has("waitingDevice")) it.getString("waitingDevice") else null,
                    ranAt = long("ranAt"),
                )
            }.getOrNull()
        } ?: AutoMemory()
    }
}

sealed interface AutoDecision {
    /** The setting is off. */
    data object Off : AutoDecision

    data object NothingToDo : AutoDecision

    /** A run is going here, or this device updates because another one asked. */
    data object Running : AutoDecision

    /** Start Update all now. Peers that last reported "up to date" before [refreshBefore] are asked to check. */
    data class Start(val targetBuild: Long, val refreshBefore: Long) : AutoDecision

    /** Someone is busy: look again at [until]. [device] is null for this device. */
    data class Wait(val busy: UpdateBusy, val device: String?, val until: Long) : AutoDecision

    /** The person chose Later. */
    data class Later(val until: Long) : AutoDecision

    /** Later three times: only when the screen is off and the phone charges. */
    data object WaitForIdle : AutoDecision

    /** A device with a lower ID and the setting on runs it. This device starts its own after [until]. */
    data class Yield(val to: String, val until: Long) : AutoDecision

    /** An automatic run for this build ended here a short while ago: the next one for it starts after [until]. */
    data class Retry(val until: Long) : AutoDecision

    /** The last attempt here did not apply; nothing tries that build again on its own. */
    data object NotApplied : AutoDecision
}

/** What the activity stream gets from one decision. */
sealed interface AutoLog {
    /** "Waiting: call in progress" ([device] null: on this device). */
    data class Waiting(val busy: UpdateBusy, val device: String?) : AutoLog
}

/** One decision, the memory to keep, and what the activity stream gets this time. */
data class AutoStep(val decision: AutoDecision, val memory: AutoMemory, val log: AutoLog? = null)

object AutoUpdatePolicy {
    private val HAS_UPDATE = setOf(UpdateState.AVAILABLE, UpdateState.DOWNLOADING, UpdateState.READY)

    /** The build this device has on offer for itself. A version that did not apply is never tried again on its own. */
    fun localTarget(status: UpdateStatus): Long? {
        val build = status.targetBuild ?: return null
        return build.takeIf { status.state in HAS_UPDATE && status.target != null && it > status.build }
    }

    /**
     * A peer's own update this device runs for it: only peers that have the setting on themselves (they
     * wait for the lowest ID), can be started from here, and have a newer build on offer.
     */
    fun peerTarget(peer: AutoPeer): Long? {
        val status = peer.status
        val build = status.targetBuild ?: return null
        return build.takeIf { status.auto && status.remoteStart && status.state in HAS_UPDATE && status.target != null && it > status.build }
    }

    /** The lowest device ID among this device and the connected peers with the setting on starts the run. */
    fun leader(localId: String, peers: List<AutoPeer>): AutoPeer? {
        val mine = localId.lowercase()
        return peers.filter { it.status.auto && it.deviceId.lowercase() < mine }.minByOrNull { it.deviceId.lowercase() }
    }

    /** The most important busy activity on any device, and where (null: this device). */
    fun busy(facts: AutoFacts): Pair<UpdateBusy, String?>? {
        val all = buildList {
            facts.localBusy?.let { add(it to null) }
            facts.peers.forEach { peer -> peer.status.busy?.let { add(it to peer.name) } }
        }
        val kind = UpdateBusy.mostImportant(all.map { it.first }) ?: return null
        return all.first { it.first == kind }
    }

    /** The newest build on offer here or for a peer this device would run it for; null when there is none. */
    fun target(facts: AutoFacts): Long? = (listOf(localTarget(facts.local)) + facts.peers.map(::peerTarget)).filterNotNull().maxOrNull()

    fun decide(facts: AutoFacts, memory: AutoMemory): AutoStep {
        val now = facts.now
        if (!facts.enabled) return AutoStep(AutoDecision.Off, AutoMemory())
        if (facts.runActive || facts.updatingForPeer) return AutoStep(AutoDecision.Running, memory)
        val mine = localTarget(facts.local)
        val target = target(facts)
        if (target == null) {
            val didNotApply = facts.local.state == UpdateState.FAILED && facts.local.reason == UpdateReason.NOT_APPLIED
            return AutoStep(if (didNotApply) AutoDecision.NotApplied else AutoDecision.NothingToDo, AutoMemory())
        }
        var next = memory.forTarget(target, now)
        // Waiting for someone: look again only every few minutes, even if they finished sooner.
        val waitUntil = next.waitUntil
        val waiting = next.waiting
        if (waitUntil != null && now < waitUntil && waiting != null) {
            return AutoStep(AutoDecision.Wait(waiting, next.waitingDevice, waitUntil), next)
        }
        busy(facts)?.let { (kind, device) ->
            val changed = next.waiting != kind || next.waitingDevice != device
            val until = now + AUTO_RECHECK_MILLIS
            next = next.copy(waitUntil = until, waiting = kind, waitingDevice = device)
            return AutoStep(AutoDecision.Wait(kind, device, until), next, if (changed) AutoLog.Waiting(kind, device) else null)
        }
        next = next.copy(waitUntil = null, waiting = null, waitingDevice = null)
        next.laterUntil?.let { if (now < it) return AutoStep(AutoDecision.Later(it), next) }
        if (next.laterCount >= AUTO_MAX_LATER && !facts.idle) return AutoStep(AutoDecision.WaitForIdle, next)
        leader(facts.localId, facts.peers)?.let { leader ->
            val since = next.yieldingSince ?: now
            next = next.copy(yieldingSince = since)
            val until = since + AUTO_YIELD_MILLIS
            // Only this device's own update may go ahead without the leader, and only after the wait.
            if (mine == null || now < until) return AutoStep(AutoDecision.Yield(leader.name, until), next)
        }
        next = next.copy(yieldingSince = null)
        next.ranAt?.let { ran -> if (now >= ran && now < ran + AUTO_RETRY_MILLIS) return AutoStep(AutoDecision.Retry(ran + AUTO_RETRY_MILLIS), next) }
        return AutoStep(AutoDecision.Start(target, next.foundAt ?: now), next)
    }

    /**
     * The Mac's command line skips the setting, Later and the lowest-ID rule, but never starts over a
     * run, an update another device started, or someone busy. Android has no command line; the same
     * rule is kept here so both platforms read alike.
     */
    sealed interface Blocked {
        data object RunActive : Blocked
        data object UpdatingForPeer : Blocked
        data class Busy(val busy: UpdateBusy, val device: String?) : Blocked
    }

    fun commandLineBlocked(facts: AutoFacts): Blocked? = when {
        facts.runActive -> Blocked.RunActive
        facts.updatingForPeer -> Blocked.UpdatingForPeer
        else -> busy(facts)?.let { (kind, device) -> Blocked.Busy(kind, device) }
    }
}

/** What a device asked to update itself (updates.start) does with an automatic start. */
object AutoStartRule {
    /** An automatic start finds the person busy here: refuse busy. A start someone tapped goes ahead. */
    fun refusesBusy(start: UpdateStart, localBusy: UpdateBusy?): Boolean = start.auto && localBusy != null
}
