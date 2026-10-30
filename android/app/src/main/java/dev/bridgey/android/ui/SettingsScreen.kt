package dev.bridgey.android.ui

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.background
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
import dev.bridgey.android.LoggingPolicy
import dev.bridgey.android.R
import dev.bridgey.android.ReleaseNotesList
import dev.bridgey.android.UpdateCardPhase
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateFeeds
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop
import dev.bridgey.android.updateCardPhase
import dev.bridgey.android.updateErrorText

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
    /** Connect away from home (Connect anywhere). */
    val connect: ConnectSettingsState = ConnectSettingsState(),
) {
    fun featureOn(feature: BridgeyFeature): Boolean = globalFeatures[feature] != false
}

class SettingsActions(
    val back: () -> Unit = {},
    val openDevices: () -> Unit = {},
    /** Settings home: open a section's page. */
    val openSection: (SettingsSection) -> Unit = {},
    val openNotificationApps: () -> Unit = {},
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
    /** Settings > Privacy > Transfer speed. */
    val openSpeedTest: () -> Unit = {},
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
    val connect: ConnectSettingsActions = ConnectSettingsActions(),
)

const val UPSTREAM_URL = "https://github.com/singeol/bridgey"

/** The three groups of rows on the Settings home, each drawn as its own card. */
enum class SettingsGroup { DEVICES, FEATURES, APP }

/**
 * The Settings sections, top to bottom: what people come to change, most used first. The Settings
 * home shows This phone as a header card, then one row per section in its [group]; each row opens
 * the section's page, which leads with the feature's on/off switch, then its options. The macOS
 * sidebar mirrors this order. A unit test pins the order and the groups.
 */
enum class SettingsSection(val titleRes: Int, val group: SettingsGroup?) {
    THIS_PHONE(R.string.settings_this_phone, null),
    DEVICES(R.string.settings_devices, SettingsGroup.DEVICES),
    /** Connect away from home: a page under Devices (its row is on the Devices page, as on the Mac). */
    AWAY(R.string.settings_connect_away, null),
    CLIPBOARD(R.string.feature_clipboard, SettingsGroup.FEATURES),
    NOTIFICATIONS(R.string.settings_notifications, SettingsGroup.FEATURES),
    MESSAGES(R.string.feature_sms, SettingsGroup.FEATURES),
    CALLS(R.string.feature_calls, SettingsGroup.FEATURES),
    FILES(R.string.feature_files, SettingsGroup.FEATURES),
    MEDIA(R.string.settings_media, SettingsGroup.FEATURES),
    REMOTE_CONTROL(R.string.settings_remote_control, SettingsGroup.FEATURES),
    PRIVACY(R.string.settings_privacy, SettingsGroup.APP),
    UPDATES(R.string.settings_updates, SettingsGroup.APP),
    GENERAL(R.string.settings_general, SettingsGroup.APP),
    ABOUT(R.string.settings_about, SettingsGroup.APP),
    ;

    companion object {
        /** The rows on the Settings home: every section but This phone, which is the header card. */
        val homeRows: List<SettingsSection> get() = entries.filter { it.group != null }
    }
}


/** Light mode band behind the page bar: status bar + 56 dp + 8 dp. */
private val PageBandHeight = 64.dp

/** A pushed settings page: page bar on the band, then a list. */
@Composable
fun SettingsPage(title: String, onBack: () -> Unit, listState: LazyListState = rememberLazyListState(), content: LazyListScope.() -> Unit) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    ScreenBackdrop(bandHeight = statusTop + PageBandHeight) {
        Column(Modifier.fillMaxSize()) {
            OnBand { PageBar(title, onBack) }
            LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(bottom = navBottom + 32.dp), content = content)
        }
    }
}

/**
 * Settings. With no [section], the home: a This phone header card, then one row per section with a
 * live summary, in three groups. With a [section], that section's page. Pushed pages, not tabs; the
 * stream is the whole app.
 */
@Composable
fun SettingsScreen(
    state: SettingsState,
    actions: SettingsActions,
    listState: LazyListState = rememberLazyListState(),
    section: SettingsSection? = null,
) {
    when (section) {
        null, SettingsSection.THIS_PHONE -> SettingsHome(state, actions, listState)
        SettingsSection.DEVICES -> DevicesPage(state, actions, listState)
        SettingsSection.AWAY -> ConnectAwayPage(state, actions, listState)
        SettingsSection.CLIPBOARD -> ClipboardPage(state, actions, listState)
        SettingsSection.NOTIFICATIONS -> NotificationsPage(state, actions, listState)
        SettingsSection.MESSAGES -> MessagesPage(state, actions, listState)
        SettingsSection.CALLS -> CallsPage(state, actions, listState)
        SettingsSection.FILES -> FilesPage(state, actions, listState)
        SettingsSection.MEDIA -> MediaPage(state, actions, listState)
        SettingsSection.REMOTE_CONTROL -> RemoteControlPage(state, actions, listState)
        SettingsSection.PRIVACY -> PrivacyPage(state, actions, listState)
        SettingsSection.UPDATES -> UpdatesPage(state, actions, listState)
        SettingsSection.GENERAL -> GeneralPage(state, actions, listState)
        SettingsSection.ABOUT -> AboutPage(state, actions, listState)
    }
}

/** Settings home: This phone (tap to rename), then a row per section, grouped Devices, Features, App. */
@Composable
private fun SettingsHome(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    var renaming by rememberSaveable { mutableStateOf(false) }
    SettingsPage(stringResource(R.string.settings_title), actions.back, listState) {
        item(key = "phone") { ThisPhoneCard(state, onRename = { renaming = true }, Modifier.padding(top = 20.dp)) }
        SettingsGroup.entries.forEach { group ->
            item(key = "group.${group.name}") {
                RowGroup(Modifier.padding(top = if (group == SettingsGroup.DEVICES) 16.dp else 24.dp)) {
                    SettingsSection.homeRows.filter { it.group == group }.forEach { section ->
                        row { shape -> SectionRow(shape, section, state) { actions.openSection(section) } }
                    }
                }
            }
        }
    }
    if (renaming) RenameDialog(state.deviceName, onDismiss = { renaming = false }, onSave = { renaming = false; actions.rename(it) })
}

/** One section's page: the section's title on the page bar, then its rows as they were on the long page. */
@Composable
private fun SectionPage(section: SettingsSection, actions: SettingsActions, listState: LazyListState, content: LazyListScope.() -> Unit) {
    SettingsPage(stringResource(section.titleRes), actions.back, listState) {
        item(key = "${section.name}.top") { Spacer(Modifier.height(12.dp)) }
        content()
    }
}

/**
 * Devices and permissions. The home's row opens [DevicesSettingsScreen] directly; this page is only
 * drawn when a caller asks for the section itself.
 */
@Composable
private fun DevicesPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.DEVICES, actions, listState) {
        item(key = "devices") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_devices),
                        androidx.compose.ui.res.pluralStringResource(R.plurals.settings_devices_count, state.pairedCount, state.pairedCount),
                        BridgeyIcons.Devices, Tint.BLUE, onClick = actions.openDevices,
                    ) { Chevron() }
                }
            }
        }
    }
}

/** Clipboard: the switch, then automatic copy, images and files, screenshots, background clipboard, the tile. */
@Composable
private fun ClipboardPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.CLIPBOARD, actions, listState) {
        item(key = "clipboard") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                featureRows(BridgeyFeature.CLIPBOARD, state, actions)
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.auto_clipboard_title), stringResource(R.string.auto_clipboard_detail),
                        BridgeyIcons.Sync, if (state.autoClipboardEnabled) Tint.BLUE else Tint.NEUTRAL,
                        state.autoClipboardEnabled, actions.setAutoClipboard,
                        synced = state.sync.syncs(dev.bridgey.android.sync.SyncKey.AUTO_CLIPBOARD),
                    )
                }
                syncRows(dev.bridgey.android.sync.SyncKey.AUTO_CLIPBOARD, state.sync, actions.sync)
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.clipboard_files_title), stringResource(R.string.clipboard_files_detail),
                        BridgeyIcons.Image, if (state.clipboardFilesEnabled) Tint.BLUE else Tint.NEUTRAL,
                        state.clipboardFilesEnabled, actions.setClipboardFiles,
                        synced = state.sync.syncs(dev.bridgey.android.sync.SyncKey.CLIPBOARD_FILES),
                    )
                }
                syncRows(dev.bridgey.android.sync.SyncKey.CLIPBOARD_FILES, state.sync, actions.sync)
                row { shape -> EagerLimitRow(shape, state, actions) }
                row { shape ->
                    // A screenshot goes as an image offer, so it follows Copy images and files.
                    val on = state.screenshotSendEnabled && state.clipboardFilesEnabled
                    SwitchRow(
                        shape, stringResource(R.string.screenshot_send_title), stringResource(R.string.screenshot_send_detail),
                        BridgeyIcons.Smartphone, if (on) Tint.BLUE else Tint.NEUTRAL,
                        on, actions.setScreenshotSend, enabled = state.clipboardFilesEnabled,
                    )
                }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.bg_clipboard_title), stringResource(R.string.bg_clipboard_detail),
                        BridgeyIcons.DeveloperMode, if (state.backgroundClipboardEnabled) Tint.BLUE else Tint.NEUTRAL,
                        state.backgroundClipboardEnabled, actions.setBackgroundClipboard,
                    )
                }
                row { shape ->
                    when {
                        state.tileAddSupported && !state.tileAdded -> ListRow(
                            shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_one_tap),
                            BridgeyIcons.AddToHomeScreen, Tint.BLUE,
                        ) { OutlinePillButton(stringResource(R.string.settings_tile_add), null, actions.addTile) }
                        state.tileAddSupported -> ListRow(
                            shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_added),
                            BridgeyIcons.AddToHomeScreen, Tint.GREEN,
                        )
                        else -> ListRow(
                            shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_detail),
                            BridgeyIcons.AddToHomeScreen, Tint.BLUE,
                        )
                    }
                }
            }
        }
        item(key = "clipboard.note") { Note(stringResource(R.string.auto_clipboard_explain), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
        if (state.backgroundClipboardEnabled) {
            item(key = "clipboard.background") { BackgroundClipboardCard(state, actions) }
        }
    }
}

/** Notifications: forwarding, its access and apps, Codes from messages, and Bridgey's own notifications. */
@Composable
private fun NotificationsPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.NOTIFICATIONS, actions, listState) {
        val notificationsOn = state.featureOn(BridgeyFeature.NOTIFICATIONS)
        item(key = "notifications") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    val on = notificationsOn
                    SwitchRow(
                        shape, stringResource(R.string.settings_forwarding_title),
                        stringResource(R.string.settings_notifications_detail),
                        BridgeyIcons.Notifications, if (on) Tint.PURPLE else Tint.NEUTRAL, on,
                        { actions.setGlobal(BridgeyFeature.NOTIFICATIONS, it) },
                        synced = state.sync.syncs(dev.bridgey.android.sync.SyncKey.NOTIFICATIONS),
                    )
                }
                syncRows(dev.bridgey.android.sync.SyncKey.NOTIFICATIONS, state.sync, actions.sync)
                if (notificationsOn) {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_forwarding),
                            stringResource(if (state.notificationAccessEnabled) R.string.settings_forwarding_on else R.string.settings_forwarding_off),
                            BridgeyIcons.Notifications, if (state.notificationAccessEnabled) Tint.GREEN else Tint.NEUTRAL,
                            detailWarning = !state.notificationAccessEnabled,
                            onClick = actions.notificationAccess,
                        ) { ManageLabel(state.notificationAccessEnabled) }
                    }
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_notification_apps),
                            stringResource(R.string.settings_notification_apps_count, state.notificationAppsEnabled, state.notificationAppsTotal),
                            BridgeyIcons.Notifications, Tint.PURPLE, onClick = actions.openNotificationApps,
                        ) { Chevron() }
                    }
                    codesRows(state.codes, actions.codes)
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_app_notifications),
                        stringResource(if (state.appNotificationsEnabled) R.string.settings_app_notifications_on else R.string.settings_app_notifications_off),
                        BridgeyIcons.Notifications, if (state.appNotificationsEnabled) Tint.GREEN else Tint.NEUTRAL,
                        onClick = actions.appNotifications,
                    ) { ManageLabel(state.appNotificationsEnabled) }
                }
            }
        }
        if (notificationsOn) {
            item(key = "notifications.codes") { CodesFootnote(state.codes, actions.codes) }
        }
        item(key = "notifications.focus.label") { SectionLabel(stringResource(R.string.focus_section), Modifier.padding(top = 20.dp)) }
        item(key = "notifications.focus") {
            RowGroup { focusRows(state.focus, actions.focus, state.sync, actions.sync) }
        }
        item(key = "notifications.focus.note") {
            Note(stringResource(R.string.focus_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
        }
    }
}

/** Text messages: the switch, then what Android allows and how replies from the Mac are sent. */
@Composable
private fun MessagesPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.MESSAGES, actions, listState) {
        val on = state.featureOn(BridgeyFeature.SMS)
        item(key = "messages") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                featureRows(BridgeyFeature.SMS, state, actions)
                if (on) messagesRows(state.messages, actions.messages)
            }
        }
        item(key = "messages.note") { Note(stringResource(R.string.messages_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
    }
}

/** Calls: the switch, then call status and controls. */
@Composable
private fun CallsPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.CALLS, actions, listState) {
        val callsOn = state.featureOn(BridgeyFeature.CALLS)
        item(key = "calls") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                featureRows(BridgeyFeature.CALLS, state, actions)
                if (callsOn) {
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.devices_direct_calls), stringResource(R.string.devices_direct_calls_detail),
                            BridgeyIcons.Call, if (state.directCallsEnabled) Tint.GREEN else Tint.NEUTRAL, state.directCallsEnabled, actions.setDirectCalls,
                        )
                    }
                }
            }
        }
    }
}

/** Files: the switch, then folders sent to this phone and Places. */
@Composable
private fun FilesPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.FILES, actions, listState) {
        item(key = "files") {
            val filesOn = state.featureOn(BridgeyFeature.FILES)
            Column {
                RowGroup(Modifier.padding(top = 8.dp)) {
                    featureRows(BridgeyFeature.FILES, state, actions)
                    if (filesOn && state.folders.supported) folderRows(state.folders, actions.folders, state.sync, actions.sync)
                }
                if (filesOn && state.folders.supported) {
                    Note(stringResource(if (state.folders.allowBrowse) R.string.settings_folders_note_browse else R.string.settings_folders_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
                    Note(stringResource(R.string.settings_folder_send_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
                }
            }
        }
    }
}

/** Media and quick actions: one switch per feature. */
@Composable
private fun MediaPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.MEDIA, actions, listState) {
        item(key = "media") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                MediaSectionFeatures.forEach { feature ->
                    featureRows(feature, state, actions)
                }
            }
        }
    }
}

/** Remote control: this phone as a Mac's touchpad, keyboard and presentation remote. */
@Composable
private fun RemoteControlPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.REMOTE_CONTROL, actions, listState) {
        val remoteOn = state.featureOn(BridgeyFeature.REMOTE_INPUT)
        item(key = "remote") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                featureRows(BridgeyFeature.REMOTE_INPUT, state, actions)
                if (remoteOn) {
                    row { shape -> PointerSpeedRow(shape, state, actions) }
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.remote_volume_keys_title), stringResource(R.string.remote_volume_keys_detail),
                            BridgeyIcons.VolumeUp, if (state.remoteVolumeKeys) Tint.PURPLE else Tint.NEUTRAL,
                            state.remoteVolumeKeys, actions.setRemoteVolumeKeys,
                        )
                    }
                }
            }
        }
        item(key = "remote.note") { Note(stringResource(R.string.remote_settings_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
    }
}

/** Privacy: previews, activity, and Logging. */
@Composable
private fun PrivacyPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    SectionPage(SettingsSection.PRIVACY, actions, listState) {
        item(key = "privacy") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_show_previews), stringResource(R.string.settings_show_previews_detail),
                        BridgeyIcons.ContentPaste, if (state.showPreviews) Tint.BLUE else Tint.NEUTRAL, state.showPreviews, actions.setShowPreviews,
                        synced = state.sync.syncs(dev.bridgey.android.sync.SyncKey.ACTIVITY_PREVIEWS),
                    )
                }
                syncRows(dev.bridgey.android.sync.SyncKey.ACTIVITY_PREVIEWS, state.sync, actions.sync)
                row { shape ->
                    ListRow(shape, stringResource(R.string.settings_activity), stringResource(R.string.settings_activity_detail), BridgeyIcons.Update, Tint.PURPLE) {
                        OutlinePillButton(
                            stringResource(R.string.action_clear), null, { confirmClear = true },
                            enabled = state.activityCount > 0,
                        )
                    }
                }
            }
        }
        item(key = "privacy.setup") { PrivacySetupRows(actions.setup) }
        item(key = "privacy.logging") {
            LoggingSettingsGroup(state.logging, actions.setLogging, actions.exportDiagnostics, actions.clearLogs)
        }
        item(key = "privacy.speed") {
            RowGroup(Modifier.padding(top = 16.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_speed_test), stringResource(R.string.settings_speed_test_detail),
                        BridgeyIcons.Wifi, Tint.BLUE, onClick = actions.openSpeedTest,
                    )
                }
            }
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(stringResource(R.string.clear_activity_title)) },
            text = { Text(stringResource(R.string.clear_activity_body)) },
            confirmButton = { TextButton(onClick = { confirmClear = false; actions.clearActivity() }) { Text(stringResource(R.string.action_clear)) } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

/** Updates: the status card, the channel and Update all devices automatically, then your devices. */
@Composable
private fun UpdatesPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.UPDATES, actions, listState) {
        item(key = "updates") { UpdatesCard(state.update, state.installedVersion, state.now, actions, state.updateAll.auto) }
        item(key = "updates.devices") {
            val colors = BridgeyTheme.colors
            YourDevicesCard(
                state.updateAll,
                actions.updateAll,
                Modifier.padding(horizontal = 16.dp).padding(top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(colors.surface1).padding(bottom = 4.dp),
            )
        }
    }
}

/**
 * General: staying connected while the phone sleeps (the Mac's Launch at login sits in its General
 * too), then Reduce motion and Turn off.
 */
@Composable
private fun GeneralPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    SectionPage(SettingsSection.GENERAL, actions, listState) {
        item(key = "general.background") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_background_title),
                        stringResource(if (state.batteryExempt) R.string.settings_background_on else R.string.settings_background_off),
                        BridgeyIcons.Bolt, if (state.batteryExempt) Tint.GREEN else Tint.NEUTRAL,
                        detailWarning = !state.batteryExempt,
                        onClick = actions.openBatterySettings, onClickLabel = stringResource(R.string.settings_background_open),
                    ) {
                        if (state.batteryExempt) {
                            Icon(BridgeyIcons.Check, null, tint = BridgeyTheme.colors.onTintGreen)
                        } else {
                            OutlinePillButton(stringResource(R.string.action_allow), null, actions.requestBatteryExemption)
                        }
                    }
                }
                if (state.keepWifiAwakeSupported) {
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.settings_wifi_awake_title), stringResource(R.string.settings_wifi_awake_detail),
                            BridgeyIcons.Wifi, if (state.keepWifiAwake) Tint.BLUE else Tint.NEUTRAL,
                            state.keepWifiAwake, actions.setKeepWifiAwake,
                        )
                    }
                }
            }
        }
        item(key = "general.background.note") { Note(stringResource(R.string.settings_background_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
        item(key = "general.oem") { GeneralOemChecklist(state.setup, actions.setup, actions.openUrl) }
        item(key = "general.sync") { SyncSettingsGroup(state.sync, actions.sync, Modifier.padding(top = 24.dp)) }
        item(key = "general") {
            RowGroup(Modifier.padding(top = 24.dp)) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_reduce_motion), stringResource(R.string.settings_reduce_motion_detail),
                        BridgeyIcons.Animation, Tint.NEUTRAL, state.reduceMotion, actions.setReduceMotion,
                        synced = state.sync.syncs(dev.bridgey.android.sync.SyncKey.REDUCE_MOTION),
                    )
                }
                syncRows(dev.bridgey.android.sync.SyncKey.REDUCE_MOTION, state.sync, actions.sync)
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_turn_off), stringResource(R.string.settings_turn_off_detail),
                        BridgeyIcons.PowerSettingsNew, Tint.NEUTRAL, detailWarning = false,
                        onClick = actions.turnOff,
                    ) {
                        Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.warn)
                    }
                }
            }
        }
        item(key = "general.setup") { GeneralSetupRows(actions.setup) }
    }
}

/** About: the version (seven taps open the Performance test), licences and the credit. */
@Composable
private fun AboutPage(state: SettingsState, actions: SettingsActions, listState: LazyListState) {
    var licences by rememberSaveable { mutableStateOf(false) }
    var versionTaps by remember { mutableIntStateOf(0) }
    SectionPage(SettingsSection.ABOUT, actions, listState) {
        item(key = "about") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_version), state.installedVersion, BridgeyIcons.Info, Tint.BLUE,
                        // Seven taps open the hidden Performance test.
                        onClick = {
                            versionTaps += 1
                            if (versionTaps >= 7) { versionTaps = 0; actions.openPerfTest() }
                        },
                    )
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_licences), stringResource(R.string.settings_licences_detail),
                        BridgeyIcons.Gavel, Tint.NEUTRAL, onClick = { licences = true },
                    ) { Chevron() }
                }
            }
        }
        item(key = "about.obtainium") { ObtainiumRow(state.update.channel, actions.setup) }
        item(key = "credit") { Credit(actions) }
    }
    if (licences) {
        AlertDialog(
            onDismissRequest = { licences = false },
            title = { Text(stringResource(R.string.settings_licences)) },
            text = { Text(stringResource(R.string.licences_body)) },
            confirmButton = { TextButton(onClick = { licences = false }) { Text(stringResource(R.string.action_close)) } },
        )
    }
}

/** The home's header: this phone's ring, name and connection. Tap to rename. */
@Composable
private fun ThisPhoneCard(state: SettingsState, onRename: () -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Row(
        modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(colors.surface1)
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

/** A home row: the section's icon, title and live summary; a dot when an update is ready. */
@Composable
private fun SectionRow(shape: androidx.compose.ui.graphics.Shape, section: SettingsSection, state: SettingsState, onClick: () -> Unit) {
    val summary = sectionSummary(section, state)
    val (icon, tint) = sectionVisual(section, state)
    ListRow(
        shape, stringResource(section.titleRes), summary.text, icon, tint,
        // Compact rows keep the whole home on one phone screen.
        compact = true, detailWarning = summary.warning, onClick = onClick,
    ) {
        if (summary.badge) UpdateDot()
        Chevron()
    }
}

/** What a home row says under its title, and whether it warns or carries the update dot. */
private data class SectionSummary(val text: String, val warning: Boolean = false, val badge: Boolean = false)

/** A section's tile: its feature's icon, tinted while the feature is on. */
private fun sectionVisual(section: SettingsSection, state: SettingsState): Pair<androidx.compose.ui.graphics.vector.ImageVector, Tint> {
    fun feature(feature: BridgeyFeature, on: Boolean = state.featureOn(feature)): Pair<androidx.compose.ui.graphics.vector.ImageVector, Tint> {
        val (icon, tint) = permissionVisual(feature)
        return icon to if (on) tint else Tint.NEUTRAL
    }
    return when (section) {
        SettingsSection.THIS_PHONE -> BridgeyIcons.Smartphone to Tint.BLUE
        SettingsSection.DEVICES -> BridgeyIcons.Devices to Tint.BLUE
        SettingsSection.AWAY -> BridgeyIcons.Public to if (state.connect.on) Tint.BLUE else Tint.NEUTRAL
        SettingsSection.CLIPBOARD -> feature(BridgeyFeature.CLIPBOARD)
        SettingsSection.NOTIFICATIONS -> feature(BridgeyFeature.NOTIFICATIONS)
        SettingsSection.MESSAGES -> feature(BridgeyFeature.SMS)
        SettingsSection.CALLS -> feature(BridgeyFeature.CALLS)
        SettingsSection.FILES -> feature(BridgeyFeature.FILES)
        SettingsSection.MEDIA -> feature(BridgeyFeature.MEDIA, MediaSectionFeatures.any(state::featureOn))
        SettingsSection.REMOTE_CONTROL -> feature(BridgeyFeature.REMOTE_INPUT)
        SettingsSection.PRIVACY -> BridgeyIcons.Shield to Tint.BLUE
        SettingsSection.UPDATES -> BridgeyIcons.SystemUpdate to Tint.PURPLE
        SettingsSection.GENERAL -> BridgeyIcons.Settings to Tint.NEUTRAL
        SettingsSection.ABOUT -> BridgeyIcons.Info to Tint.NEUTRAL
    }
}

/** The features on the Media and quick actions page, in its order. */
private val MediaSectionFeatures = listOf(
    BridgeyFeature.MEDIA, BridgeyFeature.MAC_ACTIONS, BridgeyFeature.CAMERA, BridgeyFeature.SCREEN, BridgeyFeature.LINKS, BridgeyFeature.PING,
    BridgeyFeature.FIND_DEVICE, BridgeyFeature.BATTERY,
)

/** The live one-line summary under each home row, e.g. "Automatic, images up to 25 MB". */
@Composable
private fun sectionSummary(section: SettingsSection, state: SettingsState): SectionSummary {
    val off = stringResource(R.string.settings_summary_off)
    fun featureOff(feature: BridgeyFeature) = !state.featureOn(feature)
    return when (section) {
        SettingsSection.THIS_PHONE -> SectionSummary(state.connectionStatus)
        SettingsSection.DEVICES -> SectionSummary(
            androidx.compose.ui.res.pluralStringResource(R.plurals.settings_devices_count, state.pairedCount, state.pairedCount),
        )
        SettingsSection.AWAY -> SectionSummary(connectSummary(state.connect))
        SettingsSection.CLIPBOARD -> if (featureOff(BridgeyFeature.CLIPBOARD)) {
            SectionSummary(off)
        } else {
            val mode = stringResource(if (state.autoClipboardEnabled) R.string.settings_summary_clipboard_auto else R.string.settings_summary_clipboard_manual)
            val files = when {
                !state.clipboardFilesEnabled -> stringResource(R.string.settings_summary_clipboard_text_only)
                state.clipboardEagerLimit == 0L -> stringResource(R.string.settings_summary_clipboard_images_on_paste)
                else -> stringResource(R.string.settings_summary_clipboard_images, eagerLimitLabel(state.clipboardEagerLimit))
            }
            SectionSummary(stringResource(R.string.settings_summary_pair, mode, files))
        }
        SettingsSection.NOTIFICATIONS -> when {
            featureOff(BridgeyFeature.NOTIFICATIONS) -> SectionSummary(off)
            !state.notificationAccessEnabled -> SectionSummary(stringResource(R.string.settings_summary_notifications_access), warning = true)
            else -> SectionSummary(stringResource(R.string.settings_notification_apps_count, state.notificationAppsEnabled, state.notificationAppsTotal))
        }
        SettingsSection.MESSAGES -> when {
            featureOff(BridgeyFeature.SMS) -> SectionSummary(off)
            !state.messages.smsAllowed -> SectionSummary(stringResource(R.string.settings_summary_messages_access), warning = true)
            state.messages.replyAsSms -> SectionSummary(stringResource(R.string.settings_summary_messages_sms))
            else -> SectionSummary(stringResource(R.string.settings_summary_messages_on))
        }
        SettingsSection.CALLS -> SectionSummary(
            when {
                featureOff(BridgeyFeature.CALLS) -> off
                state.directCallsEnabled -> stringResource(R.string.settings_summary_calls_controls)
                else -> stringResource(R.string.settings_summary_calls_ring)
            },
        )
        SettingsSection.FILES -> SectionSummary(
            when {
                featureOff(BridgeyFeature.FILES) -> off
                state.folders.supported -> folderModeLabel(state.folders.mode, state.folders.defaultLabel)
                else -> stringResource(R.string.settings_summary_on)
            },
        )
        SettingsSection.MEDIA -> {
            val on = MediaSectionFeatures.count(state::featureOn)
            SectionSummary(
                when (on) {
                    0 -> off
                    MediaSectionFeatures.size -> stringResource(R.string.settings_summary_all_on)
                    else -> stringResource(R.string.settings_summary_some_on, on, MediaSectionFeatures.size)
                },
            )
        }
        SettingsSection.REMOTE_CONTROL -> SectionSummary(
            when {
                featureOff(BridgeyFeature.REMOTE_INPUT) -> off
                state.remoteVolumeKeys -> stringResource(R.string.settings_summary_remote_volume_keys)
                else -> stringResource(R.string.settings_summary_on)
            },
        )
        SettingsSection.PRIVACY -> SectionSummary(
            stringResource(if (state.showPreviews) R.string.settings_summary_previews_shown else R.string.settings_summary_previews_hidden),
        )
        SettingsSection.UPDATES -> updatesSummary(state)
        SettingsSection.GENERAL -> when {
            !state.batteryExempt -> SectionSummary(stringResource(R.string.settings_summary_general_battery), warning = true)
            state.reduceMotion -> SectionSummary(stringResource(R.string.settings_summary_general_reduced))
            else -> SectionSummary(stringResource(R.string.settings_summary_general_background))
        }
        SettingsSection.ABOUT -> SectionSummary(stringResource(R.string.settings_summary_version, state.installedVersion))
    }
}

/** "Beta · up to date", "Beta · 0.6.1 is ready" (with the dot), "Beta · downloading". */
@Composable
private fun updatesSummary(state: SettingsState): SectionSummary {
    val channel = channelTitle(state.update.channel)
    val short = { version: String -> UpdateFeeds.shortVersion(version, state.installedVersion) }
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
private fun EagerLimitRow(shape: androidx.compose.ui.graphics.Shape, state: SettingsState, actions: SettingsActions) {
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
private fun PointerSpeedRow(shape: androidx.compose.ui.graphics.Shape, state: SettingsState, actions: SettingsActions) {
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

/** A feature's global switch, then its sync lines (Different on, waiting for permission). */
private fun GroupScope.featureRows(feature: BridgeyFeature, state: SettingsState, actions: SettingsActions) {
    row { shape -> FeatureSwitch(shape, feature, state, actions) }
    syncRows(syncKeyFor(feature), state.sync, actions.sync)
}

/** A feature's global on/off switch row. Title, generic detail, icon and tint from the feature. */
@Composable
private fun FeatureSwitch(shape: androidx.compose.ui.graphics.Shape, feature: BridgeyFeature, state: SettingsState, actions: SettingsActions) {
    val (icon, tint) = permissionVisual(feature)
    val on = state.featureOn(feature)
    SwitchRow(
        shape, featureSettingTitle(feature), globalFeatureDetail(feature),
        icon, if (on) tint else Tint.NEUTRAL, on,
        { actions.setGlobal(feature, it) },
        synced = syncKeyFor(feature)?.let(state.sync::syncs) == true,
    )
}

/** Find and Ping are separate rows here, so they take their own titles. */
@Composable
private fun featureSettingTitle(feature: BridgeyFeature): String = when (feature) {
    BridgeyFeature.FIND_DEVICE -> stringResource(R.string.feature_find)
    BridgeyFeature.PING -> stringResource(R.string.feature_ping)
    else -> permissionTitle(feature)
}

/** The generic, non device-specific description for a feature's global switch. */
@Composable
private fun globalFeatureDetail(feature: BridgeyFeature): String = stringResource(
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
    },
)

/** The one-time setup for the optional background clipboard: a status line, and the steps when not ready. */
@Composable
private fun BackgroundClipboardCard(state: SettingsState, actions: SettingsActions) {
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
private fun Chevron() = Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)

@Composable
private fun ManageLabel(enabled: Boolean) {
    Text(
        stringResource(if (enabled) R.string.action_manage else R.string.action_enable),
        style = BridgeyType.label,
        color = BridgeyTheme.colors.primary,
    )
}

@Composable
private fun RenameDialog(current: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
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
 * Settings > Updates: one status card that shows one state at a time, then the channel and Update
 * all devices automatically (how often it checks, what it waits for). The version appears once, in
 * the status card.
 */
@Composable
fun UpdatesCard(
    state: UpdateUiState,
    installedVersion: String,
    now: Long,
    actions: SettingsActions,
    auto: dev.bridgey.android.updates.AutoUpdateView = dev.bridgey.android.updates.AutoUpdateView(),
) {
    val colors = BridgeyTheme.colors
    val cardModifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(colors.surface1)
    Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        UpdateStatusCard(updateCardPhase(state), installedVersion, now, actions, cardModifier.padding(start = 20.dp, end = 8.dp, top = 12.dp, bottom = 16.dp))
        Column(cardModifier.padding(horizontal = 20.dp, vertical = 16.dp)) {
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
    val short = { version: String -> UpdateFeeds.shortVersion(version, installedVersion) }
    val title = when (phase) {
        is UpdateCardPhase.Current, is UpdateCardPhase.Waiting, is UpdateCardPhase.Skipped -> stringResource(R.string.updates_current, installedVersion)
        UpdateCardPhase.Checking -> stringResource(R.string.updates_checking)
        is UpdateCardPhase.Available -> stringResource(R.string.updates_is_ready, phase.update.versionName)
        is UpdateCardPhase.Confirming -> stringResource(R.string.updates_is_ready, phase.update.versionName)
        is UpdateCardPhase.Downloading -> stringResource(R.string.updates_downloading, phase.update.versionName)
        is UpdateCardPhase.Failed -> stringResource(R.string.updates_failed)
        is UpdateCardPhase.Ready -> stringResource(R.string.updates_is_ready, phase.update.versionName)
        is UpdateCardPhase.Installing -> stringResource(R.string.updates_installing, phase.update.versionName)
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
        is UpdateCardPhase.Available -> stringResource(R.string.updates_you_have, UpdateFeeds.shortVersion(installedVersion, phase.update.versionName))
        is UpdateCardPhase.Confirming -> stringResource(R.string.updates_confirm)
        is UpdateCardPhase.Downloading -> stringResource(
            R.string.updates_downloading_detail,
            Formatter.formatShortFileSize(context, (phase.update.size * phase.progress.coerceIn(0f, 1f)).toLong()),
            Formatter.formatShortFileSize(context, phase.update.size),
        )
        is UpdateCardPhase.Failed -> updateErrorText(phase.error)
        is UpdateCardPhase.Ready -> stringResource(R.string.updates_ready_detail)
        is UpdateCardPhase.Installing -> stringResource(R.string.updates_installing_detail)
        is UpdateCardPhase.NotApplied -> stringResource(R.string.updates_not_applied_detail, phase.versionName, installedVersion)
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
private fun Credit(actions: SettingsActions) {
    Column(Modifier.fillMaxWidth().padding(top = 16.dp, start = 24.dp, end = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            stringResource(R.string.about_credit),
            style = BridgeyType.small.copy(lineHeight = BridgeyType.itemBody.lineHeight),
            color = BridgeyTheme.colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        TextButton(onClick = { actions.openUrl(UPSTREAM_URL) }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.about_original), style = BridgeyType.smallStrong, color = BridgeyTheme.colors.primary)
        }
    }
}

data class DevicesSettingsState(
    val rings: List<DeviceRing>,
    val rediscovering: Boolean = false,
    /** Connect away from home, for its row (null hides it). */
    val connect: ConnectSettingsState? = null,
)

class DevicesSettingsActions(
    val back: () -> Unit = {},
    val openDevice: (DeviceRing) -> Unit = {},
    val addDevice: () -> Unit = {},
    val lookForDevices: () -> Unit = {},
    val openConnectAway: () -> Unit = {},
)

/**
 * Devices and permissions: each paired device (tap for its per-device switches and Forget), and a
 * way to pair a new one. Per-feature on/off for this phone now lives in the feature sections of
 * Settings, so the old "For every device" duplication is gone.
 */
@Composable
fun DevicesSettingsScreen(state: DevicesSettingsState, actions: DevicesSettingsActions) {
    SettingsPage(stringResource(R.string.settings_devices), actions.back) {
        item(key = "paired.label") { SectionLabel(stringResource(R.string.devices_paired), Modifier.padding(top = 20.dp)) }
        item(key = "paired") {
            val paired = state.rings.filter { it.trusted && it.deviceId != null }
            if (paired.isEmpty()) {
                Note(stringResource(R.string.devices_none), Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
            } else {
                RowGroup(Modifier.padding(top = 8.dp)) {
                    paired.forEach { ring ->
                        row { shape ->
                            ListRow(
                                shape, ring.name, ringStatusLabel(ring), null, Tint.NEUTRAL,
                                onClick = { actions.openDevice(ring) },
                                leading = { DeviceGlyph(ring.state.style(), deviceIcon(ring.platform), 40.dp, iconSize = 18.dp) },
                            ) { Chevron() }
                        }
                    }
                }
            }
        }
        state.connect?.let { connect ->
            item(key = "away") {
                RowGroup(Modifier.padding(top = 24.dp)) {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_connect_away), connectSummary(connect),
                            BridgeyIcons.Public, if (connect.on) Tint.BLUE else Tint.NEUTRAL, onClick = actions.openConnectAway,
                        ) { Chevron() }
                    }
                }
            }
        }
        item(key = "add") {
            RowGroup(Modifier.padding(top = 24.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.look_again), stringResource(R.string.look_again_detail),
                        BridgeyIcons.Refresh, Tint.NEUTRAL,
                        onClick = if (state.rediscovering) null else actions.lookForDevices,
                    )
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.devices_pair_new), stringResource(R.string.devices_pair_new_detail),
                        BridgeyIcons.Add, Tint.BLUE, onClick = actions.addDevice,
                    ) { Chevron() }
                }
            }
        }
        item(key = "per-device.note") { Note(stringResource(R.string.devices_per_device_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 12.dp)) }
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
