package dev.bridgey.android.updates

import org.json.JSONArray
import org.json.JSONObject

/*
 * Update all, the side that runs it (docs/protocol.md "Update all"; inspired by T3 Code's Update
 * everything). The planner says what one tap will update and what it skips; the run follows each
 * device and installs this phone last, after a short countdown. Both are pure (clock and effects
 * injected) so every rule is unit tested. The Mac has the same rules in UpdateAll.swift.
 */

/** The ID the plan and the run use for this device. */
const val LOCAL_DEVICE_ID = "local"

/** A peer whose last check is older than this is asked to check and update if newer. */
const val UPDATE_STALE_CHECK_MILLIS = 60L * 60 * 1000

/** A device whose step has run this long is "taking longer than usual". */
const val UPDATE_SLOW_AFTER_MILLIS = 3L * 60 * 1000

/** No updates.result this long after updates.start: no answer. */
const val UPDATE_RESULT_TIMEOUT_MILLIS = 20_000L

/** Disconnected (not restarting) this long: the connection is lost. */
const val UPDATE_LOST_AFTER_MILLIS = 3L * 60 * 1000

/** Restarting this long without coming back: it did not return. */
const val UPDATE_RETURN_TIMEOUT_MILLIS = 15L * 60 * 1000

/** This phone's own restart waits this long, with Later. */
const val UPDATE_COUNTDOWN_MILLIS = 10_000L

/** A saved run is shown again after a restart for this long. */
const val UPDATE_RUN_LIFETIME_MILLIS = 30L * 60 * 1000

/** One connected (or paired but offline) device as the planner sees it. */
data class PeerUpdateInfo(
    val deviceId: String,
    val name: String,
    val connected: Boolean,
    /** Both sides advertise updates_draft1. */
    val supportsUpdates: Boolean,
    /** Its latest updates.status, or null before the first one. */
    val status: UpdateStatus?,
)

enum class UpdateSkipReason {
    /** Paired but not connected. */
    OFFLINE,

    /** Upstream Bridgey, an older edition build, or a build that cannot update itself. */
    BY_HAND,

    /** Connected, but its version has not arrived yet. */
    NO_STATUS,

    /** Its last update did not apply; Update all does not try it again. */
    NOT_APPLIED,

    /** Its "Let paired devices start updates" switch is off. */
    REMOTE_OFF,
}

/** One device Update all will update. [to] null means "the newest build of its channel, if newer". */
data class PlanTarget(
    val deviceId: String,
    val name: String,
    val fromApp: String,
    val fromBuild: Long,
    val to: String?,
    val toBuild: Long?,
    val channel: WireChannel,
    val platform: UpdatePlatform,
) {
    val isLocal: Boolean get() = deviceId == LOCAL_DEVICE_ID
}

data class PlanSkip(val deviceId: String, val name: String, val reason: UpdateSkipReason)

data class UpdatePlan(
    /** Peers sorted by name, then this device last. */
    val targets: List<PlanTarget>,
    val skipped: List<PlanSkip>,
    /** Devices with nothing newer (names, peers then this device). */
    val upToDate: List<String>,
    /** The targets are on more than one channel; each stays on its own. */
    val channelsDiffer: Boolean,
    /** Update all is offered: at least one target has a known version to go to. */
    val visible: Boolean,
) {
    val peerTargets: List<PlanTarget> get() = targets.filterNot { it.isLocal }
    val includesLocal: Boolean get() = targets.any { it.isLocal }
}

private val HAS_UPDATE = setOf(UpdateState.AVAILABLE, UpdateState.DOWNLOADING, UpdateState.READY, UpdateState.NEEDS_USER, UpdateState.INSTALLING)

/** What one tap of Update all will do, for [local] (this device's own status) and every paired peer. */
fun planUpdateAll(local: UpdateStatus, localName: String, peers: List<PeerUpdateInfo>, now: Long): UpdatePlan {
    val targets = mutableListOf<PlanTarget>()
    val skipped = mutableListOf<PlanSkip>()
    val upToDate = mutableListOf<String>()
    for (peer in peers.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })) {
        val status = peer.status
        fun skip(reason: UpdateSkipReason) { skipped += PlanSkip(peer.deviceId, peer.name, reason) }
        when {
            !peer.connected -> skip(UpdateSkipReason.OFFLINE)
            !peer.supportsUpdates -> skip(UpdateSkipReason.BY_HAND)
            status == null -> skip(UpdateSkipReason.NO_STATUS)
            status.state == UpdateState.MANUAL -> skip(UpdateSkipReason.BY_HAND)
            status.state == UpdateState.FAILED && status.reason == UpdateReason.NOT_APPLIED -> skip(UpdateSkipReason.NOT_APPLIED)
            !status.remoteStart -> skip(UpdateSkipReason.REMOTE_OFF)
            status.state in HAS_UPDATE || status.state == UpdateState.FAILED ->
                targets += PlanTarget(peer.deviceId, peer.name, status.app, status.build, status.target, status.targetBuild, status.channel, status.platform)
            status.checkedAt <= 0 || now - status.checkedAt >= UPDATE_STALE_CHECK_MILLIS ->
                targets += PlanTarget(peer.deviceId, peer.name, status.app, status.build, null, null, status.channel, status.platform)
            else -> upToDate += peer.name
        }
    }
    when {
        local.state == UpdateState.MANUAL -> skipped += PlanSkip(LOCAL_DEVICE_ID, localName, UpdateSkipReason.BY_HAND)
        local.target != null && (local.state in HAS_UPDATE - UpdateState.INSTALLING || local.state == UpdateState.FAILED) ->
            targets += PlanTarget(LOCAL_DEVICE_ID, localName, local.app, local.build, local.target, local.targetBuild, local.channel, local.platform)
        local.state == UpdateState.CURRENT || local.state == UpdateState.CHECKING -> upToDate += localName
    }
    return UpdatePlan(
        targets = targets,
        skipped = skipped,
        upToDate = upToDate,
        channelsDiffer = targets.map { it.channel }.distinct().size > 1,
        visible = targets.any { it.to != null },
    )
}

/** One device on Settings > Updates > Your devices: its version, channel and state, or why it is out of reach. */
data class DeviceUpdateRow(
    val deviceId: String,
    val name: String,
    val status: UpdateStatus?,
    val skip: UpdateSkipReason?,
) {
    val isLocal: Boolean get() = deviceId == LOCAL_DEVICE_ID
}

/** This device first, then every paired peer by name. */
fun deviceUpdateRows(local: UpdateStatus, localName: String, peers: List<PeerUpdateInfo>): List<DeviceUpdateRow> =
    listOf(DeviceUpdateRow(LOCAL_DEVICE_ID, localName, local, null)) +
        peers.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }).map { peer ->
            val skip = when {
                !peer.connected -> UpdateSkipReason.OFFLINE
                !peer.supportsUpdates -> UpdateSkipReason.BY_HAND
                peer.status == null -> UpdateSkipReason.NO_STATUS
                !peer.status.remoteStart && peer.status.state in HAS_UPDATE -> UpdateSkipReason.REMOTE_OFF
                else -> null
            }
            DeviceUpdateRow(peer.deviceId, peer.name, peer.status.takeIf { peer.connected }, skip)
        }

// MARK: The run

enum class RunStep {
    WAITING, STARTING, CHECKING, DOWNLOADING, READY, INSTALLING, RESTARTING, NEEDS_USER, DONE, UP_TO_DATE, FAILED, NOT_APPLIED;

    val terminal: Boolean get() = this == DONE || this == UP_TO_DATE || this == FAILED || this == NOT_APPLIED

    /** Counted for "taking longer than usual". */
    val active: Boolean get() = this == STARTING || this == CHECKING || this == DOWNLOADING || this == INSTALLING || this == RESTARTING
}

/** Why a device did not finish, as the run shows it. */
enum class RunFailure(val wire: String) {
    DISABLED("disabled"),
    RATE_LIMITED("rate_limited"),
    MANUAL("manual"),
    BUSY("busy"),
    CHECK("check"),
    DOWNLOAD("download"),
    SAFETY("safety"),
    INSTALLER("installer"),
    CANCELLED("cancelled"),
    NO_ANSWER("no_answer"),
    LOST_CONNECTION("lost_connection"),
    NO_RETURN("no_return"),
    INTERRUPTED("interrupted"),
    OTHER("other"),
    ;

    companion object {
        fun fromWire(value: String?): RunFailure = entries.firstOrNull { it.wire == value } ?: OTHER

        fun of(refusal: UpdateRefusal): RunFailure = when (refusal) {
            UpdateRefusal.DISABLED -> DISABLED
            UpdateRefusal.RATE_LIMITED -> RATE_LIMITED
            UpdateRefusal.MANUAL -> MANUAL
            UpdateRefusal.BUSY -> BUSY
            UpdateRefusal.NOT_APPLIED, UpdateRefusal.OTHER -> OTHER
        }

        fun of(reason: UpdateReason?): RunFailure = when (reason) {
            UpdateReason.CHECK -> CHECK
            UpdateReason.DOWNLOAD -> DOWNLOAD
            UpdateReason.SAFETY -> SAFETY
            UpdateReason.INSTALLER -> INSTALLER
            UpdateReason.CANCELLED -> CANCELLED
            else -> OTHER
        }
    }
}

data class RunItem(
    val deviceId: String,
    val name: String,
    val fromApp: String,
    val fromBuild: Long,
    val targetApp: String?,
    val targetBuild: Long?,
    val channel: WireChannel,
    val platform: UpdatePlatform,
    val step: RunStep = RunStep.WAITING,
    val progress: Int? = null,
    val needsReason: UpdateReason? = null,
    val failure: RunFailure? = null,
    /** The version it runs after the update (DONE). */
    val newApp: String? = null,
    val requestId: String? = null,
    /** When this device's update was started (or retried): what "taking longer" measures. */
    val startedAt: Long = 0,
    val stepSince: Long = 0,
    val disconnectedAt: Long? = null,
) {
    val isLocal: Boolean get() = deviceId == LOCAL_DEVICE_ID
    val retryable: Boolean get() = !isLocal && (step == RunStep.FAILED || step == RunStep.NOT_APPLIED)
}

data class UpdateRun(
    val id: String,
    val startedAt: Long,
    val items: List<RunItem>,
    /** This device's restart countdown ends here; null when no countdown runs. */
    val restartAt: Long? = null,
    /** Later was chosen: this device stays ready until the person installs. */
    val later: Boolean = false,
) {
    val peers: List<RunItem> get() = items.filterNot { it.isLocal }
    val local: RunItem? get() = items.firstOrNull { it.isLocal }

    /** Every peer finished, failed, or handed over to its installer or its person. */
    val peersSettled: Boolean get() = peers.all {
        it.step.terminal || it.step == RunStep.NEEDS_USER || it.step == RunStep.RESTARTING || it.step == RunStep.INSTALLING
    }

    val finished: Boolean get() {
        val mine = local
        return peers.all { it.step.terminal } && (mine == null || mine.step.terminal || (later && mine.step == RunStep.READY))
    }
}

/** What the run asks the platform to do. */
interface UpdateRunEffects {
    /** Sends updates.start; false when the device is no longer connected. */
    fun sendStart(deviceId: String, start: UpdateStart): Boolean

    /** Download and verify this device's update, without installing it. */
    fun prepareLocal()

    /** Install this device's prepared update now (the app restarts). */
    fun commitLocal()

    fun newRequestId(): String
}

/**
 * One Update all run. Peers start at once; this device prepares meanwhile and installs last, after
 * a [UPDATE_COUNTDOWN_MILLIS] countdown that Later stops. Never retries on its own: only [retry]
 * (the person's Retry) starts a device again, with `retry: true`.
 */
class UpdateRunMachine(private val clock: () -> Long, private val effects: UpdateRunEffects, initial: UpdateRun? = null) {
    var run: UpdateRun? = initial
        private set

    @Synchronized fun start(plan: UpdatePlan, runId: String): UpdateRun {
        val now = clock()
        val items = plan.targets.map { target ->
            RunItem(
                target.deviceId, target.name, target.fromApp, target.fromBuild, target.to, target.toBuild, target.channel, target.platform,
                startedAt = now, stepSince = now,
            )
        }
        run = UpdateRun(runId, now, items)
        items.filterNot { it.isLocal }.forEach { sendStart(it.deviceId, retry = false) }
        if (items.any { it.isLocal }) {
            update(LOCAL_DEVICE_ID) { it.copy(step = RunStep.DOWNLOADING, stepSince = now) }
            effects.prepareLocal()
        }
        advance()
        return run!!
    }

    @Synchronized fun onResult(deviceId: String, result: UpdateResult) {
        val item = item(deviceId) ?: return
        if (item.requestId != result.requestId || item.step != RunStep.STARTING) return
        when (result.status) {
            UpdateResultStatus.ACCEPTED -> step(deviceId, RunStep.CHECKING)
            UpdateResultStatus.REFUSED -> if (result.reason == UpdateRefusal.NOT_APPLIED) {
                step(deviceId, RunStep.NOT_APPLIED)
            } else {
                step(deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.of(result.reason ?: UpdateRefusal.OTHER)) }
            }
        }
        advance()
    }

    /** A peer's updates.status. */
    @Synchronized fun onStatus(deviceId: String, status: UpdateStatus) {
        val item = item(deviceId)?.takeIf { !it.isLocal && !it.step.terminal && it.step != RunStep.WAITING } ?: return
        update(deviceId) { it.copy(disconnectedAt = null) }
        if (status.build > item.fromBuild) {
            step(deviceId, RunStep.DONE) { it.copy(newApp = status.app) }
            advance()
            return
        }
        // Same build as before from here on.
        val restarted = item.step == RunStep.RESTARTING
        when (status.state) {
            UpdateState.CHECKING -> if (!restarted && item.step != RunStep.STARTING) step(deviceId, RunStep.CHECKING)
            UpdateState.AVAILABLE, UpdateState.DOWNLOADING -> if (!restarted || status.state == UpdateState.DOWNLOADING) {
                step(deviceId, RunStep.DOWNLOADING) { it.copy(progress = status.progress, targetApp = status.target ?: it.targetApp, targetBuild = status.targetBuild ?: it.targetBuild) }
            } else {
                step(deviceId, RunStep.NOT_APPLIED)
            }
            UpdateState.READY, UpdateState.INSTALLING -> if (!restarted) {
                step(deviceId, RunStep.INSTALLING) { it.copy(targetApp = status.target ?: it.targetApp, targetBuild = status.targetBuild ?: it.targetBuild) }
            }
            UpdateState.NEEDS_USER -> step(deviceId, RunStep.NEEDS_USER) { it.copy(needsReason = status.reason) }
            UpdateState.FAILED -> if (status.reason == UpdateReason.NOT_APPLIED || restarted) {
                step(deviceId, RunStep.NOT_APPLIED)
            } else {
                step(deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.of(status.reason)) }
            }
            UpdateState.MANUAL -> step(deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.MANUAL) }
            UpdateState.CURRENT -> when (item.step) {
                RunStep.INSTALLING, RunStep.RESTARTING -> step(deviceId, RunStep.NOT_APPLIED)
                RunStep.CHECKING -> step(deviceId, RunStep.UP_TO_DATE)
                else -> Unit
            }
        }
        advance()
    }

    /** This device's own updater moved (download, ready, failure). */
    @Synchronized fun onLocalStatus(status: UpdateStatus) {
        val item = run?.local?.takeIf { !it.step.terminal } ?: return
        when (status.state) {
            UpdateState.DOWNLOADING, UpdateState.AVAILABLE, UpdateState.CHECKING ->
                if (item.step == RunStep.WAITING || item.step == RunStep.DOWNLOADING) step(LOCAL_DEVICE_ID, RunStep.DOWNLOADING) { it.copy(progress = status.progress) }
            UpdateState.READY -> if (item.step != RunStep.INSTALLING) step(LOCAL_DEVICE_ID, RunStep.READY) { it.copy(progress = null) }
            UpdateState.INSTALLING -> step(LOCAL_DEVICE_ID, RunStep.INSTALLING)
            UpdateState.NEEDS_USER -> step(LOCAL_DEVICE_ID, RunStep.NEEDS_USER) { it.copy(needsReason = status.reason) }
            UpdateState.FAILED -> if (status.reason == UpdateReason.NOT_APPLIED) {
                step(LOCAL_DEVICE_ID, RunStep.NOT_APPLIED)
            } else {
                step(LOCAL_DEVICE_ID, RunStep.FAILED) { it.copy(failure = RunFailure.of(status.reason)) }
            }
            UpdateState.CURRENT -> if (item.step == RunStep.DOWNLOADING) step(LOCAL_DEVICE_ID, RunStep.UP_TO_DATE)
            UpdateState.MANUAL -> step(LOCAL_DEVICE_ID, RunStep.FAILED) { it.copy(failure = RunFailure.MANUAL) }
        }
        advance()
    }

    /** A peer's session ended. Ready or installing means it is restarting into the new version. */
    @Synchronized fun onDisconnected(deviceId: String) {
        val item = item(deviceId)?.takeIf { !it.isLocal && !it.step.terminal } ?: return
        if (item.step == RunStep.INSTALLING) {
            step(deviceId, RunStep.RESTARTING)
        } else if (item.step != RunStep.RESTARTING && item.disconnectedAt == null) {
            update(deviceId) { it.copy(disconnectedAt = clock()) }
        }
        advance()
    }

    /** Timeouts and the countdown. Call about once a second while a run is shown. */
    @Synchronized fun tick() {
        val current = run ?: return
        val now = clock()
        for (item in current.peers) {
            when {
                item.step == RunStep.STARTING && now - item.stepSince >= UPDATE_RESULT_TIMEOUT_MILLIS ->
                    step(item.deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.NO_ANSWER) }
                item.step == RunStep.RESTARTING && now - item.stepSince >= UPDATE_RETURN_TIMEOUT_MILLIS ->
                    step(item.deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.NO_RETURN) }
                !item.step.terminal && item.step != RunStep.RESTARTING && item.disconnectedAt != null &&
                    now - item.disconnectedAt >= UPDATE_LOST_AFTER_MILLIS ->
                    step(item.deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.LOST_CONNECTION) }
            }
        }
        advance()
    }

    /** The person's Retry for one device: a new start with `retry: true`. */
    @Synchronized fun retry(deviceId: String) {
        val item = item(deviceId)?.takeIf { it.retryable } ?: return
        val now = clock()
        update(deviceId) { it.copy(failure = null, newApp = null, progress = null, needsReason = null, disconnectedAt = null, startedAt = now) }
        sendStart(item.deviceId, retry = true)
        advance()
    }

    /** Later: this device's restart waits until the person installs it. */
    @Synchronized fun later() {
        val current = run ?: return
        run = current.copy(restartAt = null, later = true)
    }

    /** The finished run's summary was closed. */
    @Synchronized fun dismiss() {
        run = null
    }

    private fun sendStart(deviceId: String, retry: Boolean) {
        val requestId = effects.newRequestId()
        step(deviceId, RunStep.STARTING) { it.copy(requestId = requestId) }
        if (!effects.sendStart(deviceId, UpdateStart(requestId, retry))) {
            step(deviceId, RunStep.FAILED) { it.copy(failure = RunFailure.LOST_CONNECTION) }
        }
    }

    /** This device installs last: a countdown once it is ready and every peer has settled; then it commits. */
    private fun advance() {
        val current = run ?: return
        val local = current.local ?: return
        val now = clock()
        when {
            local.step == RunStep.READY && !current.later && current.peersSettled && current.restartAt == null ->
                run = current.copy(restartAt = now + UPDATE_COUNTDOWN_MILLIS)
            local.step == RunStep.READY && current.restartAt != null && now >= current.restartAt -> {
                run = current.copy(restartAt = null)
                step(LOCAL_DEVICE_ID, RunStep.INSTALLING)
                effects.commitLocal()
            }
        }
    }

    private fun item(deviceId: String): RunItem? = run?.items?.firstOrNull { it.deviceId == deviceId }

    private fun update(deviceId: String, change: (RunItem) -> RunItem) {
        val current = run ?: return
        run = current.copy(items = current.items.map { if (it.deviceId == deviceId) change(it) else it })
    }

    private fun step(deviceId: String, step: RunStep, change: (RunItem) -> RunItem = { it }) {
        val now = clock()
        update(deviceId) { item -> change(if (item.step == step) item else item.copy(step = step, stepSince = now)) }
    }
}

// MARK: What the run says

/** The run in one line (the capsule on Home and the Updates page), most urgent first. */
sealed interface RunSummary {
    data class Countdown(val seconds: Int) : RunSummary
    data object Restarting : RunSummary
    data class Slow(val name: String, val minutes: Long) : RunSummary
    /** [here]: this phone waits for the person (Android's confirmation or Install unknown apps). */
    data class WaitingFor(val name: String, val here: Boolean = false) : RunSummary
    data class Progress(val done: Int, val total: Int) : RunSummary
    data class Failed(val name: String?, val count: Int) : RunSummary
    data object ReadyLater : RunSummary
    data class AllUpdated(val total: Int) : RunSummary
}

fun summarizeRun(run: UpdateRun, now: Long): RunSummary {
    run.restartAt?.let { return RunSummary.Countdown(maxOf(0L, (it - now + 999) / 1000).toInt()) }
    if (run.local?.step == RunStep.INSTALLING) return RunSummary.Restarting
    val slow = run.items.filter { it.step.active && now - it.startedAt >= UPDATE_SLOW_AFTER_MILLIS }.minByOrNull { it.startedAt }
    if (slow != null) return RunSummary.Slow(slow.name, (now - slow.startedAt) / 60_000)
    run.items.firstOrNull { it.step == RunStep.NEEDS_USER }?.let { return RunSummary.WaitingFor(it.name, here = it.isLocal) }
    val done = run.items.count { it.step == RunStep.DONE || it.step == RunStep.UP_TO_DATE }
    if (run.items.any { !it.step.terminal && !(run.later && it.isLocal && it.step == RunStep.READY) }) {
        return RunSummary.Progress(done, run.items.size)
    }
    val failed = run.items.filter { it.step == RunStep.FAILED || it.step == RunStep.NOT_APPLIED }
    if (failed.isNotEmpty()) return RunSummary.Failed(failed.singleOrNull()?.name, failed.size)
    if (run.later && run.local?.step == RunStep.READY) return RunSummary.ReadyLater
    return RunSummary.AllUpdated(run.items.size)
}

/** The device "taking longer than usual", if this one is. */
fun RunItem.isSlow(now: Long): Boolean = step.active && now - startedAt >= UPDATE_SLOW_AFTER_MILLIS

// MARK: Saving the run across this phone's own restart

fun UpdateRun.toJson(): JSONObject = JSONObject().apply {
    put("id", id)
    put("startedAt", startedAt)
    restartAt?.let { put("restartAt", it) }
    put("later", later)
    put("items", JSONArray().apply {
        items.forEach { item ->
            put(JSONObject().apply {
                put("deviceId", item.deviceId)
                put("name", item.name)
                put("fromApp", item.fromApp)
                put("fromBuild", item.fromBuild)
                item.targetApp?.let { put("targetApp", it) }
                item.targetBuild?.let { put("targetBuild", it) }
                put("channel", item.channel.wire)
                put("platform", item.platform.wire)
                put("step", item.step.name)
                item.progress?.let { put("progress", it) }
                item.needsReason?.let { put("needsReason", it.wire) }
                item.failure?.let { put("failure", it.wire) }
                item.newApp?.let { put("newApp", it) }
                item.requestId?.let { put("requestId", it) }
                put("startedAt", item.startedAt)
                put("stepSince", item.stepSince)
                item.disconnectedAt?.let { put("disconnectedAt", it) }
            })
        }
    })
}

/**
 * A saved run, or null when unreadable or older than [UPDATE_RUN_LIFETIME_MILLIS]. This phone's
 * own item is settled by its build now: at or above the target means done; installing with the
 * old build means the update did not apply; any other unfinished step was interrupted. Peers wait
 * for their next status (they count as disconnected until it comes).
 */
fun restoreUpdateRun(json: JSONObject, installedApp: String, installedBuild: Long, now: Long): UpdateRun? = runCatching {
    val startedAt = json.getLong("startedAt")
    if (now < startedAt || now - startedAt >= UPDATE_RUN_LIFETIME_MILLIS) return null
    val array = json.getJSONArray("items")
    val items = (0 until array.length()).map { index ->
        val o = array.getJSONObject(index)
        RunItem(
            deviceId = o.getString("deviceId"),
            name = o.getString("name"),
            fromApp = o.getString("fromApp"),
            fromBuild = o.getLong("fromBuild"),
            targetApp = o.optString("targetApp").takeIf { o.has("targetApp") },
            targetBuild = if (o.has("targetBuild")) o.getLong("targetBuild") else null,
            channel = WireChannel.fromWire(o.getString("channel")) ?: return null,
            platform = UpdatePlatform.fromWire(o.getString("platform")) ?: return null,
            step = RunStep.valueOf(o.getString("step")),
            progress = if (o.has("progress")) o.getInt("progress") else null,
            needsReason = o.optString("needsReason").takeIf { o.has("needsReason") }?.let(UpdateReason::fromWire),
            failure = o.optString("failure").takeIf { o.has("failure") }?.let(RunFailure::fromWire),
            newApp = o.optString("newApp").takeIf { o.has("newApp") },
            requestId = o.optString("requestId").takeIf { o.has("requestId") },
            startedAt = o.getLong("startedAt"),
            stepSince = o.getLong("stepSince"),
            disconnectedAt = if (o.has("disconnectedAt")) o.getLong("disconnectedAt") else null,
        )
    }.map { item ->
        when {
            item.isLocal && !item.step.terminal -> when {
                installedBuild > item.fromBuild -> item.copy(step = RunStep.DONE, newApp = installedApp, stepSince = now)
                item.step == RunStep.INSTALLING -> item.copy(step = RunStep.NOT_APPLIED, stepSince = now)
                else -> item.copy(step = RunStep.FAILED, failure = RunFailure.INTERRUPTED, stepSince = now)
            }
            !item.isLocal && !item.step.terminal && item.step != RunStep.RESTARTING && item.disconnectedAt == null ->
                item.copy(disconnectedAt = now)
            else -> item
        }
    }
    UpdateRun(json.getString("id"), startedAt, items, restartAt = null, later = json.optBoolean("later", false))
}.getOrNull()
