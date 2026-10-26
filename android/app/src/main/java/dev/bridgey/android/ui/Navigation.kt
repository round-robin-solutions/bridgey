package dev.bridgey.android.ui

import androidx.activity.BackEventCompat
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.MotionMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** The app's screens. Settings is a pushed page; the stream is the whole app. */
sealed interface Route {
    val key: String

    data object Home : Route {
        override val key = "home"
    }

    data class Device(val deviceId: String) : Route {
        override val key get() = "device:$deviceId"
    }

    /** Remote control of a Mac: touchpad, keyboard and slides. */
    data class Remote(val deviceId: String) : Route {
        override val key get() = "remote:$deviceId"
    }

    data object Settings : Route {
        override val key = "settings"
    }

    data object Devices : Route {
        override val key = "devices"
    }

    data object NotificationApps : Route {
        override val key = "notification_apps"
    }

    data object PerfTest : Route {
        override val key = "perf_test"
    }

    companion object {
        fun fromKey(key: String): Route? = when {
            key == Home.key -> Home
            key == Settings.key -> Settings
            key == Devices.key -> Devices
            key == NotificationApps.key -> NotificationApps
            key == PerfTest.key -> PerfTest
            key.startsWith("device:") -> Device(key.removePrefix("device:"))
            key.startsWith("remote:") -> Remote(key.removePrefix("remote:"))
            else -> null
        }
    }
}

class BackStack(initial: List<Route>) {
    val entries: SnapshotStateList<Route> = initial.toMutableStateList()
    val top: Route get() = entries.last()

    fun push(route: Route) {
        if (top != route) entries += route
    }

    fun pop(): Boolean {
        if (entries.size <= 1) return false
        entries.removeAt(entries.lastIndex)
        return true
    }

    /** Drops pages for devices that no longer exist, e.g. after Forget. */
    fun removeWhere(predicate: (Route) -> Boolean) {
        val kept = entries.filterIndexed { index, route -> index == 0 || !predicate(route) }
        if (kept.size != entries.size) {
            entries.clear()
            entries.addAll(kept)
        }
    }
}

@Composable
fun rememberBackStack(): BackStack = rememberSaveable(
    saver = listSaver(
        save = { stack -> stack.entries.map { it.key } },
        restore = { keys -> BackStack(keys.mapNotNull(Route::fromKey).ifEmpty { listOf(Route.Home) }) },
    ),
) { BackStack(listOf(Route.Home)) }

/**
 * Shows the top of [stack]. A pushed page comes in on a shared axis (15 % of the width on the page
 * spring) while the page behind recedes to 0.95 under an 0.18 dim; back reverses it, and the
 * predictive back gesture scrubs it. Reduced motion cross-fades; animator scale 0 cuts.
 * Transform and opacity only.
 */
@Composable
fun MotionNavHost(stack: BackStack, content: @Composable (Route) -> Unit) {
    val motion = LocalMotion.current
    val holder = rememberSaveableStateHolder()
    val scope = rememberCoroutineScope()
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    // Progress of the top page: 1 shown, 0 gone.
    val progress = remember { Animatable(1f) }
    var shown by remember { mutableStateOf(stack.entries.toList()) }
    var popping by remember { mutableStateOf<Route?>(null) }

    val current = stack.entries.toList()
    LaunchedEffect(current) {
        val before = shown
        when {
            current.size > before.size && current.dropLast(1) == before -> {
                shown = current
                if (motion.mode == MotionMode.Instant) {
                    progress.snapTo(1f)
                } else {
                    progress.snapTo(0f)
                    progress.animateTo(1f, motion.page.takeIf { motion.moves }?.spec() ?: motion.fadeSpec())
                }
            }
            current.size < before.size && before.take(current.size) == current -> {
                val leaving = before.last()
                popping = leaving
                if (motion.mode != MotionMode.Instant) {
                    progress.animateTo(0f, motion.page.takeIf { motion.moves }?.spec() ?: motion.fadeSpec())
                }
                before.drop(current.size).forEach { holder.removeState(it.key) }
                popping = null
                shown = current
                progress.snapTo(1f)
            }
            else -> {
                (before - current.toSet()).forEach { holder.removeState(it.key) }
                shown = current
                progress.snapTo(1f)
            }
        }
    }

    PredictiveBackHandler(enabled = current.size > 1) { events ->
        try {
            events.collect { event: BackEventCompat -> progress.snapTo(1f - event.progress) }
            stack.pop()
        } catch (cancelled: CancellationException) {
            scope.launch { progress.animateTo(1f, motion.page.takeIf { motion.moves }?.spec() ?: motion.fadeSpec()) }
            throw cancelled
        }
    }

    val pages = shown
    val top = pages.last()
    val below = pages.getOrNull(pages.lastIndex - 1)
    Box(Modifier.fillMaxSize()) {
        val p = progress.value
        if (below != null && (p < 1f || progress.isRunning || popping != null)) {
            key(below.key) {
                Box(
                    Modifier.fillMaxSize().graphicsLayer {
                        if (motion.moves) {
                            val s = 1f - (1f - motion.recedeScale) * p.coerceIn(0f, 1f)
                            scaleX = s
                            scaleY = s
                        }
                    },
                ) {
                    holder.SaveableStateProvider(below.key) { content(below) }
                    if (motion.moves) {
                        Box(Modifier.fillMaxSize().graphicsLayer { alpha = motion.recedeDim * p.coerceIn(0f, 1f) }.background(Color.Black))
                    }
                }
            }
        }
        key(top.key) {
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    val v = progress.value
                    alpha = v.coerceIn(0f, 1f)
                    if (motion.moves) translationX = (1f - v) * size.width * motion.pageSlideFraction * (if (rtl) -1f else 1f)
                },
            ) {
                holder.SaveableStateProvider(top.key) { content(top) }
            }
        }
    }
}
