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
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.theme.BridgeyTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

/** Where a search result points: a row titled [title] on the page whose route key is [routeKey]. */
data class SearchTarget(val routeKey: String, val title: String, val scope: String? = null, val token: Long)

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

    /** Where the target's row is, in root coordinates, once drawn. */
    internal var rowBounds: Rect? = null

    /** Tests: every row drawn, with its page (route key), scope, title and whether search offers it. */
    var recorder: ((route: String?, scope: String?, title: String, searchable: Boolean) -> Unit)? = null

    fun open(routeKey: String, title: String, scope: String? = null) {
        rowBounds = null
        pending = SearchTarget(routeKey, title, scope, nextToken++)
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
    host.recorder?.let { record -> SideEffect { record(route, scope, title, searchable) } }
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
        .onGloballyPositioned { host.rowBounds = it.boundsInRoot() }
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
 * through items not drawn yet), centres it, then lets the highlight play. Attach the returned modifier to the
 * list. Scrolls without animation under reduced motion.
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
        if (host.located != target.token) {
            val count = listState.layoutInfo.totalItemsCount
            for (index in 0 until count) {
                listState.scrollToItem(index)
                withFrameNanos {}
                if (host.located == target.token) break
            }
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
    Modifier.onGloballyPositioned { viewport[0] = it.boundsInRoot() }
}
