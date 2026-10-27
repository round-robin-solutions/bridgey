package dev.bridgey.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.setup.OemChecklist
import dev.bridgey.android.setup.OemStep
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.QuickStep
import dev.bridgey.android.setup.SetupChoice
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupGroup
import dev.bridgey.android.setup.SetupPath
import dev.bridgey.android.setup.SetupScreen
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.setup.StepOutcome
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop

/** A Mac setup's Pair step can pair with: found on this network, or already paired. */
data class SetupNearbyMac(val key: String, val name: String, val paired: Boolean)

/** Everything the setup screens show. [settings] is the same state the Settings pages read. */
data class SetupUiState(
    val flow: SetupState,
    val settings: SettingsState,
    val pairedNames: List<String> = emptyList(),
    val nearby: List<SetupNearbyMac> = emptyList(),
    val oem: OemChecklist? = null,
    /** Opened again from Settings: Welcome shows a back arrow. */
    val rerun: Boolean = false,
) {
    /** Whether a quick step's permission is granted (or a Mac is paired) right now. */
    fun stepDone(step: QuickStep): Boolean = when (step) {
        QuickStep.PAIR -> pairedNames.isNotEmpty()
        QuickStep.NOTIFICATION_ACCESS -> settings.notificationAccessEnabled
        QuickStep.BATTERY -> settings.batteryExempt
    }
}

class SetupActions(
    val event: (SetupEvent) -> Unit = {},
    /** The real settings: what setup changes is applied at once. */
    val settings: SettingsActions = SettingsActions(),
    val pair: (SetupNearbyMac) -> Unit = {},
    val addDevice: () -> Unit = {},
    val lookForDevices: () -> Unit = {},
    val allowNotificationAccess: () -> Unit = {},
    val allowBattery: () -> Unit = {},
    val openOemStep: (OemStep) -> Unit = {},
    /** "Open Clipboard settings": the full page, above setup; Back returns here. */
    val openSection: (SettingsSection) -> Unit = {},
    val openSettings: () -> Unit = {},
    val start: () -> Unit = {},
    /** Back on Welcome: leave setup (it is offered again next launch until it is finished). */
    val exit: () -> Unit = {},
)

/** First-run setup: Welcome, the quick steps, the advanced groups, Done. */
@Composable
fun SetupScreen(state: SetupUiState, actions: SetupActions) {
    // A granted permission or a new pairing ticks its quick step (also when setup was left and resumed).
    QuickStep.entries.forEach { step ->
        val done = state.stepDone(step)
        LaunchedEffect(step, done) { if (done && state.flow.outcomes[step] != StepOutcome.DONE) actions.event(SetupEvent.StepDone(step)) }
    }
    when (val screen = state.flow.screen) {
        SetupScreen.Welcome -> WelcomePage(state, actions)
        is SetupScreen.Quick -> QuickStepPage(screen.step, state, actions)
        is SetupScreen.Advanced -> AdvancedPage(screen.group, state, actions)
        is SetupScreen.Done -> DonePage(screen.path, state, actions)
    }
}

@Composable
private fun WelcomePage(state: SetupUiState, actions: SetupActions) {
    val density = LocalDensity.current
    var headerHeight by remember { mutableStateOf(280.dp) }
    ScreenBackdrop(bandHeight = headerHeight) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp)) {
            item(key = "header") {
                OnBand {
                    Column(
                        Modifier.fillMaxWidth().onSizeChanged { headerHeight = with(density) { it.height.toDp() } }
                            .statusBarsPadding().padding(bottom = 28.dp),
                    ) {
                        if (state.rerun) {
                            Row(Modifier.height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                BarIconButton(BridgeyIcons.ArrowBack, stringResource(R.string.action_back), actions.exit)
                            }
                        } else {
                            Spacer(Modifier.height(40.dp))
                        }
                        Column(Modifier.padding(horizontal = 28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Image(painterResource(R.drawable.ic_app_mark), contentDescription = null, modifier = Modifier.size(52.dp))
                            Text(
                                stringResource(R.string.setup_welcome_title),
                                style = BridgeyType.deviceName.copy(fontSize = BridgeyType.deviceName.fontSize * 1.15f, lineHeight = BridgeyType.deviceName.lineHeight * 1.15f),
                                color = BridgeyTheme.colors.onSurface,
                                modifier = Modifier.padding(top = 8.dp).semantics { heading() },
                            )
                            Text(stringResource(R.string.setup_welcome_body), style = BridgeyType.bodyText, color = BridgeyTheme.colors.onSurfaceVariant)
                        }
                    }
                }
            }
            item(key = "quick") {
                ChoiceCard(
                    title = stringResource(R.string.setup_quick_title),
                    badge = stringResource(R.string.setup_quick_badge),
                    body = stringResource(R.string.setup_quick_body),
                    icon = BridgeyIcons.Bolt,
                    tint = Tint.BLUE,
                    highlighted = true,
                    onClick = { actions.event(SetupEvent.ChooseQuick) },
                    modifier = Modifier.padding(top = 24.dp),
                )
            }
            item(key = "advanced") {
                ChoiceCard(
                    title = stringResource(R.string.setup_advanced_title),
                    badge = null,
                    body = stringResource(R.string.setup_advanced_body),
                    icon = BridgeyIcons.Settings,
                    tint = Tint.PURPLE,
                    highlighted = false,
                    onClick = { actions.event(SetupEvent.ChooseAdvanced) },
                    modifier = Modifier.padding(top = 12.dp),
                )
            }
            if (state.rerun) {
                item(key = "note") { Note(stringResource(R.string.setup_run_again_detail), Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp)) }
            }
        }
    }
}

/** A Welcome choice: the whole card is the button. */
@Composable
private fun ChoiceCard(
    title: String,
    badge: String?,
    body: String,
    icon: ImageVector,
    tint: Tint,
    highlighted: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = BridgeyTheme.colors
    val shape = RoundedCornerShape(24.dp)
    Row(
        modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surface1)
            .then(if (highlighted) Modifier.border(2.dp, colors.primary, shape) else Modifier)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        IconTile(icon, tint, size = 44.dp, corner = 15.dp, iconSize = 24.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (badge != null) StatusPill(badge, null, Tint.BLUE)
            Text(title, style = BridgeyType.rowTitle, color = colors.onSurface)
            Text(body, style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        }
        Icon(BridgeyIcons.ChevronRight, null, tint = colors.onSurfaceVariant, modifier = Modifier.padding(top = 10.dp))
    }
}

/** The frame of every step: page bar on the band, optional chips, the content, then the footer. */
@Composable
private fun SetupFrame(
    title: String,
    position: Pair<Int, Int>?,
    onBack: () -> Unit,
    header: (@Composable () -> Unit)? = null,
    footer: @Composable () -> Unit,
    content: LazyListScope.() -> Unit,
) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    ScreenBackdrop(bandHeight = statusTop + 64.dp) {
        Column(Modifier.fillMaxSize()) {
            OnBand {
                PageBar(title, onBack) {
                    if (position != null) {
                        Text(
                            stringResource(R.string.setup_step_of, position.first, position.second),
                            style = BridgeyType.label,
                            color = BridgeyTheme.colors.onSurfaceVariant,
                            modifier = Modifier.padding(end = 16.dp),
                        )
                    }
                }
            }
            header?.invoke()
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(bottom = 24.dp), content = content)
            Box(
                Modifier.fillMaxWidth().background(BridgeyTheme.colors.background).navigationBarsPadding()
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 12.dp),
            ) { footer() }
        }
    }
}

/** Skip or Back on the left, the main action on the right. */
@Composable
private fun SetupFooter(
    secondary: String?,
    onSecondary: () -> Unit,
    primary: String?,
    onPrimary: () -> Unit,
    middle: String? = null,
    onMiddle: () -> Unit = {},
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (secondary != null) OutlinePillButton(secondary, null, onSecondary)
        Spacer(Modifier.weight(1f))
        if (middle != null) {
            Text(
                middle,
                style = BridgeyType.label,
                color = BridgeyTheme.colors.primary,
                modifier = Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onMiddle)
                    .padding(horizontal = 12.dp, vertical = 14.dp),
            )
        }
        if (primary != null) GradientButton(primary, null, onPrimary, height = 48.dp, textStyle = BridgeyType.label)
    }
}

@Composable
private fun QuickStepPage(step: QuickStep, state: SetupUiState, actions: SetupActions) {
    val done = state.stepDone(step)
    val title = when (step) {
        QuickStep.PAIR -> stringResource(R.string.setup_pair_title)
        QuickStep.NOTIFICATION_ACCESS -> stringResource(R.string.perm_notification_access_name)
        QuickStep.BATTERY -> stringResource(R.string.perm_battery_name)
    }
    val (why, without) = when (step) {
        QuickStep.PAIR -> stringResource(R.string.setup_pair_why) to stringResource(R.string.setup_pair_without)
        QuickStep.NOTIFICATION_ACCESS -> permissionWhy(PermissionKind.NOTIFICATION_ACCESS) to permissionWithout(PermissionKind.NOTIFICATION_ACCESS)
        QuickStep.BATTERY -> permissionWhy(PermissionKind.BATTERY) to permissionWithout(PermissionKind.BATTERY)
    }
    val (icon, tint) = when (step) {
        QuickStep.PAIR -> BridgeyIcons.LaptopMac to Tint.BLUE
        QuickStep.NOTIFICATION_ACCESS -> BridgeyIcons.Notifications to Tint.PURPLE
        QuickStep.BATTERY -> BridgeyIcons.Bolt to Tint.GREEN
    }
    val allow: (() -> Unit)? = when (step) {
        QuickStep.PAIR -> null
        QuickStep.NOTIFICATION_ACCESS -> actions.allowNotificationAccess
        QuickStep.BATTERY -> actions.allowBattery
    }
    SetupFrame(
        title = stringResource(R.string.setup_title),
        position = state.flow.position,
        onBack = { actions.event(SetupEvent.Back) },
        footer = {
            SetupFooter(
                secondary = if (done) null else stringResource(if (step == QuickStep.PAIR) R.string.setup_pair_later else R.string.setup_skip),
                onSecondary = { actions.event(SetupEvent.Skip) },
                primary = when {
                    done -> stringResource(R.string.setup_next)
                    allow != null -> stringResource(R.string.setup_allow)
                    else -> null
                },
                onPrimary = { if (done || allow == null) actions.event(SetupEvent.Next) else allow() },
            )
        },
    ) {
        item(key = "step") { StepCard(title, why, without, icon, tint, done, Modifier.padding(top = 20.dp)) }
        when (step) {
            QuickStep.PAIR -> pairRows(state, actions)
            QuickStep.BATTERY -> state.oem?.let { checklist ->
                item(key = "oem") { OemChecklistCard(checklist, actions.openOemStep, actions.settings.openUrl, Modifier.padding(top = 16.dp)) }
            }
            QuickStep.NOTIFICATION_ACCESS -> Unit
        }
    }
}

/** The step's title, the one-line why and without-it, and the Done check once granted. */
@Composable
private fun StepCard(title: String, why: String, without: String, icon: ImageVector, tint: Tint, done: Boolean, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Column(
        modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(colors.surface1).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            IconTile(icon, if (done) Tint.GREEN else tint, size = 52.dp, corner = 18.dp, iconSize = 28.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = BridgeyType.cardTitle, color = colors.onSurface, modifier = Modifier.semantics { heading() })
                if (done) StatusPill(stringResource(R.string.setup_done_check), BridgeyIcons.Check, Tint.GREEN)
            }
        }
        Text(stringResource(R.string.setup_why, why), style = BridgeyType.bodyText, color = colors.onSurface, modifier = Modifier.padding(top = 4.dp))
        Text(stringResource(R.string.setup_without, without), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
    }
}

/** The Pair step: paired Macs, or the Macs found on this network to pair with. */
private fun LazyListScope.pairRows(state: SetupUiState, actions: SetupActions) {
    item(key = "pair.label") { SectionLabel(stringResource(R.string.setup_pair_nearby), Modifier.padding(top = 24.dp, bottom = 8.dp)) }
    item(key = "pair.list") {
        val colors = BridgeyTheme.colors
        if (state.nearby.isEmpty()) {
            Note(stringResource(R.string.setup_pair_searching), Modifier.padding(horizontal = 32.dp))
        } else {
            RowGroup {
                state.nearby.forEach { mac ->
                    row { shape ->
                        ListRow(
                            shape, mac.name,
                            stringResource(if (mac.paired) R.string.pair_paired_suffix else R.string.pair_new_suffix),
                            null, Tint.NEUTRAL,
                            onClick = if (mac.paired) null else ({ actions.pair(mac) }),
                            leading = { DeviceGlyph(if (mac.paired) RingStyle.SAME_WIFI else RingStyle.NEARBY, BridgeyIcons.LaptopMac, 40.dp, iconSize = 18.dp) },
                        ) {
                            if (mac.paired) {
                                Icon(BridgeyIcons.Check, null, tint = colors.onTintGreen)
                            } else {
                                TonalPillButton(stringResource(R.string.setup_pair_action), { actions.pair(mac) })
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DonePage(path: SetupPath, state: SetupUiState, actions: SetupActions) {
    val colors = BridgeyTheme.colors
    val skipped = state.flow.skipped.filter { !state.stepDone(it) }
    SetupFrame(
        title = stringResource(R.string.setup_title),
        position = null,
        onBack = { actions.event(SetupEvent.Back) },
        footer = {
            SetupFooter(
                secondary = stringResource(R.string.setup_open_settings),
                onSecondary = actions.openSettings,
                primary = stringResource(R.string.setup_start),
                onPrimary = actions.start,
            )
        },
    ) {
        item(key = "done") {
            Column(
                Modifier.fillMaxWidth().padding(start = 28.dp, end = 28.dp, top = 48.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                IconTile(BridgeyIcons.CheckCircle, Tint.GREEN, size = 72.dp, corner = 24.dp, iconSize = 40.dp)
                Text(
                    stringResource(R.string.setup_done_title),
                    style = BridgeyType.deviceName,
                    color = colors.onSurface,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics { heading() },
                )
                Text(stringResource(R.string.setup_done_body), style = BridgeyType.bodyText, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
        if (path == SetupPath.QUICK && skipped.isNotEmpty()) {
            item(key = "skipped") {
                val names = skipped.map { quickStepName(it) }.joinToString(", ")
                Note(stringResource(R.string.setup_done_skipped, names), Modifier.padding(start = 32.dp, end = 32.dp, top = 20.dp), center = true)
            }
        }
    }
}

@Composable
private fun quickStepName(step: QuickStep): String = when (step) {
    QuickStep.PAIR -> stringResource(R.string.setup_pair_title)
    QuickStep.NOTIFICATION_ACCESS -> stringResource(R.string.perm_notification_access_name)
    QuickStep.BATTERY -> stringResource(R.string.perm_battery_name)
}

@Composable
fun setupGroupTitle(group: SetupGroup): String = stringResource(
    when (group) {
        SetupGroup.DEVICES -> R.string.setup_group_devices
        SetupGroup.CLIPBOARD -> R.string.setup_group_clipboard
        SetupGroup.NOTIFICATIONS -> R.string.setup_group_notifications
        SetupGroup.CALLS -> R.string.setup_group_calls
        SetupGroup.FILES -> R.string.setup_group_files
        SetupGroup.MEDIA -> R.string.setup_group_media
        SetupGroup.REMOTE_CONTROL -> R.string.setup_group_remote
        SetupGroup.PRIVACY -> R.string.setup_group_privacy
        SetupGroup.UPDATES -> R.string.setup_group_updates
        SetupGroup.GENERAL -> R.string.setup_group_general
    },
)

@Composable
private fun setupGroupIntro(group: SetupGroup): String = stringResource(
    when (group) {
        SetupGroup.DEVICES -> R.string.setup_group_devices_intro
        SetupGroup.CLIPBOARD -> R.string.setup_group_clipboard_intro
        SetupGroup.NOTIFICATIONS -> R.string.setup_group_notifications_intro
        SetupGroup.CALLS -> R.string.setup_group_calls_intro
        SetupGroup.FILES -> R.string.setup_group_files_intro
        SetupGroup.MEDIA -> R.string.setup_group_media_intro
        SetupGroup.REMOTE_CONTROL -> R.string.setup_group_remote_intro
        SetupGroup.PRIVACY -> R.string.setup_group_privacy_intro
        SetupGroup.UPDATES -> R.string.setup_group_updates_intro
        SetupGroup.GENERAL -> R.string.setup_group_general_intro
    },
)

/** The Settings page a group's "Open … settings" link opens, if any. */
private fun SetupGroup.section(): SettingsSection? = when (this) {
    SetupGroup.DEVICES -> null
    SetupGroup.CLIPBOARD -> SettingsSection.CLIPBOARD
    SetupGroup.NOTIFICATIONS -> SettingsSection.NOTIFICATIONS
    SetupGroup.CALLS -> null
    SetupGroup.FILES -> SettingsSection.FILES
    SetupGroup.MEDIA -> null
    SetupGroup.REMOTE_CONTROL -> null
    SetupGroup.PRIVACY -> null
    SetupGroup.UPDATES -> SettingsSection.UPDATES
    SetupGroup.GENERAL -> null
}

@Composable
private fun AdvancedPage(group: SetupGroup, state: SetupUiState, actions: SetupActions) {
    val last = group == SetupGroup.entries.last()
    SetupFrame(
        title = setupGroupTitle(group),
        position = state.flow.position,
        onBack = { actions.event(SetupEvent.Back) },
        header = { GroupChips(group, state.flow.visited) { actions.event(SetupEvent.Jump(it)) } },
        footer = {
            SetupFooter(
                secondary = stringResource(R.string.action_back),
                onSecondary = { actions.event(SetupEvent.Back) },
                middle = if (last) null else stringResource(R.string.setup_finish_now),
                onMiddle = { actions.event(SetupEvent.Finish) },
                primary = stringResource(if (last) R.string.setup_finish_now else R.string.setup_next),
                onPrimary = { actions.event(if (last) SetupEvent.Finish else SetupEvent.Next) },
            )
        },
    ) {
        item(key = "$group.intro") { Note(setupGroupIntro(group), Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp, bottom = 12.dp)) }
        groupContent(group, state, actions)
        group.section()?.let { section ->
            item(key = "$group.open") {
                RowGroup(Modifier.padding(top = 16.dp)) {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.setup_open_section, stringResource(section.titleRes)), null,
                            BridgeyIcons.Settings, Tint.NEUTRAL, compact = true, onClick = { actions.openSection(section) },
                        ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
                    }
                }
            }
        }
    }
}

/** "3 of 10" plus a chip per group, to jump to any of them. */
@Composable
private fun GroupChips(current: SetupGroup, visited: Set<SetupGroup>, onJump: (SetupGroup) -> Unit) {
    val colors = BridgeyTheme.colors
    val listState = rememberLazyListState()
    LaunchedEffect(current) { listState.scrollToItem((current.ordinal - 1).coerceAtLeast(0)) }
    LazyRow(
        Modifier.fillMaxWidth().padding(top = 12.dp).semantics { heading() },
        state = listState,
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(SetupGroup.entries, key = { it.name }) { group ->
            val selected = group == current
            val seen = group in visited
            Row(
                Modifier
                    .heightIn(min = 48.dp)
                    .padding(vertical = 6.dp)
                    .clip(RoundedCornerShape(18.dp))
                    .background(if (selected) colors.primary else colors.surface2)
                    .selectable(selected = selected, role = Role.Tab) { onJump(group) }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (seen && !selected) Icon(BridgeyIcons.Check, null, tint = colors.onTintGreen, modifier = Modifier.size(16.dp))
                Text(
                    "${group.ordinal + 1}. ${setupGroupTitle(group)}",
                    style = BridgeyType.chip,
                    color = if (selected) colors.onPrimary else colors.onSurface,
                    maxLines = 1,
                )
            }
        }
    }
}

/** A group's choices: the real settings, each with its current value and a one-line explanation. */
private fun LazyListScope.groupContent(group: SetupGroup, state: SetupUiState, actions: SetupActions) {
    val settings = state.settings
    val choose: (String, String) -> Unit = { key, value -> actions.event(SetupEvent.Choose(SetupChoice(group, key, value))) }
    fun feature(feature: BridgeyFeature, on: Boolean) {
        actions.settings.setGlobal(feature, on)
        choose("global.${feature.key}", on.toString())
    }
    when (group) {
        SetupGroup.DEVICES -> {
            item(key = "devices") {
                RowGroup {
                    if (state.pairedNames.isEmpty()) {
                        row { shape -> ListRow(shape, stringResource(R.string.setup_paired_none), stringResource(R.string.setup_pair_without), BridgeyIcons.LaptopMac, Tint.NEUTRAL) }
                    }
                    state.pairedNames.forEach { name ->
                        row { shape -> ListRow(shape, name, stringResource(R.string.setup_paired), BridgeyIcons.LaptopMac, Tint.BLUE) }
                    }
                }
            }
            item(key = "devices.add") {
                RowGroup(Modifier.padding(top = 16.dp)) {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.devices_pair_new), stringResource(R.string.devices_pair_new_detail),
                            BridgeyIcons.Add, Tint.BLUE, onClick = actions.addDevice,
                        ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
                    }
                    row { shape ->
                        ListRow(shape, stringResource(R.string.look_again), stringResource(R.string.look_again_detail), BridgeyIcons.Refresh, Tint.NEUTRAL, onClick = actions.lookForDevices)
                    }
                }
            }
        }
        SetupGroup.CLIPBOARD -> item(key = "clipboard") {
            RowGroup {
                row { shape -> FeatureRow(shape, BridgeyFeature.CLIPBOARD, R.string.feature_clipboard_detail, settings) { feature(BridgeyFeature.CLIPBOARD, it) } }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.auto_clipboard_title), stringResource(R.string.auto_clipboard_detail),
                        BridgeyIcons.Sync, if (settings.autoClipboardEnabled) Tint.BLUE else Tint.NEUTRAL, settings.autoClipboardEnabled,
                        { actions.settings.setAutoClipboard(it); choose("clipboard.auto", it.toString()) },
                    )
                }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.clipboard_files_title), stringResource(R.string.clipboard_files_detail),
                        BridgeyIcons.Image, if (settings.clipboardFilesEnabled) Tint.BLUE else Tint.NEUTRAL, settings.clipboardFilesEnabled,
                        { actions.settings.setClipboardFiles(it); choose("clipboard.files", it.toString()) },
                    )
                }
                row { shape ->
                    val on = settings.screenshotSendEnabled && settings.clipboardFilesEnabled
                    SwitchRow(
                        shape, stringResource(R.string.screenshot_send_title), stringResource(R.string.screenshot_send_detail),
                        BridgeyIcons.Smartphone, if (on) Tint.BLUE else Tint.NEUTRAL, on,
                        { actions.settings.setScreenshotSend(it); choose("clipboard.screenshot", it.toString()) },
                        enabled = settings.clipboardFilesEnabled,
                    )
                }
            }
        }
        SetupGroup.NOTIFICATIONS -> {
            item(key = "notifications") {
                val on = settings.featureOn(BridgeyFeature.NOTIFICATIONS)
                RowGroup {
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.settings_forwarding_title), stringResource(R.string.settings_notifications_detail),
                            BridgeyIcons.Notifications, if (on) Tint.PURPLE else Tint.NEUTRAL, on, { feature(BridgeyFeature.NOTIFICATIONS, it) },
                        )
                    }
                    if (on) {
                        row { shape ->
                            ListRow(
                                shape, stringResource(R.string.settings_forwarding),
                                stringResource(if (settings.notificationAccessEnabled) R.string.settings_forwarding_on else R.string.settings_forwarding_off),
                                BridgeyIcons.Notifications, if (settings.notificationAccessEnabled) Tint.GREEN else Tint.NEUTRAL,
                                detailWarning = !settings.notificationAccessEnabled, onClick = actions.settings.notificationAccess,
                            ) { ManageText(settings.notificationAccessEnabled) }
                        }
                        row { shape ->
                            val ok = settings.codes.access == dev.bridgey.android.codes.CodeAccessStatus.ALLOWED
                            ListRow(
                                shape, stringResource(R.string.codes_title), codeAccessText(settings.codes.access),
                                BridgeyIcons.Notifications, if (ok) Tint.GREEN else Tint.NEUTRAL, detailWarning = !ok,
                            )
                        }
                    }
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_app_notifications),
                            stringResource(if (settings.appNotificationsEnabled) R.string.settings_app_notifications_on else R.string.settings_app_notifications_off),
                            BridgeyIcons.Notifications, if (settings.appNotificationsEnabled) Tint.GREEN else Tint.NEUTRAL,
                            onClick = actions.settings.appNotifications,
                        ) { ManageText(settings.appNotificationsEnabled) }
                    }
                }
            }
            // v0.9: Focus sync, as on the Settings page (Notifications > Focus), each direction its own switch.
            item(key = "notifications.focus.label") { SectionLabel(stringResource(R.string.focus_section), Modifier.padding(top = 20.dp)) }
            item(key = "notifications.focus") {
                RowGroup {
                    focusRows(
                        settings.focus,
                        FocusSettingsActions(
                            setShare = { actions.settings.focus.setShare(it); choose("focus.share", it.toString()) },
                            setFollow = { actions.settings.focus.setFollow(it); choose("focus.follow", it.toString()) },
                            openAccess = actions.settings.focus.openAccess,
                        ),
                    )
                }
            }
        }
        SetupGroup.CALLS -> item(key = "calls") {
            val on = settings.featureOn(BridgeyFeature.CALLS)
            RowGroup {
                row { shape -> FeatureRow(shape, BridgeyFeature.CALLS, R.string.settings_calls_detail, settings) { feature(BridgeyFeature.CALLS, it) } }
                if (on) {
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.devices_direct_calls), stringResource(R.string.devices_direct_calls_detail),
                            BridgeyIcons.Call, if (settings.directCallsEnabled) Tint.GREEN else Tint.NEUTRAL, settings.directCallsEnabled,
                            { actions.settings.setDirectCalls(it); choose("calls.direct", it.toString()) },
                        )
                    }
                }
            }
        }
        SetupGroup.FILES -> item(key = "files") {
            val on = settings.featureOn(BridgeyFeature.FILES)
            RowGroup {
                row { shape -> FeatureRow(shape, BridgeyFeature.FILES, R.string.feature_files_detail, settings) { feature(BridgeyFeature.FILES, it) } }
                if (on && settings.folders.supported) folderRows(settings.folders, actions.settings.folders)
            }
        }
        SetupGroup.MEDIA -> item(key = "media") {
            RowGroup {
                // The Settings page's order (MediaSectionFeatures): Mac actions and the camera follow media controls.
                listOf(
                    BridgeyFeature.MEDIA to R.string.settings_media_detail,
                    BridgeyFeature.MAC_ACTIONS to R.string.settings_mac_actions_detail,
                    BridgeyFeature.CAMERA to R.string.settings_camera_detail,
                    BridgeyFeature.LINKS to R.string.feature_links_detail,
                    BridgeyFeature.PING to R.string.settings_ping_detail,
                    BridgeyFeature.FIND_DEVICE to R.string.settings_find_detail,
                    BridgeyFeature.BATTERY to R.string.settings_battery_detail,
                ).forEach { (item, detail) ->
                    row { shape -> FeatureRow(shape, item, detail, settings) { feature(item, it) } }
                }
            }
        }
        SetupGroup.REMOTE_CONTROL -> item(key = "remote") {
            val on = settings.featureOn(BridgeyFeature.REMOTE_INPUT)
            RowGroup {
                row { shape -> FeatureRow(shape, BridgeyFeature.REMOTE_INPUT, R.string.settings_remote_detail, settings) { feature(BridgeyFeature.REMOTE_INPUT, it) } }
                if (on) {
                    row { shape ->
                        ListRow(shape, stringResource(R.string.remote_speed_title), pointerSpeedName(settings.remotePointerSpeed), BridgeyIcons.Mouse, Tint.PURPLE)
                    }
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.remote_volume_keys_title), stringResource(R.string.remote_volume_keys_detail),
                            BridgeyIcons.VolumeUp, if (settings.remoteVolumeKeys) Tint.PURPLE else Tint.NEUTRAL, settings.remoteVolumeKeys,
                            { actions.settings.setRemoteVolumeKeys(it); choose("remote.volume_keys", it.toString()) },
                        )
                    }
                }
            }
        }
        SetupGroup.PRIVACY -> {
            item(key = "privacy") {
                RowGroup {
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.settings_show_previews), stringResource(R.string.settings_show_previews_detail),
                            BridgeyIcons.ContentPaste, if (settings.showPreviews) Tint.BLUE else Tint.NEUTRAL, settings.showPreviews,
                            { actions.settings.setShowPreviews(it); choose("privacy.previews", it.toString()) },
                        )
                    }
                }
            }
            item(key = "privacy.logging") {
                LoggingSettingsGroup(
                    settings.logging,
                    { actions.settings.setLogging(it); choose("privacy.logging", it.toString()) },
                    actions.settings.exportDiagnostics,
                    actions.settings.clearLogs,
                )
            }
        }
        SetupGroup.UPDATES -> item(key = "updates") {
            RowGroup {
                UpdateChannel.entries.forEach { channel ->
                    row { shape ->
                        val selected = settings.update.channel == channel
                        ListRow(
                            shape, channelTitle(channel), stringResource(channelDetailRes(channel)), BridgeyIcons.SystemUpdate,
                            if (selected) Tint.PURPLE else Tint.NEUTRAL, role = Role.RadioButton,
                            onClick = { actions.settings.setChannel(channel); choose("updates.channel", channel.key) },
                        ) { if (selected) Icon(BridgeyIcons.Check, null, tint = BridgeyTheme.colors.primary) }
                    }
                }
            }
        }
        SetupGroup.GENERAL -> {
            item(key = "general") {
                RowGroup {
                    row { shape ->
                        ListRow(
                            shape, stringResource(R.string.settings_background_title),
                            stringResource(if (settings.batteryExempt) R.string.settings_background_on else R.string.settings_background_off),
                            BridgeyIcons.Bolt, if (settings.batteryExempt) Tint.GREEN else Tint.NEUTRAL,
                            detailWarning = !settings.batteryExempt,
                        ) {
                            if (settings.batteryExempt) {
                                Icon(BridgeyIcons.Check, null, tint = BridgeyTheme.colors.onTintGreen)
                            } else {
                                OutlinePillButton(stringResource(R.string.action_allow), null, actions.allowBattery)
                            }
                        }
                    }
                    if (settings.keepWifiAwakeSupported) {
                        row { shape ->
                            SwitchRow(
                                shape, stringResource(R.string.settings_wifi_awake_title), stringResource(R.string.settings_wifi_awake_detail),
                                BridgeyIcons.Wifi, if (settings.keepWifiAwake) Tint.BLUE else Tint.NEUTRAL, settings.keepWifiAwake,
                                { actions.settings.setKeepWifiAwake(it); choose("general.wifi_awake", it.toString()) },
                            )
                        }
                    }
                    row { shape ->
                        SwitchRow(
                            shape, stringResource(R.string.settings_reduce_motion), stringResource(R.string.settings_reduce_motion_detail),
                            BridgeyIcons.Animation, Tint.NEUTRAL, settings.reduceMotion,
                            { actions.settings.setReduceMotion(it); choose("general.reduce_motion", it.toString()) },
                        )
                    }
                }
            }
            state.oem?.let { checklist ->
                item(key = "general.oem") { OemChecklistCard(checklist, actions.openOemStep, actions.settings.openUrl, Modifier.padding(top = 16.dp)) }
            }
        }
    }
}

/** A feature's on/off switch with its title, icon and one-line detail. */
@Composable
private fun FeatureRow(shape: androidx.compose.ui.graphics.Shape, feature: BridgeyFeature, detail: Int, settings: SettingsState, onChange: (Boolean) -> Unit) {
    val (icon, tint) = permissionVisual(feature)
    val on = settings.featureOn(feature)
    val title = when (feature) {
        BridgeyFeature.FIND_DEVICE -> stringResource(R.string.feature_find)
        BridgeyFeature.PING -> stringResource(R.string.feature_ping)
        else -> permissionTitle(feature)
    }
    SwitchRow(shape, title, stringResource(detail), icon, if (on) tint else Tint.NEUTRAL, on, onChange)
}

@Composable
private fun ManageText(enabled: Boolean) {
    Text(stringResource(if (enabled) R.string.action_manage else R.string.action_enable), style = BridgeyType.label, color = BridgeyTheme.colors.primary)
}

@Composable
private fun pointerSpeedName(level: Int): String = stringResource(
    when (level) {
        1 -> R.string.remote_speed_1
        2 -> R.string.remote_speed_2
        4 -> R.string.remote_speed_4
        5 -> R.string.remote_speed_5
        else -> R.string.remote_speed_3
    },
)

private fun channelDetailRes(channel: UpdateChannel): Int = when (channel) {
    UpdateChannel.STABLE -> R.string.channel_stable_detail
    UpdateChannel.BETA -> R.string.channel_beta_detail
    UpdateChannel.NIGHTLY -> R.string.channel_nightly_detail
}
