package dev.bridgey.android.ui.attach

import android.view.KeyEvent
import androidx.compose.foundation.border
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.isAltPressed
import androidx.compose.ui.input.pointer.isCtrlPressed
import androidx.compose.ui.input.pointer.isMetaPressed
import androidx.compose.ui.input.pointer.isShiftPressed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import dev.bridgey.android.ui.theme.BridgeyTheme

/** Item-scoped keyboard handling leaves Browse, permission prompts, menus and target controls alone. */
internal class AttachPickerSelection(
    val focusedKey: String?,
    val keyboardFocus: Boolean,
    val selectedKeys: Set<String>,
    val focus: (String) -> Unit,
    val pointerStarted: () -> Unit,
    val click: (String, Boolean, Boolean) -> Unit,
    val key: (String, KeyEvent) -> Boolean,
    val escape: (KeyEvent) -> Boolean,
)

@Composable
internal fun rememberAttachPickerSelection(state: AttachState, actions: AttachActions): AttachPickerSelection {
    var cursor by remember(state.tab) { mutableStateOf(AttachSelectionCursor()) }
    var keyboardFocus by remember(state.tab) { mutableStateOf(false) }
    var pointerFocus by remember(state.tab) { mutableStateOf(false) }
    var escapeHeld by remember { mutableStateOf(false) }
    val keys = AttachSelection.selectableKeys(state)

    fun apply(change: (List<String>) -> AttachSelectionChange) {
        actions.updateSelection { selection ->
            val result = change(selection)
            cursor = result.cursor
            result.selection
        }
    }

    fun clear(): Boolean {
        var cleared = false
        actions.updateSelection { current ->
            cleared = current.isNotEmpty()
            if (cleared) emptyList() else current
        }
        if (cleared) cursor = cursor.copy(anchor = null, rangeBase = null)
        return cleared
    }

    return AttachPickerSelection(
        focusedKey = cursor.focused?.takeIf(keys::contains),
        keyboardFocus = keyboardFocus,
        selectedKeys = state.selection.toHashSet(),
        focus = { key ->
            cursor = AttachSelectionShortcuts.focus(cursor, key, pointer = pointerFocus)
            if (!pointerFocus) keyboardFocus = true
        },
        pointerStarted = { pointerFocus = true; keyboardFocus = false },
        click = { key, shift, control ->
            pointerFocus = true; keyboardFocus = false
            apply { selection -> AttachSelectionShortcuts.click(cursor, selection, keys, key, shift, control) }
        },
        key = key@{ key, event ->
            val shortcut = AttachSelectionShortcuts.decode(event) ?: return@key false
            if (key !in keys) return@key false
            pointerFocus = false; keyboardFocus = true
            when (shortcut.command) {
                AttachSelectionCommand.ALL -> {
                    if (event.repeatCount == 0) apply { current ->
                        AttachSelectionChange(AttachSelection.add(current, keys), AttachSelectionCursor(keys.first(), key))
                    }
                }
                AttachSelectionCommand.CLEAR -> return@key clear()
                AttachSelectionCommand.TOGGLE -> {
                    if (event.repeatCount == 0) apply { current ->
                        AttachSelectionShortcuts.click(cursor, current, keys, key, shift = false, control = false)
                    }
                }
                else -> apply { current ->
                    val from = if (cursor.focused?.let(keys::contains) == true) cursor else cursor.copy(focused = key)
                    AttachSelectionShortcuts.move(from, current, keys, shortcut, if (state.tab == AttachTab.MEDIA) 3 else 1)
                }
            }
            true
        },
        escape = escape@{ event ->
            if (event.flags and KeyEvent.FLAG_SOFT_KEYBOARD != 0) return@escape false
            // Merely observe Tab and other physical keys; their normal focus/control action still runs.
            if (event.action == KeyEvent.ACTION_DOWN) { pointerFocus = false; keyboardFocus = true }
            if (AttachSelectionShortcuts.decode(event)?.command != AttachSelectionCommand.CLEAR) return@escape false
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    if (escapeHeld) true
                    else clear().also { escapeHeld = it }
                }
                KeyEvent.ACTION_UP -> escapeHeld.also { escapeHeld = false }
                else -> false
            }
        },
    )
}

private class AttachPointerModifiers {
    var shift = false
    var control = false
    fun clear() { shift = false; control = false }
}

/** Adds no layout node: the existing clickable/toggleable remains the one accessible focus target. */
@Composable
internal fun AttachSelectionItem(
    key: String,
    input: AttachPickerSelection,
    shape: Shape,
    content: @Composable (Modifier, () -> Unit) -> Unit,
) {
    val requester = remember(key) { FocusRequester() }
    val modifiers = remember(key) { AttachPointerModifiers() }
    val pressedKeys = remember(key) { mutableSetOf<Int>() }
    var focused by remember(key) { mutableStateOf(false) }
    val liveInput by rememberUpdatedState(input)
    val colors = BridgeyTheme.colors
    LaunchedEffect(input.focusedKey) {
        if (input.focusedKey == key) requester.requestFocus()
    }
    val modifier = Modifier
        .focusRequester(requester)
        .onFocusChanged { state ->
            focused = state.isFocused
            if (state.isFocused) liveInput.focus(key)
        }
        .onPreviewKeyEvent { event ->
            val native = event.nativeKeyEvent
            when (native.action) {
                KeyEvent.ACTION_DOWN -> liveInput.key(key, native).also { if (it) pressedKeys += native.keyCode }
                KeyEvent.ACTION_UP -> pressedKeys.remove(native.keyCode)
                else -> false
            }
        }
        .pointerInput(key) {
            awaitPointerEventScope {
                while (true) {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    if (event.changes.any { it.changedToDownIgnoreConsumed() }) {
                        val flags = event.keyboardModifiers
                        modifiers.shift = flags.isShiftPressed && !flags.isAltPressed && !flags.isMetaPressed
                        modifiers.control = flags.isCtrlPressed && !flags.isAltPressed && !flags.isMetaPressed
                        liveInput.pointerStarted()
                    }
                    if (event.changes.any { it.changedToUpIgnoreConsumed() }) {
                        // The existing clickable reads the sampled modifiers in Main, before Final.
                        awaitPointerEvent(PointerEventPass.Final)
                        modifiers.clear()
                    }
                }
            }
        }
        .border(2.dp, if (focused && input.keyboardFocus) colors.primary else Color.Transparent, shape)
        .semantics { toggleableState = if (key in input.selectedKeys) ToggleableState.On else ToggleableState.Off }
    content(modifier) {
        val shift = modifiers.shift
        val control = modifiers.control
        modifiers.clear()
        input.click(key, shift, control)
    }
}
