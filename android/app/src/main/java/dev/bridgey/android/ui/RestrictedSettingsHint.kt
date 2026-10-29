package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/**
 * Setup: Android may have blocked [kind] as a restricted setting (an app installed from a file or a browser,
 * Android 13 and later). A short explanation, the three steps, and a button that opens Bridgey's App info.
 */
@Composable
fun RestrictedSettingsHint(kind: PermissionKind, onOpenAppInfo: () -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(colors.surface2).padding(14.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(stringResource(R.string.restricted_hint_title), style = BridgeyType.itemTitle, color = colors.onSurface)
        Text(stringResource(R.string.restricted_hint_body, permissionName(kind)), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        Text(stringResource(R.string.restricted_hint_steps), style = BridgeyType.itemBody, color = colors.onSurface)
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(1f))
            TonalPillButton(stringResource(R.string.restricted_hint_open), onOpenAppInfo)
        }
    }
}
