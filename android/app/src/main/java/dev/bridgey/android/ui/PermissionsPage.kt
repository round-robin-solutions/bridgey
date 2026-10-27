package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.setup.PermissionEntry
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.PermissionState
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

@Composable
fun permissionName(kind: PermissionKind): String = stringResource(
    when (kind) {
        PermissionKind.NOTIFICATION_ACCESS -> R.string.perm_notification_access_name
        PermissionKind.POST_NOTIFICATIONS -> R.string.perm_post_notifications_name
        PermissionKind.PHONE_CALLS -> R.string.perm_phone_calls_name
        PermissionKind.PHOTOS -> R.string.perm_photos_name
        PermissionKind.COMPANION_LINK -> R.string.perm_companion_link_name
        PermissionKind.BATTERY -> R.string.perm_battery_name
        PermissionKind.INSTALL_PACKAGES -> R.string.perm_install_packages_name
        PermissionKind.SMS -> R.string.perm_sms_name
        PermissionKind.LOGS -> R.string.perm_logs_name
    },
)

@Composable
fun permissionWhy(kind: PermissionKind): String = stringResource(
    when (kind) {
        PermissionKind.NOTIFICATION_ACCESS -> R.string.perm_notification_access_why
        PermissionKind.POST_NOTIFICATIONS -> R.string.perm_post_notifications_why
        PermissionKind.PHONE_CALLS -> R.string.perm_phone_calls_why
        PermissionKind.PHOTOS -> R.string.perm_photos_why
        PermissionKind.COMPANION_LINK -> R.string.perm_companion_link_why
        PermissionKind.BATTERY -> R.string.perm_battery_why
        PermissionKind.INSTALL_PACKAGES -> R.string.perm_install_packages_why
        PermissionKind.SMS -> R.string.perm_sms_why
        PermissionKind.LOGS -> R.string.perm_logs_why
    },
)

@Composable
fun permissionWithout(kind: PermissionKind): String = stringResource(
    when (kind) {
        PermissionKind.NOTIFICATION_ACCESS -> R.string.perm_notification_access_without
        PermissionKind.POST_NOTIFICATIONS -> R.string.perm_post_notifications_without
        PermissionKind.PHONE_CALLS -> R.string.perm_phone_calls_without
        PermissionKind.PHOTOS -> R.string.perm_photos_without
        PermissionKind.COMPANION_LINK -> R.string.perm_companion_link_without
        PermissionKind.BATTERY -> R.string.perm_battery_without
        PermissionKind.INSTALL_PACKAGES -> R.string.perm_install_packages_without
        PermissionKind.SMS -> R.string.perm_sms_without
        PermissionKind.LOGS -> R.string.perm_logs_without
    },
)

fun permissionIcon(kind: PermissionKind): Pair<ImageVector, Tint> = when (kind) {
    PermissionKind.NOTIFICATION_ACCESS -> BridgeyIcons.Notifications to Tint.PURPLE
    PermissionKind.POST_NOTIFICATIONS -> BridgeyIcons.Notifications to Tint.BLUE
    PermissionKind.PHONE_CALLS -> BridgeyIcons.Call to Tint.GREEN
    PermissionKind.PHOTOS -> BridgeyIcons.Image to Tint.BLUE
    PermissionKind.COMPANION_LINK -> BridgeyIcons.Link to Tint.BLUE
    PermissionKind.BATTERY -> BridgeyIcons.Bolt to Tint.GREEN
    PermissionKind.INSTALL_PACKAGES -> BridgeyIcons.SystemUpdate to Tint.PURPLE
    PermissionKind.SMS -> BridgeyIcons.Description to Tint.NEUTRAL
    PermissionKind.LOGS -> BridgeyIcons.DeveloperMode to Tint.NEUTRAL
}

/** "Allow Notification access?", the one-line why and without-it, Continue and Not now. */
@Composable
fun PermissionExplainerDialog(kind: PermissionKind, onContinue: () -> Unit, onDismiss: () -> Unit) {
    val colors = BridgeyTheme.colors
    val (icon, tint) = permissionIcon(kind)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface2,
        icon = { IconTile(icon, tint, size = 48.dp, corner = 16.dp, iconSize = 26.dp) },
        title = { Text(stringResource(R.string.perm_explainer_title, permissionName(kind)), style = BridgeyType.cardTitle, color = colors.onSurface) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(R.string.setup_why, permissionWhy(kind)), style = BridgeyType.bodyText, color = colors.onSurface)
                Text(stringResource(R.string.setup_without, permissionWithout(kind)), style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = onContinue) { Text(stringResource(R.string.perm_continue), style = BridgeyType.label, color = colors.primary) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_not_now), style = BridgeyType.label, color = colors.onSurfaceVariant) } },
    )
}

/** Settings > Privacy > Permissions: every optional permission, its state and Manage. */
@Composable
fun PermissionsScreen(entries: List<PermissionEntry>, onBack: () -> Unit, onManage: (PermissionEntry) -> Unit) {
    SettingsPage(stringResource(R.string.perm_page_title), onBack) {
        item(key = "intro") { Note(stringResource(R.string.perm_page_intro), Modifier.padding(start = 32.dp, end = 32.dp, top = 20.dp, bottom = 12.dp)) }
        item(key = "permissions") {
            RowGroup {
                entries.forEach { entry -> row { shape -> PermissionRowItem(shape, entry) { onManage(entry) } } }
            }
        }
    }
}

@Composable
private fun PermissionRowItem(shape: Shape, entry: PermissionEntry, onManage: () -> Unit) {
    val colors = BridgeyTheme.colors
    val (icon, tint) = permissionIcon(entry.kind)
    val available = entry.state != PermissionState.NOT_ON_THIS_DEVICE
    Row(
        Modifier.fillMaxWidth().clip(shape).background(colors.surface1).padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        IconTile(icon, if (entry.state == PermissionState.ALLOWED) tint else Tint.NEUTRAL)
        Column(Modifier.weight(1f)) {
            Text(permissionName(entry.kind), style = BridgeyType.rowTitle, color = colors.onSurface, modifier = Modifier.padding(end = 8.dp))
            Text(permissionWhy(entry.kind), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 1.dp, end = 8.dp))
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                PermissionStateChip(entry.state)
                Spacer(Modifier.weight(1f))
                if (available) {
                    Text(
                        stringResource(R.string.action_manage),
                        style = BridgeyType.label,
                        color = colors.primary,
                        modifier = Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onManage)
                            .padding(horizontal = 12.dp, vertical = 14.dp),
                    )
                }
            }
        }
    }
}

@Composable
fun PermissionStateChip(state: PermissionState) {
    when (state) {
        PermissionState.ALLOWED -> StatusPill(stringResource(R.string.perm_state_allowed), BridgeyIcons.Check, Tint.GREEN)
        PermissionState.NOT_ALLOWED -> StatusPill(stringResource(R.string.perm_state_not_allowed), null, Tint.PURPLE)
        PermissionState.NOT_NEEDED_YET -> StatusPill(stringResource(R.string.perm_state_not_needed), null, Tint.NEUTRAL)
        PermissionState.NOT_ON_THIS_DEVICE -> StatusPill(stringResource(R.string.perm_state_not_on_device), null, Tint.NEUTRAL)
    }
}
