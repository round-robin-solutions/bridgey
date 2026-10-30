package dev.bridgey.android.updates

import dev.bridgey.android.activity.ActivityKind
import org.json.JSONObject

/*
 * Update all devices automatically, the part between the pure rules (AutoUpdate.kt) and the phone:
 * it keeps the memory (Later, the waits, the yield), starts the automatic run when the rules say so,
 * remembers the last automatic run for Settings, and says what happened in the activity stream with
 * the keys the Mac uses. No Android types, so it is unit tested with a fake store and fake effects;
 * UpdateAllCoordinator builds the facts and does the effects.
 */

/** Where the automatic run keeps what it remembers: SharedPreferences on the phone, a map in tests. */
interface AutoStore {
    fun read(key: String): String?
    fun write(key: String, value: String?)
}

/** The last automatic run here, for Settings > Updates. */
data class AutoRunRecord(
    val at: Long,
    /** The version it went to: this phone's, or the first device's. */
    val version: String?,
    /** Devices that updated or were already up to date. */
    val updated: Int,
    val total: Int,
    /** Devices whose update did not finish or did not apply. */
    val failed: Int,
    /** This phone's restart was put off with Later. */
    val later: Boolean,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("at", at)
        version?.let { put("version", it) }
        put("updated", updated)
        put("total", total)
        put("failed", failed)
        if (later) put("later", true)
    }

    companion object {
        fun of(run: UpdateRun, now: Long): AutoRunRecord {
            val version = run.local?.let { it.newApp ?: it.targetApp } ?: run.items.firstNotNullOfOrNull { it.newApp ?: it.targetApp }
            return AutoRunRecord(
                at = now,
                version = version,
                updated = run.items.count { it.step == RunStep.DONE || it.step == RunStep.UP_TO_DATE },
                total = run.items.size,
                failed = run.items.count { it.step == RunStep.FAILED || it.step == RunStep.NOT_APPLIED },
                later = run.later && run.local?.step == RunStep.READY,
            )
        }

        fun fromJson(text: String?): AutoRunRecord? = text?.let {
            runCatching {
                val json = JSONObject(it)
                AutoRunRecord(
                    at = json.getLong("at"),
                    version = if (json.has("version")) json.getString("version") else null,
                    updated = json.getInt("updated"),
                    total = json.getInt("total"),
                    failed = json.optInt("failed", 0),
                    later = json.optBoolean("later", false),
                )
            }.getOrNull()
        }
    }
}

/** What Settings > Updates says under Update all devices automatically, besides how often it checks. */
sealed interface AutoCondition {
    /** "Waiting: call in progress", with the device when it is not this phone. */
    data class Waiting(val busy: UpdateBusy, val device: String?) : AutoCondition

    /** "Put off until 15:30". */
    data class PutOff(val until: Long) : AutoCondition

    /** Later three times: "Waits until the screen is off and the phone is charging". */
    data object IdleOnly : AutoCondition

    /** "Work Mac starts these updates". */
    data class Yielding(val to: String) : AutoCondition

    /** An automatic run for this build ended a short while ago: "Tries again at 15:30". */
    data class Retrying(val at: Long) : AutoCondition
}

/**
 * The condition worth a line now: a run that holds this phone's restart for someone busy, else what
 * the last decision waits for. [runBusy] is who is busy, from the last look.
 */
fun autoCondition(decision: AutoDecision?, run: UpdateRun?, runBusy: Pair<UpdateBusy, String?>?, now: Long): AutoCondition? {
    if (run != null && !run.finished) {
        val held = summarizeRun(run, now) as? RunSummary.Held ?: return null
        return AutoCondition.Waiting(held.busy, runBusy?.takeIf { it.first == held.busy }?.second)
    }
    return when (decision) {
        is AutoDecision.Wait -> AutoCondition.Waiting(decision.busy, decision.device)
        is AutoDecision.Later -> AutoCondition.PutOff(decision.until)
        AutoDecision.WaitForIdle -> AutoCondition.IdleOnly
        is AutoDecision.Yield -> AutoCondition.Yielding(decision.to)
        is AutoDecision.Retry -> AutoCondition.Retrying(decision.until)
        else -> null
    }
}

/** Update all devices automatically as Settings > Updates draws it. */
data class AutoUpdateView(
    /** This build can update itself (it has an HTTPS feed). */
    val supported: Boolean = true,
    /** The setting as it is now: the person's choice, or the channel's default. */
    val on: Boolean = false,
    val channel: WireChannel = WireChannel.STABLE,
    val condition: AutoCondition? = null,
    val lastRun: AutoRunRecord? = null,
) {
    /** How often this phone checks its channel now. */
    val checkEvery: Long get() = AutoUpdateRules.checkInterval(on && supported, channel)
}

/** The skip reasons the activity stream names (the Mac uses the same words); null for ones it leaves out. */
fun UpdateSkipReason.autoWire(): String? = when (this) {
    UpdateSkipReason.OFFLINE -> "offline"
    UpdateSkipReason.BY_HAND -> "by_hand"
    UpdateSkipReason.NOT_APPLIED -> "not_applied"
    UpdateSkipReason.REMOTE_OFF -> "remote_off"
    UpdateSkipReason.NO_STATUS -> null
}

/** The activity stream's content for a device whose automatic update did not apply (a [RunFailure] wire otherwise). */
const val AUTO_FAILED_NOT_APPLIED = "not_applied"

/** A start from another device marked automatic, kept until this phone runs again (to say "Updated automatically"). */
data class PeerStartMarker(val fromBuild: Long, val at: Long)

/** The automatic run's notification, as a model: it is posted again only when this changes. */
data class AutoNotice(
    /** The version this phone (or else the first device) goes to. */
    val version: String?,
    /** The devices that update before this phone. */
    val first: List<String>,
    val includesLocal: Boolean,
    /** This phone's restart: the countdown ends here. */
    val restartAt: Long?,
    /** Someone is busy and this phone's restart waits. */
    val held: UpdateBusy?,
    val restarting: Boolean,
) {
    companion object {
        /** The notice for an automatic run going on here, or null when there is none to show. */
        fun of(run: UpdateRun?, now: Long): AutoNotice? {
            if (run == null || !run.auto || run.finished || run.later) return null
            val local = run.local
            val summary = summarizeRun(run, now)
            return AutoNotice(
                version = local?.targetApp ?: run.items.firstNotNullOfOrNull { it.targetApp },
                first = run.peers.map { it.name },
                includesLocal = local != null,
                restartAt = run.restartAt,
                held = (summary as? RunSummary.Held)?.busy,
                restarting = local?.step == RunStep.INSTALLING,
            )
        }
    }
}

/**
 * Runs Update all devices automatically from [AutoUpdatePolicy]'s decisions. Call [evaluate] with
 * fresh facts whenever something may have changed; the rest are the moments the coordinator sees.
 */
class AutoUpdateController(
    private val clock: () -> Long,
    private val store: AutoStore,
    private val effects: Effects,
) {
    interface Effects {
        /** Plans Update all with [refreshBefore] and starts it as an automatic run; the plan, or null when nothing started. */
        fun startRun(refreshBefore: Long): UpdatePlan?

        /** An activity stream entry (the keys are shared with the Mac). [deviceId] null: this phone. */
        fun record(kind: ActivityKind, deviceId: String?, deviceName: String, content: String?)
    }

    var memory: AutoMemory = AutoMemory.fromJson(store.read(KEY_MEMORY)?.let { runCatching { JSONObject(it) }.getOrNull() })
        private set

    /** The last decision, for Settings and the heartbeat. */
    var decision: AutoDecision? = null
        private set

    var lastRun: AutoRunRecord? = AutoRunRecord.fromJson(store.read(KEY_LAST_RUN))
        private set

    /** When an updates.start from another device was last accepted (any start, tapped or automatic). */
    var peerStartAt: Long? = null
        private set

    /** Who holds this phone's restart in the automatic run going on, as last logged. */
    private var held: Pair<UpdateBusy, String?>? = null

    /** Decides with [facts], keeps the memory, logs a new wait, and starts the run when it is time. */
    @Synchronized fun evaluate(facts: AutoFacts): AutoDecision {
        val step = AutoUpdatePolicy.decide(facts, memory)
        remember(step.memory)
        decision = step.decision
        (step.log as? AutoLog.Waiting)?.let { waiting(it.busy, it.device, facts.peers, facts.localName) }
        val start = step.decision as? AutoDecision.Start
        if (start != null) {
            val plan = effects.startRun(start.refreshBefore)
            plan?.skipped?.forEach { skip ->
                val reason = skip.reason.autoWire() ?: return@forEach
                effects.record(ActivityKind.UPDATE_AUTO_SKIPPED, skip.deviceId.takeUnless { it == LOCAL_DEVICE_ID }, skip.name, reason)
            }
            held = null
        }
        return step.decision
    }

    /** Waiting, Later, idle only, a yield or a retry: worth looking again every minute. */
    val pending: Boolean
        get() = when (decision) {
            is AutoDecision.Wait, is AutoDecision.Later, AutoDecision.WaitForIdle, is AutoDecision.Yield, is AutoDecision.Retry -> true
            else -> false
        }

    /**
     * Later on the automatic notice or the capsule, in any run while the setting is on: an hour, and
     * after three Laters only when the phone is idle. [target] is the build on offer now ([AutoUpdatePolicy.target]).
     */
    @Synchronized fun later(target: Long?) {
        target ?: return
        val now = clock()
        remember(memory.forTarget(target, now).later(now))
    }

    /**
     * During a run, each look: logs "Waiting: call in progress" (once per who and what) while an
     * automatic run holds this phone's restart. [busy] is who is busy now; [peers] give device IDs.
     */
    @Synchronized fun runLook(run: UpdateRun, busy: Pair<UpdateBusy, String?>?, peers: List<AutoPeer>, localName: String) {
        if (!run.auto) return
        val now = busy?.takeIf { summarizeRun(run, clock()) is RunSummary.Held }
        if (now != null && now != held) waiting(now.first, now.second, peers, localName)
        held = now
    }

    /**
     * A run finished (or was restored finished). Whatever is still on offer ([target], null when nothing
     * is) waits [AUTO_RETRY_MILLIS] before an automatic run, after a tapped run too. Automatic runs are
     * recorded once, with their failures.
     */
    @Synchronized fun runEnded(run: UpdateRun, target: Long?) {
        if (store.read(KEY_ENDED_RUN) == run.id) return
        store.write(KEY_ENDED_RUN, run.id)
        val now = clock()
        target?.let { remember(memory.forTarget(it, now).ran(now)) }
        held = null
        if (!run.auto) return
        val record = AutoRunRecord.of(run, now)
        lastRun = record
        store.write(KEY_LAST_RUN, record.toJson().toString())
        run.items.filter { it.step == RunStep.FAILED || it.step == RunStep.NOT_APPLIED }.forEach { item ->
            val content = if (item.step == RunStep.NOT_APPLIED) AUTO_FAILED_NOT_APPLIED else (item.failure ?: RunFailure.OTHER).wire
            effects.record(ActivityKind.UPDATE_AUTO_FAILED, item.deviceId.takeUnless { item.isLocal }, item.name, content)
        }
    }

    /** After this phone restarted: a restored automatic run in which this phone updated says so, once. */
    @Synchronized fun restored(run: UpdateRun, installedBuild: Long, installedApp: String, localName: String) {
        val local = run.local ?: return
        if (run.auto && local.step == RunStep.DONE) updatedHere(installedBuild, local.newApp ?: installedApp, localName)
    }

    /**
     * Another device's updates.start was accepted. An automatic one says who started it and leaves a
     * marker, so "Updated automatically" shows after this phone restarts into the new version.
     */
    @Synchronized fun peerStartAccepted(deviceId: String, name: String, start: UpdateStart, installedBuild: Long) {
        val now = clock()
        peerStartAt = now
        if (!start.auto) return
        effects.record(ActivityKind.UPDATE_AUTO_STARTED_BY, deviceId, name, null)
        store.write(KEY_MARKER, JSONObject().put("fromBuild", installedBuild).put("at", now).toString())
    }

    /** At start: a marker from an automatic start that this phone has since updated past says so, once. */
    @Synchronized fun settleMarker(installedBuild: Long, installedApp: String, localName: String) {
        val marker = store.read(KEY_MARKER)?.let { text ->
            runCatching { JSONObject(text).let { PeerStartMarker(it.getLong("fromBuild"), it.getLong("at")) } }.getOrNull()
        }
        if (marker == null) {
            store.write(KEY_MARKER, null)
            return
        }
        val now = clock()
        val fresh = now >= marker.at && now - marker.at < MARKER_LIFETIME_MILLIS
        when {
            installedBuild > marker.fromBuild -> {
                if (fresh) updatedHere(installedBuild, installedApp, localName)
                store.write(KEY_MARKER, null)
            }
            !fresh -> store.write(KEY_MARKER, null)
        }
    }

    /** This phone updated another device's or its own automatic run: "Updated automatically to 0.10.0-rr.1-beta.11", once per build. */
    private fun updatedHere(installedBuild: Long, version: String, localName: String) {
        if (store.read(KEY_DONE_BUILD) == installedBuild.toString()) return
        store.write(KEY_DONE_BUILD, installedBuild.toString())
        effects.record(ActivityKind.UPDATE_AUTO_DONE, null, localName, version)
    }

    private fun waiting(busy: UpdateBusy, device: String?, peers: List<AutoPeer>, localName: String) {
        val peer = device?.let { name -> peers.firstOrNull { it.name == name } }
        effects.record(ActivityKind.UPDATE_AUTO_WAITING, peer?.deviceId, device ?: localName, busy.wire)
    }

    private fun remember(next: AutoMemory) {
        if (next == memory) return
        memory = next
        store.write(KEY_MEMORY, next.toJson().toString())
    }

    companion object {
        const val KEY_MEMORY = "auto.memory"
        const val KEY_LAST_RUN = "auto.last_run"
        const val KEY_ENDED_RUN = "auto.ended_run"
        const val KEY_MARKER = "auto.peer_start"
        const val KEY_DONE_BUILD = "auto.done_build"

        /** An automatic start from another device counts for "Updated automatically" this long. */
        const val MARKER_LIFETIME_MILLIS = 60L * 60 * 1000
    }
}
