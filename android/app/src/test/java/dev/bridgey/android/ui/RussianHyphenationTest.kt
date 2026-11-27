package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.LocalTextStyle
import androidx.compose.ui.text.style.Hyphens
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Russian text breaks long words with a hyphen ("Автоматиче-ский"); English keeps its wrapping. Robolectric has no
 * hyphenation patterns to draw it, so this checks the styles; the emulator screenshots show the result.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class RussianHyphenationTest {
    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun styles(): List<Hyphens> {
        var found = emptyList<Hyphens>()
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    BridgeyTheme {
                        found = listOf(BridgeyType.rowTitle.hyphens, BridgeyType.itemBody.hyphens, BridgeyType.label.hyphens, LocalTextStyle.current.hyphens)
                    }
                }
            }
            shadowOf(Looper.getMainLooper()).idle()
        }
        return found
    }

    @Test @Config(qualifiers = "ru")
    fun russianHyphenates() = assertEquals(List(4) { Hyphens.Auto }, styles())

    @Test @Config(qualifiers = "en-rGB")
    fun englishDoesNot() = styles().also { assertEquals(4, it.size) }.forEach { assertNotEquals(Hyphens.Auto, it) }
}
