package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * A row that appears or goes while its group is on screen (a feature switched on, a settings sync line) is drawn at
 * once, not only when the page opens again. Settings > Notifications showed this: turning forwarding on left its
 * access and apps rows out until the page was reopened.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class RowGroupTest {
    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    /** The shape every page uses: a value read above the group, captured by its rows. */
    @Composable
    private fun Page(on: Boolean, drawn: MutableList<String>) {
        RowGroup {
            row { Line("switch", drawn) }
            if (on) row { Line("detail", drawn) }
            row { Line("last", drawn) }
        }
    }

    @Composable
    private fun Line(name: String, drawn: MutableList<String>) {
        Text(name)
        SideEffect { drawn += name }
    }

    @Test
    fun aRowThatAppearsOrGoesWhileShownIsDrawnAtOnce() {
        val on = mutableStateOf(false)
        val drawn = mutableListOf<String>()
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { it.setContent { Page(on.value, drawn) } }
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(listOf("switch", "last"), drawn.distinct())

            drawn.clear()
            on.value = true
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            assertEquals("the new row is drawn while the page stays open", true, "detail" in drawn)

            drawn.clear()
            on.value = false
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            assertEquals("the row that went is not drawn again", false, "detail" in drawn)
        }
    }
}
