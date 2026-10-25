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
    val pairedCount: Int,
    val notificationAppsEnabled: Int,
    val notificationAppsTotal: Int,
    val notificationsFeatureOn: Boolean,
    val appNotificationsEnabled: Boolean,
    val notificationAccessEnabled: Boolean,
    val reduceMotion: Boolean,
    val showPreviews: Boolean,
    val activityCount: Int,
    val update: UpdateUiState,
    val installedVersion: String,
    val now: Long,
)

class SettingsActions(
    val back: () -> Unit = {},
    val openDevices: () -> Unit = {},
    val openNotificationApps: () -> Unit = {},
    val appNotifications: () -> Unit = {},
    val notificationAccess: () -> Unit = {},
    val rename: (String) -> Unit = {},
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

/** Light mode band behind the page bar: status bar + 56 dp + 8 dp. */
private val PageBandHeight = 64.dp

/** A pushed settings page: page bar on the band, then a list. */
@Composable
fun SettingsPage(title: String, onBack: () -> Unit, content: LazyListScope.() -> Unit) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    ScreenBackdrop(bandHeight = statusTop + PageBandHeight) {
        Column(Modifier.fillMaxSize()) {
            OnBand { PageBar(title, onBack) }
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = navBottom + 32.dp), content = content)
        }
    }
}

/** Settings: Updates lead, with the latest release inline; then the rest, one level each. */
@Composable
fun SettingsScreen(state: SettingsState, actions: SettingsActions) {
    var renaming by rememberSaveable { mutableStateOf(false) }
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    SettingsPage(stringResource(R.string.settings_title), actions.back) {
        item(key = "updates.label") { SectionLabel(stringResource(R.string.settings_updates), Modifier.padding(top = 20.dp)) }
        item(key = "updates") { UpdatesCard(state.update, state.installedVersion, state.now, actions) }

        item(key = "more.label") { SectionLabel(stringResource(R.string.settings_more), Modifier.padding(top = 24.dp)) }
        item(key = "more") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_devices),
                        androidx.compose.ui.res.pluralStringResource(R.plurals.settings_devices_count, state.pairedCount, state.pairedCount),
                        BridgeyIcons.Devices, Tint.BLUE, onClick = actions.openDevices,
                    ) { Chevron() }
                }
                if (state.notificationsFeatureOn) {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_notification_apps),
                            stringResource(R.string.settings_notification_apps_count, state.notificationAppsEnabled, state.notificationAppsTotal),
                            BridgeyIcons.Notifications, Tint.PURPLE, onClick = actions.openNotificationApps,
                        ) { Chevron() }
                    }
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_forwarding),
                            stringResource(if (state.notificationAccessEnabled) R.string.settings_forwarding_on else R.string.settings_forwarding_off),
                            BridgeyIcons.Notifications, if (state.notificationAccessEnabled) Tint.GREEN else Tint.NEUTRAL,
                            detailWarning = !state.notificationAccessEnabled,
                            onClick = actions.notificationAccess,
                        ) { ManageLabel(state.notificationAccessEnabled) }
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
                row { shape ->
                    ListRow(shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_detail), BridgeyIcons.ContentPaste, Tint.BLUE)
                }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_reduce_motion), stringResource(R.string.settings_reduce_motion_detail),
                        BridgeyIcons.Animation, Tint.NEUTRAL, state.reduceMotion, actions.setReduceMotion,
                    )
                }
            }
        }

        item(key = "phone.label") { SectionLabel(stringResource(R.string.settings_this_phone), Modifier.padding(top = 24.dp)) }
        item(key = "phone") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_device_name), state.deviceName, BridgeyIcons.Smartphone, Tint.BLUE,
                        onClick = { renaming = true }, onClickLabel = stringResource(R.string.action_rename),
                    ) { Icon(BridgeyIcons.Edit, null, tint = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.size(20.dp)) }
                }
            }
        }

        item(key = "privacy.label") { SectionLabel(stringResource(R.string.settings_privacy), Modifier.padding(top = 24.dp)) }
        item(key = "privacy") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                row { shape ->
                    ListRow(shape, stringResource(R.string.settings_activity), stringResource(R.string.settings_activity_detail), BridgeyIcons.Update, Tint.PURPLE) {
                        OutlinePillButton(
                            stringResource(R.string.action_clear), null, { confirmClear = true },
                            enabled = state.activityCount > 0,
                        )
                    }
                }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_show_previews), stringResource(R.string.settings_show_previews_detail),
                        BridgeyIcons.ContentPaste, if (state.showPreviews) Tint.BLUE else Tint.NEUTRAL, state.showPreviews, actions.setShowPreviews,
                    )
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_diagnostics), stringResource(R.string.settings_diagnostics_detail),
                        BridgeyIcons.BugReport, Tint.NEUTRAL, onClick = actions.exportDiagnostics, onClickLabel = stringResource(R.string.action_share),
                    ) { Icon(BridgeyIcons.IosShare, null, tint = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.size(20.dp)) }
                }
            }
        }

        item(key = "turnoff") {
            Box(Modifier.fillMaxWidth().padding(top = 24.dp), contentAlignment = Alignment.Center) {
                OutlinePillButton(
                    stringResource(R.string.settings_turn_off), BridgeyIcons.PowerSettingsNew, actions.turnOff,
                    contentColor = BridgeyTheme.colors.warn,
                )
            }
        }
        item(key = "credit") { Credit(state.installedVersion, actions) }
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
private fun Credit(version: String, actions: SettingsActions) {
    Column(Modifier.fillMaxWidth().padding(top = 16.dp, start = 24.dp, end = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            stringResource(R.string.about_credit, version),
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
    val globalFeatures: Map<BridgeyFeature, Boolean>,
    val directCallsEnabled: Boolean,
    val rings: List<DeviceRing>,
)

class DevicesSettingsActions(
    val back: () -> Unit = {},
    val setGlobal: (BridgeyFeature, Boolean) -> Unit = { _, _ -> },
    val setDirectCalls: (Boolean) -> Unit = {},
    val openDevice: (DeviceRing) -> Unit = {},
)

/** Devices and permissions: what this phone shares with every device, then each paired device. */
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
        item(key = "global.label") { SectionLabel(stringResource(R.string.devices_everywhere), Modifier.padding(top = 24.dp)) }
        item(key = "global.note") { Note(stringResource(R.string.devices_everywhere_detail), Modifier.padding(start = 32.dp, end = 32.dp, top = 4.dp)) }
        item(key = "global") {
            RowGroup(Modifier.padding(top = 8.dp)) {
                BridgeyFeature.entries.forEach { feature ->
                    row { shape ->
                        val (icon, tint) = permissionVisual(feature)
                        val on = state.globalFeatures[feature] != false
                        SwitchRow(
                            shape, globalFeatureTitle(feature), null, icon, if (on) tint else Tint.NEUTRAL, on,
                            { actions.setGlobal(feature, it) }, compact = true,
                        )
                    }
                }
                if (state.globalFeatures[BridgeyFeature.CALLS] != false) {
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.devices_direct_calls), stringResource(R.string.devices_direct_calls_detail),
                            BridgeyIcons.Call, if (state.directCallsEnabled) Tint.GREEN else Tint.NEUTRAL, state.directCallsEnabled, actions.setDirectCalls,
                            compact = true,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun globalFeatureTitle(feature: BridgeyFeature): String = when (feature) {
    BridgeyFeature.FIND_DEVICE -> stringResource(R.string.feature_find)
    BridgeyFeature.PING -> stringResource(R.string.feature_ping)
    else -> permissionTitle(feature)
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
