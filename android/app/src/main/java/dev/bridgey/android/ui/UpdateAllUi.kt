package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateFeeds
import android.text.format.DateUtils
import androidx.compose.ui.platform.LocalContext
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.updates.AUTO_CHECK_STABLE_MILLIS
import dev.bridgey.android.updates.AUTO_FAILED_NOT_APPLIED
import dev.bridgey.android.updates.AutoCondition
import dev.bridgey.android.updates.AutoRunRecord
import dev.bridgey.android.updates.AutoUpdateView
import dev.bridgey.android.updates.DeviceUpdateRow
import dev.bridgey.android.updates.UpdateBusy
import dev.bridgey.android.updates.PlanTarget
import dev.bridgey.android.updates.RunFailure
import dev.bridgey.android.updates.RunItem
import dev.bridgey.android.updates.RunStep
import dev.bridgey.android.updates.RunSummary
import dev.bridgey.android.updates.UpdatePlan
import dev.bridgey.android.updates.UpdatePlatform
import dev.bridgey.android.updates.UpdateReason
import dev.bridgey.android.updates.UpdateRun
import dev.bridgey.android.updates.UpdateSkipReason
import dev.bridgey.android.updates.UpdateState
import dev.bridgey.android.updates.UpdateStatus
import dev.bridgey.android.updates.WireChannel
import dev.bridgey.android.updates.isSlow
import dev.bridgey.android.updates.summarizeRun
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Update all as the screens draw it: the plan (what one tap would do), the run if one is going, and every device. */
data class UpdateAllUiState(
    val plan: UpdatePlan? = null,
    val run: UpdateRun? = null,
    val now: Long = 0L,
    val devices: List<DeviceUpdateRow> = emptyList(),
    /** "Let paired devices start updates on this phone". */
    val remoteStart: Boolean = true,
    /** Update all devices automatically: the switch, how often it checks, what it waits for, the last run. */
    val auto: AutoUpdateView = AutoUpdateView(),
) {
    /** The card shows on Home and the button in Settings: something to update, or a run to follow. */
    val offered: Boolean get() = run != null || plan?.visible == true
}

class UpdateAllActions(
    /** Opens the preview (or, during a run, the per-device progress). */
    val open: () -> Unit = {},
    val start: () -> Unit = {},
    val retry: (String) -> Unit = {},
    val later: () -> Unit = {},
    /** Closes a finished run's summary. */
    val dismiss: () -> Unit = {},
    val close: () -> Unit = {},
    val setRemoteStart: (Boolean) -> Unit = {},
    /** Update all devices automatically: the person's own choice from now on. */
    val setAuto: (Boolean) -> Unit = {},
)

// MARK: Words

private fun WireChannel.local(): UpdateChannel = UpdateChannel.fromKey(wire)

@Composable
private fun channelName(channel: WireChannel): String = channelTitle(channel.local())

/** "Updates this phone and 3 connected Macs", "Updates 2 connected Macs", "Updates this phone". */
@Composable
fun updateAllSummary(plan: UpdatePlan): String {
    val macs = plan.peerTargets.size
    return when {
        plan.includesLocal && macs > 0 -> pluralStringResource(R.plurals.update_all_summary_phone_and_macs, macs, macs)
        macs > 0 -> pluralStringResource(R.plurals.update_all_summary_macs, macs, macs)
        else -> stringResource(R.string.update_all_summary_phone)
    }
}

/** What it will update, in order (the phone's version of hovering the button): "MacBook Pro, Work Mac, then this phone". */
@Composable
fun updateAllOrder(plan: UpdatePlan): String {
    val names = plan.peerTargets.joinToString(", ") { it.name }
    return when {
        names.isEmpty() -> stringResource(R.string.update_all_summary_phone)
        plan.includesLocal -> stringResource(R.string.update_all_order, names)
        else -> names
    }
}

/** What the person is doing, in the words "Waiting: …" uses: "call in progress", "screen sharing", … */
@Composable
fun busyText(busy: UpdateBusy): String = stringResource(
    when (busy) {
        UpdateBusy.CALL -> R.string.update_busy_call
        UpdateBusy.SCREEN_SHARE -> R.string.update_busy_screen_share
        UpdateBusy.REMOTE_CONTROL -> R.string.update_busy_remote_control
        UpdateBusy.TRANSFER -> R.string.update_busy_transfer
        UpdateBusy.PHONE_FILES -> R.string.update_busy_phone_files
        UpdateBusy.SETUP -> R.string.update_busy_setup
        UpdateBusy.OTHER -> R.string.update_busy_other
    },
)

/** "Waiting: call in progress", or "Waiting: call in progress on Work Mac" when [device] is another device. */
@Composable
fun waitingText(busy: UpdateBusy, device: String?): String =
    if (device == null) stringResource(R.string.update_auto_waiting, busyText(busy)) else stringResource(R.string.update_auto_waiting_on, busyText(busy), device)

@Composable
fun runSummaryText(summary: RunSummary): String = when (summary) {
    is RunSummary.Held -> waitingText(summary.busy, null)
    is RunSummary.Countdown -> stringResource(R.string.update_all_capsule_countdown, summary.seconds)
    RunSummary.Restarting -> stringResource(R.string.update_all_capsule_restarting)
    is RunSummary.Slow -> stringResource(R.string.update_all_capsule_slow, summary.name, summary.minutes.toInt())
    is RunSummary.WaitingFor -> if (summary.here) stringResource(R.string.update_all_capsule_waiting_here) else stringResource(R.string.update_all_capsule_waiting_for, summary.name)
    is RunSummary.Progress -> stringResource(R.string.update_all_capsule_progress, summary.done, summary.total)
    is RunSummary.Failed -> summary.name?.let {
        stringResource(if (summary.notApplied) R.string.update_all_capsule_not_applied_one else R.string.update_all_capsule_failed_one, it)
    }
        ?: pluralStringResource(R.plurals.update_all_capsule_failed_many, summary.count, summary.count)
    RunSummary.ReadyLater -> stringResource(R.string.update_all_capsule_ready_later)
    is RunSummary.AllUpdated -> stringResource(R.string.update_all_capsule_done)
}

@Composable
private fun skipText(reason: UpdateSkipReason): String = stringResource(
    when (reason) {
        UpdateSkipReason.OFFLINE -> R.string.update_all_skip_offline
        UpdateSkipReason.BY_HAND -> R.string.update_all_skip_by_hand
        UpdateSkipReason.NO_STATUS -> R.string.update_all_skip_no_status
        UpdateSkipReason.NOT_APPLIED -> R.string.update_all_skip_not_applied
        UpdateSkipReason.REMOTE_OFF -> R.string.update_all_skip_remote_off
    },
)

@Composable
internal fun failureText(failure: RunFailure?): String = stringResource(
    when (failure) {
        RunFailure.DISABLED -> R.string.update_all_failure_disabled
        RunFailure.RATE_LIMITED -> R.string.update_all_failure_rate_limited
        RunFailure.MANUAL -> R.string.update_all_failure_manual
        RunFailure.BUSY -> R.string.update_all_failure_busy
        RunFailure.CHECK -> R.string.update_all_failure_check
        RunFailure.DOWNLOAD -> R.string.update_all_failure_download
        RunFailure.SAFETY -> R.string.update_all_failure_safety
        RunFailure.INSTALLER -> R.string.update_all_failure_installer
        RunFailure.CANCELLED -> R.string.update_all_failure_cancelled
        RunFailure.NO_ANSWER -> R.string.update_all_failure_no_answer
        RunFailure.LOST_CONNECTION -> R.string.update_all_failure_lost_connection
        RunFailure.NO_RETURN -> R.string.update_all_failure_no_return
        RunFailure.INTERRUPTED -> R.string.update_all_failure_interrupted
        RunFailure.OTHER, null -> R.string.update_all_failure_other
    },
)

/** One device's line in a run. */
@Composable
fun runRowText(item: RunItem, later: Boolean): String = when (item.step) {
    RunStep.WAITING -> stringResource(R.string.update_all_row_waiting)
    RunStep.STARTING -> stringResource(R.string.update_all_row_starting)
    RunStep.CHECKING -> stringResource(R.string.update_all_row_checking)
    RunStep.DOWNLOADING -> item.progress?.let { stringResource(R.string.update_all_row_downloading_percent, it) }
        ?: stringResource(R.string.update_all_row_downloading)
    RunStep.READY -> stringResource(if (later) R.string.update_all_row_ready_later else R.string.update_all_row_ready)
    RunStep.INSTALLING -> stringResource(R.string.update_all_row_installing)
    RunStep.RESTARTING -> stringResource(R.string.update_all_row_restarting)
    RunStep.NEEDS_USER -> stringResource(
        if (item.needsReason == UpdateReason.PERMISSION) R.string.update_all_row_needs_permission else R.string.update_all_row_needs_you,
    )
    RunStep.DONE -> stringResource(R.string.update_all_row_done, item.newApp ?: item.targetApp.orEmpty())
    RunStep.UP_TO_DATE -> stringResource(R.string.update_all_row_up_to_date)
    RunStep.FAILED -> stringResource(R.string.update_all_row_failed, failureText(item.failure))
    RunStep.NOT_APPLIED -> stringResource(R.string.update_all_row_not_applied)
}

/** "0.9.0-rr.3-beta.2 → beta.3", or "→ newest Beta, if newer" when the device checks its own feed. */
@Composable
private fun fromToText(fromApp: String, to: String?, channel: WireChannel): String =
    if (to != null) {
        stringResource(R.string.update_all_from_to, fromApp, UpdateFeeds.shortVersion(to, fromApp))
    } else {
        stringResource(R.string.update_all_newest, fromApp, channelName(channel))
    }

/** A device's state on Settings > Updates > Your devices. */
@Composable
private fun deviceStateText(row: DeviceUpdateRow): String {
    row.skip?.let { return skipText(it) }
    val status = row.status ?: return skipText(UpdateSkipReason.NO_STATUS)
    val short = status.target?.let { UpdateFeeds.shortVersion(it, status.app) }.orEmpty()
    return when (status.state) {
        UpdateState.CURRENT -> stringResource(R.string.update_all_state_current)
        UpdateState.CHECKING -> stringResource(R.string.update_all_state_checking)
        UpdateState.AVAILABLE -> stringResource(R.string.update_all_state_available, short)
        UpdateState.DOWNLOADING -> stringResource(R.string.update_all_state_downloading)
        UpdateState.READY -> stringResource(R.string.update_all_state_ready, short)
        UpdateState.INSTALLING -> stringResource(R.string.update_all_state_installing)
        UpdateState.NEEDS_USER -> stringResource(R.string.update_all_state_needs_user)
        UpdateState.FAILED -> stringResource(
            if (status.reason == UpdateReason.NOT_APPLIED) R.string.update_all_state_not_applied else R.string.update_all_state_failed,
        )
        UpdateState.MANUAL -> stringResource(R.string.update_all_state_manual)
    }
}

private fun platformIcon(platform: UpdatePlatform?): ImageVector =
    if (platform == UpdatePlatform.ANDROID) BridgeyIcons.Smartphone else BridgeyIcons.LaptopMac

// MARK: Home card

/** The Home live card's content: what Update all would do, or how the run is going. */
@Composable
fun UpdateAllCardContent(state: UpdateAllUiState, actions: UpdateAllActions) {
    val run = state.run
    val plan = state.plan
    if (run != null) {
        val summary = summarizeRun(run, state.now)
        val names = run.items.joinToString(" · ") { it.name }
        CardText(runSummaryText(summary), if (run.auto) pluralStringResource(R.plurals.update_auto_card_detail, run.items.size, run.items.size) else names)
        RunProgress(run, Modifier.padding(top = 10.dp))
        CardActions {
            when {
                summary is RunSummary.Countdown || summary is RunSummary.Held -> TonalPillButton(stringResource(R.string.updates_later), actions.later, tint = Tint.NEUTRAL)
                run.finished -> TonalPillButton(stringResource(R.string.action_dismiss), actions.dismiss, tint = Tint.NEUTRAL)
                else -> Unit
            }
            run.items.singleOrNull { it.retryable }?.let { failed ->
                TonalPillButton(stringResource(R.string.action_retry), { actions.retry(failed.deviceId) })
            }
            TonalPillButton(stringResource(R.string.update_all_devices_title), actions.open, tint = Tint.PURPLE)
        }
    } else if (plan != null) {
        CardText(pluralStringResource(R.plurals.update_all_card_title, plan.targets.size, plan.targets.size), updateAllSummary(plan))
        Text(
            updateAllOrder(plan),
            style = BridgeyType.small,
            color = BridgeyTheme.colors.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
        CardActions { TonalPillButton(stringResource(R.string.update_all_action), actions.open, tint = Tint.PURPLE) }
    }
}

/** Done out of all, as a thin bar; static, so reduced motion has nothing to still. */
@Composable
private fun RunProgress(run: UpdateRun, modifier: Modifier = Modifier) {
    val done = run.items.count { it.step == RunStep.DONE || it.step == RunStep.UP_TO_DATE }
    LinearProgressIndicator(
        progress = { if (run.items.isEmpty()) 0f else done.toFloat() / run.items.size },
        modifier = modifier.fillMaxWidth().height(6.dp),
        color = BridgeyTheme.colors.primary,
        trackColor = BridgeyTheme.colors.surface3,
        strokeCap = StrokeCap.Round,
        drawStopIndicator = {},
    )
}

// MARK: The sheet

/** The preview (and, during a run, each device's progress) as a bottom sheet while Bridgey is open. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UpdateAllSheetHost(visible: Boolean, state: UpdateAllUiState, actions: UpdateAllActions) {
    if (!visible) return
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = actions.close, sheetState = sheet, containerColor = BridgeyTheme.colors.surface2) {
        UpdateAllSheet(state, actions)
    }
}

/**
 * Before: every device with its version change and channel, this phone last; what is skipped and
 * why; a note when the channels differ; Cancel and Update all. During: each device's step, slow
 * ones marked, Retry on a failed one, Later during this phone's countdown.
 */
@Composable
fun UpdateAllSheet(state: UpdateAllUiState, actions: UpdateAllActions, modifier: Modifier = Modifier) {
    val run = state.run
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        if (run != null) RunContent(run, state.now, actions) else state.plan?.let { PreviewContent(it, actions) }
    }
}

@Composable
private fun SheetTitle(title: String, subtitle: String?) {
    Row(Modifier.padding(horizontal = 24.dp).padding(top = 4.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        IconTile(BridgeyIcons.Update, Tint.PURPLE)
        Column(Modifier.weight(1f)) {
            Text(title, style = BridgeyType.cardTitle, color = BridgeyTheme.colors.onSurface, modifier = Modifier.semantics { heading() })
            if (subtitle != null) Text(subtitle, style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant)
        }
    }
}

@Composable
private fun PreviewContent(plan: UpdatePlan, actions: UpdateAllActions) {
    val colors = BridgeyTheme.colors
    SheetTitle(stringResource(R.string.update_all_preview_title), updateAllSummary(plan))
    DeviceList(plan.targets.size) { index, shape ->
        val target = plan.targets[index]
        DeviceRowFrame(shape, platformIcon(target.platform), target.name, trailing = { StatusPill(channelName(target.channel), null, Tint.NEUTRAL) }) {
            Text(fromToText(target.fromApp, target.to, target.channel), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (target.isLocal) Text(stringResource(R.string.update_all_restarts_last), style = BridgeyType.small, color = colors.onSurfaceVariant)
        }
    }
    if (plan.channelsDiffer) {
        val parts = plan.targets.map { target -> channelOnText(target) }
        val list = parts.joinToString(", ")
        Note(stringResource(R.string.update_all_channels_differ, list), Modifier.padding(start = 24.dp, end = 24.dp, top = 10.dp))
    }
    if (plan.skipped.isNotEmpty()) {
        SectionLabel(stringResource(R.string.update_all_skipped), Modifier.padding(start = 24.dp, top = 18.dp, bottom = 8.dp))
        DeviceList(plan.skipped.size) { index, shape ->
            val skip = plan.skipped[index]
            DeviceRowFrame(shape, BridgeyIcons.LaptopMac, skip.name, muted = true) {
                Text(skipText(skip.reason), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
        }
    }
    if (plan.upToDate.isNotEmpty()) {
        Text(
            stringResource(R.string.update_all_up_to_date, plan.upToDate.joinToString(", ")),
            style = BridgeyType.small,
            color = colors.onSurfaceVariant,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp),
        )
    }
    Note(stringResource(R.string.update_all_preview_note), Modifier.padding(start = 24.dp, end = 24.dp, top = 12.dp))
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinePillButton(stringResource(R.string.action_cancel), null, actions.close)
        GradientButton(stringResource(R.string.update_all_action), BridgeyIcons.Update, actions.start, enabled = plan.targets.isNotEmpty(), height = 40.dp, textStyle = BridgeyType.label)
    }
}

@Composable
private fun channelOnText(target: PlanTarget): String = stringResource(R.string.update_all_channel_on, target.name, channelName(target.channel))

@Composable
private fun RunContent(run: UpdateRun, now: Long, actions: UpdateAllActions) {
    val colors = BridgeyTheme.colors
    val summary = summarizeRun(run, now)
    SheetTitle(runSummaryText(summary), null)
    RunProgress(run, Modifier.padding(start = 24.dp, end = 24.dp, bottom = 12.dp))
    DeviceList(run.items.size) { index, shape ->
        val item = run.items[index]
        val slow = item.isSlow(now)
        val problem = item.step == RunStep.FAILED || item.step == RunStep.NOT_APPLIED
        DeviceRowFrame(
            shape, platformIcon(item.platform), item.name,
            trailing = {
                when {
                    item.retryable -> TonalPillButton(stringResource(R.string.action_retry), { actions.retry(item.deviceId) })
                    item.step == RunStep.DONE -> Icon(BridgeyIcons.CheckCircle, null, tint = colors.onTintGreen, modifier = Modifier.size(22.dp))
                    else -> Unit
                }
            },
        ) {
            Text(
                runRowText(item, run.later),
                style = BridgeyType.itemBody,
                color = if (problem || item.step == RunStep.NEEDS_USER) colors.warn else colors.onSurfaceVariant,
            )
            if (slow) Text(stringResource(R.string.update_all_row_slow), style = BridgeyType.smallStrong, color = colors.warn)
            if (item.step == RunStep.DOWNLOADING && item.progress != null) {
                LinearProgressIndicator(
                    progress = { item.progress / 100f },
                    modifier = Modifier.padding(top = 6.dp).fillMaxWidth().height(4.dp),
                    color = colors.primary,
                    trackColor = colors.surface3,
                    strokeCap = StrokeCap.Round,
                    drawStopIndicator = {},
                )
            }
        }
    }
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            summary is RunSummary.Countdown || summary is RunSummary.Held -> OutlinePillButton(stringResource(R.string.updates_later), null, actions.later)
            run.finished -> OutlinePillButton(stringResource(R.string.action_dismiss), null, { actions.dismiss(); actions.close() })
            else -> Unit
        }
        TonalPillButton(stringResource(R.string.action_close), actions.close, tint = Tint.NEUTRAL)
    }
}

/** Rows grouped like the Settings rows: one rounded block, small gaps between rows. */
@Composable
private fun DeviceList(count: Int, row: @Composable (index: Int, shape: androidx.compose.ui.graphics.Shape) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        for (index in 0 until count) row(index, groupShape(index, count, outer = 20.dp, inner = 6.dp))
    }
}

@Composable
private fun DeviceRowFrame(
    shape: androidx.compose.ui.graphics.Shape,
    icon: ImageVector,
    name: String,
    muted: Boolean = false,
    trailing: @Composable () -> Unit = {},
    content: @Composable () -> Unit,
) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(shape).background(colors.surface1).padding(start = 14.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        IconTile(icon, if (muted) Tint.NEUTRAL else Tint.BLUE, size = 36.dp, corner = 12.dp, iconSize = 20.dp)
        Column(Modifier.weight(1f)) {
            Text(name, style = BridgeyType.itemTitle, color = if (muted) colors.onSurfaceVariant else colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
            content()
        }
        trailing()
    }
}

// MARK: Settings > Updates

/** "Your devices": this phone and each Mac with version, channel and state; Update all; the remote start switch. */
@Composable
fun YourDevicesCard(state: UpdateAllUiState, actions: UpdateAllActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Column(modifier) {
        Text(
            stringResource(R.string.update_all_devices_title),
            style = BridgeyType.itemTitle,
            color = colors.onSurface,
            modifier = Modifier.padding(horizontal = 20.dp).padding(top = 16.dp, bottom = 8.dp).semantics { heading() },
        )
        state.devices.forEach { row -> YourDeviceRow(row) }
        if (state.devices.size <= 1) {
            Text(stringResource(R.string.update_all_devices_empty), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        }
        val run = state.run
        val plan = state.plan
        if (run != null || plan?.visible == true) {
            Box(Modifier.padding(horizontal = 20.dp).padding(top = 8.dp).fillMaxWidth().height(1.dp).background(colors.outlineVariant))
            Row(
                Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    if (run != null) {
                        Text(runSummaryText(summarizeRun(run, state.now)), style = BridgeyType.itemTitle, color = colors.onSurface)
                    } else if (plan != null) {
                        Text(updateAllSummary(plan), style = BridgeyType.itemTitle, color = colors.onSurface)
                        Text(updateAllOrder(plan), style = BridgeyType.small, color = colors.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (run != null) {
                    TonalPillButton(stringResource(R.string.update_all_devices_title), actions.open, tint = Tint.PURPLE)
                } else {
                    GradientButton(stringResource(R.string.update_all_action), BridgeyIcons.Update, actions.open, height = 40.dp, textStyle = BridgeyType.label)
                }
            }
        }
        Box(Modifier.padding(horizontal = 20.dp).padding(top = 8.dp).fillMaxWidth().height(1.dp).background(colors.outlineVariant))
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 64.dp)
                .toggleable(value = state.remoteStart, role = Role.Switch) { actions.setRemoteStart(it) }
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.update_all_remote_start_title), style = BridgeyType.itemTitle, color = colors.onSurface)
                Text(stringResource(R.string.update_all_remote_start_detail), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
            BridgeySwitch(checked = state.remoteStart, onCheckedChange = null)
        }
    }
}

@Composable
private fun YourDeviceRow(row: DeviceUpdateRow) {
    val colors = BridgeyTheme.colors
    val status: UpdateStatus? = row.status
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 20.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        IconTile(if (row.isLocal) BridgeyIcons.Smartphone else platformIcon(status?.platform ?: UpdatePlatform.MACOS), if (row.skip == null) Tint.BLUE else Tint.NEUTRAL, size = 36.dp, corner = 12.dp, iconSize = 20.dp)
        Column(Modifier.weight(1f)) {
            Text(row.name, style = BridgeyType.itemTitle, color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val line = if (status != null) stringResource(R.string.update_all_device_line, status.app, channelName(status.channel)) else null
            if (line != null) Text(line, style = BridgeyType.small, color = colors.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val stateText = deviceStateText(row)
            val attention = status?.state == UpdateState.AVAILABLE || status?.state == UpdateState.READY
            Text(stateText, style = BridgeyType.smallStrong, color = if (attention) colors.primary else colors.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

// MARK: Update all devices automatically

/** A stream row's title for an automatic update entry (keys shared with the Mac). [device] is the row's device name. */
@Composable
internal fun autoUpdateItemTitle(item: ActivityItem, device: String): String {
    val content = item.content
    return when (item.kind) {
        ActivityKind.UPDATE_AUTO_DONE -> stringResource(R.string.stream_update_auto_done_title, content.orEmpty())
        ActivityKind.UPDATE_AUTO_WAITING -> waitingText(UpdateBusy.fromWire(content.orEmpty()), device.takeIf { item.deviceId != null })
        ActivityKind.UPDATE_AUTO_SKIPPED -> autoSkipText(content)?.let { stringResource(R.string.stream_update_auto_skipped_title, device, it) }
            ?: stringResource(R.string.stream_update_auto_skipped_plain, device)
        ActivityKind.UPDATE_AUTO_STARTED_BY -> stringResource(R.string.stream_update_auto_started_by_title, device)
        ActivityKind.UPDATE_AUTO_FAILED -> when {
            content == AUTO_FAILED_NOT_APPLIED && item.deviceId == null -> stringResource(R.string.stream_update_auto_not_applied_here)
            content == AUTO_FAILED_NOT_APPLIED -> stringResource(R.string.stream_update_auto_not_applied_title, device)
            item.deviceId == null -> stringResource(R.string.stream_update_auto_failed_here, failureText(RunFailure.fromWire(content)))
            else -> stringResource(R.string.stream_update_auto_failed_title, device, failureText(RunFailure.fromWire(content)))
        }
        else -> device
    }
}

/** Why the automatic run skipped a device, as the stream says it ("updates from other devices are off"). */
@Composable
private fun autoSkipText(wire: String?): String? = when (wire) {
    "offline" -> stringResource(R.string.update_auto_skip_offline)
    "by_hand" -> stringResource(R.string.update_auto_skip_by_hand)
    "not_applied" -> stringResource(R.string.update_auto_skip_not_applied)
    "remote_off" -> stringResource(R.string.update_auto_skip_remote_off)
    else -> null
}

/** "15:30" today, "29 Oct, 15:30" on another day. */
private fun autoTimeText(context: android.content.Context, at: Long, now: Long): String {
    val sameDay = java.util.Calendar.getInstance().let { first ->
        first.timeInMillis = at
        val second = java.util.Calendar.getInstance().apply { timeInMillis = now }
        first.get(java.util.Calendar.YEAR) == second.get(java.util.Calendar.YEAR) &&
            first.get(java.util.Calendar.DAY_OF_YEAR) == second.get(java.util.Calendar.DAY_OF_YEAR)
    }
    val flags = if (sameDay) DateUtils.FORMAT_SHOW_TIME else DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_NO_YEAR or DateUtils.FORMAT_SHOW_TIME
    return DateUtils.formatDateTime(context, at, flags)
}

/** What it waits for now, in one line, or null. */
@Composable
fun autoConditionText(condition: AutoCondition, now: Long): String = when (condition) {
    is AutoCondition.Waiting -> waitingText(condition.busy, condition.device)
    is AutoCondition.PutOff -> stringResource(R.string.update_auto_put_off, autoTimeText(LocalContext.current, condition.until, now))
    AutoCondition.IdleOnly -> stringResource(R.string.update_auto_idle_only)
    is AutoCondition.Yielding -> stringResource(R.string.update_auto_yield, condition.to)
    is AutoCondition.Retrying -> stringResource(R.string.update_auto_retry, autoTimeText(LocalContext.current, condition.at, now))
}

/** "3 of 3 updated", with what did not finish and a Later. */
@Composable
fun autoResultText(record: AutoRunRecord): String = when {
    record.failed > 0 && record.later -> stringResource(R.string.update_auto_result_failed_later, record.updated, record.total, record.failed)
    record.failed > 0 -> stringResource(R.string.update_auto_result_failed, record.updated, record.total, record.failed)
    record.later -> stringResource(R.string.update_auto_result_later, record.updated, record.total)
    else -> stringResource(R.string.update_auto_result, record.updated, record.total)
}

/**
 * Settings > Updates: the Update all devices automatically switch, then how often this phone checks,
 * what the automatic update waits for (if anything) and how the last one went. Off: the daily check
 * and installs only when the person taps.
 */
@Composable
fun AutoUpdateSettings(view: AutoUpdateView, now: Long, setAuto: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    val context = LocalContext.current
    val on = view.on && view.supported
    Column(modifier) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .clip(RoundedCornerShape(12.dp))
                .toggleable(value = on, enabled = view.supported, role = Role.Switch) { setAuto(it) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.update_auto_title), style = BridgeyType.itemTitle, color = colors.onSurface)
                Text(stringResource(R.string.update_auto_detail), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
            BridgeySwitch(checked = on, onCheckedChange = null, enabled = view.supported)
        }
        Column(Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (on) {
                val every = if (view.checkEvery >= AUTO_CHECK_STABLE_MILLIS) R.string.update_auto_every_6_hours else R.string.update_auto_every_30_minutes
                Text(stringResource(every), style = BridgeyType.small, color = colors.onSurfaceVariant)
                view.condition?.let { condition ->
                    Text(autoConditionText(condition, now), style = BridgeyType.smallStrong, color = colors.onSurface)
                }
            } else {
                Text(stringResource(R.string.updates_auto_title), style = BridgeyType.small, color = colors.onSurfaceVariant)
                Text(stringResource(R.string.updates_auto_detail), style = BridgeyType.small, color = colors.onSurfaceVariant)
            }
            view.lastRun?.let { record ->
                val time = autoTimeText(context, record.at, now)
                val title = record.version?.let { stringResource(R.string.update_auto_last_to, time, it) } ?: stringResource(R.string.update_auto_last, time)
                Text(title, style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp))
                Text(autoResultText(record), style = BridgeyType.small, color = if (record.failed > 0) colors.warn else colors.onSurfaceVariant)
            }
        }
    }
}
