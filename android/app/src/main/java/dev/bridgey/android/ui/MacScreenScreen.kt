package dev.bridgey.android.ui

import androidx.compose.ui.semantics.clearAndSetSemantics
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.display.ControlKey
import dev.bridgey.android.display.DisplayAction
import dev.bridgey.android.display.DisplayControlReason
import dev.bridgey.android.display.DisplayGestures
import dev.bridgey.android.display.DisplayOutcome
import dev.bridgey.android.display.DisplayStatus
import dev.bridgey.android.display.DisplayStopReason
import dev.bridgey.android.display.DisplayViewState
import dev.bridgey.android.display.ScreenControl
import dev.bridgey.android.display.letterboxRect
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/** What the viewer's buttons and the picture do. */
class MacScreenActions(
    val back: () -> Unit = {},
    val stop: () -> Unit = {},
    val startAgain: () -> Unit = {},
    val control: (Boolean) -> Unit = {},
    /** One action from the picture; false when it was not taken. */
    val input: (DisplayAction) -> Boolean = { false },
    val press: (ControlKey, Boolean) -> Boolean = { _, _ -> false },
)

/**
 * A Mac's screen on this phone: a bar naming the Mac with what is happening and Stop, the picture letterboxed on
 * black, and, while controlling, the picture takes touches and a keyboard can open. [picture] draws the video surface
 * at the size and place it is given.
 */
@Composable
fun MacScreenScreen(
    state: DisplayViewState,
    actions: MacScreenActions,
    picture: @Composable (Modifier) -> Unit,
    initialKeyboard: Boolean = false,
) {
    var keyboard by rememberSaveable { mutableStateOf(initialKeyboard) }
    val showKeyboard = keyboard && state.controlling && state.input.let { it.keys || it.text }
    Column(Modifier.fillMaxSize().background(BridgeyTheme.colors.background).statusBarsPadding().navigationBarsPadding().imePadding()) {
        MacScreenBar(state, actions)
        PictureArea(state, actions, picture, Modifier.weight(1f).fillMaxWidth())
        if (showKeyboard) {
            MacKeysRow(actions, Modifier.padding(top = 8.dp))
            MacTextComposer(actions, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
        }
        if (state.streaming && state.controlAllowed) ControlRow(state, actions, showKeyboard, onKeyboard = { keyboard = it })
    }
}

@Composable
private fun MacScreenBar(state: DisplayViewState, actions: MacScreenActions) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(start = 4.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BarIconButton(BridgeyIcons.ArrowBack, stringResource(R.string.action_back), actions.back)
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text(state.macName, style = BridgeyType.itemTitle, color = colors.onSurface, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val (line, dot) = statusLine(state)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
                Text(line, style = BridgeyType.small, color = colors.onSurfaceVariant, maxLines = if (largeText()) 2 else 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (state.phase in setOf(DisplayViewState.Phase.ASKING, DisplayViewState.Phase.WAITING, DisplayViewState.Phase.STREAMING)) {
            OutlinePillButton(stringResource(R.string.action_stop), BridgeyIcons.StopCircle, actions.stop, contentColor = colors.warn)
        }
    }
}

/** Under the picture while the Mac allows control: Control on and off, and the keyboard while controlling. */
@Composable
private fun ControlRow(state: DisplayViewState, actions: MacScreenActions, keyboard: Boolean, onKeyboard: (Boolean) -> Unit) {
    val on = state.control != DisplayViewState.ControlPhase.OFF
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinePillButton(
            stringResource(if (on) R.string.display_control_stop else R.string.display_control),
            BridgeyIcons.Mouse,
            { actions.control(!on) },
            enabled = state.control != DisplayViewState.ControlPhase.STARTING,
        )
        if (state.controlling && state.input.let { it.keys || it.text }) {
            OutlinePillButton(
                stringResource(if (keyboard) R.string.remote_keyboard_hide else R.string.remote_keyboard),
                if (keyboard) BridgeyIcons.KeyboardHide else BridgeyIcons.Keyboard,
                { onKeyboard(!keyboard) },
            )
        }
    }
}

/** The line under the Mac's name, and its dot's colour. */
@Composable
private fun statusLine(state: DisplayViewState): Pair<String, Color> {
    val colors = BridgeyTheme.colors
    return when (state.phase) {
        DisplayViewState.Phase.ASKING -> stringResource(R.string.display_status_asking) to colors.onTintBlue
        DisplayViewState.Phase.WAITING -> stringResource(R.string.display_status_waiting) to colors.onTintBlue
        DisplayViewState.Phase.STREAMING -> {
            val what = when (state.control) {
                DisplayViewState.ControlPhase.ACTIVE -> stringResource(R.string.display_status_controlling)
                DisplayViewState.ControlPhase.STARTING -> stringResource(R.string.display_status_control_starting)
                DisplayViewState.ControlPhase.OFF -> stringResource(R.string.display_status_viewing)
            }
            val stats = state.stats?.let { stringResource(R.string.display_stats, it.latencyMs.toInt(), it.fps) }
            listOfNotNull(what, stats).joinToString(" · ") to colors.good
        }
        DisplayViewState.Phase.IDLE, DisplayViewState.Phase.ENDED -> stringResource(R.string.display_status_stopped) to colors.onSurfaceVariant
    }
}

@Composable
private fun PictureArea(state: DisplayViewState, actions: MacScreenActions, picture: @Composable (Modifier) -> Unit, modifier: Modifier) {
    var size by remember { mutableStateOf(IntSize.Zero) }
    val density = LocalDensity.current
    val geometry = state.geometry
    val rect = if (geometry != null && size.width > 0) {
        letterboxRect(size.width.toDouble(), size.height.toDouble(), geometry.width, geometry.height)
    } else {
        null
    }
    val description = stringResource(R.string.display_picture, state.macName)
    Box(
        modifier
            .background(Color.Black)
            .onSizeChanged { size = it }
            .semantics { contentDescription = description },
    ) {
        // The surface stays while the viewer is open, so the first key frame finds it ready.
        val placed = if (rect != null) {
            with(density) {
                Modifier
                    .offset { IntOffset(rect.left.toInt(), rect.top.toInt()) }
                    .size(rect.width.toInt().toDp(), rect.height.toInt().toDp())
            }
        } else {
            Modifier.fillMaxSize()
        }
        picture(placed)
        if (state.controlling && rect != null && geometry != null) {
            TouchLayer(state, actions, rect, geometry.width, geometry.height)
        }
        if (!state.streaming) {
            Message(state, actions, Modifier.fillMaxSize().background(BridgeyTheme.colors.background))
        } else {
            state.controlNote?.let { ControlNote(it, state.macName, Modifier.align(Alignment.BottomCenter).padding(16.dp)) }
        }
    }
}

/** Touches on the picture, as absolute positions on the Mac's shared display. */
@Composable
private fun TouchLayer(state: DisplayViewState, actions: MacScreenActions, rect: dev.bridgey.android.display.ContentRect, width: Int, height: Int) {
    val view = LocalView.current
    val input by rememberUpdatedState(actions.input)
    val slop = with(LocalDensity.current) { 8.dp.toPx() }
    val gestures = remember(state.gestureEpoch) { DisplayGestures(slop) }
    gestures.rect = rect
    gestures.streamWidth = width
    gestures.streamHeight = height
    Box(
        Modifier.fillMaxSize().pointerInput(state.gestureEpoch) {
            fun send(list: List<DisplayAction>) {
                list.forEach { action ->
                    val taken = input(action)
                    if (taken && action is DisplayAction.Button && action.down) view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                }
            }
            try {
                awaitPointerEventScope {
                    while (true) {
                        val deadline = gestures.holdDeadline
                        val event = if (deadline != null) {
                            withTimeoutOrNull((deadline - SystemClock.uptimeMillis()).coerceAtLeast(1)) { awaitPointerEvent(PointerEventPass.Main) }
                        } else {
                            awaitPointerEvent(PointerEventPass.Main)
                        }
                        if (event == null) {
                            send(gestures.onTimer(SystemClock.uptimeMillis()))
                            continue
                        }
                        val moves = HashMap<Long, Pair<Float, Float>>()
                        event.changes.forEach { change ->
                            val id = change.id.value
                            when {
                                change.pressed && !change.previousPressed -> send(gestures.onDown(id, change.position.x, change.position.y, change.uptimeMillis))
                                change.pressed -> moves[id] = change.position.x to change.position.y
                            }
                        }
                        if (moves.isNotEmpty()) send(gestures.onMove(moves))
                        event.changes.forEach { change ->
                            if (!change.pressed && change.previousPressed) send(gestures.onUp(change.id.value, change.uptimeMillis))
                            change.consume()
                        }
                    }
                }
            } finally {
                // Cancelled (control ended, the geometry changed or the screen closed): no button stays down.
                send(gestures.onCancel())
            }
        },
    )
}

@Composable
private fun Message(state: DisplayViewState, actions: MacScreenActions, modifier: Modifier) {
    val colors = BridgeyTheme.colors
    val text = when (state.phase) {
        DisplayViewState.Phase.ASKING, DisplayViewState.Phase.IDLE -> stringResource(R.string.display_asking_title, state.macName)
        DisplayViewState.Phase.WAITING -> stringResource(R.string.display_waiting_title, state.macName)
        DisplayViewState.Phase.ENDED -> outcomeText(state.outcome, state.macName)
        DisplayViewState.Phase.STREAMING -> ""
    }
    Column(
        modifier.padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(BridgeyIcons.DesktopMac, null, tint = colors.outline, modifier = Modifier.size(40.dp))
        Text(text, style = BridgeyType.bodyText, color = colors.onSurface, textAlign = TextAlign.Center)
        if (state.phase == DisplayViewState.Phase.ENDED) {
            OutlinePillButton(stringResource(R.string.display_start_again), BridgeyIcons.Refresh, actions.startAgain)
        }
    }
}

@Composable
internal fun outcomeText(outcome: DisplayOutcome?, mac: String): String = when (outcome) {
    is DisplayOutcome.Refused -> when (outcome.status) {
        DisplayStatus.DECLINED -> stringResource(R.string.display_outcome_declined, mac)
        DisplayStatus.BUSY -> stringResource(R.string.display_outcome_busy, mac)
        DisplayStatus.DISABLED -> stringResource(R.string.display_outcome_disabled, mac)
        DisplayStatus.PERMISSION -> stringResource(R.string.display_outcome_permission, mac)
        DisplayStatus.LOCKED -> stringResource(R.string.display_outcome_locked, mac)
        DisplayStatus.FAILED, DisplayStatus.WAITING -> stringResource(R.string.display_outcome_failed, mac)
    }
    is DisplayOutcome.Stopped -> when (outcome.reason) {
        DisplayStopReason.LOCAL_STOP -> stringResource(R.string.display_outcome_stopped_mac, mac)
        DisplayStopReason.USER, DisplayStopReason.LEFT_SCREEN, DisplayStopReason.SCREEN_OFF ->
            if (outcome.byMac) stringResource(R.string.display_outcome_stopped_mac, mac) else stringResource(R.string.display_outcome_stopped_here)
        DisplayStopReason.DISABLED -> stringResource(R.string.display_outcome_disabled, mac)
        DisplayStopReason.PERMISSION -> stringResource(R.string.display_outcome_permission, mac)
        DisplayStopReason.LOCKED -> stringResource(R.string.display_outcome_locked, mac)
        DisplayStopReason.SOURCE_CHANGED -> stringResource(R.string.display_outcome_display_changed, mac)
        DisplayStopReason.TIMEOUT -> stringResource(R.string.display_outcome_timeout, mac)
        DisplayStopReason.INVALID, DisplayStopReason.FAILED -> stringResource(R.string.display_outcome_failed, mac)
    }
    DisplayOutcome.Disconnected -> stringResource(R.string.display_outcome_disconnected, mac)
    DisplayOutcome.NoAnswer -> stringResource(R.string.display_outcome_no_answer, mac)
    DisplayOutcome.Unavailable -> stringResource(R.string.display_outcome_unavailable, mac)
    null -> stringResource(R.string.display_outcome_stopped_here)
}

@Composable
private fun ControlNote(reason: DisplayControlReason, mac: String, modifier: Modifier) {
    val colors = BridgeyTheme.colors
    val text = when (reason) {
        DisplayControlReason.DISABLED -> stringResource(R.string.display_control_note_disabled, mac)
        DisplayControlReason.PERMISSION -> stringResource(R.string.display_control_note_permission, mac)
        DisplayControlReason.BUSY -> stringResource(R.string.display_control_note_busy, mac)
        DisplayControlReason.FOCUS -> stringResource(R.string.display_control_note_focus)
        DisplayControlReason.LOCKED -> stringResource(R.string.display_outcome_locked, mac)
        DisplayControlReason.TIMEOUT -> stringResource(R.string.display_control_note_timeout)
        DisplayControlReason.LOCAL_STOP -> stringResource(R.string.display_control_note_stopped, mac)
        DisplayControlReason.USER, DisplayControlReason.RATE, DisplayControlReason.INVALID, DisplayControlReason.SOURCE_CHANGED,
        DisplayControlReason.FAILED -> stringResource(R.string.display_control_note_ended)
    }
    Text(
        text,
        style = BridgeyType.small,
        color = colors.onSurface,
        textAlign = TextAlign.Center,
        modifier = modifier.clip(RoundedCornerShape(16.dp)).background(colors.surface2).padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

private data class MacKey(val key: ControlKey, val label: Int, val shift: Boolean = false)

private val MacKeys = listOf(
    MacKey(ControlKey.ESCAPE, R.string.remote_key_escape),
    MacKey(ControlKey.TAB, R.string.remote_key_tab),
    MacKey(ControlKey.TAB, R.string.remote_key_shift_tab, shift = true),
    MacKey(ControlKey.LEFT, R.string.remote_key_left),
    MacKey(ControlKey.UP, R.string.remote_key_up),
    MacKey(ControlKey.DOWN, R.string.remote_key_down),
    MacKey(ControlKey.RIGHT, R.string.remote_key_right),
    MacKey(ControlKey.BACKSPACE, R.string.remote_key_backspace),
    MacKey(ControlKey.ENTER, R.string.remote_key_return),
    MacKey(ControlKey.PAGE_UP, R.string.remote_key_page_up),
    MacKey(ControlKey.PAGE_DOWN, R.string.remote_key_page_down),
    MacKey(ControlKey.HOME, R.string.remote_key_home),
    MacKey(ControlKey.END, R.string.remote_key_end),
)

/** The named keys: everything the phone can press besides typed text (Space goes as text). */
@Composable
private fun MacKeysRow(actions: MacScreenActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    val view = LocalView.current
    LazyRow(modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        items(MacKeys, key = { "${it.key.wire}:${it.shift}" }) { chip ->
            val label = stringResource(chip.label)
            Box(
                Modifier
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .clickable(role = Role.Button, onClickLabel = label) {
                        if (actions.press(chip.key, chip.shift)) view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    }
                    .semantics(mergeDescendants = true) { contentDescription = label },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.heightIn(min = 40.dp).clip(RoundedCornerShape(12.dp)).background(colors.surface2).padding(horizontal = 12.dp),
                    contentAlignment = Alignment.Center,
                    // The key's description is its label: read once.
                ) { Text(label, style = BridgeyType.label, color = colors.onSurface, maxLines = 1, modifier = Modifier.clearAndSetSemantics {}) }
            }
        }
    }
}

/** Typed text goes as text, never as shortcuts: at most 256 characters a message. */
@Composable
private fun MacTextComposer(actions: MacScreenActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    var text by rememberSaveable { mutableStateOf("") }
    val send = {
        if (text.isNotEmpty() && actions.input(DisplayAction.Text(text))) text = ""
    }
    val hint = stringResource(R.string.display_type_hint)
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(colors.surface1)
            .border(1.dp, fieldBorderColor, RoundedCornerShape(24.dp)).padding(start = 16.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f).heightIn(min = 48.dp), contentAlignment = Alignment.CenterStart) {
            if (text.isEmpty()) Text(hint, style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
            BasicTextField(
                value = text,
                onValueChange = { value -> text = value.filterNot { it == '\n' || it == '\t' }.take(ScreenControl.MAX_TEXT_SCALARS) },
                textStyle = BridgeyType.bodyText.copy(color = colors.onSurface),
                cursorBrush = SolidColor(colors.primary),
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { send() }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = hint },
            )
        }
        BarIconButton(BridgeyIcons.Send, stringResource(R.string.display_type_send), { send() }, enabled = text.isNotEmpty())
    }
}
