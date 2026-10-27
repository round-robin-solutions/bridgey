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
import dev.bridgey.android.R
import dev.bridgey.android.setup.OemChecklist
import dev.bridgey.android.setup.OemStep
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.QuickStep
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupEvent
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
    /** What the questions depend on: the settings now, permissions, a paired Mac. */
    val facts: SetupFacts = SetupFacts(),
    /** Screenshots: text already typed on the Intro, and bundles already picked. */
    val typedText: String = "",
    val pickedBundles: Set<String> = emptySet(),
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
    /** More options and Change in Settings: a Settings page (a [SettingsSection] name), above setup; Back returns here. */
    val openPage: (String) -> Unit = {},
    /** Allow on a permissions row: its system dialog or screen; the page refreshes when Bridgey is back. */
    val allowPermission: (PermissionKind) -> Unit = {},
    /** Allow all: the runtime permissions in one dialog, then each special access screen in order. */
    val allowAll: () -> Unit = {},
    val openSettings: () -> Unit = {},
    val start: () -> Unit = {},
    /** Back on Welcome: leave setup (it is offered again next launch until it is finished). */
    val exit: () -> Unit = {},
    /** The close button: leave now, or ask first when something was chosen. */
    val leave: () -> Unit = exit,
)

/** First-run setup: Welcome, the quick steps, the questions and their summary, Done. */
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
        SetupScreen.Intro, is SetupScreen.Question, SetupScreen.Switches, SetupScreen.Permissions, SetupScreen.Summary -> QuestionPath(state, actions)
        is SetupScreen.Done -> DonePage(screen.path, state, actions)
    }
    if (state.flow.confirmLeave) {
        LeaveSetupDialog(onLeave = actions.exit, onStay = { actions.event(SetupEvent.KeepGoing) })
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
        if (path == SetupPath.QUICK) {
            item(key = "essentials") {
                Note(stringResource(R.string.setup_done_essentials), Modifier.padding(start = 32.dp, end = 32.dp, top = 20.dp), center = true)
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
