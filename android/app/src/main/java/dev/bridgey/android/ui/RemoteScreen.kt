package dev.bridgey.android.ui

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
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
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.R
import dev.bridgey.android.remote.MotionBatcher
import dev.bridgey.android.remote.PointerButton
import dev.bridgey.android.remote.PresentAction
import dev.bridgey.android.remote.RemoteInput
import dev.bridgey.android.remote.RemoteInputLimits
import dev.bridgey.android.remote.RemoteKey
import dev.bridgey.android.remote.RemoteMode
import dev.bridgey.android.remote.RemoteSessionState
import dev.bridgey.android.remote.RemoteStopReason
import dev.bridgey.android.remote.SCROLL_GAIN
import dev.bridgey.android.remote.TouchpadGesture
import dev.bridgey.android.remote.TouchpadGestureRecognizer
import dev.bridgey.android.remote.boundedRemoteText
import dev.bridgey.android.remote.isValidRemoteText
import dev.bridgey.android.remote.laserPosition
import dev.bridgey.android.remote.pointerGain
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.SpringTabIndicator
import dev.bridgey.android.ui.motion.pressScale
import dev.bridgey.android.ui.motion.tabContentTransform
import dev.bridgey.android.ui.theme.Aurora
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop
import kotlin.math.hypot
import kotlinx.coroutines.delay

data class RemoteScreenState(
    val deviceName: String,
    val session: RemoteSessionState,
    /** 1 (slow) to 5 (fast). */
    val pointerSpeed: Int,
    val volumeKeys: Boolean,
) {
    val active: Boolean get() = session is RemoteSessionState.Active
}

class RemoteActions(
    val back: () -> Unit = {},
    val start: (RemoteMode) -> Unit = {},
    val stop: () -> Unit = {},
    /** Sends one input message; false when it was dropped. */
    val input: (RemoteInput) -> Boolean = { false },
)

/** Light mode band: status bar + 56 dp page bar + 8 dp, as on Settings pages. */
private val RemoteBand = 64.dp

/**
 * Remote control of a Mac: a full-screen touchpad with an optional keyboard, or a presentation
 * remote with a laser pointer. The session runs only while this screen is shown; the Mac shows who
 * is in control and can stop it.
 */
@Composable
fun RemoteScreen(
    state: RemoteScreenState,
    actions: RemoteActions,
    initialMode: RemoteMode = RemoteMode.TOUCHPAD,
    initialKeyboard: Boolean = false,
) {
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var mode by rememberSaveable { mutableStateOf(initialMode) }
    var keyboard by rememberSaveable { mutableStateOf(initialKeyboard) }
    val motion = LocalMotion.current
    val batcher = remember { MotionBatcher() }
    val send by rememberUpdatedState(actions.input)
    // Motion goes out at most 60 times a second, whatever the display's refresh rate.
    LaunchedEffect(state.active) {
        if (!state.active) return@LaunchedEffect
        while (true) {
            delay(16)
            batcher.flush().forEach { send(it) }
        }
    }
    ScreenBackdrop(bandHeight = statusTop + RemoteBand) {
        Column(Modifier.fillMaxSize()) {
            OnBand { RemoteBar(state, actions) }
            ModeTabs(mode, onMode = { mode = it }, modifier = Modifier.padding(top = 8.dp))
            Box(Modifier.weight(1f).fillMaxWidth()) {
                AnimatedContent(
                    targetState = mode,
                    transitionSpec = { motion.tabContentTransform(forward = targetState.ordinal > initialState.ordinal) },
                    label = "remoteMode",
                    modifier = Modifier.fillMaxSize(),
                ) { shown ->
                    when (shown) {
                        RemoteMode.TOUCHPAD -> TouchpadPane(state, actions, batcher, keyboard, onKeyboard = { keyboard = it })
                        RemoteMode.PRESENTATION -> PresentationPane(state, actions, batcher)
                    }
                }
                androidx.compose.animation.AnimatedVisibility(
                    visible = !state.active,
                    enter = fadeIn(motion.fadeSpec()),
                    exit = fadeOut(motion.fadeSpec()),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    SessionOverlay(state, onStart = { actions.start(mode) })
                }
            }
        }
    }
}

@Composable
private fun RemoteBar(state: RemoteScreenState, actions: RemoteActions) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(start = 4.dp, end = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BarIconButton(BridgeyIcons.ArrowBack, stringResource(R.string.action_back), actions.back)
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            Text(state.deviceName, style = BridgeyType.itemTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val (label, color) = when (state.session) {
                is RemoteSessionState.Active -> stringResource(R.string.remote_status_active) to colors.good
                is RemoteSessionState.Starting -> stringResource(R.string.remote_status_starting) to colors.onTintBlue
                else -> stringResource(R.string.remote_status_stopped) to colors.onSurfaceVariant
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(color))
                Text(label, style = BridgeyType.small, color = colors.onSurfaceVariant, maxLines = 1)
            }
        }
        if (state.session is RemoteSessionState.Active || state.session is RemoteSessionState.Starting) {
            OutlinePillButton(stringResource(R.string.action_stop), BridgeyIcons.StopCircle, actions.stop, contentColor = colors.warn)
        }
    }
}

@Composable
private fun ModeTabs(mode: RemoteMode, onMode: (RemoteMode) -> Unit, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Box(modifier.fillMaxWidth().height(48.dp)) {
        Row(Modifier.fillMaxSize().padding(horizontal = 8.dp)) {
            RemoteMode.entries.forEach { entry ->
                val selected = entry == mode
                Row(
                    Modifier.weight(1f).fillMaxSize().selectable(selected = selected, role = Role.Tab) { onMode(entry) },
                    horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        if (entry == RemoteMode.TOUCHPAD) BridgeyIcons.Mouse else BridgeyIcons.Slideshow,
                        null,
                        tint = if (selected) colors.onSurface else colors.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        stringResource(if (entry == RemoteMode.TOUCHPAD) R.string.remote_mode_touchpad else R.string.remote_mode_slides),
                        style = BridgeyType.label,
                        color = if (selected) colors.onSurface else colors.onSurfaceVariant,
                    )
                }
            }
        }
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(1.dp).background(colors.outlineVariant))
        SpringTabIndicator(
            selected = mode.ordinal,
            count = RemoteMode.entries.size,
            brush = Aurora.ringHorizontal(),
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 8.dp),
        )
    }
}

// MARK: Touchpad

@Composable
private fun TouchpadPane(
    state: RemoteScreenState,
    actions: RemoteActions,
    batcher: MotionBatcher,
    keyboard: Boolean,
    onKeyboard: (Boolean) -> Unit,
) {
    Column(Modifier.fillMaxSize().imePadding().navigationBarsPadding()) {
        TouchSurface(state, actions, batcher, Modifier.weight(1f).fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp))
        if (keyboard) {
            SpecialKeysRow(state.active, actions, Modifier.padding(top = 12.dp))
            TextComposer(state.active, actions, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinePillButton(
                stringResource(if (keyboard) R.string.remote_keyboard_hide else R.string.remote_keyboard),
                if (keyboard) BridgeyIcons.KeyboardHide else BridgeyIcons.Keyboard,
                { onKeyboard(!keyboard) },
            )
        }
    }
}

/**
 * The touch surface: the gesture recogniser turns touches into moves, clicks, scrolls and drags.
 * Pending motion goes out before every click, so a click lands where the pointer was moved.
 */
@Composable
private fun TouchSurface(state: RemoteScreenState, actions: RemoteActions, batcher: MotionBatcher, modifier: Modifier) {
    val colors = BridgeyTheme.colors
    val density = LocalDensity.current.density
    val view = LocalView.current
    val send by rememberUpdatedState(actions.input)
    val speed by rememberUpdatedState(state.pointerSpeed)
    val shape = RoundedCornerShape(28.dp)
    val description = stringResource(R.string.remote_touchpad_label)
    Box(
        modifier
            .clip(shape)
            .background(colors.surface1)
            .border(1.dp, colors.outlineVariant, shape)
            .semantics { contentDescription = description }
            .pointerInput(state.active) {
                if (!state.active) return@pointerInput
                val recognizer = TouchpadGestureRecognizer(slopPx = 8.dp.toPx())
                var lastMoveAt = 0L
                fun flush() = batcher.flush().forEach { send(it) }
                fun handle(gestures: List<TouchpadGesture>, eventTime: Long) {
                    for (gesture in gestures) when (gesture) {
                        is TouchpadGesture.Move -> {
                            val dpX = gesture.dx / density
                            val dpY = gesture.dy / density
                            val elapsed = (eventTime - lastMoveAt).coerceIn(1, 100)
                            lastMoveAt = eventTime
                            val gain = pointerGain(speed, hypot(dpX, dpY) / elapsed)
                            batcher.addPointer(dpX * gain, dpY * gain)
                        }
                        is TouchpadGesture.Scroll -> batcher.addScroll(gesture.dx / density * SCROLL_GAIN, gesture.dy / density * SCROLL_GAIN)
                        is TouchpadGesture.DragMove -> {
                            val gain = pointerGain(speed, 0f)
                            batcher.addDrag(gesture.dx / density * gain, gesture.dy / density * gain)
                        }
                        is TouchpadGesture.Click -> {
                            flush()
                            send(RemoteInput.Button(gesture.button, down = true))
                            send(RemoteInput.Button(gesture.button, down = false))
                            view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                        }
                        TouchpadGesture.DragStart -> {
                            flush()
                            send(RemoteInput.DragStart)
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        }
                        TouchpadGesture.DragEnd -> {
                            flush()
                            send(RemoteInput.DragEnd)
                        }
                    }
                }
                try {
                    awaitPointerEventScope {
                        while (true) {
                            val deadline = recognizer.holdDeadline
                            val event = if (deadline != null) {
                                withTimeoutOrNull((deadline - SystemClock.uptimeMillis()).coerceAtLeast(1)) { awaitPointerEvent(PointerEventPass.Main) }
                            } else {
                                awaitPointerEvent(PointerEventPass.Main)
                            }
                            if (event == null) {
                                handle(recognizer.onTimer(SystemClock.uptimeMillis()), SystemClock.uptimeMillis())
                                continue
                            }
                            val time = event.changes.maxOfOrNull { it.uptimeMillis } ?: SystemClock.uptimeMillis()
                            val moves = HashMap<Long, Pair<Float, Float>>()
                            event.changes.forEach { change ->
                                val id = change.id.value
                                when {
                                    change.pressed && !change.previousPressed ->
                                        handle(recognizer.onDown(id, change.position.x, change.position.y, change.uptimeMillis), time)
                                    change.pressed -> moves[id] = change.position.x to change.position.y
                                }
                            }
                            if (moves.isNotEmpty()) handle(recognizer.onMove(moves), time)
                            event.changes.forEach { change ->
                                if (!change.pressed && change.previousPressed) handle(recognizer.onUp(change.id.value, change.uptimeMillis), time)
                                change.consume()
                            }
                        }
                    }
                } finally {
                    // Cancelled (the session ended or the screen closed): no button stays down.
                    handle(recognizer.onCancel(), SystemClock.uptimeMillis())
                }
            },
    ) {
        TouchHints(Modifier.align(Alignment.Center))
    }
}

@Composable
private fun TouchHints(modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Column(modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(BridgeyIcons.Mouse, null, tint = colors.outline, modifier = Modifier.size(32.dp))
        listOf(R.string.remote_hint_move, R.string.remote_hint_click, R.string.remote_hint_scroll).forEach {
            Text(stringResource(it), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}

private data class KeyChip(val key: RemoteKey, val label: Int, val icon: ImageVector? = null, val shift: Boolean = false)

private val KeyChips = listOf(
    KeyChip(RemoteKey.ESCAPE, R.string.remote_key_escape),
    KeyChip(RemoteKey.TAB, R.string.remote_key_tab, BridgeyIcons.KeyboardTab),
    KeyChip(RemoteKey.LEFT, R.string.remote_key_left, BridgeyIcons.KeyLeft),
    KeyChip(RemoteKey.UP, R.string.remote_key_up, BridgeyIcons.KeyUp),
    KeyChip(RemoteKey.DOWN, R.string.remote_key_down, BridgeyIcons.KeyDown),
    KeyChip(RemoteKey.RIGHT, R.string.remote_key_right, BridgeyIcons.KeyRight),
    KeyChip(RemoteKey.BACKSPACE, R.string.remote_key_backspace, BridgeyIcons.Backspace),
    KeyChip(RemoteKey.RETURN, R.string.remote_key_return, BridgeyIcons.KeyboardReturn),
    KeyChip(RemoteKey.SPACE, R.string.remote_key_space, BridgeyIcons.SpaceBar),
    KeyChip(RemoteKey.TAB, R.string.remote_key_shift_tab, shift = true),
    KeyChip(RemoteKey.PAGE_UP, R.string.remote_key_page_up),
    KeyChip(RemoteKey.PAGE_DOWN, R.string.remote_key_page_down),
    KeyChip(RemoteKey.HOME, R.string.remote_key_home),
    KeyChip(RemoteKey.END, R.string.remote_key_end),
    KeyChip(RemoteKey.F5, R.string.remote_key_f5),
    KeyChip(RemoteKey.PREVIOUS_APP, R.string.remote_key_previous_app, BridgeyIcons.SwapHoriz),
)

/** The allowlisted special keys: everything a phone can press besides typed text. */
@Composable
private fun SpecialKeysRow(enabled: Boolean, actions: RemoteActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    val view = LocalView.current
    LazyRow(modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        items(KeyChips, key = { "${it.key.wire}:${it.shift}" }) { chip ->
            val label = stringResource(chip.label)
            Box(
                Modifier
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .clickable(enabled = enabled, role = Role.Button, onClickLabel = label) {
                        if (actions.input(RemoteInput.Key(chip.key, chip.shift))) view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    }
                    .semantics(mergeDescendants = true) { contentDescription = label },
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    Modifier.height(40.dp).clip(RoundedCornerShape(12.dp)).background(colors.surface2).padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    val tint = if (enabled) colors.onSurface else colors.onSurfaceVariant
                    if (chip.icon != null) Icon(chip.icon, null, tint = tint, modifier = Modifier.size(18.dp))
                    if (chip.icon == null || chip.key == RemoteKey.PREVIOUS_APP) {
                        Text(label, style = BridgeyType.label, color = tint, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** Bounded text: up to 256 characters a message, sent when you tap Send. */
@Composable
private fun TextComposer(enabled: Boolean, actions: RemoteActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    var text by rememberSaveable { mutableStateOf("") }
    val send = {
        if (isValidRemoteText(text) && actions.input(RemoteInput.Text(text))) text = ""
    }
    val label = stringResource(R.string.remote_text_label)
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(colors.composer)
            .border(1.dp, colors.composerOutline, RoundedCornerShape(28.dp)).padding(start = 20.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) {
                Text(stringResource(R.string.remote_text_hint), style = BridgeyType.field, color = colors.onSurfaceVariant, maxLines = 1)
            }
            BasicTextField(
                value = text,
                onValueChange = { text = boundedRemoteText(it) },
                enabled = enabled,
                singleLine = true,
                textStyle = BridgeyType.field.copy(color = colors.onSurface),
                cursorBrush = SolidColor(colors.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { send() }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = label },
            )
        }
        Text(
            "${text.codePointCount(0, text.length)}/${RemoteInputLimits.MAX_TEXT_SCALARS}",
            style = BridgeyType.small,
            color = colors.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 8.dp),
        )
        GradientCircleButton(BridgeyIcons.Send, stringResource(R.string.remote_text_send), onClick = send, enabled = enabled && text.isNotEmpty())
    }
}

// MARK: Presentation

@Composable
private fun PresentationPane(state: RemoteScreenState, actions: RemoteActions, batcher: MotionBatcher) {
    val view = LocalView.current
    val press: (PresentAction) -> Unit = { action ->
        if (actions.input(RemoteInput.Present(action))) view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    }
    // Volume keys change slides while this pane shows, if Settings allows it.
    val volumeKeys = state.volumeKeys && state.active
    DisposableEffect(volumeKeys) {
        dev.bridgey.android.remote.VolumeKeyRouter.handler = if (volumeKeys) {
            { up -> press(if (up) PresentAction.PREVIOUS else PresentAction.NEXT) }
        } else {
            null
        }
        onDispose { dev.bridgey.android.remote.VolumeKeyRouter.handler = null }
    }
    Column(
        Modifier.fillMaxSize().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        LaserPad(state.active, actions, batcher, Modifier.fillMaxWidth().aspectRatio(16f / 9f))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SlideAction(stringResource(R.string.remote_present_start), BridgeyIcons.PlayArrow, state.active, Modifier.weight(1f)) { press(PresentAction.START) }
            SlideAction(stringResource(R.string.remote_present_black), BridgeyIcons.TvOff, state.active, Modifier.weight(1f)) { press(PresentAction.BLACK) }
            SlideAction(stringResource(R.string.remote_present_end), BridgeyIcons.Close, state.active, Modifier.weight(1f)) { press(PresentAction.END) }
        }
        Spacer(Modifier.weight(1f))
        if (state.volumeKeys) {
            Note(stringResource(R.string.remote_volume_keys_on), Modifier.fillMaxWidth().padding(horizontal = 8.dp), center = true)
        }
        Row(Modifier.fillMaxWidth().height(144.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SlideStep(stringResource(R.string.remote_present_previous), BridgeyIcons.SkipPrevious, primary = false, state.active, Modifier.weight(1f)) {
                press(PresentAction.PREVIOUS)
            }
            SlideStep(stringResource(R.string.remote_present_next), BridgeyIcons.SkipNext, primary = true, state.active, Modifier.weight(1.5f)) {
                press(PresentAction.NEXT)
            }
        }
    }
}

/**
 * The laser: touch and hold to show a dot on the Mac where your finger is, move to move it, lift
 * to hide it. The pad stands for the whole display (16:9).
 */
@Composable
private fun LaserPad(enabled: Boolean, actions: RemoteActions, batcher: MotionBatcher, modifier: Modifier) {
    val colors = BridgeyTheme.colors
    val send by rememberUpdatedState(actions.input)
    val view = LocalView.current
    var size by remember { mutableStateOf(IntSize.Zero) }
    var finger by remember { mutableStateOf<Offset?>(null) }
    val shape = RoundedCornerShape(24.dp)
    Box(
        modifier
            .clip(shape)
            .background(colors.surface1)
            .border(1.dp, colors.outlineVariant, shape)
            .onSizeChanged { size = it }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    val down = awaitFirstDown()
                    fun position(at: Offset) = laserPosition(at.x, at.y, size.width.toFloat(), size.height.toFloat())
                    val (x, y) = position(down.position)
                    send(RemoteInput.Present(PresentAction.LASER_ON, x, y))
                    view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                    finger = down.position
                    down.consume()
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) break
                            val (mx, my) = position(change.position)
                            batcher.moveLaser(mx, my)
                            finger = change.position
                            change.consume()
                        }
                    } finally {
                        batcher.clearLaser()
                        send(RemoteInput.Present(PresentAction.LASER_OFF))
                        finger = null
                    }
                }
            },
    ) {
        val showing = finger != null
        Column(
            Modifier.align(Alignment.Center).graphicsLayer { alpha = if (showing) 0f else 1f }.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(BridgeyIcons.AdsClick, null, tint = colors.outline, modifier = Modifier.size(28.dp))
            Text(stringResource(R.string.remote_laser_hint), style = BridgeyType.itemBody, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        // The dot under the finger: moved by a transform only.
        LaserDot(Modifier.graphicsLayer {
            val at = finger
            alpha = if (at == null) 0f else 1f
            translationX = (at?.x ?: 0f) - 14.dp.toPx()
            translationY = (at?.y ?: 0f) - 14.dp.toPx()
        })
    }
}

@Composable
private fun LaserDot(modifier: Modifier) {
    Box(modifier.size(28.dp).clip(CircleShape).background(Color(0x66FF3B30)), contentAlignment = Alignment.Center) {
        Box(Modifier.size(12.dp).clip(CircleShape).background(Color(0xFFFF453A)))
    }
}

@Composable
private fun SlideAction(label: String, icon: ImageVector, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    Column(
        modifier
            .pressScale(interaction)
            .height(72.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(colors.surface2)
            .clickable(interactionSource = interaction, indication = androidx.compose.material3.ripple(), enabled = enabled, role = Role.Button, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
    ) {
        val alpha = if (enabled) 1f else 0.38f
        Icon(icon, null, tint = colors.onTintBlue.copy(alpha = alpha), modifier = Modifier.size(22.dp))
        Text(label, style = BridgeyType.smallStrong, color = colors.onSurface.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Previous and Next: big, so they can be hit without looking. Next is the main action. */
@Composable
private fun SlideStep(label: String, icon: ImageVector, primary: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
    val shape = RoundedCornerShape(32.dp)
    Column(
        modifier
            .pressScale(interaction)
            .fillMaxSize()
            .clip(shape)
            .then(
                if (primary && enabled) Modifier.drawBehind { drawRect(Aurora.button(size)) }
                else Modifier.background(colors.surface2),
            )
            .clickable(interactionSource = interaction, indication = androidx.compose.material3.ripple(), enabled = enabled, role = Role.Button, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
    ) {
        val fg = when {
            !enabled -> colors.onSurfaceVariant
            primary -> Aurora.OnGradient
            else -> colors.onSurface
        }
        Icon(icon, null, tint = fg, modifier = Modifier.size(36.dp))
        Text(label, style = BridgeyType.button, color = fg, maxLines = 1)
    }
}

// MARK: Session overlay

/** Shown over the controls whenever no session runs: connecting, why it stopped, and Start again. */
@Composable
private fun SessionOverlay(state: RemoteScreenState, onStart: () -> Unit) {
    val colors = BridgeyTheme.colors
    // Opaque, so the touchpad hints never show through the message.
    Box(Modifier.fillMaxSize().background(colors.background).pointerInput(Unit) {
        // Touches stop here while no session runs.
        awaitEachGesture { awaitFirstDown().consume() }
    }) {
        Column(
            Modifier.align(Alignment.Center).padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            val session = state.session
            IconTile(
                if (session is RemoteSessionState.Starting) BridgeyIcons.Mouse else BridgeyIcons.StopCircle,
                if (session is RemoteSessionState.Starting) Tint.BLUE else Tint.NEUTRAL,
                size = 56.dp,
                corner = 18.dp,
                iconSize = 28.dp,
            )
            Text(overlayTitle(state), style = BridgeyType.cardTitle, color = colors.onSurface, textAlign = TextAlign.Center)
            Text(overlayDetail(state), style = BridgeyType.bodyText, color = colors.onSurfaceVariant, textAlign = TextAlign.Center)
            if (session !is RemoteSessionState.Starting) {
                GradientButton(
                    stringResource(if (session is RemoteSessionState.Idle) R.string.remote_start else R.string.remote_start_again),
                    BridgeyIcons.PlayArrow,
                    onStart,
                    Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun overlayTitle(state: RemoteScreenState): String = when (val session = state.session) {
    is RemoteSessionState.Starting -> stringResource(R.string.remote_overlay_connecting, state.deviceName)
    is RemoteSessionState.Ended -> when (session.reason) {
        RemoteStopReason.LOCAL_STOP -> stringResource(R.string.remote_overlay_stopped_on_mac, state.deviceName)
        RemoteStopReason.DISABLED -> stringResource(R.string.remote_overlay_not_allowed)
        RemoteStopReason.PERMISSION_REQUIRED -> stringResource(R.string.remote_overlay_accessibility)
        RemoteStopReason.BUSY -> stringResource(R.string.remote_overlay_busy)
        else -> stringResource(R.string.remote_overlay_stopped)
    }
    else -> stringResource(R.string.remote_overlay_ready, state.deviceName)
}

@Composable
private fun overlayDetail(state: RemoteScreenState): String = when (val session = state.session) {
    is RemoteSessionState.Starting -> stringResource(R.string.remote_overlay_connecting_detail, state.deviceName)
    is RemoteSessionState.Ended -> stringResource(
        when (session.reason) {
            RemoteStopReason.USER -> R.string.remote_reason_user
            RemoteStopReason.LEFT_SCREEN, RemoteStopReason.SCREEN_OFF -> R.string.remote_reason_left
            RemoteStopReason.LOCAL_STOP -> R.string.remote_reason_local_stop
            RemoteStopReason.TIMEOUT -> R.string.remote_reason_timeout
            RemoteStopReason.DISABLED -> R.string.remote_reason_disabled
            RemoteStopReason.PERMISSION_REQUIRED -> R.string.remote_reason_permission
            RemoteStopReason.BUSY -> R.string.remote_reason_busy
            RemoteStopReason.INVALID, RemoteStopReason.UNSUPPORTED -> R.string.remote_reason_unsupported
            RemoteStopReason.DISCONNECTED -> R.string.remote_reason_disconnected
            RemoteStopReason.NO_ANSWER -> R.string.remote_reason_no_answer
        },
        state.deviceName,
    )
    else -> stringResource(R.string.remote_overlay_ready_detail, state.deviceName)
}

/** The device a session belongs to, while it starts, runs or after it ended. */
val RemoteSessionState.deviceId: String?
    get() = when (this) {
        is RemoteSessionState.Starting -> deviceId
        is RemoteSessionState.Active -> deviceId
        is RemoteSessionState.Ended -> deviceId
        RemoteSessionState.Idle -> null
    }

/**
 * The remote control screen for [deviceId], wired to the controller: it starts once when opened,
 * keeps the screen on, and stops when the screen closes, the app leaves the foreground or the
 * display turns off. Coming back shows Start again rather than restarting by itself.
 */
@Composable
fun RemoteRoute(
    deviceId: String,
    deviceName: String,
    controller: dev.bridgey.android.remote.RemoteInputController,
    preferences: dev.bridgey.android.remote.RemotePreferencesState,
    onBack: () -> Unit,
) {
    val session by controller.state.collectAsStateWithLifecycle()
    val shown = session.takeIf { it.deviceId == deviceId } ?: RemoteSessionState.Idle
    var autoStarted by rememberSaveable(deviceId) { mutableStateOf(false) }
    val view = LocalView.current
    val context = androidx.compose.ui.platform.LocalContext.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }
    androidx.lifecycle.compose.LifecycleStartEffect(deviceId) {
        if (!autoStarted) {
            autoStarted = true
            controller.start(deviceId, RemoteMode.TOUCHPAD)
        }
        onStopOrDispose {
            val interactive = context.getSystemService(android.os.PowerManager::class.java)?.isInteractive != false
            controller.stop(if (interactive) RemoteStopReason.LEFT_SCREEN else RemoteStopReason.SCREEN_OFF)
        }
    }
    DisposableEffect(deviceId) { onDispose { controller.clear() } }
    RemoteScreen(
        state = RemoteScreenState(deviceName, shown, preferences.pointerSpeed, preferences.volumeKeysChangeSlides),
        actions = RemoteActions(
            back = onBack,
            start = { controller.start(deviceId, it) },
            stop = { controller.stop(RemoteStopReason.USER) },
            input = controller::send,
        ),
    )
}
