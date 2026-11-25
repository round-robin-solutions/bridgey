package dev.bridgey.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
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

/** A paired Mac on the Remote control page: whether it may control this phone. */
data class PhoneControlMac(
    val id: String,
    val name: String,
    val mode: PhoneControlGrantMode,
    /** Share screen with Macs is on for it: control happens inside a share, so without it nothing can start. */
    val sharing: Boolean,
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
)

class PhoneControlSettingsActions(
    val openServiceSettings: () -> Unit = {},
    val openAppInfo: () -> Unit = {},
    /** False when refused (raising a grant while a Mac controls this phone). */
    val setMode: (String, PhoneControlGrantMode) -> Boolean = { _, _ -> true },
)

@Composable
private fun modeLabel(mode: PhoneControlGrantMode): String = stringResource(
    when (mode) {
        PhoneControlGrantMode.OFF -> R.string.control_mode_off
        PhoneControlGrantMode.ASK -> R.string.control_mode_ask
        PhoneControlGrantMode.ALWAYS -> R.string.control_mode_always
    },
)

/**
 * The Remote control page's part: Bridgey control's status with Android's settings one tap away, then each Mac's choice
 * (Off, Ask each time, Allow without asking), and why Android asks for an accessibility service.
 */
internal fun LazyListScope.phoneControlItems(state: PhoneControlSettingsState, actions: PhoneControlSettingsActions) {
    if (!state.built) return
    item(key = "remote.phoneControl") {
        var choosing by rememberSaveable { mutableStateOf<String?>(null) }
        var asked by rememberSaveable { mutableStateOf(false) }
        val openSettings = {
            asked = true
            actions.openServiceSettings()
        }
        Column {
            RowGroup(Modifier.padding(top = 16.dp)) {
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
                    row { shape ->
                        ListRow(
                            shape, mac.name,
                            if (mac.mode != PhoneControlGrantMode.OFF && !mac.sharing) stringResource(R.string.control_mac_needs_share) else modeLabel(mac.mode),
                            BridgeyIcons.LaptopMac, if (mac.mode == PhoneControlGrantMode.OFF) Tint.NEUTRAL else Tint.PURPLE,
                            compact = true,
                            detailWarning = mac.mode != PhoneControlGrantMode.OFF && !mac.sharing,
                            onClick = { choosing = mac.id },
                            role = Role.Button,
                            searchTitle = stringResource(R.string.control_settings_title),
                        ) {
                            Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
                        }
                    }
                }
            }
            if (asked && !state.serviceEnabled && state.restrictedPossible) {
                RestrictedSettingsHint(stringResource(R.string.control_service_label), actions.openAppInfo, Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp))
            }
            Note(
                stringResource(if (state.typing) R.string.control_settings_note else R.string.control_settings_note_no_typing),
                Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp),
            )
        }
        state.macs.firstOrNull { it.id == choosing }?.let { mac ->
            PhoneControlModeDialog(mac, state.controlledBy, onDismiss = { choosing = null }) { mode -> actions.setMode(mac.id, mode) }
        }
    }
}

/** Off, Ask each time or Allow without asking for one Mac. Raising it is refused while a Mac controls this phone. */
@Composable
private fun PhoneControlModeDialog(mac: PhoneControlMac, controlledBy: String?, onDismiss: () -> Unit, choose: (PhoneControlGrantMode) -> Boolean) {
    var refused by rememberSaveable { mutableStateOf(false) }
    val colors = BridgeyTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.control_mode_title, mac.name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                PhoneControlGrantMode.entries.forEach { mode ->
                    val selected = mode == mac.mode
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
                            Text(modeLabel(mode), style = BridgeyType.itemTitle, color = colors.onSurface)
                            Text(
                                stringResource(
                                    when (mode) {
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
    val state = PhoneControlSettingsState(
        built = hub != null,
        serviceEnabled = serviceEnabled,
        typing = android.os.Build.VERSION.SDK_INT >= dev.bridgey.android.control.PhoneControlLimits.TYPING_SDK,
        restrictedPossible = android.os.Build.VERSION.SDK_INT >= dev.bridgey.android.setup.RestrictedSettings.FIRST_SDK,
        controlledBy = controlState.takeIf { it.active }?.macName,
        macs = if (hub == null) emptyList() else macs.map { (id, name) -> PhoneControlMac(id, name, modes[id] ?: PhoneControlGrantMode.OFF, sharingWith(id)) },
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
    )
    return PhoneControlSettingsUi(state, actions)
}
