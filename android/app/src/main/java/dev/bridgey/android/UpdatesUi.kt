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

private const val UPSTREAM_URL = "https://github.com/singeol/bridgey"

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

/** Settings items: Updates (channel, Check now, last check, version) and About (attribution). */
fun LazyListScope.updateAndAboutItems(updater: AppUpdater) {
    item { SettingsSectionTitle("Updates") }
    item { UpdatesCard(updater) }
    item { SettingsSectionTitle("About") }
    item { AboutCard(updater) }
}

@Composable
private fun UpdatesCard(updater: AppUpdater) {
    val state by updater.state.collectAsStateWithLifecycle()
    Card(shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "Version ${updater.installedVersionName} (${updater.installedVersionCode}) · ${state.channel.title} channel",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            UpdateChannel.entries.forEach { channel ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .selectable(
                            selected = channel == state.channel,
                            role = Role.RadioButton,
                            onClick = { updater.setChannel(channel) },
                        ),
                ) {
                    RadioButton(selected = channel == state.channel, onClick = null)
                    Column(Modifier.padding(start = 12.dp).weight(1f)) {
                        Text(channel.title, fontWeight = FontWeight.Medium)
                        Text(channel.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            Text(
                "Switching to a more stable channel never downgrades. Bridgey waits for the next newer build there.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                if (state.lastCheckedAt > 0) {
                    "Last checked " + DateUtils.getRelativeTimeSpanString(state.lastCheckedAt).toString().replaceFirstChar { it.lowercase() }
                } else {
                    "Not checked yet"
                },
                style = MaterialTheme.typography.bodySmall,
            )
            state.status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            state.downloadProgress?.let { LinearProgressIndicator(progress = { it }, modifier = Modifier.fillMaxWidth()) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = updater::checkNow, enabled = !state.checking) {
                    Text(if (state.checking) "Checking…" else "Check now")
                }
                val update = state.available
                if (update != null && state.downloadProgress == null) {
                    Button(onClick = updater::install) { Text("Install ${update.versionName}") }
                }
            }
        }
    }
}

@Composable
private fun AboutCard(updater: AppUpdater) {
    val uriHandler = LocalUriHandler.current
    Card(shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Bridgey by Round Robin", fontWeight = FontWeight.SemiBold)
            Text("Version ${updater.installedVersionName}", style = MaterialTheme.typography.bodySmall)
            Text("Built on Bridgey by Semyon Mikhailov.", style = MaterialTheme.typography.bodySmall)
            Text(
                "Open source under the MIT License.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            TextButton(onClick = { uriHandler.openUri(UPSTREAM_URL) }) { Text("Original Bridgey project") }
        }
    }
}

@Composable
private fun SettingsSectionTitle(value: String) =
    Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
