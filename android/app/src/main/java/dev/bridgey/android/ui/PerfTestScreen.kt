package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.bench.BenchMode
import dev.bridgey.android.bench.BenchReport
import dev.bridgey.android.bench.BenchUiState
import dev.bridgey.android.bench.FULL_BYTES
import dev.bridgey.android.bench.ModeResult
import dev.bridgey.android.bench.QUICK_BYTES
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

class PerfTestActions(
    val back: () -> Unit = {},
    val run: (Long) -> Unit = {},
    val cancel: () -> Unit = {},
    val copy: (BenchReport) -> Unit = {},
    val share: (BenchReport) -> Unit = {},
    /** Lab builds only: the Code reader test lives next to this one. */
    val openCodeTest: (() -> Unit)? = null,
)

@Composable
fun modeName(mode: BenchMode): String = stringResource(
    when (mode) {
        BenchMode.WRITE_ONLY -> R.string.perf_mode_write_only
        BenchMode.BLAKE3_BLOCK -> R.string.perf_mode_blake3_block
        BenchMode.BLAKE3_BLOCK_READBACK -> R.string.perf_mode_blake3_readback
        BenchMode.BLAKE3_WHOLE_END -> R.string.perf_mode_blake3_whole
        BenchMode.SHA256_BLOCK -> R.string.perf_mode_sha256_block
    },
)

/** Settings, About, version tapped 7 times: the integrity cost test. */
@Composable
fun PerfTestScreen(state: BenchUiState, pluggedIn: Boolean?, actions: PerfTestActions, listState: LazyListState = rememberLazyListState()) {
    val colors = BridgeyTheme.colors
    val running = state is BenchUiState.Running
    SettingsPage(stringResource(R.string.perf_title), actions.back, listState) {
        item(key = "intro") {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.perf_intro), style = BridgeyType.bodyText, color = colors.onSurface)
                Text(
                    stringResource(if (pluggedIn == true) R.string.perf_plugged_warning else R.string.perf_unplug_hint),
                    style = BridgeyType.small,
                    color = if (pluggedIn == true) colors.warn else colors.onSurfaceVariant,
                )
            }
        }
        item(key = "buttons") {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                GradientButton(stringResource(R.string.perf_run_quick), null, { actions.run(QUICK_BYTES) }, Modifier.weight(1f), enabled = !running, height = 48.dp)
                GradientButton(stringResource(R.string.perf_run_full), null, { actions.run(FULL_BYTES) }, Modifier.weight(1f), enabled = !running, height = 48.dp)
            }
        }
        when (state) {
            is BenchUiState.Running -> item(key = "progress") {
                Column(Modifier.padding(horizontal = 20.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        stringResource(R.string.perf_running, state.modeIndex + 1, state.modeCount, modeName(state.mode)),
                        style = BridgeyType.label, color = colors.onSurface,
                    )
                    LinearProgressIndicator(
                        progress = { ((state.modeIndex + state.fraction) / state.modeCount).coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth().height(6.dp),
                        color = colors.primary, trackColor = colors.surface3, strokeCap = StrokeCap.Round, drawStopIndicator = {},
                    )
                    OutlinePillButton(stringResource(R.string.perf_cancel), null, actions.cancel)
                }
            }
            is BenchUiState.Failed -> item(key = "failed") {
                Text(
                    stringResource(
                        when (state.reason) {
                            BenchUiState.Reason.NO_SPACE -> R.string.perf_fail_space
                            BenchUiState.Reason.NO_NATIVE -> R.string.perf_fail_native
                            BenchUiState.Reason.VECTORS -> R.string.perf_fail_vectors
                            BenchUiState.Reason.IO -> R.string.perf_fail_io
                            BenchUiState.Reason.CANCELLED -> R.string.perf_cancelled
                        },
                    ) + if (state.reason == BenchUiState.Reason.IO && state.detail.isNotBlank()) " ${state.detail}" else "",
                    style = BridgeyType.bodyText, color = colors.warn, modifier = Modifier.padding(20.dp),
                )
            }
            is BenchUiState.Done -> {
                val report = state.report
                item(key = "summary") {
                    Text(
                        stringResource(R.string.perf_summary, report.sizeBytes / (1024 * 1024), report.hashImplementation),
                        style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.padding(20.dp, 20.dp, 20.dp, 8.dp),
                    )
                }
                items(report.results, key = { it.mode.id }) { r -> ResultCard(r, report) }
                item(key = "readback") {
                    Text(report.readBackNote, style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.padding(20.dp, 12.dp))
                }
                item(key = "export") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinePillButton(stringResource(R.string.perf_copy), null, { actions.copy(report) })
                        OutlinePillButton(stringResource(R.string.perf_share), BridgeyIcons.IosShare, { actions.share(report) })
                    }
                }
            }
            BenchUiState.Idle -> {}
        }
        actions.openCodeTest?.let { open -> item(key = "codetest") { CodeTestEntry(open) } }
    }
}

private fun <T> androidx.compose.foundation.lazy.LazyListScope.items(list: List<T>, key: (T) -> Any, content: @Composable (T) -> Unit) {
    items(list.size, key = { key(list[it]) }) { content(list[it]) }
}

@Composable
private fun ResultCard(r: ModeResult, report: BenchReport) {
    val colors = BridgeyTheme.colors
    val extra = report.extrapolations.firstOrNull { it.mode == r.mode }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)
            .background(colors.surface2, RoundedCornerShape(16.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(modeName(r.mode), style = BridgeyType.itemTitle, color = colors.onSurface)
        Text(
            stringResource(R.string.perf_line_time, r.wallSeconds, r.mbPerSecond, r.cpuSeconds),
            style = BridgeyType.itemBody, color = colors.onSurface,
        )
        r.energyMah?.let {
            Text(stringResource(R.string.perf_line_energy, it), style = BridgeyType.itemBody, color = colors.onSurface)
        }
        if (r.verifyMismatches > 0) {
            Text(stringResource(R.string.perf_line_mismatch, r.verifyMismatches), style = BridgeyType.itemBody, color = colors.warn)
        }
        if (extra != null) {
            Text(stringResource(R.string.perf_line_extra, extra.extraWallSeconds, extra.extraCpuSeconds), style = BridgeyType.small, color = colors.onSurfaceVariant)
            if (extra.extraMah != null && extra.extraPercentOfBattery != null) {
                Text(stringResource(R.string.perf_line_extra_energy, extra.extraMah, extra.extraPercentOfBattery), style = BridgeyType.small, color = colors.onSurfaceVariant)
            }
        }
    }
}
