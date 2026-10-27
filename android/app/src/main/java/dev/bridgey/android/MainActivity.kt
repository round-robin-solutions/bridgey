package dev.bridgey.android

import android.Manifest
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityLog
import dev.bridgey.android.ui.DeviceActions
import dev.bridgey.android.ui.DeviceGlyph
import dev.bridgey.android.ui.DeviceRing
import dev.bridgey.android.ui.DeviceScreen
import dev.bridgey.android.ui.DeviceState
import dev.bridgey.android.ui.DevicesSettingsActions
import dev.bridgey.android.ui.DevicesSettingsScreen
import dev.bridgey.android.ui.DevicesSettingsState
import dev.bridgey.android.ui.HomeActions
import dev.bridgey.android.ui.HomeScreen
import dev.bridgey.android.ui.HomeState
import dev.bridgey.android.ui.LiveActions
import dev.bridgey.android.ui.LiveCard
import dev.bridgey.android.ui.lastSeenText
import dev.bridgey.android.ui.LocalShowPreviews
import dev.bridgey.android.ui.MotionNavHost
import dev.bridgey.android.ui.NotificationAppsScreen
import dev.bridgey.android.ui.NotificationAppsState
import dev.bridgey.android.ui.PermissionRow
import dev.bridgey.android.ui.RemoteRoute
import dev.bridgey.android.remote.RemoteInputController
import dev.bridgey.android.remote.RemoteInputPreferences
import dev.bridgey.android.remote.RemoteShortcuts
import dev.bridgey.android.remote.VolumeKeyRouter
import dev.bridgey.android.ui.RingState
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsActions
import dev.bridgey.android.ui.CodeTestActions
import dev.bridgey.android.ui.CodeTestScreen
import dev.bridgey.android.ui.CodesSettingsActions
import dev.bridgey.android.ui.CodesSettingsState
import dev.bridgey.android.ui.FocusSettingsActions
import dev.bridgey.android.ui.FocusSettingsState
import dev.bridgey.android.ui.PerfTestActions
import dev.bridgey.android.ui.PerfTestScreen
import dev.bridgey.android.bench.AndroidBenchProbe
import dev.bridgey.android.bench.BenchService
import dev.bridgey.android.bench.BenchState
import dev.bridgey.android.ui.SettingsScreen
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.SettingsState
import dev.bridgey.android.ui.SettingsDeepLink
import dev.bridgey.android.ui.settingsRoute
import dev.bridgey.android.ui.UiPreferences
import dev.bridgey.android.ui.deviceIcon
import dev.bridgey.android.ui.deviceRings
import dev.bridgey.android.ui.liveTransfers
import dev.bridgey.android.ui.showsCancelAll
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.rememberAnimatorScale
import dev.bridgey.android.ui.motion.resolveMotion
import dev.bridgey.android.ui.notificationAppCounts
import dev.bridgey.android.ui.rememberBackStack
import dev.bridgey.android.ui.sendTarget
import dev.bridgey.android.ui.style
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.ScreenBackdrop
import dev.bridgey.core.discovery.DiscoveredPeer
import dev.bridgey.core.discovery.NsdDiscoveryService
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.merge

private enum class PermissionPrompt {
    BridgeyNotifications,
    NotificationForwarding,
    DirectCalls,
}

private data class SharedContent(
    val text: String? = null,
    val files: List<Uri> = emptyList(),
)

/** Codes from messages: what the activity hands the UI (the link, code access, the Code reader test). */
private class CodesHooks(
    val linker: dev.bridgey.android.codes.CompanionLinker,
    val access: dev.bridgey.android.codes.CodeAccessMonitor,
    /** A Mac asked for the link (its notification was tapped); empty means any Mac. */
    val linkRequest: String?,
    val onLinkRequestHandled: () -> Unit,
    val smsDenied: Boolean,
    val smsGranted: Boolean,
    val startTest: (Int, Boolean) -> Unit,
    val stopTest: () -> Unit,
    val restart: () -> Unit,
    val openAppSettings: () -> Unit,
    /** The link picker's choice (empty: none). */
    val pickedTarget: String?,
    val pickTarget: (String) -> Unit,
    val linkRecord: dev.bridgey.android.codes.CodeLinkRecord,
)

class MainActivity : ComponentActivity() {
    private lateinit var discovery: NsdDiscoveryService
    private lateinit var pairing: PairingCoordinator
    private lateinit var bridgeySettings: BridgeySettings
    private var notificationAccessEnabled by mutableStateOf(false)
    private var appNotificationsEnabled by mutableStateOf(false)
    private var readLogsGranted by mutableStateOf(false)
    /** A folder question notification was tapped: show that question's sheet. */
    private var folderQuestion by mutableStateOf<String?>(null)
    private var batteryExempt by mutableStateOf(true)
    /** Focus sync: Android lets Bridgey change Do Not Disturb. */
    private var dndAccess by mutableStateOf(false)
    private var sharedContent by mutableStateOf<SharedContent?>(null)
    /** The launcher's Remote control quick action asked for this Mac. */
    private var remoteTarget by mutableStateOf<String?>(null)
    /** A notification asked for a Settings page (a [SettingsSection] name), e.g. Updates. */
    private var settingsTarget by mutableStateOf<String?>(null)
    private var showOnboarding by mutableStateOf(false)
    /** v0.10 setup, Permissions, Reset and What's new. */
    private lateinit var setupHooks: SetupHooks
    /** Codes from messages: the Mac chosen in the link picker. */
    private var pickedLinkTarget by mutableStateOf<String?>(null)
    private val notificationPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        refreshPermissionState()
    }
    /** Photo access for Settings > Clipboard > Send a fresh screenshot. */
    private val screenshotAccess = ScreenshotAccessController(this) { bridgeySettings }
    private val callPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        bridgeySettings.setDirectCallsEnabled(hasCallIntegrationPermissions())
        BridgeyNotificationListenerService.callPermissionsChanged()
    }

    /** Codes from messages: "Link this phone to the Mac" (a companion link), from Settings or the Mac's request. */
    private val companionLinker = dev.bridgey.android.codes.CompanionLinker(
        this,
        transport = { codeLinkTransport() },
        onLinked = ::companionLinked,
    )
    /** The Mac's link request notification was tapped: link with that Mac. */
    private var linkRequest by mutableStateOf<String?>(null)
    /** Code reader test (lab builds): READ_SMS is asked for only when Start is pressed. */
    private var pendingCodeTest: Pair<Int, Boolean>? = null
    private var smsDenied by mutableStateOf(false)
    private var smsGranted by mutableStateOf(false)
    private val smsPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        smsGranted = granted
        smsDenied = !granted
        val pending = pendingCodeTest
        pendingCodeTest = null
        if (granted && pending != null) startCodeTest(pending.first, pending.second)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // The top of every screen is midnight (dark mode, or the light mode band): light status bar icons.
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        val bridgey = application as BridgeyApplication
        if (!bridgey.isPrimaryUser) {
            setContent { BridgeyTheme { UnsupportedProfile() } }
            return
        }
        bridgey.enableBridgey()
        // Pre-v0.10 onboarding flag: people who finished it skip setup and get the What's new banner.
        val oldOnboardingCompleted = getSharedPreferences("bridgey_onboarding", MODE_PRIVATE)
            .getBoolean("completed", false)
        setupHooks = SetupHooks.create(this, oldOnboardingCompleted, restart = ::restartBridgey, resetHook = bridgey::runResetHook)
        showOnboarding = setupHooks.launch.showSetup
        pairing = bridgey.pairing
        discovery = bridgey.discovery
        bridgeySettings = bridgey.settings
        sharedContent = intent.toSharedContent()
        remoteTarget = intent.toRemoteTarget()
        if (savedInstanceState == null) settingsTarget = intent.getStringExtra(SettingsDeepLink.EXTRA_SECTION)
        folderQuestion = intent.getStringExtra(FolderNotifier.EXTRA_FOLDER_QUESTION)
        linkRequest = intent.toLinkRequest()
        startForegroundService(Intent(this, BridgeyConnectionService::class.java))
        if (savedInstanceState == null) bridgey.updater.checkOnAppOpen()
        setContent {
            BridgeyTheme {
                BridgeyApp(
                    discovery = discovery,
                    pairing = pairing,
                    settings = bridgey.settings,
                    updater = bridgey.updater,
                    updateAll = bridgey.updateAll,
                    activityLog = bridgey.activityLog,
                    uiPreferences = bridgey.uiPreferences,
                    remoteInput = bridgey.remoteInput,
                    remotePreferences = bridgey.remotePreferences,
                    remoteTarget = remoteTarget,
                    onRemoteTargetHandled = ::clearRemoteTarget,
                    settingsTarget = settingsTarget,
                    onSettingsTargetHandled = { settingsTarget = null },
                    folderQuestion = folderQuestion,
                    onFolderQuestionHandled = { folderQuestion = null },
                    onDeviceNameChanged = bridgey::updateDeviceName,
                    appNotificationsEnabled = appNotificationsEnabled,
                    notificationAccessEnabled = notificationAccessEnabled,
                    readLogsGranted = readLogsGranted,
                    batteryExempt = batteryExempt,
                    dndAccess = dndAccess,
                    onOpenDndAccess = ::openDndAccessSettings,
                    onRequestBatteryExemption = ::requestBatteryExemption,
                    onOpenBatterySettings = ::openBatterySettings,
                    onTurnOff = {
                        startService(Intent(this, BridgeyConnectionService::class.java).setAction(BridgeyConnectionService.ACTION_TURN_OFF))
                        finishAndRemoveTask()
                    },
                    onRequestAppNotifications = ::requestAppNotifications,
                    onOpenAppNotificationSettings = ::openAppNotificationSettings,
                    onOpenNotificationAccessSettings = {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    },
                    onRequestDirectCalls = ::requestDirectCalls,
                    onExportDiagnostics = ::exportDiagnostics,
                    onAddTile = ::requestAddClipboardTile,
                    screenshotAccess = screenshotAccess,
                    sharedContent = sharedContent,
                    onSharedContentHandled = ::clearSharedContent,
                    codes = CodesHooks(
                        linker = companionLinker,
                        access = bridgey.codeAccess,
                        linkRequest = linkRequest,
                        onLinkRequestHandled = { linkRequest = null },
                        smsDenied = smsDenied,
                        smsGranted = smsGranted,
                        startTest = ::requestCodeTest,
                        stopTest = ::finishCodeTest,
                        restart = ::restartForPermissionRemoval,
                        openAppSettings = ::openAppDetails,
                        pickedTarget = pickedLinkTarget,
                        pickTarget = { pickedLinkTarget = it },
                        linkRecord = dev.bridgey.android.codes.CodeLinkRecord(this),
                    ),
                    setup = setupHooks,
                    showOnboarding = showOnboarding,
                    onOnboardingComplete = {
                        setupHooks.store.complete()
                        showOnboarding = false
                    },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshPermissionState()
        if (::pairing.isInitialized) (application as BridgeyApplication).codeAccess.refresh()
        screenshotAccess.onResume()
        autoSendClipboardOnResume()
    }

    /**
     * Automatic clipboard, phone to Mac: on every resume, read the clipboard (allowed while
     * foreground) and offer a fresh clip (copied within the last 10 minutes) to be sent. The
     * coordinator applies the skip rules, de-duplication and loop prevention.
     */
    private fun autoSendClipboardOnResume() {
        if (!::pairing.isInitialized || !::bridgeySettings.isInitialized) return
        if (pairing.state.value !is PairingState.Connected) return
        if (!bridgeySettings.state.value.autoClipboardGlobal) return
        val clipboard = getSystemService(ClipboardManager::class.java)
        if (clipboard.primaryClip?.takeIf { it.itemCount > 0 } == null) return
        val timestamp = clipboard.primaryClipDescription?.timestamp ?: 0L
        pairing.autoSendClipOnResume(pairing.readClipForAutomaticSend(), timestamp)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sharedContent = intent.toSharedContent()
        remoteTarget = intent.toRemoteTarget()
        intent.getStringExtra(SettingsDeepLink.EXTRA_SECTION)?.let { settingsTarget = it }
        intent.getStringExtra(FolderNotifier.EXTRA_FOLDER_QUESTION)?.let { folderQuestion = it }
        intent.toLinkRequest()?.let { linkRequest = it }
    }

    private fun Intent.toLinkRequest(): String? =
        if (action == dev.bridgey.android.codes.CodeLinkNotifier.ACTION_LINK) {
            getStringExtra(dev.bridgey.android.codes.CodeLinkNotifier.EXTRA_DEVICE_ID).orEmpty()
        } else {
            null
        }

    private fun codeLinkTransport(): dev.bridgey.android.codes.CompanionLinkTransport = object : dev.bridgey.android.codes.CompanionLinkTransport {
        override fun linkTarget(): String? {
            val requested = linkRequest?.takeIf { it.isNotEmpty() }
            val supported = pairing.connections.value.filter { it.state.remoteSmsCodes }.map { it.deviceId }
            return requested?.takeIf { it in supported } ?: pickedLinkTarget?.takeIf { it in supported } ?: pairing.companionLinkTarget()
        }

        override fun macTooOld(): Boolean = pairing.companionLinkMacTooOld()

        override fun requestAdvertising(deviceId: String, serviceUuid: java.util.UUID, onResult: (Boolean, String?) -> Unit) =
            pairing.requestCompanionAdvertising(deviceId, serviceUuid, onResult)

        override fun stopAdvertising(deviceId: String, serviceUuid: java.util.UUID, linked: Boolean) {
            // Android's association does not say which Mac it was: remember it for "Linked to ...".
            if (linked) {
                val name = pairing.connections.value.firstOrNull { it.deviceId == deviceId }?.peerName.orEmpty()
                dev.bridgey.android.codes.CodeLinkRecord(this@MainActivity).save(dev.bridgey.android.codes.CodeLinkMac(deviceId, name))
            }
            pairing.stopCompanionAdvertising(deviceId, serviceUuid, linked)
        }
    }

    /** Android trusts a listener when it connects: reconnect it, then tell the Macs. */
    private fun companionLinked() {
        val bridgey = application as BridgeyApplication
        bridgey.codeAccess.linkChanged()
        dev.bridgey.android.codes.CodeLinkNotifier.dismiss(this)
        BridgeyNotificationListenerService.rebindForTrust(this)
        pairing.sendCodeStatus()
    }

    private fun requestCodeTest(limit: Int, useCloud: Boolean) {
        if (checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
            smsGranted = true
            startCodeTest(limit, useCloud)
        } else {
            pendingCodeTest = limit to useCloud
            smsPermissionLauncher.launch(Manifest.permission.READ_SMS)
        }
    }

    private fun startCodeTest(limit: Int, useCloud: Boolean) {
        val bridgey = application as BridgeyApplication
        dev.bridgey.android.codes.CodeTestSession.start(
            this, limit, useCloud, BuildConfig.OTP_PROXY_URL, bridgey.updater.installedVersionName, bridgey.codeAccess,
        )
    }

    /** The test stopped or its run was deleted: ask Android to drop SMS access when Bridgey next restarts. */
    private fun finishCodeTest() {
        dev.bridgey.android.codes.CodeTestSession.cancel()
        releaseSmsAccess()
    }

    private fun releaseSmsAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
        ) {
            revokeSelfPermissionOnKill(Manifest.permission.READ_SMS)
        }
    }

    /** "Restart Bridgey": the revoke takes effect when the process ends; the launcher opens a fresh one. */
    private fun restartForPermissionRemoval() {
        releaseSmsAccess()
        dev.bridgey.android.codes.CodeTestSession.delete()
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        if (launch != null) startActivity(launch)
        finishAffinity()
        Runtime.getRuntime().exit(0)
    }

    /** Focus sync > Follow: Android's Do Not Disturb access page, where Bridgey RR is switched on. */
    private fun openDndAccessSettings() {
        runCatching { startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
            .onFailure { openAppDetails() }
    }

    private fun openAppDetails() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
    }

    /** While the presentation remote shows (and Settings allows it), the volume keys change slides. */
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        val handler = VolumeKeyRouter.handler
        if (handler == null || !isVolumeKey(keyCode)) return super.onKeyDown(keyCode, event)
        if (event.repeatCount == 0) handler(keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP)
        return true
    }

    override fun onKeyUp(keyCode: Int, event: android.view.KeyEvent): Boolean =
        if (VolumeKeyRouter.handler != null && isVolumeKey(keyCode)) true else super.onKeyUp(keyCode, event)

    private fun isVolumeKey(keyCode: Int) =
        keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN

    private fun Intent.toRemoteTarget(): String? =
        if (action == RemoteShortcuts.ACTION_REMOTE_CONTROL) getStringExtra(RemoteShortcuts.EXTRA_DEVICE_ID)?.takeIf { it.isNotBlank() } else null

    private fun clearRemoteTarget() {
        remoteTarget = null
        setIntent(Intent(this, MainActivity::class.java))
    }

    private fun Intent.toSharedContent(): SharedContent? {
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null

        val streams = when (action) {
            Intent.ACTION_SEND_MULTIPLE -> streamUris()
            else -> listOfNotNull(streamUri())
        }.distinct()
        val sharedText = getCharSequenceExtra(Intent.EXTRA_TEXT)
            ?.toString()
            ?.takeIf { it.isNotBlank() && streams.isEmpty() }
        return SharedContent(text = sharedText, files = streams)
            .takeIf { it.text != null || it.files.isNotEmpty() }
    }

    @Suppress("DEPRECATION")
    private fun Intent.streamUri(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun Intent.streamUris(): List<Uri> =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        } else {
            getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        }

    private fun refreshPermissionState() {
        smsGranted = checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
        appNotificationsEnabled = getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        notificationAccessEnabled = NotificationAccess.isEnabled(this)
        readLogsGranted = checkSelfPermission(Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED
        batteryExempt = PowerFacts.ignoringBatteryOptimizations(this)
        dndAccess = getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted
        if (
            ::bridgeySettings.isInitialized && bridgeySettings.state.value.directCallsEnabled &&
            !hasCallIntegrationPermissions()
        ) {
            bridgeySettings.setDirectCallsEnabled(false)
            BridgeyNotificationListenerService.callPermissionsChanged()
        }
    }

    private fun clearSharedContent() {
        sharedContent = null
        // Prevent a handled share intent from being replayed after configuration changes.
        setIntent(Intent(this, MainActivity::class.java))
    }

    private fun requestAppNotifications() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            openAppNotificationSettings()
        }
    }

    private fun requestDirectCalls() {
        if (hasCallIntegrationPermissions()) {
            bridgeySettings.setDirectCallsEnabled(true)
            BridgeyNotificationListenerService.callPermissionsChanged()
        } else {
            callPermissionLauncher.launch(CALL_INTEGRATION_PERMISSIONS)
        }
    }

    private fun hasCallIntegrationPermissions(): Boolean =
        CALL_INTEGRATION_PERMISSIONS.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun openAppNotificationSettings() {
        startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
        )
    }

    /** The system's "Let Bridgey always run in the background?" dialog. */
    @android.annotation.SuppressLint("BatteryLife")
    private fun requestBatteryExemption() {
        val request = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        runCatching { startActivity(request) }.onFailure { openBatterySettings() }
    }

    /** App info, where phones such as OnePlus keep their own battery limits too. */
    private fun openBatterySettings() {
        runCatching {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }
    }

    private fun requestAddClipboardTile() {
        if (Build.VERSION.SDK_INT < 33) return
        val statusBar = getSystemService(android.app.StatusBarManager::class.java) ?: return
        statusBar.requestAddTileService(
            android.content.ComponentName(this, ClipboardTileService::class.java),
            getString(R.string.tile_label),
            android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_bridgey_notification),
            mainExecutor,
        ) { result ->
            if (
                result == android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                result == android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
            ) {
                (application as BridgeyApplication).uiPreferences.setTileAdded(true)
            }
        }
    }

    private fun exportDiagnostics() {
        val report = pairing.diagnosticsReport()
        val diagnosticsDirectory = File(cacheDir, "diagnostics")
        val reportFile = runCatching {
            check(diagnosticsDirectory.exists() || diagnosticsDirectory.mkdirs())
            File(diagnosticsDirectory, "Bridgey-Diagnostics.json").apply {
                writeText(report, Charsets.UTF_8)
            }
        }.getOrElse {
            android.widget.Toast.makeText(this, "Could not create diagnostics file", android.widget.Toast.LENGTH_LONG).show()
            return
        }
        val reportUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            reportFile,
        )
        startActivity(Intent.createChooser(
            Intent(Intent.ACTION_SEND).apply {
                type = "application/json"
                putExtra(Intent.EXTRA_SUBJECT, "Bridgey diagnostics")
                putExtra(Intent.EXTRA_STREAM, reportUri)
                clipData = ClipData.newUri(contentResolver, "Bridgey diagnostics", reportUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
            "Export Bridgey diagnostics",
        ))
    }
}

@Composable
private fun UnsupportedProfile() = ScreenBackdrop(bandHeight = 0.dp) {
    Column(Modifier.fillMaxSize().statusBarsPadding().padding(28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Bridgey", style = MaterialTheme.typography.headlineLarge)
        Text("Already active in the main phone profile", style = MaterialTheme.typography.titleLarge)
        Text("Open Bridgey from the main profile to avoid showing this phone twice.", color = BridgeyTheme.colors.onSurfaceVariant)
    }
}

/** Status texts from the coordinator that report progress or success: the stream already shows those. */
private val QuietStatuses = setOf("Delivered", "Sending…", "Pinging Mac…", "Ping delivered", "Media command completed")

private val PermissionOrder = listOf(
    listOf(BridgeyFeature.CLIPBOARD),
    listOf(BridgeyFeature.FILES),
    listOf(BridgeyFeature.NOTIFICATIONS),
    listOf(BridgeyFeature.CALLS),
    listOf(BridgeyFeature.MEDIA),
    listOf(BridgeyFeature.REMOTE_INPUT),
    listOf(BridgeyFeature.MAC_ACTIONS),
    listOf(BridgeyFeature.CAMERA),
    listOf(BridgeyFeature.SCREEN),
    listOf(BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING),
    listOf(BridgeyFeature.LINKS),
    listOf(BridgeyFeature.BATTERY),
)

@Composable
private fun BridgeyApp(
    discovery: NsdDiscoveryService,
    pairing: PairingCoordinator,
    settings: BridgeySettings,
    updater: AppUpdater,
    updateAll: dev.bridgey.android.updates.UpdateAllCoordinator,
    activityLog: ActivityLog,
    uiPreferences: UiPreferences,
    remoteInput: RemoteInputController,
    remotePreferences: RemoteInputPreferences,
    remoteTarget: String?,
    onRemoteTargetHandled: () -> Unit,
    settingsTarget: String?,
    onSettingsTargetHandled: () -> Unit,
    folderQuestion: String?,
    onFolderQuestionHandled: () -> Unit,
    onDeviceNameChanged: (String) -> Unit,
    appNotificationsEnabled: Boolean,
    notificationAccessEnabled: Boolean,
    readLogsGranted: Boolean,
    batteryExempt: Boolean,
    dndAccess: Boolean,
    onOpenDndAccess: () -> Unit,
    onRequestBatteryExemption: () -> Unit,
    onOpenBatterySettings: () -> Unit,
    onTurnOff: () -> Unit,
    onRequestAppNotifications: () -> Unit,
    onOpenAppNotificationSettings: () -> Unit,
    onOpenNotificationAccessSettings: () -> Unit,
    onRequestDirectCalls: () -> Unit,
    onExportDiagnostics: () -> Unit,
    onAddTile: () -> Unit,
    screenshotAccess: ScreenshotAccessController,
    sharedContent: SharedContent?,
    onSharedContentHandled: () -> Unit,
    codes: CodesHooks,
    setup: SetupHooks,
    showOnboarding: Boolean,
    onOnboardingComplete: () -> Unit,
) {
    val peers by discovery.peers.collectAsStateWithLifecycle()
    val pairingState by pairing.state.collectAsStateWithLifecycle()
    val pairingFlow by pairing.pairingFlow.collectAsStateWithLifecycle()
    val connections by pairing.connections.collectAsStateWithLifecycle()
    val fileTransfers by pairing.fileTransfers.collectAsStateWithLifecycle()
    val phoneRinging by pairing.phoneRinging.collectAsStateWithLifecycle()
    val trustedDevices by pairing.trustedDevices.collectAsStateWithLifecycle()
    val receivedLink by pairing.quickActions.receivedLink.collectAsStateWithLifecycle()
    val media by pairing.quickActions.media.collectAsStateWithLifecycle()
    val macCatalogs by pairing.macActions.catalogs.collectAsStateWithLifecycle()
    val macLive by pairing.macActions.live.collectAsStateWithLifecycle()
    // Share screen with Macs: the hub lives in the application (absent in previews and tests).
    val screenHub = (LocalContext.current.applicationContext as? BridgeyApplication)?.takeIf { it.isPrimaryUser }?.screenShare
    val screenState by (screenHub?.state ?: remember { kotlinx.coroutines.flow.MutableStateFlow(dev.bridgey.android.screen.ScreenShareState()) })
        .collectAsStateWithLifecycle()
    val macRunning by pairing.macActions.running.collectAsStateWithLifecycle()
    val healthTick by pairing.health.changes.collectAsStateWithLifecycle()
    val settingsState by settings.state.collectAsStateWithLifecycle()
    val updateState by updater.state.collectAsStateWithLifecycle()
    val updateRun by updateAll.state.collectAsStateWithLifecycle()
    val updateOverview by updateAll.overview.collectAsStateWithLifecycle()
    var updateAllSheet by rememberSaveable { mutableStateOf(false) }
    val activity by activityLog.items.collectAsStateWithLifecycle()
    val reduceMotion by uiPreferences.reduceMotion.collectAsStateWithLifecycle()
    val showPreviews by uiPreferences.showPreviews.collectAsStateWithLifecycle()
    val tileAdded by uiPreferences.tileAdded.collectAsStateWithLifecycle()
    val remotePrefs by remotePreferences.state.collectAsStateWithLifecycle()
    val reconnectStates by pairing.reconnectStates.collectAsStateWithLifecycle()
    val rediscover by pairing.rediscover.collectAsStateWithLifecycle()
    val batteryPromptShown by uiPreferences.batteryPromptShown.collectAsStateWithLifecycle()
    val codeAccessStatus by codes.access.status.collectAsStateWithLifecycle()
    val companionLink by codes.linker.state.collectAsStateWithLifecycle()
    val codeTestState by dev.bridgey.android.codes.CodeTestSession.state.collectAsStateWithLifecycle()
    var permissionPrompt by remember { mutableStateOf<PermissionPrompt?>(null) }
    var pairDialog by rememberSaveable { mutableStateOf(false) }
    var forgetting by remember { mutableStateOf<DeviceRing?>(null) }
    var pickedTarget by rememberSaveable { mutableStateOf<String?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val stack = rememberBackStack(if (showOnboarding) listOf(Route.Home, Route.Setup) else listOf(Route.Home))
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current

    // Time moves on: "Now" becomes a time, Today becomes Yesterday.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        activityLog.prune()
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
        }
    }
    LaunchedEffect(activity) { now = System.currentTimeMillis() }

    // Problems reported by the coordinator (clipboard empty, not connected, ...) show once as a snackbar.
    LaunchedEffect(pairing) {
        merge(pairing.clipboardStatus.drop(1), pairing.pingStatus.drop(1), pairing.quickActions.status.drop(1), screenshotAccess.messages)
            .filterNotNull()
            .collect { status ->
                if (status !in QuietStatuses && !status.startsWith("Link delivered")) {
                    snackbar.currentSnackbarData?.dismiss()
                    snackbar.showSnackbar(status)
                }
            }
    }

    // Mac actions: refusals, timeouts and finished apps or Shortcuts show once as a snackbar.
    LaunchedEffect(pairing) {
        pairing.macActions.status.drop(1).filterNotNull().collect { status ->
            val catalog = pairing.macActions.catalogs.value[status.deviceId]
            val name = pairing.trustedDevices.value.firstOrNull { it.id == status.deviceId }?.name ?: "Mac"
            macActionMessage(context, status, catalog?.entry(status.actionId)?.title, name)?.let { message ->
                snackbar.currentSnackbarData?.dismiss()
                snackbar.showSnackbar(message)
            }
        }
    }

    val connected = pairingState as? PairingState.Connected
    val rings = remember(trustedDevices, peers, connections, pairingFlow, reconnectStates) {
        deviceRings(trustedDevices, peers, connections, pairingFlow, reconnectStates)
    }
    // "Look for devices again": "Looking for devices…", then who answered and who did not.
    LaunchedEffect(rediscover) {
        when (val result = rediscover) {
            RediscoverState.Running -> {
                snackbar.currentSnackbarData?.dismiss()
                snackbar.showSnackbar(context.getString(R.string.rediscover_looking))
            }
            is RediscoverState.Done -> {
                snackbar.currentSnackbarData?.dismiss()
                pairing.clearRediscover()
                snackbar.showSnackbar(rediscoverMessage(context, result))
            }
            null -> Unit
        }
    }
    fun reconnectCard(ring: DeviceRing?): LiveCard.Reconnecting? {
        if (ring?.canRetry != true) return null
        val retry = ring.reconnect ?: return null
        val seen = retry.lastSeenMillis?.let {
            lastSeenText(it, now, java.time.ZoneId.systemDefault(), java.util.Locale.getDefault(), android.text.format.DateFormat.is24HourFormat(context))
        }
        return LiveCard.Reconnecting(ring.deviceId!!, ring.name, seen, retry.struggling)
    }
    val target = sendTarget(rings, pickedTarget)
    // The send bar's pick is the coordinator's target for actions without an explicit device.
    LaunchedEffect(target?.deviceId) { pairing.selectDevice(target?.deviceId) }
    fun connectionOf(deviceId: String?): DeviceConnection? = connections.firstOrNull { it.deviceId == deviceId }
    fun availableWith(deviceId: String?): Set<BridgeyFeature> {
        val connection = connectionOf(deviceId) ?: return emptySet()
        return BridgeyFeature.entries.filter { settings.isEnabled(it, connection.deviceId) && connection.state.remoteFeatures[it] != false }.toSet()
    }

    val nameFor: (ActivityItem) -> String = { item ->
        rings.firstOrNull { it.deviceId != null && it.deviceId == item.deviceId }?.name
            ?: item.deviceName.ifBlank { context.getString(R.string.stream_file_unnamed) }
    }
    val linksAvailable = BridgeyFeature.LINKS in availableWith(connected?.deviceId)
    val updateAllState = dev.bridgey.android.ui.UpdateAllUiState(
        plan = updateOverview.plan,
        run = updateRun.run,
        now = updateRun.now,
        devices = updateOverview.devices,
        remoteStart = settingsState.updatesRemoteStart,
    )
    val updateAllActions = dev.bridgey.android.ui.UpdateAllActions(
        open = { updateAllSheet = true },
        start = updateAll::runUpdateAll,
        retry = updateAll::retry,
        later = updateAll::later,
        dismiss = updateAll::dismiss,
        close = { updateAllSheet = false },
        setRemoteStart = settings::setUpdatesRemoteStart,
    )
    val homeLive = buildList {
        if (updateAllState.offered) add(LiveCard.UpdateAll(updateAllState))
        reconnectCard(target)?.let(::add)
        if (phoneRinging && connected != null) add(LiveCard.Ringing(connected.peerName))
        receivedLink?.takeIf { linksAvailable && connected != null }?.let { add(LiveCard.Link(it, connected!!.peerName)) }
        val cancelAll = showsCancelAll(fileTransfers.values)
        liveTransfers(fileTransfers).forEachIndexed { index, transfer -> add(LiveCard.Transfer(transfer, cancelAll = cancelAll && index == 0)) }
    }
    val folderUi = rememberFolderUi(pairing, settings, snackbar, { stack.push(Route.Places) }, folderQuestion, onFolderQuestionHandled)
    val liveActions = LiveActions(
        cancelTransfer = pairing::cancelFileTransfer,
        cancelAllTransfers = { pairing.cancelFileTransfer() },
        retryTransfer = pairing::retryFileTransfer,
        dismissTransfers = pairing::clearTransferHistory,
        openLink = pairing.quickActions::openLink,
        dismissLink = pairing.quickActions::dismissLink,
        stopRinging = pairing::stopFinding,
        media = { action, value -> pairing.quickActions.request(BridgeyFeature.MEDIA, action, value) },
        retryDevice = pairing::retryNow,
        answerFolder = folderUi.showQuestion,
        updateAll = updateAllActions,
    )
    // Files 2.0: the in-app attach sheet is the main way to send; the system pickers are its Browse… fallback.
    val attach = rememberAttachUi(pairing, snackbar)
    val readClipboard = {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
    }

    // A device page whose device was forgotten closes.
    LaunchedEffect(rings) {
        stack.removeWhere { route ->
            (route is Route.Device && rings.none { it.deviceId == route.deviceId }) ||
                (route is Route.Remote && rings.none { it.deviceId == route.deviceId })
        }
    }

    // The Mac's "Link this phone to the Mac" notification: Settings › Notifications, where Codes
    // from messages lives, and the link starts. Back goes to the Settings home.
    LaunchedEffect(codes.linkRequest) {
        if (codes.linkRequest == null) return@LaunchedEffect
        stack.openSettings(settingsRoute(SettingsSection.NOTIFICATIONS))
        codes.linker.start()
        codes.onLinkRequestHandled()
    }

    // The Code reader test reached its report: ask Android to drop SMS access at the next restart.
    LaunchedEffect(codeTestState is dev.bridgey.android.codes.CodeTestState.Report) {
        if (codeTestState is dev.bridgey.android.codes.CodeTestState.Report && android.os.Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
        ) {
            context.revokeSelfPermissionOnKill(Manifest.permission.READ_SMS)
        }
    }

    // The launcher's Remote control quick action opens that Mac's remote.
    LaunchedEffect(remoteTarget) {
        val deviceId = remoteTarget ?: return@LaunchedEffect
        if (rings.any { it.deviceId == deviceId }) stack.push(Route.Remote(deviceId))
        onRemoteTargetHandled()
    }

    // A notification opens its Settings page, e.g. the update notification opens Updates.
    LaunchedEffect(settingsTarget) {
        val section = SettingsDeepLink.section(settingsTarget ?: return@LaunchedEffect)
        if (section != null) stack.openSettings(settingsRoute(section))
        onSettingsTargetHandled()
    }

    val onSetGlobalFeature: (BridgeyFeature, Boolean) -> Unit = { feature, enabled ->
        settings.setGlobal(feature, enabled)
        if (feature == BridgeyFeature.FIND_DEVICE && !enabled) pairing.stopFinding()
        if (feature == BridgeyFeature.CALLS && !enabled) {
            settings.setDirectCallsEnabled(false)
            BridgeyNotificationListenerService.callPermissionsChanged()
        }
    }
    val onSetDirectCalls: (Boolean) -> Unit = { enabled ->
        if (enabled) {
            permissionPrompt = PermissionPrompt.DirectCalls
        } else {
            settings.setDirectCallsEnabled(false)
            BridgeyNotificationListenerService.callPermissionsChanged()
        }
    }

    val animatorScale = rememberAnimatorScale()
    val motion = remember(animatorScale, reduceMotion) { resolveMotion(animatorScale, reduceMotion) }
    CompositionLocalProvider(LocalMotion provides motion, LocalShowPreviews provides showPreviews) {
        MotionNavHost(stack) { route ->
            when (route) {
                Route.Home -> HomeScreen(
                    state = HomeState(
                        rings = rings,
                        target = target,
                        activity = activity,
                        live = homeLive,
                        canSendClipboard = target != null && BridgeyFeature.CLIPBOARD in availableWith(target.deviceId),
                        canAttach = target != null && BridgeyFeature.FILES in availableWith(target.deviceId),
                        now = now,
                        rediscovering = rediscover == RediscoverState.Running,
                    ),
                    actions = HomeActions(
                        openSettings = { stack.push(Route.Settings) },
                        selectRing = { ring -> pickedTarget = ring.deviceId; pairing.selectDevice(ring.deviceId) },
                        openDevice = { ring -> ring.deviceId?.let { stack.push(Route.Device(it)) } },
                        pairRing = { ring -> ring.peer?.host?.let { pairing.pair(it, ring.peer.port ?: 42_458, ring.peer.deviceNameHint) } ?: run { pairDialog = true } },
                        addDevice = { pairDialog = true },
                        pickTarget = { pickedTarget = it; pairing.selectDevice(it) },
                        sendClipboard = {
                            val deviceId = target?.deviceId
                            screenshotAccess.beforeSend(pairing.clipboardOffersAvailable(deviceId)) { pairing.sendClipboard(deviceId) }
                        },
                        attach = { attach.open(target?.deviceId) },
                        lookForDevices = pairing::lookForDevices,
                        live = liveActions,
                    ),
                    snackbar = snackbar,
                    deviceName = nameFor,
                )
                is Route.Device -> {
                    val ring = rings.firstOrNull { it.deviceId == route.deviceId }
                    // A device page aims links and media at its own device.
                    LaunchedEffect(route.deviceId) {
                        pickedTarget = route.deviceId
                        pairing.selectDevice(route.deviceId)
                    }
                    if (ring != null) {
                        val connection = connectionOf(ring.deviceId)
                        val isConnected = connection != null
                        val available = availableWith(ring.deviceId)
                        val artwork = remember(media.artwork) { decodeArtwork(media.artwork) }
                        val deviceLive = if (!isConnected) listOfNotNull<LiveCard>(reconnectCard(ring)) else buildList {
                            if (BridgeyFeature.MEDIA in available) add(LiveCard.Media(media, artwork))
                            addAll(homeLive)
                        }
                        val (enabledApps, _) = notificationAppCounts(settingsState.notificationApplications, settingsState.disabledNotificationPackages)
                        DeviceScreen(
                            state = DeviceState(
                                ring = ring,
                                battery = connection?.state?.battery,
                                connected = isConnected,
                                available = available,
                                ringing = isConnected && (connection?.state?.ringing == true || phoneRinging),
                                permissions = PermissionOrder.map { features ->
                                    val deviceId = ring.deviceId!!
                                    PermissionRow(
                                        features = features,
                                        checked = features.any { settingsState.globalFeatures[it] != false && settingsState.deviceFeatures[deviceId]?.get(it) != false },
                                        globallyOff = features.all { settingsState.globalFeatures[it] == false },
                                        remotelyOff = isConnected && features.all { connection?.state?.remoteFeatures?.get(it) == false },
                                    )
                                },
                                notificationAccess = notificationAccessEnabled,
                                notificationAppsEnabled = enabledApps,
                                autoClipboard = settings.isAutoClipboardEnabled(ring.deviceId),
                                autoClipboardGlobalOn = settingsState.autoClipboardGlobal,
                                activity = activity,
                                live = deviceLive,
                                now = now,
                                macActions = ring.deviceId?.takeIf { it in macLive && BridgeyFeature.MAC_ACTIONS in available }?.let { macCatalogs[it] },
                                runningActions = macRunning.filter { it.first == ring.deviceId }.map { it.second }.toSet(),
                                health = remember(healthTick, now, ring.deviceId, isConnected) { ring.deviceId?.let(pairing::healthOf) },
                                screen = screenState.takeIf { it.deviceId == ring.deviceId },
                            ),
                            actions = DeviceActions(
                                back = { stack.pop() },
                                forget = { forgetting = ring },
                                sendFile = { attach.open(ring.deviceId) },
                                sendLink = {
                                    pairing.selectDevice(ring.deviceId)
                                    pairing.quickActions.sendLink(readClipboard())
                                },
                                ping = { pairing.sendPing(ring.deviceId) },
                                find = { pairing.findMac(ring.deviceId) },
                                stopFind = { ring.deviceId?.let(pairing::stopFinding) ?: pairing.stopFinding() },
                                setPermission = { features, enabled ->
                                    val deviceId = ring.deviceId!!
                                    features.forEach { settings.setForDevice(deviceId, it, enabled) }
                                    if (BridgeyFeature.FIND_DEVICE in features && !enabled && isConnected) pairing.stopFinding(deviceId)
                                },
                                setAutoClipboard = { enabled -> ring.deviceId?.let { settings.setAutoClipboardForDevice(it, enabled) } },
                                notificationAccess = {
                                    if (notificationAccessEnabled) onOpenNotificationAccessSettings()
                                    else permissionPrompt = PermissionPrompt.NotificationForwarding
                                },
                                sendClipboard = {
                                    screenshotAccess.beforeSend(pairing.clipboardOffersAvailable(ring.deviceId)) { pairing.sendClipboard(ring.deviceId) }
                                },
                                sendText = { pairing.sendText(it, deviceId = ring.deviceId) },
                                remoteControl = { ring.deviceId?.let { stack.push(Route.Remote(it)) } },
                                shareScreen = { ring.deviceId?.let { id -> screenHub?.ask(context, id, ring.name, null) } },
                                stopScreen = { screenHub?.stop(dev.bridgey.android.screen.ScreenStopReason.USER) },
                                runMacAction = { id, value -> ring.deviceId?.let { pairing.macActions.run(it, id, value) } },
                                live = liveActions,
                            ),
                            snackbar = snackbar,
                            deviceName = nameFor,
                        )
                    }
                }
                is Route.Remote -> RemoteRoute(
                    deviceId = route.deviceId,
                    deviceName = rings.firstOrNull { it.deviceId == route.deviceId }?.name ?: stringResource(R.string.remote_default_name),
                    controller = remoteInput,
                    preferences = remotePrefs,
                    onBack = { stack.pop() },
                )
                Route.Settings, is Route.SettingsPane, Route.Setup, Route.Permissions, Route.Reset -> {
                    val (enabledApps, totalApps) = notificationAppCounts(settingsState.notificationApplications, settingsState.disabledNotificationPackages)
                    val bridgeyApp = context.applicationContext as BridgeyApplication
                    val bgSourceStatus by bridgeyApp.backgroundClipboardSource.status.collectAsStateWithLifecycle()
                    val backgroundStatus = when {
                        !settingsState.backgroundClipboardEnabled -> BackgroundClipboardStatus.OFF
                        !readLogsGranted -> BackgroundClipboardStatus.WAITING_FOR_SETUP
                        bgSourceStatus == BackgroundClipboardStatus.DENIED -> BackgroundClipboardStatus.DENIED
                        else -> BackgroundClipboardStatus.READY
                    }
                    val pkg = BuildConfig.APPLICATION_ID
                    val backgroundCommand = "adb shell pm grant $pkg android.permission.READ_LOGS && " +
                        "adb shell appops set $pkg SYSTEM_ALERT_WINDOW allow && " +
                        "adb shell am force-stop $pkg"
                    val connectionStatus = when {
                        connections.size > 1 -> stringResource(R.string.settings_status_connected_many, connections.size)
                        connections.size == 1 -> stringResource(R.string.settings_status_connected, connections.single().peerName)
                        else -> when (val s = pairingFlow) {
                            is PairingState.Connecting -> stringResource(R.string.settings_status_connecting, s.peerName)
                            is PairingState.Verification -> stringResource(R.string.settings_status_connecting, s.peerName)
                            else -> stringResource(R.string.settings_status_not_connected)
                        }
                    }
                    val codeTargets = connections.filter { it.state.remoteSmsCodes }.map { dev.bridgey.android.codes.CodeLinkMac(it.deviceId, it.peerName) }
                    val settingsUi =
                        SettingsState(
                            deviceName = settingsState.deviceName,
                            connectionStatus = connectionStatus,
                            connected = connected != null,
                            pairedCount = trustedDevices.size,
                            globalFeatures = settingsState.globalFeatures,
                            directCallsEnabled = settingsState.directCallsEnabled,
                            autoClipboardEnabled = settingsState.autoClipboardGlobal,
                            backgroundClipboardEnabled = settingsState.backgroundClipboardEnabled,
                            backgroundClipboardStatus = backgroundStatus,
                            backgroundClipboardCommand = backgroundCommand,
                            clipboardFilesEnabled = settingsState.clipboardFilesEnabled,
                            clipboardEagerLimit = settingsState.clipboardEagerLimit,
                            screenshotSendEnabled = settingsState.screenshotSendEnabled,
                            tileAddSupported = Build.VERSION.SDK_INT >= 33,
                            tileAdded = tileAdded,
                            notificationAppsEnabled = enabledApps,
                            notificationAppsTotal = totalApps,
                            appNotificationsEnabled = appNotificationsEnabled,
                            notificationAccessEnabled = notificationAccessEnabled,
                            reduceMotion = reduceMotion,
                            showPreviews = showPreviews,
                            activityCount = activity.size,
                            update = updateState,
                            installedVersion = updater.installedVersionName,
                            now = now,
                            remotePointerSpeed = remotePrefs.pointerSpeed,
                            remoteVolumeKeys = remotePrefs.volumeKeysChangeSlides,
                            batteryExempt = batteryExempt,
                            keepWifiAwakeSupported = WifiKeeper.SUPPORTED,
                            keepWifiAwake = settingsState.keepWifiAwake,
                            folders = folderUi.settingsState,
                            logging = settingsState.logging,
                            codes = CodesSettingsState(
                                access = codeAccessStatus,
                                link = companionLink,
                                linkApplies = Build.VERSION.SDK_INT >= dev.bridgey.android.codes.SENSITIVE_REDACTION_SDK,
                                linked = remember(codeAccessStatus, companionLink) { codes.access.isLinked() },
                                adbCommand = dev.bridgey.android.codes.codeAccessAdbCommand(BuildConfig.APPLICATION_ID),
                                linkTargets = codeTargets,
                                linkTarget = dev.bridgey.android.codes.CodeLinkTargets.current(codeTargets, codes.pickedTarget, pairing.companionLinkTarget()),
                                linkedMac = remember(companionLink) { codes.linkRecord.linked() },
                            ),
                            setup = dev.bridgey.android.ui.SetupSettingsState(oem = setup.oem),
                            focus = FocusSettingsState(settingsState.focusShare, settingsState.focusFollow, dndAccess),
                            updateAll = updateAllState,
                        )
                    val settingsUiActions =
                        SettingsActions(
                            back = { stack.pop() },
                            openDevices = { stack.push(Route.Devices) },
                            openSection = { stack.push(settingsRoute(it)) },
                            openPerfTest = { stack.push(Route.PerfTest) },
                            openNotificationApps = { stack.push(Route.NotificationApps) },
                            appNotifications = {
                                if (appNotificationsEnabled) onOpenAppNotificationSettings()
                                else permissionPrompt = PermissionPrompt.BridgeyNotifications
                            },
                            notificationAccess = {
                                if (notificationAccessEnabled) onOpenNotificationAccessSettings()
                                else permissionPrompt = PermissionPrompt.NotificationForwarding
                            },
                            rename = onDeviceNameChanged,
                            setGlobal = onSetGlobalFeature,
                            setDirectCalls = onSetDirectCalls,
                            setAutoClipboard = settings::setAutoClipboardGlobal,
                            setBackgroundClipboard = settings::setBackgroundClipboardEnabled,
                            setClipboardFiles = settings::setClipboardFilesEnabled,
                            setClipboardEagerLimit = settings::setClipboardEagerLimit,
                            setScreenshotSend = screenshotAccess::setEnabled,
                            copyCommand = {
                                context.getSystemService(ClipboardManager::class.java)
                                    .setPrimaryClip(ClipData.newPlainText("Bridgey", backgroundCommand))
                                android.widget.Toast.makeText(context, context.getString(R.string.bg_clipboard_copied), android.widget.Toast.LENGTH_SHORT).show()
                            },
                            addTile = onAddTile,
                            setReduceMotion = uiPreferences::setReduceMotion,
                            setShowPreviews = uiPreferences::setShowPreviews,
                            clearActivity = {
                                activityLog.clear()
                                pairing.clearClipboardCache()
                            },
                            exportDiagnostics = onExportDiagnostics,
                            setLogging = settings::setLogging,
                            clearLogs = pairing::clearDiagnostics,
                            turnOff = onTurnOff,
                            checkNow = updater::checkNow,
                            setChannel = updater::setChannel,
                            install = updater::install,
                            laterUpdate = updater::later,
                            skipUpdate = updater::skip,
                            showUpdate = updater::showUpdate,
                            dismissUpdateError = updater::dismissError,
                            openUrl = { runCatching { uriHandler.openUri(it) } },
                            setRemotePointerSpeed = remotePreferences::setPointerSpeed,
                            setRemoteVolumeKeys = remotePreferences::setVolumeKeysChangeSlides,
                            requestBatteryExemption = onRequestBatteryExemption,
                            openBatterySettings = onOpenBatterySettings,
                            setKeepWifiAwake = settings::setKeepWifiAwake,
                            folders = folderUi.settingsActions,
                            setup = dev.bridgey.android.ui.SetupSettingsActions(
                                openPermissions = { stack.push(Route.Permissions) },
                                openReset = { stack.push(Route.Reset) },
                                runSetup = {
                                    setup.startRerun()
                                    stack.push(Route.Setup)
                                },
                                openOemStep = { dev.bridgey.android.setup.OemBattery.open(context, it) },
                                addToObtainium = { dev.bridgey.android.setup.Obtainium.open(context, updateState.channel) },
                            ),
                            updateAll = updateAllActions,
                            focus = FocusSettingsActions(
                                setShare = settings::setFocusShare,
                                setFollow = { on ->
                                    settings.setFocusFollow(on)
                                    // Asked only now, when the person turns Follow on.
                                    if (on && !dndAccess) onOpenDndAccess()
                                },
                                openAccess = onOpenDndAccess,
                            ),
                            codes = CodesSettingsActions(
                                link = codes.linker::start,
                                linkTo = { deviceId ->
                                    codes.pickTarget(deviceId)
                                    codes.linker.start()
                                },
                                copyCommand = {
                                    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(
                                        ClipData.newPlainText("Bridgey", dev.bridgey.android.codes.codeAccessAdbCommand(BuildConfig.APPLICATION_ID)),
                                    )
                                    android.widget.Toast.makeText(context, context.getString(R.string.codes_adb_copied), android.widget.Toast.LENGTH_SHORT).show()
                                },
                            ),
                        )
                    when (route) {
                        Route.Setup -> SetupRoute(
                            hooks = setup,
                            settings = settingsUi,
                            actions = settingsUiActions,
                            pairedNames = trustedDevices.map { it.name },
                            nearby = peers.map { peer ->
                                dev.bridgey.android.ui.SetupNearbyMac(peer.key, peer.deviceNameHint, trustedDevices.any { it.id == peer.deviceIdHint })
                            },
                            onPair = { mac ->
                                peers.firstOrNull { it.key == mac.key }?.let { peer -> peer.host?.let { pairing.pair(it, peer.port ?: 42_458, peer.deviceNameHint) } }
                            },
                            onAddDevice = { pairDialog = true },
                            onLookForDevices = pairing::lookForDevices,
                            onOpenNotificationAccess = onOpenNotificationAccessSettings,
                            onOpenSection = { stack.push(settingsRoute(it)) },
                            onFinish = { openSettings ->
                                onOnboardingComplete()
                                stack.pop()
                                if (openSettings) stack.openSettings(Route.Settings)
                            },
                            onExit = { stack.pop() },
                            apply = { change -> applySetupChange(change, settings, onSetGlobalFeature, uiPreferences, remotePreferences, updater) },
                        )
                        Route.Permissions -> PermissionsRoute(
                            hooks = setup,
                            settings = settingsUi,
                            actions = settingsUiActions,
                            onRequestAppNotifications = onRequestAppNotifications,
                            onRequestDirectCalls = onRequestDirectCalls,
                            onOpenSection = { stack.push(settingsRoute(it)) },
                        )
                        Route.Reset -> ResetRoute(setup, onBack = { stack.pop() })
                        else -> SettingsScreen(section = (route as? Route.SettingsPane)?.section, state = settingsUi, actions = settingsUiActions)
                    }
                }
                Route.PerfTest -> {
                    val benchState by BenchState.state.collectAsStateWithLifecycle()
                    PerfTestScreen(
                        state = benchState,
                        pluggedIn = AndroidBenchProbe.isPluggedIn(context),
                        actions = PerfTestActions(
                            back = { stack.pop() },
                            run = { BenchService.start(context, it) },
                            cancel = { BenchService.cancel(context) },
                            copy = { report ->
                                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(
                                    ClipData.newPlainText("Bridgey performance test", report.toText { mode -> mode.english }),
                                )
                                android.widget.Toast.makeText(context, context.getString(R.string.perf_copied), android.widget.Toast.LENGTH_SHORT).show()
                            },
                            share = { report ->
                                context.startActivity(
                                    Intent.createChooser(
                                        Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, report.toJson()),
                                        context.getString(R.string.perf_share),
                                    ),
                                )
                            },
                            openCodeTest = if (BuildConfig.CODE_TEST_AVAILABLE) ({ stack.push(Route.CodeTest) }) else null,
                        ),
                    )
                }
                Route.CodeTest -> CodeTestScreen(
                    state = codeTestState,
                    cloudAvailable = dev.bridgey.android.codes.CodeTestSession.cloudAvailable(BuildConfig.OTP_PROXY_URL),
                    smsDenied = codes.smsDenied,
                    smsGranted = codes.smsGranted,
                    actions = CodeTestActions(
                        back = { stack.pop() },
                        start = codes.startTest,
                        stop = codes.stopTest,
                        label = dev.bridgey.android.codes.CodeTestSession::label,
                        finishReview = dev.bridgey.android.codes.CodeTestSession::finishReview,
                        export = { report ->
                            context.startActivity(
                                Intent.createChooser(
                                    Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_TEXT, report.toJson().toString(2)),
                                    context.getString(R.string.codetest_export),
                                ),
                            )
                        },
                        delete = codes.stopTest,
                        restart = codes.restart,
                        openAppSettings = codes.openAppSettings,
                    ),
                )
                Route.Places -> dev.bridgey.android.ui.PlacesScreen(
                    state = folderUi.placesState,
                    actions = dev.bridgey.android.ui.PlacesScreenActions(
                        back = { stack.pop() },
                        add = folderUi.placesActions.add,
                        allowFullAccess = folderUi.placesActions.allowFullAccess,
                        grantAgain = folderUi.placesActions.grantAgain,
                        remove = folderUi.placesActions.remove,
                        rename = folderUi.placesActions.rename,
                    ),
                )
                Route.Devices -> DevicesSettingsScreen(
                    state = DevicesSettingsState(rings = rings, rediscovering = rediscover == RediscoverState.Running),
                    actions = DevicesSettingsActions(
                        back = { stack.pop() },
                        openDevice = { ring -> ring.deviceId?.let { stack.push(Route.Device(it)) } },
                        addDevice = { pairDialog = true },
                        lookForDevices = pairing::lookForDevices,
                    ),
                )
                Route.NotificationApps -> NotificationAppsScreen(
                    state = NotificationAppsState(
                        applications = settingsState.notificationApplications.entries
                            .sortedBy { "${it.value.lowercase()}\u0000${it.key}" }
                            .map { it.key to it.value },
                        disabled = settingsState.disabledNotificationPackages,
                    ),
                    back = { stack.pop() },
                    setEnabled = { packageName, enabled ->
                        settings.setNotificationApplicationEnabled(packageName, enabled)
                        BridgeyNotificationListenerService.filterChanged(packageName, enabled)
                    },
                )
            }
        }
    }

    UpdatePrompts(updater)
    dev.bridgey.android.ui.UpdateAllSheetHost(updateAllSheet, updateAllState, updateAllActions)
    FolderQuestionHost(folderUi)
    AttachSheetHost(attach)

    // Asked once, after the first connection, while Android may still pause Bridgey in Doze.
    if (!batteryExempt && !batteryPromptShown && !showOnboarding && connections.isNotEmpty() && pairingFlow !is PairingState.Verification) {
        AlertDialog(
            onDismissRequest = uiPreferences::setBatteryPromptShown,
            title = { Text(stringResource(R.string.battery_prompt_title)) },
            text = { Text(stringResource(R.string.battery_prompt_body)) },
            confirmButton = {
                Button(onClick = {
                    uiPreferences.setBatteryPromptShown()
                    onRequestBatteryExemption()
                }) { Text(stringResource(R.string.action_allow)) }
            },
            dismissButton = { TextButton(onClick = uiPreferences::setBatteryPromptShown) { Text(stringResource(R.string.action_not_now)) } },
        )
    }

    // What's new, once after an update (the Home banner first for people who updated from before setup).
    WhatsNewHost(
        hooks = setup,
        updater = updater,
        onHome = stack.top == Route.Home,
        setupShowing = Route.Setup in stack.entries,
        onReviewSetup = {
            setup.startReview()
            stack.push(Route.Setup)
        },
        openUrl = { runCatching { uriHandler.openUri(it) } },
    )

    if (pairDialog) {
        PairDialog(
            peers = peers,
            trustedIds = trustedDevices.mapTo(HashSet()) { it.id },
            connectedIds = connections.mapTo(HashSet()) { it.deviceId },
            onPair = { peer ->
                pairDialog = false
                peer.host?.let { pairing.pair(it, peer.port ?: 42_458, peer.deviceNameHint) }
            },
            onDismiss = { pairDialog = false },
        )
    }

    forgetting?.let { ring ->
        AlertDialog(
            onDismissRequest = { forgetting = null },
            title = { Text(stringResource(R.string.forget_title, ring.name)) },
            text = { Text(stringResource(R.string.forget_body)) },
            confirmButton = {
                TextButton(onClick = {
                    forgetting = null
                    ring.deviceId?.let(pairing::forget)
                }) { Text(stringResource(R.string.action_forget), color = BridgeyTheme.colors.warn) }
            },
            dismissButton = { TextButton(onClick = { forgetting = null }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }

    // The pairing flow only: connected devices never hide or replace the prompt.
    when (val state = pairingFlow) {
        is PairingState.Verification -> AlertDialog(
            onDismissRequest = pairing::cancel,
            title = { Text("Verify this device") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Check that this code also appears on ${state.peerName}.")
                    Text(state.code, style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
                }
            },
            confirmButton = { Button(onClick = pairing::confirm) { Text("Codes match") } },
            dismissButton = { TextButton(onClick = pairing::cancel) { Text("Cancel") } },
        )
        is PairingState.Failed -> AlertDialog(
            onDismissRequest = pairing::cancel,
            title = { Text("Pairing failed") },
            text = { Text(state.message) },
            confirmButton = { Button(onClick = pairing::cancel) { Text("OK") } },
        )
        else -> Unit
    }

    ScreenshotAccessDialog(screenshotAccess)

    // The explainer the first time a feature needs the permission; straight on once explained.
    permissionPrompt?.let { prompt ->
        val kind = when (prompt) {
            PermissionPrompt.BridgeyNotifications -> dev.bridgey.android.setup.PermissionKind.POST_NOTIFICATIONS
            PermissionPrompt.NotificationForwarding -> dev.bridgey.android.setup.PermissionKind.NOTIFICATION_ACCESS
            PermissionPrompt.DirectCalls -> dev.bridgey.android.setup.PermissionKind.PHONE_CALLS
        }
        ExplainedPermission(
            setup, kind,
            onContinue = {
                permissionPrompt = null
                when (prompt) {
                    PermissionPrompt.NotificationForwarding -> onOpenNotificationAccessSettings()
                    PermissionPrompt.DirectCalls -> onRequestDirectCalls()
                    PermissionPrompt.BridgeyNotifications -> onRequestAppNotifications()
                }
            },
            onDismiss = { permissionPrompt = null },
        )
    }

    sharedContent?.let { content ->
        val isConnected = pairingState is PairingState.Connected
        val requiredFeature = if (content.files.isNotEmpty()) BridgeyFeature.FILES else BridgeyFeature.CLIPBOARD
        val featureAvailable = requiredFeature in availableWith((pairingState as? PairingState.Connected)?.deviceId)
        val summary = when {
            content.files.size == 1 -> "Send the selected file to your Mac?"
            content.files.isNotEmpty() -> "Send ${content.files.size} selected files to your Mac?"
            else -> "Send the shared text to your Mac?"
        }
        AlertDialog(
            onDismissRequest = onSharedContentHandled,
            title = { Text("Share with Bridgey") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(summary)
                    when {
                        !isConnected -> Text(
                            "Waiting for a trusted Mac to reconnect.",
                            color = MaterialTheme.colorScheme.error,
                        )
                        !featureAvailable -> Text(
                            "This feature is turned off on one of your devices.",
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }
            },
            confirmButton = {
                Button(
                    enabled = isConnected && featureAvailable,
                    onClick = {
                        content.text?.let { pairing.sendText(it) }
                        if (content.files.isNotEmpty()) pairing.sendFiles(content.files)
                        onSharedContentHandled()
                    },
                ) { Text("Send") }
            },
            dismissButton = {
                Row {
                    if (content.files.isEmpty() && content.text?.let(::validatedWebLink) != null &&
                        pairing.isFeatureAvailable(BridgeyFeature.LINKS)) {
                        TextButton(onClick = {
                            pairing.quickActions.sendLink(content.text.orEmpty())
                            onSharedContentHandled()
                        }) { Text("Send as link") }
                    }
                    TextButton(onClick = onSharedContentHandled) { Text("Cancel") }
                }
            },
        )
    }
}

/** Add: devices on this Wi-Fi, to pair or reconnect. */
@Composable
private fun PairDialog(
    peers: List<DiscoveredPeer>,
    trustedIds: Set<String>,
    connectedIds: Set<String>,
    onPair: (DiscoveredPeer) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    val visible = peers.filter { it.deviceIdHint == null || it.deviceIdHint !in connectedIds }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.pair_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.pair_body), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
                if (visible.isEmpty()) {
                    Text(stringResource(R.string.pair_searching), style = BridgeyType.bodyText, modifier = Modifier.padding(top = 8.dp))
                }
                visible.forEach { peer ->
                    val trusted = peer.deviceIdHint in trustedIds
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 56.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .clickable(role = Role.Button) { onPair(peer) }
                            .padding(horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        DeviceGlyph(RingState.NEARBY.style(), deviceIcon(peer.platformHint), 40.dp, iconSize = 18.dp)
                        Column(Modifier.weight(1f)) {
                            Text(peer.deviceNameHint, style = BridgeyType.itemTitle)
                            Text(
                                stringResource(if (trusted) R.string.pair_paired_suffix else R.string.pair_new_suffix),
                                style = BridgeyType.itemBody,
                                color = colors.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_close)) } },
    )
}

private fun decodeArtwork(encoded: String?): ImageBitmap? = runCatching {
    val bytes = Base64.decode(encoded ?: return@runCatching null, Base64.DEFAULT)
    if (bytes.size > 16384) return@runCatching null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth !in 1..128 || bounds.outHeight !in 1..128) return@runCatching null
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
}.getOrNull()

private val CALL_INTEGRATION_PERMISSIONS = arrayOf(
    Manifest.permission.CALL_PHONE,
    Manifest.permission.READ_PHONE_STATE,
    Manifest.permission.ANSWER_PHONE_CALLS,
)

/** The feedback line after "Look for devices again". */
private fun rediscoverMessage(context: android.content.Context, result: RediscoverState.Done): String {
    fun names(list: List<String>): String =
        if (list.size > 2) context.resources.getQuantityString(R.plurals.rediscover_many, list.size, list.size) else list.joinToString(", ")
    return when {
        result.found.isNotEmpty() && result.stillMissing.isNotEmpty() ->
            context.getString(R.string.rediscover_found_missing, names(result.found), names(result.stillMissing))
        result.found.isNotEmpty() -> context.getString(R.string.rediscover_found, names(result.found))
        result.stillMissing.isNotEmpty() -> context.getString(R.string.rediscover_missing, names(result.stillMissing))
        else -> context.getString(R.string.rediscover_none)
    }
}

/** The snackbar line for a Mac action status, or null when the screen already shows it. */
internal fun macActionMessage(
    context: android.content.Context,
    status: dev.bridgey.android.actions.MacActionStatus,
    title: String?,
    macName: String,
): String? {
    val kind = dev.bridgey.android.actions.MacActionIds.kind(status.actionId)
    return when (status.outcome) {
        dev.bridgey.android.actions.MacActionOutcome.RUNNING -> null
        dev.bridgey.android.actions.MacActionOutcome.DONE -> when (kind) {
            dev.bridgey.android.actions.MacActionKind.APP -> context.getString(R.string.mac_action_done_app, title ?: "", macName)
            dev.bridgey.android.actions.MacActionKind.SHORTCUT -> context.getString(R.string.mac_action_done_shortcut, title ?: "", macName)
            else -> null
        }
        dev.bridgey.android.actions.MacActionOutcome.NOT_CONFIRMED -> context.getString(R.string.mac_action_not_confirmed, macName)
        dev.bridgey.android.actions.MacActionOutcome.NOT_SENT -> context.getString(R.string.mac_action_not_sent, macName)
        dev.bridgey.android.actions.MacActionOutcome.REFUSED -> when (status.reason) {
            "not_allowed" -> context.getString(R.string.mac_action_refused_not_allowed, macName)
            "invalid" -> context.getString(R.string.mac_action_refused_invalid, macName)
            "rate_limited" -> context.getString(R.string.mac_action_refused_rate_limited)
            "busy" -> context.getString(R.string.mac_action_refused_busy, macName)
            "permission_required" -> context.getString(R.string.mac_action_refused_permission, macName)
            "unavailable" -> context.getString(R.string.mac_action_refused_unavailable, macName)
            else -> context.getString(R.string.mac_action_refused_failed, macName)
        }
    }
}
