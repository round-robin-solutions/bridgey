package dev.bridgey.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.folders.ConflictChoice
import dev.bridgey.android.folders.FolderPolicy
import dev.bridgey.android.folders.FolderQuestion
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import kotlinx.coroutines.delay

/** A place as one tap row in the Save to… sheet. */
data class SheetPlace(val placeId: String, val label: String, val available: Boolean, val isDefault: Boolean = false, val storageTitle: String? = null)

/** A recent destination: a place plus a folder inside it ("Pictures/Trip"). */
data class SheetRecent(val placeId: String, val path: String, val label: String)

class FolderSheetActions(
    val choose: (placeId: String, path: String) -> Unit = { _, _ -> },
    val otherFolder: (addToPlaces: Boolean) -> Unit = {},
    val answer: (ConflictChoice) -> Unit = {},
    val cancel: () -> Unit = {},
)

/**
 * The phone's folder question (6.4) as sheet content: Save to… (mode b and the fallbacks) or the conflict
 * question, with the 3 minute countdown. Hosted by a bottom sheet in the app; the screenshots draw it as is.
 */
@Composable
fun FolderQuestionSheet(
    question: FolderQuestion,
    places: List<SheetPlace>,
    recent: List<SheetRecent>,
    actions: FolderSheetActions,
    modifier: Modifier = Modifier,
) {
    val clock = LocalNow.current
    var now by remember { mutableLongStateOf(clock()) }
    LaunchedEffect(question.deadlineMillis) {
        while (true) {
            now = clock()
            delay(1_000)
        }
    }
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
        when (question.kind) {
            FolderQuestion.Kind.DESTINATION -> SaveToContent(question, places, recent, actions)
            FolderQuestion.Kind.CONFLICT -> ConflictContent(question, actions)
        }
        Row(
            Modifier.fillMaxWidth().padding(start = 24.dp, end = 16.dp, top = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.sheet_cancels_in, FolderText.countdown(question.deadlineMillis, now)),
                style = BridgeyType.small,
                color = BridgeyTheme.colors.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            TonalPillButton(stringResource(R.string.action_cancel), actions.cancel, tint = Tint.NEUTRAL)
        }
    }
}

@Composable
private fun SheetHeader(title: String, subtitle: String?) {
    Column(Modifier.padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 4.dp)) {
        Text(title, style = BridgeyType.cardTitle, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.semantics { heading() })
        if (subtitle != null) Text(subtitle, style = BridgeyType.itemBody, color = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun SaveToContent(question: FolderQuestion, places: List<SheetPlace>, recent: List<SheetRecent>, actions: FolderSheetActions) {
    val context = LocalContext.current
    var addToPlaces by rememberSaveable(question.folderTransferId) { mutableStateOf(false) }
    SheetHeader(
        stringResource(R.string.sheet_save_to_title, question.rootName),
        stringResource(R.string.sheet_save_to_subtitle, question.deviceName, FolderText.files(context, question.fileCount), FolderText.size(context, question.totalBytes)),
    )
    val reason = when (question.reason) {
        FolderPolicy.AskReason.DEFAULT_UNAVAILABLE -> question.unavailableDefaultLabel?.let { stringResource(R.string.sheet_reason_default_unavailable, it) }
        FolderPolicy.AskReason.NO_DESTINATION -> stringResource(R.string.sheet_reason_no_destination, question.deviceName)
        else -> null
    }
    if (reason != null) Note(reason, Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
    if (recent.isNotEmpty()) {
        SectionLabel(stringResource(R.string.sheet_recent), Modifier.padding(top = 16.dp, bottom = 8.dp))
        RowGroup {
            recent.forEach { item ->
                row { shape ->
                    ListRow(shape, item.label, null, BridgeyIcons.Folder, Tint.GREEN, compact = true, onClick = { actions.choose(item.placeId, item.path) })
                }
            }
        }
    }
    SectionLabel(stringResource(R.string.sheet_places), Modifier.padding(top = 16.dp, bottom = 8.dp))
    RowGroup {
        places.forEach { place ->
            row { shape ->
                val detail = when {
                    !place.available -> stringResource(R.string.place_not_available)
                    place.isDefault -> stringResource(R.string.place_default_detail)
                    else -> place.storageTitle
                }
                ListRow(
                    shape, place.label, detail, if (place.isDefault) BridgeyIcons.Download else BridgeyIcons.Folder,
                    if (place.available) Tint.BLUE else Tint.NEUTRAL, compact = true, detailWarning = !place.available,
                    onClick = if (place.available) ({ actions.choose(place.placeId, "") }) else null,
                )
            }
        }
        row { shape ->
            ListRow(
                shape, stringResource(R.string.sheet_other_folder), stringResource(R.string.sheet_other_folder_detail),
                BridgeyIcons.Add, Tint.NEUTRAL, compact = true, onClick = { actions.otherFolder(addToPlaces) },
            ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant) }
        }
    }
    Row(
        Modifier
            .padding(horizontal = 24.dp)
            .padding(top = 4.dp)
            .heightIn(min = 48.dp)
            .toggleable(value = addToPlaces, role = Role.Checkbox, onValueChange = { addToPlaces = it }),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = addToPlaces,
            onCheckedChange = null,
            colors = CheckboxDefaults.colors(checkedColor = BridgeyTheme.colors.primary, uncheckedColor = BridgeyTheme.colors.outline),
        )
        Text(stringResource(R.string.sheet_add_to_places), style = BridgeyType.bodyText, modifier = Modifier.padding(start = 12.dp))
    }
}

@Composable
private fun ConflictContent(question: FolderQuestion, actions: FolderSheetActions) {
    val body = when {
        question.confirmsRemoteReplace -> stringResource(R.string.conflict_confirm_replace, question.deviceName)
        question.existing == FolderPolicy.Existing.FILE -> stringResource(R.string.conflict_existing_file)
        question.clashingFiles == null -> stringResource(R.string.conflict_clashes_unknown)
        else -> pluralStringResource(R.plurals.conflict_clashes, question.fileCount, question.clashingFiles, question.fileCount)
    }
    SheetHeader(stringResource(R.string.conflict_title, question.rootName, question.destinationLabel), null)
    Note(body, Modifier.padding(horizontal = 24.dp, vertical = 4.dp))
    if (question.confirmsRemoteReplace && question.clashingFiles != null) {
        Note(
            pluralStringResource(R.plurals.conflict_clashes, question.fileCount, question.clashingFiles, question.fileCount),
            Modifier.padding(horizontal = 24.dp, vertical = 2.dp),
        )
    }
    Column(Modifier.padding(top = 12.dp)) {
        // Merge first and highlighted (the default); Replace is never the default.
        val order = listOf(ConflictChoice.MERGE, ConflictChoice.REPLACE, ConflictChoice.NEW_FOLDER).filter { it in question.choices }
        RowGroup {
            order.forEachIndexed { index, choice ->
                row { shape ->
                    val (title, detail) = when (choice) {
                        ConflictChoice.MERGE -> stringResource(R.string.conflict_merge) to stringResource(R.string.conflict_merge_detail)
                        ConflictChoice.REPLACE -> stringResource(R.string.conflict_replace) to stringResource(R.string.conflict_replace_detail)
                        else -> stringResource(R.string.conflict_new_folder, question.newFolderName) to stringResource(R.string.conflict_new_folder_detail)
                    }
                    val icon = when (choice) {
                        ConflictChoice.MERGE -> BridgeyIcons.Folder
                        ConflictChoice.REPLACE -> BridgeyIcons.SwapHoriz
                        else -> BridgeyIcons.Add
                    }
                    val primary = index == 0
                    ListRow(shape, title, detail, icon, if (primary) Tint.BLUE else Tint.NEUTRAL, onClick = { actions.answer(choice) }, role = Role.Button)
                }
            }
        }
    }
}

/** The sheet's own surface for previews and screenshots: rounded top, drag handle. */
@Composable
fun FolderSheetSurface(content: @Composable () -> Unit) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
            .background(colors.surface2)
            .padding(top = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.width(32.dp).size(width = 32.dp, height = 4.dp).clip(RoundedCornerShape(2.dp)).background(colors.outline))
        Box(Modifier.fillMaxWidth().padding(top = 12.dp)) { content() }
    }
}
