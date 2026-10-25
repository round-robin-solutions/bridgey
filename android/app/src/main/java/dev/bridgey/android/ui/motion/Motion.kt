package dev.bridgey.android.ui.motion

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min

/*
 * Motion tokens, adapted from round-robin-forms ui/motion (MotionTokens.kt, MicroMotion.kt,
 * LocalMotion.kt). Bridgey uses the Expressive Snap direction only, with the values in the
 * direction B motion table. Only transform and opacity animate.
 */

/** A spring as Compose takes it (mass 1). */
data class SpringToken(val dampingRatio: Float, val stiffness: Float) {
    fun <T> spec(visibilityThreshold: T? = null): SpringSpec<T> = spring(dampingRatio, stiffness, visibilityThreshold)
}

data class TweenToken(val durationMillis: Int, val easing: Easing)

enum class MotionMode {
    /** Everything on. */
    Full,

    /** Reduce motion: screens cross-fade in 150 ms; nothing moves, scales or bounces. */
    Fade,

    /** System animator scale 0: every change is instant. */
    Instant,
}

data class MotionSpec(
    val mode: MotionMode,
    /** Pushed pages and the stream swap: shared axis. */
    val page: SpringToken,
    val pageSlideFraction: Float,
    /** Tab underline edges, items sliding down, menus settling. */
    val small: SpringToken,
    val smallTrail: SpringToken,
    /** Opacity. */
    val effects: SpringToken,
    /** New stream item, selected ring, menus popping in. */
    val pop: SpringToken,
    /** Pressed buttons. */
    val press: SpringToken,
    val pressScaleButton: Float,
    /** The screen behind a pushed page. */
    val recedeScale: Float,
    val recedeDim: Float,
    /** The cross-fade used when motion is reduced. */
    val fade: TweenToken,
    /** New stream item: how far above it starts and how small. */
    val arriveRise: Dp,
    val arriveScale: Float,
) {
    val moves: Boolean get() = mode == MotionMode.Full

    fun <T> spatial(token: SpringToken, visibilityThreshold: T? = null): FiniteAnimationSpec<T> =
        if (moves) token.spec(visibilityThreshold) else snap()

    fun <T> fadeSpec(): FiniteAnimationSpec<T> = when (mode) {
        MotionMode.Instant -> snap()
        MotionMode.Fade -> tween(fade.durationMillis, easing = fade.easing)
        MotionMode.Full -> effects.spec()
    }
}

object MotionTokens {
    /** HarmonyOS Sharp curve: cubic-bezier(0.33, 0, 0.67, 1). */
    val Sharp: Easing = CubicBezierEasing(0.33f, 0f, 0.67f, 1f)

    /** "Expressive Snap": Material 3 Expressive springs, as in the Forms app and the motion table. */
    val ExpressiveSnap = MotionSpec(
        mode = MotionMode.Full,
        page = SpringToken(0.8f, 380f),
        pageSlideFraction = 0.15f,
        small = SpringToken(0.6f, 800f),
        smallTrail = SpringToken(0.6f, 800f),
        effects = SpringToken(1f, 1600f),
        pop = SpringToken(0.5f, 600f),
        press = SpringToken(0.6f, 800f),
        pressScaleButton = 0.92f,
        recedeScale = 0.95f,
        recedeDim = 0.18f,
        fade = TweenToken(150, Sharp),
        arriveRise = 24.dp,
        arriveScale = 0.7f,
    )

    fun reduced(base: MotionSpec): MotionSpec = base.copy(mode = MotionMode.Fade, fade = TweenToken(150, Sharp))

    fun instant(base: MotionSpec): MotionSpec = base.copy(mode = MotionMode.Instant, fade = TweenToken(0, Sharp))
}

/**
 * The motion the app uses. [animatorScale] is Android's animator duration scale ("Remove
 * animations" sets it to 0); [reduceMotion] is the in-app setting. Scale 0 wins.
 */
fun resolveMotion(animatorScale: Float, reduceMotion: Boolean): MotionSpec = when {
    animatorScale <= 0f -> MotionTokens.instant(MotionTokens.ExpressiveSnap)
    reduceMotion -> MotionTokens.reduced(MotionTokens.ExpressiveSnap)
    else -> MotionTokens.ExpressiveSnap
}

val LocalMotion = staticCompositionLocalOf { MotionTokens.ExpressiveSnap }

/** Android's animator duration scale, kept up to date while the UI is shown. */
@Composable
fun rememberAnimatorScale(): Float {
    val resolver = LocalContext.current.contentResolver
    fun read() = Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
    var scale by remember(resolver) { mutableFloatStateOf(read()) }
    DisposableEffect(resolver) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                scale = read()
            }
        }
        resolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer)
        onDispose { resolver.unregisterContentObserver(observer) }
    }
    return scale
}

/** Buttons sink a little while pressed and spring back on release. */
@Composable
fun Modifier.pressScale(interactionSource: InteractionSource): Modifier {
    val motion = LocalMotion.current
    val scale = remember { Animatable(1f) }
    LaunchedEffect(interactionSource, motion) {
        if (!motion.moves) return@LaunchedEffect
        interactionSource.interactions.collect { interaction ->
            when (interaction) {
                is PressInteraction.Press -> launch { scale.animateTo(motion.pressScaleButton, motion.press.spec()) }
                is PressInteraction.Release, is PressInteraction.Cancel -> launch {
                    val target = motion.pressScaleButton
                    if (scale.value > 1f - (1f - target) / 2f) scale.animateTo(target, SpringToken(1f, 3000f).spec())
                    scale.animateTo(1f, motion.press.spec())
                }
            }
        }
    }
    return graphicsLayer {
        scaleX = scale.value
        scaleY = scale.value
    }
}

/** Selected ring: pops from 0.92 on the pop spring when it becomes selected (never on first show). */
@Composable
fun Modifier.selectionPop(selected: Boolean): Modifier {
    val motion = LocalMotion.current
    val scale = remember { Animatable(1f) }
    var first by remember { mutableStateOf(true) }
    LaunchedEffect(selected) {
        if (first) {
            first = false
        } else if (selected && motion.moves) {
            scale.snapTo(0.92f)
            scale.animateTo(1f, motion.pop.spec())
        }
    }
    return graphicsLayer {
        scaleX = scale.value
        scaleY = scale.value
    }
}

/** Something appearing in place (a menu, a snackbar) springs in from [fromScale] with a [rise]. */
@Composable
fun Modifier.springIn(fromScale: Float = 0.85f, rise: Dp = 24.dp): Modifier {
    val motion = LocalMotion.current
    val progress = remember { Animatable(if (motion.moves) 0f else 1f) }
    val alpha = remember { Animatable(if (motion.mode == MotionMode.Instant) 1f else 0f) }
    LaunchedEffect(Unit) {
        launch { progress.animateTo(1f, motion.pop.spec()) }
        alpha.animateTo(1f, motion.fadeSpec())
    }
    return graphicsLayer {
        val p = progress.value
        val s = fromScale + (1f - fromScale) * p
        scaleX = s
        scaleY = s
        this.alpha = alpha.value
        translationY = (1f - p) * rise.toPx()
    }
}

/** Switching tabs: shared axis, a tenth of the width toward the new tab's side. */
fun MotionSpec.tabContentTransform(forward: Boolean): ContentTransform {
    val transform = when (mode) {
        MotionMode.Instant -> EnterTransition.None togetherWith ExitTransition.None
        MotionMode.Fade -> fadeIn(fadeSpec()) togetherWith fadeOut(fadeSpec())
        MotionMode.Full -> {
            val side = if (forward) 1 else -1
            val offset = page.spec(IntOffset.VisibilityThreshold)
            (slideInHorizontally(offset) { side * it / 10 } + fadeIn(effects.spec())) togetherWith
                (slideOutHorizontally(offset) { -side * it / 10 } + fadeOut(SpringToken(1f, effects.stiffness * 2).spec()))
        }
    }
    return ContentTransform(transform.targetContentEnter, transform.initialContentExit, sizeTransform = null)
}

/**
 * The tab underline: one bar that springs to the selected tab. Leading edge on [MotionSpec.small],
 * trailing edge on [MotionSpec.smallTrail]. Place it over the tab row (tabs of equal weight).
 */
@Composable
fun SpringTabIndicator(selected: Int, count: Int, brush: Brush, modifier: Modifier = Modifier, width: Dp = 56.dp, height: Dp = 3.dp) {
    val motion = LocalMotion.current
    val lead by animateFloatAsState(selected.toFloat(), motion.spatial(motion.small, 0.001f), label = "tabLead")
    val trail by animateFloatAsState(selected.toFloat(), motion.spatial(motion.smallTrail, 0.001f), label = "tabTrail")
    var rowWidth by remember { mutableIntStateOf(0) }
    Box(modifier.onSizeChanged { rowWidth = it.width }) {
        Box(
            Modifier
                .align(Alignment.BottomStart)
                .size(width, height)
                .graphicsLayer {
                    if (rowWidth == 0 || count == 0) {
                        alpha = 0f
                        return@graphicsLayer
                    }
                    val tab = rowWidth / count.toFloat()
                    val bar = size.width
                    val from = min(lead, trail)
                    val to = max(lead, trail)
                    translationX = from * tab + (tab - bar) / 2f
                    scaleX = ((to - from) * tab + bar) / bar
                    transformOrigin = TransformOrigin(0f, 0.5f)
                }
                .clip(RoundedCornerShape(topStart = height, topEnd = height))
                .background(brush),
        )
    }
}
