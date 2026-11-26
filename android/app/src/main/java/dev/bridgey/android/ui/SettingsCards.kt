package dev.bridgey.android.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.MotionMode
import dev.bridgey.android.ui.search.LocalSearchRoute
import dev.bridgey.android.ui.search.LocalSearchScope
import dev.bridgey.android.ui.search.LocalSettingsSearch
import dev.bridgey.android.ui.search.settingsSearchHighlight
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import kotlinx.coroutines.launch

/*
 * Settings in six groups (direction A, 26 Nov 2026): the Settings home lists the groups, each group is one page of
 * cards, and each feature is one card: its switch in the header, the rows people use most, a Devices row of chips for
 * the per-device choice, and More options for the rest. The Mac sidebar has the same six groups.
 */

/** The Settings home's rows, top to bottom. The Mac's sidebar has the same groups ("Phone" there). */
enum class SettingsGroup(@StringRes val titleRes: Int, val icon: () -> ImageVector, val tint: Tint) {
    DEVICES(R.string.settings_group_devices, { BridgeyIcons.Devices }, Tint.BLUE),
    SHARING(R.string.settings_group_sharing, { BridgeyIcons.IosShare }, Tint.BLUE),
    PHONE(R.string.settings_group_phone, { BridgeyIcons.Notifications }, Tint.PURPLE),
    CONTROL(R.string.settings_group_control, { BridgeyIcons.AdsClick }, Tint.GREEN),
    PRIVACY(R.string.settings_group_privacy, { BridgeyIcons.Shield }, Tint.NEUTRAL),
    APP(R.string.settings_group_app, { BridgeyIcons.Settings }, Tint.NEUTRAL),
}

/** Every card on the group pages, in page order. [key] is stable: search opens a card's More options by it. */
enum class SettingsCard(val group: SettingsGroup) {
    THIS_PHONE(SettingsGroup.DEVICES),
    PAIRED(SettingsGroup.DEVICES),
    AWAY(SettingsGroup.DEVICES),
    FIND_PING(SettingsGroup.DEVICES),
    BATTERY(SettingsGroup.DEVICES),
    CLIPBOARD(SettingsGroup.SHARING),
    FILES(SettingsGroup.SHARING),
    MEDIA(SettingsGroup.SHARING),
    LINKS(SettingsGroup.SHARING),
    CAMERA(SettingsGroup.SHARING),
    NOTIFICATIONS(SettingsGroup.PHONE),
    CODES(SettingsGroup.PHONE),
    FOCUS(SettingsGroup.PHONE),
    MESSAGES(SettingsGroup.PHONE),
    CALLS(SettingsGroup.PHONE),
    CALLS_WINDOW(SettingsGroup.PHONE),
    CALL_QUIET(SettingsGroup.PHONE),
    REMOTE(SettingsGroup.CONTROL),
    SEE_MAC_SCREEN(SettingsGroup.CONTROL),
    SHARE_SCREEN(SettingsGroup.CONTROL),
    PHONE_CONTROL(SettingsGroup.CONTROL),
    MAC_ACTIONS(SettingsGroup.CONTROL),
    ACTIVITY(SettingsGroup.PRIVACY),
    PERMISSIONS(SettingsGroup.PRIVACY),
    LOGGING(SettingsGroup.PRIVACY),
    UPDATES(SettingsGroup.APP),
    GENERAL(SettingsGroup.APP),
    SYNC(SettingsGroup.APP),
    ABOUT(SettingsGroup.APP),
    DEVELOPER(SettingsGroup.APP),
    ;

    val key: String get() = name.lowercase()
}

/** The card's name in breadcrumbs (its header, or its first row); null for a card that has neither. */
@get:StringRes
val SettingsCard.titleRes: Int?
    get() = when (this) {
        SettingsCard.THIS_PHONE -> R.string.settings_this_phone
        SettingsCard.PAIRED -> R.string.devices_paired
        SettingsCard.AWAY -> R.string.settings_connect_away
        SettingsCard.FIND_PING -> R.string.feature_find
        SettingsCard.BATTERY -> R.string.feature_battery
        SettingsCard.CLIPBOARD -> R.string.feature_clipboard
        SettingsCard.FILES -> R.string.feature_files
        SettingsCard.MEDIA -> R.string.feature_media
        SettingsCard.LINKS -> R.string.feature_links
        SettingsCard.CAMERA -> R.string.feature_camera
        SettingsCard.NOTIFICATIONS -> R.string.settings_forwarding_title
        SettingsCard.CODES -> R.string.codes_title
        SettingsCard.FOCUS -> R.string.focus_section
        SettingsCard.MESSAGES -> R.string.feature_sms
        SettingsCard.CALLS -> R.string.feature_calls
        SettingsCard.CALLS_WINDOW -> R.string.dialer_title
        SettingsCard.CALL_QUIET -> R.string.call_quiet_title
        SettingsCard.REMOTE -> R.string.feature_remote_input
        SettingsCard.SEE_MAC_SCREEN -> R.string.feature_screen_control
        SettingsCard.SHARE_SCREEN -> R.string.feature_screen
        SettingsCard.PHONE_CONTROL -> R.string.control_settings_title
        SettingsCard.MAC_ACTIONS -> R.string.feature_mac_actions
        SettingsCard.ACTIVITY, SettingsCard.PERMISSIONS -> null
        SettingsCard.LOGGING -> R.string.settings_logging
        SettingsCard.UPDATES -> R.string.settings_updates
        SettingsCard.GENERAL -> R.string.settings_general
        SettingsCard.SYNC -> R.string.settings_sync_title
        SettingsCard.ABOUT -> R.string.settings_about
        SettingsCard.DEVELOPER -> R.string.settings_developer
    }

fun cardTitle(context: android.content.Context, card: SettingsCard): String? = card.titleRes?.let(context::getString)

/**
 * The card that holds each per-device choice, and the title its chip answers to in search (the title the per-device
 * row had, so the registry's "device.<id>.<n>" entries keep pointing at it). [more] is true for a chip row inside
 * More options. Order and titles match SettingsSearchRegistry.devicePermissionRows.
 */
data class DeviceChoice(@StringRes val titleRes: Int, val features: List<BridgeyFeature>, val card: SettingsCard, val more: Boolean = false)

val DeviceChoices: List<DeviceChoice> = listOf(
    DeviceChoice(R.string.feature_clipboard, listOf(BridgeyFeature.CLIPBOARD), SettingsCard.CLIPBOARD),
    DeviceChoice(R.string.auto_clipboard_title, listOf(BridgeyFeature.CLIPBOARD), SettingsCard.CLIPBOARD, more = true),
    DeviceChoice(R.string.feature_files, listOf(BridgeyFeature.FILES), SettingsCard.FILES),
    DeviceChoice(R.string.feature_notifications, listOf(BridgeyFeature.NOTIFICATIONS), SettingsCard.NOTIFICATIONS),
    DeviceChoice(R.string.feature_sms, listOf(BridgeyFeature.SMS), SettingsCard.MESSAGES),
    DeviceChoice(R.string.feature_calls, listOf(BridgeyFeature.CALLS), SettingsCard.CALLS),
    DeviceChoice(R.string.feature_media, listOf(BridgeyFeature.MEDIA), SettingsCard.MEDIA),
    DeviceChoice(R.string.feature_remote_input, listOf(BridgeyFeature.REMOTE_INPUT), SettingsCard.REMOTE),
    DeviceChoice(R.string.feature_screen_control, listOf(BridgeyFeature.SCREEN_CONTROL), SettingsCard.SEE_MAC_SCREEN),
    DeviceChoice(R.string.feature_mac_actions, listOf(BridgeyFeature.MAC_ACTIONS), SettingsCard.MAC_ACTIONS),
    DeviceChoice(R.string.feature_camera, listOf(BridgeyFeature.CAMERA), SettingsCard.CAMERA),
    DeviceChoice(R.string.call_quiet_title, listOf(BridgeyFeature.CALL_QUIET), SettingsCard.CALL_QUIET),
    DeviceChoice(R.string.dialer_title, listOf(BridgeyFeature.DIALER), SettingsCard.CALLS_WINDOW),
    DeviceChoice(R.string.feature_screen, listOf(BridgeyFeature.SCREEN), SettingsCard.SHARE_SCREEN),
    DeviceChoice(R.string.feature_find_ping, listOf(BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING), SettingsCard.FIND_PING),
    DeviceChoice(R.string.feature_links, listOf(BridgeyFeature.LINKS), SettingsCard.LINKS),
    DeviceChoice(R.string.feature_battery, listOf(BridgeyFeature.BATTERY), SettingsCard.BATTERY),
    DeviceChoice(R.string.devices_sync_title, emptyList(), SettingsCard.SYNC),
)

/**
 * A paired device (not an agent) as the cards' Devices rows see it: what each feature is set to for it (the same value
 * the device page's switches showed: BridgeySettings.isEnabled), what it turned off on its side, its Automatic
 * clipboard and its settings sync.
 */
data class SettingsDevice(
    val id: String,
    val name: String,
    val on: Map<BridgeyFeature, Boolean> = emptyMap(),
    /** Features it has off on its side (only known while connected). */
    val remoteOff: Set<BridgeyFeature> = emptySet(),
    val autoClipboard: Boolean = true,
    val sync: Boolean = true,
    val syncOffRemote: Boolean = false,
)

/** A paired device for the chips, read from the stored settings exactly as the device page read its switches. */
fun settingsDevice(
    settings: dev.bridgey.android.BridgeySettings,
    id: String,
    name: String,
    /** Its own feature state while connected; null while not. */
    remoteFeatures: Map<BridgeyFeature, Boolean>?,
    sync: Boolean,
    syncOffRemote: Boolean,
): SettingsDevice = SettingsDevice(
    id = id,
    name = name,
    on = BridgeyFeature.entries.associateWith { settings.isEnabled(it, id) },
    remoteOff = remoteFeatures?.filterValues { !it }?.keys.orEmpty(),
    autoClipboard = settings.isAutoClipboardEnabled(id),
    sync = sync,
    syncOffRemote = syncOffRemote,
)

/** What a feature chip writes: the device page's switch's write, for each feature behind it. */
fun setDeviceChoice(settings: dev.bridgey.android.BridgeySettings, deviceId: String, features: List<BridgeyFeature>, enabled: Boolean) {
    features.forEach { settings.setForDevice(deviceId, it, enabled) }
}

/** One chip in a Devices row. */
data class DeviceChip(val id: String, val name: String, val checked: Boolean, val enabled: Boolean, val onChange: (Boolean) -> Unit)

/** The chips for a per-device feature choice, exactly as the device page's switch read and wrote it. */
fun featureChips(state: SettingsState, features: List<BridgeyFeature>, set: (String, List<BridgeyFeature>, Boolean) -> Unit): List<DeviceChip> {
    val globallyOff = features.all { state.globalFeatures[it] == false }
    return state.devices.map { device ->
        val remotelyOff = features.all { it in device.remoteOff }
        DeviceChip(
            device.id, device.name,
            checked = features.any { device.on[it] == true } && !globallyOff && !remotelyOff,
            enabled = !globallyOff && !remotelyOff,
        ) { set(device.id, features, it) }
    }
}

/**
 * Automatic clipboard for each device, as the device page's switch under Clipboard read and wrote it: usable only while
 * Clipboard is on for the device and Automatic clipboard is on.
 */
fun autoClipboardChips(state: SettingsState, set: (String, Boolean) -> Unit): List<DeviceChip> = state.devices.map { device ->
    val usable = state.autoClipboardEnabled && state.featureOn(BridgeyFeature.CLIPBOARD) &&
        device.on[BridgeyFeature.CLIPBOARD] == true && BridgeyFeature.CLIPBOARD !in device.remoteOff
    DeviceChip(device.id, device.name, checked = usable && device.autoClipboard, enabled = usable) { set(device.id, it) }
}

/** Sync settings with each device, as the device page's switch read and wrote it: only while sync is on. */
fun syncChips(state: SettingsState, set: (String, Boolean) -> Unit): List<DeviceChip> = state.devices.map { device ->
    val enabled = state.sync.switches.enabled
    DeviceChip(device.id, device.name, checked = device.sync && enabled, enabled = enabled) { set(device.id, it) }
}

/** "Off on Work MacBook": the devices that turned [features] off on their side. */
fun remotelyOffNames(state: SettingsState, features: List<BridgeyFeature>): List<String> =
    state.devices.filter { device -> features.isNotEmpty() && features.all { it in device.remoteOff } }.map { it.name }

/** Tests and screenshots: every card drawn with More options open (true) or closed (false); null in the app. */
val LocalCardsExpanded = staticCompositionLocalOf<Boolean?> { null }

/** The card (its key) a page was opened at, drawn with its More options open. */
val LocalOpenCard = staticCompositionLocalOf<String?> { null }

/** A card's header: icon, feature name, and the feature's switch when it has one. */
data class CardHeader(
    val title: String,
    val icon: ImageVector,
    val tint: Tint,
    val detail: String? = null,
    val switch: CardSwitch? = null,
)

data class CardSwitch(val checked: Boolean, val onChange: (Boolean) -> Unit, val enabled: Boolean = true, val synced: Boolean = false)

/**
 * One card: [header] (no header when null), then [rows] (the two or three people use most), then [more] behind a More
 * options row. Rows are the same segmented rows as everywhere else. More options opens when tapped, and when a search
 * result points inside it; its rows fade and rise in (opacity and transform only) below the More options row, which stays
 * where it is. [footer] holds the card's notes.
 */
@Composable
fun FeatureCard(
    card: SettingsCard,
    header: CardHeader?,
    modifier: Modifier = Modifier,
    rows: GroupScope.() -> Unit = {},
    more: (GroupScope.() -> Unit)? = null,
    footer: (@Composable ColumnScope.() -> Unit)? = null,
) {
    val host = LocalSettingsSearch.current
    val route = LocalSearchRoute.current
    var expanded by rememberSaveable(card.key) { mutableStateOf(false) }
    var tapped by remember { mutableStateOf(false) }
    val searchOpens = host?.pending?.let { it.routeKey == route && it.expand == card.key } == true
    if (searchOpens && !expanded) SideEffect { expanded = true }
    val shown = LocalCardsExpanded.current ?: (expanded || searchOpens || LocalOpenCard.current == card.key)
    val moreRows = more?.let { GroupScope().apply(it).rows }.orEmpty()
    Column(modifier) {
        RowGroup {
            if (header != null) row { shape -> CardHeaderRow(shape, header) }
            rows()
            if (moreRows.isNotEmpty()) {
                row { shape -> MoreOptionsRow(shape, shown) { tapped = true; expanded = !shown } }
                if (shown) moreRows.forEach { content -> row { shape -> Revealed(tapped) { content(shape) } } }
            }
        }
        footer?.invoke(this)
    }
}

@Composable
private fun CardHeaderRow(shape: Shape, header: CardHeader) {
    val switch = header.switch
    val on = switch?.checked ?: true
    ListRow(
        shape = shape,
        title = header.title,
        detail = header.detail,
        icon = header.icon,
        tint = if (on) header.tint else Tint.NEUTRAL,
        synced = switch?.synced == true,
        titleStyle = BridgeyType.rowTitle.copy(fontSize = 17.sp, lineHeight = 22.sp),
        modifier = Modifier.semantics(mergeDescendants = true) { heading() },
        onClick = switch?.takeIf { it.enabled }?.let { { it.onChange(!it.checked) } },
        role = if (switch != null) Role.Switch else null,
        // The header is the feature's switch for search; a header without one is a title only.
        searchable = switch != null,
    ) {
        if (switch != null) BridgeySwitch(checked = switch.checked, onCheckedChange = null, enabled = switch.enabled)
    }
}

/** More options: a chevron that turns, and the rows below it. */
@Composable
private fun MoreOptionsRow(shape: Shape, expanded: Boolean, onToggle: () -> Unit) {
    val colors = BridgeyTheme.colors
    val motion = LocalMotion.current
    val turn by animateFloatAsState(
        if (expanded) 90f else 0f,
        if (motion.moves) motion.spatial(motion.small) else motion.fadeSpec(),
        label = "moreOptions",
    )
    val state = stringResource(if (expanded) R.string.settings_expanded else R.string.settings_collapsed)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(shape)
            .background(colors.surface1)
            .clickable(role = Role.Button, onClick = onToggle)
            .semantics { stateDescription = state }
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(BridgeyIcons.ChevronRight, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(20.dp).graphicsLayer { rotationZ = turn })
        Text(stringResource(R.string.settings_more_options), style = BridgeyType.label, color = colors.onSurfaceVariant)
    }
}

/** A row that has just been shown by More options: fades in and rises 12 dp (fade only with Reduce motion). */
@Composable
private fun Revealed(animate: Boolean, content: @Composable () -> Unit) {
    val motion = LocalMotion.current
    val alpha = remember { Animatable(if (animate && motion.mode != MotionMode.Instant) 0f else 1f) }
    val rise = remember { Animatable(if (animate && motion.moves) 1f else 0f) }
    LaunchedEffect(Unit) {
        launch { alpha.animateTo(1f, motion.fadeSpec()) }
        if (rise.value > 0f) rise.animateTo(0f, motion.spatial(motion.small))
    }
    Box(Modifier.graphicsLayer { this.alpha = alpha.value; translationY = -rise.value * 12.dp.toPx() }) { content() }
}

/**
 * A card's Devices row: one chip per paired device, checked while the choice is on for it. [anchor] is the title each
 * chip answers to in search (inside its device's scope). [offOn] are the devices that turned it off on their side.
 */
fun GroupScope.deviceChips(
    @StringRes anchor: Int,
    chips: List<DeviceChip>,
    offOn: List<String> = emptyList(),
    @StringRes title: Int = R.string.settings_card_devices,
) {
    if (chips.isEmpty()) return
    row { shape ->
        val note = offOn.takeIf { it.isNotEmpty() }?.let { stringResource(R.string.permission_off_remote, it.joinToString(", ")) }
        DeviceChipsRow(shape, stringResource(title), stringResource(anchor), chips, note)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DeviceChipsRow(shape: Shape, title: String, anchor: String, chips: List<DeviceChip>, note: String?) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier.fillMaxWidth().clip(shape).background(colors.surface1).padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 14.dp),
    ) {
        Text(title, style = BridgeyType.rowTitle, color = colors.onSurface)
        if (note != null) Text(note, style = BridgeyType.itemBody, color = colors.onTintPurple, modifier = Modifier.padding(top = 1.dp))
        FlowRow(
            Modifier.padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            chips.forEach { chip ->
                CompositionLocalProvider(LocalSearchScope provides chip.id) { DeviceChipView(chip, anchor) }
            }
        }
    }
}

@Composable
private fun DeviceChipView(chip: DeviceChip, anchor: String) {
    val colors = BridgeyTheme.colors
    val shape = RoundedCornerShape(20.dp)
    val description = stringResource(R.string.settings_chip_description, chip.name, anchor)
    val content = if (!chip.enabled) colors.onSurfaceVariant.copy(alpha = 0.6f) else if (chip.checked) colors.onTintBlue else colors.onSurface
    Row(
        Modifier
            .heightIn(min = 40.dp)
            .clip(shape)
            .background(if (chip.checked) colors.tintBlue else colors.surface1)
            .then(if (chip.checked) Modifier else Modifier.border(1.dp, colors.outline, shape))
            .settingsSearchHighlight(anchor, shape)
            .toggleable(value = chip.checked, enabled = chip.enabled, role = Role.Checkbox, onValueChange = chip.onChange)
            .semantics { contentDescription = description }
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (chip.checked) Icon(BridgeyIcons.Check, null, tint = content, modifier = Modifier.size(16.dp))
        Text(chip.name, style = BridgeyType.label, color = content, maxLines = 1)
    }
}
