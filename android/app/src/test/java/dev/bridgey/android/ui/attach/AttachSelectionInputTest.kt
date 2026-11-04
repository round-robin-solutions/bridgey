package dev.bridgey.android.ui.attach

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Real Android events through the production Compose modifier; isolated Activity, no device or files. */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [26, 35], application = Application::class)
class AttachSelectionInputTest {
    private fun settle() { repeat(4) { shadowOf(Looper.getMainLooper()).idleFor(16, TimeUnit.MILLISECONDS) } }

    @Test fun heldShiftMouseClicksAndControlSelectAllReachTheProductionSelectionHandler() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName(app, ComponentActivity::class.java))
        val state = AttachState(tab = AttachTab.FILES, documents = (0..7).map { index ->
            DocumentItem("fixture", "", "File $index", 1, 1, "text/plain", "content://fixture/$index", "Fixture")
        })
        val keys = AttachSelection.selectableKeys(state)
        val picks = mutableStateOf(emptyList<String>())
        val boxes = mutableMapOf<String, Rect>()
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    BridgeyTheme {
                        val input = rememberAttachPickerSelection(state.copy(selection = picks.value),
                            AttachActions(updateSelection = { reducer -> picks.value = reducer(picks.value) }))
                        Column {
                            keys.forEach { key ->
                                AttachSelectionItem(key, input, RoundedCornerShape(4.dp)) { modifier, click ->
                                    Box(modifier.size(40.dp).onGloballyPositioned { boxes[key] = it.boundsInWindow() }
                                        .toggleable(key in picks.value, role = Role.Checkbox, onValueChange = { click() }))
                                }
                            }
                        }
                    }
                }
            }
            settle()
            assertEquals(keys.size, boxes.size)
            fun click(index: Int, modifiers: Int) {
                val center = boxes.getValue(keys[index]).center
                scenario.onActivity { activity ->
                    val down = SystemClock.uptimeMillis()
                    listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).forEachIndexed { offset, action ->
                        val pointer = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_MOUSE }
                        val coordinates = MotionEvent.PointerCoords().apply { x = center.x; y = center.y; pressure = 1f; size = 1f }
                        val event = MotionEvent.obtain(down, down + offset, action, 1, arrayOf(pointer), arrayOf(coordinates),
                            modifiers, if (action == MotionEvent.ACTION_DOWN) MotionEvent.BUTTON_PRIMARY else 0,
                            1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0)
                        try { activity.dispatchTouchEvent(event) } finally { event.recycle() }
                    }
                }
                settle()
            }
            click(1, KeyEvent.META_SHIFT_ON)
            click(6, KeyEvent.META_SHIFT_ON)
            assertEquals(keys.subList(1, 7), picks.value)
            click(3, KeyEvent.META_CTRL_ON)
            assertEquals(keys.subList(1, 7).filterNot { it == keys[3] }, picks.value)
            scenario.onActivity { activity ->
                val at = SystemClock.uptimeMillis()
                listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP).forEach { action ->
                    assertTrue(activity.dispatchKeyEvent(KeyEvent(at, at, action, KeyEvent.KEYCODE_A, 0, KeyEvent.META_CTRL_ON)))
                }
            }
            settle()
            assertEquals(keys.toSet(), picks.value.toSet())
            assertEquals(keys.size, picks.value.size)
        }
    }
}
