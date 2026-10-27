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
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import dev.bridgey.android.setup.SetupChoicesSync
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupLaunch
import dev.bridgey.android.setup.SetupScreen
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
    /** Where the next Route.Setup starts: Welcome, or the advanced path at Devices (Review setup). */
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

private val SetupStateSaver = Saver<SetupState, String>(save = { it.encode() }, restore = { SetupState.decode(it) })

/**
 * Route.Setup: first-run setup, or Run setup again. Settings changed here are the real settings.
 * [onFinish] marks setup done; `true` opens Settings instead of Home.
 */
@Composable
internal fun SetupRoute(
    hooks: SetupHooks,
    settings: SettingsState,
    actions: SettingsActions,
    pairedNames: List<String>,
    nearby: List<SetupNearbyMac>,
    onPair: (SetupNearbyMac) -> Unit,
    onAddDevice: () -> Unit,
    onLookForDevices: () -> Unit,
    onOpenNotificationAccess: () -> Unit,
    onOpenSection: (SettingsSection) -> Unit,
    onFinish: (openSettings: Boolean) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    var flow by rememberSaveable(stateSaver = SetupStateSaver) { mutableStateOf(hooks.takeStart()) }
    val rerun = remember { hooks.rerun }
    BackHandler(enabled = flow.screen != SetupScreen.Welcome) { flow = SetupFlow.reduce(flow, SetupEvent.Back) }
    fun finish(openSettings: Boolean) {
        hooks.store.recordSkipped(flow.skipped)
        // Settings sync hook (deferred): a later sync can offer these choices to the other device.
        SetupChoicesSync.offer(flow.choices)
        onFinish(openSettings)
    }
    SetupScreen(
        SetupUiState(flow, settings.copy(setup = settings.setup.copy(oem = hooks.oem)), pairedNames, nearby, hooks.oem, rerun),
        SetupActions(
            event = { flow = SetupFlow.reduce(flow, it) },
            settings = actions,
            pair = onPair,
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
            openSection = onOpenSection,
            openSettings = { finish(openSettings = true) },
            start = { finish(openSettings = false) },
            exit = onExit,
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
        if (PhotoPermissions.access(context) == PhotoAccess.FULL) add(PermissionKind.PHOTOS)
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
            PermissionKind.PHOTOS -> if (allowed) start(appDetails) else actions.setScreenshotSend(true)
            PermissionKind.COMPANION_LINK -> onOpenSection(SettingsSection.NOTIFICATIONS)
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
