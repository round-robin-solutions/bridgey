package dev.bridgey.android.ui.attach

import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.MediaAccess
import dev.bridgey.android.browse.MediaItem
import dev.bridgey.android.ui.BridgeyIcons
import dev.bridgey.android.ui.GradientButton
import dev.bridgey.android.ui.IconTile
import dev.bridgey.android.ui.ListRow
import dev.bridgey.android.ui.Note
import dev.bridgey.android.ui.OutlinePillButton
import dev.bridgey.android.ui.Tint
import dev.bridgey.android.ui.TonalPillButton
import dev.bridgey.android.ui.groupShape
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.selectionPop
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import kotlinx.coroutines.flow.distinctUntilChanged

/** Rows of media to load ahead of the last visible one: three rows of three. */
private const val PREFETCH_AHEAD = 9

/** Start the next page this many items before the end. */
private const val PAGE_AHEAD = 30

/**
 * The attach sheet's content (hosted by a bottom sheet in the app; screenshots draw it as is). Tabs: Photos and
 * Videos, Files, Folders. Picks keep their order across tabs; Send sends them in that order.
 */
@Composable
fun AttachSheetContent(state: AttachState, actions: AttachActions, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().height(640.dp)) {
        AttachHeader(state, actions)
        AttachTabs(state.tab, actions.selectTab)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (state.tab) {
                AttachTab.MEDIA -> MediaTab(state, actions)
                AttachTab.FILES -> FilesTab(state, actions)
                AttachTab.FOLDERS -> FoldersTab(state, actions)
            }
        }
        SendBar(state, actions)
    }
}

@Composable
private fun AttachHeader(state: AttachState, actions: AttachActions) {
    var browsing by remember { mutableStateOf(false) }
    val colors = BridgeyTheme.colors
    Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            state.target?.let { stringResource(R.string.attach_title_to, it.name) } ?: stringResource(R.string.attach_title),
            style = BridgeyType.cardTitle,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        Box {
            TonalPillButton(stringResource(R.string.attach_browse), { browsing = true }, tint = Tint.NEUTRAL)
            DropdownMenu(
                expanded = browsing,
                onDismissRequest = { browsing = false },
                containerColor = colors.surface2,
                shape = RoundedCornerShape(20.dp),
            ) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.attach_browse_files), style = BridgeyType.label, color = colors.onSurface) },
                    leadingIcon = { Icon(BridgeyIcons.Description, null, tint = colors.onSurfaceVariant) },
                    onClick = {
                        browsing = false
                        actions.browseFiles()
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.attach_browse_folder), style = BridgeyType.label, color = colors.onSurface) },
                    leadingIcon = { Icon(BridgeyIcons.Folder, null, tint = colors.onSurfaceVariant) },
                    enabled = state.canSendFolders,
                    onClick = {
                        browsing = false
                        actions.browseFolder()
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                )
            }
        }
    }
}

@Composable
private fun AttachTabs(selected: AttachTab, onSelect: (AttachTab) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AttachTab.entries.forEach { tab ->
            TabChip(
                stringResource(
                    when (tab) {
                        AttachTab.MEDIA -> R.string.attach_tab_media
                        AttachTab.FILES -> R.string.attach_tab_files
                        AttachTab.FOLDERS -> R.string.attach_tab_folders
                    },
                ),
                selected = tab == selected,
                onClick = { onSelect(tab) },
            )
        }
    }
}

@Composable
private fun TabChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    Box(Modifier.heightIn(min = 48.dp).selectable(selected = selected, role = Role.Tab, onClick = onClick), contentAlignment = Alignment.Center) {
        Row(
            Modifier
                .height(32.dp)
                .clip(RoundedCornerShape(10.dp))
                .then(if (selected) Modifier.background(colors.tintBlue) else Modifier.border(1.dp, colors.outline, RoundedCornerShape(10.dp)))
                .padding(horizontal = 12.dp)
                .selectionPop(selected),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, style = BridgeyType.chip, color = if (selected) colors.onSurface else colors.onSurfaceVariant, maxLines = 1)
        }
    }
}

// MARK: Photos and Videos

@Composable
private fun MediaTab(state: AttachState, actions: AttachActions) {
    if (state.mediaAccess == MediaAccess.NONE) {
        PermissionCard(state.mediaPrompt, actions)
        return
    }
    val thumbnails = LocalMediaThumbnails.current
    val grid = rememberLazyGridState()
    val order = state.order
    LaunchedEffect(grid, state.media) {
        snapshotFlow { grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .distinctUntilChanged()
            .collect { last ->
                val media = state.media
                if (media.isEmpty()) return@collect
                thumbnails.prefetch(media.subList((last + 1).coerceAtMost(media.size), (last + 1 + PREFETCH_AHEAD).coerceAtMost(media.size)))
                if (state.mediaMore && last >= media.size - PAGE_AHEAD) actions.loadMoreMedia()
            }
    }
    Column(Modifier.fillMaxSize()) {
        if (state.mediaAccess == MediaAccess.PARTIAL) PartialBanner(actions)
        if (state.media.isEmpty()) {
            Note(stringResource(R.string.attach_media_empty), Modifier.padding(32.dp), center = true)
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                state = grid,
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                itemsIndexed(state.media, key = { _, item -> item.mediaId }, contentType = { _, _ -> "media" }) { index, item ->
                    val key = AttachKeys.media(item)
                    MediaCell(item, order[key], first = index == 0) { actions.toggle(key) }
                }
            }
        }
    }
}

@Composable
private fun MediaCell(item: MediaItem, pick: Int?, first: Boolean, onToggle: () -> Unit) {
    val context = LocalContext.current
    val colors = BridgeyTheme.colors
    val motion = LocalMotion.current
    val thumbnails = LocalMediaThumbnails.current
    // Memory hits draw in the first frame; misses load once and fade in.
    val bitmap by produceState<ImageBitmap?>(thumbnails.cached(item), item.mediaId, item.modifiedMillis) {
        if (value == null) value = thumbnails.load(item)
    }
    val shown by animateFloatAsState(if (bitmap != null) 1f else 0f, motion.fadeSpec<Float>(), label = "thumb")
    val selected = pick != null
    val inset by animateFloatAsState(if (selected) 0.88f else 1f, motion.spatial<Float>(motion.small), label = "pick")
    val description = stringResource(if (item.isVideo) R.string.attach_video_description else R.string.attach_photo_description, Formatter.formatShortFileSize(context, item.size))
    Box(
        Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(if (first) 18.dp else 6.dp, 6.dp, 6.dp, 6.dp))
            .background(colors.surface3)
            .toggleable(value = selected, role = Role.Checkbox, onValueChange = { onToggle() })
            .semantics {
                contentDescription = description
                if (pick != null) stateDescription = pick.toString()
            },
    ) {
        bitmap?.let { image ->
            Image(
                image,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize().graphicsLayer {
                    alpha = shown
                    scaleX = inset
                    scaleY = inset
                },
            )
        }
        if (item.isVideo) {
            Row(
                Modifier.align(Alignment.BottomStart).padding(6.dp).clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(BridgeyIcons.PlayArrow, null, tint = Color.White, modifier = Modifier.size(14.dp))
                Text(item.durationMs?.let(AttachSelection::duration) ?: "", style = BridgeyType.tiny, color = Color.White)
            }
        }
        PickCounter(pick, Modifier.align(Alignment.TopEnd).padding(6.dp))
    }
}

/** Telegram's counter: an empty ring until picked, then the pick number on the primary colour. */
@Composable
private fun PickCounter(pick: Int?, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Box(
        modifier
            .size(24.dp)
            .selectionPop(pick != null)
            .clip(CircleShape)
            .background(if (pick != null) colors.primary else Color.Black.copy(alpha = 0.25f))
            .border(1.5.dp, if (pick != null) colors.primary else Color.White, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        if (pick != null) Text(pick.toString(), style = BridgeyType.smallStrong, color = colors.onPrimary, textAlign = TextAlign.Center)
    }
}

@Composable
private fun PermissionCard(prompt: MediaPrompt, actions: AttachActions) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(16.dp).clip(RoundedCornerShape(24.dp)).background(colors.surface1).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconTile(BridgeyIcons.Image, Tint.BLUE)
        Text(stringResource(R.string.attach_media_access_title), style = BridgeyType.rowTitle, modifier = Modifier.padding(top = 4.dp))
        Text(stringResource(R.string.attach_media_access_body), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        Text(stringResource(R.string.attach_media_access_mac), style = BridgeyType.small, color = colors.onSurfaceVariant)
        Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.End) {
            if (prompt == MediaPrompt.OPEN_SETTINGS) {
                TonalPillButton(stringResource(R.string.attach_media_open_settings), actions.allowAllPhotos)
            } else {
                TonalPillButton(stringResource(R.string.attach_media_allow), actions.requestMedia)
            }
        }
    }
}

@Composable
private fun PartialBanner(actions: AttachActions) {
    val colors = BridgeyTheme.colors
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).clip(RoundedCornerShape(18.dp)).background(colors.surface1)
            .padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(R.string.attach_media_partial), style = BridgeyType.small, color = colors.onSurfaceVariant, modifier = Modifier.weight(1f))
        TonalPillButton(stringResource(R.string.attach_media_select_more), actions.selectMorePhotos, tint = Tint.NEUTRAL)
        TonalPillButton(stringResource(R.string.attach_media_allow_all), actions.allowAllPhotos)
    }
}

// MARK: Files

@Composable
private fun FilesTab(state: AttachState, actions: AttachActions) {
    val context = LocalContext.current
    val order = state.order
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 8.dp, bottom = 8.dp)) {
        if (state.showDocumentsCard) {
            item(key = "card") { DocumentsCard(actions) }
        }
        if (state.documents.isEmpty() && !state.showDocumentsCard) {
            item(key = "empty") {
                Note(
                    stringResource(if (state.documentsIndexing) R.string.attach_files_indexing else R.string.attach_files_empty),
                    Modifier.padding(horizontal = 32.dp, vertical = 24.dp),
                    center = true,
                )
            }
        }
        itemsIndexed(state.documents, key = { _, item -> item.documentUri }) { index, item ->
            val key = AttachKeys.document(item)
            val pick = order[key]
            val detail = listOf(
                Formatter.formatShortFileSize(context, item.size),
                DateUtils.getRelativeTimeSpanString(item.modifiedMillis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString(),
                item.location,
            ).filter { it.isNotBlank() }.joinToString(" · ")
            Box(Modifier.padding(horizontal = 16.dp, vertical = 1.dp)) {
                ListRow(
                    groupShape(index, state.documents.size + if (state.hasDocumentPlace) 1 else 0),
                    item.name, detail, BridgeyIcons.Description, if (pick != null) Tint.BLUE else Tint.NEUTRAL,
                    compact = true, onClick = { actions.toggle(key) }, role = Role.Checkbox,
                ) { PickCounter(pick) }
            }
        }
        if (state.hasDocumentPlace) {
            item(key = "add") {
                Box(Modifier.padding(horizontal = 16.dp, vertical = 1.dp)) {
                    ListRow(
                        groupShape(state.documents.size, state.documents.size + 1),
                        stringResource(R.string.attach_files_add_folder), stringResource(R.string.attach_files_add_folder_detail),
                        BridgeyIcons.Add, Tint.NEUTRAL, compact = true, onClick = actions.addFolder,
                    )
                }
            }
        }
    }
}

@Composable
private fun DocumentsCard(actions: AttachActions) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(24.dp)).background(colors.surface1).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        IconTile(BridgeyIcons.Description, Tint.GREEN)
        Text(stringResource(R.string.attach_documents_title), style = BridgeyType.rowTitle, modifier = Modifier.padding(top = 4.dp))
        Text(stringResource(R.string.attach_documents_body), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        Text(stringResource(R.string.attach_documents_download_note), style = BridgeyType.small, color = colors.onSurfaceVariant)
        Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
            TonalPillButton(stringResource(R.string.attach_documents_later), actions.dismissDocumentsCard, tint = Tint.NEUTRAL)
            TonalPillButton(stringResource(R.string.attach_documents_choose), actions.grantDocuments)
        }
    }
}

// MARK: Folders

@Composable
private fun FoldersTab(state: AttachState, actions: AttachActions) {
    val order = state.order
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 8.dp, bottom = 8.dp)) {
        if (!state.canSendFolders) {
            item(key = "note") {
                Note(
                    stringResource(R.string.attach_folders_unsupported, state.target?.name ?: stringResource(R.string.attach_this_device)),
                    Modifier.padding(horizontal = 32.dp, vertical = 8.dp),
                )
            }
        }
        itemsIndexed(state.folders, key = { _, folder -> folder.placeId }) { index, folder ->
            val key = AttachKeys.folder(folder.placeId)
            val pick = order[key]
            val enabled = state.canSendFolders && folder.available
            Box(Modifier.padding(horizontal = 16.dp, vertical = 1.dp).graphicsLayer { alpha = if (enabled) 1f else 0.5f }) {
                ListRow(
                    groupShape(index, state.folders.size + 1),
                    folder.label,
                    if (!folder.available) stringResource(R.string.place_not_available) else folder.detail,
                    if (folder.isDefault) BridgeyIcons.Download else BridgeyIcons.Folder,
                    if (pick != null) Tint.BLUE else Tint.GREEN,
                    compact = true,
                    detailWarning = !folder.available,
                    onClick = if (enabled) ({ actions.toggle(key) }) else null,
                    role = Role.Checkbox,
                ) { if (enabled) PickCounter(pick) }
            }
        }
        item(key = "add") {
            Box(Modifier.padding(horizontal = 16.dp, vertical = 1.dp)) {
                ListRow(
                    groupShape(state.folders.size, state.folders.size + 1),
                    stringResource(R.string.attach_files_add_folder), stringResource(R.string.attach_folders_add_detail),
                    BridgeyIcons.Add, Tint.NEUTRAL, compact = true, onClick = actions.addFolder,
                )
            }
        }
    }
}

// MARK: Send

@Composable
private fun SendBar(state: AttachState, actions: AttachActions) {
    val context = LocalContext.current
    val colors = BridgeyTheme.colors
    var picking by remember { mutableStateOf(false) }
    val count = state.selection.size
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (state.targets.size > 1) {
            Box {
                OutlinePillButton(state.target?.name ?: "", BridgeyIcons.LaptopMac, { picking = true }, modifier = Modifier.widthIn(max = 180.dp))
                DropdownMenu(expanded = picking, onDismissRequest = { picking = false }, containerColor = colors.surface2, shape = RoundedCornerShape(20.dp)) {
                    state.targets.forEach { target ->
                        DropdownMenuItem(
                            text = { Text(target.name, style = BridgeyType.label, color = colors.onSurface) },
                            trailingIcon = if (target.deviceId == state.target?.deviceId) ({ Icon(BridgeyIcons.Check, null, tint = colors.primary) }) else null,
                            onClick = {
                                picking = false
                                actions.pickTarget(target.deviceId)
                            },
                            modifier = Modifier.heightIn(min = 48.dp),
                        )
                    }
                }
            }
        }
        Box(Modifier.weight(1f))
        val label = when {
            count == 0 -> stringResource(R.string.attach_send_none)
            state.selectedBytes > 0 -> pluralStringResource(R.plurals.attach_send_count_size, count, count, Formatter.formatShortFileSize(context, state.selectedBytes))
            else -> pluralStringResource(R.plurals.attach_send_count, count, count)
        }
        GradientButton(label, BridgeyIcons.Send, actions.send, enabled = count > 0 && state.target != null, height = 48.dp, textStyle = BridgeyType.label)
    }
}
