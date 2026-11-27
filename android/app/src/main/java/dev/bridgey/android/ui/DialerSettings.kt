package dev.bridgey.android.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import dev.bridgey.android.BuildGates
import dev.bridgey.android.R
import dev.bridgey.android.ui.theme.BridgeyTheme

/** A paired Mac on the Calls page: whether it may use this phone for calls. */
data class DialerMac(val id: String, val name: String, val allowed: Boolean)

/** Settings > Calls > Calls window: what Android allows, Ask on this phone first, and the Macs allowed. */
data class DialerSettingsState(
    /** CALL_PHONE (with READ_PHONE_STATE for the SIMs): calls start without a tap. */
    val placeAllowed: Boolean = false,
    val contactsAllowed: Boolean = false,
    val callLogAllowed: Boolean = false,
    /** This build may ask for contacts and the call log (not the Play build). */
    val contactsBuilt: Boolean = true,
    val callLogBuilt: Boolean = true,
    val askFirst: Boolean = false,
    /** Ask on this phone first posts a notification for each call: without them every call is refused. */
    val notificationsAllowed: Boolean = true,
    val macs: List<DialerMac> = emptyList(),
)

class DialerSettingsActions(
    val allowPlace: () -> Unit = {},
    val allowContacts: () -> Unit = {},
    val allowCallLog: () -> Unit = {},
    val setAskFirst: (Boolean) -> Unit = {},
    val allowNotifications: () -> Unit = {},
    val setMacAllowed: (String, Boolean) -> Unit = { _, _ -> },
)

/** The rows under the Calls window switch: permissions and Ask on this phone first. */
internal fun GroupScope.dialerRows(state: DialerSettingsState, actions: DialerSettingsActions) {
    dialerMainRows(state, actions)
    dialerMoreRows(state, actions)
}

/** The Calls window card's main rows: Place calls, Ask on this phone first (and the notifications it needs). */
internal fun GroupScope.dialerMainRows(state: DialerSettingsState, actions: DialerSettingsActions) {
    row { shape ->
        DialerAccessRow(
            shape, stringResource(R.string.dialer_place_access),
            stringResource(if (state.placeAllowed) R.string.dialer_place_access_on else R.string.dialer_place_access_off),
            state.placeAllowed, BridgeyIcons.Call, actions.allowPlace,
        )
    }
    row { shape ->
        SwitchRow(
            shape, stringResource(R.string.dialer_ask_first), stringResource(R.string.dialer_ask_first_detail),
            BridgeyIcons.Smartphone, if (state.askFirst) Tint.GREEN else Tint.NEUTRAL, state.askFirst, actions.setAskFirst,
        )
    }
    if (state.askFirst && !state.notificationsAllowed) {
        row { shape ->
            DialerAccessRow(
                shape, stringResource(R.string.perm_post_notifications_name),
                stringResource(R.string.dialer_ask_first_needs_notifications), false,
                BridgeyIcons.Notifications, actions.allowNotifications,
            )
        }
    }
}

/** The Calls window card's More options: contacts and call history. */
internal fun GroupScope.dialerMoreRows(state: DialerSettingsState, actions: DialerSettingsActions) {
    if (state.contactsBuilt) {
        row { shape ->
            DialerAccessRow(
                shape, stringResource(R.string.perm_contacts_name),
                stringResource(if (state.contactsAllowed) R.string.dialer_contacts_access_on else R.string.dialer_contacts_access_off),
                state.contactsAllowed, BridgeyIcons.Contacts, actions.allowContacts,
            )
        }
    }
    if (state.callLogBuilt) {
        row { shape ->
            DialerAccessRow(
                shape, stringResource(R.string.perm_call_log_name),
                stringResource(if (state.callLogAllowed) R.string.dialer_call_log_access_on else R.string.dialer_call_log_access_off),
                state.callLogAllowed, BridgeyIcons.Update, actions.allowCallLog,
            )
        }
    }
}

/** One switch per paired Mac: off until allowed. */
internal fun GroupScope.dialerMacRows(state: DialerSettingsState, actions: DialerSettingsActions) {
    state.macs.forEach { mac ->
        row { shape ->
            SwitchRow(
                shape, mac.name,
                stringResource(if (mac.allowed) R.string.dialer_mac_allowed else R.string.dialer_mac_not_allowed),
                BridgeyIcons.LaptopMac, if (mac.allowed) Tint.GREEN else Tint.NEUTRAL, mac.allowed,
                { actions.setMacAllowed(mac.id, it) }, compact = true,
            )
        }
    }
}

@Composable
private fun DialerAccessRow(shape: Shape, title: String, detail: String, allowed: Boolean, icon: ImageVector, onAllow: () -> Unit) {
    ListRow(
        shape, title, detail, icon, if (allowed) Tint.GREEN else Tint.NEUTRAL,
        detailWarning = !allowed,
        onClick = onAllow,
    ) {
        if (allowed) {
            Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
        } else {
            TonalPillButton(stringResource(R.string.messages_allow), onAllow, label = stringResource(R.string.action_allow_named, title))
        }
    }
}

/**
 * Asks Android only when the Calls window is turned on or Allow is tapped: Phone (CALL_PHONE and, for
 * the SIM list, READ_PHONE_STATE), contacts and call history, each on its own row. A permission
 * refused for good opens App info instead of a dialog that would not show.
 */
class DialerPermissions(
    val placeAllowed: Boolean,
    val contactsAllowed: Boolean,
    val callLogAllowed: Boolean,
    val askAll: () -> Unit,
    val askPlace: () -> Unit,
    val askContacts: () -> Unit,
    val askCallLog: () -> Unit,
)

@Composable
fun rememberDialerPermissions(onChanged: () -> Unit): DialerPermissions {
    val context = LocalContext.current
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { resumes++ }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        resumes++
        onChanged()
    }
    fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    val place = listOf(Manifest.permission.CALL_PHONE, Manifest.permission.READ_PHONE_STATE)
    val contacts = if (BuildGates.contacts) listOf(Manifest.permission.READ_CONTACTS) else emptyList()
    val callLog = if (BuildGates.callLog) listOf(Manifest.permission.READ_CALL_LOG) else emptyList()
    val states = remember(resumes) {
        Triple(granted(Manifest.permission.CALL_PHONE), contacts.isNotEmpty() && contacts.all(::granted), callLog.isNotEmpty() && callLog.all(::granted))
    }
    fun ask(permissions: List<String>) {
        val missing = permissions.filterNot(::granted)
        if (missing.isEmpty()) return
        val activity = context as? Activity
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val refusedForGood = activity != null && missing.all { preferences.getBoolean(it, false) && !activity.shouldShowRequestPermissionRationale(it) }
        if (refusedForGood) {
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
            return
        }
        preferences.edit().apply { missing.forEach { putBoolean(it, true) } }.apply()
        launcher.launch(missing.toTypedArray())
    }
    return DialerPermissions(
        placeAllowed = states.first,
        contactsAllowed = states.second,
        callLogAllowed = states.third,
        askAll = { ask(place + contacts + callLog) },
        askPlace = { ask(place) },
        askContacts = { ask(contacts) },
        askCallLog = { ask(callLog) },
    )
}

/** Which permissions the Calls window has asked for before (so a refusal for good is told apart from never asked). */
private const val PREFERENCES = "bridgey.dialer.asked"
