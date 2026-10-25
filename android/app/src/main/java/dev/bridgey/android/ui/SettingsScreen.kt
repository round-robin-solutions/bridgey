package dev.bridgey.android.ui

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.ui.theme.Aurora
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop

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
    val notificationAppsEnabled: Int,
    val notificationAppsTotal: Int,
    val appNotificationsEnabled: Boolean,
    val notificationAccessEnabled: Boolean,
    val reduceMotion: Boolean,
    val showPreviews: Boolean,
    val activityCount: Int,
    val update: UpdateUiState,
    val installedVersion: String,
    val now: Long,
) {
    fun featureOn(feature: BridgeyFeature): Boolean = globalFeatures[feature] != false
}

class SettingsActions(
    val back: () -> Unit = {},
    val openDevices: () -> Unit = {},
    val openNotificationApps: () -> Unit = {},
    val appNotifications: () -> Unit = {},
    val notificationAccess: () -> Unit = {},
    val rename: (String) -> Unit = {},
    val setGlobal: (BridgeyFeature, Boolean) -> Unit = { _, _ -> },
    val setDirectCalls: (Boolean) -> Unit = {},
    val setAutoClipboard: (Boolean) -> Unit = {},
    val setBackgroundClipboard: (Boolean) -> Unit = {},
    val copyCommand: () -> Unit = {},
    val setReduceMotion: (Boolean) -> Unit = {},
    val setShowPreviews: (Boolean) -> Unit = {},
    val clearActivity: () -> Unit = {},
    val exportDiagnostics: () -> Unit = {},
    val turnOff: () -> Unit = {},
    val checkNow: () -> Unit = {},
    val setChannel: (UpdateChannel) -> Unit = {},
    val install: () -> Unit = {},
    val openUrl: (String) -> Unit = {},
)

const val UPSTREAM_URL = "https://github.com/singeol/bridgey"

/**
 * The order of Settings sections, top to bottom: what people come to change, most used first.
 * Each feature section leads with its on/off switch, then its options. The macOS app mirrors
 * this order. [SettingsScreen] draws its section labels from this list; a unit test pins the order.
 */
enum class SettingsSection(val titleRes: Int) {
    THIS_PHONE(R.string.settings_this_phone),
    DEVICES(R.string.settings_devices_section),
    CLIPBOARD(R.string.feature_clipboard),
    NOTIFICATIONS(R.string.settings_notifications),
    CALLS(R.string.feature_calls),
    FILES(R.string.feature_files),
    MEDIA(R.string.settings_media),
    PRIVACY(R.string.settings_privacy),
    UPDATES(R.string.settings_updates),
    GENERAL(R.string.settings_general),
    ABOUT(R.string.settings_about),
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
 * Settings, grouped by what people come to change. Each feature section leads with its on/off
 * switch, then its options. A pushed page, not a tab; the stream is the whole app.
 */
@Composable
fun SettingsScreen(state: SettingsState, actions: SettingsActions, listState: LazyListState = rememberLazyListState()) {
    var renaming by rememberSaveable { mutableStateOf(false) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    var licences by rememberSaveable { mutableStateOf(false) }
    SettingsPage(stringResource(R.string.settings_title), actions.back, listState) {
        // 1. This phone
        sectionLabel(SettingsSection.THIS_PHONE, 20.dp)
        item(key = "phone") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_device_name), state.deviceName, BridgeyIcons.Smartphone, Tint.BLUE,
                        onClick = { renaming = true }, onClickLabel = stringResource(R.string.action_rename),
                    ) { Icon(BridgeyIcons.Edit, null, tint = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.size(20.dp)) }
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_connection), state.connectionStatus,
                        if (state.connected) BridgeyIcons.Wifi else BridgeyIcons.WifiOff,
                        if (state.connected) Tint.GREEN else Tint.NEUTRAL,
                    )
                }
            }
        }

        // 2. Devices and permissions
        sectionLabel(SettingsSection.DEVICES, 24.dp)
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

        // 3. Clipboard
        sectionLabel(SettingsSection.CLIPBOARD, 24.dp)
        item(key = "clipboard") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape -> FeatureSwitch(shape, BridgeyFeature.CLIPBOARD, state, actions) }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.auto_clipboard_title), stringResource(R.string.auto_clipboard_detail),
                        BridgeyIcons.Sync, if (state.autoClipboardEnabled) Tint.BLUE else Tint.NEUTRAL,
                        state.autoClipboardEnabled, actions.setAutoClipboard,
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
                    ListRow(shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_detail), BridgeyIcons.AddToHomeScreen, Tint.BLUE)
                }
            }
        }
        item(key = "clipboard.note") { Note(stringResource(R.string.auto_clipboard_explain), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
        if (state.backgroundClipboardEnabled) {
            item(key = "clipboard.background") { BackgroundClipboardCard(state, actions) }
        }

        // 4. Notifications
        val notificationsOn = state.featureOn(BridgeyFeature.NOTIFICATIONS)
        sectionLabel(SettingsSection.NOTIFICATIONS, 24.dp)
        item(key = "notifications") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    val on = notificationsOn
                    SwitchRow(
                        shape, stringResource(R.string.settings_forwarding_title),
                        stringResource(R.string.settings_notifications_detail),
                        BridgeyIcons.Notifications, if (on) Tint.PURPLE else Tint.NEUTRAL, on,
                        { actions.setGlobal(BridgeyFeature.NOTIFICATIONS, it) },
                    )
                }
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

        // 5. Calls
        val callsOn = state.featureOn(BridgeyFeature.CALLS)
        sectionLabel(SettingsSection.CALLS, 24.dp)
        item(key = "calls") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape -> FeatureSwitch(shape, BridgeyFeature.CALLS, state, actions) }
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

        // 6. Files
        sectionLabel(SettingsSection.FILES, 24.dp)
        item(key = "files") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape -> FeatureSwitch(shape, BridgeyFeature.FILES, state, actions) }
            }
        }

        // 7. Media and quick actions
        sectionLabel(SettingsSection.MEDIA, 24.dp)
        item(key = "media") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                listOf(
                    BridgeyFeature.MEDIA, BridgeyFeature.LINKS, BridgeyFeature.PING,
                    BridgeyFeature.FIND_DEVICE, BridgeyFeature.BATTERY,
                ).forEach { feature ->
                    row { shape -> FeatureSwitch(shape, feature, state, actions) }
                }
            }
        }

        // 8. Privacy
        sectionLabel(SettingsSection.PRIVACY, 24.dp)
        item(key = "privacy") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_show_previews), stringResource(R.string.settings_show_previews_detail),
                        BridgeyIcons.ContentPaste, if (state.showPreviews) Tint.BLUE else Tint.NEUTRAL, state.showPreviews, actions.setShowPreviews,
                    )
                }
                row { shape ->
                    ListRow(shape, stringResource(R.string.settings_activity), stringResource(R.string.settings_activity_detail), BridgeyIcons.Update, Tint.PURPLE) {
                        OutlinePillButton(
                            stringResource(R.string.action_clear), null, { confirmClear = true },
                            enabled = state.activityCount > 0,
                        )
                    }
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_diagnostics), stringResource(R.string.settings_diagnostics_detail),
                        BridgeyIcons.BugReport, Tint.NEUTRAL, onClick = actions.exportDiagnostics, onClickLabel = stringResource(R.string.action_share),
                    ) { Icon(BridgeyIcons.IosShare, null, tint = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.size(20.dp)) }
                }
            }
        }

        // 9. Updates
        sectionLabel(SettingsSection.UPDATES, 24.dp)
        item(key = "updates") { UpdatesCard(state.update, state.installedVersion, state.now, actions) }

        // 10. General
        sectionLabel(SettingsSection.GENERAL, 24.dp)
        item(key = "general") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_reduce_motion), stringResource(R.string.settings_reduce_motion_detail),
                        BridgeyIcons.Animation, Tint.NEUTRAL, state.reduceMotion, actions.setReduceMotion,
                    )
                }
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

        // 11. About
        sectionLabel(SettingsSection.ABOUT, 24.dp)
        item(key = "about") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(shape, stringResource(R.string.settings_version), state.installedVersion, BridgeyIcons.Info, Tint.BLUE)
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_licences), stringResource(R.string.settings_licences_detail),
                        BridgeyIcons.Gavel, Tint.NEUTRAL, onClick = { licences = true },
                    ) { Chevron() }
                }
            }
        }
        item(key = "credit") { Credit(actions) }
    }

    if (renaming) RenameDialog(state.deviceName, onDismiss = { renaming = false }, onSave = { renaming = false; actions.rename(it) })
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(stringResource(R.string.clear_activity_title)) },
            text = { Text(stringResource(R.string.clear_activity_body)) },
            confirmButton = { TextButton(onClick = { confirmClear = false; actions.clearActivity() }) { Text(stringResource(R.string.action_clear)) } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
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

/** A section label item, keyed and titled from [SettingsSection] so the order stays testable. */
private fun LazyListScope.sectionLabel(section: SettingsSection, top: androidx.compose.ui.unit.Dp) {
    item(key = "${section.name}.label") { SectionLabel(stringResource(section.titleRes), Modifier.padding(top = top)) }
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

/** The Updates card: version and status, the channel as a three-way button group, and what is new. */
@Composable
fun UpdatesCard(state: UpdateUiState, installedVersion: String, now: Long, actions: SettingsActions) {
    val colors = BridgeyTheme.colors
    val update = state.available
    Column(
        Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp).fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(colors.surface1).padding(20.dp),
    ) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.updates_version, installedVersion), style = BridgeyType.cardTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    if (state.lastCheckedAt > 0) {
                        stringResource(
                            R.string.updates_checked,
                            DateUtils.getRelativeTimeSpanString(state.lastCheckedAt, maxOf(now, state.lastCheckedAt), DateUtils.MINUTE_IN_MILLIS).toString(),
                        )
                    } else {
                        stringResource(R.string.updates_not_checked)
                    },
                    style = BridgeyType.itemBody,
                    color = colors.onSurfaceVariant,
                )
            }
            Spacer(Modifier.width(12.dp))
            when {
                state.checking -> StatusPill(stringResource(R.string.updates_checking), BridgeyIcons.Refresh, Tint.NEUTRAL)
                update != null -> StatusPill(stringResource(R.string.updates_available), BridgeyIcons.Download, Tint.BLUE)
                state.lastCheckedAt > 0 -> StatusPill(stringResource(R.string.updates_up_to_date), BridgeyIcons.Check, Tint.GREEN)
            }
        }

        Text(stringResource(R.string.updates_channel), style = BridgeyType.section.copy(letterSpacing = BridgeyType.label.letterSpacing), color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 18.dp).semantics { heading() })
        ChannelPicker(state.channel, actions.setChannel, Modifier.padding(top = 10.dp))
        Text(channelDescription(state.channel), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp))
        Text(stringResource(R.string.updates_channel_note), style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp))

        Row(Modifier.fillMaxWidth().padding(top = 12.dp).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.updates_auto_title), style = BridgeyType.itemTitle)
                Text(stringResource(R.string.updates_auto_detail), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
            OutlinePillButton(stringResource(R.string.updates_check_now), BridgeyIcons.Refresh, actions.checkNow, enabled = !state.checking)
        }

        if (update != null && state.downloadProgress == null) {
            GradientButton(
                stringResource(R.string.updates_install, update.versionName),
                BridgeyIcons.Download,
                actions.install,
                Modifier.fillMaxWidth().padding(top = 12.dp),
            )
        }
        state.downloadProgress?.let { progress ->
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp).height(6.dp),
                color = colors.primary,
                trackColor = colors.surface3,
                strokeCap = StrokeCap.Round,
                drawStopIndicator = {},
            )
        }
        state.status?.takeIf { update == null || state.downloadProgress != null || !it.startsWith("Version ") }?.takeIf { it != "Bridgey is up to date." }?.let {
            Text(it, style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp))
        }

        val notesUrl = update?.notesUrl?.takeIf { it.isNotEmpty() } ?: RELEASES_URL
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.updates_whats_new), style = BridgeyType.section.copy(letterSpacing = BridgeyType.label.letterSpacing), color = colors.onSurfaceVariant, modifier = Modifier.weight(1f).semantics { heading() })
            Row(
                Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button) { actions.openUrl(notesUrl) }.padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(stringResource(R.string.updates_release_notes), style = BridgeyType.smallStrong.copy(fontSize = BridgeyType.itemBody.fontSize), color = colors.primary)
                Icon(BridgeyIcons.OpenInNew, null, tint = colors.primary, modifier = Modifier.size(14.dp))
            }
        }
        val entries = buildList {
            if (update != null) add(update.versionName to (update.notes.lineSequence().map { it.trim().trimStart('-', '*', ' ') }.firstOrNull { it.isNotBlank() } ?: ""))
            add(installedVersion to "")
        }
        Column {
            entries.forEachIndexed { index, (version, line) ->
                WhatsNewRow(
                    version,
                    line.ifBlank { if (index == entries.lastIndex) stringResource(R.string.updates_installed_here) else stringResource(R.string.updates_ready) },
                    first = index == 0,
                    last = index == entries.lastIndex,
                )
            }
        }
    }
}

const val RELEASES_URL = "https://github.com/round-robin-solutions/bridgey/releases"

@Composable
private fun WhatsNewRow(version: String, line: String, first: Boolean, last: Boolean) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 40.dp).drawBehind {
            val x = 5.dp.toPx()
            val top = if (first) size.height / 2 else 0f
            val bottom = if (last) size.height / 2 else size.height
            if (bottom > top) drawLine(colors.outlineVariant, Offset(x, top), Offset(x, bottom), 2.dp.toPx())
        },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.size(10.dp).clip(RoundedCornerShape(5.dp)).then(
                if (first) Modifier.drawBehind { drawRect(androidx.compose.ui.graphics.Brush.linearGradient(listOf(Aurora.Ring[0], Aurora.Ring[2]))) } else Modifier.background(colors.surface4),
            ),
        )
        Text(version, style = BridgeyType.itemBody.copy(fontWeight = BridgeyType.label.fontWeight), color = colors.onSurface, modifier = Modifier.widthIn(min = 40.dp))
        Text(line, style = BridgeyType.itemBody, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
    }
}

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
)

class DevicesSettingsActions(
    val back: () -> Unit = {},
    val openDevice: (DeviceRing) -> Unit = {},
    val addDevice: () -> Unit = {},
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
                                shape, ring.name, ringStateLabel(ring.state), null, Tint.NEUTRAL,
                                onClick = { actions.openDevice(ring) },
                                leading = { DeviceGlyph(ring.state.style(), deviceIcon(ring.platform), 40.dp, iconSize = 18.dp) },
                            ) { Chevron() }
                        }
                    }
                }
            }
        }
        item(key = "add") {
            RowGroup(Modifier.padding(top = 24.dp)) {
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
