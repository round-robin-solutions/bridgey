package dev.bridgey.android

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.selectable
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

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
                .onFailure { updater.onInstallFinished("Android did not open the installer.") }
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
                    if (update.notes.isNotBlank()) {
                        Text(update.notes.take(600), style = MaterialTheme.typography.bodySmall)
                    }
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
