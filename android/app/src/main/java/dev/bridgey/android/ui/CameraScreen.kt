package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** Where the camera screen is. */
enum class CameraPhase { STARTING, NEEDS_PERMISSION, READY, CAPTURING, SENDING, FAILED, ENDED }

data class CameraUiState(
    val macName: String,
    val phase: CameraPhase,
    /** The person said no and Android will not ask again: only app settings can allow it now. */
    val permanentlyDenied: Boolean = false,
    /** A short problem line under the preview (a photo that could not be saved). */
    val problem: String? = null,
)

class CameraUiActions(
    val shutter: () -> Unit = {},
    val cancel: () -> Unit = {},
    val allow: () -> Unit = {},
    val openAppSettings: () -> Unit = {},
)

/**
 * The camera a Mac asked for: Cancel and who it is for at the top, the live preview in the
 * middle (or the permission explanation), one big shutter at the bottom.
 */
@Composable
fun CameraScreen(state: CameraUiState, actions: CameraUiActions, preview: @Composable () -> Unit) {
    val colors = BridgeyTheme.colors
    Column(Modifier.fillMaxSize().background(colors.background).statusBarsPadding().navigationBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BarIconButton(BridgeyIcons.Close, stringResource(R.string.action_cancel), actions.cancel)
            Text(
                stringResource(R.string.camera_title, state.macName),
                style = BridgeyType.pageTitle,
                color = colors.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(start = 4.dp, end = 16.dp).semantics { heading() },
            )
        }
        Box(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(colors.surface2),
            contentAlignment = Alignment.Center,
        ) {
            when (state.phase) {
                CameraPhase.READY, CameraPhase.CAPTURING -> preview()
                CameraPhase.NEEDS_PERMISSION -> PermissionExplanation(state, actions)
                CameraPhase.ENDED -> Message(stringResource(R.string.camera_ended))
                CameraPhase.FAILED -> Message(state.problem ?: stringResource(R.string.camera_failed))
                CameraPhase.STARTING, CameraPhase.SENDING -> CircularProgressIndicator(color = colors.onSurfaceVariant, strokeWidth = 3.dp)
            }
        }
        // The line keeps its height in every phase, so nothing jumps when the camera starts.
        Text(
            when {
                state.problem != null && state.phase != CameraPhase.FAILED -> state.problem
                state.phase == CameraPhase.SENDING -> stringResource(R.string.camera_sending, state.macName)
                state.phase == CameraPhase.READY || state.phase == CameraPhase.CAPTURING || state.phase == CameraPhase.STARTING ->
                    stringResource(R.string.camera_hint)
                else -> ""
            },
            minLines = 2,
            style = BridgeyType.itemBody,
            color = if (state.problem != null) colors.warn else colors.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 12.dp),
        )
        Box(Modifier.fillMaxWidth().height(136.dp), contentAlignment = Alignment.Center) {
            when (state.phase) {
                CameraPhase.ENDED, CameraPhase.FAILED -> OutlinePillButton(stringResource(R.string.action_close), null, actions.cancel)
                // The permission card holds the one action; the shutter comes once the camera is allowed.
                CameraPhase.NEEDS_PERMISSION -> Unit
                else -> Shutter(enabled = state.phase == CameraPhase.READY, onClick = actions.shutter)
            }
        }
    }
}

/** One big shutter: the aurora button inside a thin ring. */
@Composable
private fun Shutter(enabled: Boolean, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    Box(
        Modifier.size(96.dp).border(3.dp, if (enabled) colors.onSurface else colors.outlineVariant, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        GradientCircleButton(BridgeyIcons.PhotoCamera, stringResource(R.string.camera_shutter), onClick, enabled = enabled, size = 80.dp)
    }
}

@Composable
private fun PermissionExplanation(state: CameraUiState, actions: CameraUiActions) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(56.dp).clip(CircleShape).background(colors.tintGreen), contentAlignment = Alignment.Center) {
            Icon(BridgeyIcons.PhotoCamera, null, tint = colors.onTintGreen, modifier = Modifier.size(28.dp))
        }
        Text(stringResource(R.string.camera_permission_title), style = BridgeyType.cardTitle, color = colors.onSurface, textAlign = TextAlign.Center)
        Text(
            stringResource(if (state.permanentlyDenied) R.string.camera_permission_denied else R.string.camera_permission_body, state.macName),
            style = BridgeyType.bodyText, color = colors.onSurfaceVariant, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.width(1.dp).height(4.dp))
        if (state.permanentlyDenied) {
            GradientButton(stringResource(R.string.camera_open_settings), null, actions.openAppSettings, height = 48.dp)
        } else {
            GradientButton(stringResource(R.string.camera_allow), BridgeyIcons.PhotoCamera, actions.allow, height = 48.dp)
        }
    }
}

@Composable
private fun Message(text: String) {
    Text(
        text,
        style = BridgeyType.bodyText,
        color = BridgeyTheme.colors.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(horizontal = 28.dp),
    )
}
