package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.R
import dev.bridgey.android.control.PhoneControlGrantMode
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** A paired Mac on the Remote control page: whether it may see and control this phone without asking. */
data class PhoneControlMac(
    val id: String,
    val name: String,
    /** What it may do now: its own choice, else what Unattended access gives. */
    val mode: PhoneControlGrantMode,
    /** Share screen with Macs is on for it: control happens inside a share, so without it nothing can start. */
    val sharing: Boolean,
    /** Its own choice; null is Default (it follows Unattended access). */
    val choice: PhoneControlGrantMode? = mode,
)

/** Settings > Remote control > Let Macs control this phone. */
data class PhoneControlSettingsState(
    /** This build has phone control (not the Play build). */
    val built: Boolean = true,
    /** Bridgey control is on in Android's accessibility settings. */
    val serviceEnabled: Boolean = false,
    /** Typing works here (Android 13 and later). */
    val typing: Boolean = true,
    /** Android may block the service as a restricted setting (Android 13 and later, installed from a file). */
    val restrictedPossible: Boolean = false,
    /** The Mac controlling this phone now, if any: grants cannot be raised meanwhile. */
    val controlledBy: String? = null,
    val macs: List<PhoneControlMac> = emptyList(),
    /** Unattended access: Macs on Default see and control this phone without asking. On by default. */
    val unattended: Boolean = true,
    /** Screenshots need Android 11 or later (seeing this phone with nobody here). */
    val screenshots: Boolean = true,
    /** Share screen with Macs was turned on by settings sync, not here: Macs are still asked. */
    val screenOnBySync: Boolean = false,
) {
    /** What Default gives a Mac now. */
    val defaultMode: PhoneControlGrantMode get() = if (unattended) PhoneControlGrantMode.ALWAYS else PhoneControlGrantMode.OFF
}

class PhoneControlSettingsActions(
    val openServiceSettings: () -> Unit = {},
    val openAppInfo: () -> Unit = {},
    /** A Mac's choice, null for Default. False when refused (raising a grant while a Mac controls this phone). */
    val setMode: (String, PhoneControlGrantMode?) -> Boolean = { _, _ -> true },
    /** False when refused (turning it on while a Mac controls this phone). */
    val setUnattended: (Boolean) -> Boolean = { true },
)

@Composable
private fun modeLabel(mode: PhoneControlGrantMode): String = stringResource(
    when (mode) {
        PhoneControlGrantMode.OFF -> R.string.control_mode_off
        PhoneControlGrantMode.ASK -> R.string.control_mode_ask
        PhoneControlGrantMode.ALWAYS -> R.string.control_mode_always
    },
)

/** What a Mac row says: its own choice, or Default with what Default gives now ("Default (Allow without asking)"). */
@Composable
private fun choiceLabel(choice: PhoneControlGrantMode?, defaultMode: PhoneControlGrantMode): String =
    choice?.let { modeLabel(it) } ?: stringResource(R.string.control_mode_default_value, modeLabel(defaultMode))

/**
 * The Remote control page's part: Unattended access, Bridgey control's status with Android's settings one tap away, then
 * each Mac's choice (Default, Off, Ask each time, Allow without asking), and why Android asks for an accessibility service.
 */
@Composable
internal fun PhoneControlCard(state: PhoneControlSettingsState, actions: PhoneControlSettingsActions, modifier: Modifier = Modifier) {
    var choosing by rememberSaveable { mutableStateOf<String?>(null) }
    var asked by rememberSaveable { mutableStateOf(false) }
    var unattendedRefused by rememberSaveable { mutableStateOf(false) }
    val openSettings = {
        asked = true
        actions.openServiceSettings()
    }
    FeatureCard(
        SettingsCard.PHONE_CONTROL, null, modifier,
        rows = {
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.unattended_title),
                    if (unattendedRefused && state.controlledBy != null) stringResource(R.string.control_raise_refused, state.controlledBy)
                    else stringResource(R.string.unattended_detail),
                    BridgeyIcons.ScreenShare, if (state.unattended) Tint.PURPLE else Tint.NEUTRAL,
                    checked = state.unattended,
                    onCheckedChange = { on -> unattendedRefused = !actions.setUnattended(on) },
                    detailWarning = unattendedRefused && state.controlledBy != null,
                )
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.control_settings_title),
                    stringResource(if (state.serviceEnabled) R.string.control_service_on else R.string.control_service_off),
                    BridgeyIcons.AdsClick, if (state.serviceEnabled) Tint.GREEN else Tint.NEUTRAL,
                    detailWarning = !state.serviceEnabled && state.macs.any { it.mode != PhoneControlGrantMode.OFF },
                    onClick = openSettings,
                ) {
                    if (state.serviceEnabled) {
                        Icon(BridgeyIcons.OpenInNew, null, tint = BridgeyTheme.colors.onSurfaceVariant)
                    } else {
                        TonalPillButton(stringResource(R.string.control_service_open), openSettings)
                    }
                }
            }
            state.macs.forEach { mac ->
                // A Mac on Default is not flagged: without screen sharing the switch simply has nothing to do for it.
                val needsShare = mac.choice != null && mac.choice != PhoneControlGrantMode.OFF && !mac.sharing
                row { shape ->
                    ListRow(
                        shape, mac.name,
                        if (needsShare) stringResource(R.string.control_mac_needs_share) else choiceLabel(mac.choice, state.defaultMode),
                        BridgeyIcons.LaptopMac, if (mac.mode == PhoneControlGrantMode.OFF) Tint.NEUTRAL else Tint.PURPLE,
                        compact = true,
                        detailWarning = needsShare,
                        onClick = { choosing = mac.id },
                        role = Role.Button,
                    ) {
                        Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
                    }
                }
            }
        },
        footer = {
            if (asked && !state.serviceEnabled && state.restrictedPossible) {
                RestrictedSettingsHint(stringResource(R.string.control_service_label), actions.openAppInfo, Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp))
            }
            // Unattended access needs Bridgey's screenshots: say what is missing rather than fail quietly.
            val unattendedNeeds = when {
                !state.unattended && state.macs.none { it.choice == PhoneControlGrantMode.ALWAYS } -> null
                !state.screenshots -> R.string.unattended_needs_android
                !state.serviceEnabled -> R.string.unattended_needs_service
                state.screenOnBySync -> R.string.unattended_needs_share_here
                else -> null
            }
            unattendedNeeds?.let { Note(stringResource(it), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) }
            Note(
                stringResource(if (state.typing) R.string.control_settings_note else R.string.control_settings_note_no_typing),
                Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp),
            )
        },
    )
    state.macs.firstOrNull { it.id == choosing }?.let { mac ->
        PhoneControlModeDialog(mac, state.defaultMode, state.controlledBy, onDismiss = { choosing = null }) { mode -> actions.setMode(mac.id, mode) }
    }
}

/**
 * Default, Off, Ask each time or Allow without asking for one Mac. Raising what it may do is refused while a Mac controls
 * this phone.
 */
@Composable
private fun PhoneControlModeDialog(
    mac: PhoneControlMac,
    defaultMode: PhoneControlGrantMode,
    controlledBy: String?,
    onDismiss: () -> Unit,
    choose: (PhoneControlGrantMode?) -> Boolean,
) {
    var refused by rememberSaveable { mutableStateOf(false) }
    val colors = BridgeyTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.control_mode_title, mac.name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                (listOf<PhoneControlGrantMode?>(null) + PhoneControlGrantMode.entries).forEach { mode ->
                    val selected = mode == mac.choice
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(16.dp))
                            .selectable(selected = selected, role = Role.RadioButton) {
                                if (choose(mode)) onDismiss() else refused = true
                            }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        RadioButton(selected = selected, onClick = null)
                        Column(Modifier.weight(1f)) {
                            Text(choiceLabel(mode, defaultMode), style = BridgeyType.itemTitle, color = colors.onSurface)
                            Text(
                                stringResource(
                                    when (mode) {
                                        null -> R.string.control_mode_default_detail
                                        PhoneControlGrantMode.OFF -> R.string.control_mode_off_detail
                                        PhoneControlGrantMode.ASK -> R.string.control_mode_ask_detail
                                        PhoneControlGrantMode.ALWAYS -> R.string.control_mode_always_detail
                                    },
                                ),
                                style = BridgeyType.itemBody, color = colors.onSurfaceVariant,
                            )
                        }
                    }
                }
                if (refused && controlledBy != null) {
                    Text(stringResource(R.string.control_raise_refused, controlledBy), style = BridgeyType.itemBody, color = colors.warn, modifier = Modifier.padding(top = 4.dp))
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}

private val idleControl = kotlinx.coroutines.flow.MutableStateFlow(dev.bridgey.android.control.PhoneControlViewState())

/** The Remote control page's phone control state and actions, read again when the app comes back from Android settings. */
class PhoneControlSettingsUi(val state: PhoneControlSettingsState, val actions: PhoneControlSettingsActions)

@Composable
fun rememberPhoneControlSettings(macs: List<Pair<String, String>>, sharingWith: (String) -> Boolean): PhoneControlSettingsUi {
    val context = androidx.compose.ui.platform.LocalContext.current
    val app = context.applicationContext as? dev.bridgey.android.BridgeyApplication
    val hub = app?.phoneControlOrNull
    var serviceEnabled by androidx.compose.runtime.remember { mutableStateOf(dev.bridgey.android.control.BridgeyControlService.enabled(context)) }
    var revision by androidx.compose.runtime.remember { mutableStateOf(0) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                serviceEnabled = dev.bridgey.android.control.BridgeyControlService.enabled(context)
                revision++
            }
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    val controlState by (hub?.state ?: idleControl).collectAsStateWithLifecycle()
    val modes = androidx.compose.runtime.remember(revision, macs, hub) { macs.associate { (id, _) -> id to (hub?.mode(id) ?: PhoneControlGrantMode.OFF) } }
    val choices = androidx.compose.runtime.remember(revision, macs, hub) { macs.associate { (id, _) -> id to hub?.choice(id) } }
    val state = PhoneControlSettingsState(
        built = hub != null,
        serviceEnabled = serviceEnabled,
        typing = android.os.Build.VERSION.SDK_INT >= dev.bridgey.android.control.PhoneControlLimits.TYPING_SDK,
        restrictedPossible = android.os.Build.VERSION.SDK_INT >= dev.bridgey.android.setup.RestrictedSettings.FIRST_SDK,
        controlledBy = controlState.takeIf { it.active }?.macName,
        macs = if (hub == null) emptyList() else macs.map { (id, name) -> PhoneControlMac(id, name, modes[id] ?: PhoneControlGrantMode.OFF, sharingWith(id), choices[id]) },
        unattended = androidx.compose.runtime.remember(revision, hub) { hub?.unattended ?: false },
        screenshots = android.os.Build.VERSION.SDK_INT >= dev.bridgey.android.screen.StillFrameRates.MIN_SDK,
        screenOnBySync = androidx.compose.runtime.remember(revision, app) { app?.settings?.screenOnBySync == true },
    )
    val actions = PhoneControlSettingsActions(
        openServiceSettings = { runCatching { context.startActivity(dev.bridgey.android.control.BridgeyControlService.settingsIntent()) } },
        openAppInfo = {
            runCatching {
                context.startActivity(
                    android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", context.packageName, null))
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        },
        setMode = { id, mode -> (hub?.setGrant(id, mode) == true).also { if (it) revision++ } },
        setUnattended = { on -> (hub?.setUnattended(on) == true).also { if (it) revision++ } },
    )
    return PhoneControlSettingsUi(state, actions)
}
