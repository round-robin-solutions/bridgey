package dev.bridgey.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
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
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.agents.AgentGrant
import dev.bridgey.android.agents.AgentInfo
import dev.bridgey.android.agents.AskRecord
import dev.bridgey.android.agents.AuditAction
import dev.bridgey.android.agents.AuditEntry
import dev.bridgey.android.agents.GrantPreset
import dev.bridgey.android.agents.GrantShown
import dev.bridgey.android.agents.GrantView
import dev.bridgey.android.agents.GrantWindow
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.SpringTabIndicator
import dev.bridgey.android.ui.motion.springIn
import dev.bridgey.android.ui.motion.tabContentTransform
import dev.bridgey.android.ui.theme.Aurora
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop

/** An agent's page, "Devices and permissions": its grants and its activity. */
data class AgentPageState(
    val ring: DeviceRing,
    val info: AgentInfo,
    val connected: Boolean,
    val grants: List<GrantView>,
    val activity: List<AuditEntry>,
    /** Right after an invite pairing: "Start with" and the presets. */
    val showPresets: Boolean,
    /** The folder name under Download/Bridgey for Send you files. */
    val folderName: String,
    val now: Long,
)

class AgentPageActions(
    val back: () -> Unit = {},
    val forget: () -> Unit = {},
    val disconnect: () -> Unit = {},
    val connect: () -> Unit = {},
    val setGrant: (AgentGrant, Boolean, GrantWindow?) -> Unit = { _, _, _ -> },
    val applyPreset: (GrantPreset, GrantWindow) -> Unit = { _, _ -> },
    val export: () -> Unit = {},
    val clear: () -> Unit = {},
)

enum class AgentTab { PERMISSIONS, ACTIVITY }

private val AgentBand = 160.dp

/**
 * The device page of an agent (the bridgey command): who it is, then Permissions (one row per grant in the shared
 * wording's order, each with its state and a switch; switching on asks how long) and Activity (its audit list,
 * export and clear). Grants start off; nothing here is ever on by default.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun AgentDeviceScreen(state: AgentPageState, actions: AgentPageActions) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    var tab by rememberSaveable { mutableStateOf(AgentTab.PERMISSIONS) }
    var asking by remember { mutableStateOf<AgentGrant?>(null) }
    var askingPreset by remember { mutableStateOf<GrantPreset?>(null) }
    var clearing by remember { mutableStateOf(false) }
    val motion = LocalMotion.current
    ScreenBackdrop(bandHeight = statusTop + AgentBand, modifier = Modifier.semantics { testTagsAsResourceId = true }) {
        Column(Modifier.fillMaxSize()) {
            OnBand {
                Column {
                    AgentBar(state, actions)
                    AgentHeader(state)
                }
            }
            AgentTabs(tab, { tab = it }, Modifier.padding(top = 16.dp))
            AnimatedContent(
                targetState = tab,
                transitionSpec = { motion.tabContentTransform(forward = targetState.ordinal > initialState.ordinal) },
                label = "agentTab",
                modifier = Modifier.weight(1f),
            ) { shown ->
                val padding = PaddingValues(bottom = navBottom + 24.dp)
                when (shown) {
                    AgentTab.PERMISSIONS -> AgentPermissions(state, padding, onSwitch = { grant, on ->
                        if (on) asking = grant else actions.setGrant(grant, false, null)
                    }, onPreset = { askingPreset = it })
                    AgentTab.ACTIVITY -> AgentActivity(state, padding, actions.export) { clearing = true }
                }
            }
        }
    }
    asking?.let { grant ->
        WindowDialog(onPick = { window -> asking = null; actions.setGrant(grant, true, window) }, onDismiss = { asking = null })
    }
    askingPreset?.let { preset ->
        WindowDialog(onPick = { window -> askingPreset = null; actions.applyPreset(preset, window) }, onDismiss = { askingPreset = null })
    }
    if (clearing) {
        AlertDialog(
            onDismissRequest = { clearing = false },
            containerColor = BridgeyTheme.colors.surface2,
            title = { Text(stringResource(R.string.agent_clear)) },
            text = { Text(stringResource(R.string.agent_clear_confirm, state.ring.name)) },
            confirmButton = {
                TextButton(onClick = { clearing = false; actions.clear() }, modifier = Modifier.testTag("agent-clear-confirm")) {
                    Text(stringResource(R.string.action_clear), color = BridgeyTheme.colors.warn)
                }
            },
            dismissButton = { TextButton(onClick = { clearing = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

@Composable
private fun AgentBar(state: AgentPageState, actions: AgentPageActions) {
    var menu by remember { mutableStateOf(false) }
    PageBar(title = stringResource(R.string.agent_page), onBack = actions.back) {
        Box {
            BarIconButton(BridgeyIcons.MoreVert, stringResource(R.string.device_more), { menu = true })
            DropdownMenu(
                expanded = menu,
                onDismissRequest = { menu = false },
                modifier = Modifier.springIn(),
                containerColor = BridgeyTheme.colors.surface2,
                shape = RoundedCornerShape(16.dp),
            ) {
                if (state.connected) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.device_disconnect, state.ring.name)) },
                        leadingIcon = { Icon(BridgeyIcons.PowerSettingsNew, null) },
                        onClick = { menu = false; actions.disconnect() },
                    )
                } else if (state.ring.reconnect?.disconnectedByUser == true) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.device_connect, state.ring.name)) },
                        leadingIcon = { Icon(BridgeyIcons.Link, null) },
                        onClick = { menu = false; actions.connect() },
                    )
                }
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.device_forget, state.ring.name), color = BridgeyTheme.colors.warn) },
                    leadingIcon = { Icon(BridgeyIcons.Delete, null, tint = BridgeyTheme.colors.warn) },
                    onClick = { menu = false; actions.forget() },
                )
            }
        }
    }
}

@Composable
private fun AgentHeader(state: AgentPageState) {
    Row(
        Modifier.fillMaxWidth().height(88.dp).padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        DeviceGlyph(state.ring.state.style(), BridgeyIcons.Terminal, 64.dp)
        Column(Modifier.weight(1f)) {
            Text(
                state.ring.name,
                style = BridgeyType.deviceName,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatusPill(stringResource(R.string.agent_badge), BridgeyIcons.Terminal, Tint.PURPLE)
                RoutePill(state.ring.state, ringStatusLabel(state.ring), state.ring.route)
            }
            state.info.os?.takeIf { it.isNotBlank() }?.let { os ->
                Text(
                    stringResource(R.string.agent_subtitle, os),
                    style = BridgeyType.itemBody,
                    color = BridgeyTheme.colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun AgentTabs(tab: AgentTab, onTab: (AgentTab) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Box(modifier.fillMaxWidth().height(48.dp)) {
        Row(Modifier.fillMaxSize().padding(horizontal = 8.dp)) {
            AgentTab.entries.forEach { entry ->
                val selected = entry == tab
                Box(
                    Modifier.weight(1f).fillMaxSize().selectable(selected = selected, role = Role.Tab) { onTab(entry) }
                        .testTag("agent-tab-${entry.name.lowercase()}"),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(if (entry == AgentTab.PERMISSIONS) R.string.agent_tab_permissions else R.string.agent_tab_activity),
                        style = BridgeyType.label,
                        color = if (selected) colors.onSurface else colors.onSurfaceVariant,
                    )
                }
            }
        }
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(1.dp).background(colors.outlineVariant))
        SpringTabIndicator(
            selected = tab.ordinal,
            count = AgentTab.entries.size,
            brush = Aurora.ringHorizontal(),
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 8.dp),
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AgentPermissions(
    state: AgentPageState,
    contentPadding: PaddingValues,
    onSwitch: (AgentGrant, Boolean) -> Unit,
    onPreset: (GrantPreset) -> Unit,
) {
    val context = LocalContext.current
    LazyColumn(Modifier.fillMaxSize(), contentPadding = contentPadding) {
        if (state.showPresets) {
            item(key = "presets") {
                Column(
                    Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp))
                        .background(BridgeyTheme.colors.surface1).padding(horizontal = 14.dp, vertical = 12.dp),
                ) {
                    Text(stringResource(R.string.agent_presets), style = BridgeyType.itemTitle)
                    FlowRow(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        GrantPreset.entries.forEach { preset ->
                            val on = preset.grants.all { grant -> state.grants.firstOrNull { it.grant == grant }?.state == GrantShown.ON }
                            // Opacity only, and still with reduced motion.
                            androidx.compose.animation.Crossfade(targetState = on, animationSpec = LocalMotion.current.fadeSpec(), label = "preset") { applied ->
                                TonalPillButton(
                                    presetTitle(preset),
                                    onClick = { if (!applied) onPreset(preset) },
                                    tint = if (applied) Tint.GREEN else Tint.BLUE,
                                    modifier = Modifier.testTag("agent-preset-${preset.name.lowercase()}"),
                                )
                            }
                        }
                    }
                }
            }
        }
        item(key = "section") {
            SectionLabel(stringResource(R.string.agent_section), Modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 8.dp))
        }
        item(key = "grants") {
            RowGroup {
                state.grants.forEach { view ->
                    row { shape ->
                        val on = view.state == GrantShown.ON
                        val grantable = view.grant.grantable
                        val stateText = grantStateText(context, view, state.now)
                        ListRow(
                            shape = shape,
                            title = grantTitleText(view.grant),
                            detail = grantDetailText(view.grant, state.folderName) + "\n" + stateText,
                            icon = grantIcon(view.grant),
                            tint = if (on) grantTint(view.grant) else Tint.NEUTRAL,
                            compact = true,
                            detailWarning = view.state == GrantShown.WAITING,
                            modifier = Modifier.semantics(mergeDescendants = true) {}.testTag("agent-grant-${view.grant.key}"),
                            onClick = if (grantable) ({ onSwitch(view.grant, !on) }) else null,
                            role = Role.Switch,
                        ) {
                            BridgeySwitch(checked = on, onCheckedChange = null, enabled = grantable)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AgentActivity(state: AgentPageState, contentPadding: PaddingValues, export: () -> Unit, clear: () -> Unit) {
    val context = LocalContext.current
    LazyColumn(Modifier.fillMaxSize(), contentPadding = contentPadding) {
        item(key = "actions") {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinePillButton(stringResource(R.string.agent_export), BridgeyIcons.IosShare, export, Modifier.testTag("agent-export"), enabled = state.activity.isNotEmpty())
                OutlinePillButton(stringResource(R.string.agent_clear), BridgeyIcons.Delete, clear, Modifier.testTag("agent-clear"), enabled = state.activity.isNotEmpty())
            }
        }
        if (state.activity.isEmpty()) {
            item(key = "empty") {
                Note(stringResource(R.string.agent_empty), Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 40.dp), center = true)
            }
        }
        items(state.activity, key = { "${it.at}-${it.action}-${it.outcome}-${it.detail}" }) { entry ->
            val (icon, tint) = auditVisual(entry.action)
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 20.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                IconTile(icon, tint, size = 36.dp, corner = 12.dp, iconSize = 20.dp)
                Column(Modifier.weight(1f)) {
                    val (title, shownDetail) = auditWords(entry.action, entry.detail)
                    Text(title, style = BridgeyType.itemTitle)
                    val detail = listOfNotNull(auditOutcome(entry.outcome), shownDetail).joinToString(" · ")
                    Text(detail, style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                Text(shortTime(context, entry.at, state.now), style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant)
            }
        }
    }
}

/** "How long?": For 1 hour, Today, 7 days, Until I turn it off. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun WindowDialog(onPick: (GrantWindow) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = BridgeyTheme.colors.surface2,
        title = { Text(stringResource(R.string.agent_window_ask)) },
        text = {
            Column(Modifier.semantics { testTagsAsResourceId = true }) {
                GrantWindow.entries.forEach { window ->
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp))
                            .clickable(role = Role.Button) { onPick(window) }.testTag("agent-window-${window.wire}")
                            .padding(horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) { Text(windowTitle(window), style = BridgeyType.bodyText) }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}

@Composable
fun windowTitle(window: GrantWindow): String = stringResource(
    when (window) {
        GrantWindow.HOUR -> R.string.agent_window_1h
        GrantWindow.TODAY -> R.string.agent_window_today
        GrantWindow.WEEK -> R.string.agent_window_7d
        GrantWindow.FOREVER -> R.string.agent_window_forever
    },
)

@Composable
private fun presetTitle(preset: GrantPreset): String = stringResource(
    when (preset) {
        GrantPreset.MESSAGES -> R.string.agent_preset_messages
        GrantPreset.FILES -> R.string.agent_preset_files
        GrantPreset.FIND -> R.string.agent_preset_find
    },
)

@Composable
fun grantTitleText(grant: AgentGrant): String = dev.bridgey.android.agents.grantTitle(LocalContext.current, grant)

@Composable
private fun grantDetailText(grant: AgentGrant, folder: String): String = when (grant) {
    AgentGrant.FILES -> stringResource(R.string.agent_grant_files_detail, folder)
    AgentGrant.CLIPBOARD -> stringResource(R.string.agent_grant_clipboard_detail)
    AgentGrant.CLIPBOARD_REQUEST -> stringResource(R.string.agent_grant_clipboard_request_detail)
    AgentGrant.NOTIFY -> stringResource(R.string.agent_grant_notify_detail)
    AgentGrant.ASK -> stringResource(R.string.agent_grant_ask_detail)
    AgentGrant.RING -> stringResource(R.string.agent_grant_ring_detail)
    AgentGrant.BATTERY -> stringResource(R.string.agent_grant_battery_detail)
    AgentGrant.CODES -> stringResource(R.string.agent_grant_codes_detail)
    AgentGrant.NOTIFICATIONS -> stringResource(R.string.agent_grant_notifications_detail)
}

/** "On until 15:40", "On until Fri 15:40", "On until you turn it off", "Waiting for you" or "Off". */
fun grantStateText(context: android.content.Context, view: GrantView, now: Long): String = when (view.state) {
    GrantShown.ON -> view.expiresAt?.let { context.getString(R.string.agent_until_time, untilTime(context, it, now)) }
        ?: context.getString(R.string.agent_until_forever)
    GrantShown.WAITING -> context.getString(R.string.agent_state_waiting)
    GrantShown.OFF -> context.getString(R.string.agent_state_off)
}

private fun untilTime(context: android.content.Context, at: Long, now: Long): String {
    val zone = java.time.ZoneId.systemDefault()
    val sameDay = java.time.Instant.ofEpochMilli(at).atZone(zone).toLocalDate() == java.time.Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val flags = android.text.format.DateUtils.FORMAT_SHOW_TIME or
        (if (sameDay) 0 else android.text.format.DateUtils.FORMAT_SHOW_WEEKDAY or android.text.format.DateUtils.FORMAT_ABBREV_WEEKDAY)
    return android.text.format.DateUtils.formatDateTime(context, at, flags)
}

private fun shortTime(context: android.content.Context, at: Long, now: Long): String {
    val zone = java.time.ZoneId.systemDefault()
    val sameDay = java.time.Instant.ofEpochMilli(at).atZone(zone).toLocalDate() == java.time.Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val flags = if (sameDay) android.text.format.DateUtils.FORMAT_SHOW_TIME else android.text.format.DateUtils.FORMAT_SHOW_DATE or android.text.format.DateUtils.FORMAT_ABBREV_MONTH
    return android.text.format.DateUtils.formatDateTime(context, at, flags)
}

private fun grantIcon(grant: AgentGrant) = when (grant) {
    AgentGrant.FILES -> BridgeyIcons.Folder
    AgentGrant.CLIPBOARD, AgentGrant.CLIPBOARD_REQUEST -> BridgeyIcons.ContentPaste
    AgentGrant.NOTIFY, AgentGrant.NOTIFICATIONS -> BridgeyIcons.Notifications
    AgentGrant.ASK -> BridgeyIcons.Info
    AgentGrant.RING -> BridgeyIcons.Sensors
    AgentGrant.BATTERY -> BridgeyIcons.Battery5Bar
    AgentGrant.CODES -> BridgeyIcons.Shield
}

private fun grantTint(grant: AgentGrant) = when (grant) {
    AgentGrant.FILES, AgentGrant.BATTERY -> Tint.GREEN
    AgentGrant.NOTIFY, AgentGrant.ASK, AgentGrant.CODES, AgentGrant.NOTIFICATIONS -> Tint.PURPLE
    else -> Tint.BLUE
}

private fun auditVisual(action: String) = when (action) {
    AuditAction.PAIR, AuditAction.FORGET -> BridgeyIcons.Link to Tint.BLUE
    AuditAction.GRANT_CHANGE, AuditAction.GRANT_REQUEST, AuditAction.GRANT_EXPIRED -> BridgeyIcons.Lock to Tint.PURPLE
    AuditAction.NOTIFY -> BridgeyIcons.Notifications to Tint.PURPLE
    AuditAction.ASK, AuditAction.ANSWER -> BridgeyIcons.Info to Tint.PURPLE
    AuditAction.RING, AuditAction.PING -> BridgeyIcons.Sensors to Tint.BLUE
    AuditAction.BATTERY -> BridgeyIcons.Battery5Bar to Tint.GREEN
    AuditAction.CLIPBOARD_SET, AuditAction.CLIPBOARD_REQUEST -> BridgeyIcons.ContentPaste to Tint.BLUE
    AuditAction.FILES_RECEIVE -> BridgeyIcons.Folder to Tint.GREEN
    AuditAction.CODES_READ -> BridgeyIcons.Shield to Tint.PURPLE
    else -> BridgeyIcons.Info to Tint.NEUTRAL
}

@Composable
private fun auditTitle(action: String): String = when (action) {
    AuditAction.PAIR -> stringResource(R.string.agent_audit_pair)
    AuditAction.GRANT_CHANGE -> stringResource(R.string.agent_audit_grant_change)
    AuditAction.GRANT_REQUEST -> stringResource(R.string.agent_audit_grant_request)
    AuditAction.GRANT_EXPIRED -> stringResource(R.string.agent_audit_grant_expired)
    AuditAction.NOTIFY -> stringResource(R.string.agent_audit_notify)
    AuditAction.ASK -> stringResource(R.string.agent_audit_ask)
    AuditAction.ANSWER -> stringResource(R.string.agent_audit_answer)
    AuditAction.RING -> stringResource(R.string.agent_audit_ring)
    AuditAction.PING -> stringResource(R.string.agent_audit_ping)
    AuditAction.BATTERY -> stringResource(R.string.agent_audit_battery)
    AuditAction.CLIPBOARD_SET -> stringResource(R.string.agent_audit_clipboard_set)
    AuditAction.CLIPBOARD_REQUEST -> stringResource(R.string.agent_audit_clipboard_request)
    AuditAction.FILES_RECEIVE -> stringResource(R.string.agent_audit_files_receive)
    AuditAction.CODES_READ -> stringResource(R.string.agent_audit_codes_read)
    AuditAction.FORGET -> stringResource(R.string.agent_audit_forget)
    else -> action
}

/**
 * The row's title and detail in the wording table's words: a code read names its service ("Read the code from
 * HDFC Bank", or "Read a code" with ×N), and grant changes show the permission and its window, not their keys.
 */
@Composable
private fun auditWords(action: String, detail: String?): Pair<String, String?> {
    if (action == AuditAction.CODES_READ) {
        val service = detail?.substringBeforeLast(",", "")?.trim().orEmpty()
        val count = detail?.substringAfterLast(",", "")?.trim()?.toIntOrNull() ?: 1
        return if (count == 1 && service.isNotEmpty()) {
            stringResource(R.string.agent_audit_codes_read_from, service) to null
        } else {
            stringResource(R.string.agent_audit_codes_read) to (if (count > 1) stringResource(R.string.agent_audit_count, count) else service.ifEmpty { null })
        }
    }
    if (detail != null && action in setOf(AuditAction.GRANT_CHANGE, AuditAction.GRANT_EXPIRED, AuditAction.GRANT_REQUEST)) {
        val words = detail.split(' ').filter { it.isNotBlank() }.map { token ->
            AgentGrant.of(token)?.let { grantTitleText(it) } ?: windowText(token) ?: token
        }
        return auditTitle(action) to words.joinToString(if (action == AuditAction.GRANT_REQUEST) ", " else ", ")
    }
    return auditTitle(action) to detail
}

@Composable
private fun windowText(token: String): String? = when (token) {
    "1h" -> stringResource(R.string.agent_window_1h)
    "today" -> stringResource(R.string.agent_window_today)
    "7d" -> stringResource(R.string.agent_window_7d)
    "forever" -> stringResource(R.string.agent_window_forever)
    else -> null
}

@Composable
private fun auditOutcome(outcome: String): String = when {
    outcome == "ok" -> stringResource(R.string.agent_outcome_ok)
    outcome == "delivered" -> stringResource(R.string.agent_outcome_delivered)
    outcome.startsWith("answered:") -> stringResource(R.string.agent_outcome_answered, outcome.removePrefix("answered:"))
    outcome == "declined" -> stringResource(R.string.agent_outcome_declined)
    outcome == "dismissed" -> stringResource(R.string.agent_outcome_dismissed)
    outcome == "expired" -> stringResource(R.string.agent_outcome_expired)
    outcome == "rate_limited" -> stringResource(R.string.agent_outcome_rate_limited)
    outcome == "not_granted" -> stringResource(R.string.agent_outcome_not_granted)
    outcome == "invalid" -> stringResource(R.string.agent_outcome_invalid)
    else -> outcome
}

/** The pairing screen's entry for remote pairing by invite. */
@Composable
fun InviteEntryRow(onClick: () -> Unit, modifier: Modifier = Modifier) {
    ListRow(
        shape = RoundedCornerShape(16.dp),
        title = stringResource(R.string.agent_invite_title),
        detail = stringResource(R.string.agent_invite_detail),
        icon = BridgeyIcons.Public,
        tint = Tint.PURPLE,
        compact = true,
        onClick = onClick,
        role = Role.Button,
        modifier = modifier.testTag("agent-invite-entry"),
    ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
}

/** Why an invite was refused, for the paste field. */
enum class InviteProblem { INVALID, EXPIRED, OTHER_SERVICE, NEEDS_CONNECT }

/**
 * Remote pairing by invite: paste the link from bridgey pair (or arrive with one from a bridgey:// link), then
 * "Pair with <name>?". [parse] reads the text; [start] starts the pairing and returns false when Connect away from
 * home is off.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun InviteDialog(
    initial: String?,
    parse: (String) -> Pair<dev.bridgey.android.agents.AgentInvite?, InviteProblem?>,
    start: (dev.bridgey.android.agents.AgentInvite) -> Boolean,
    readClipboard: () -> String,
    onScan: () -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    var text by rememberSaveable { mutableStateOf(initial.orEmpty()) }
    var problem by remember { mutableStateOf<InviteProblem?>(null) }
    var invite by remember { mutableStateOf<dev.bridgey.android.agents.AgentInvite?>(null) }
    // A link that came in (bridgey://pair#...) goes straight to the question.
    androidx.compose.runtime.LaunchedEffect(initial) {
        if (!initial.isNullOrBlank()) {
            val (parsed, error) = parse(initial)
            invite = parsed
            problem = error
        }
    }
    val confirming = invite
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface2,
        icon = { IconTile(BridgeyIcons.Public, Tint.PURPLE, size = 48.dp, corner = 16.dp, iconSize = 26.dp) },
        title = {
            Text(
                if (confirming != null) stringResource(R.string.agent_invite_confirm_title, confirming.name) else stringResource(R.string.agent_invite_title),
                style = BridgeyType.cardTitle,
                modifier = Modifier.semantics { heading() },
            )
        },
        text = {
            Column(Modifier.semantics { testTagsAsResourceId = true }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (confirming != null) {
                    Text(stringResource(R.string.agent_invite_confirm_body), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
                } else {
                    Text(stringResource(R.string.agent_invite_paste), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
                    OutlinedTextField(
                        value = text,
                        onValueChange = { text = it.take(2_048); problem = null },
                        label = { Text(stringResource(R.string.agent_invite_field)) },
                        singleLine = true,
                        isError = problem != null,
                        modifier = Modifier.fillMaxWidth().testTag("agent-invite-field"),
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        TonalPillButton(stringResource(R.string.agent_invite_scan), onScan, Modifier.testTag("agent-invite-scan"), tint = Tint.PURPLE)
                        TonalPillButton(stringResource(R.string.agent_invite_paste_button), { text = readClipboard().take(2_048); problem = null }, tint = Tint.NEUTRAL)
                    }
                }
                AnimatedVisibility(
                    visible = problem != null,
                    enter = fadeIn(LocalMotion.current.fadeSpec()) + scaleIn(LocalMotion.current.spatial(LocalMotion.current.pop), initialScale = 0.96f),
                    exit = fadeOut(LocalMotion.current.fadeSpec()) + scaleOut(LocalMotion.current.fadeSpec(), targetScale = 0.96f),
                ) {
                    Text(
                        stringResource(
                            when (problem) {
                                InviteProblem.EXPIRED -> R.string.agent_invite_expired
                                InviteProblem.OTHER_SERVICE -> R.string.agent_invite_other_service
                                InviteProblem.NEEDS_CONNECT -> R.string.agent_invite_needs_connect
                                else -> R.string.agent_invite_invalid
                            },
                        ),
                        style = BridgeyType.itemBody,
                        color = colors.warn,
                        modifier = Modifier.testTag("agent-invite-error"),
                    )
                }
            }
        },
        confirmButton = {
            if (confirming != null) {
                TextButton(
                    onClick = { if (start(confirming)) onDismiss() else { problem = InviteProblem.NEEDS_CONNECT; invite = null } },
                    modifier = Modifier.testTag("agent-invite-pair"),
                ) { Text(stringResource(R.string.agent_invite_pair), style = BridgeyType.label, color = colors.primary) }
            } else {
                TextButton(
                    onClick = {
                        val (parsed, error) = parse(text)
                        invite = parsed
                        problem = error
                    },
                    enabled = text.isNotBlank(),
                    modifier = Modifier.testTag("agent-invite-continue"),
                ) { Text(stringResource(R.string.agent_invite_continue), style = BridgeyType.label, color = colors.primary) }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel), style = BridgeyType.label, color = colors.onSurfaceVariant) }
        },
    )
}

/**
 * An agent's question answered in Bridgey: on Android 11 and older when it needs the phone unlocked (the
 * notification has no buttons then), or after a tap on the notification.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun AskDialog(ask: AskRecord, deviceName: String, onAnswer: (String?, String?) -> Unit, onDismiss: () -> Unit) {
    val colors = BridgeyTheme.colors
    var text by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface2,
        title = { Text(ask.title, style = BridgeyType.cardTitle) },
        text = {
            Column(Modifier.semantics { testTagsAsResourceId = true }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(deviceName, style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                ask.body?.let { Text(it, style = BridgeyType.bodyText) }
                ask.from?.let { Text(stringResource(R.string.agent_from, it), style = BridgeyType.itemBody, color = colors.onSurfaceVariant) }
                if (ask.allowText) {
                    OutlinedTextField(
                        value = text,
                        onValueChange = { text = it.take(dev.bridgey.android.agents.ASK_TEXT_MAX_CHARS) },
                        label = { Text(ask.textHint ?: stringResource(R.string.agent_reply_hint)) },
                        modifier = Modifier.fillMaxWidth().testTag("agent-ask-text"),
                    )
                }
                if (ask.options.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        ask.options.forEach { option ->
                            TonalPillButton(option.label, { onAnswer(option.id, null) }, Modifier.testTag("agent-ask-option-${option.id}"))
                        }
                    }
                }
                Spacer(Modifier.size(0.dp))
            }
        },
        confirmButton = {
            if (ask.allowText) {
                TextButton(onClick = { onAnswer(null, text) }, enabled = text.isNotBlank(), modifier = Modifier.testTag("agent-ask-send")) {
                    Text(stringResource(R.string.agent_ask_send), color = colors.primary)
                }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_close)) } },
    )
}
