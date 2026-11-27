package dev.bridgey.android.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import dev.bridgey.android.ui.theme.BridgeyColors
import dev.bridgey.android.ui.theme.DarkBridgeyColors
import dev.bridgey.android.ui.theme.LightBridgeyColors
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A text field's edge is what shows where to type, so it needs 3:1 against what is behind it (WCAG 1.4.11), in light
 * and dark. Every field's border is onSurfaceVariant (bridgeyTextFieldColors, fieldBorderColor).
 */
class TextFieldContrastTest {
    private fun ratio(a: Color, b: Color): Double {
        val (light, dark) = listOf(a.luminance().toDouble(), b.luminance().toDouble()).sortedDescending()
        return (light + 0.05) / (dark + 0.05)
    }

    private fun backgrounds(colors: BridgeyColors) =
        mapOf("background" to colors.background, "surface1" to colors.surface1, "surface2" to colors.surface2, "composer" to colors.composer)

    @Test fun fieldBordersStandOutInLightAndDark() {
        for ((name, colors) in listOf("light" to LightBridgeyColors, "dark" to DarkBridgeyColors)) {
            for ((where, behind) in backgrounds(colors)) {
                val contrast = ratio(colors.onSurfaceVariant, behind)
                assertTrue("$name: field border on $where is ${"%.2f".format(contrast)}:1", contrast >= 3.0)
            }
        }
    }
}
