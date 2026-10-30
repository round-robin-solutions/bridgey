package dev.bridgey.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import dev.bridgey.android.R
import dev.bridgey.android.ui.theme.BridgeyTheme

/** Settings > Text messages: what Android allows, and how replies from the Mac are sent. */
data class MessagesSettingsState(
    /** READ_SMS and SEND_SMS. */
    val smsAllowed: Boolean = false,
    /** READ_CONTACTS: names and contact search on the Mac. */
    val contactsAllowed: Boolean = false,
    /** A dual-SIM phone: the Mac can pick a SIM once Phone and calls lists them. */
    val dualSim: Boolean = false,
    val simsAllowed: Boolean = false,
    /** Send replies as SMS (off: through the messaging app when it offers a reply). */
    val replyAsSms: Boolean = false,
)

class MessagesSettingsActions(
    val setReplyAsSms: (Boolean) -> Unit = {},
    /** Asks for READ_SMS and SEND_SMS (or opens App info once refused). */
    val allowSms: () -> Unit = {},
    val allowContacts: () -> Unit = {},
    val allowSims: () -> Unit = {},
)

/** The rows under the Text messages switch: permissions, then Send replies as SMS. */
internal fun GroupScope.messagesRows(state: MessagesSettingsState, actions: MessagesSettingsActions) {
    row { shape ->
        AccessRow(
            shape, stringResource(R.string.messages_sms_access),
            stringResource(if (state.smsAllowed) R.string.messages_sms_access_on else R.string.messages_sms_access_off),
            state.smsAllowed, BridgeyIcons.Sms, actions.allowSms,
        )
    }
    row { shape ->
        AccessRow(
            shape, stringResource(R.string.messages_contacts_access),
            stringResource(if (state.contactsAllowed) R.string.messages_contacts_access_on else R.string.messages_contacts_access_off),
            state.contactsAllowed, BridgeyIcons.Contacts, actions.allowContacts,
        )
    }
    if (state.dualSim) {
        row { shape ->
            AccessRow(
                shape, stringResource(R.string.messages_sims_access),
                stringResource(if (state.simsAllowed) R.string.messages_sims_access_on else R.string.messages_sims_access_off),
                state.simsAllowed, BridgeyIcons.SimCard, actions.allowSims,
            )
        }
    }
    row { shape ->
        SwitchRow(
            shape, stringResource(R.string.messages_reply_as_sms), stringResource(R.string.messages_reply_as_sms_detail),
            BridgeyIcons.Sms, if (state.replyAsSms) Tint.GREEN else Tint.NEUTRAL, state.replyAsSms, actions.setReplyAsSms,
        )
    }
}

@Composable
private fun AccessRow(shape: Shape, title: String, detail: String, allowed: Boolean, icon: androidx.compose.ui.graphics.vector.ImageVector, onAllow: () -> Unit) {
    ListRow(
        shape, title, detail, icon, if (allowed) Tint.GREEN else Tint.NEUTRAL,
        detailWarning = !allowed,
        onClick = onAllow,
    ) {
        if (allowed) {
            androidx.compose.material3.Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
        } else {
            TonalPillButton(stringResource(R.string.messages_allow), onAllow)
        }
    }
}
