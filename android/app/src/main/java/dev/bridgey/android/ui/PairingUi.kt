package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties
import dev.bridgey.android.PairingFailure
import dev.bridgey.android.PairingRequest
import dev.bridgey.android.PairingState
import dev.bridgey.android.R
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** "482913" as "482 913": two groups of three, easier to compare across two screens. */
fun groupedPairingCode(code: String): String = if (code.length == 6) "${code.take(3)} ${code.drop(3)}" else code

/** What TalkBack reads for the code: digit by digit ("4 8 2 9 1 3"), never "four hundred eighty-two thousand". */
fun spokenPairingCode(code: String): String = code.filter(Char::isDigit).toList().joinToString(" ")

/** Allow pairing's countdown, "1:58". */
fun pairingCountdown(seconds: Int): String = "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"

/** The six digits, large and monospaced; [quiet] while this end waits for the other (the code stays in place). */
@Composable
fun PairingCode(code: String, modifier: Modifier = Modifier, quiet: Boolean = false) {
    val colors = BridgeyTheme.colors
    Box(
        modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(vertical = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            groupedPairingCode(code),
            style = PairingCodeStyle,
            color = if (quiet) colors.onSurfaceVariant else colors.onSurface,
            maxLines = 1,
            modifier = Modifier.describedAs(spokenPairingCode(code)),
        )
    }
}

private val PairingCodeStyle = TextStyle(
    fontFamily = FontFamily.Monospace,
    fontWeight = FontWeight.SemiBold,
    fontSize = 44.sp,
    lineHeight = 52.sp,
    letterSpacing = 2.sp,
)

class PairingSheetActions(
    val confirm: (token: String) -> Unit = {},
    val reject: (token: String) -> Unit = {},
    val cancel: (token: String?) -> Unit = {},
    /** Try again on a failure. */
    val retry: () -> Unit = {},
    /** Close on a failure, Done on success. */
    val dismiss: () -> Unit = {},
)

/**
 * The pairing sheet: connecting, waiting for the other end to allow pairing, the code check (neither confirmed, this
 * end waiting, the other end confirmed), paired, and why it did not finish. Nothing for Idle and Connected.
 * [stillProgress] (screenshots only) draws the waiting bar still at that point instead of animating it.
 */
@Composable
fun PairingSheet(state: PairingState, actions: PairingSheetActions, stillProgress: Float? = null) {
    val colors = BridgeyTheme.colors
    val content: PairingSheetContent = when (state) {
        is PairingState.Connecting -> PairingSheetContent(
            icon = BridgeyIcons.LaptopMac, tint = Tint.BLUE,
            title = stringResource(R.string.pairing_connecting_title, state.peerName),
            body = stringResource(R.string.pairing_connecting_body),
            progress = true,
            secondary = stringResource(R.string.action_cancel) to { actions.cancel(null) },
        )
        is PairingState.WaitingForAllow -> PairingSheetContent(
            icon = BridgeyIcons.Lock, tint = Tint.PURPLE,
            title = stringResource(R.string.pairing_allow_wait_title, state.peerName),
            body = stringResource(R.string.pairing_allow_wait_body, state.peerName),
            progress = true,
            secondary = stringResource(R.string.action_cancel) to { actions.cancel(null) },
        )
        is PairingState.Verification -> when {
            state.localConfirmed && !state.remoteConfirmed -> PairingSheetContent(
                icon = BridgeyIcons.Sync, tint = Tint.BLUE,
                title = stringResource(R.string.pairing_waiting_title, state.peerName),
                body = stringResource(R.string.pairing_waiting_body),
                code = state.code, quietCode = true, progress = true,
                secondary = stringResource(R.string.action_cancel) to { actions.cancel(state.token) },
            )
            state.remoteConfirmed -> PairingSheetContent(
                icon = BridgeyIcons.CheckCircle, tint = Tint.GREEN,
                title = stringResource(R.string.pairing_remote_confirmed_title, state.peerName),
                body = stringResource(R.string.pairing_remote_confirmed_body),
                code = state.code,
                primary = stringResource(R.string.pairing_codes_match) to { actions.confirm(state.token) },
                secondary = stringResource(R.string.pairing_codes_differ) to { actions.reject(state.token) },
            )
            else -> PairingSheetContent(
                icon = BridgeyIcons.Shield, tint = Tint.BLUE,
                title = stringResource(R.string.pairing_check_title),
                body = stringResource(R.string.pairing_check_body, state.peerName),
                code = state.code,
                primary = stringResource(R.string.pairing_codes_match) to { actions.confirm(state.token) },
                secondary = stringResource(R.string.pairing_codes_differ) to { actions.reject(state.token) },
            )
        }
        is PairingState.Paired -> PairingSheetContent(
            icon = BridgeyIcons.CheckCircle, tint = Tint.GREEN,
            title = stringResource(R.string.pairing_paired_title, state.peerName),
            body = stringResource(R.string.pairing_paired_body),
            primary = stringResource(R.string.pairing_done) to actions.dismiss,
        )
        is PairingState.Failed -> PairingSheetContent(
            icon = BridgeyIcons.Error, tint = Tint.NEUTRAL,
            title = stringResource(R.string.pairing_failed_title),
            body = pairingFailureText(state.reason, state.peerName),
            primary = stringResource(R.string.pairing_try_again) to actions.retry,
            secondary = stringResource(R.string.action_close) to actions.dismiss,
        )
        PairingState.Idle, is PairingState.Connected -> return
    }
    // Outside taps do nothing while a code is on screen (a stray tap must not answer for the person); Back cancels.
    val verifying = state is PairingState.Verification
    AlertDialog(
        onDismissRequest = {
            when {
                state is PairingState.Verification -> actions.cancel(state.token)
                else -> (content.secondary ?: content.primary)?.second?.invoke()
            }
        },
        properties = DialogProperties(dismissOnClickOutside = !verifying),
        containerColor = colors.surface2,
        icon = { IconTile(content.icon, content.tint, size = 48.dp, corner = 16.dp, iconSize = 26.dp) },
        title = {
            Text(
                content.title,
                style = BridgeyType.cardTitle,
                color = colors.onSurface,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics {
                    heading()
                    liveRegion = LiveRegionMode.Polite
                },
            )
        },
        text = {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(content.body, style = BridgeyType.bodyText, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
                content.code?.let { PairingCode(it, quiet = content.quietCode) }
                // Live while it waits; with reduced motion nothing moves, the words say it is waiting.
                if (content.progress && stillProgress != null) {
                    LinearProgressIndicator(
                        progress = { stillProgress },
                        modifier = Modifier.fillMaxWidth().height(4.dp),
                        color = colors.primary,
                        trackColor = colors.surface3,
                        strokeCap = StrokeCap.Round,
                        drawStopIndicator = {},
                    )
                } else if (content.progress && LocalMotion.current.moves) {
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().height(4.dp),
                        color = colors.primary,
                        trackColor = colors.surface3,
                        strokeCap = StrokeCap.Round,
                    )
                }
            }
        },
        confirmButton = {
            content.primary?.let { (label, onClick) ->
                TextButton(onClick = onClick) { Text(label, style = BridgeyType.label, color = colors.primary) }
            }
        },
        dismissButton = {
            content.secondary?.let { (label, onClick) ->
                TextButton(onClick = onClick) { Text(label, style = BridgeyType.label, color = colors.onSurfaceVariant) }
            }
        },
    )
}

private class PairingSheetContent(
    val icon: ImageVector,
    val tint: Tint,
    val title: String,
    val body: String,
    val code: String? = null,
    val quietCode: Boolean = false,
    val progress: Boolean = false,
    val primary: Pair<String, () -> Unit>? = null,
    val secondary: Pair<String, () -> Unit>? = null,
)

/** Why a pairing did not finish, with the other device's name. */
@Composable
fun pairingFailureText(reason: PairingFailure, peerName: String): String = when (reason) {
    PairingFailure.MISMATCH_REMOTE -> stringResource(R.string.pairing_failed_mismatch_remote, peerName)
    PairingFailure.MISMATCH_LOCAL -> stringResource(R.string.pairing_failed_mismatch_local, peerName)
    PairingFailure.TIMEOUT_REMOTE -> stringResource(R.string.pairing_failed_timeout_remote, peerName)
    PairingFailure.TIMEOUT_LOCAL -> stringResource(R.string.pairing_failed_timeout_local)
    PairingFailure.TIMEOUT_NEITHER -> stringResource(R.string.pairing_failed_timeout_neither)
    PairingFailure.CANCELLED_REMOTE -> stringResource(R.string.pairing_failed_cancelled_remote, peerName)
    PairingFailure.OLD_VERSION -> stringResource(R.string.pairing_failed_old_version, peerName)
    PairingFailure.NO_ANSWER -> stringResource(R.string.pairing_failed_no_answer, peerName)
    PairingFailure.NOT_ALLOWED -> stringResource(R.string.pairing_failed_not_allowed, peerName)
    PairingFailure.BUSY -> stringResource(R.string.pairing_failed_busy, peerName)
    PairingFailure.RATE_LIMITED -> stringResource(R.string.pairing_failed_rate_limited, peerName)
    PairingFailure.CONNECTION_LOST -> stringResource(R.string.pairing_failed_connection_lost, peerName)
    PairingFailure.COULD_NOT_CONNECT -> stringResource(R.string.pairing_failed_could_not_connect, peerName)
    PairingFailure.TIMEOUT -> stringResource(R.string.pairing_failed_timeout, peerName)
    PairingFailure.CODE_REJECTED -> stringResource(R.string.pairing_failed_code_rejected)
    PairingFailure.IDENTITY_CHANGED -> stringResource(R.string.pairing_failed_identity_changed, peerName)
    PairingFailure.INVALID -> stringResource(R.string.pairing_failed_invalid, peerName)
}

/**
 * Whether this phone takes pairings now, on the pairing screens: a device's request with Allow pairing, Allow
 * pairing's countdown with Stop, or (while the screen holds pairing on) a quiet line saying so.
 */
@Composable
fun PairingReadyCard(
    request: PairingRequest?,
    armedSeconds: Int,
    onAllow: () -> Unit,
    onNotNow: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = BridgeyTheme.colors
    val (title, detail) = when {
        request != null && request.oldVersion ->
            stringResource(R.string.pairing_request_title, request.peerName) to stringResource(R.string.pairing_failed_old_version, request.peerName)
        request != null -> stringResource(R.string.pairing_request_title, request.peerName) to stringResource(R.string.pairing_request_body)
        armedSeconds > 0 -> stringResource(R.string.pairing_ready_title, pairingCountdown(armedSeconds)) to stringResource(R.string.pairing_ready_body)
        else -> null to stringResource(R.string.pairing_ready_held)
    }
    if (title == null) {
        Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusPill(detail, BridgeyIcons.Lock, Tint.GREEN)
        }
        return
    }
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(horizontal = 14.dp, vertical = 12.dp)
            .semantics(mergeDescendants = false) { liveRegion = LiveRegionMode.Polite },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            IconTile(if (request != null) BridgeyIcons.LaptopMac else BridgeyIcons.Timer, if (request?.oldVersion == true) Tint.NEUTRAL else Tint.PURPLE, corner = 20.dp)
            Column(Modifier.weight(1f)) { CardText(title, detail, singleLineDetail = false) }
        }
        CardActions {
            when {
                request != null && request.oldVersion -> TonalPillButton(stringResource(R.string.action_close), onNotNow, tint = Tint.NEUTRAL)
                request != null -> {
                    TonalPillButton(stringResource(R.string.action_not_now), onNotNow, tint = Tint.NEUTRAL)
                    TonalPillButton(stringResource(R.string.pairing_allow), onAllow, tint = Tint.PURPLE)
                }
                else -> TonalPillButton(stringResource(R.string.action_stop), onStop, tint = Tint.NEUTRAL)
            }
        }
    }
}
