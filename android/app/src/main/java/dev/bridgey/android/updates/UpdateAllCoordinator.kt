package dev.bridgey.android.updates

import android.content.Context
import dev.bridgey.android.AppUpdater
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.R
import dev.bridgey.android.activity.ActivityKind
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
 * Update all on the phone: tells every Mac that understands it this phone's version, update state,
 * whether it updates automatically and what the person is doing; answers a Mac's updates.start
 * through [UpdateStartGate] and this phone's own updater; runs Update all from here (every connected
 * Mac first, this phone last, after a countdown); and runs it by itself with Update all devices
 * automatically ([AutoUpdateController]).
 */
class UpdateAllCoordinator(
    private val context: Context,
    private val scope: CoroutineScope,
    private val pairing: PairingCoordinator,
    private val updater: AppUpdater,
    private val settings: BridgeySettings,
    private val clock: () -> Long = System::currentTimeMillis,
    /** What the person is doing on this phone; empty when nothing. */
    private val busy: StateFlow<Set<UpdateBusy>> = MutableStateFlow(emptySet()),
    /** Reads the call signals again now (each second of a run, so a call that starts holds the restart at once). */
    private val refreshBusy: () -> Unit = {},
    /** The screen is off and the phone charges. */
    private val idle: () -> Boolean = { false },
    /** An activity stream entry: kind, device ID (null: this phone), device name, content. */
    private val record: (ActivityKind, String?, String, String?) -> Unit = { _, _, _, _ -> },
    private val notifier: AutoUpdateNotifier? = null,
) : UpdatesPeerHost {
    private val gate = UpdateStartGate(clock)
    private val preferences = context.getSharedPreferences("bridgey.updates.run", Context.MODE_PRIVATE)
    private val machine: UpdateRunMachine
    private val mutableState = MutableStateFlow(UpdateAllState(now = clock()))
    val state: StateFlow<UpdateAllState> = mutableState.asStateFlow()
    private var ticker: Job? = null
    private var heartbeat: Job? = null

    /** The status last sent to each device, without its progress, and when progress last went. */
    private val lastSent = mutableMapOf<String, UpdateStatus>()
    private val lastProgressAt = mutableMapOf<String, Long>()

    private val localName: String get() = context.getString(R.string.update_all_this_phone)

    private val store = object : AutoStore {
        override fun read(key: String): String? = preferences.getString(key, null)
        override fun write(key: String, value: String?) {
            preferences.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
        }
    }
    private val controller = AutoUpdateController(clock, store, AutoEffects())
    private val mutableAuto = MutableStateFlow(AutoUpdateView())

    /** Update all devices automatically, as Settings > Updates draws it. */
    val auto: StateFlow<AutoUpdateView> = mutableAuto.asStateFlow()

    /** Who was busy at the last look during a run (null: nobody), for "Waiting: … on Work Mac". */
    @Volatile private var runBusy: Pair<UpdateBusy, String?>? = null

    /** The run whose end was handled, so it is handled once. */
    @Volatile private var endedRunId: String? = null

    init {
        updater.automatic = ::autoEnabled
        val saved = preferences.getString(KEY_RUN, null)?.let { text ->
            runCatching { JSONObject(text) }.getOrNull()?.let {
                restoreUpdateRun(it, updater.installedVersionName, updater.installedVersionCode, clock())
            }
        }
        machine = UpdateRunMachine(clock, Effects(), saved)
        if (saved == null) preferences.edit().remove(KEY_RUN).apply()
        controller.settleMarker(updater.installedVersionCode, updater.installedVersionName, localName)
        saved?.let { controller.restored(it, updater.installedVersionCode, updater.installedVersionName, localName) }
        publish()
    }

    /** What Update all would do now, and every device's row. Recomputed as devices connect and report and as this phone's updater moves. */
    val overview: StateFlow<UpdateOverview> = combine(pairing.connections, pairing.trustedDevices, updater.state, settings.state) { _, _, _, _ -> currentOverview() }
        .stateIn(scope, SharingStarted.Eagerly, currentOverview())

    fun start() {
        scope.launch {
            // This phone's status goes to every Mac that understands it whenever it changes: the
            // updater, the remote start and automatic switches, the channel, and what the person is doing.
            val switches = settings.state.map { it.updatesRemoteStart to it.updatesAutoAll }.distinctUntilChanged()
            combine(updater.state, switches, busy) { _, _, _ -> localStatus() }
                .collect { status ->
                    broadcast(status)
                    machine.onLocalStatus(status)
                    lookBusy()
                    publish()
                    evaluate()
                }
        }
        if (machine.run?.finished == false) startTicker()
    }

    fun currentPlan(): UpdatePlan = currentOverview().plan

    private fun planPeers(): List<PeerUpdateInfo> {
        val connections = pairing.connections.value.associateBy { it.deviceId }
        val trusted = pairing.trustedDevices.value
        val ids = (trusted.map { it.id } + connections.keys).distinct()
        return ids.map { id ->
            val connection = connections[id]
            PeerUpdateInfo(
                deviceId = id,
                name = trusted.firstOrNull { it.id == id }?.name ?: connection?.peerName.orEmpty(),
                connected = connection != null,
                supportsUpdates = connection?.state?.remoteUpdates == true,
                status = connection?.state?.updateStatus,
            )
        }
    }

    private fun currentOverview(): UpdateOverview {
        val peers = planPeers()
        val local = localStatus()
        return UpdateOverview(planUpdateAll(local, localName, peers, clock()), deviceUpdateRows(local, localName, peers))
    }

    /** Update all: every connected Mac that will update starts now; this phone installs last. */
    fun runUpdateAll() {
        if (machine.run?.finished == false) return
        val plan = currentPlan()
        if (plan.targets.isEmpty()) return
        machine.start(plan, UUID.randomUUID().toString())
        lookBusy()
        publish()
        startTicker()
    }

    fun retry(deviceId: String) {
        machine.retry(deviceId)
        publish()
        startTicker()
    }

    /**
     * Later during this phone's countdown (or while it waits for someone): the update waits, verified,
     * for Install in Settings > Updates. In an automatic run it also puts the automatic update off for
     * an hour, and after three Laters until the phone is idle.
     */
    fun later() {
        val run = machine.run ?: return
        // With the setting on, Later in any run puts the automatic update of this build off too.
        if (!run.finished && autoEnabled()) controller.later(AutoUpdatePolicy.target(autoFacts()))
        machine.later()
        updater.laterAfterRun()
        publish()
        evaluate()
    }

    fun dismiss() {
        machine.dismiss()
        publish()
    }

    /**
     * The screen came on or off, or the network changed: checks the channel when one is due
     * (automatic updates on, rate limited), and looks again (idle may have changed).
     */
    fun deviceEvent(event: String) {
        scope.launch {
            if (event == EVENT_SCREEN_ON || event == EVENT_NETWORK) updater.checkOnEvent()
            evaluate()
        }
    }

    /** Charging started or stopped. */
    fun idleChanged() {
        scope.launch { evaluate() }
    }

    // MARK: Update all devices automatically

    /** The setting: the person's choice, or the channel's default. */
    private fun autoSetting(): Boolean = AutoUpdateRules.enabled(settings.state.value.updatesAutoAll, wireChannel())

    /** The setting is on and this build's updater can run. */
    private fun autoEnabled(): Boolean = updater.canUpdate && autoSetting()

    private fun wireChannel(): WireChannel = WireChannel.fromWire(updater.state.value.channel.key) ?: WireChannel.STABLE

    private fun localBusy(): UpdateBusy? = UpdateBusy.mostImportant(busy.value)

    /** This phone's updates.status. */
    private fun localStatus(): UpdateStatus = updater.wireStatus(settings.state.value.updatesRemoteStart, autoEnabled(), localBusy())

    private fun peerName(deviceId: String): String =
        pairing.trustedDevices.value.firstOrNull { it.id == deviceId }?.name
            ?: pairing.connections.value.firstOrNull { it.deviceId == deviceId }?.peerName
            ?: deviceId

    /** Connected devices that support Update all and have sent their status. */
    private fun autoPeers(): List<AutoPeer> = pairing.connections.value.mapNotNull { connection ->
        val status = connection.state.updateStatus?.takeIf { connection.state.remoteUpdates } ?: return@mapNotNull null
        AutoPeer(connection.deviceId, peerName(connection.deviceId), status)
    }

    private fun autoFacts(): AutoFacts {
        val now = clock()
        val local = localStatus()
        return AutoFacts(
            now = now,
            enabled = autoEnabled(),
            localId = pairing.deviceId,
            localName = localName,
            local = local,
            localBusy = localBusy(),
            peers = autoPeers(),
            runActive = machine.run?.finished == false,
            updatingForPeer = updatingForPeer(local, now),
            idle = runCatching(idle).getOrDefault(false),
        )
    }

    /** Another device's start was accepted a short while ago and this phone's updater is still on it. */
    private fun updatingForPeer(local: UpdateStatus, now: Long): Boolean {
        val at = controller.peerStartAt ?: return false
        return now >= at && now - at < AUTO_PEER_REQUEST_MILLIS && local.state in UPDATING_STATES
    }

    /** Looks again: maybe starts the automatic run. Main thread. */
    private fun evaluate() {
        controller.evaluate(autoFacts())
        refreshAuto()
        if (controller.pending) startHeartbeat()
    }

    /** While the automatic update waits (someone busy, Later, a yield), look again every minute. */
    private fun startHeartbeat() {
        if (heartbeat?.isActive == true) return
        heartbeat = scope.launch {
            while (true) {
                delay(HEARTBEAT_MILLIS)
                evaluate()
                if (!controller.pending) break
            }
        }
    }

    /** During a run: who is busy on any device holds this phone's restart. */
    private fun lookBusy() {
        val run = machine.run?.takeIf { !it.finished } ?: return
        val facts = autoFacts()
        val who = AutoUpdatePolicy.busy(facts)
        runBusy = who
        machine.busy(who?.first)
        controller.runLook(machine.run ?: run, who, facts.peers, localName)
    }

    private fun refreshAuto() {
        val enabled = autoEnabled()
        mutableAuto.value = AutoUpdateView(
            supported = updater.canUpdate,
            on = autoSetting(),
            channel = wireChannel(),
            condition = if (enabled) autoCondition(controller.decision, machine.run, runBusy, clock()) else null,
            lastRun = controller.lastRun,
        )
    }

    private inner class AutoEffects : AutoUpdateController.Effects {
        override fun startRun(refreshBefore: Long): UpdatePlan? {
            if (machine.run?.finished == false) return null
            val plan = planUpdateAll(localStatus(), localName, planPeers(), clock(), refreshBefore)
            if (plan.targets.isEmpty() || !plan.visible) return null
            machine.start(plan, UUID.randomUUID().toString(), auto = true)
            publish()
            startTicker()
            // The updater may already hold this build, verified: its state does not change, so the run hears it now.
            scope.launch {
                machine.onLocalStatus(localStatus())
                publish()
            }
            return plan
        }

        override fun record(kind: ActivityKind, deviceId: String?, deviceName: String, content: String?) {
            this@UpdateAllCoordinator.record(kind, deviceId, deviceName, content)
        }
    }

    // MARK: UpdatesPeerHost

    override fun peerReady(deviceId: String) {
        val status = localStatus()
        synchronized(lastSent) { lastSent.remove(deviceId) }
        send(deviceId, status, force = true)
    }

    override fun statusReceived(deviceId: String, status: UpdateStatus) {
        machine.onStatus(deviceId, status)
        publish()
        scope.launch {
            lookBusy()
            publish()
            evaluate()
        }
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
                personBusy = localBusy(),
            ),
        )
    }

    override fun startAccepted(deviceId: String, start: UpdateStart) {
        scope.launch {
            val name = peerName(deviceId)
            controller.peerStartAccepted(deviceId, name, start, updater.installedVersionCode)
            if (start.auto) notifier?.startedBy(name)
            // This phone's own run is going: it installs this phone's update last, after its countdown.
            if (machine.run?.finished == false) return@launch
            updater.startFromPeer(start.retry)
        }
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
        scope.launch { evaluate() }
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
                refreshBusy()
                lookBusy()
                machine.tick()
                publish()
                val run = machine.run
                if (run == null || run.finished) break
            }
        }
    }

    private fun publish() {
        val run = machine.run
        val now = clock()
        mutableState.value = UpdateAllState(run, now)
        if (run == null) {
            preferences.edit().remove(KEY_RUN).apply()
        } else {
            preferences.edit().putString(KEY_RUN, run.toJson().toString()).apply()
        }
        notifier?.show(AutoNotice.of(run, now))
        if (run != null && run.finished && endedRunId != run.id) {
            endedRunId = run.id
            controller.runEnded(run, AutoUpdatePolicy.target(autoFacts()))
            // A run ended: the automatic update looks again (Later, a retry, or a newer build).
            scope.launch { evaluate() }
        }
        refreshAuto()
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

        /** While the automatic update waits, it looks again this often. */
        private const val HEARTBEAT_MILLIS = 60_000L

        /** This phone's updater is working on another device's start. */
        private val UPDATING_STATES = setOf(
            UpdateState.CHECKING, UpdateState.AVAILABLE, UpdateState.DOWNLOADING, UpdateState.READY, UpdateState.INSTALLING, UpdateState.NEEDS_USER,
        )

        const val EVENT_SCREEN_ON = "screen_on"
        const val EVENT_SCREEN_OFF = "screen_off"
        const val EVENT_NETWORK = "network"
    }
}
