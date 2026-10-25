package dev.bridgey.android.ui.theme

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/*
 * Adapted from round-robin-forms ui/theme/AuroraBrushes.kt and MidnightAurora.kt.
 */

/** One radial glow: a colour at [alpha] fading to clear, centred at a fraction of the layer. */
data class GlowSpot(
    val color: Color,
    val alpha: Float,
    val centerX: Float,
    val centerY: Float,
    val radiusX: Dp,
    val radiusY: Dp,
)

object Aurora {
    /** The ring, in the mockup's order: purple, blue, green. */
    val Ring = listOf(RoundRobinTokens.AuroraPurple, RoundRobinTokens.AuroraBlue, RoundRobinTokens.AuroraGreen)

    private val ButtonStops = listOf(
        0f to RoundRobinTokens.AuroraPurple,
        0.55f to RoundRobinTokens.AuroraBlue,
        1f to RoundRobinTokens.AuroraGreen,
    )
    private const val BUTTON_DEGREES = 100f
    private const val RING_START_DEGREES = 200f

    /** Text and icons over the gradient buttons, in both modes. */
    val OnGradient = RoundRobinTokens.Midnight

    /** Dark mode backdrop, painted once behind each screen. */
    val DarkGlow = listOf(
        GlowSpot(RoundRobinTokens.AuroraPurple, 0.22f, 0f, 0f, 420.dp, 260.dp),
        GlowSpot(RoundRobinTokens.AuroraBlue, 0.16f, 1f, 0.06f, 380.dp, 240.dp),
        GlowSpot(RoundRobinTokens.AuroraGreen, 0.07f, 0.6f, 1f, 360.dp, 220.dp),
    )

    /** Light mode header band glow. */
    val BandGlow = listOf(
        GlowSpot(RoundRobinTokens.AuroraPurple, 0.30f, 0f, 0f, 300.dp, 200.dp),
        GlowSpot(RoundRobinTokens.AuroraBlue, 0.22f, 1f, 0f, 300.dp, 200.dp),
    )

    val BandCorner = 28.dp

    /** Device ring for "connected, same Wi-Fi": a sweep of purple, blue, green, from 200 degrees. */
    fun ringSweep(center: Offset = Offset.Unspecified): Brush {
        val colors = Ring + Ring.first()
        // Brush.sweepGradient starts at 3 o'clock; CSS conic angles start at 12 o'clock.
        val shift = ((RING_START_DEGREES - 90f) / 360f).mod(1f)
        val stops = colors.mapIndexed { i, c -> ((i.toFloat() / (colors.size - 1)) + shift).mod(1f) to c }
            .sortedBy { it.first }
        val first = stops.first()
        val last = stops.last()
        val padded = buildList {
            if (first.first > 0f) add(0f to lerpStop(last, first))
            addAll(stops)
            if (last.first < 1f) add(1f to lerpStop(last, first))
        }
        return Brush.sweepGradient(colorStops = padded.toTypedArray(), center = center)
    }

    /** Selected tab underline and other thin accents: purple to green. */
    fun ringHorizontal(): Brush = Brush.horizontalGradient(Ring)

    /** Main buttons at the mockup's 100 degree angle. */
    fun button(size: Size): Brush {
        val css = BUTTON_DEGREES * PI.toFloat() / 180f
        val length = abs(size.width * sin(css)) + abs(size.height * cos(css))
        val rad = css - PI.toFloat() / 2f
        val half = Offset(cos(rad) * length / 2f, sin(rad) * length / 2f)
        val c = Offset(size.width / 2f, size.height / 2f)
        return Brush.linearGradient(colorStops = ButtonStops.toTypedArray(), start = c - half, end = c + half)
    }

    private fun lerpStop(a: Pair<Float, Color>, b: Pair<Float, Color>): Color {
        val span = (b.first + 1f) - a.first
        val t = if (span == 0f) 0f else (1f - a.first) / span
        return lerp(a.second, b.second, t)
    }
}

/** Paints glow spots. Static: drawn once per size change, never animated. */
fun DrawScope.drawGlow(spots: List<GlowSpot>) {
    spots.forEach { spot ->
        val rx = spot.radiusX.toPx()
        val ry = spot.radiusY.toPx()
        val center = Offset(size.width * spot.centerX, size.height * spot.centerY)
        scale(scaleX = 1f, scaleY = ry / rx, pivot = center) {
            drawCircle(
                brush = Brush.radialGradient(
                    0f to spot.color.copy(alpha = spot.alpha),
                    0.7f to spot.color.copy(alpha = 0f),
                    center = center,
                    radius = rx,
                ),
                radius = rx,
                center = center,
            )
        }
    }
}

/**
 * A screen's fixed background: midnight with the aurora glow in dark mode; frost with a
 * midnight band of [bandHeight] (status bar included) in light mode. Opaque, so a screen
 * sliding over another never shows the one behind.
 */
@Composable
fun ScreenBackdrop(bandHeight: Dp, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val colors = BridgeyTheme.colors
    Box(
        modifier.fillMaxSize().drawBehind {
            drawRect(colors.background)
            if (colors.isDark) {
                drawGlow(Aurora.DarkGlow)
            } else {
                val h = bandHeight.toPx()
                val r = Aurora.BandCorner.toPx()
                val band = Path().apply {
                    addRoundRect(
                        RoundRect(
                            0f, 0f, size.width, h,
                            topLeftCornerRadius = CornerRadius.Zero, topRightCornerRadius = CornerRadius.Zero,
                            bottomRightCornerRadius = CornerRadius(r, r), bottomLeftCornerRadius = CornerRadius(r, r),
                        ),
                    )
                }
                clipPath(band) {
                    drawRect(RoundRobinTokens.Midnight)
                    drawGlow(Aurora.BandGlow)
                }
            }
        },
    ) { content() }
}
