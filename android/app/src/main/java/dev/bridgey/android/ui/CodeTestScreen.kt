package dev.bridgey.android.ui

import android.app.Activity
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.codes.CodeTestReport
import dev.bridgey.android.codes.CodeTestSession
import dev.bridgey.android.codes.CodeTestState
import dev.bridgey.android.codes.Extractor
import dev.bridgey.android.codes.Label
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

class CodeTestActions(
    val back: () -> Unit = {},
    val start: (limit: Int, useCloud: Boolean) -> Unit = { _, _ -> },
    val stop: () -> Unit = {},
    val label: (Label) -> Unit = {},
    val finishReview: () -> Unit = {},
    val export: (CodeTestReport) -> Unit = {},
    val delete: () -> Unit = {},
    val restart: () -> Unit = {},
    val openAppSettings: () -> Unit = {},
)

private val LIMITS = listOf(500, CodeTestSession.DEFAULT_LIMIT, 5_000)

/**
 * Settings, About, version tapped 7 times, then Code reader test (lab builds): the Phase 0 check of
 * how well codes are found in the phone's own messages. Only totals leave this screen.
 */
@Composable
fun CodeTestScreen(
    state: CodeTestState,
    cloudAvailable: Boolean,
    smsDenied: Boolean,
    smsGranted: Boolean,
    actions: CodeTestActions,
) {
    val colors = BridgeyTheme.colors
    var limit by rememberSaveable { mutableIntStateOf(CodeTestSession.DEFAULT_LIMIT) }
    var useCloud by rememberSaveable { mutableStateOf(false) }
    // Message text is on screen while reviewing: no screenshots, blank in recent apps.
    if (state is CodeTestState.Review) SecureWindow()
    SettingsPage(stringResource(R.string.codetest_title), actions.back) {
        when (state) {
            CodeTestState.Idle, is CodeTestState.Failed -> {
                item(key = "intro") {
                    Column(Modifier.padding(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(stringResource(R.string.codetest_intro), style = BridgeyType.bodyText, color = colors.onSurface)
                        val failure = (state as? CodeTestState.Failed)?.reason
                        when {
                            smsDenied || failure == CodeTestState.Reason.NO_PERMISSION -> {
                                Text(stringResource(R.string.codetest_denied), style = BridgeyType.small, color = colors.warn)
                                OutlinePillButton(stringResource(R.string.codetest_open_settings), null, actions.openAppSettings)
                            }
                            failure == CodeTestState.Reason.READ_FAILED ->
                                Text(stringResource(R.string.codetest_failed_read), style = BridgeyType.small, color = colors.warn)
                            failure == CodeTestState.Reason.EMPTY ->
                                Text(stringResource(R.string.codetest_failed_empty), style = BridgeyType.small, color = colors.warn)
                        }
                    }
                }
                item(key = "options") {
                    RowGroup {
                        row { shape -> LimitRow(shape, limit) { limit = it } }
                        row { shape ->
                            SwitchRow(
                                shape, stringResource(R.string.codetest_cloud),
                                if (cloudAvailable) stringResource(R.string.codetest_cloud_detail, CodeTestSession.CLOUD_LIMIT)
                                else stringResource(R.string.codetest_cloud_unavailable),
                                BridgeyIcons.Send, if (useCloud) Tint.PURPLE else Tint.NEUTRAL,
                                useCloud && cloudAvailable, { useCloud = it }, enabled = cloudAvailable,
                            )
                        }
                    }
                }
                item(key = "start") {
                    Row(Modifier.fillMaxWidth().padding(16.dp)) {
                        GradientButton(stringResource(R.string.codetest_start), null, { actions.start(limit, useCloud && cloudAvailable) }, Modifier.weight(1f), height = 48.dp)
                    }
                }
                if (smsGranted) item(key = "revoke") { RevokeCard(actions) }
            }
            is CodeTestState.Reading, is CodeTestState.Cloud -> item(key = "progress") {
                Column(Modifier.padding(horizontal = 20.dp, vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val text = if (state is CodeTestState.Cloud) {
                        stringResource(R.string.codetest_cloud_progress, state.done, state.total, (state.secondsLeft + 59) / 60)
                    } else {
                        stringResource(R.string.codetest_reading, (state as CodeTestState.Reading).read)
                    }
                    Text(text, style = BridgeyType.label, color = colors.onSurface)
                    if (state is CodeTestState.Cloud && state.total > 0) {
                        LinearProgressIndicator(
                            progress = { state.done.toFloat() / state.total },
                            modifier = Modifier.fillMaxWidth().heightIn(min = 6.dp),
                            color = colors.primary, trackColor = colors.surface3, strokeCap = StrokeCap.Round, drawStopIndicator = {},
                        )
                    } else {
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth().heightIn(min = 6.dp), color = colors.primary, trackColor = colors.surface3, strokeCap = StrokeCap.Round)
                    }
                    OutlinePillButton(stringResource(R.string.codetest_stop), null, actions.stop)
                }
            }
            is CodeTestState.Review -> item(key = "review:${state.messageId}") { ReviewCard(state, actions) }
            is CodeTestState.Report -> {
                item(key = "report") { ReportCard(state.report, actions) }
                if (smsGranted) item(key = "revoke") { RevokeCard(actions) }
            }
        }
    }
}

@Composable
private fun SecureWindow() {
    val view = LocalView.current
    DisposableEffect(view) {
        val window = (view.context as? Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose { window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
    }
}

@Composable
private fun LimitRow(shape: androidx.compose.ui.graphics.Shape, limit: Int, onChange: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val colors = BridgeyTheme.colors
    Box {
        ListRow(
            shape, stringResource(R.string.codetest_count), stringResource(R.string.codetest_count_value, limit),
            BridgeyIcons.Description, Tint.BLUE, onClick = { open = true }, role = Role.DropdownList,
        ) { Icon(BridgeyIcons.ArrowDropDown, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(24.dp)) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = colors.surface2, shape = RoundedCornerShape(20.dp)) {
            LIMITS.forEach { choice ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.codetest_count_value, choice), style = BridgeyType.label, color = colors.onSurface) },
                    trailingIcon = if (choice == limit) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                    onClick = { open = false; onChange(choice) },
                    modifier = Modifier.heightIn(min = 48.dp),
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ReviewCard(state: CodeTestState.Review, actions: CodeTestActions) {
    val colors = BridgeyTheme.colors
    var typing by rememberSaveable(state.messageId) { mutableStateOf(false) }
    var typed by rememberSaveable(state.messageId) { mutableStateOf("") }
    Column(Modifier.padding(horizontal = 16.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.codetest_review_title, state.position, state.count), style = BridgeyType.itemTitle, color = colors.onSurface)
        Text(stringResource(R.string.codetest_review_hint), style = BridgeyType.small, color = colors.onSurfaceVariant)
        Text(
            state.body,
            style = BridgeyType.bodyText,
            color = colors.onSurface,
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(16.dp),
        )
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            state.candidates.forEach { code -> TonalPillButton(code, { actions.label(Label.Code(code)) }) }
            TonalPillButton(stringResource(R.string.codetest_no_code), { actions.label(Label.NoCode) }, tint = Tint.NEUTRAL)
            OutlinePillButton(stringResource(R.string.codetest_other), null, { typing = true })
            OutlinePillButton(stringResource(R.string.codetest_skip), null, { actions.label(Label.Skipped) })
        }
        if (typing) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = typed, onValueChange = { typed = it.take(24) }, singleLine = true,
                    placeholder = { Text(stringResource(R.string.codetest_other_hint)) }, modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = {
                        val code = dev.bridgey.android.codes.CodeGuard.accept(typed, state.body) ?: typed.filter { it.isLetterOrDigit() }
                        if (code.isNotEmpty()) actions.label(Label.Code(code))
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) { Text(stringResource(R.string.codetest_save)) }
            }
        }
        TextButton(onClick = actions.finishReview, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.codetest_finish), style = BridgeyType.smallStrong, color = colors.primary)
        }
    }
}

@Composable
private fun ReportCard(report: CodeTestReport, actions: CodeTestActions) {
    val colors = BridgeyTheme.colors
    Column(Modifier.padding(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.codetest_report_title), style = BridgeyType.itemTitle, color = colors.onSurface)
        Text(stringResource(R.string.codetest_report_messages, report.messagesRead, report.codeLike, report.reviewed), style = BridgeyType.itemBody, color = colors.onSurface)
        Text(codeAccessText(report.platform.codeAccess), style = BridgeyType.itemBody, color = colors.onSurface)
        Text(
            stringResource(R.string.codetest_report_platform, report.platform.smsNotificationsHidden, report.platform.smsNotificationsSeen),
            style = BridgeyType.itemBody, color = colors.onSurface,
        )
        report.scores.toSortedMap().forEach { (extractor, score) ->
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    stringResource(if (extractor == Extractor.CLOUD) R.string.codetest_extractor_cloud else R.string.codetest_extractor_pattern),
                    style = BridgeyType.label, color = colors.onSurface,
                )
                Text(
                    stringResource(R.string.codetest_report_line, score.codesRight, score.wrongCodes, score.misses, score.falseAlarms, score.failures),
                    style = BridgeyType.itemBody, color = colors.onSurfaceVariant,
                )
                val (median, p95) = report.latency[extractor] ?: (0L to 0L)
                Text(
                    stringResource(R.string.codetest_report_latency, median.toInt(), p95.toInt(), report.ran[extractor] ?: 0),
                    style = BridgeyType.small, color = colors.onSurfaceVariant,
                )
            }
        }
        Text(
            stringResource(R.string.codetest_report_audit, report.auditCodeWrong, report.auditCodeChecked, report.auditNoneWrong, report.auditNoneChecked),
            style = BridgeyType.small, color = colors.onSurfaceVariant,
        )
        Text(stringResource(R.string.codetest_report_note), style = BridgeyType.small, color = colors.onSurfaceVariant)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinePillButton(stringResource(R.string.codetest_export), BridgeyIcons.IosShare, { actions.export(report) })
            OutlinePillButton(stringResource(R.string.codetest_delete), BridgeyIcons.Delete, actions.delete)
        }
    }
}

@Composable
private fun RevokeCard(actions: CodeTestActions) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.surface1).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(stringResource(R.string.codetest_revoke_title), style = BridgeyType.itemTitle, color = colors.onSurface)
        Text(stringResource(R.string.codetest_revoke_body), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        OutlinePillButton(stringResource(R.string.codetest_restart), BridgeyIcons.Refresh, actions.restart)
    }
}

/** The Performance test screen's link to the Code reader test (lab builds only). */
@Composable
fun CodeTestEntry(open: () -> Unit) {
    RowGroup(Modifier.padding(top = 8.dp)) {
        row { shape ->
            ListRow(
                shape, stringResource(R.string.codetest_title), stringResource(R.string.codetest_open_detail),
                BridgeyIcons.Notifications, Tint.PURPLE, onClick = open,
            ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
        }
    }
}
