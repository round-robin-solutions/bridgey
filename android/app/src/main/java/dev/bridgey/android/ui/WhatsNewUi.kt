package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.ReleaseNoteBlock
import dev.bridgey.android.ReleaseNotes
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/**
 * What's new, once after an update: the installed build's notes (from the feed, else bundled),
 * Got it, and Review setup for people who updated from a build before setup existed.
 */
@Composable
fun WhatsNewDialog(
    version: String,
    notes: String?,
    reviewSetup: Boolean,
    onDismiss: () -> Unit,
    onReviewSetup: () -> Unit,
    onOpenNotes: () -> Unit,
) {
    val colors = BridgeyTheme.colors
    val blocks = remember(notes, version) { notes?.let { ReleaseNotes.blocks(it, version) }.orEmpty() }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surface2,
        icon = { IconTile(BridgeyIcons.Update, Tint.PURPLE, size = 48.dp, corner = 16.dp, iconSize = 26.dp) },
        title = {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.whats_new_title), style = BridgeyType.cardTitle, color = colors.onSurface)
                Text(stringResource(R.string.whats_new_version, version), style = BridgeyType.small, color = colors.onSurfaceVariant)
            }
        },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (blocks.isEmpty()) {
                    Text(stringResource(R.string.whats_new_no_notes), style = BridgeyType.bodyText, color = colors.onSurface)
                } else {
                    blocks.forEach { block ->
                        when (block) {
                            is ReleaseNoteBlock.Heading -> Text(block.text, style = BridgeyType.smallStrong, color = colors.onSurfaceVariant, modifier = Modifier.semantics { heading() })
                            is ReleaseNoteBlock.Bullet -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Box(Modifier.padding(top = 7.dp).size(5.dp).clip(CircleShape).background(colors.primary))
                                Text(block.text, style = BridgeyType.itemBody, color = colors.onSurface, modifier = Modifier.weight(1f))
                            }
                            is ReleaseNoteBlock.Paragraph -> Text(block.text, style = BridgeyType.itemBody, color = colors.onSurface)
                        }
                    }
                }
                Row(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onOpenNotes),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(stringResource(R.string.whats_new_release_notes), style = BridgeyType.smallStrong, color = colors.primary)
                    Icon(BridgeyIcons.OpenInNew, null, tint = colors.primary, modifier = Modifier.size(14.dp))
                }
                if (reviewSetup) {
                    Text(stringResource(R.string.whats_new_review_note), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                }
            }
        },
        confirmButton = {
            if (reviewSetup) {
                TextButton(onClick = onReviewSetup) { Text(stringResource(R.string.whats_new_review), style = BridgeyType.label, color = colors.primary) }
            } else {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.whats_new_got_it), style = BridgeyType.label, color = colors.primary) }
            }
        },
        dismissButton = if (reviewSetup) {
            { TextButton(onClick = onDismiss) { Text(stringResource(R.string.whats_new_got_it), style = BridgeyType.label, color = colors.onSurfaceVariant) } }
        } else {
            null
        },
    )
}

/**
 * Home, once, for people who updated from a build before setup: "See what's new and review your
 * setup". Sits above the send bar; the rest of Home stays usable.
 */
@Composable
fun WhatsNewBanner(onOpen: () -> Unit, onDismiss: () -> Unit) {
    val colors = BridgeyTheme.colors
    Box(Modifier.fillMaxSize().navigationBarsPadding().padding(bottom = 88.dp), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier
                .padding(horizontal = 16.dp)
                .capWidth()
                .fillMaxWidth()
                .shadow(8.dp, RoundedCornerShape(24.dp))
                .clip(RoundedCornerShape(24.dp))
                .background(colors.surface2)
                .clickable(role = Role.Button, onClick = onOpen)
                .padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            IconTile(BridgeyIcons.Update, Tint.PURPLE, size = 40.dp, corner = 14.dp, iconSize = 22.dp)
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.whats_new_banner_title), style = BridgeyType.itemTitle, color = colors.onSurface)
                Text(stringResource(R.string.whats_new_banner_body), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
            WithContentColor(colors.onSurfaceVariant) { BarIconButton(BridgeyIcons.Close, stringResource(R.string.action_dismiss), onDismiss) }
        }
    }
}
