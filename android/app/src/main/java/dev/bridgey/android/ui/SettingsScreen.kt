package dev.bridgey.android.ui

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.needsDeviceGrant
import dev.bridgey.android.LoggingPolicy
import dev.bridgey.android.R
import dev.bridgey.android.ReleaseNotesList
import dev.bridgey.android.UpdateCardPhase
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateFeeds
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.VersionNames
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop
import dev.bridgey.android.updateCardPhase
import dev.bridgey.android.updateErrorText
import dev.bridgey.android.ui.search.settingsSearchScroll
import dev.bridgey.android.ui.search.settingsSearchHighlight

data class SettingsState(
    val deviceName: String,
    val connectionStatus: String,
    val connected: Boolean,
    val pairedCount: Int,
    val globalFeatures: Map<BridgeyFeature, Boolean>,
    val directCallsEnabled: Boolean,
    val autoClipboardEnabled: Boolean,
    val backgroundClipboardEnabled: Boolean,
    val backgroundClipboardStatus: dev.bridgey.android.BackgroundClipboardStatus,
    val backgroundClipboardCommand: String,
    /** Clipboard > Copy images and files. */
    val clipboardFilesEnabled: Boolean = true,
    /** Clipboard > Send right away up to, in bytes; 0 is "Always ask when pasting". */
    val clipboardEagerLimit: Long = dev.bridgey.android.ClipLimits.DEFAULT_EAGER_LIMIT,
    /** Clipboard > Send a fresh screenshot. */
    val screenshotSendEnabled: Boolean = true,
    val tileAddSupported: Boolean,
    val tileAdded: Boolean,
    val notificationAppsEnabled: Int,
    val notificationAppsTotal: Int,
    val appNotificationsEnabled: Boolean,
    val notificationAccessEnabled: Boolean,
    val reduceMotion: Boolean,
    val showPreviews: Boolean,
    val activityCount: Int,
    /** Privacy > Logging. */
    val logging: LoggingPolicy = LoggingPolicy(),
    val update: UpdateUiState,
    val installedVersion: String,
    val now: Long,
    /** Remote control: pointer speed (1 to 5) and the volume keys for slides. */
    val remotePointerSpeed: Int = 3,
    val remoteVolumeKeys: Boolean = false,
    /** Bridgey is exempt from battery optimisation, so Doze does not pause its connection. */
    val batteryExempt: Boolean = true,
    /** Keep Wi-Fi awake is offered (Android 13 and older, where a Wi-Fi lock works with the screen off). */
    val keepWifiAwakeSupported: Boolean = false,
    val keepWifiAwake: Boolean = false,
    /** Files: folders sent to this phone, default folder, conflicts, Replace from other devices, places. */
    val folders: FolderSettingsState = FolderSettingsState(),
    /** Notifications > Codes from messages: code access and the companion link. */
    val codes: CodesSettingsState = CodesSettingsState(),
    /** v0.10: OEM checklist (General). */
    val setup: SetupSettingsState = SetupSettingsState(),
    /** Notifications > Focus sync with the Macs. */
    val focus: FocusSettingsState = FocusSettingsState(),
    /** Settings sync: the switches, and what each synced row says about the other devices. */
    val sync: dev.bridgey.android.sync.SyncUiState = dev.bridgey.android.sync.SyncUiState(),
    /** Updates > Your devices and Update all. */
    val updateAll: UpdateAllUiState = UpdateAllUiState(),
    /** Text messages: permissions and how replies are sent. */
    val messages: MessagesSettingsState = MessagesSettingsState(),
    /** Calls > Calls window: permissions, Ask on this phone first and the Macs allowed. */
    val dialer: DialerSettingsState = DialerSettingsState(),
    /** Connect away from home (Connect anywhere). */
    val connect: ConnectSettingsState = ConnectSettingsState(),
    /** External Tailscale package availability; never sign-in or VPN connection state. */
    val tailscale: dev.bridgey.android.tailscale.TailscaleSetupState = dev.bridgey.android.tailscale.TailscaleSetupState(),
    /** The hidden Developer and experimental menu is on (DeveloperMenu.kt); never synced. */
    val developerMenu: Boolean = false,
    val shareAlwaysAsk: Boolean = false,
    /** Developer menu > Transfers: how files travel to each connected device. */
    val transferPaths: List<dev.bridgey.android.TransferPath> = emptyList(),
    val callQuiet: CallQuietSettingsState = CallQuietSettingsState(),
    val smartRouting: SmartRoutingSettingsState = SmartRoutingSettingsState(),
    /** The installed build number (versionCode), shown next to the version in About. */
    val installedBuild: Long = 0,
    /** Remote control > Let Macs control this phone: Bridgey control and each Mac's choice. */
    val phoneControl: PhoneControlSettingsState = PhoneControlSettingsState(),
    /** Devices > Paired devices: every paired device and agent, with its ring. */
    val rings: List<DeviceRing> = emptyList(),
    val rediscovering: Boolean = false,
    /** Paired devices (not agents) for the cards' Devices chips. */
    val devices: List<SettingsDevice> = emptyList(),
) {
    fun featureOn(feature: BridgeyFeature): Boolean =
        if (feature.needsDeviceGrant) globalFeatures[feature] == true else globalFeatures[feature] != false
}

class SettingsActions(
    val back: () -> Unit = {},
    /** Settings home: open Settings search. */
    val openSearch: () -> Unit = {},
    /** Settings home: open a group's page. */
    val openGroup: (SettingsGroup) -> Unit = {},
    /** Opens a section's group at its card (setup's links, permission prompts). */
    val openSection: (SettingsSection) -> Unit = {},
    /** Devices > Paired devices. */
    val openDevice: (DeviceRing) -> Unit = {},
    val addDevice: () -> Unit = {},
    val lookForDevices: () -> Unit = {},
    /** A Devices chip: the feature (or Find and ping together) on or off for one device, as the device page's switch did. */
    val setDeviceFeature: (String, List<BridgeyFeature>, Boolean) -> Unit = { _, _, _ -> },
    /** Clipboard > More options > Automatic clipboard for one device. */
    val setDeviceAutoClipboard: (String, Boolean) -> Unit = { _, _ -> },
    /** Sync settings > Devices: sync with one device. */
    val setDeviceSync: (String, Boolean) -> Unit = { _, _ -> },
    val openNotificationApps: () -> Unit = {},
    val smartRouting: SmartRoutingSettingsActions = SmartRoutingSettingsActions(),
    val appNotifications: () -> Unit = {},
    val notificationAccess: () -> Unit = {},
    val rename: (String) -> Unit = {},
    val setGlobal: (BridgeyFeature, Boolean) -> Unit = { _, _ -> },
    val setDirectCalls: (Boolean) -> Unit = {},
    val setAutoClipboard: (Boolean) -> Unit = {},
    val setBackgroundClipboard: (Boolean) -> Unit = {},
    val setClipboardFiles: (Boolean) -> Unit = {},
    val setClipboardEagerLimit: (Long) -> Unit = {},
    val setScreenshotSend: (Boolean) -> Unit = {},
    val setShareAlwaysAsk: (Boolean) -> Unit = {},
    val copyCommand: () -> Unit = {},
    val addTile: () -> Unit = {},
    val setReduceMotion: (Boolean) -> Unit = {},
    val setShowPreviews: (Boolean) -> Unit = {},
    val clearActivity: () -> Unit = {},
    val exportDiagnostics: () -> Unit = {},
    val setLogging: (LoggingPolicy) -> Unit = {},
    val clearLogs: () -> Unit = {},
    val turnOff: () -> Unit = {},
    val checkNow: () -> Unit = {},
    val setChannel: (UpdateChannel) -> Unit = {},
    val install: () -> Unit = {},
    val laterUpdate: () -> Unit = {},
    val skipUpdate: () -> Unit = {},
    val showUpdate: () -> Unit = {},
    val dismissUpdateError: () -> Unit = {},
    val openUrl: (String) -> Unit = {},
    val openPerfTest: () -> Unit = {},
    /** Developer and experimental > Transfer speed. */
    val openSpeedTest: () -> Unit = {},
    /** About > Version: counts toward the Developer and experimental menu, or opens it once on. */
    val versionTapped: () -> Unit = {},
    /** Developer and experimental > Turn off. */
    val turnOffDeveloper: () -> Unit = {},
    val setRemotePointerSpeed: (Int) -> Unit = {},
    val setRemoteVolumeKeys: (Boolean) -> Unit = {},
    val requestBatteryExemption: () -> Unit = {},
    val openBatterySettings: () -> Unit = {},
    val setKeepWifiAwake: (Boolean) -> Unit = {},
    val folders: FolderSettingsActions = FolderSettingsActions(),
    val codes: CodesSettingsActions = CodesSettingsActions(),
    /** v0.10: Permissions, Reset, Run setup again, OEM steps, Obtainium. */
    val setup: SetupSettingsActions = SetupSettingsActions(),
    val focus: FocusSettingsActions = FocusSettingsActions(),
    val sync: SyncSettingsActions = SyncSettingsActions(),
    val updateAll: UpdateAllActions = UpdateAllActions(),
    val messages: MessagesSettingsActions = MessagesSettingsActions(),
    val dialer: DialerSettingsActions = DialerSettingsActions(),
    val connect: ConnectSettingsActions = ConnectSettingsActions(),
    val tailscale: dev.bridgey.android.tailscale.TailscaleSetupActions = dev.bridgey.android.tailscale.TailscaleSetupActions(),
    val callQuiet: CallQuietSettingsActions = CallQuietSettingsActions(),
    val phoneControl: PhoneControlSettingsActions = PhoneControlSettingsActions(),
)

const val UPSTREAM_URL = "https://github.com/singeol/bridgey"

/**
 * The Settings pages before the six groups (26 Nov 2026), kept as names for the places that open one: deep links (the
 * update notification opens UPDATES), setup's links and permission prompts. Each opens its group at [card], scrolled to
 * the row titled [anchorRes] (the card's header switch, or its first row). A unit test pins that every section has one.
 */
enum class SettingsSection(
    val card: SettingsCard,
    @androidx.annotation.StringRes val anchorRes: Int?,
    /** The section's name, as setup's bundles and switches say it. */
    @androidx.annotation.StringRes val titleRes: Int,
) {
    THIS_PHONE(SettingsCard.THIS_PHONE, R.string.settings_this_phone, R.string.settings_this_phone),
    DEVICES(SettingsCard.PAIRED, null, R.string.settings_devices),
    AWAY(SettingsCard.AWAY, R.string.settings_connect_away, R.string.settings_connect_away),
    CLIPBOARD(SettingsCard.CLIPBOARD, R.string.feature_clipboard, R.string.feature_clipboard),
    NOTIFICATIONS(SettingsCard.NOTIFICATIONS, R.string.settings_forwarding_title, R.string.settings_notifications),
    MESSAGES(SettingsCard.MESSAGES, R.string.feature_sms, R.string.feature_sms),
    CALLS(SettingsCard.CALLS, R.string.feature_calls, R.string.feature_calls),
    FILES(SettingsCard.FILES, R.string.feature_files, R.string.feature_files),
    MEDIA(SettingsCard.MEDIA, R.string.feature_media, R.string.settings_media),
    REMOTE_CONTROL(SettingsCard.REMOTE, R.string.feature_remote_input, R.string.settings_remote_control),
    PRIVACY(SettingsCard.ACTIVITY, R.string.settings_show_previews, R.string.settings_privacy),
    UPDATES(SettingsCard.UPDATES, R.string.settings_search_check_updates, R.string.settings_updates),
    GENERAL(SettingsCard.GENERAL, R.string.settings_background_title, R.string.settings_general),
    ABOUT(SettingsCard.ABOUT, R.string.settings_version, R.string.settings_about),
    /** Hidden until the version is tapped five times (DeveloperMenu.kt); then the last card of App. */
    DEVELOPER(SettingsCard.DEVELOPER, R.string.settings_speed_test, R.string.settings_developer),
    ;

    val group: SettingsGroup get() = card.group

    /** False for a page whose feature this build leaves out (the Play build: Text messages, Updates). */
    val built: Boolean get() = when (this) {
        MESSAGES -> dev.bridgey.android.BuildGates.sms
        UPDATES -> dev.bridgey.android.BuildGates.selfUpdate
        else -> true
    }
}

/** Light mode band behind the page bar: status bar + 56 dp + 8 dp. */
private val PageBandHeight = 64.dp

/** A pushed settings page: page bar on the band, then a list. */
@Composable
fun SettingsPage(
    title: String,
    onBack: () -> Unit,
    listState: LazyListState = rememberLazyListState(),
    actions: @Composable RowScope.() -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    ScreenBackdrop(bandHeight = statusTop + PageBandHeight) {
        Column(Modifier.fillMaxSize()) {
            OnBand { PageBar(title, onBack, actions) }
            LazyColumn(
                Modifier.fillMaxSize().settingsSearchScroll(listState),
                state = listState,
                contentPadding = PaddingValues(bottom = navBottom + 32.dp),
                content = content,
            )
        }
    }
}

/**
 * Settings. With no [group], the home: search at the top, then the six groups, each with a live summary. With a
 * [group], that group's page of cards (SettingsGroupPages.kt). Pushed pages, not tabs; the stream is the whole app.
 */
@Composable
fun SettingsScreen(
    state: SettingsState,
    actions: SettingsActions,
    listState: LazyListState = rememberLazyListState(),
    group: SettingsGroup? = null,
    /** Starts on this section's group at its card, with its More options open (tests and screenshots). */
    section: SettingsSection? = null,
) {
    val shown = group ?: section?.group
    if (shown == null) SettingsHome(state, actions, listState) else SettingsGroupPage(shown, state, actions, listState, section?.card)
}

/** Settings home: the search field, then one row per group. */
@Composable
private fun SettingsHome(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SettingsPage(stringResource(R.string.settings_title), actions.back, listState) {
        item(key = "search") { SearchField(actions.openSearch, Modifier.padding(top = 16.dp)) }
        item(key = "groups") {
            RowGroup(Modifier.padding(top = 16.dp)) {
                SettingsGroup.entries.forEach { group ->
                    row { shape -> GroupRow(shape, group, state) { actions.openGroup(group) } }
                }
            }
        }
    }
}

/** Looks like a search field and opens Settings search, where the typing happens. */
@Composable
private fun SearchField(open: () -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    val label = stringResource(R.string.settings_search_open)
    Row(
        modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(colors.surface1)
            .border(1.dp, colors.outline, RoundedCornerShape(28.dp))
            .clickable(role = Role.Button, onClickLabel = label, onClick = open)
            .semantics(mergeDescendants = true) { contentDescription = label }
            .padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(BridgeyIcons.Search, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(22.dp))
        Text(label, style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
    }
}

/** A home row: the group's icon, title and summary; the update dot on App when an update is ready. */
@Composable
private fun GroupRow(shape: androidx.compose.ui.graphics.Shape, group: SettingsGroup, state: SettingsState, onClick: () -> Unit) {
    val summary = groupSummary(group, state)
    ListRow(
        shape, stringResource(group.titleRes), summary.text, group.icon(), group.tint,
        detailWarning = summary.warning, onClick = onClick,
        // A way to a page, not a setting: search finds the page's own rows.
        searchable = false,
    ) {
        if (summary.badge) UpdateDot()
        Chevron()
    }
}

/** What a home row says under its title, and whether it warns or carries the update dot. */
private data class SectionSummary(val text: String, val warning: Boolean = false, val badge: Boolean = false)

/** The home row's summary: what the group holds, or the one thing in it that needs attention. */
@Composable
private fun groupSummary(group: SettingsGroup, state: SettingsState): SectionSummary = when (group) {
    SettingsGroup.DEVICES -> {
        val paired = androidx.compose.ui.res.pluralStringResource(R.plurals.settings_group_devices_paired, state.pairedCount, state.pairedCount)
        SectionSummary(if (state.connect.on) stringResource(R.string.settings_group_devices_away, paired) else paired)
    }
    SettingsGroup.SHARING -> SectionSummary(stringResource(R.string.settings_group_sharing_summary))
    SettingsGroup.PHONE -> if (state.featureOn(BridgeyFeature.NOTIFICATIONS) && !state.notificationAccessEnabled) {
        SectionSummary(stringResource(R.string.settings_summary_notifications_access), warning = true)
    } else {
        SectionSummary(stringResource(R.string.settings_group_phone_summary))
    }
    // Macs can see and control this phone without asking: say so on the group's row.
    SettingsGroup.CONTROL -> SectionSummary(
        stringResource(if (state.phoneControl.built && state.phoneControl.unattended) R.string.settings_summary_unattended else R.string.settings_group_control_summary),
    )
    SettingsGroup.PRIVACY -> SectionSummary(stringResource(R.string.settings_group_privacy_summary))
    SettingsGroup.APP -> {
        val updates = if (dev.bridgey.android.BuildGates.selfUpdate) updatesSummary(state) else null
        when {
            !state.batteryExempt -> SectionSummary(stringResource(R.string.settings_summary_general_battery), warning = true)
            updates != null && (updates.badge || updates.warning) -> updates
            else -> SectionSummary(stringResource(R.string.settings_group_app_summary))
        }
    }
}



/** Devices > This phone: this phone's ring, name and connection. Tap to rename. */
@Composable
internal fun ThisPhoneCard(state: SettingsState, onRename: () -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Row(
        modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(colors.surface1)
            .settingsSearchHighlight(stringResource(R.string.settings_this_phone), RoundedCornerShape(24.dp))
            .clickable(onClickLabel = stringResource(R.string.action_rename), role = Role.Button, onClick = onRename)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        DeviceGlyph(if (state.connected) RingStyle.SAME_WIFI else RingStyle.OFFLINE, BridgeyIcons.Smartphone, 48.dp, iconSize = 22.dp)
        Column(Modifier.weight(1f)) {
            Text(state.deviceName, style = BridgeyType.rowTitle, color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                state.connectionStatus,
                style = BridgeyType.itemBody,
                color = if (state.connected) colors.onTintGreen else colors.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 1.dp),
            )
        }
        Icon(BridgeyIcons.Edit, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(20.dp))
    }
}


/** "Beta · up to date", "Beta · 0.6.1 is ready" (with the dot), "Beta · downloading". */
@Composable
private fun updatesSummary(state: SettingsState): SectionSummary {
    val channel = channelTitle(state.update.channel)
    val words = versionWords()
    val short = { version: String -> VersionNames.short(version, state.installedVersion, words) }
    val phase = updateCardPhase(state.update)
    val (status, warning) = when (phase) {
        is UpdateCardPhase.Current -> stringResource(
            if (phase.lastCheckedAt > 0) R.string.settings_summary_updates_current else R.string.settings_summary_updates_not_checked,
        ) to false
        is UpdateCardPhase.Skipped -> stringResource(R.string.settings_summary_updates_current) to false
        UpdateCardPhase.Checking -> stringResource(R.string.settings_summary_updates_checking) to false
        is UpdateCardPhase.Available -> stringResource(R.string.settings_summary_updates_ready, short(phase.update.versionName)) to false
        is UpdateCardPhase.Waiting -> stringResource(R.string.settings_summary_updates_ready, short(phase.update.versionName)) to false
        is UpdateCardPhase.Confirming -> stringResource(R.string.settings_summary_updates_ready, short(phase.update.versionName)) to false
        is UpdateCardPhase.Downloading -> stringResource(R.string.settings_summary_updates_downloading) to false
        is UpdateCardPhase.Failed -> stringResource(R.string.settings_summary_updates_failed) to true
        is UpdateCardPhase.Installing -> stringResource(R.string.settings_summary_updates_ready, short(phase.update.versionName)) to false
        is UpdateCardPhase.Ready -> stringResource(R.string.settings_summary_updates_ready, short(phase.update.versionName)) to false
        is UpdateCardPhase.NotApplied -> stringResource(R.string.settings_summary_updates_failed) to true
    }
    val ready = phase is UpdateCardPhase.Available || phase is UpdateCardPhase.Waiting || phase is UpdateCardPhase.Confirming ||
        phase is UpdateCardPhase.Ready || phase is UpdateCardPhase.Installing
    return SectionSummary(stringResource(R.string.settings_summary_dot, channel, status), warning = warning, badge = ready)
}

/** The Updates row's "update ready" dot. */
@Composable
private fun UpdateDot() {
    val label = stringResource(R.string.settings_summary_update_dot)
    Box(
        Modifier
            .size(10.dp)
            .clip(androidx.compose.foundation.shape.CircleShape)
            .background(BridgeyTheme.colors.primary)
            .semantics { contentDescription = label },
    )
}

@Composable
private fun eagerLimitLabel(bytes: Long): String = stringResource(
    when (bytes) {
        5_000_000L -> R.string.clipboard_eager_5
        100_000_000L -> R.string.clipboard_eager_100
        0L -> R.string.clipboard_eager_ask
        else -> R.string.clipboard_eager_25
    },
)

/** Send right away up to: the current choice as the detail, the four choices in a menu. */
@Composable
internal fun EagerLimitRow(shape: androidx.compose.ui.graphics.Shape, state: SettingsState, actions: SettingsActions) {
    val colors = BridgeyTheme.colors
    var open by remember { mutableStateOf(false) }
    val enabled = state.clipboardFilesEnabled
    Box {
        ListRow(
            shape, stringResource(R.string.clipboard_eager_title), eagerLimitLabel(state.clipboardEagerLimit),
            BridgeyIcons.Bolt, if (enabled) Tint.BLUE else Tint.NEUTRAL,
            onClick = if (enabled) ({ open = true }) else null,
            role = Role.DropdownList,
        ) {
            Icon(BridgeyIcons.ArrowDropDown, null, tint = if (enabled) colors.onSurfaceVariant else colors.outline, modifier = Modifier.size(24.dp))
        }
        androidx.compose.material3.DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            containerColor = colors.surface2,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Text(
                stringResource(R.string.clipboard_eager_detail),
                style = BridgeyType.small,
                color = colors.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
            dev.bridgey.android.ClipLimits.EAGER_LIMIT_CHOICES.forEach { choice ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(eagerLimitLabel(choice), style = BridgeyType.label, color = colors.onSurface) },
                    trailingIcon = if (choice == state.clipboardEagerLimit) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                    onClick = {
                        open = false
                        actions.setClipboardEagerLimit(choice)
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                )
            }
        }
    }
}

@Composable
private fun pointerSpeedLabel(level: Int): String = stringResource(
    when (level) {
        1 -> R.string.remote_speed_1
        2 -> R.string.remote_speed_2
        4 -> R.string.remote_speed_4
        5 -> R.string.remote_speed_5
        else -> R.string.remote_speed_3
    },
)

/** Pointer speed: the current choice as the detail, five choices in a menu. */
@Composable
internal fun PointerSpeedRow(shape: androidx.compose.ui.graphics.Shape, state: SettingsState, actions: SettingsActions) {
    val colors = BridgeyTheme.colors
    var open by remember { mutableStateOf(false) }
    Box {
        ListRow(
            shape, stringResource(R.string.remote_speed_title), pointerSpeedLabel(state.remotePointerSpeed),
            BridgeyIcons.Mouse, Tint.PURPLE, onClick = { open = true }, role = Role.DropdownList,
        ) {
            Icon(BridgeyIcons.ArrowDropDown, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(24.dp))
        }
        androidx.compose.material3.DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            containerColor = colors.surface2,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            dev.bridgey.android.remote.RemotePreferencesState.POINTER_SPEEDS.forEach { level ->
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text(pointerSpeedLabel(level), style = BridgeyType.label, color = colors.onSurface) },
                    trailingIcon = if (level == state.remotePointerSpeed) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                    onClick = {
                        open = false
                        actions.setRemotePointerSpeed(level)
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                )
            }
        }
    }
}


/** Find and Ping are separate switches in Settings, so they take their own titles. */
@Composable
internal fun featureSettingTitle(feature: BridgeyFeature): String = when (feature) {
    BridgeyFeature.FIND_DEVICE -> stringResource(R.string.feature_find)
    BridgeyFeature.PING -> stringResource(R.string.feature_ping)
    else -> permissionTitle(feature)
}

/** The generic, non device-specific description for a feature's global switch. */
@Composable
internal fun globalFeatureDetail(feature: BridgeyFeature): String = stringResource(
    when (feature) {
        BridgeyFeature.CLIPBOARD -> R.string.feature_clipboard_detail
        BridgeyFeature.FILES -> R.string.feature_files_detail
        BridgeyFeature.NOTIFICATIONS -> R.string.settings_notifications_detail
        BridgeyFeature.CALLS -> R.string.settings_calls_detail
        BridgeyFeature.MEDIA -> R.string.settings_media_detail
        BridgeyFeature.FIND_DEVICE -> R.string.settings_find_detail
        BridgeyFeature.PING -> R.string.settings_ping_detail
        BridgeyFeature.LINKS -> R.string.feature_links_detail
        BridgeyFeature.BATTERY -> R.string.settings_battery_detail
        BridgeyFeature.REMOTE_INPUT -> R.string.settings_remote_detail
        BridgeyFeature.MAC_ACTIONS -> R.string.settings_mac_actions_detail
        BridgeyFeature.CAMERA -> R.string.settings_camera_detail
        BridgeyFeature.SCREEN -> R.string.settings_screen_detail
        BridgeyFeature.SMS -> R.string.feature_sms_detail
        BridgeyFeature.CALL_QUIET -> R.string.call_quiet_detail
        BridgeyFeature.DIALER -> R.string.dialer_detail
        BridgeyFeature.SCREEN_CONTROL -> R.string.settings_screen_control_detail
    },
)


/** The one-time setup for the optional background clipboard: a status line, and the steps when not ready. */
@Composable
internal fun BackgroundClipboardCard(state: SettingsState, actions: SettingsActions) {
    val colors = BridgeyTheme.colors
    val status = state.backgroundClipboardStatus
    val (statusText, statusIcon, statusTint) = when (status) {
        dev.bridgey.android.BackgroundClipboardStatus.READY -> Triple(stringResource(R.string.bg_clipboard_status_ready), BridgeyIcons.Check, Tint.GREEN)
        dev.bridgey.android.BackgroundClipboardStatus.DENIED -> Triple(stringResource(R.string.bg_clipboard_status_denied), BridgeyIcons.Error, Tint.NEUTRAL)
        else -> Triple(stringResource(R.string.bg_clipboard_status_waiting), BridgeyIcons.DeveloperMode, Tint.NEUTRAL)
    }
    Column(
        Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.surface1).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        StatusPill(statusText, statusIcon, statusTint)
        if (status != dev.bridgey.android.BackgroundClipboardStatus.READY) {
            SetupStep(1, stringResource(R.string.bg_clipboard_step1))
            SetupStep(2, stringResource(R.string.bg_clipboard_step2))
            SetupStep(3, stringResource(R.string.bg_clipboard_step3))
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colors.surface2).padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    state.backgroundClipboardCommand,
                    style = BridgeyType.small.copy(fontFamily = FontFamily.Monospace),
                    color = colors.onSurface,
                    modifier = Modifier.weight(1f),
                )
                OutlinePillButton(stringResource(R.string.action_copy), BridgeyIcons.ContentPaste, actions.copyCommand)
            }
            SetupStep(4, stringResource(R.string.bg_clipboard_step4))
        }
    }
}

@Composable
private fun SetupStep(number: Int, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("$number.", style = BridgeyType.itemBody.copy(fontWeight = BridgeyType.label.fontWeight), color = BridgeyTheme.colors.primary)
        Text(text, style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant)
    }
}

@Composable
internal fun Chevron() = Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)

@Composable
internal fun ManageLabel(enabled: Boolean) {
    Text(
        stringResource(if (enabled) R.string.action_manage else R.string.action_enable),
        style = BridgeyType.label,
        color = BridgeyTheme.colors.primary,
    )
}

@Composable
internal fun RenameDialog(current: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var name by rememberSaveable { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.settings_device_name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.rename_body))
                OutlinedTextField(value = name, onValueChange = { name = it.take(64) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(name) }, enabled = name.trim().isNotEmpty() && name.trim() != current) {
                Text(stringResource(R.string.action_save))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}

@Composable
fun channelTitle(channel: UpdateChannel): String = stringResource(
    when (channel) {
        UpdateChannel.STABLE -> R.string.channel_stable
        UpdateChannel.BETA -> R.string.channel_beta
        UpdateChannel.NIGHTLY -> R.string.channel_nightly
    },
)

@Composable
private fun channelDescription(channel: UpdateChannel): String = stringResource(
    when (channel) {
        UpdateChannel.STABLE -> R.string.channel_stable_detail
        UpdateChannel.BETA -> R.string.channel_beta_detail
        UpdateChannel.NIGHTLY -> R.string.channel_nightly_detail
    },
)

/**
 * App > Updates: one status row that shows one state at a time, then the channel and Update all devices automatically
 * (how often it checks, what it waits for). The version appears once, in the status row.
 */
internal fun GroupScope.updatesRows(
    state: UpdateUiState,
    installedVersion: String,
    now: Long,
    actions: SettingsActions,
    auto: dev.bridgey.android.updates.AutoUpdateView = dev.bridgey.android.updates.AutoUpdateView(),
) {
    row { shape ->
        UpdateStatusCard(
            updateCardPhase(state), installedVersion, now, actions,
            Modifier.fillMaxWidth().clip(shape).background(BridgeyTheme.colors.surface1)
                .settingsSearchHighlight(stringResource(R.string.settings_search_check_updates), shape)
                .padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 16.dp),
        )
    }
    row { shape ->
        val colors = BridgeyTheme.colors
        Column(
            Modifier.fillMaxWidth().clip(shape).background(colors.surface1)
                .settingsSearchHighlight(stringResource(R.string.updates_channel), shape).padding(horizontal = 16.dp, vertical = 16.dp),
        ) {
            Text(stringResource(R.string.updates_channel), style = BridgeyType.itemTitle, modifier = Modifier.semantics { heading() })
            ChannelPicker(state.channel, actions.setChannel, Modifier.padding(top = 10.dp))
            Text(channelDescription(state.channel), style = BridgeyType.itemBody, color = colors.onSurface, modifier = Modifier.padding(top = 10.dp))
            Text(stringResource(R.string.updates_channel_note), style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp))
            Box(Modifier.padding(vertical = 14.dp).fillMaxWidth().height(1.dp).background(colors.outlineVariant))
            AutoUpdateSettings(auto, now, actions.updateAll.setAuto)
        }
    }
}

@Composable
private fun UpdateStatusCard(phase: UpdateCardPhase, installedVersion: String, now: Long, actions: SettingsActions, modifier: Modifier) {
    val colors = BridgeyTheme.colors
    val context = LocalContext.current
    val words = versionWords()
    val short = { version: String -> VersionNames.short(version, installedVersion, words) }
    val label = { version: String -> VersionNames.label(version, words) }
    val title = when (phase) {
        is UpdateCardPhase.Current, is UpdateCardPhase.Waiting, is UpdateCardPhase.Skipped -> stringResource(R.string.updates_current, label(installedVersion))
        UpdateCardPhase.Checking -> stringResource(R.string.updates_checking)
        is UpdateCardPhase.Available -> stringResource(R.string.updates_is_ready, label(phase.update.versionName))
        is UpdateCardPhase.Confirming -> stringResource(R.string.updates_is_ready, label(phase.update.versionName))
        is UpdateCardPhase.Downloading -> stringResource(R.string.updates_downloading, label(phase.update.versionName))
        is UpdateCardPhase.Failed -> stringResource(R.string.updates_failed)
        is UpdateCardPhase.Ready -> stringResource(R.string.updates_is_ready, label(phase.update.versionName))
        is UpdateCardPhase.Installing -> stringResource(R.string.updates_installing, label(phase.update.versionName))
        is UpdateCardPhase.NotApplied -> stringResource(R.string.updates_not_applied_title)
    }
    val detail: String? = when (phase) {
        is UpdateCardPhase.Current -> if (phase.lastCheckedAt > 0) {
            stringResource(R.string.updates_up_to_date_checked, checkedText(context, phase.lastCheckedAt, now))
        } else {
            stringResource(R.string.updates_not_checked)
        }
        is UpdateCardPhase.Waiting -> stringResource(R.string.updates_waiting, short(phase.update.versionName))
        is UpdateCardPhase.Skipped -> stringResource(R.string.updates_skipped, short(phase.versionName))
        UpdateCardPhase.Checking -> null
        is UpdateCardPhase.Available -> stringResource(R.string.updates_you_have, VersionNames.short(installedVersion, phase.update.versionName, words))
        is UpdateCardPhase.Confirming -> stringResource(R.string.updates_confirm)
        is UpdateCardPhase.Downloading -> stringResource(
            R.string.updates_downloading_detail,
            Formatter.formatShortFileSize(context, (phase.update.size * phase.progress.coerceIn(0f, 1f)).toLong()),
            Formatter.formatShortFileSize(context, phase.update.size),
        )
        is UpdateCardPhase.Failed -> updateErrorText(phase.error)
        is UpdateCardPhase.Ready -> stringResource(R.string.updates_ready_detail)
        is UpdateCardPhase.Installing -> stringResource(R.string.updates_installing_detail)
        is UpdateCardPhase.NotApplied -> stringResource(R.string.updates_not_applied_detail, label(phase.versionName), label(installedVersion))
    }
    val (icon, tint) = when (phase) {
        is UpdateCardPhase.Current -> if (phase.lastCheckedAt > 0) BridgeyIcons.CheckCircle to Tint.GREEN else BridgeyIcons.Refresh to Tint.NEUTRAL
        is UpdateCardPhase.Skipped, UpdateCardPhase.Checking -> BridgeyIcons.Refresh to Tint.NEUTRAL
        is UpdateCardPhase.Failed, is UpdateCardPhase.NotApplied -> BridgeyIcons.Error to Tint.NEUTRAL
        is UpdateCardPhase.Confirming, is UpdateCardPhase.Ready, is UpdateCardPhase.Installing -> BridgeyIcons.Update to Tint.GREEN
        else -> BridgeyIcons.Download to Tint.PURPLE
    }
    Column(modifier) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            IconTile(icon, tint, size = 40.dp, corner = 14.dp, iconSize = 22.dp)
            Column(Modifier.weight(1f).padding(start = 12.dp, end = 12.dp)) {
                Text(title, style = BridgeyType.itemTitle, color = colors.onSurface)
                if (detail != null) {
                    Text(detail, style = BridgeyType.itemBody, color = if (phase is UpdateCardPhase.Failed || phase is UpdateCardPhase.NotApplied) colors.warn else colors.onSurfaceVariant)
                }
            }
            if (phase is UpdateCardPhase.Available) {
                Box {
                    var menu by remember { mutableStateOf(false) }
                    BarIconButton(BridgeyIcons.MoreVert, stringResource(R.string.updates_more), { menu = true })
                    DropdownMenu(
                        expanded = menu,
                        onDismissRequest = { menu = false },
                        containerColor = colors.surface2,
                        shape = RoundedCornerShape(16.dp),
                    ) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.updates_skip)) },
                            onClick = {
                                menu = false
                                actions.skipUpdate()
                            },
                        )
                    }
                }
            } else {
                Spacer(Modifier.width(12.dp))
            }
        }
        val inset = Modifier.padding(start = 52.dp, end = 12.dp)
        when (phase) {
            is UpdateCardPhase.Downloading -> LinearProgressIndicator(
                progress = { phase.progress },
                modifier = inset.padding(top = 12.dp).fillMaxWidth().height(6.dp),
                color = colors.primary,
                trackColor = colors.surface3,
                strokeCap = StrokeCap.Round,
                drawStopIndicator = {},
            )
            is UpdateCardPhase.Available -> {
                val notesUrl = phase.update.notesUrl.takeIf { it.isNotEmpty() } ?: RELEASES_URL
                val link: @Composable RowScope.() -> Unit = {
                    Row(
                        Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button) { actions.openUrl(notesUrl) },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(stringResource(R.string.updates_full_notes), style = BridgeyType.smallStrong.copy(fontSize = BridgeyType.itemBody.fontSize), color = colors.primary)
                        Icon(BridgeyIcons.OpenInNew, null, tint = colors.primary, modifier = Modifier.size(14.dp))
                    }
                }
                if (phase.update.notes.isNotBlank()) {
                    ReleaseNotesList(phase.update.notes, phase.update.versionName, inset.padding(top = 12.dp), link)
                } else {
                    Row(inset, content = link)
                }
            }
            else -> Unit
        }
        val buttons = Modifier.fillMaxWidth().padding(top = 8.dp, end = 12.dp)
        when (phase) {
            is UpdateCardPhase.Current, is UpdateCardPhase.Skipped -> Row(buttons, horizontalArrangement = Arrangement.End) {
                OutlinePillButton(stringResource(R.string.updates_check_now), BridgeyIcons.Refresh, actions.checkNow)
            }
            is UpdateCardPhase.Waiting -> Row(buttons, horizontalArrangement = Arrangement.End) {
                TonalPillButton(stringResource(R.string.updates_show_update), actions.showUpdate)
            }
            is UpdateCardPhase.Available -> Row(buttons, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                OutlinePillButton(stringResource(R.string.updates_later), null, actions.laterUpdate)
                GradientButton(stringResource(R.string.updates_install), BridgeyIcons.Download, actions.install, height = 40.dp, textStyle = BridgeyType.label)
            }
            is UpdateCardPhase.Failed -> Row(buttons, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                OutlinePillButton(stringResource(R.string.action_dismiss), null, actions.dismissUpdateError)
                TonalPillButton(stringResource(R.string.action_retry), if (phase.retryInstalls) actions.install else actions.checkNow)
            }
            is UpdateCardPhase.Ready -> Row(buttons, horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                GradientButton(stringResource(R.string.updates_install), BridgeyIcons.Update, actions.install, height = 40.dp, textStyle = BridgeyType.label)
            }
            // Only the person tries a version that did not apply again.
            is UpdateCardPhase.NotApplied -> Row(buttons, horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                TonalPillButton(stringResource(R.string.action_retry), if (phase.canRetry) actions.install else actions.checkNow)
            }
            else -> Unit
        }
    }
}

/** "3:58 PM" on the day of [now], "24 Oct" before. */
private fun checkedText(context: android.content.Context, at: Long, now: Long): String =
    if (sameDay(at, now)) {
        DateUtils.formatDateTime(context, at, DateUtils.FORMAT_SHOW_TIME)
    } else {
        DateUtils.formatDateTime(context, at, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_NO_YEAR)
    }

private fun sameDay(a: Long, b: Long): Boolean {
    val first = java.util.Calendar.getInstance().apply { timeInMillis = a }
    val second = java.util.Calendar.getInstance().apply { timeInMillis = b }
    return first.get(java.util.Calendar.YEAR) == second.get(java.util.Calendar.YEAR) &&
        first.get(java.util.Calendar.DAY_OF_YEAR) == second.get(java.util.Calendar.DAY_OF_YEAR)
}

const val RELEASES_URL = "https://github.com/round-robin-solutions/bridgey/releases"

/** Stable, Beta, Nightly as one connected button group. */
@Composable
private fun ChannelPicker(selected: UpdateChannel, onSelect: (UpdateChannel) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    val channels = UpdateChannel.entries
    Row(modifier.fillMaxWidth().height(48.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        channels.forEachIndexed { index, channel ->
            val on = channel == selected
            val shape = when (index) {
                0 -> RoundedCornerShape(topStart = 24.dp, bottomStart = 24.dp, topEnd = 8.dp, bottomEnd = 8.dp)
                channels.lastIndex -> RoundedCornerShape(topStart = 8.dp, bottomStart = 8.dp, topEnd = 24.dp, bottomEnd = 24.dp)
                else -> RoundedCornerShape(8.dp)
            }
            Row(
                Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(shape)
                    .background(if (on) colors.primary else colors.surface2)
                    .selectable(selected = on, role = Role.RadioButton) { onSelect(channel) },
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (on) Icon(BridgeyIcons.Check, null, tint = colors.onPrimary, modifier = Modifier.size(18.dp))
                Text(channelTitle(channel), style = BridgeyType.label, color = if (on) colors.onPrimary else colors.onSurface, maxLines = 1)
            }
        }
    }
}

@Composable
internal fun Credit(actions: SettingsActions) {
    Column(Modifier.fillMaxWidth().padding(top = 16.dp, start = 24.dp, end = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            stringResource(R.string.about_credit, dev.bridgey.android.BuildConfig.UPSTREAM_BASE),
            style = BridgeyType.small.copy(lineHeight = BridgeyType.itemBody.lineHeight),
            color = BridgeyTheme.colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        TextButton(onClick = { actions.openUrl(UPSTREAM_URL) }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.about_original), style = BridgeyType.smallStrong, color = BridgeyTheme.colors.primary)
        }
    }
}


data class NotificationAppsState(
    val applications: List<Pair<String, String>>,
    val disabled: Set<String>,
)

/** Which apps may forward notifications. */
@Composable
fun NotificationAppsScreen(state: NotificationAppsState, back: () -> Unit, setEnabled: (String, Boolean) -> Unit) {
    SettingsPage(stringResource(R.string.settings_notification_apps), back) {
        item(key = "note") {
            Note(
                stringResource(if (state.applications.isEmpty()) R.string.notification_apps_empty else R.string.notification_apps_intro),
                Modifier.padding(start = 32.dp, end = 32.dp, top = 20.dp),
            )
        }
        item(key = "apps") {
            RowGroup(Modifier.padding(top = 12.dp)) {
                state.applications.forEach { (packageName, label) ->
                    row { shape ->
                        SwitchRow(
                            shape, label, packageName, null, Tint.NEUTRAL, packageName !in state.disabled,
                            { setEnabled(packageName, it) }, compact = true,
                        )
                    }
                }
            }
        }
    }
}
