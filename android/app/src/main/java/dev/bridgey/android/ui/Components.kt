package dev.bridgey.android.ui

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.pressScale
import dev.bridgey.android.ui.theme.Aurora
import dev.bridgey.android.ui.theme.BridgeyColors
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.LocalOnBand
import kotlin.math.PI

/** Tile tints from the mockup: purple, blue, green or neutral. */
enum class Tint { PURPLE, BLUE, GREEN, NEUTRAL }

fun BridgeyColors.tint(tint: Tint): Pair<Color, Color> = when (tint) {
    Tint.PURPLE -> tintPurple to onTintPurple
    Tint.BLUE -> tintBlue to onTintBlue
    Tint.GREEN -> tintGreen to onTintGreen
    Tint.NEUTRAL -> surface3 to onSurfaceVariant
}

/** Square-ish icon tile in front of rows and stream items. */
@Composable
fun IconTile(icon: ImageVector, tint: Tint, size: Dp = 40.dp, corner: Dp = 14.dp, iconSize: Dp = 24.dp) {
    val (bg, fg) = BridgeyTheme.colors.tint(tint)
    Box(
        Modifier.size(size).clip(RoundedCornerShape(corner)).background(bg),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(iconSize)) }
}

/** Ring styles. Private network and relay are not offered yet; their styles are kept for when they are. */
enum class RingStyle { SAME_WIFI, PRIVATE_NETWORK, RELAY, NEARBY, OFFLINE, ADD }

fun RingState.style(): RingStyle = when (this) {
    RingState.CONNECTED -> RingStyle.SAME_WIFI
    RingState.CONNECTING, RingState.NEARBY -> RingStyle.NEARBY
    RingState.OFFLINE -> RingStyle.OFFLINE
}

fun deviceIcon(platform: String?): ImageVector =
    if (platform == "android") BridgeyIcons.Smartphone else BridgeyIcons.LaptopMac

/**
 * A device glyph inside its ring. The ring shows how the device is reached: aurora gradient for
 * same Wi-Fi, solid blue for a private network, dotted purple for relay, dashed green for nearby,
 * a plain outline when offline. Ring 3 dp, then a 3 dp gap, then the glyph.
 */
@Composable
fun DeviceGlyph(
    style: RingStyle,
    icon: ImageVector,
    size: Dp,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    iconSize: Dp = if (size >= 56.dp) 28.dp else 20.dp,
) {
    val colors = BridgeyTheme.colors
    val onBand = LocalOnBand.current
    Box(
        modifier
            .size(size)
            .drawBehind {
                val stroke = 3.dp.toPx()
                val radius = size.toPx() / 2f - stroke / 2f
                when (style) {
                    RingStyle.SAME_WIFI -> drawCircle(Aurora.ringSweep(center), radius, style = Stroke(stroke))
                    RingStyle.PRIVATE_NETWORK -> drawCircle(Color(0xFF54C7F5), radius, style = Stroke(stroke))
                    RingStyle.RELAY -> {
                        val dash = (2 * PI * radius / 36).toFloat()
                        drawCircle(Color(0xFF9B7CFF), radius, style = Stroke(stroke, pathEffect = PathEffect.dashPathEffect(floatArrayOf(dash, dash))))
                    }
                    RingStyle.NEARBY -> {
                        val segment = (2 * PI * radius / 16).toFloat()
                        drawCircle(colors.onTintGreen, radius, style = Stroke(stroke, pathEffect = PathEffect.dashPathEffect(floatArrayOf(segment * 0.62f, segment * 0.38f))))
                    }
                    RingStyle.OFFLINE -> drawCircle(colors.outline, radius, style = Stroke(stroke))
                    RingStyle.ADD -> drawCircle(colors.outline, size.toPx() / 2f - 6.dp.toPx() - 1.dp.toPx(), style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))))
                }
                if (selected) {
                    val halo = if (onBand || colors.isDark) colors.selectionHalo else colors.selectionHalo
                    drawCircle(halo, size.toPx() / 2f + 5.dp.toPx(), style = Stroke(2.dp.toPx()), center = Offset(this.size.width / 2f, this.size.height / 2f))
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        val inner = size - 12.dp
        val glyphBg = when {
            style == RingStyle.ADD -> Color.Transparent
            selected -> colors.tintBlue
            else -> colors.surface3
        }
        val glyphFg = when {
            style == RingStyle.ADD -> colors.onSurfaceVariant
            selected -> colors.onTintBlue
            else -> colors.onSurface
        }
        Box(Modifier.size(inner).clip(CircleShape).background(glyphBg), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = glyphFg, modifier = Modifier.size(iconSize))
        }
    }
}

/** Section label: 13 sp, upper case, muted, inset 32 dp. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        style = BridgeyType.section,
        color = BridgeyTheme.colors.onSurfaceVariant,
        modifier = modifier.padding(horizontal = 32.dp).semantics { heading() },
    )
}

/** Rows in a group: 24 dp outer corners, 6 dp inner, 2 dp apart. */
fun groupShape(index: Int, count: Int, outer: Dp = 24.dp, inner: Dp = 6.dp): Shape = when {
    count == 1 -> RoundedCornerShape(outer)
    index == 0 -> RoundedCornerShape(topStart = outer, topEnd = outer, bottomStart = inner, bottomEnd = inner)
    index == count - 1 -> RoundedCornerShape(topStart = inner, topEnd = inner, bottomStart = outer, bottomEnd = outer)
    else -> RoundedCornerShape(inner)
}

@Composable
fun RowGroup(modifier: Modifier = Modifier, content: @Composable GroupScope.() -> Unit) {
    val scope = remember { GroupScope() }
    scope.rows.clear()
    scope.content()
    Column(modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        scope.rows.forEachIndexed { index, row -> row(groupShape(index, scope.rows.size)) }
    }
}

class GroupScope {
    internal val rows = mutableListOf<@Composable (Shape) -> Unit>()
    fun row(content: @Composable (Shape) -> Unit) {
        rows += content
    }
}

/**
 * A settings or permission row: tile, title and detail, then a trailing control. [compact] is the
 * device page's 56 dp row with a 36 dp tile; the default is 64 dp with a 40 dp tile.
 */
@Composable
fun ListRow(
    shape: Shape,
    title: String,
    detail: String?,
    icon: ImageVector?,
    tint: Tint,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    detailWarning: Boolean = false,
    onClick: (() -> Unit)? = null,
    onClickLabel: String? = null,
    role: Role? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    val colors = BridgeyTheme.colors
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = if (compact) 56.dp else 64.dp)
            .clip(shape)
            .background(colors.surface1)
            .then(
                if (onClick != null) {
                    Modifier.clickable(onClickLabel = onClickLabel, role = role, onClick = onClick)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 16.dp, vertical = if (compact) 8.dp else 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        when {
            leading != null -> leading()
            icon != null -> if (compact) {
                IconTile(icon, tint, size = 36.dp, corner = 12.dp, iconSize = 20.dp)
            } else {
                IconTile(icon, tint)
            }
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = if (compact) BridgeyType.itemTitle else BridgeyType.rowTitle, color = colors.onSurface)
            if (detail != null) {
                Text(
                    detail,
                    style = BridgeyType.itemBody,
                    color = if (detailWarning) colors.onTintPurple else colors.onSurfaceVariant,
                    modifier = Modifier.padding(top = 1.dp),
                )
            }
        }
        trailing?.invoke(this)
    }
}

/** The mockup's switch: 52 x 32, aurora blue track when on. */
@Composable
fun BridgeySwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val colors = BridgeyTheme.colors
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        enabled = enabled,
        modifier = modifier,
        colors = SwitchDefaults.colors(
            checkedThumbColor = colors.switchThumb,
            checkedTrackColor = colors.switchOn,
            checkedBorderColor = Color.Transparent,
            uncheckedThumbColor = colors.onSurfaceVariant,
            uncheckedTrackColor = colors.switchOff,
            uncheckedBorderColor = colors.outline,
            disabledCheckedTrackColor = colors.switchOn.copy(alpha = 0.38f),
            disabledCheckedThumbColor = colors.switchThumb,
            disabledUncheckedTrackColor = colors.switchOff.copy(alpha = 0.5f),
            disabledUncheckedThumbColor = colors.onSurfaceVariant.copy(alpha = 0.5f),
            disabledUncheckedBorderColor = colors.outline.copy(alpha = 0.5f),
        ),
    )
}

/** A row whose whole surface toggles its switch, so the touch target is the row. */
@Composable
fun SwitchRow(
    shape: Shape,
    title: String,
    detail: String?,
    icon: ImageVector?,
    tint: Tint,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
    compact: Boolean = false,
    detailWarning: Boolean = false,
) {
    ListRow(
        shape = shape,
        title = title,
        detail = detail,
        icon = icon,
        tint = tint,
        compact = compact,
        detailWarning = detailWarning,
        modifier = Modifier.semantics(mergeDescendants = true) {},
        onClick = if (enabled) ({ onCheckedChange(!checked) }) else null,
        role = Role.Switch,
    ) {
        BridgeySwitch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

/** The aurora gradient button, the one main action on a screen. */
@Composable
fun GradientButton(
    text: String,
    icon: ImageVector?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    height: Dp = 56.dp,
    textStyle: TextStyle = BridgeyType.button,
    contentPadding: PaddingValues = PaddingValues(horizontal = 20.dp),
) {
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier
            .pressScale(interaction)
            .height(height)
            .shadow(if (enabled) 10.dp else 0.dp, RoundedCornerShape(height / 2), ambientColor = Color(0xFF54C7F5), spotColor = Color(0xFF54C7F5))
            .clip(RoundedCornerShape(height / 2))
            .drawBehind {
                if (enabled) drawRect(Aurora.button(size)) else drawRect(Color(0x33808A99))
            }
            .clickable(interactionSource = interaction, indication = ripple(color = Aurora.OnGradient), enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(contentPadding),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (enabled) Aurora.OnGradient else BridgeyTheme.colors.onSurfaceVariant
        if (icon != null) Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(20.dp))
        Text(text, style = textStyle, color = fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Round gradient send button. */
@Composable
fun GradientCircleButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit, enabled: Boolean = true, size: Dp = 48.dp) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        Modifier
            .pressScale(interaction)
            .size(size)
            .clip(CircleShape)
            .drawBehind { if (enabled) drawRect(Aurora.button(this.size)) else drawRect(Color(0x33808A99)) }
            .clickable(interactionSource = interaction, indication = ripple(color = Aurora.OnGradient), enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (enabled) Aurora.OnGradient else BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.size(22.dp))
    }
}

/** 48 dp icon button in the content colour. */
@Composable
fun BarIconButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 48.dp, enabled: Boolean = true) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = LocalContentColor.current.copy(alpha = if (enabled) 1f else 0.38f), modifier = Modifier.size(24.dp))
    }
}

/** Outlined pill button (Check now, Clear). At least 48 dp tall to touch, 40 dp drawn. */
@Composable
fun OutlinePillButton(text: String, icon: ImageVector?, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, contentColor: Color = BridgeyTheme.colors.onSurface) {
    val colors = BridgeyTheme.colors
    Box(
        modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(24.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier
                .height(40.dp)
                .border(1.dp, colors.outline, RoundedCornerShape(20.dp))
                .padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            val fg = if (enabled) contentColor else colors.onSurfaceVariant
            if (icon != null) Icon(icon, null, tint = fg, modifier = Modifier.size(18.dp))
            Text(text, style = BridgeyType.label, color = fg, maxLines = 1)
        }
    }
}

/** Tonal pill used for small inline actions on cards (Cancel, Retry, Open, Stop). */
@Composable
fun TonalPillButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Tint = Tint.BLUE) {
    val (bg, fg) = BridgeyTheme.colors.tint(tint)
    Box(
        modifier
            .heightIn(min = 48.dp)
            .widthIn(min = 48.dp)
            .clip(RoundedCornerShape(24.dp))
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.height(36.dp).clip(RoundedCornerShape(18.dp)).background(bg).padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center,
        ) { Text(text, style = BridgeyType.label, color = fg, maxLines = 1) }
    }
}

/** Status pill (Up to date, Update available). */
@Composable
fun StatusPill(text: String, icon: ImageVector?, tint: Tint) {
    val (bg, fg) = BridgeyTheme.colors.tint(tint)
    Row(
        Modifier.height(24.dp).clip(RoundedCornerShape(12.dp)).background(bg).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (icon != null) Icon(icon, null, tint = fg, modifier = Modifier.size(14.dp))
        Text(text, style = BridgeyType.smallStrong, color = fg, maxLines = 1)
    }
}

/** Route pill under a device name. */
@Composable
fun RoutePill(state: RingState, label: String? = null, route: dev.bridgey.android.connect.ConnectRoute? = null) {
    val colors = BridgeyTheme.colors
    val (bg, fg) = when (state) {
        RingState.CONNECTED -> colors.tintGreen to colors.onTintGreen
        RingState.NEARBY, RingState.CONNECTING -> colors.tintBlue to colors.onTintBlue
        RingState.OFFLINE -> colors.surface3 to colors.onSurfaceVariant
    }
    val icon = when {
        state == RingState.OFFLINE -> BridgeyIcons.WifiOff
        state != RingState.CONNECTED || route == null || route.route == "lan" -> BridgeyIcons.Wifi
        route.route == "vpn" -> BridgeyIcons.VpnLock
        route.route == "direct" -> BridgeyIcons.Public
        else -> BridgeyIcons.Cloud
    }
    Crossfade(state, animationSpec = LocalMotion.current.fadeSpec(), label = "route") { shown ->
        Row(
            Modifier.height(26.dp).clip(RoundedCornerShape(13.dp)).background(bg).padding(start = 8.dp, end = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(icon, null, tint = fg, modifier = Modifier.size(15.dp))
            Text(label ?: ringStateLabel(shown), style = BridgeyType.smallStrong, color = fg, maxLines = 1)
        }
    }
}

@Composable
fun ringStateLabel(state: RingState): String = stringResource(
    when (state) {
        RingState.CONNECTED -> R.string.ring_same_wifi
        RingState.CONNECTING -> R.string.ring_connecting
        RingState.NEARBY -> R.string.ring_nearby
        RingState.OFFLINE -> R.string.ring_offline
    },
)

/** A ring's one-line status: "Reconnecting…" or "Retrying…" while a dropped device is retried, else its route. */
@Composable
fun ringStatusLabel(ring: DeviceRing): String = when {
    ring.state == RingState.CONNECTED && ring.route != null -> connectRouteLabel(ring.route)
    !ring.canRetry -> ringStateLabel(ring.state)
    ring.reconnect?.struggling == true -> stringResource(R.string.ring_retrying)
    else -> stringResource(R.string.ring_reconnecting)
}

@Composable
fun ringStateColor(state: RingState): Color {
    val colors = BridgeyTheme.colors
    return when (state) {
        RingState.CONNECTED -> colors.onTintGreen
        RingState.CONNECTING, RingState.NEARBY -> colors.onTintBlue
        RingState.OFFLINE -> colors.onSurfaceVariant
    }
}

/** A page's top bar: back, a title, and optional actions. 56 dp tall. */
@Composable
fun PageBar(title: String?, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BarIconButton(BridgeyIcons.ArrowBack, stringResource(R.string.action_back), onBack)
        if (title != null) {
            Text(
                title,
                style = BridgeyType.pageTitle,
                modifier = Modifier.weight(1f).padding(start = 4.dp).semantics { heading() },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        } else {
            Spacer(Modifier.weight(1f))
        }
        actions()
    }
}

/** Centered muted note. */
@Composable
fun Note(text: String, modifier: Modifier = Modifier, center: Boolean = false) {
    Text(
        text,
        style = BridgeyType.itemBody,
        color = BridgeyTheme.colors.onSurfaceVariant,
        textAlign = if (center) TextAlign.Center else TextAlign.Start,
        modifier = modifier,
    )
}

/** Gives a composable the content colour of the band or the page. */
@Composable
fun WithContentColor(color: Color, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalContentColor provides color, content = content)
}

/** Hides decorative children from accessibility and gives the group one description. */
fun Modifier.describedAs(description: String): Modifier = clearAndSetSemantics { contentDescription = description }

val ScreenWidthCap = 600.dp

fun Modifier.capWidth(): Modifier = widthIn(max = ScreenWidthCap)
