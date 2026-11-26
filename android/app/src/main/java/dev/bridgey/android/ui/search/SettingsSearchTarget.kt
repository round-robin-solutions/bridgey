package dev.bridgey.android.ui.search

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.toSize
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.theme.BridgeyTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

/**
 * Where a search result points: a row titled [title] on the page whose route key is [routeKey]. [fallback] is the
 * switch to show instead when that row is hidden in the page's current state.
 */
data class SearchTarget(val routeKey: String, val title: String, val scope: String? = null, val token: Long, val fallback: String? = null)

/**
 * Settings search across the app: the result that was chosen (the page scrolls to its row, which then
 * highlights briefly) and, in tests, a recorder of every row drawn. One per activity, given to every page
 * through [LocalSettingsSearch]; rows outside it cost nothing.
 */
class SettingsSearchHost {
    var pending by mutableStateOf<SearchTarget?>(null)
        private set
    private var nextToken = 1L

    /** The target's row has been drawn on its page (its token). */
    internal var located by mutableLongStateOf(0L)

    /** The page has scrolled the row into place: the highlight may play (its token). */
    internal var arrived by mutableLongStateOf(0L)

    /** Where the target's row is, in root coordinates, once drawn (unclipped: it may be below the visible part). */
    internal var rowBounds: Rect? = null

    /**
     * Tests: every row drawn, with its page (route key), scope, title, whether search offers it, and an object that
     * stays the same while the row stays drawn (rows record again when they recompose).
     */
    var recorder: ((route: String?, scope: String?, title: String, searchable: Boolean, row: Any) -> Unit)? = null

    fun open(routeKey: String, title: String, scope: String? = null, fallback: String? = null) {
        rowBounds = null
        pending = SearchTarget(routeKey, title, scope, nextToken++, fallback?.takeIf { it != title })
    }

    /** The row is not on the page: point at its [SearchTarget.fallback] instead, keeping the token. */
    internal fun useFallback(token: Long): Boolean {
        val target = pending?.takeIf { it.token == token } ?: return false
        val fallback = target.fallback ?: return false
        rowBounds = null
        pending = target.copy(title = fallback, fallback = null)
        return true
    }

    internal fun finish(token: Long) {
        if (pending?.token == token) pending = null
    }
}

val LocalSettingsSearch = staticCompositionLocalOf<SettingsSearchHost?> { null }

/** The route key of the page being drawn, so a target only matches rows on its own page. */
val LocalSearchRoute = staticCompositionLocalOf<String?> { null }

/** Rows that repeat per device on one page tell them apart with the device id. */
val LocalSearchScope = staticCompositionLocalOf<String?> { null }

/** The highlight's whole run: in, a dip, in again, a short hold, out. */
private const val HIGHLIGHT_IN = 180
private const val HIGHLIGHT_DIP = 260
private const val HIGHLIGHT_HOLD = 380
private const val HIGHLIGHT_OUT = 520

/** Reduce motion: a steady tint, then one fade out, about as long as the pulse. */
private const val STEADY_HOLD = 1300
private const val STEADY_OUT = 300

/**
 * A settings row's part in search: records it for tests and, when it is the chosen result, reports where it
 * is and draws the highlight behind its content (opacity only; with reduced motion a steady tint that fades
 * out once). Put it after the row's background. [title] identifies the row; [searchable] is false for status
 * lines that are not settings.
 */
fun Modifier.settingsSearchHighlight(title: String, shape: Shape, searchable: Boolean = true): Modifier = this.composed {
    val host = LocalSettingsSearch.current ?: return@composed Modifier
    val route = LocalSearchRoute.current
    val scope = LocalSearchScope.current
    host.recorder?.let { record ->
        val row = remember { Any() }
        SideEffect { record(route, scope, title, searchable, row) }
    }
    val target = host.pending
    if (!searchable || target == null || target.routeKey != route || target.scope != scope || target.title != title) return@composed Modifier
    val motion = LocalMotion.current
    val alpha = remember(target.token) { Animatable(0f) }
    val tint = BridgeyTheme.colors.tintBlue
    SideEffect { if (host.located != target.token) host.located = target.token }
    LaunchedEffect(target.token) {
        snapshotFlow { host.arrived }.first { it == target.token }
        if (motion.moves) {
            alpha.animateTo(1f, tween(HIGHLIGHT_IN, easing = LinearEasing))
            alpha.animateTo(0.35f, tween(HIGHLIGHT_DIP))
            alpha.animateTo(1f, tween(HIGHLIGHT_DIP))
            delay(HIGHLIGHT_HOLD.toLong())
            alpha.animateTo(0f, tween(HIGHLIGHT_OUT))
        } else {
            alpha.snapTo(1f)
            delay(STEADY_HOLD.toLong())
            alpha.animateTo(0f, tween(STEADY_OUT))
        }
        host.finish(target.token)
    }
    Modifier
        .onGloballyPositioned { host.rowBounds = it.unclippedBounds() }
        .drawBehind {
            val a = alpha.value
            if (a > 0f) {
                val outline: Outline = shape.createOutline(size, layoutDirection, this)
                drawOutline(outline, tint, alpha = a)
            }
        }
}

/**
 * A scrolling settings list's part in search: when the chosen result is on this page, finds its row (stepping
 * through items not drawn yet; a hidden row's switch when it has one), centres it in the list, below the page bar,
 * then lets the highlight play. Attach the returned modifier to the list. Scrolls without animation under reduced
 * motion.
 */
fun Modifier.settingsSearchScroll(listState: LazyListState): Modifier = this.composed {
    val host = LocalSettingsSearch.current ?: return@composed Modifier
    val route = LocalSearchRoute.current
    val target = host.pending?.takeIf { it.routeKey == route } ?: return@composed Modifier
    val motion = LocalMotion.current
    val viewport = remember { arrayOfNulls<Rect>(1) }
    LaunchedEffect(target.token) {
        // A page result (a device's page) has no row to find.
        if (target.title.isEmpty()) {
            host.finish(target.token)
            return@LaunchedEffect
        }
        // Let the page arrive first, so the scroll is seen.
        if (motion.moves) delay(280)
        withFrameNanos {}
        suspend fun locate() {
            if (host.located == target.token) return
            val count = listState.layoutInfo.totalItemsCount
            for (index in 0 until count) {
                listState.scrollToItem(index)
                withFrameNanos {}
                if (host.located == target.token) return
            }
        }
        locate()
        // Hidden while its feature is off (the folder options with Files off): show the switch that brings it back.
        if (host.located != target.token && host.useFallback(target.token)) {
            withFrameNanos {}
            locate()
        }
        if (host.located != target.token) {
            // Not on the page in its current state (an option hidden while its switch is off).
            host.finish(target.token)
            return@LaunchedEffect
        }
        withFrameNanos {}
        val row = host.rowBounds
        val view = viewport[0]
        if (row != null && view != null) {
            val delta = row.center.y - view.center.y
            if (motion.moves) listState.animateScrollBy(delta) else listState.scrollBy(delta)
        }
        host.arrived = target.token
    }
    Modifier.onGloballyPositioned { viewport[0] = it.unclippedBounds() }
}

/**
 * Where a layout is in root coordinates, whether or not it is visible. boundsInRoot clips to the parents, so a row
 * inside a list item that is only partly on screen (Privacy's Logging group) measured as an empty rectangle at the
 * origin and the page never scrolled to it.
 */
private fun LayoutCoordinates.unclippedBounds(): Rect = Rect(positionInRoot(), size.toSize())
