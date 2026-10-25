package dev.bridgey.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import dev.bridgey.android.R

/*
 * Bridgey by Round Robin, design direction B "Stream" (picked by Rahul 2026-10-25).
 * Reference: pa outputs/bridgey/design/direction-b.html. Colours are the mockup's CSS variables,
 * which come from the Forms app's Midnight Aurora tokens (round-robin-forms ui/theme).
 */
object RoundRobinTokens {
    val AuroraBlue = Color(0xFF54C7F5)
    val AuroraGreen = Color(0xFF5EF2B2)
    val AuroraPurple = Color(0xFF9B7CFF)
    val Midnight = Color(0xFF050B18)
    val Frost = Color(0xFFF4F7FA)
    val MutedFrost = Color(0xFF9AA8B8)
}

/** The mockup's palette for one mode (or for the light mode midnight band). */
@Immutable
data class BridgeyColors(
    val isDark: Boolean,
    val background: Color,
    val surface1: Color,
    val surface2: Color,
    val surface3: Color,
    val surface4: Color,
    val onSurface: Color,
    val onSurfaceVariant: Color,
    val outline: Color,
    val outlineVariant: Color,
    val primary: Color,
    val onPrimary: Color,
    val good: Color,
    val warn: Color,
    val tintPurple: Color,
    val onTintPurple: Color,
    val tintBlue: Color,
    val onTintBlue: Color,
    val tintGreen: Color,
    val onTintGreen: Color,
    val switchOn: Color,
    val switchThumb: Color,
    val switchOff: Color,
    /** Gap drawn between a device ring and its glyph. */
    val ringGap: Color,
    /** Halo around the selected device ring. */
    val selectionHalo: Color,
    /** The floating send bar. */
    val composer: Color,
    val composerOutline: Color,
)

val DarkBridgeyColors = BridgeyColors(
    isDark = true,
    background = Color(0xFF050B18),
    surface1 = Color(0xFF0D1321),
    surface2 = Color(0xFF151C29),
    surface3 = Color(0xFF19202D),
    surface4 = Color(0xFF232A38),
    onSurface = Color(0xFFF4F7FA),
    onSurfaceVariant = Color(0xFF9AA8B8),
    outline = Color(0xFF2A303F),
    outlineVariant = Color(0xFF19202D),
    primary = Color(0xFF54C7F5),
    onPrimary = Color(0xFF050B18),
    good = Color(0xFF5EF2B2),
    warn = Color(0xFFFFB4A8),
    tintPurple = Color(0x299B7CFF),
    onTintPurple = Color(0xFFCDBDFF),
    tintBlue = Color(0x2654C7F5),
    onTintBlue = Color(0xFF6AD3FF),
    tintGreen = Color(0x215EF2B2),
    onTintGreen = Color(0xFF5EF2B2),
    switchOn = Color(0xFF54C7F5),
    switchThumb = Color(0xFF050B18),
    switchOff = Color(0xFF232A38),
    ringGap = Color(0xFF050B18),
    selectionHalo = Color(0x2654C7F5),
    composer = Color(0xFF151C29),
    composerOutline = Color.Transparent,
)

val LightBridgeyColors = BridgeyColors(
    isDark = false,
    background = Color(0xFFF4F7FA),
    surface1 = Color.White,
    surface2 = Color(0xFFEEF2F7),
    surface3 = Color(0xFFE6EBF2),
    surface4 = Color(0xFFDCE3EC),
    onSurface = Color(0xFF050B18),
    onSurfaceVariant = Color(0xFF4C5262),
    outline = Color(0xFFDDE3EB),
    outlineVariant = Color(0xFFE6EBF2),
    primary = Color(0xFF006685),
    onPrimary = Color.White,
    good = Color(0xFF006C49),
    warn = Color(0xFFB3261E),
    tintPurple = Color(0xFFEDE4FF),
    onTintPurple = Color(0xFF5A38BA),
    tintBlue = Color(0xFFDAF1FF),
    onTintBlue = Color(0xFF005A74),
    tintGreen = Color(0xFFCDFFE2),
    onTintGreen = Color(0xFF005236),
    switchOn = Color(0xFF006685),
    switchThumb = Color.White,
    switchOff = Color(0xFFDCE3EC),
    ringGap = Color.White,
    selectionHalo = Color(0xFFDAF1FF),
    composer = Color.White,
    composerOutline = Color(0xFFDDE3EB),
)

/** Light mode's midnight header band: the dark tokens, tuned as in the mockup's `.light .bz`. */
val BandBridgeyColors = DarkBridgeyColors.copy(
    surface3 = Color(0xFF1B2333),
    tintPurple = Color(0x339B7CFF),
    tintBlue = Color(0x2E54C7F5),
    tintGreen = Color(0x265EF2B2),
    selectionHalo = Color(0x5954C7F5),
)

val LocalBridgeyColors = staticCompositionLocalOf { DarkBridgeyColors }

/** True inside the light mode header band, so the band content uses [BandBridgeyColors]. */
val LocalOnBand = staticCompositionLocalOf { false }

object BridgeyTheme {
    val colors: BridgeyColors
        @Composable @ReadOnlyComposable get() = LocalBridgeyColors.current
}

val SpaceGrotesk = FontFamily(Font(R.font.space_grotesk_semibold, FontWeight.SemiBold))

val Inter = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
)

private const val INTER_FEATURES = "cv11, ss01"

/** Text styles from the mockup, in sp. Headings are Space Grotesk 600; everything people read or tap is Inter. */
object BridgeyType {
    private val body = TextStyle(fontFamily = Inter, fontFeatureSettings = INTER_FEATURES)
    private val heading = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.SemiBold)

    val brand = heading.copy(fontSize = 24.sp, lineHeight = 24.sp, letterSpacing = (-0.24).sp)
    val pageTitle = heading.copy(fontSize = 22.sp, lineHeight = 28.sp)
    val deviceName = heading.copy(fontSize = 24.sp, lineHeight = 30.sp)
    val cardTitle = heading.copy(fontSize = 20.sp, lineHeight = 26.sp)
    val brandSub = body.copy(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.22.sp)
    val section = body.copy(fontSize = 13.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.52.sp)
    val rowTitle = body.copy(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
    val itemTitle = body.copy(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold)
    val itemBody = body.copy(fontSize = 13.sp, lineHeight = 18.sp)
    val small = body.copy(fontSize = 12.sp, lineHeight = 16.sp)
    val smallStrong = body.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.SemiBold)
    val tiny = body.copy(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.SemiBold)
    val tinyLabel = body.copy(fontSize = 11.sp, lineHeight = 13.sp)
    val label = body.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold)
    val chip = body.copy(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium)
    val button = body.copy(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
    val field = body.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium)
    val bodyText = body.copy(fontSize = 14.sp, lineHeight = 20.sp)
}

private fun materialTypography(): Typography {
    val base = Typography()
    fun TextStyle.h() = copy(fontFamily = SpaceGrotesk, fontWeight = FontWeight.SemiBold)
    fun TextStyle.b() = copy(fontFamily = Inter, fontFeatureSettings = INTER_FEATURES)
    return Typography(
        displayLarge = base.displayLarge.h(),
        displayMedium = base.displayMedium.h(),
        displaySmall = base.displaySmall.h(),
        headlineLarge = base.headlineLarge.h(),
        headlineMedium = base.headlineMedium.h(),
        headlineSmall = base.headlineSmall.h(),
        titleLarge = base.titleLarge.h(),
        titleMedium = base.titleMedium.b(),
        titleSmall = base.titleSmall.b(),
        bodyLarge = base.bodyLarge.b(),
        bodyMedium = base.bodyMedium.b(),
        bodySmall = base.bodySmall.b(),
        labelLarge = base.labelLarge.b(),
        labelMedium = base.labelMedium.b(),
        labelSmall = base.labelSmall.b(),
    )
}

private val DarkScheme = darkColorScheme(
    primary = RoundRobinTokens.AuroraBlue,
    onPrimary = RoundRobinTokens.Midnight,
    primaryContainer = Color(0xFF112739),
    onPrimaryContainer = Color(0xFF6AD3FF),
    secondary = RoundRobinTokens.AuroraGreen,
    onSecondary = RoundRobinTokens.Midnight,
    secondaryContainer = Color(0xFF11292C),
    onSecondaryContainer = Color(0xFF5EF2B2),
    tertiary = RoundRobinTokens.AuroraPurple,
    onTertiary = RoundRobinTokens.Midnight,
    tertiaryContainer = Color(0xFF1D1D3D),
    onTertiaryContainer = Color(0xFFCDBDFF),
    background = RoundRobinTokens.Midnight,
    onBackground = RoundRobinTokens.Frost,
    surface = RoundRobinTokens.Midnight,
    onSurface = RoundRobinTokens.Frost,
    surfaceVariant = Color(0xFF19202D),
    onSurfaceVariant = RoundRobinTokens.MutedFrost,
    surfaceContainerLowest = RoundRobinTokens.Midnight,
    surfaceContainerLow = Color(0xFF0D1321),
    surfaceContainer = Color(0xFF151C29),
    surfaceContainerHigh = Color(0xFF19202D),
    surfaceContainerHighest = Color(0xFF232A38),
    outline = Color(0xFF2A303F),
    outlineVariant = Color(0xFF232A38),
    error = Color(0xFFFFB4A8),
    onError = Color(0xFF690005),
)

private val LightScheme = lightColorScheme(
    primary = Color(0xFF006685),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDAF1FF),
    onPrimaryContainer = Color(0xFF005A74),
    secondary = Color(0xFF006C49),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFCDFFE2),
    onSecondaryContainer = Color(0xFF005236),
    tertiary = Color(0xFF6645C7),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFEDE4FF),
    onTertiaryContainer = Color(0xFF5A38BA),
    background = RoundRobinTokens.Frost,
    onBackground = RoundRobinTokens.Midnight,
    surface = RoundRobinTokens.Frost,
    onSurface = RoundRobinTokens.Midnight,
    surfaceVariant = Color(0xFFE6EBF2),
    onSurfaceVariant = Color(0xFF4C5262),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainer = Color(0xFFEEF2F7),
    surfaceContainerHigh = Color(0xFFF4F7FA),
    surfaceContainerHighest = Color(0xFFDCE3EC),
    outline = Color(0xFF8A93A3),
    outlineVariant = Color(0xFFDDE3EB),
    error = Color(0xFFB3261E),
)

/** App theme: follows the system light or dark setting; dark is the lead design. */
@Composable
fun BridgeyTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) DarkBridgeyColors else LightBridgeyColors
    MaterialTheme(colorScheme = if (dark) DarkScheme else LightScheme, typography = materialTypography()) {
        CompositionLocalProvider(
            LocalBridgeyColors provides colors,
            LocalContentColor provides colors.onSurface,
            LocalTextStyle provides TextStyle(fontFamily = Inter, fontFeatureSettings = INTER_FEATURES),
            content = content,
        )
    }
}

/** Content drawn on the light mode midnight band uses the band palette; dark mode is unchanged. */
@Composable
fun OnBand(content: @Composable () -> Unit) {
    val colors = LocalBridgeyColors.current
    if (colors.isDark) {
        content()
    } else {
        CompositionLocalProvider(
            LocalBridgeyColors provides BandBridgeyColors,
            LocalOnBand provides true,
            LocalContentColor provides BandBridgeyColors.onSurface,
            content = content,
        )
    }
}
