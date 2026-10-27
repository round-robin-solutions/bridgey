package dev.bridgey.android.updates

import android.content.Context
import dev.bridgey.android.AppUpdater
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.R
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.json.JSONObject

/** What the pairing coordinator tells Update all (draft updates_draft1). Calls may come from any thread. */
interface UpdatesPeerHost {
    /** A device's features.update shows updates_draft1 on both sides: it hears this phone's status. */
    fun peerReady(deviceId: String)

    fun statusReceived(deviceId: String, status: UpdateStatus)

    /** Decides an updates.start; null accepts. The coordinator answers updates.result either way. */
    fun startReceived(deviceId: String, start: UpdateStart): UpdateRefusal?

    /** After the accepted answer went out: start updating. */
    fun startAccepted(deviceId: String, start: UpdateStart)

    fun resultReceived(deviceId: String, result: UpdateResult)

    fun disconnected(deviceId: String)
}

/** What Update all would do, and every device's row for Settings > Updates. */
data class UpdateOverview(val plan: UpdatePlan, val devices: List<DeviceUpdateRow>)

/** The run and the clock the UI draws it with. */
data class UpdateAllState(val run: UpdateRun? = null, val now: Long = 0L)

/**
 * Update all on the phone: tells every Mac that understands it this phone's version and update
 * state, answers a Mac's updates.start through [UpdateStartGate] and this phone's own updater, and
 * runs Update all from here (every connected Mac first, this phone last, after a countdown).
 */
class UpdateAllCoordinator(
    private val context: Context,
    private val scope: CoroutineScope,
    private val pairing: PairingCoordinator,
    private val updater: AppUpdater,
    private val settings: BridgeySettings,
    private val clock: () -> Long = System::currentTimeMillis,
) : UpdatesPeerHost {
    private val gate = UpdateStartGate(clock)
    private val preferences = context.getSharedPreferences("bridgey.updates.run", Context.MODE_PRIVATE)
    private val machine: UpdateRunMachine
    private val mutableState = MutableStateFlow(UpdateAllState(now = clock()))
    val state: StateFlow<UpdateAllState> = mutableState.asStateFlow()
    private var ticker: Job? = null

    /** The status last sent to each device, without its progress, and when progress last went. */
    private val lastSent = mutableMapOf<String, UpdateStatus>()
    private val lastProgressAt = mutableMapOf<String, Long>()

    private val localName: String get() = context.getString(R.string.update_all_this_phone)

    init {
        val saved = preferences.getString(KEY_RUN, null)?.let { text ->
            runCatching { JSONObject(text) }.getOrNull()?.let {
                restoreUpdateRun(it, updater.installedVersionName, updater.installedVersionCode, clock())
            }
        }
        machine = UpdateRunMachine(clock, Effects(), saved)
        if (saved == null) preferences.edit().remove(KEY_RUN).apply()
        publish()
    }

    /** What Update all would do now, and every device's row. Recomputed as devices connect and report and as this phone's updater moves. */
    val overview: StateFlow<UpdateOverview> = combine(pairing.connections, pairing.trustedDevices, updater.state, settings.state) { _, _, _, _ -> currentOverview() }
        .stateIn(scope, SharingStarted.Eagerly, currentOverview())

    fun start() {
        scope.launch {
            // This phone's status goes to every Mac that understands it whenever it changes.
            combine(updater.state, settings.state.map { it.updatesRemoteStart }.distinctUntilChanged()) { _, remoteStart -> updater.wireStatus(remoteStart) }
                .collect { status ->
                    broadcast(status)
                    machine.onLocalStatus(status)
                    publish()
                }
        }
        if (machine.run?.finished == false) startTicker()
    }

    fun currentPlan(): UpdatePlan = currentOverview().plan

    private fun currentOverview(): UpdateOverview {
        val connections = pairing.connections.value.associateBy { it.deviceId }
        val trusted = pairing.trustedDevices.value
        val ids = (trusted.map { it.id } + connections.keys).distinct()
        val peers = ids.map { id ->
            val connection = connections[id]
            PeerUpdateInfo(
                deviceId = id,
                name = trusted.firstOrNull { it.id == id }?.name ?: connection?.peerName.orEmpty(),
                connected = connection != null,
                supportsUpdates = connection?.state?.remoteUpdates == true,
                status = connection?.state?.updateStatus,
            )
        }
        val local = updater.wireStatus(settings.state.value.updatesRemoteStart)
        return UpdateOverview(planUpdateAll(local, localName, peers, clock()), deviceUpdateRows(local, localName, peers))
    }

    /** Update all: every connected Mac that will update starts now; this phone installs last. */
    fun runUpdateAll() {
        if (machine.run?.finished == false) return
        val plan = currentPlan()
        if (plan.targets.isEmpty()) return
        machine.start(plan, UUID.randomUUID().toString())
        publish()
        startTicker()
    }

    fun retry(deviceId: String) {
        machine.retry(deviceId)
        publish()
        startTicker()
    }

    /** Later during this phone's countdown: the update waits, verified, for Install in Settings > Updates. */
    fun later() {
        machine.later()
        updater.laterAfterRun()
        publish()
    }

    fun dismiss() {
        machine.dismiss()
        publish()
    }

    // MARK: UpdatesPeerHost

    override fun peerReady(deviceId: String) {
        val status = updater.wireStatus(settings.state.value.updatesRemoteStart)
        synchronized(lastSent) { lastSent.remove(deviceId) }
        send(deviceId, status, force = true)
    }

    override fun statusReceived(deviceId: String, status: UpdateStatus) {
        machine.onStatus(deviceId, status)
        publish()
    }

    override fun startReceived(deviceId: String, start: UpdateStart): UpdateRefusal? {
        val updateState = updater.state.value
        return gate.decide(
            deviceId,
            start,
            UpdateGateFacts(
                remoteStartOn = settings.state.value.updatesRemoteStart,
                updaterAvailable = updater.canUpdate,
                busy = false,
                notApplied = updateState.notApplied,
                offeredBuild = updateState.available?.versionCode,
            ),
        )
    }

    override fun startAccepted(deviceId: String, start: UpdateStart) {
        scope.launch { updater.startFromPeer(start.retry) }
    }

    override fun resultReceived(deviceId: String, result: UpdateResult) {
        machine.onResult(deviceId, result)
        publish()
    }

    override fun disconnected(deviceId: String) {
        synchronized(lastSent) {
            lastSent.remove(deviceId)
            lastProgressAt.remove(deviceId)
        }
        machine.onDisconnected(deviceId)
        publish()
    }

    // MARK: Sending this phone's status

    private fun broadcast(status: UpdateStatus) {
        pairing.updatePeers().forEach { send(it, status, force = false) }
    }

    /** Every change but progress goes at once; progress at most once a second. */
    private fun send(deviceId: String, status: UpdateStatus, force: Boolean) {
        val now = clock()
        val shouldSend = synchronized(lastSent) {
            val previous = lastSent[deviceId]
            val changed = force || previous != status.withoutProgress()
            val progressDue = status.progress != null && now - (lastProgressAt[deviceId] ?: 0L) >= PROGRESS_INTERVAL_MILLIS
            if (changed || progressDue) {
                lastSent[deviceId] = status.withoutProgress()
                if (status.progress != null) lastProgressAt[deviceId] = now
                true
            } else {
                false
            }
        }
        if (shouldSend) pairing.sendUpdateStatus(deviceId, status)
    }

    // MARK: The run

    private fun startTicker() {
        if (ticker?.isActive == true) return
        ticker = scope.launch {
            while (true) {
                delay(TICK_MILLIS)
                machine.tick()
                publish()
                val run = machine.run
                if (run == null || run.finished) break
            }
        }
    }

    private fun publish() {
        val run = machine.run
        mutableState.value = UpdateAllState(run, clock())
        if (run == null) {
            preferences.edit().remove(KEY_RUN).apply()
        } else {
            preferences.edit().putString(KEY_RUN, run.toJson().toString()).apply()
        }
    }

    private inner class Effects : UpdateRunEffects {
        override fun sendStart(deviceId: String, start: UpdateStart): Boolean = pairing.sendUpdateStart(deviceId, start)
        // Posted, so the updater's state changes reach the run after the step that caused them.
        override fun prepareLocal() {
            scope.launch { updater.prepareForRun() }
        }

        override fun commitLocal() {
            scope.launch { updater.commitPrepared() }
        }

        override fun newRequestId(): String = UUID.randomUUID().toString()
    }

    companion object {
        private const val KEY_RUN = "run"
        private const val TICK_MILLIS = 1_000L
        private const val PROGRESS_INTERVAL_MILLIS = 1_000L
    }
}
