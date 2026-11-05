package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.ui.motion.springIn
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** The generic Share screen entry uses the same visible destination rows as files and links. */
@Composable
fun ScreenDestinationSheet(
    choices: List<DeviceDestination>, selected: String?, unavailable: Boolean,
    select: (String) -> Unit, continueSharing: () -> Unit, cancel: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Column(Modifier.springIn().capWidth().fillMaxWidth().padding(12.dp).navigationBarsPadding()
            .clip(RoundedCornerShape(28.dp)).background(colors.surface1).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.screen_destination_title), style = BridgeyType.cardTitle, color = colors.onSurface)
            Text(stringResource(R.string.screen_destination_note), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            DeviceDestinationList(choices, selected, select)
            if (unavailable) Text(stringResource(R.string.destination_unavailable), style = BridgeyType.itemBody, color = colors.onTintPurple)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                OutlinePillButton(stringResource(R.string.action_cancel), null, cancel)
                GradientButton(stringResource(R.string.screen_destination_continue), null, continueSharing,
                    enabled = DeviceDestinationSelection.canSend(choices, selected), height = 44.dp, textStyle = BridgeyType.label)
            }
        }
    }
}
