package dev.bridgey.android.ui.attach

import android.view.KeyEvent

/** One range anchor per visible tab. A range never removes picks from another tab. */
internal data class AttachSelectionCursor(
    val anchor: String? = null,
    val focused: String? = null,
    val rangeBase: List<String>? = null,
    val additiveRange: Boolean = false,
)

internal data class AttachSelectionChange(val selection: List<String>, val cursor: AttachSelectionCursor)

internal enum class AttachSelectionCommand { ALL, CLEAR, TOGGLE, PREVIOUS, NEXT, UP, DOWN, FIRST, LAST }

internal data class AttachSelectionShortcut(val command: AttachSelectionCommand, val extend: Boolean = false, val additive: Boolean = false)

internal object AttachSelectionShortcuts {
    /** Pointer focus can arrive before the click; it must not replace an existing Shift anchor. */
    fun focus(cursor: AttachSelectionCursor, key: String, pointer: Boolean): AttachSelectionCursor = when {
        cursor.focused == key -> cursor
        pointer -> cursor.copy(focused = key)
        else -> AttachSelectionCursor(anchor = key, focused = key)
    }

    fun decode(event: KeyEvent): AttachSelectionShortcut? {
        if (event.flags and KeyEvent.FLAG_SOFT_KEYBOARD != 0 || event.isCanceled ||
            event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return null
        val modifiers = KeyEvent.normalizeMetaState(event.metaState)
        return decode(event.keyCode, modifiers and KeyEvent.META_SHIFT_ON != 0, modifiers and KeyEvent.META_CTRL_ON != 0,
            modifiers and KeyEvent.META_ALT_ON != 0, modifiers and KeyEvent.META_META_ON != 0)
    }

    /** Physical keyboard commands only; Alt/Meta combinations and text/IME input retain their meaning. */
    fun decode(keyCode: Int, shift: Boolean = false, control: Boolean = false, alt: Boolean = false,
               meta: Boolean = false): AttachSelectionShortcut? {
        if (alt || meta) return null
        val command = when (keyCode) {
            KeyEvent.KEYCODE_A -> if (control && !shift) AttachSelectionCommand.ALL else return null
            KeyEvent.KEYCODE_ESCAPE -> if (!control && !shift) AttachSelectionCommand.CLEAR else return null
            KeyEvent.KEYCODE_SPACE, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_DPAD_CENTER ->
                if (!control && !shift) AttachSelectionCommand.TOGGLE else return null
            KeyEvent.KEYCODE_DPAD_LEFT -> AttachSelectionCommand.PREVIOUS
            KeyEvent.KEYCODE_DPAD_RIGHT -> AttachSelectionCommand.NEXT
            KeyEvent.KEYCODE_DPAD_UP -> AttachSelectionCommand.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> AttachSelectionCommand.DOWN
            KeyEvent.KEYCODE_MOVE_HOME -> AttachSelectionCommand.FIRST
            KeyEvent.KEYCODE_MOVE_END -> AttachSelectionCommand.LAST
            else -> return null
        }
        return AttachSelectionShortcut(command, extend = shift, additive = control && shift)
    }

    fun click(cursor: AttachSelectionCursor, selection: List<String>, keys: List<String>, key: String,
              shift: Boolean, control: Boolean): AttachSelectionChange {
        if (key !in keys) return AttachSelectionChange(selection, cursor)
        if (!shift) return AttachSelectionChange(AttachSelection.toggle(selection, key), AttachSelectionCursor(key, key))
        val anchor = cursor.anchor?.takeIf(keys::contains) ?: key
        val from = if (cursor.anchor == anchor) cursor else cursor.copy(anchor = anchor, rangeBase = null)
        return range(from, selection, keys, key, additive = control)
    }

    fun move(cursor: AttachSelectionCursor, selection: List<String>, keys: List<String>, shortcut: AttachSelectionShortcut,
             columns: Int): AttachSelectionChange {
        if (keys.isEmpty()) return AttachSelectionChange(selection, AttachSelectionCursor())
        val current = cursor.focused?.takeIf(keys::contains) ?: selection.lastOrNull(keys::contains) ?: keys.first()
        val index = keys.indexOf(current)
        val next = when (shortcut.command) {
            AttachSelectionCommand.PREVIOUS -> index - 1
            AttachSelectionCommand.NEXT -> index + 1
            AttachSelectionCommand.UP -> if (index >= columns.coerceAtLeast(1)) index - columns.coerceAtLeast(1) else index
            AttachSelectionCommand.DOWN -> if (index / columns.coerceAtLeast(1) == keys.lastIndex / columns.coerceAtLeast(1)) index
                else index + columns.coerceAtLeast(1)
            AttachSelectionCommand.FIRST -> 0
            AttachSelectionCommand.LAST -> keys.lastIndex
            else -> return AttachSelectionChange(selection, cursor)
        }.coerceIn(keys.indices)
        val key = keys[next]
        if (!shortcut.extend) return AttachSelectionChange(selection, AttachSelectionCursor(key, key))
        val anchor = cursor.anchor?.takeIf(keys::contains) ?: current
        val from = if (cursor.anchor == anchor) cursor else cursor.copy(anchor = anchor, rangeBase = null)
        return range(from, selection, keys, key, shortcut.additive)
    }

    private fun range(cursor: AttachSelectionCursor, selection: List<String>, keys: List<String>, key: String,
                      additive: Boolean): AttachSelectionChange {
        val anchor = cursor.anchor?.let(keys::indexOf) ?: -1
        val target = keys.indexOf(key)
        if (anchor < 0 || target < 0) return AttachSelectionChange(selection, cursor)
        val base = cursor.rangeBase?.takeIf { cursor.additiveRange == additive }
            ?: if (additive) selection else selection.filterNot { it.substringBefore(':') == key.substringBefore(':') }
        val range = keys.subList(minOf(anchor, target), maxOf(anchor, target) + 1)
        return AttachSelectionChange(AttachSelection.add(base, range),
            cursor.copy(focused = key, rangeBase = base, additiveRange = additive))
    }
}
