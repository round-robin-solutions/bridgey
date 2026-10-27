package dev.bridgey.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.FileTransferState
import dev.bridgey.android.R
import dev.bridgey.android.folders.FolderEnd
import dev.bridgey.android.folders.FolderWaiting
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import kotlinx.coroutines.delay

/** At most this many saved names show when a folder card is open; the rest is "and N earlier". */
private const val SHOWN_SAVED = 12
private const val SHOWN_FAILURES = 5

/**
 * One folder, one card (3.4): "Photos from MacBook Pro › Pictures/Trip", progress by bytes, "37 of 124 files ·
 * 812 MB of 2.3 GB · 12 MB/s · 2 min left". Tap to open: the current file with its own progress, failures with
 * their reasons, then the last saved names. Cancel cancels the whole folder.
 */
@Composable
internal fun FolderCardContent(transfer: FileTransferState, cancelAll: Boolean, startExpanded: Boolean, actions: LiveActions) {
    val folder = transfer.folder ?: return CardText(transfer.name, transfer.status)
    val context = LocalContext.current
    val colors = BridgeyTheme.colors
    val clock = LocalNow.current
    var now by remember { mutableLongStateOf(clock()) }
    if (folder.deadlineMillis != null) {
        LaunchedEffect(folder.deadlineMillis) {
            while (true) {
                now = clock()
                delay(1_000)
            }
        }
    }
    var expanded by rememberSaveable(transfer.id) { mutableStateOf(startExpanded) }
    val canExpand = folder.waiting == null && (folder.currentFile != null || folder.recent.isNotEmpty() || folder.failures.isNotEmpty())
    val toggleLabel = stringResource(if (expanded) R.string.live_folder_hide_files else R.string.live_folder_show_files)
    Column(
        Modifier.fillMaxWidth().then(
            if (canExpand) Modifier.clickable(onClickLabel = toggleLabel, role = Role.Button) { expanded = !expanded } else Modifier,
        ),
    ) {
        Text(FolderText.cardTitle(context, folder), style = BridgeyType.itemTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(
            FolderText.statusLine(context, folder, now),
            style = BridgeyType.itemBody,
            color = colors.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
        if (transfer.active) {
            val progress = FolderText.progress(folder)
            Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (progress != null) {
                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier.weight(1f).height(6.dp),
                        color = colors.primary,
                        trackColor = colors.surface3,
                        strokeCap = StrokeCap.Round,
                        drawStopIndicator = {},
                    )
                    Text("${(progress * 100).toInt()}%", style = BridgeyType.smallStrong)
                } else if (folder.waiting == FolderWaiting.MANIFEST) {
                    LinearProgressIndicator(
                        modifier = Modifier.weight(1f).height(6.dp),
                        color = colors.primary,
                        trackColor = colors.surface3,
                        strokeCap = StrokeCap.Round,
                    )
                }
            }
        }
        if (expanded && canExpand) FolderFiles(folder)
        if (canExpand) {
            Text(
                toggleLabel,
                style = BridgeyType.smallStrong,
                color = colors.primary,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
    CardActions {
        when {
            // A folder this phone sends waits for the other device's answer: nothing to choose here.
            transfer.active && !folder.outgoing && (folder.waiting == FolderWaiting.DESTINATION || folder.waiting == FolderWaiting.CONFLICT_HERE) -> {
                TonalPillButton(stringResource(R.string.action_cancel), { actions.cancelTransfer(transfer.id) }, tint = Tint.NEUTRAL)
                TonalPillButton(
                    stringResource(if (folder.waiting == FolderWaiting.DESTINATION) R.string.action_choose else R.string.action_answer),
                    { actions.answerFolder(transfer.id) },
                )
            }
            transfer.active -> {
                if (cancelAll) TonalPillButton(stringResource(R.string.transfers_cancel_all), actions.cancelAllTransfers, tint = Tint.NEUTRAL)
                TonalPillButton(stringResource(R.string.action_cancel), { actions.cancelTransfer(transfer.id) }, tint = Tint.NEUTRAL)
            }
            folder.end == FolderEnd.INTERRUPTED -> TonalPillButton(stringResource(R.string.action_dismiss), actions.dismissTransfers, tint = Tint.NEUTRAL)
            else -> TonalPillButton(stringResource(R.string.action_dismiss), actions.dismissTransfers, tint = Tint.NEUTRAL)
        }
    }
}

/** The open card: current file, failures, the last saved names (capped; never every row of a big folder). */
@Composable
private fun FolderFiles(folder: dev.bridgey.android.folders.FolderSnapshot) {
    val context = LocalContext.current
    val colors = BridgeyTheme.colors
    Column(Modifier.fillMaxWidth().padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        folder.currentFile?.let { name ->
            Text(stringResource(R.string.live_folder_now, name), style = BridgeyType.small, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val part = if (folder.currentFileSize > 0) (folder.currentFileBytes.toFloat() / folder.currentFileSize).coerceIn(0f, 1f) else 0f
            LinearProgressIndicator(
                progress = { part },
                modifier = Modifier.fillMaxWidth().height(4.dp),
                color = colors.primary,
                trackColor = colors.surface3,
                strokeCap = StrokeCap.Round,
                drawStopIndicator = {},
            )
        }
        if (folder.failures.isNotEmpty()) {
            Text(stringResource(R.string.live_folder_failed_heading), style = BridgeyType.smallStrong, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp))
            folder.failures.takeLast(SHOWN_FAILURES).reversed().forEach { failure ->
                Text(
                    "${failure.name} · ${FolderText.failureReason(context, failure.code)}",
                    style = BridgeyType.small,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (folder.recent.isNotEmpty()) {
            Text(stringResource(R.string.live_folder_saved_heading), style = BridgeyType.smallStrong, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp))
            folder.recent.takeLast(SHOWN_SAVED).reversed().forEach { name ->
                Text(name, style = BridgeyType.small, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            val earlier = folder.filesDone - minOf(SHOWN_SAVED, folder.recent.size)
            if (earlier > 0) Text(stringResource(R.string.live_folder_more_saved, earlier), style = BridgeyType.small, color = colors.onSurfaceVariant)
        }
    }
}
