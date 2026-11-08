package dev.bridgey.android.ui.attach

import android.view.KeyEvent
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.MediaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AttachSelectionShortcutsTest {
    private val keys = (0..9).map { "m:$it" }

    private class Picks(val keys: List<String>, var selected: List<String> = emptyList()) {
        var cursor = AttachSelectionCursor()
        fun click(index: Int, shift: Boolean = false, control: Boolean = false) {
            val change = AttachSelectionShortcuts.click(cursor, selected, keys, keys[index], shift, control)
            selected = change.selection; cursor = change.cursor
        }
        fun move(command: AttachSelectionCommand, shift: Boolean = false, control: Boolean = false, columns: Int = 1) {
            val change = AttachSelectionShortcuts.move(cursor, selected, keys, AttachSelectionShortcut(command, shift, control && shift), columns)
            selected = change.selection; cursor = change.cursor
        }
    }

    @Test fun holdingShiftFromTheFirstClickSelectsTheWholeInclusiveRange() {
        val picks = Picks(keys)
        picks.click(1, shift = true)
        picks.click(6, shift = true)
        assertEquals(keys.subList(1, 7), picks.selected)
        assertEquals(keys[1], picks.cursor.anchor)
    }

    @Test fun pointerFocusBeforeShiftClickCannotReplaceTheOriginalAnchor() {
        val picks = Picks(keys)
        picks.click(2)
        picks.cursor = AttachSelectionShortcuts.focus(picks.cursor, keys[7], pointer = true)
        picks.click(7, shift = true)
        assertEquals(keys.subList(2, 8), picks.selected)
        picks.cursor = AttachSelectionShortcuts.focus(picks.cursor, keys[4], pointer = false)
        assertEquals("a fresh keyboard Tab focus starts its own range", keys[4], picks.cursor.anchor)
    }

    @Test fun reverseRangesShrinkAndCrossTheAnchorWithoutDroppingOtherTabs() {
        val picks = Picks(keys, listOf("d:other"))
        picks.click(5)
        picks.click(2, shift = true)
        assertEquals(listOf("d:other") + keys.subList(2, 6), picks.selected)
        picks.click(4, shift = true)
        assertEquals(listOf("d:other") + keys.subList(4, 6), picks.selected)
        picks.click(8, shift = true)
        assertEquals(listOf("d:other") + keys.subList(5, 9), picks.selected)
        assertEquals(keys[5], picks.cursor.anchor)
    }

    @Test fun controlShiftAddsAndShrinksARangeWhileKeepingEarlierSeparatePicks() {
        val picks = Picks(keys, listOf(keys[0], keys[9], "d:other"))
        picks.click(3, control = true)
        picks.click(6, shift = true, control = true)
        assertEquals(listOf(keys[0], keys[9], "d:other") + keys.subList(3, 7), picks.selected)
        picks.click(4, shift = true, control = true)
        assertEquals(listOf(keys[0], keys[9], "d:other", keys[3], keys[4]), picks.selected)
        picks.click(5, shift = true)
        assertEquals(listOf("d:other") + keys.subList(3, 6), picks.selected)
    }

    @Test fun ordinaryAndControlClicksKeepExistingToggleAndPickOrder() {
        val picks = Picks(keys)
        picks.click(4); picks.click(1, control = true); picks.click(7)
        picks.click(1, control = true)
        assertEquals(listOf(keys[4], keys[7]), picks.selected)
        assertEquals(mapOf(keys[4] to 1, keys[7] to 2), AttachSelection.order(picks.selected))
    }

    @Test fun selectAllAddsLoadedDisplayOrderWithoutDuplicatesOrReorderingEarlierPicks() {
        val selected = listOf("d:other", keys[4], keys[1])
        assertEquals(selected + keys.filterNot(selected::contains), AttachSelection.add(selected, keys))
    }

    @Test fun rangeAndSelectAllRespectTheExistingCapIncludingPicksFromOtherTabs() {
        val other = (1..99).map { "d:$it" }
        val picks = Picks(keys, other)
        picks.cursor = AttachSelectionCursor(anchor = keys[0], focused = keys[0])
        picks.click(5, shift = true)
        assertEquals(other + keys[0], picks.selected)
        assertEquals(AttachSelection.MAX, AttachSelection.add(other, keys).size)
        assertEquals(other + keys[0], AttachSelection.add(other, keys))
    }

    @Test fun aVanishedAnchorCannotReviveItsOldRangeBase() {
        val stale = AttachSelectionCursor("m:gone", "m:gone", listOf("d:other", "m:gone"))
        val change = AttachSelectionShortcuts.click(stale, listOf("d:other", "m:gone"), keys, keys[4], true, false)
        assertEquals(listOf("d:other", keys[4]), change.selection)
        assertEquals(keys[4], change.cursor.anchor)
    }

    @Test fun unavailableKeysAreNeverAddedOrUsedAsARangeEndpoint() {
        val cursor = AttachSelectionCursor(keys[1], keys[1])
        val change = AttachSelectionShortcuts.click(cursor, listOf(keys[1]), keys, "m:unavailable", true, true)
        assertEquals(listOf(keys[1]), change.selection)
        assertEquals(cursor, change.cursor)
    }

    @Test fun onlyAvailableSupportedFoldersAreSelectable() {
        val state = AttachState(tab = AttachTab.FOLDERS, canSendFolders = true, folders = listOf(
            AttachFolder("available", "Ready", null, true), AttachFolder("missing", "Unavailable", null, false)))
        assertEquals(listOf("f:available"), AttachSelection.selectableKeys(state))
        assertEquals(emptyList<String>(), AttachSelection.selectableKeys(state.copy(canSendFolders = false)))
    }

    @Test fun mediaWithoutAnAccessGrantCannotBeSelectedByShortcut() {
        val media = MediaItem(1, "Photo.jpg", 1, 1, 1, "image/jpeg", 1, 1, null, "Camera", "content://media/1")
        val state = AttachState(media = listOf(media), mediaAccess = MediaAccess.NONE)
        assertEquals(emptyList<String>(), AttachSelection.selectableKeys(state))
        assertEquals(listOf("m:1"), AttachSelection.selectableKeys(state.copy(mediaAccess = MediaAccess.PARTIAL)))
    }

    @Test fun keyboardRangesStartFromFocusAndExtendByTheActualGridRowWidth() {
        val picks = Picks(keys, listOf("d:other"))
        picks.cursor = AttachSelectionCursor(focused = keys[1])
        picks.move(AttachSelectionCommand.DOWN, shift = true, columns = 3)
        assertEquals(listOf("d:other") + keys.subList(1, 5), picks.selected)
        picks.move(AttachSelectionCommand.UP, shift = true, columns = 3)
        assertEquals(listOf("d:other", keys[1]), picks.selected)
        picks.move(AttachSelectionCommand.UP, columns = 3)
        assertEquals("Up on the first row must not move sideways", keys[1], picks.cursor.focused)
    }

    @Test fun homeEndAndPlainArrowsMoveFocusWithoutSilentlyTogglingPicks() {
        val picks = Picks(keys, listOf("d:other"))
        picks.cursor = AttachSelectionCursor(focused = keys[4])
        picks.move(AttachSelectionCommand.FIRST)
        assertEquals(listOf("d:other"), picks.selected)
        picks.move(AttachSelectionCommand.LAST, shift = true)
        assertEquals(listOf("d:other") + keys, picks.selected)
        picks.move(AttachSelectionCommand.PREVIOUS, shift = true)
        assertEquals(listOf("d:other") + keys.dropLast(1), picks.selected)
    }

    @Test fun shortcutsUseControlAndLeaveOtherModifierAndTypingCombinationsAlone() {
        assertEquals(AttachSelectionCommand.ALL, AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_A, control = true)?.command)
        assertNull(AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_A))
        assertNull(AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_A, control = true, shift = true))
        assertNull(AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_A, control = true, alt = true))
        assertNull(AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_DPAD_DOWN, meta = true))
        assertEquals(AttachSelectionShortcut(AttachSelectionCommand.NEXT, true, true),
            AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_DPAD_RIGHT, shift = true, control = true))
        assertEquals(AttachSelectionCommand.CLEAR, AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_ESCAPE)?.command)
        assertEquals(AttachSelectionCommand.TOGGLE, AttachSelectionShortcuts.decode(KeyEvent.KEYCODE_SPACE)?.command)
    }
}
