package dev.bridgey.android.ui.attach

import android.app.Application
import android.view.InputDevice
import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Real Android key objects, never a live keyboard, app window or media/account resource. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 35], application = Application::class)
class AttachSelectionKeyEventTest {
    private fun event(code: Int, modifiers: Int = 0, flags: Int = 0, action: Int = KeyEvent.ACTION_DOWN) =
        KeyEvent(1, 2, action, code, 0, modifiers, 1, 0, flags, InputDevice.SOURCE_KEYBOARD)

    @Test fun physicalLeftAndRightModifiersUseTheSameSelectionCommands() {
        assertEquals(AttachSelectionCommand.ALL,
            AttachSelectionShortcuts.decode(event(KeyEvent.KEYCODE_A, KeyEvent.META_CTRL_RIGHT_ON))?.command)
        assertEquals(AttachSelectionShortcut(AttachSelectionCommand.LAST, true, true),
            AttachSelectionShortcuts.decode(event(KeyEvent.KEYCODE_MOVE_END, KeyEvent.META_SHIFT_LEFT_ON or KeyEvent.META_CTRL_RIGHT_ON)))
    }

    @Test fun softKeyboardCancelledAndMultipleCharacterEventsAreNotSelectionShortcuts() {
        assertNull(AttachSelectionShortcuts.decode(event(KeyEvent.KEYCODE_A, KeyEvent.META_CTRL_ON, KeyEvent.FLAG_SOFT_KEYBOARD)))
        assertNull(AttachSelectionShortcuts.decode(event(KeyEvent.KEYCODE_ENTER, flags = KeyEvent.FLAG_CANCELED)))
        assertNull(AttachSelectionShortcuts.decode(event(KeyEvent.KEYCODE_A, KeyEvent.META_CTRL_ON, action = KeyEvent.ACTION_MULTIPLE)))
        assertNull(AttachSelectionShortcuts.decode(event(KeyEvent.KEYCODE_A, KeyEvent.META_CTRL_ON or KeyEvent.META_ALT_ON)))
    }
}
