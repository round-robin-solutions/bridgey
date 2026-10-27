package dev.bridgey.android

import android.Manifest
import android.app.Activity
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.setup.AndroidResetEnvironment
import dev.bridgey.android.setup.AppVersion
import dev.bridgey.android.setup.BundledNotes
import dev.bridgey.android.setup.LocalDataReset
import dev.bridgey.android.setup.OemBattery
import dev.bridgey.android.setup.OemChecklist
import dev.bridgey.android.setup.PermissionCatalog
import dev.bridgey.android.setup.PermissionEntry
import dev.bridgey.android.setup.PermissionFacts
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.PermissionState
import dev.bridgey.android.setup.ResetChoice
import dev.bridgey.android.setup.ResetHook
import dev.bridgey.android.setup.BackAction
import dev.bridgey.android.setup.MacTwinApps
import dev.bridgey.android.setup.SettingChange
import dev.bridgey.android.setup.SetupBack
import dev.bridgey.android.setup.SetupChoicesSync
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupPermission
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupLaunch
import dev.bridgey.android.setup.SetupQuestions
import dev.bridgey.android.setup.SetupScreen
import dev.bridgey.android.setup.SetupSetting
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.setup.SetupStore
import dev.bridgey.android.setup.WhatsNewDecision
import dev.bridgey.android.setup.WhatsNewLogic
import dev.bridgey.android.ui.PermissionExplainerDialog
import dev.bridgey.android.ui.PermissionsScreen
import dev.bridgey.android.ui.ResetScreen
import dev.bridgey.android.ui.SettingsActions
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.SettingsState
import dev.bridgey.android.ui.SetupActions
import dev.bridgey.android.ui.SetupNearbyMac
import dev.bridgey.android.ui.SetupScreen
import dev.bridgey.android.ui.SetupUiState
import dev.bridgey.android.ui.WhatsNewBanner
import dev.bridgey.android.ui.WhatsNewDialog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * What the activity hands the v0.10 setup, Permissions, Reset and What's new screens. Created in
 * onCreate, once per launch; [launch] is that launch's decision about setup.
 */
internal class SetupHooks(
    val store: SetupStore,
    val launch: SetupLaunch,
    val oem: OemChecklist?,
    /** Restarts Bridgey after Reset > Settings or Everything (settings live in memory). */
    val restart: () -> Unit,
    val resetHook: (ResetHook) -> Unit,
) {
    /** Where the next Route.Setup starts: Welcome, or the questions (Review setup). */
    private var nextStart: SetupState = SetupState()

    /** Setup was opened from Settings or What's new, not as first-run setup. */
    var rerun: Boolean = false
        private set

    fun startRerun() {
        nextStart = SetupState()
        rerun = true
    }

    fun startReview() {
        nextStart = SetupState.review()
        rerun = true
    }

    fun takeStart(): SetupState = nextStart.also { nextStart = SetupState() }

    companion object {
        fun create(activity: Activity, oldOnboardingCompleted: Boolean, restart: () -> Unit, resetHook: (ResetHook) -> Unit): SetupHooks {
            val store = SetupStore(activity)
            return SetupHooks(store, store.launch(oldOnboardingCompleted), OemBattery.checklist(Build.MANUFACTURER, Build.BRAND), restart, resetHook)
        }
    }
}

/** Restarts the app in a fresh process (Reset > Settings and Everything). */
internal fun Activity.restartBridgey() {
    val launch = packageManager.getLaunchIntentForPackage(packageName)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
    if (launch != null) startActivity(launch)
    finishAffinity()
    Runtime.getRuntime().exit(0)
}

/** What a reset asks the running Bridgey to do before files go. */
internal fun BridgeyApplication.runResetHook(hook: ResetHook) {
    when (hook) {
        ResetHook.DISCONNECT -> {
            discovery.stop()
            pairing.pause()
        }
        ResetHook.CLEAR_ACTIVITY -> activityLog.clear()
        ResetHook.CLEAR_DIAGNOSTICS -> pairing.clearDiagnostics()
        ResetHook.CLEAR_TRANSFER_HISTORY -> pairing.clearTransferHistory()
        ResetHook.CLEAR_CLIPBOARD_CACHE -> pairing.clearClipboardCache()
        ResetHook.CLEAR_CONNECTION_HEALTH -> pairing.clearConnectionHealth()
        ResetHook.CLEAR_MAC_ACTION_CATALOGS -> pairing.macActions.clearCatalogs()
        ResetHook.RELEASE_FOCUS -> pairing.releaseFocus()
        ResetHook.RELEASE_FOLDER_GRANTS -> contentResolver.persistedUriPermissions.forEach { permission ->
            val flags = (if (permission.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
            runCatching { contentResolver.releasePersistableUriPermission(permission.uri, flags) }
        }
        ResetHook.REMOVE_COMPANION_LINK -> {
            val manager = getSystemService(CompanionDeviceManager::class.java) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.myAssociations.forEach { runCatching { manager.disassociate(it.id) } }
            } else {
                @Suppress("DEPRECATION")
                manager.associations.forEach { runCatching { manager.disassociate(it) } }
            }
        }
    }
}

internal val SetupStateSaver = Saver<SetupState, String>(save = { it.encode() }, restore = { SetupState.decode(it) })

/** What the questions read from Settings now (the answers are applied as they are given). */
internal fun setupFacts(context: Context, settings: SettingsState, paired: Boolean, duplicateApps: List<Pair<String, String>>): SetupFacts {
    val current = buildMap {
        mapOf(
            SetupSetting.FEATURE_CLIPBOARD to BridgeyFeature.CLIPBOARD, SetupSetting.FEATURE_NOTIFICATIONS to BridgeyFeature.NOTIFICATIONS,
            SetupSetting.FEATURE_CALLS to BridgeyFeature.CALLS, SetupSetting.FEATURE_FILES to BridgeyFeature.FILES,
            SetupSetting.FEATURE_REMOTE_INPUT to BridgeyFeature.REMOTE_INPUT, SetupSetting.FEATURE_MAC_ACTIONS to BridgeyFeature.MAC_ACTIONS,
            SetupSetting.FEATURE_MEDIA to BridgeyFeature.MEDIA, SetupSetting.FEATURE_CAMERA to BridgeyFeature.CAMERA,
            SetupSetting.FEATURE_LINKS to BridgeyFeature.LINKS, SetupSetting.FEATURE_FIND_DEVICE to BridgeyFeature.FIND_DEVICE,
            SetupSetting.FEATURE_PING to BridgeyFeature.PING, SetupSetting.FEATURE_BATTERY to BridgeyFeature.BATTERY,
        ).forEach { (setting, feature) -> put(setting, settings.featureOn(feature).toString()) }
        put(SetupSetting.PAIRING, paired.toString())
        put(SetupSetting.AUTO_CLIPBOARD, settings.autoClipboardEnabled.toString())
        put(SetupSetting.CLIPBOARD_FILES, settings.clipboardFilesEnabled.toString())
        put(SetupSetting.SCREENSHOT_SEND, settings.screenshotSendEnabled.toString())
        put(SetupSetting.BACKGROUND_CLIPBOARD, settings.backgroundClipboardEnabled.toString())
        put(SetupSetting.NOTIFICATION_ACCESS, settings.notificationAccessEnabled.toString())
        put(SetupSetting.APP_NOTIFICATIONS, settings.appNotificationsEnabled.toString())
        put(SetupSetting.CODES_LINK, settings.codes.linked.toString())
        put(SetupSetting.FOCUS_SHARE, settings.focus.share.toString())
        put(SetupSetting.FOCUS_FOLLOW, settings.focus.follow.toString())
        put(SetupSetting.DIRECT_CALLS, settings.directCallsEnabled.toString())
        put(SetupSetting.FOLDER_MODE, settings.folders.mode.name)
        put(SetupSetting.ALLOW_BROWSE, settings.folders.allowBrowse.toString())
        put(SetupSetting.ALLOW_REPLACE, settings.folders.allowReplace.toString())
        put(SetupSetting.REMOTE_VOLUME_KEYS, settings.remoteVolumeKeys.toString())
        put(SetupSetting.SHOW_PREVIEWS, settings.showPreviews.toString())
        put(SetupSetting.LOGGING_CONNECTION, settings.logging.connection.toString())
        put(SetupSetting.UPDATE_CHANNEL, settings.update.channel.name)
        put(SetupSetting.BATTERY_EXEMPTION, settings.batteryExempt.toString())
        put(SetupSetting.KEEP_WIFI_AWAKE, settings.keepWifiAwake.toString())
        put(SetupSetting.REDUCE_MOTION, settings.reduceMotion.toString())
    }
    return SetupFacts(
        paired = paired,
        current = current,
        granted = permissionFacts(context, settings).granted,
        sdkInt = Build.VERSION.SDK_INT,
        foldersSupported = settings.folders.supported,
        wifiAwakeSupported = settings.keepWifiAwakeSupported,
        codesLinkApplies = settings.codes.linkApplies,
        duplicateApps = duplicateApps,
    )
}

/** The apps in [MacTwinApps] installed on this phone (declared in the manifest's queries). */
internal fun installedMacTwinApps(context: Context): List<Pair<String, String>> =
    MacTwinApps.known.filter { (packageName, _) ->
        runCatching { context.packageManager.getApplicationInfo(packageName, 0) }.isSuccess
    }

/**
 * Applies one answer's setting the way its Settings page does, without the page's own permission
 * prompts: setup asks for the permission itself, right after the answer.
 */
internal fun applySetupChange(
    change: SettingChange,
    settings: BridgeySettings,
    setGlobal: (BridgeyFeature, Boolean) -> Unit,
    uiPreferences: dev.bridgey.android.ui.UiPreferences,
    remotePreferences: dev.bridgey.android.remote.RemoteInputPreferences,
    updater: AppUpdater,
) {
    val on = change.value == "true"
    when (change.setting) {
        SetupSetting.FEATURE_CLIPBOARD -> setGlobal(BridgeyFeature.CLIPBOARD, on)
        SetupSetting.FEATURE_NOTIFICATIONS -> setGlobal(BridgeyFeature.NOTIFICATIONS, on)
        SetupSetting.FEATURE_CALLS -> setGlobal(BridgeyFeature.CALLS, on)
        SetupSetting.FEATURE_FILES -> setGlobal(BridgeyFeature.FILES, on)
        SetupSetting.FEATURE_REMOTE_INPUT -> setGlobal(BridgeyFeature.REMOTE_INPUT, on)
        SetupSetting.FEATURE_MAC_ACTIONS -> setGlobal(BridgeyFeature.MAC_ACTIONS, on)
        SetupSetting.FEATURE_MEDIA -> setGlobal(BridgeyFeature.MEDIA, on)
        SetupSetting.FEATURE_CAMERA -> setGlobal(BridgeyFeature.CAMERA, on)
        SetupSetting.FEATURE_LINKS -> setGlobal(BridgeyFeature.LINKS, on)
        SetupSetting.FEATURE_FIND_DEVICE -> setGlobal(BridgeyFeature.FIND_DEVICE, on)
        SetupSetting.FEATURE_PING -> setGlobal(BridgeyFeature.PING, on)
        SetupSetting.FEATURE_BATTERY -> setGlobal(BridgeyFeature.BATTERY, on)
        SetupSetting.AUTO_CLIPBOARD -> settings.setAutoClipboardGlobal(on)
        SetupSetting.CLIPBOARD_FILES -> settings.setClipboardFilesEnabled(on)
        SetupSetting.SCREENSHOT_SEND -> settings.setScreenshotSendEnabled(on)
        SetupSetting.DIRECT_CALLS -> settings.setDirectCallsEnabled(on)
        SetupSetting.FOCUS_SHARE -> settings.setFocusShare(on)
        SetupSetting.FOCUS_FOLLOW -> settings.setFocusFollow(on)
        SetupSetting.FOLDER_MODE -> runCatching { dev.bridgey.android.folders.DestinationMode.valueOf(change.value) }.getOrNull()?.let(settings::setFolderMode)
        SetupSetting.ALLOW_BROWSE -> settings.setAllowBrowseFromOtherDevices(on)
        SetupSetting.ALLOW_REPLACE -> settings.setAllowReplaceFromOtherDevices(on)
        SetupSetting.REMOTE_VOLUME_KEYS -> remotePreferences.setVolumeKeysChangeSlides(on)
        SetupSetting.SHOW_PREVIEWS -> uiPreferences.setShowPreviews(on)
        SetupSetting.REDUCE_MOTION -> uiPreferences.setReduceMotion(on)
        SetupSetting.LOGGING_CONNECTION -> settings.setLogging(settings.state.value.logging.copy(connection = on))
        SetupSetting.UPDATE_CHANNEL -> UpdateChannel.entries.firstOrNull { it.name == change.value }?.let(updater::setChannel)
        SetupSetting.KEEP_WIFI_AWAKE -> settings.setKeepWifiAwake(on)
        SetupSetting.HIDDEN_NOTIFICATION_APPS -> {
            // Only the apps the question listed: picked ones stay on the phone, the others are sent again.
            val hidden = change.value.split(',').filter { it.isNotEmpty() }.toSet()
            MacTwinApps.known.forEach { (packageName, name) ->
                val wasKnown = settings.state.value.notificationApplications.containsKey(packageName)
                if (!wasKnown && packageName !in hidden) return@forEach
                settings.observeNotificationApplication(packageName, name)
                settings.setNotificationApplicationEnabled(packageName, packageName !in hidden)
                BridgeyNotificationListenerService.filterChanged(packageName, packageName !in hidden)
            }
        }
        // Set by their permission (asked right after the answer), by pairing, or on a Settings page.
        SetupSetting.PAIRING, SetupSetting.NOTIFICATION_ACCESS, SetupSetting.APP_NOTIFICATIONS, SetupSetting.CODES_LINK,
        SetupSetting.BATTERY_EXEMPTION, SetupSetting.OEM_CHECKLIST, SetupSetting.CLIPBOARD_EAGER_LIMIT,
        SetupSetting.BACKGROUND_CLIPBOARD, SetupSetting.FOLDER_DEFAULT_PLACE, SetupSetting.FOLDER_CONFLICT, SetupSetting.PLACES,
        SetupSetting.REMOTE_POINTER_SPEED, SetupSetting.LOGGING_DETAIL -> Unit
    }
}

/**
 * System back and the predictive gesture in setup: the previous step; on the first screen, leave,
 * asking once ("Leave setup?") when something was chosen. It goes through the nav host's page
 * back ([dev.bridgey.android.ui.PageBackHandler]), the only back handler, so the order handlers
 * registered in cannot send back past setup.
 */
@Composable
internal fun SetupBackHandler(flow: SetupState, send: (SetupEvent) -> Unit, onExit: () -> Unit) {
    dev.bridgey.android.ui.PageBackHandler(enabled = SetupBack.intercepts(flow) || flow.confirmLeave) {
        when {
            flow.confirmLeave -> send(SetupEvent.KeepGoing)
            else -> when (SetupBack.decide(flow)) {
                BackAction.STEP -> send(SetupEvent.Back)
                BackAction.ASK_LEAVE -> send(SetupEvent.AskLeave)
                BackAction.LEAVE -> onExit()
            }
        }
    }
}

/**
 * Route.Setup: first-run setup, or Run setup again. Answers change the real settings as they are
 * given ([apply]). [onFinish] marks setup done; `true` opens Settings instead of Home. Back (and
 * the predictive gesture) goes to the previous step through the nav host's page back; on the first
 * screen it leaves, asking first when something was chosen.
 */
/** The Pair step's link to the coordinator's Allow pairing (see [dev.bridgey.android.PairingCoordinator.armPairing]). */
internal class SetupPairing(
    val request: dev.bridgey.android.PairingRequest? = null,
    val armedSeconds: Int = 0,
    val hold: (Boolean) -> Unit = {},
    val allow: () -> Unit = {},
    val dismiss: () -> Unit = {},
    val stop: () -> Unit = {},
)

@Composable
internal fun SetupRoute(
    hooks: SetupHooks,
    settings: SettingsState,
    actions: SettingsActions,
    pairedNames: List<String>,
    nearby: List<SetupNearbyMac>,
    onPair: (SetupNearbyMac) -> Unit,
    pairingReady: SetupPairing,
    onAddDevice: () -> Unit,
    onLookForDevices: () -> Unit,
    onOpenNotificationAccess: () -> Unit,
    onOpenSection: (SettingsSection) -> Unit,
    onFinish: (openSettings: Boolean) -> Unit,
    onExit: () -> Unit,
    apply: (SettingChange) -> Unit,
) {
    val context = LocalContext.current
    var flow by rememberSaveable(stateSaver = SetupStateSaver) { mutableStateOf(hooks.takeStart()) }
    val rerun = remember { hooks.rerun }
    val duplicateApps = remember { installedMacTwinApps(context) }
    val facts = setupFacts(context, settings, pairedNames.isNotEmpty(), duplicateApps)
    val latestSettings by rememberUpdatedState(settings)
    val scope = rememberCoroutineScope()
    /** Allow all: the special access screens still to open, in order (saved, as the app leaves for each). */
    var queue by rememberSaveable { mutableStateOf("") }

    fun currentFacts() = setupFacts(context, latestSettings, pairedNames.isNotEmpty(), duplicateApps)

    fun send(event: SetupEvent) {
        val current = flow
        val now = currentFacts()
        when (event) {
            // Get started quickly: the Essentials, for the features that are off.
            SetupEvent.ChooseQuick -> SetupBundles.essentialChanges(SetupFlow.effective(current, now)).forEach(apply)
            is SetupEvent.StartQuestions -> SetupFlow.startChanges(event.chosen).forEach(apply)
            is SetupEvent.Answer -> SetupQuestions.question(event.id)?.let { question -> SetupQuestions.changes(question, event.key).forEach(apply) }
            is SetupEvent.Switch -> SetupFeatures.feature(event.feature)?.let { feature -> (if (event.on) feature.on else feature.off).forEach(apply) }
            // Leaving the permissions page: whatever is still not allowed turns its features off.
            SetupEvent.Continue -> if (current.screen == SetupScreen.Permissions) {
                SetupFlow.neededPermissions(current, now).filter { it.kind !in now.granted }.forEach { it.offWhenRefused.forEach(apply) }
            }
            is SetupEvent.SummarySwitch -> SetupFeatures.feature(event.feature)?.let { feature -> (if (event.on) feature.on else feature.off).forEach(apply) }
            else -> Unit
        }
        flow = SetupFlow.reduce(current, event, now)
    }

    fun leave() {
        if (flow.hasProgress) send(SetupEvent.AskLeave) else onExit()
    }

    SetupBackHandler(flow, ::send, onExit)

    fun granted(kind: PermissionKind): Boolean = kind in permissionFacts(context, latestSettings).granted

    fun openSpecial(kind: PermissionKind) {
        when (kind) {
            PermissionKind.NOTIFICATION_ACCESS -> onOpenNotificationAccess()
            PermissionKind.BATTERY -> actions.requestBatteryExemption()
            PermissionKind.DO_NOT_DISTURB -> actions.focus.openAccess()
            PermissionKind.COMPANION_LINK -> actions.codes.link()
            else -> Unit
        }
    }

    /** The next special access screen Allow all opens; the rest wait for Bridgey to come back. */
    fun nextInQueue() {
        val kinds = queue.split(',').filter { it.isNotEmpty() }.map(PermissionKind::valueOf).filterNot(::granted)
        val next = kinds.firstOrNull()
        queue = kinds.drop(1).joinToString(",") { it.name }
        if (next != null) {
            send(SetupEvent.Asked(setOf(next)))
            openSpecial(next)
        }
    }

    val runtimeRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result.keys.any { it == Manifest.permission.CALL_PHONE } && granted(PermissionKind.PHONE_CALLS)) {
            BridgeyNotificationListenerService.callPermissionsChanged()
        }
        nextInQueue()
    }

    // Back from a system screen: the page shows the new status; Allow all goes on to the next screen.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        if (queue.isEmpty()) return@LifecycleEventEffect
        // Some answers (the companion link) arrive a moment after the app resumes.
        scope.launch {
            delay(400)
            nextInQueue()
        }
    }

    fun runtimeNames(kinds: List<PermissionKind>): Array<String> = kinds.flatMap { kind ->
        when (kind) {
            PermissionKind.PHONE_CALLS -> listOf(Manifest.permission.CALL_PHONE, Manifest.permission.READ_PHONE_STATE, Manifest.permission.ANSWER_PHONE_CALLS)
            PermissionKind.POST_NOTIFICATIONS -> if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()
            PermissionKind.PHOTOS -> dev.bridgey.android.browse.MediaAccessRules.request(Build.VERSION.SDK_INT).toList()
            PermissionKind.CAMERA -> listOf(Manifest.permission.CAMERA)
            else -> emptyList()
        }
    }.distinct().toTypedArray()

    fun allow(kinds: List<SetupPermission>) {
        val open = kinds.filterNot { granted(it.kind) }
        if (open.isEmpty()) return
        open.forEach { hooks.store.markExplained(it.kind) }
        val runtime = open.filter { it.runtime }.map { it.kind }
        queue = open.filterNot { it.runtime }.joinToString(",") { it.kind.name }
        val names = runtimeNames(runtime)
        if (names.isNotEmpty()) {
            send(SetupEvent.Asked(runtime.toSet()))
            runtimeRequest.launch(names)
        } else {
            nextInQueue()
        }
    }

    fun finish(openSettings: Boolean) {
        hooks.store.recordSkipped(flow.skipped)
        // Settings sync hook (deferred): a later sync can offer these choices to the other device.
        SetupChoicesSync.offer(flow.choices)
        onFinish(openSettings)
    }
    SetupScreen(
        SetupUiState(
            flow, settings.copy(setup = settings.setup.copy(oem = hooks.oem)), pairedNames, nearby, hooks.oem, rerun, facts,
            pairingRequest = pairingReady.request, armedSeconds = pairingReady.armedSeconds,
        ),
        SetupActions(
            event = ::send,
            settings = actions,
            pair = onPair,
            holdPairing = pairingReady.hold,
            allowPairing = pairingReady.allow,
            dismissPairingRequest = pairingReady.dismiss,
            stopPairing = pairingReady.stop,
            addDevice = onAddDevice,
            lookForDevices = onLookForDevices,
            // The quick step shows the explainer's why and without-it itself.
            allowNotificationAccess = {
                hooks.store.markExplained(PermissionKind.NOTIFICATION_ACCESS)
                onOpenNotificationAccess()
            },
            allowBattery = {
                hooks.store.markExplained(PermissionKind.BATTERY)
                actions.requestBatteryExemption()
            },
            openOemStep = { OemBattery.open(context, it) },
            openPage = { page -> SettingsSection.entries.firstOrNull { it.name == page }?.let(onOpenSection) },
            allowPermission = { kind -> SetupQuestions.permission(kind)?.let { allow(listOf(it)) } },
            allowAll = { allow(SetupFlow.neededPermissions(flow, currentFacts())) },
            openSettings = { finish(openSettings = true) },
            start = { finish(openSettings = false) },
            exit = onExit,
            leave = ::leave,
        ),
    )
}

/** The permission facts right now; read again whenever the app returns to the front. */
@Composable
internal fun rememberPermissionEntries(settings: SettingsState): List<PermissionEntry> {
    val context = LocalContext.current
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { resumes++ }
    return remember(settings, resumes) { PermissionCatalog.entries(permissionFacts(context, settings)) }
}

internal fun permissionFacts(context: Context, settings: SettingsState): PermissionFacts {
    fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    val granted = buildSet {
        if (settings.notificationAccessEnabled) add(PermissionKind.NOTIFICATION_ACCESS)
        if (settings.appNotificationsEnabled) add(PermissionKind.POST_NOTIFICATIONS)
        if (listOf(Manifest.permission.CALL_PHONE, Manifest.permission.READ_PHONE_STATE, Manifest.permission.ANSWER_PHONE_CALLS).all(::granted)) {
            add(PermissionKind.PHONE_CALLS)
        }
        // Files 2.0 needs photos and videos (attach sheet, Mac browsing); a fresh screenshot needs photos only.
        val photosGranted = if (settings.featureOn(BridgeyFeature.FILES)) {
            dev.bridgey.android.browse.MediaAccessRules.access(Build.VERSION.SDK_INT, ::granted) == dev.bridgey.android.browse.MediaAccess.FULL
        } else {
            PhotoPermissions.access(context) == PhotoAccess.FULL
        }
        if (photosGranted) add(PermissionKind.PHOTOS)
        if (granted(Manifest.permission.CAMERA)) add(PermissionKind.CAMERA)
        if (settings.focus.access) add(PermissionKind.DO_NOT_DISTURB)
        if (settings.codes.linked) add(PermissionKind.COMPANION_LINK)
        if (settings.batteryExempt) add(PermissionKind.BATTERY)
        if (context.packageManager.canRequestPackageInstalls()) add(PermissionKind.INSTALL_PACKAGES)
        if (granted(Manifest.permission.READ_SMS)) add(PermissionKind.SMS)
        if (granted(Manifest.permission.READ_LOGS)) add(PermissionKind.LOGS)
    }
    return PermissionFacts(
        sdkInt = Build.VERSION.SDK_INT,
        labBuild = BuildConfig.CODE_TEST_AVAILABLE,
        granted = granted,
        notificationsOn = settings.featureOn(BridgeyFeature.NOTIFICATIONS),
        callsOn = settings.featureOn(BridgeyFeature.CALLS),
        screenshotOn = settings.featureOn(BridgeyFeature.CLIPBOARD) && settings.clipboardFilesEnabled && settings.screenshotSendEnabled,
        backgroundClipboardOn = settings.backgroundClipboardEnabled,
        mediaOn = settings.featureOn(BridgeyFeature.FILES),
        cameraOn = settings.featureOn(BridgeyFeature.CAMERA),
        focusFollowOn = settings.focus.follow,
    )
}

/** Route.Permissions: Manage opens the system screen, or the explainer then the request. */
@Composable
internal fun PermissionsRoute(
    hooks: SetupHooks,
    settings: SettingsState,
    actions: SettingsActions,
    onRequestAppNotifications: () -> Unit,
    onRequestDirectCalls: () -> Unit,
    onOpenSection: (SettingsSection) -> Unit,
) {
    val context = LocalContext.current
    var explaining by rememberSaveable { mutableStateOf<PermissionKind?>(null) }
    val entries = rememberPermissionEntries(settings)
    fun start(intent: Intent) = runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    val appDetails = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
    fun open(kind: PermissionKind, allowed: Boolean) {
        when (kind) {
            PermissionKind.NOTIFICATION_ACCESS -> start(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            PermissionKind.POST_NOTIFICATIONS -> onRequestAppNotifications()
            PermissionKind.PHONE_CALLS -> if (allowed) start(appDetails) else onRequestDirectCalls()
            // Files 2.0 also needs videos, which the screenshot request does not ask for: App info allows both.
            PermissionKind.PHOTOS -> if (allowed || settings.featureOn(BridgeyFeature.FILES)) start(appDetails) else actions.setScreenshotSend(true)
            // Android asks for the camera the first time a Mac asks for a photo; App info allows or removes it.
            PermissionKind.CAMERA -> start(appDetails)
            PermissionKind.COMPANION_LINK -> onOpenSection(SettingsSection.NOTIFICATIONS)
            PermissionKind.DO_NOT_DISTURB -> actions.focus.openAccess()
            PermissionKind.BATTERY -> if (allowed) start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) else actions.requestBatteryExemption()
            PermissionKind.INSTALL_PACKAGES -> start(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
            PermissionKind.SMS -> start(appDetails)
            PermissionKind.LOGS -> onOpenSection(SettingsSection.CLIPBOARD)
        }
    }
    PermissionsScreen(entries, onBack = actions.back) { entry ->
        if (entry.state == PermissionState.ALLOWED) open(entry.kind, allowed = true) else explaining = entry.kind
    }
    explaining?.let { kind ->
        PermissionExplainerDialog(
            kind,
            onContinue = {
                explaining = null
                hooks.store.markExplained(kind)
                open(kind, allowed = false)
            },
            onDismiss = { explaining = null },
        )
    }
}

/**
 * A feature needs [kind]: the explainer the first time, straight to [onContinue] once explained.
 * [onDismiss] runs for Not now.
 */
@Composable
internal fun ExplainedPermission(hooks: SetupHooks, kind: PermissionKind, onContinue: () -> Unit, onDismiss: () -> Unit) {
    if (hooks.store.explained(kind)) {
        LaunchedEffect(kind) { onContinue() }
    } else {
        PermissionExplainerDialog(kind, onContinue = { hooks.store.markExplained(kind); onContinue() }, onDismiss = onDismiss)
    }
}

/** Route.Reset: the four choices; Settings and Everything restart Bridgey. */
@Composable
internal fun ResetRoute(hooks: SetupHooks, onBack: () -> Unit) {
    val context = LocalContext.current
    var confirming by rememberSaveable { mutableStateOf<ResetChoice?>(null) }
    var done by rememberSaveable { mutableStateOf<ResetChoice?>(null) }
    ResetScreen(
        confirming = confirming,
        done = done,
        onBack = onBack,
        onChoose = { confirming = it },
        onConfirm = { choice ->
            confirming = null
            LocalDataReset(AndroidResetEnvironment(context.applicationContext, hooks.resetHook)).perform(choice)
            if (LocalDataReset.needsRestart(choice)) {
                android.widget.Toast.makeText(context, context.getString(resetDoneRes(choice)), android.widget.Toast.LENGTH_SHORT).show()
                hooks.restart()
            } else {
                done = choice
            }
        },
    )
}

private fun resetDoneRes(choice: ResetChoice): Int = when (choice) {
    ResetChoice.ACTIVITY_AND_LOGS -> R.string.reset_done_activity
    ResetChoice.MODELS_AND_CACHES -> R.string.reset_done_caches
    ResetChoice.SETTINGS -> R.string.reset_done_settings
    ResetChoice.EVERYTHING -> R.string.reset_done_everything
}

/**
 * What's new, once after an update: a dialog, or for people who updated from before setup the
 * Home banner first ([onHome]: Home is showing). Nothing on a fresh install or while setup shows.
 */
@Composable
internal fun WhatsNewHost(hooks: SetupHooks, updater: AppUpdater, onHome: Boolean, setupShowing: Boolean, onReviewSetup: () -> Unit, openUrl: (String) -> Unit) {
    val installed = remember { AppVersion(updater.installedVersionName, updater.installedVersionCode) }
    val bundled = BundledNotes(stringResource(R.string.whats_new_bundled_for), stringResource(R.string.whats_new_bundled))
    val feedNotes by updater.installedNotes.collectAsStateWithLifecycle()
    val decision = remember {
        WhatsNewLogic.decide(installed, hooks.store.lastWhatsNew(), hooks.launch.freshInstall, hooks.launch.legacyUser, null, null)
    }
    var dialog by rememberSaveable { mutableStateOf(decision is WhatsNewDecision.Show && !decision.reviewSetup) }
    var handled by rememberSaveable { mutableStateOf(false) }
    val banner by hooks.store.bannerPending.collectAsStateWithLifecycle()
    LaunchedEffect(decision) {
        when (decision) {
            is WhatsNewDecision.None -> decision.record?.let(hooks.store::recordWhatsNew)
            is WhatsNewDecision.Show -> if (decision.reviewSetup) hooks.store.setBannerPending(true)
        }
    }
    val show = decision as? WhatsNewDecision.Show ?: return
    fun seen() {
        handled = true
        dialog = false
        hooks.store.recordWhatsNew(installed)
        hooks.store.setBannerPending(false)
    }
    if (handled || setupShowing) return
    if (show.reviewSetup && banner && onHome && !dialog) {
        WhatsNewBanner(onOpen = { dialog = true }, onDismiss = ::seen)
    }
    if (dialog) {
        WhatsNewDialog(
            version = installed.name,
            notes = WhatsNewLogic.notesFor(installed, feedNotes, bundled),
            reviewSetup = show.reviewSetup,
            onDismiss = ::seen,
            onReviewSetup = {
                seen()
                onReviewSetup()
            },
            onOpenNotes = { openUrl(dev.bridgey.android.ui.RELEASES_URL) },
        )
    }
}
