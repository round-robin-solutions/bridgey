package dev.bridgey.android.ui

import android.text.format.DateFormat
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import dev.bridgey.android.FileTransferState
import dev.bridgey.android.MacMediaState
import dev.bridgey.android.R
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.MotionMode
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import kotlinx.coroutines.launch
import java.util.Date

/** Settings > Privacy > Show previews in activity. Off hides stored previews and app names. */
val LocalShowPreviews = androidx.compose.runtime.staticCompositionLocalOf { true }

/** Cards at the top of the stream that need an action now. They are new items, so they arrive like one. */
sealed interface LiveCard {
    val key: String

    /** [expanded] opens a folder card on its file list at first (screenshots); the user toggles it by tapping. */
    data class Transfer(val transfer: FileTransferState, val cancelAll: Boolean = false, val expanded: Boolean = false) : LiveCard {
        override val key get() = "transfer:${transfer.id}"
    }

    data class Link(val url: String, val deviceName: String) : LiveCard {
        override val key get() = "link"
    }

    data class Ringing(val deviceName: String) : LiveCard {
        override val key get() = "ringing"
    }

    data class Media(val media: MacMediaState, val artwork: ImageBitmap?) : LiveCard {
        override val key get() = "media"
    }

    /** A trusted device that dropped and is being retried, with Retry now. */
    data class Reconnecting(val deviceId: String, val deviceName: String, val lastSeen: String?, val struggling: Boolean) : LiveCard {
        override val key get() = "reconnecting:$deviceId"
    }

    /** Update all: devices with an update, or a run to follow. */
    data class UpdateAll(val state: UpdateAllUiState) : LiveCard {
        override val key get() = "update-all"
    }
}

class LiveActions(
    val cancelTransfer: (String) -> Unit = {},
    val cancelAllTransfers: () -> Unit = {},
    val retryTransfer: (String) -> Unit = {},
    val dismissTransfers: () -> Unit = {},
    val openLink: () -> Unit = {},
    val dismissLink: () -> Unit = {},
    val stopRinging: () -> Unit = {},
    val media: (action: String, value: String) -> Unit = { _, _ -> },
    val retryDevice: (String) -> Unit = {},
    /** A folder waits for this phone's answer: open its sheet. */
    val answerFolder: (String) -> Unit = {},
    val updateAll: UpdateAllActions = UpdateAllActions(),
)

/** The clock for live countdowns; screenshots fix it. */
val LocalNow = androidx.compose.runtime.staticCompositionLocalOf<() -> Long> { System::currentTimeMillis }

/** Icon and tint for a stream item. */
fun ActivityKind.visual(): Pair<ImageVector, Tint> = when (this) {
    ActivityKind.CLIPBOARD_SENT, ActivityKind.CLIPBOARD_RECEIVED -> BridgeyIcons.ContentPaste to Tint.BLUE
    ActivityKind.CLIPBOARD_RECEIVE_FAILED -> BridgeyIcons.Error to Tint.NEUTRAL
    ActivityKind.FILE_SENT, ActivityKind.FILE_RECEIVED -> BridgeyIcons.Description to Tint.GREEN
    ActivityKind.FILE_FAILED -> BridgeyIcons.Error to Tint.NEUTRAL
    ActivityKind.LINK_SENT, ActivityKind.LINK_RECEIVED -> BridgeyIcons.Link to Tint.BLUE
    ActivityKind.NOTIFICATIONS_SHOWN -> BridgeyIcons.Notifications to Tint.PURPLE
    ActivityKind.CALL_SHOWN, ActivityKind.CALL_STARTED -> BridgeyIcons.Call to Tint.GREEN
    ActivityKind.PING_SENT, ActivityKind.PING_RECEIVED -> BridgeyIcons.Sensors to Tint.BLUE
    ActivityKind.FIND_MAC, ActivityKind.FIND_PHONE -> BridgeyIcons.MyLocation to Tint.BLUE
    ActivityKind.PAIRED -> BridgeyIcons.Devices to Tint.PURPLE
    ActivityKind.CLIP_OFFER_SENT, ActivityKind.CLIP_OFFER_RECEIVED, ActivityKind.CLIP_PASTED -> BridgeyIcons.ContentPaste to Tint.BLUE
    ActivityKind.CLIP_PASTE_FAILED -> BridgeyIcons.Error to Tint.NEUTRAL
    ActivityKind.FOLDER_SENT, ActivityKind.FOLDER_RECEIVED -> BridgeyIcons.Folder to Tint.GREEN
    ActivityKind.FOLDER_INCOMPLETE -> BridgeyIcons.Folder to Tint.NEUTRAL
}

/** Clipboard offers show what they carried: an image or a file, else the clipboard. */
fun ActivityItem.visual(): Pair<ImageVector, Tint> = when {
    kind == ActivityKind.CLIP_PASTE_FAILED || !kind.isClipOffer -> kind.visual()
    content == "image" -> BridgeyIcons.Image to Tint.BLUE
    content == "file" -> BridgeyIcons.Description to Tint.GREEN
    else -> kind.visual()
}

@Composable
fun itemTitle(item: ActivityItem, device: String): String {
    val show = LocalShowPreviews.current
    if (show && item.kind == ActivityKind.NOTIFICATIONS_SHOWN && item.appName != null) {
        return pluralStringResource(R.plurals.stream_app_alerts_title, item.count, item.count, item.appName)
    }
    if (show && item.kind == ActivityKind.CALL_SHOWN && item.preview != null) {
        return stringResource(R.string.stream_call_from_title, item.preview)
    }
    if (item.kind.isClipOffer) return clipTitle(item, device, if (show) item.fileName else null)
    if (item.kind.isFolder) return FolderText.itemTitle(LocalContext.current, item, device)
    return itemTitleWithoutPreview(item, device)
}

/** "Copied image from Personal Mac (2.1 MB)", "Pasted video.mp4 from OnePlus 11 (340 MB)", "Copied 3 files". */
@Composable
private fun clipTitle(item: ActivityItem, device: String, name: String?): String {
    if (item.kind == ActivityKind.CLIP_PASTE_FAILED) return stringResource(R.string.stream_clip_failed_title, device)
    val size = Formatter.formatShortFileSize(LocalContext.current, item.bytes ?: 0L)
    val image = item.content == "image"
    if (item.count > 1) {
        val res = when (item.kind) {
            ActivityKind.CLIP_OFFER_SENT -> if (image) R.plurals.stream_clip_sent_images else R.plurals.stream_clip_sent_files
            ActivityKind.CLIP_OFFER_RECEIVED -> if (image) R.plurals.stream_clip_received_images else R.plurals.stream_clip_received_files
            else -> if (image) R.plurals.stream_clip_pasted_images else R.plurals.stream_clip_pasted_files
        }
        return if (item.kind == ActivityKind.CLIP_OFFER_SENT) {
            pluralStringResource(res, item.count, item.count)
        } else {
            pluralStringResource(res, item.count, item.count, device)
        }
    }
    return when (item.kind) {
        ActivityKind.CLIP_OFFER_SENT -> when {
            image -> stringResource(R.string.stream_clip_sent_image, size)
            item.content == "text" -> stringResource(R.string.stream_clip_sent_text, size)
            name != null -> stringResource(R.string.stream_clip_sent_file, name, size)
            else -> stringResource(R.string.stream_clip_sent_file_unnamed, size)
        }
        ActivityKind.CLIP_OFFER_RECEIVED -> when {
            image -> stringResource(R.string.stream_clip_received_image, device, size)
            item.content == "text" -> stringResource(R.string.stream_clip_received_text, device, size)
            name != null -> stringResource(R.string.stream_clip_received_file, name, device, size)
            else -> stringResource(R.string.stream_clip_received_file_unnamed, device, size)
        }
        else -> when {
            image -> stringResource(R.string.stream_clip_pasted_image, device, size)
            item.content == "text" -> stringResource(R.string.stream_clip_pasted_text, device, size)
            name != null -> stringResource(R.string.stream_clip_pasted_file, name, device, size)
            else -> stringResource(R.string.stream_clip_pasted_file_unnamed, device, size)
        }
    }
}

/** A clipboard item's quoted preview, "Hidden" for sensitive clips, or null to use the plain detail. */
@Composable
fun itemQuote(item: ActivityItem): String? {
    if (item.kind != ActivityKind.CLIPBOARD_SENT && item.kind != ActivityKind.CLIPBOARD_RECEIVED) return null
    if (item.sensitive) return stringResource(R.string.stream_clipboard_hidden)
    val preview = item.preview?.takeIf { LocalShowPreviews.current } ?: return null
    return "\u201C$preview\u201D"
}

@Composable
private fun itemTitleWithoutPreview(item: ActivityItem, device: String): String = when (item.kind) {
    ActivityKind.CLIPBOARD_SENT -> stringResource(R.string.stream_clipboard_sent_title, device)
    ActivityKind.CLIPBOARD_RECEIVED -> stringResource(R.string.stream_clipboard_received_title, device)
    ActivityKind.CLIPBOARD_RECEIVE_FAILED -> stringResource(R.string.stream_clipboard_failed_title)
    ActivityKind.FILE_SENT, ActivityKind.FILE_RECEIVED, ActivityKind.FILE_FAILED ->
        item.fileName ?: stringResource(R.string.stream_file_unnamed)
    ActivityKind.LINK_SENT -> stringResource(R.string.stream_link_sent_title, device)
    ActivityKind.LINK_RECEIVED -> stringResource(R.string.stream_link_received_title, device)
    ActivityKind.NOTIFICATIONS_SHOWN -> pluralStringResource(R.plurals.stream_alerts_title, item.count, item.count)
    ActivityKind.CALL_SHOWN -> if (item.count == 1) {
        stringResource(R.string.stream_call_title)
    } else {
        pluralStringResource(R.plurals.stream_calls_title, item.count, item.count)
    }
    ActivityKind.CALL_STARTED -> stringResource(R.string.stream_call_started_title, device)
    ActivityKind.PING_SENT -> stringResource(R.string.stream_ping_sent_title, device)
    ActivityKind.PING_RECEIVED -> stringResource(R.string.stream_ping_received_title, device)
    ActivityKind.FIND_MAC -> stringResource(R.string.stream_find_mac_title, device)
    ActivityKind.FIND_PHONE -> stringResource(R.string.stream_find_phone_title, device)
    ActivityKind.PAIRED -> stringResource(R.string.stream_paired_title, device)
    ActivityKind.CLIP_OFFER_SENT, ActivityKind.CLIP_OFFER_RECEIVED, ActivityKind.CLIP_PASTED, ActivityKind.CLIP_PASTE_FAILED ->
        clipTitle(item, device, null)
    ActivityKind.FOLDER_SENT, ActivityKind.FOLDER_RECEIVED, ActivityKind.FOLDER_INCOMPLETE -> FolderText.itemTitle(LocalContext.current, item, device)
}

@Composable
fun itemDetail(item: ActivityItem, device: String): String = when (item.kind) {
    ActivityKind.CLIP_OFFER_SENT ->
        stringResource(if (item.automatic) R.string.stream_clip_sent_auto else R.string.stream_clip_sent_detail, device)
    ActivityKind.CLIP_OFFER_RECEIVED ->
        stringResource(if (item.automatic) R.string.stream_clipboard_received_auto else R.string.stream_clipboard_received_detail)
    ActivityKind.CLIP_PASTED -> stringResource(R.string.stream_clip_pasted_detail)
    ActivityKind.CLIP_PASTE_FAILED -> stringResource(R.string.stream_clip_failed_detail)
    ActivityKind.CLIPBOARD_SENT ->
        stringResource(if (item.automatic) R.string.stream_clipboard_auto else R.string.stream_clipboard_sent_detail)
    ActivityKind.CLIPBOARD_RECEIVED ->
        stringResource(if (item.automatic) R.string.stream_clipboard_received_auto else R.string.stream_clipboard_received_detail)
    ActivityKind.CLIPBOARD_RECEIVE_FAILED -> stringResource(R.string.stream_clipboard_failed_detail)
    ActivityKind.FILE_SENT -> stringResource(R.string.stream_file_sent_detail, device)
    ActivityKind.FILE_RECEIVED -> stringResource(R.string.stream_file_received_detail, device)
    ActivityKind.FILE_FAILED -> stringResource(R.string.stream_file_failed_detail, device)
    ActivityKind.LINK_SENT -> stringResource(R.string.stream_link_sent_detail)
    ActivityKind.LINK_RECEIVED -> stringResource(R.string.stream_link_received_detail)
    ActivityKind.NOTIFICATIONS_SHOWN, ActivityKind.CALL_SHOWN -> stringResource(R.string.stream_shown_on, device)
    ActivityKind.CALL_STARTED -> stringResource(R.string.stream_call_started_detail)
    ActivityKind.PING_SENT, ActivityKind.PING_RECEIVED -> stringResource(R.string.stream_ping_detail)
    ActivityKind.FIND_MAC, ActivityKind.FIND_PHONE -> stringResource(R.string.stream_find_detail)
    ActivityKind.PAIRED -> stringResource(R.string.stream_paired_detail)
    ActivityKind.FOLDER_SENT, ActivityKind.FOLDER_RECEIVED, ActivityKind.FOLDER_INCOMPLETE -> FolderText.itemDetail(LocalContext.current, item, device)
}

@Composable
fun timeLabel(atMillis: Long, now: Long, section: DaySection): String {
    val context = LocalContext.current
    return when {
        now - atMillis in 0 until 60_000 -> stringResource(R.string.stream_now)
        section == DaySection.EARLIER -> DateUtils.formatDateTime(
            context, atMillis,
            DateUtils.FORMAT_SHOW_WEEKDAY or DateUtils.FORMAT_ABBREV_WEEKDAY or DateUtils.FORMAT_SHOW_TIME,
        )
        else -> DateFormat.getTimeFormat(context).format(Date(atMillis))
    }
}

@Composable
fun sectionTitle(section: DaySection): String = stringResource(
    when (section) {
        DaySection.TODAY -> R.string.stream_today
        DaySection.YESTERDAY -> R.string.stream_yesterday
        DaySection.EARLIER -> R.string.stream_earlier
    },
)

/**
 * The stream: live cards, then activity grouped by day, on a timeline rail. New rows drop in from
 * above and pop; rows below slide down by translation. When the user has scrolled down, the list
 * keeps its place (lazy lists anchor on the first visible key).
 */
@Composable
fun StreamList(
    rows: List<StreamRow>,
    live: List<LiveCard>,
    liveActions: LiveActions,
    deviceName: (ActivityItem) -> String,
    now: Long,
    state: LazyListState,
    contentPadding: PaddingValues,
    empty: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    leading: (LazyListScope.() -> Unit)? = null,
) {
    val tracker = remember { ArrivalTracker() }
    val hasToday = rows.any { it is StreamRow.Header && it.section == DaySection.TODAY }
    val keys = buildList {
        live.forEach { add(it.key) }
        rows.forEach { add(it.key) }
    }
    tracker.update(keys)
    val wasAtTop = remember { booleanArrayOf(true) }
    LaunchedEffect(keys.firstOrNull { it.startsWith("item:") || it.startsWith("transfer:") }) {
        // At the very top, keep the newest item in view; scrolled down, keep the reader's place.
        if (wasAtTop[0] && state.firstVisibleItemIndex <= 1) state.scrollToItem(0)
    }
    wasAtTop[0] = state.firstVisibleItemIndex == 0 && state.firstVisibleItemScrollOffset == 0

    LazyColumn(modifier = modifier, state = state, contentPadding = contentPadding) {
        leading?.invoke(this)
        if (live.isEmpty() && rows.isEmpty()) {
            item(key = "empty") { empty() }
            return@LazyColumn
        }
        var firstHeader = true
        if (live.isNotEmpty() && !hasToday) {
            item(key = StreamRow.Header(DaySection.TODAY).key, contentType = "header") { StreamHeader(DaySection.TODAY, first = true) }
            liveItems(live, liveActions, tracker, hasItemsBelow = false)
            firstHeader = false
        }
        rows.forEach { row ->
            when (row) {
                is StreamRow.Header -> {
                    val isFirst = firstHeader
                    firstHeader = false
                    item(key = row.key, contentType = "header") { StreamHeader(row.section, first = isFirst) }
                    if (row.section == DaySection.TODAY) liveItems(live, liveActions, tracker, hasItemsBelow = true)
                }
                is StreamRow.Item -> item(key = row.key, contentType = "item") {
                    val firstInRail = row.first && !(row.section == DaySection.TODAY && live.isNotEmpty())
                    ArrivingItem(row.key, tracker) {
                        StreamItemRow(row, deviceName(row.item), now, firstInRail)
                    }
                }
            }
        }
    }
}

private fun LazyListScope.liveItems(live: List<LiveCard>, actions: LiveActions, tracker: ArrivalTracker, hasItemsBelow: Boolean) {
    live.forEachIndexed { index, card ->
        item(key = card.key, contentType = "live") {
            ArrivingItem(card.key, tracker) {
                LiveCardRow(card, actions, first = index == 0, last = index == live.lastIndex && !hasItemsBelow)
            }
        }
    }
}

@Composable
private fun StreamHeader(section: DaySection, first: Boolean) {
    SectionLabel(sectionTitle(section), Modifier.padding(top = if (first) 20.dp else 24.dp, bottom = 8.dp))
}

/** A new row drops from 24 dp above and grows from 0.7 on the pop spring; opacity on the effects spring. */
@Composable
private fun LazyItemScope.ArrivingItem(key: String, tracker: ArrivalTracker, content: @Composable () -> Unit) {
    val motion = LocalMotion.current
    val arriving = remember(key) { tracker.consume(key) && motion.mode != MotionMode.Instant }
    val progress = remember(key) { Animatable(if (arriving && motion.moves) 0f else 1f) }
    val alpha = remember(key) { Animatable(if (arriving) 0f else 1f) }
    if (arriving) {
        LaunchedEffect(key) {
            launch { progress.animateTo(1f, motion.pop.spec()) }
            alpha.animateTo(1f, motion.fadeSpec())
        }
    }
    Box(
        Modifier
            .animateItem(fadeInSpec = null, fadeOutSpec = null, placementSpec = motion.spatial(motion.small, IntOffset.VisibilityThreshold))
            .graphicsLayer {
                val p = progress.value
                val s = motion.arriveScale + (1f - motion.arriveScale) * p
                scaleX = s
                scaleY = s
                transformOrigin = TransformOrigin(0.5f, 0f)
                translationY = -(1f - p) * motion.arriveRise.toPx()
                this.alpha = alpha.value.coerceIn(0f, 1f)
            },
    ) { content() }
}

/** Timeline rail: a 2 dp line through the tiles, from the first tile's centre to the last one's. */
private fun Modifier.rail(first: Boolean, last: Boolean, color: androidx.compose.ui.graphics.Color, tileCenter: Float = 40f): Modifier = drawBehind {
    val x = 20.dp.toPx()
    val top = if (first) tileCenter.dp.toPx() else -8.dp.toPx()
    val bottom = if (last) tileCenter.dp.toPx() else size.height
    if (bottom > top) drawLine(color, Offset(x, top), Offset(x, bottom), strokeWidth = 2.dp.toPx())
}

@Composable
private fun StreamItemRow(row: StreamRow.Item, device: String, now: Long, first: Boolean) {
    val colors = BridgeyTheme.colors
    val item = row.item
    val (icon, tint) = item.visual()
    val title = itemTitle(item, device)
    val quote = itemQuote(item)
    val detail = quote ?: itemDetail(item, device)
    val time = timeLabel(item.atMillis, now, row.section)
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(bottom = if (row.last) 0.dp else 8.dp)
            .height(80.dp)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.width(40.dp).fillMaxHeight().rail(first, row.last, colors.outlineVariant),
            contentAlignment = Alignment.Center,
        ) { IconTile(icon, tint, corner = 20.dp) }
        Row(
            Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(title, style = BridgeyType.itemTitle, maxLines = if (item.kind.isClipOffer || item.kind.isFolder) 2 else 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(time, style = BridgeyType.small, color = colors.onSurfaceVariant, maxLines = 1)
                }
                Text(
                    detail,
                    style = BridgeyType.itemBody,
                    color = if (quote != null && !item.sensitive) colors.onSurface else colors.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

@Composable
private fun LiveCardRow(card: LiveCard, actions: LiveActions, first: Boolean, last: Boolean) {
    val colors = BridgeyTheme.colors
    val (icon, tint) = when (card) {
        is LiveCard.Transfer -> (if (card.transfer.kind == dev.bridgey.android.TransferKind.FOLDER) BridgeyIcons.Folder else BridgeyIcons.Description) to Tint.GREEN
        is LiveCard.Link -> BridgeyIcons.Link to Tint.BLUE
        is LiveCard.Ringing -> BridgeyIcons.MyLocation to Tint.PURPLE
        is LiveCard.Media -> BridgeyIcons.MusicNote to Tint.BLUE
        is LiveCard.Reconnecting -> (if (card.struggling) BridgeyIcons.WifiOff else BridgeyIcons.Sync) to (if (card.struggling) Tint.NEUTRAL else Tint.BLUE)
        is LiveCard.UpdateAll -> BridgeyIcons.Update to Tint.PURPLE
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp).heightIn(min = 80.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.width(40.dp).heightIn(min = 80.dp).rail(first, last, colors.outlineVariant).padding(top = 20.dp),
            contentAlignment = Alignment.TopCenter,
        ) { IconTile(icon, tint, corner = 20.dp) }
        Column(
            Modifier.weight(1f).clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            when (card) {
                is LiveCard.Transfer -> if (card.transfer.kind == dev.bridgey.android.TransferKind.FOLDER) {
                    FolderCardContent(card.transfer, card.cancelAll, card.expanded, actions)
                } else {
                    TransferCardContent(card.transfer, card.cancelAll, actions)
                }
                is LiveCard.Link -> {
                    CardText(stringResource(R.string.live_link_title, card.deviceName), card.url, singleLineDetail = false)
                    CardActions {
                        TonalPillButton(stringResource(R.string.action_dismiss), actions.dismissLink, tint = Tint.NEUTRAL)
                        TonalPillButton(stringResource(R.string.action_open), actions.openLink)
                    }
                }
                is LiveCard.Ringing -> {
                    CardText(stringResource(R.string.live_ringing_title, card.deviceName), stringResource(R.string.live_ringing_detail))
                    CardActions { TonalPillButton(stringResource(R.string.action_stop), actions.stopRinging, tint = Tint.PURPLE) }
                }
                is LiveCard.Media -> MediaCardContent(card, actions)
                is LiveCard.Reconnecting -> {
                    CardText(
                        stringResource(if (card.struggling) R.string.live_cant_reach_title else R.string.live_reconnecting_title, card.deviceName),
                        card.lastSeen?.let { stringResource(R.string.live_last_seen, it) } ?: stringResource(R.string.live_reconnecting_detail),
                    )
                    CardActions { TonalPillButton(stringResource(R.string.action_retry_now), { actions.retryDevice(card.deviceId) }) }
                }
                is LiveCard.UpdateAll -> UpdateAllCardContent(card.state, actions.updateAll)
            }
        }
    }
}

@Composable
internal fun CardText(title: String, detail: String?, singleLineDetail: Boolean = true) {
    Text(title, style = BridgeyType.itemTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
    if (!detail.isNullOrBlank()) {
        Text(
            detail,
            style = BridgeyType.itemBody,
            color = BridgeyTheme.colors.onSurfaceVariant,
            maxLines = if (singleLineDetail) 1 else 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}

@Composable
internal fun CardActions(content: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End)) { content() }
}

@Composable
private fun TransferCardContent(transfer: FileTransferState, cancelAll: Boolean, actions: LiveActions) {
    CardText(transfer.name, compactTransferStatus(transfer))
    val percent = transfer.progressPercent
    if (transfer.active && transfer.queued) {
        CardActions {
            if (cancelAll) TonalPillButton(stringResource(R.string.transfers_cancel_all), actions.cancelAllTransfers, tint = Tint.NEUTRAL)
            TonalPillButton(stringResource(R.string.action_cancel), { actions.cancelTransfer(transfer.id) }, tint = Tint.NEUTRAL)
        }
    } else if (transfer.active) {
        Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (percent != null) {
                LinearProgressIndicator(
                    progress = { percent / 100f },
                    modifier = Modifier.weight(1f).height(6.dp),
                    color = BridgeyTheme.colors.primary,
                    trackColor = BridgeyTheme.colors.surface3,
                    strokeCap = StrokeCap.Round,
                    drawStopIndicator = {},
                )
                Text("$percent%", style = BridgeyType.smallStrong)
            } else {
                LinearProgressIndicator(
                    modifier = Modifier.weight(1f).height(6.dp),
                    color = BridgeyTheme.colors.primary,
                    trackColor = BridgeyTheme.colors.surface3,
                    strokeCap = StrokeCap.Round,
                )
            }
        }
        CardActions {
            if (cancelAll) TonalPillButton(stringResource(R.string.transfers_cancel_all), actions.cancelAllTransfers, tint = Tint.NEUTRAL)
            TonalPillButton(stringResource(R.string.action_cancel), { actions.cancelTransfer(transfer.id) }, tint = Tint.NEUTRAL)
        }
    } else {
        CardActions {
            TonalPillButton(stringResource(R.string.action_dismiss), actions.dismissTransfers, tint = Tint.NEUTRAL)
            TonalPillButton(stringResource(R.string.action_retry), { actions.retryTransfer(transfer.id) })
        }
    }
}

/** Status line without the file name the card already shows. */
internal fun compactTransferStatus(transfer: FileTransferState): String = transfer.status
    .substringAfter(": ", transfer.status)
    .replace(Regex("^(Sending|Receiving)\\s+${Regex.escape(transfer.name)}:?\\s*"), "")
    .ifBlank { if (transfer.active) "Preparing…" else transfer.status }

@Composable
private fun MediaCardContent(card: LiveCard.Media, actions: LiveActions) {
    val media = card.media
    val colors = BridgeyTheme.colors
    val ready = media.player in setOf("Music", "Spotify") && media.detail.isEmpty()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        card.artwork?.let {
            Image(it, contentDescription = stringResource(R.string.media_artwork), modifier = Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)))
        }
        Column(Modifier.weight(1f)) {
            val title = media.title.ifBlank { stringResource(R.string.media_title, media.player.ifBlank { stringResource(R.string.media_player_unknown) }) }
            CardText(title, media.artist.ifBlank { media.detail })
        }
    }
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        BarIconButton(BridgeyIcons.SkipPrevious, stringResource(R.string.media_previous), { actions.media("previous", "") }, enabled = ready)
        Spacer(Modifier.width(8.dp))
        GradientCircleButton(
            if (media.playing) BridgeyIcons.Pause else BridgeyIcons.PlayArrow,
            stringResource(if (media.playing) R.string.media_pause else R.string.media_play),
            { actions.media("toggle", "") },
            enabled = ready,
        )
        Spacer(Modifier.width(8.dp))
        BarIconButton(BridgeyIcons.SkipNext, stringResource(R.string.media_next), { actions.media("next", "") }, enabled = ready)
    }
    val sliderColors = SliderDefaults.colors(thumbColor = colors.primary, activeTrackColor = colors.primary, inactiveTrackColor = colors.surface3)
    if (media.duration > 0) {
        var position by remember(media.position, media.duration) { mutableFloatStateOf(media.position.coerceAtMost(media.duration).toFloat()) }
        Slider(
            value = position,
            enabled = ready,
            onValueChange = { position = it },
            valueRange = 0f..media.duration.toFloat(),
            onValueChangeFinished = { actions.media("seek", position.toInt().toString()) },
            colors = sliderColors,
            modifier = Modifier.semantics { },
        )
        Text(
            "${position.toInt() / 60}:${(position.toInt() % 60).toString().padStart(2, '0')} / ${media.duration / 60}:${(media.duration % 60).toString().padStart(2, '0')}",
            style = BridgeyType.small,
            color = colors.onSurfaceVariant,
        )
    }
    var volume by remember(media.volume) { mutableFloatStateOf(media.volume.toFloat()) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(BridgeyIcons.VolumeUp, contentDescription = stringResource(R.string.media_volume), tint = colors.onSurfaceVariant, modifier = Modifier.size(20.dp))
        Slider(
            value = volume,
            enabled = ready,
            onValueChange = { volume = it },
            valueRange = 0f..100f,
            onValueChangeFinished = { actions.media("volume", volume.toInt().toString()) },
            colors = sliderColors,
            modifier = Modifier.weight(1f),
        )
    }
}

/** Shown where the stream would be when nothing has happened yet. */
@Composable
fun StreamEmpty(title: String, body: String) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        IconTile(BridgeyIcons.Devices, Tint.BLUE, size = 48.dp, corner = 16.dp)
        Spacer(Modifier.height(6.dp))
        Text(title, style = BridgeyType.rowTitle)
        Note(body, center = true)
    }
}
