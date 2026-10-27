package dev.bridgey.android

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Bundle
import android.os.UserManager
import android.provider.Settings
import dev.bridgey.android.activity.ActivityLog
import dev.bridgey.android.activity.ActivityRecorder
import dev.bridgey.android.remote.RemoteInputController
import dev.bridgey.android.remote.RemoteInputPreferences
import dev.bridgey.android.remote.RemoteInputTransport
import dev.bridgey.android.remote.RemoteShortcuts
import dev.bridgey.android.remote.remoteShortcutTargets
import dev.bridgey.android.ui.UiPreferences
import dev.bridgey.core.discovery.LocalDiscoveryIdentity
import dev.bridgey.core.discovery.NsdDiscoveryService
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch

class BridgeyApplication : Application() {
    var isPrimaryUser: Boolean = true
        private set
    lateinit var pairing: PairingCoordinator
        private set
    lateinit var discovery: NsdDiscoveryService
        private set
    lateinit var settings: BridgeySettings
        private set
    lateinit var updater: AppUpdater
        private set
    lateinit var activityLog: ActivityLog
        private set
    lateinit var activity: ActivityRecorder
        private set
    lateinit var uiPreferences: UiPreferences
        private set
    lateinit var backgroundClipboardSource: ClipboardChangeSource
        private set

    /** Remote control of a Mac (draft remote_input_draft1). */
    lateinit var remoteInput: RemoteInputController
        private set
    lateinit var remotePreferences: RemoteInputPreferences
        private set

    /** Codes from messages: whether Android shows Bridgey the text of code SMS (companion link). */
    lateinit var codeAccess: dev.bridgey.android.codes.CodeAccessMonitor
        private set
    var isBridgeyEnabled: Boolean = false
        private set
    private lateinit var networkWatcher: NetworkWatcher
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    // Automatic clipboard, phone to Mac: while any Bridgey activity is in the foreground we may read
    // the clipboard (Android 10+ forbids it in the background), so a foreground clip change is sent
    // automatically. The coordinator applies the skip rules, de-duplication and loop prevention.
    private var startedActivityCount = 0
    private var clipListenerRegistered = false
    private val clipboardChangeListener = ClipboardManager.OnPrimaryClipChangedListener { readAndAutoSendClipboard() }
    private var lastBatteryIntent: Intent? = null
    private var batteryReceiverRegistered = false
    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent ?: return
            lastBatteryIntent = intent
            publishBattery(intent)
        }
    }

    /** Focus sync: Android's Do Not Disturb changed. */
    private val interruptionFilterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == android.app.NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED) pairing.interruptionFilterChanged()
        }
    }
    private var interruptionFilterReceiverRegistered = false

    override fun onCreate() {
        super.onCreate()
        isPrimaryUser = getSystemService(UserManager::class.java).isSystemUser
        if (!isPrimaryUser) return
        val preferences = getSharedPreferences("bridgey", MODE_PRIVATE)
        // Before the device ID is written: an install that ran before keeps its feature defaults.
        val defaultsGeneration = dev.bridgey.android.setup.DefaultsGeneration.settle(this, priorInstall = preferences.contains("device_id"))
        val deviceId = preferences.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            preferences.edit().putString("device_id", it).apply()
        }
        val systemDeviceName = Settings.Global.getString(contentResolver, "device_name") ?: "Android device"
        settings = BridgeySettings(this, systemDeviceName, defaultsGeneration)
        updater = AppUpdater(this, applicationScope)
        val deviceName = settings.state.value.deviceName
        pairing = PairingCoordinator(this, deviceId, deviceName, settings = settings)
        // Files 2.0: photos and videos, and recent documents over the granted places, for the attach sheet and the Mac.
        pairing.mediaLibrary = dev.bridgey.android.browse.MediaStoreLibrary(this)
        val documentIndex = dev.bridgey.android.browse.TreeDocumentIndex.create(this, pairing.placesStore)
        pairing.documentIndex = documentIndex
        applicationScope.launch {
            kotlinx.coroutines.flow.combine(pairing.placesStore.places, pairing.placesStore.defaultTree) { places, tree -> places to tree }
                .drop(1)
                .collect { documentIndex.placesChanged() }
        }
        discovery = NsdDiscoveryService(this, LocalDiscoveryIdentity(deviceId, deviceName))
        uiPreferences = UiPreferences(this)
        activityLog = ActivityLog(File(noBackupFilesDir, ActivityLog.FILE_NAME), Executors.newSingleThreadExecutor())
        activity = ActivityRecorder(activityLog, pairing, applicationScope) { uiPreferences.showPreviews.value }.also { it.start() }
        startSettingsSync()
        backgroundClipboardSource = LogcatClipboardSource(
            this,
            packageName,
            hasLogPermission = { checkSelfPermission(Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED },
            onClipboardChangeDenied = ::launchBackgroundClipboardCapture,
        )
        // Reconnects: NSD sightings, network, Doze and screen events go to the coordinator, which
        // keeps dialling every trusted device that is not connected at its known addresses.
        networkWatcher = NetworkWatcher(this, onRecoveryEvent = pairing::linkEvent, onObservation = pairing::observe)
        pairing.restartDiscovery = discovery::restart
        pairing.localNetworks = networkWatcher::localNetworks
        discovery.onEvent = pairing::discoveryEvent
        applicationScope.launch {
            discovery.peers.collect { peers -> if (isBridgeyEnabled) pairing.discoveryChanged(peers) }
        }
        applicationScope.launch {
            // A newly connected device gets the battery straight away.
            pairing.connections.map { list -> list.map { it.deviceId }.toSet() }.distinctUntilChanged().collect { ids ->
                if (ids.isNotEmpty()) lastBatteryIntent?.let(::publishBattery)
            }
        }
        applicationScope.launch {
            settings.state.collect { lastBatteryIntent?.let(::publishBattery) }
        }
        applicationScope.launch {
            pairing.connections.map { list -> list.map { it.state.remoteFeatures[BridgeyFeature.BATTERY] } }.distinctUntilChanged().collect {
                lastBatteryIntent?.let(::publishBattery)
            }
        }
        applicationScope.launch {
            // Home-screen widgets redraw when a Mac connects, drops or sends its list (at most twice a second).
            @OptIn(kotlinx.coroutines.FlowPreview::class)
            dev.bridgey.android.controls.controlChanges(this@BridgeyApplication)
                .debounce(500)
                .collect {
                    if (dev.bridgey.android.widget.hasWidgets(this@BridgeyApplication)) {
                        runCatching { dev.bridgey.android.widget.MacWidget.refresh(this@BridgeyApplication) }
                    }
                }
        }
        startRemoteInput()
        startCodeAccess()
        startCamera()
        registerForegroundClipboardWatcher()
        if (preferences.getBoolean(PREFERENCE_ENABLED, true)) enableBridgey()
    }

    /**
     * Settings sync (settings_sync_draft1): this phone's settings and feature switches, kept the same as on the Macs
     * that sync. Every change a Mac makes here is an activity item; a feature it turns on also posts a notification.
     */
    private fun startSettingsSync() {
        val sync = pairing.settingsSync
        sync.attach(dev.bridgey.android.sync.phoneSyncedSettings(settings, uiPreferences, dev.bridgey.android.sync.AndroidSyncPermissions(this)))
        sync.onSynced = { deviceId, deviceName, changes ->
            activityLog.record(
                dev.bridgey.android.activity.ActivityKind.SETTINGS_SYNCED, deviceId, deviceName,
                detail = dev.bridgey.android.sync.SyncDetail.encode(changes),
            )
        }
        sync.onTurnedOn = { _, deviceName, key, waiting -> dev.bridgey.android.sync.SyncNotifier.turnedOn(this, deviceName, key, waiting) }
        applicationScope.launch {
            // Any synced setting changed here (Settings, setup, shortcuts, a Mac's change being applied): the
            // controller stamps only what differs from its record, so applied changes are never sent back.
            combine(settings.state, uiPreferences.reduceMotion, uiPreferences.showPreviews) { _, _, _ -> }.collect { sync.localChanged() }
        }
    }

    /** The app came to the front: a permission may have changed, so the Macs hear the new waiting list. */
    fun syncPermissionsChanged() {
        if (::pairing.isInitialized) pairing.settingsSync.permissionsChanged()
    }

    private fun startRemoteInput() {
        remotePreferences = RemoteInputPreferences(this)
        remoteInput = RemoteInputController(
            applicationScope,
            object : RemoteInputTransport {
                override fun send(deviceId: String, kind: String, payload: ByteArray) = pairing.sendRemoteInput(deviceId, kind, payload)
                override fun isAvailable(deviceId: String) = pairing.isFeatureAvailable(BridgeyFeature.REMOTE_INPUT, deviceId)
            },
            clock = android.os.SystemClock::elapsedRealtime,
        )
        pairing.remoteInputListener = remoteInput::onHostMessage
        applicationScope.launch {
            // Settings > Privacy > Logging > Remote control sessions: start and end only, never input.
            remoteInput.state.collect { state ->
                when (state) {
                    is dev.bridgey.android.remote.RemoteSessionState.Active ->
                        pairing.recordRemoteControlEvent("session_active", state.deviceId, state.mode.wire)
                    is dev.bridgey.android.remote.RemoteSessionState.Ended ->
                        pairing.recordRemoteControlEvent("session_ended", state.deviceId, state.reason.wire)
                    else -> Unit
                }
            }
        }
        val shortcuts = RemoteShortcuts(this)
        applicationScope.launch {
            // A session ends when its Mac disconnects or stops allowing it; the launcher's
            // Remote control quick action follows the same rule.
            combine(pairing.connections, settings.state) { connections, _ -> connections }.collect { connections ->
                remoteInput.connectionsChanged(connections.mapTo(HashSet()) { it.deviceId })
                shortcuts.publish(remoteShortcutTargets(connections) { settings.isEnabled(BridgeyFeature.REMOTE_INPUT, it) })
            }
        }
    }

    /**
     * Phone camera to Mac: a locked phone says "Unlock your phone to take the photo"; with Bridgey
     * in front the camera opens at once; otherwise a notification waits for a tap (Android does not
     * let an app open a screen from the background, and a person must take the photo anyway).
     */
    private fun startCamera() {
        pairing.cameraRequested = { request ->
            val locked = getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked
            when (dev.bridgey.android.camera.cameraRoute(locked, startedActivityCount > 0)) {
                dev.bridgey.android.camera.CameraRoute.LOCKED_NOTIFICATION -> {
                    pairing.sendCameraStatus(request.deviceId, request.requestId, dev.bridgey.android.camera.CameraStatus.LOCKED)
                    dev.bridgey.android.camera.CameraNotifier.showLocked(this, request)
                }
                dev.bridgey.android.camera.CameraRoute.OPEN_NOW ->
                    runCatching { startActivity(dev.bridgey.android.camera.CameraActivity.intent(this, request)) }
                        .onFailure { dev.bridgey.android.camera.CameraNotifier.showAsk(this, request) }
                dev.bridgey.android.camera.CameraRoute.NOTIFICATION -> dev.bridgey.android.camera.CameraNotifier.showAsk(this, request)
            }
        }
        pairing.cameraEnded = { request -> dev.bridgey.android.camera.CameraNotifier.dismiss(this, request.deviceId) }
    }

    private fun startCodeAccess() {
        codeAccess = dev.bridgey.android.codes.CodeAccessMonitor(this)
        pairing.codeAccessStatus = { codeAccess.status.value }
        pairing.codeLinkRequested = { deviceId, name -> dev.bridgey.android.codes.CodeLinkNotifier.show(this, deviceId, name) }
        applicationScope.launch {
            // Every Mac that reads codes hears when Android starts or stops hiding them.
            codeAccess.status.drop(1).collect { pairing.sendCodeStatus() }
        }
    }

    private fun registerForegroundClipboardWatcher() {
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                if (startedActivityCount++ == 0 && !clipListenerRegistered) {
                    getSystemService(ClipboardManager::class.java).addPrimaryClipChangedListener(clipboardChangeListener)
                    clipListenerRegistered = true
                }
            }

            override fun onActivityStopped(activity: Activity) {
                startedActivityCount = (startedActivityCount - 1).coerceAtLeast(0)
                if (startedActivityCount == 0 && clipListenerRegistered) {
                    getSystemService(ClipboardManager::class.java).removePrimaryClipChangedListener(clipboardChangeListener)
                    clipListenerRegistered = false
                }
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    /**
     * Optional background clipboard: a transparent, excluded-from-recents activity reads the
     * clipboard once it has window focus and auto-sends it. Starting it from the background needs
     * SYSTEM_ALERT_WINDOW, which the one-time ADB setup grants.
     */
    private fun launchBackgroundClipboardCapture() {
        val intent = Intent(this, ClipboardCaptureActivity::class.java)
            .putExtra(ClipboardCaptureActivity.EXTRA_AUTOMATIC, true)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
                    Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION,
            )
        runCatching { startActivity(intent) }
    }

    /** Reads the current clipboard (allowed while foreground) and offers it to automatic clipboard. */
    private fun readAndAutoSendClipboard() {
        if (!isBridgeyEnabled) return
        if (pairing.state.value !is PairingState.Connected) return
        if (!settings.state.value.autoClipboardGlobal) return
        pairing.autoSendClip(pairing.readClipForAutomaticSend())
    }

    fun enableBridgey() {
        if (!isPrimaryUser) return
        getSharedPreferences("bridgey", MODE_PRIVATE).edit().putBoolean(PREFERENCE_ENABLED, true).apply()
        if (isBridgeyEnabled) return
        isBridgeyEnabled = true
        networkWatcher.start()
        pairing.start()
        discovery.start()
        if (!batteryReceiverRegistered) {
            lastBatteryIntent = registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            batteryReceiverRegistered = true
        }
        lastBatteryIntent?.let(::publishBattery)
        if (!interruptionFilterReceiverRegistered) {
            val filter = IntentFilter(android.app.NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            if (android.os.Build.VERSION.SDK_INT >= 33) registerReceiver(interruptionFilterReceiver, filter, RECEIVER_NOT_EXPORTED)
            else registerReceiver(interruptionFilterReceiver, filter)
            interruptionFilterReceiverRegistered = true
        }
    }

    fun disableBridgey() {
        if (!isPrimaryUser) return
        getSharedPreferences("bridgey", MODE_PRIVATE).edit().putBoolean(PREFERENCE_ENABLED, false).commit()
        if (!isBridgeyEnabled) return
        isBridgeyEnabled = false
        if (batteryReceiverRegistered) {
            runCatching { unregisterReceiver(batteryReceiver) }
            batteryReceiverRegistered = false
        }
        if (interruptionFilterReceiverRegistered) {
            runCatching { unregisterReceiver(interruptionFilterReceiver) }
            interruptionFilterReceiverRegistered = false
        }
        discovery.stop()
        remoteInput.stop()
        networkWatcher.stop()
        pairing.pause()
    }

    fun updateDeviceName(value: String) {
        settings.setDeviceName(value)
        val name = settings.state.value.deviceName
        pairing.updateDeviceName(name)
        discovery.updateDeviceName(name)
    }

    private fun publishBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        if (level < 0 || scale <= 0) return
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN)
        val percent = (level * 100 / scale).coerceIn(0, 100)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        pairing.sendBattery(percent, charging)
    }

    companion object {
        private const val PREFERENCE_ENABLED = "bridgey_enabled"
    }
}
