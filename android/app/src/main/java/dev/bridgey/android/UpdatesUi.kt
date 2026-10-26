package dev.bridgey.android

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** "Update available" and "Install unknown apps" prompts. Shown above any screen. */
@Composable
fun UpdatePrompts(updater: AppUpdater) {
    val state by updater.state.collectAsStateWithLifecycle()
    val confirmation by updater.pendingConfirmation.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current

    LaunchedEffect(confirmation) {
        confirmation?.let { intent ->
            runCatching { context.startActivity(intent) }
                .onFailure { updater.onInstallFinished(UpdateError.INSTALLER) }
            updater.confirmationLaunched()
        }
    }

    val update = state.available
    if (state.promptVisible && update != null) {
        AlertDialog(
            onDismissRequest = updater::later,
            title = { Text("Update available") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Bridgey by Round Robin ${update.versionName} (${update.channel.title}) is ready to install.")
                    if (update.notes.isNotBlank()) ReleaseNotesList(update.notes, update.versionName)
                    if (update.notesUrl.isNotEmpty()) {
                        TextButton(onClick = { uriHandler.openUri(update.notesUrl) }) { Text("Read release notes") }
                    }
                }
            },
            confirmButton = { Button(onClick = updater::install) { Text("Install") } },
            dismissButton = { TextButton(onClick = updater::later) { Text("Later") } },
        )
    }

    if (state.needsInstallPermission) {
        AlertDialog(
            onDismissRequest = updater::dismissInstallPermission,
            title = { Text("Allow Bridgey to install updates") },
            text = {
                Text(
                    "Android asks before an app installs its own updates. Open Install unknown apps, " +
                        "turn on Allow from this source for Bridgey by Round Robin, then come back and tap Install again.",
                )
            },
            confirmButton = {
                Button(onClick = {
                    updater.dismissInstallPermission()
                    context.startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")),
                    )
                }) { Text("Open settings") }
            },
            dismissButton = { TextButton(onClick = updater::dismissInstallPermission) { Text("Not now") } },
        )
    }
}

/** What the Settings > Updates status card shows: one state at a time. */
sealed interface UpdateCardPhase {
    data object Checking : UpdateCardPhase
    data class Downloading(val update: AndroidUpdate, val progress: Float) : UpdateCardPhase
    /** The APK is with the Android installer (the phone's "ready to restart"). */
    data class Confirming(val update: AndroidUpdate) : UpdateCardPhase
    data class Failed(val error: UpdateError, val retryInstalls: Boolean) : UpdateCardPhase
    data class Available(val update: AndroidUpdate) : UpdateCardPhase
    /** Later was tapped: the update waits behind Show update. */
    data class Waiting(val update: AndroidUpdate) : UpdateCardPhase
    data class Skipped(val versionName: String) : UpdateCardPhase
    /** Up to date (or never checked when [lastCheckedAt] is 0). */
    data class Current(val lastCheckedAt: Long) : UpdateCardPhase
}

fun updateCardPhase(state: UpdateUiState): UpdateCardPhase {
    val update = state.available
    val progress = state.downloadProgress
    return when {
        update != null && progress != null -> UpdateCardPhase.Downloading(update, progress)
        update != null && state.awaitingConfirmation -> UpdateCardPhase.Confirming(update)
        state.error != null -> UpdateCardPhase.Failed(state.error, retryInstalls = update != null && state.error != UpdateError.CHECK)
        state.checking -> UpdateCardPhase.Checking
        update != null && !state.deferred -> UpdateCardPhase.Available(update)
        update != null -> UpdateCardPhase.Waiting(update)
        state.skippedVersion != null -> UpdateCardPhase.Skipped(state.skippedVersion)
        else -> UpdateCardPhase.Current(state.lastCheckedAt)
    }
}

@Composable
fun updateErrorText(error: UpdateError): String = stringResource(
    when (error) {
        UpdateError.CHECK -> R.string.update_error_check
        UpdateError.DOWNLOAD -> R.string.update_error_download
        UpdateError.SAFETY -> R.string.update_error_safety
        UpdateError.INSTALLER -> R.string.update_error_installer
        UpdateError.CANCELLED -> R.string.update_error_cancelled
    },
)

/** Release notes as a list: about four lines, then Show all. Never scrolls on its own. */
@Composable
fun ReleaseNotesList(notes: String, version: String, modifier: Modifier = Modifier, trailing: @Composable RowScope.() -> Unit = {}) {
    val blocks = remember(notes, version) { ReleaseNotes.blocks(notes, version) }
    if (blocks.isEmpty()) return
    val preview = remember(blocks) { ReleaseNotes.preview(blocks) }
    var expanded by rememberSaveable(version) { mutableStateOf(false) }
    val colors = BridgeyTheme.colors
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        (if (expanded) blocks else preview).forEach { block ->
            when (block) {
                is ReleaseNoteBlock.Heading -> Text(
                    block.text,
                    style = BridgeyType.smallStrong,
                    color = colors.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp).semantics { heading() },
                )
                is ReleaseNoteBlock.Bullet -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.padding(top = 7.dp).size(5.dp).clip(CircleShape).background(colors.onSurfaceVariant))
                    Text(block.text, style = BridgeyType.itemBody, color = colors.onSurface, modifier = Modifier.weight(1f))
                }
                is ReleaseNoteBlock.Paragraph -> Text(block.text, style = BridgeyType.itemBody, color = colors.onSurface)
            }
        }
        // Show all and the caller's link share one row of 48 dp touch targets.
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            if (preview.size < blocks.size) {
                Text(
                    if (expanded) stringResource(R.string.updates_show_less) else stringResource(R.string.updates_show_all, blocks.size),
                    style = BridgeyType.smallStrong.copy(fontSize = BridgeyType.itemBody.fontSize),
                    color = colors.primary,
                    modifier = Modifier
                        .heightIn(min = 48.dp)
                        .clip(RoundedCornerShape(24.dp))
                        .clickable(role = Role.Button) { expanded = !expanded }
                        .wrapContentHeight(Alignment.CenterVertically),
                )
            }
            trailing()
        }
    }
}
