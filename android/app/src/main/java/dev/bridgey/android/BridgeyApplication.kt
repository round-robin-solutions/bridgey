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
    var isBridgeyEnabled: Boolean = false
        private set
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

    override fun onCreate() {
        super.onCreate()
        isPrimaryUser = getSystemService(UserManager::class.java).isSystemUser
        if (!isPrimaryUser) return
        val preferences = getSharedPreferences("bridgey", MODE_PRIVATE)
        val deviceId = preferences.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            preferences.edit().putString("device_id", it).apply()
        }
        val systemDeviceName = Settings.Global.getString(contentResolver, "device_name") ?: "Android device"
        settings = BridgeySettings(this, systemDeviceName)
        updater = AppUpdater(this, applicationScope)
        val deviceName = settings.state.value.deviceName
        pairing = PairingCoordinator(this, deviceId, deviceName, settings = settings)
        discovery = NsdDiscoveryService(this, LocalDiscoveryIdentity(deviceId, deviceName))
        uiPreferences = UiPreferences(this)
        activityLog = ActivityLog(File(noBackupFilesDir, ActivityLog.FILE_NAME), Executors.newSingleThreadExecutor())
        activity = ActivityRecorder(activityLog, pairing, applicationScope) { uiPreferences.showPreviews.value }.also { it.start() }
        backgroundClipboardSource = LogcatClipboardSource(
            this,
            packageName,
            hasLogPermission = { checkSelfPermission(Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED },
            onClipboardChangeDenied = ::launchBackgroundClipboardCapture,
        )
        applicationScope.launch {
            combine(discovery.peers, pairing.trustedDeviceIds, pairing.state) { peers, trustedIds, state ->
                Triple(peers, trustedIds, state)
            }.collect { (peers, trustedIds, state) ->
                if (isBridgeyEnabled && state is PairingState.Idle) {
                    peers.firstOrNull {
                        val peerId = it.deviceIdHint
                        peerId != null && peerId in trustedIds && deviceId < peerId
                    }?.let { peer ->
                        peer.host?.let { pairing.pair(it, peer.port ?: 42_458, peer.deviceNameHint) }
                    }
                } else if (state is PairingState.Connected) {
                    lastBatteryIntent?.let(::publishBattery)
                }
            }
        }
        applicationScope.launch {
            settings.state.collect { lastBatteryIntent?.let(::publishBattery) }
        }
        applicationScope.launch {
            pairing.remoteFeatures.collect { features ->
                if (features[BridgeyFeature.BATTERY] != false) lastBatteryIntent?.let(::publishBattery)
            }
        }
        registerForegroundClipboardWatcher()
        if (preferences.getBoolean(PREFERENCE_ENABLED, true)) enableBridgey()
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
        val clipboard = getSystemService(ClipboardManager::class.java)
        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return
        val text = item.coerceToText(this).toString()
        pairing.autoSendClipboard(text, clipboard.primaryClipDescription.isMarkedSensitive())
    }

    fun enableBridgey() {
        if (!isPrimaryUser) return
        getSharedPreferences("bridgey", MODE_PRIVATE).edit().putBoolean(PREFERENCE_ENABLED, true).apply()
        if (isBridgeyEnabled) return
        isBridgeyEnabled = true
        pairing.start()
        discovery.start()
        if (!batteryReceiverRegistered) {
            lastBatteryIntent = registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            batteryReceiverRegistered = true
        }
        lastBatteryIntent?.let(::publishBattery)
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
        discovery.stop()
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
