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
import dev.bridgey.android.ui.LocalShowPreviews
import dev.bridgey.android.ui.MotionNavHost
import dev.bridgey.android.ui.NotificationAppsScreen
import dev.bridgey.android.ui.NotificationAppsState
import dev.bridgey.android.ui.PermissionRow
import dev.bridgey.android.ui.RingState
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsActions
import dev.bridgey.android.ui.SettingsScreen
import dev.bridgey.android.ui.SettingsState
import dev.bridgey.android.ui.UiPreferences
import dev.bridgey.android.ui.deviceIcon
import dev.bridgey.android.ui.deviceRings
import dev.bridgey.android.ui.liveTransfers
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

class MainActivity : ComponentActivity() {
    private lateinit var discovery: NsdDiscoveryService
    private lateinit var pairing: PairingCoordinator
    private lateinit var bridgeySettings: BridgeySettings
    private var notificationAccessEnabled by mutableStateOf(false)
    private var appNotificationsEnabled by mutableStateOf(false)
    private var readLogsGranted by mutableStateOf(false)
    private var sharedContent by mutableStateOf<SharedContent?>(null)
    private var showOnboarding by mutableStateOf(false)
    private val notificationPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        refreshPermissionState()
    }
    private val callPermissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        bridgeySettings.setDirectCallsEnabled(hasCallIntegrationPermissions())
        BridgeyNotificationListenerService.callPermissionsChanged()
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
        showOnboarding = !getSharedPreferences("bridgey_onboarding", MODE_PRIVATE)
            .getBoolean("completed", false)
        pairing = bridgey.pairing
        discovery = bridgey.discovery
        bridgeySettings = bridgey.settings
        sharedContent = intent.toSharedContent()
        startForegroundService(Intent(this, BridgeyConnectionService::class.java))
        if (savedInstanceState == null) bridgey.updater.checkOnAppOpen()
        setContent {
            BridgeyTheme {
                BridgeyApp(
                    discovery = discovery,
                    pairing = pairing,
                    settings = bridgey.settings,
                    updater = bridgey.updater,
                    activityLog = bridgey.activityLog,
                    uiPreferences = bridgey.uiPreferences,
                    onDeviceNameChanged = bridgey::updateDeviceName,
                    appNotificationsEnabled = appNotificationsEnabled,
                    notificationAccessEnabled = notificationAccessEnabled,
                    readLogsGranted = readLogsGranted,
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
                    sharedContent = sharedContent,
                    onSharedContentHandled = ::clearSharedContent,
                    showOnboarding = showOnboarding,
                    onOnboardingComplete = {
                        getSharedPreferences("bridgey_onboarding", MODE_PRIVATE)
                            .edit().putBoolean("completed", true).apply()
                        showOnboarding = false
                    },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshPermissionState()
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
        val item = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return
        val description = clipboard.primaryClipDescription
        pairing.autoSendClipboardOnResume(
            item.coerceToText(this).toString(),
            description.isMarkedSensitive(),
            description?.timestamp ?: 0L,
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sharedContent = intent.toSharedContent()
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
        appNotificationsEnabled = getSystemService(NotificationManager::class.java).areNotificationsEnabled()
        notificationAccessEnabled = NotificationAccess.isEnabled(this)
        readLogsGranted = checkSelfPermission(Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED
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
    activityLog: ActivityLog,
    uiPreferences: UiPreferences,
    onDeviceNameChanged: (String) -> Unit,
    appNotificationsEnabled: Boolean,
    notificationAccessEnabled: Boolean,
    readLogsGranted: Boolean,
    onTurnOff: () -> Unit,
    onRequestAppNotifications: () -> Unit,
    onOpenAppNotificationSettings: () -> Unit,
    onOpenNotificationAccessSettings: () -> Unit,
    onRequestDirectCalls: () -> Unit,
    onExportDiagnostics: () -> Unit,
    onAddTile: () -> Unit,
    sharedContent: SharedContent?,
    onSharedContentHandled: () -> Unit,
    showOnboarding: Boolean,
    onOnboardingComplete: () -> Unit,
) {
    val peers by discovery.peers.collectAsStateWithLifecycle()
    val pairingState by pairing.state.collectAsStateWithLifecycle()
    val fileTransfers by pairing.fileTransfers.collectAsStateWithLifecycle()
    val phoneRinging by pairing.phoneRinging.collectAsStateWithLifecycle()
    val macRinging by pairing.macRinging.collectAsStateWithLifecycle()
    val remoteBattery by pairing.remoteBattery.collectAsStateWithLifecycle()
    val trustedDevices by pairing.trustedDevices.collectAsStateWithLifecycle()
    val remoteFeatures by pairing.remoteFeatures.collectAsStateWithLifecycle()
    val receivedLink by pairing.quickActions.receivedLink.collectAsStateWithLifecycle()
    val media by pairing.quickActions.media.collectAsStateWithLifecycle()
    val settingsState by settings.state.collectAsStateWithLifecycle()
    val updateState by updater.state.collectAsStateWithLifecycle()
    val activity by activityLog.items.collectAsStateWithLifecycle()
    val reduceMotion by uiPreferences.reduceMotion.collectAsStateWithLifecycle()
    val showPreviews by uiPreferences.showPreviews.collectAsStateWithLifecycle()
    val tileAdded by uiPreferences.tileAdded.collectAsStateWithLifecycle()
    var permissionPrompt by remember { mutableStateOf<PermissionPrompt?>(null) }
    var pairDialog by rememberSaveable { mutableStateOf(false) }
    var forgetting by remember { mutableStateOf<DeviceRing?>(null) }
    var pickedTarget by rememberSaveable { mutableStateOf<String?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val stack = rememberBackStack()
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
        merge(pairing.clipboardStatus.drop(1), pairing.pingStatus.drop(1), pairing.quickActions.status.drop(1))
            .filterNotNull()
            .collect { status ->
                if (status !in QuietStatuses && !status.startsWith("Link delivered")) {
                    snackbar.currentSnackbarData?.dismiss()
                    snackbar.showSnackbar(status)
                }
            }
    }

    val connected = pairingState as? PairingState.Connected
    val rings = remember(trustedDevices, peers, pairingState) { deviceRings(trustedDevices, peers, pairingState) }
    val target = sendTarget(rings, pickedTarget)
    fun availableWith(deviceId: String?): Set<BridgeyFeature> =
        if (deviceId == null || connected?.deviceId != deviceId) {
            emptySet()
        } else {
            BridgeyFeature.entries.filter { settings.isEnabled(it, deviceId) && remoteFeatures[it] != false }.toSet()
        }

    val nameFor: (ActivityItem) -> String = { item ->
        rings.firstOrNull { it.deviceId != null && it.deviceId == item.deviceId }?.name
            ?: item.deviceName.ifBlank { context.getString(R.string.stream_file_unnamed) }
    }
    val linksAvailable = BridgeyFeature.LINKS in availableWith(connected?.deviceId)
    val homeLive = buildList {
        if (phoneRinging && connected != null) add(LiveCard.Ringing(connected.peerName))
        receivedLink?.takeIf { linksAvailable && connected != null }?.let { add(LiveCard.Link(it, connected!!.peerName)) }
        liveTransfers(fileTransfers).forEach { add(LiveCard.Transfer(it)) }
    }
    val liveActions = LiveActions(
        cancelTransfer = pairing::cancelFileTransfer,
        retryTransfer = pairing::retryFileTransfer,
        dismissTransfers = pairing::clearTransferHistory,
        openLink = pairing.quickActions::openLink,
        dismissLink = pairing.quickActions::dismissLink,
        stopRinging = pairing::stopFinding,
        media = { action, value -> pairing.quickActions.request(BridgeyFeature.MEDIA, action, value) },
    )
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(pairing::sendFile) }
    val readClipboard = {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
    }

    // A device page whose device was forgotten closes.
    LaunchedEffect(rings) {
        stack.removeWhere { route -> route is Route.Device && rings.none { it.deviceId == route.deviceId } }
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
                        now = now,
                    ),
                    actions = HomeActions(
                        openSettings = { stack.push(Route.Settings) },
                        selectRing = { ring -> pickedTarget = ring.deviceId },
                        openDevice = { ring -> ring.deviceId?.let { stack.push(Route.Device(it)) } },
                        pairRing = { ring -> ring.peer?.host?.let { pairing.pair(it, ring.peer.port ?: 42_458, ring.peer.deviceNameHint) } ?: run { pairDialog = true } },
                        addDevice = { pairDialog = true },
                        pickTarget = { pickedTarget = it },
                        sendClipboard = pairing::sendClipboard,
                        live = liveActions,
                    ),
                    snackbar = snackbar,
                    deviceName = nameFor,
                )
                is Route.Device -> {
                    val ring = rings.firstOrNull { it.deviceId == route.deviceId }
                    if (ring != null) {
                        val isConnected = connected?.deviceId == ring.deviceId
                        val available = availableWith(ring.deviceId)
                        val artwork = remember(media.artwork) { decodeArtwork(media.artwork) }
                        val deviceLive = if (!isConnected) emptyList() else buildList {
                            if (BridgeyFeature.MEDIA in available) add(LiveCard.Media(media, artwork))
                            addAll(homeLive)
                        }
                        val (enabledApps, _) = notificationAppCounts(settingsState.notificationApplications, settingsState.disabledNotificationPackages)
                        DeviceScreen(
                            state = DeviceState(
                                ring = ring,
                                battery = if (isConnected) remoteBattery else null,
                                connected = isConnected,
                                available = available,
                                ringing = isConnected && (macRinging || phoneRinging),
                                permissions = PermissionOrder.map { features ->
                                    val deviceId = ring.deviceId!!
                                    PermissionRow(
                                        features = features,
                                        checked = features.any { settingsState.globalFeatures[it] != false && settingsState.deviceFeatures[deviceId]?.get(it) != false },
                                        globallyOff = features.all { settingsState.globalFeatures[it] == false },
                                        remotelyOff = isConnected && features.all { remoteFeatures[it] == false },
                                    )
                                },
                                notificationAccess = notificationAccessEnabled,
                                notificationAppsEnabled = enabledApps,
                                autoClipboard = settings.isAutoClipboardEnabled(ring.deviceId),
                                autoClipboardGlobalOn = settingsState.autoClipboardGlobal,
                                activity = activity,
                                live = deviceLive,
                                now = now,
                            ),
                            actions = DeviceActions(
                                back = { stack.pop() },
                                forget = { forgetting = ring },
                                sendFile = { filePicker.launch(arrayOf("*/*")) },
                                sendLink = { pairing.quickActions.sendLink(readClipboard()) },
                                ping = pairing::sendPing,
                                find = pairing::findMac,
                                stopFind = pairing::stopFinding,
                                setPermission = { features, enabled ->
                                    val deviceId = ring.deviceId!!
                                    features.forEach { settings.setForDevice(deviceId, it, enabled) }
                                    if (BridgeyFeature.FIND_DEVICE in features && !enabled && isConnected) pairing.stopFinding()
                                },
                                setAutoClipboard = { enabled -> ring.deviceId?.let { settings.setAutoClipboardForDevice(it, enabled) } },
                                notificationAccess = {
                                    if (notificationAccessEnabled) onOpenNotificationAccessSettings()
                                    else permissionPrompt = PermissionPrompt.NotificationForwarding
                                },
                                sendClipboard = pairing::sendClipboard,
                                sendText = { pairing.sendText(it) },
                                live = liveActions,
                            ),
                            snackbar = snackbar,
                            deviceName = nameFor,
                        )
                    }
                }
                Route.Settings -> {
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
                    val connectionStatus = when (val s = pairingState) {
                        is PairingState.Connected -> stringResource(R.string.settings_status_connected, s.peerName)
                        is PairingState.Connecting -> stringResource(R.string.settings_status_connecting, s.peerName)
                        is PairingState.Verification -> stringResource(R.string.settings_status_connecting, s.peerName)
                        else -> stringResource(R.string.settings_status_not_connected)
                    }
                    SettingsScreen(
                        state = SettingsState(
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
                        ),
                        actions = SettingsActions(
                            back = { stack.pop() },
                            openDevices = { stack.push(Route.Devices) },
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
                            copyCommand = {
                                context.getSystemService(ClipboardManager::class.java)
                                    .setPrimaryClip(ClipData.newPlainText("Bridgey", backgroundCommand))
                                android.widget.Toast.makeText(context, context.getString(R.string.bg_clipboard_copied), android.widget.Toast.LENGTH_SHORT).show()
                            },
                            addTile = onAddTile,
                            setReduceMotion = uiPreferences::setReduceMotion,
                            setShowPreviews = uiPreferences::setShowPreviews,
                            clearActivity = activityLog::clear,
                            exportDiagnostics = onExportDiagnostics,
                            turnOff = onTurnOff,
                            checkNow = updater::checkNow,
                            setChannel = updater::setChannel,
                            install = updater::install,
                            openUrl = { runCatching { uriHandler.openUri(it) } },
                        ),
                    )
                }
                Route.Devices -> DevicesSettingsScreen(
                    state = DevicesSettingsState(rings = rings),
                    actions = DevicesSettingsActions(
                        back = { stack.pop() },
                        openDevice = { ring -> ring.deviceId?.let { stack.push(Route.Device(it)) } },
                        addDevice = { pairDialog = true },
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

    if (showOnboarding) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text(stringResource(R.string.welcome_title)) },
            text = { Text(stringResource(R.string.welcome_body)) },
            confirmButton = {
                Button(onClick = onOnboardingComplete) {
                    Text(stringResource(R.string.welcome_continue))
                }
            },
        )
    }

    if (pairDialog) {
        PairDialog(
            peers = peers,
            trustedIds = trustedDevices.mapTo(HashSet()) { it.id },
            connectedId = connected?.deviceId,
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

    when (val state = pairingState) {
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
            title = { Text("Couldn’t connect") },
            text = { Text(state.message) },
            confirmButton = { Button(onClick = pairing::cancel) { Text("OK") } },
        )
        else -> Unit
    }

    permissionPrompt?.let { prompt ->
        val isForwarding = prompt == PermissionPrompt.NotificationForwarding
        val isDirectCalls = prompt == PermissionPrompt.DirectCalls
        AlertDialog(
            onDismissRequest = { permissionPrompt = null },
            title = {
                Text(
                    when {
                        isForwarding -> "Forward Android notifications?"
                        isDirectCalls -> "Allow call status and controls?"
                        else -> "Allow Bridgey notifications?"
                    },
                )
            },
            text = {
                Text(
                    when {
                        isForwarding -> "This optional access lets Bridgey read notification titles and text and send them only to your paired Mac over the encrypted local connection."
                        isDirectCalls -> "These optional Phone permissions let an authenticated paired Mac start calls, distinguish ringing from active calls, and answer, decline, or hang up. Bridgey does not read contacts or call history."
                        else -> "Bridgey uses notifications to keep the connection visible and show file transfers, received files, and Find Device. It does not use notifications for advertising."
                    },
                )
            },
            confirmButton = {
                Button(onClick = {
                    permissionPrompt = null
                    when {
                        isForwarding -> onOpenNotificationAccessSettings()
                        isDirectCalls -> onRequestDirectCalls()
                        else -> onRequestAppNotifications()
                    }
                }) { Text("Continue") }
            },
            dismissButton = { TextButton(onClick = { permissionPrompt = null }) { Text("Not now") } },
        )
    }

    sharedContent?.let { content ->
        val isConnected = pairingState is PairingState.Connected
        val requiredFeature = if (content.files.isNotEmpty()) BridgeyFeature.FILES else BridgeyFeature.CLIPBOARD
        val featureAvailable = settings.isEnabled(
            requiredFeature,
            (pairingState as? PairingState.Connected)?.deviceId,
        ) && remoteFeatures[requiredFeature] != false
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
                        content.files.forEach(pairing::sendFile)
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
    connectedId: String?,
    onPair: (DiscoveredPeer) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    val visible = peers.filter { it.deviceIdHint == null || it.deviceIdHint != connectedId }
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
