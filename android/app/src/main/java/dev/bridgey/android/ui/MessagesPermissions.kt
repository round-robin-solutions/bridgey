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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect

/**
 * Text messages asks Android only when it is turned on or Allow is tapped: SMS (read and send) and
 * contacts together, and on a dual-SIM phone Phone and calls, to list the SIMs. A permission refused
 * for good opens App info instead of a dialog that would not show.
 */
class MessagesPermissions(
    val state: MessagesSettingsState,
    val askAll: () -> Unit,
    val askSms: () -> Unit,
    val askContacts: () -> Unit,
    val askSims: () -> Unit,
)

@Composable
fun rememberMessagesPermissions(replyAsSms: Boolean, dualSim: Boolean, onChanged: () -> Unit): MessagesPermissions {
    val context = LocalContext.current
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { resumes++ }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        resumes++
        onChanged()
    }
    fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    val state = remember(resumes, replyAsSms, dualSim) {
        MessagesSettingsState(
            smsAllowed = granted(Manifest.permission.READ_SMS) && granted(Manifest.permission.SEND_SMS),
            contactsAllowed = granted(Manifest.permission.READ_CONTACTS),
            dualSim = dualSim,
            simsAllowed = granted(Manifest.permission.READ_PHONE_STATE),
            replyAsSms = replyAsSms,
        )
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
    val sms = listOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS)
    val contacts = listOf(Manifest.permission.READ_CONTACTS)
    val sims = listOf(Manifest.permission.READ_PHONE_STATE)
    return MessagesPermissions(
        state = state,
        askAll = { ask(sms + contacts + if (dualSim) sims else emptyList()) },
        askSms = { ask(sms) },
        askContacts = { ask(contacts) },
        askSims = { ask(sims) },
    )
}

/** Which permissions Text messages has asked for before (so a refusal for good is told apart from never asked). */
private const val PREFERENCES = "bridgey.sms.asked"
