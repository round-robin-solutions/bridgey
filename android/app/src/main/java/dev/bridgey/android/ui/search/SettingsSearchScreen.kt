package dev.bridgey.android.ui.search

import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.ui.BarIconButton
import dev.bridgey.android.ui.BridgeyIcons
import dev.bridgey.android.ui.IconTile
import dev.bridgey.android.ui.Note
import dev.bridgey.android.ui.RowGroup
import dev.bridgey.android.ui.SectionLabel
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.motion.MotionSpec
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop

/** Light mode band behind the search bar: status bar + 56 dp + 8 dp, as on the other Settings pages. */
private val SearchBandHeight = 64.dp

/** One group of results: a page (or a device) and its rows, best first. */
private data class ResultGroup(val key: String, val title: String, val rows: List<Pair<SearchResultEntry, SearchHit?>>)

/** Groups and rows fade in and slide into place as the results change (opacity and transform only). */
private fun Modifier.appear(scope: LazyItemScope, motion: MotionSpec): Modifier = with(scope) {
    this@appear.animateItem(
        fadeInSpec = motion.fadeSpec(),
        fadeOutSpec = null,
        placementSpec = motion.spatial(motion.small, IntOffset.VisibilityThreshold),
    )
}

/**
 * Settings search: a field on the page bar, then the matching rows grouped by page, each with the page's tile,
 * the title with what matched marked, and where it lives ("Notifications › Codes from messages"). With nothing
 * found, the closest matches. Choosing a row calls [onOpen]; the query stays when coming back.
 */
@Composable
fun SettingsSearchScreen(entries: List<SearchResultEntry>, onBack: () -> Unit, onOpen: (SearchResultEntry) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val docs = remember(entries) { entries.map { it.doc } }
    val hits = remember(query, docs) { SettingsSearch.search(query, docs) }
    val groups = remember(hits, entries) {
        val byGroup = LinkedHashMap<String, MutableList<Pair<SearchResultEntry, SearchHit?>>>()
        hits.forEach { hit ->
            val entry = entries[hit.index]
            byGroup.getOrPut("${entry.group}\u0000${entry.route.key}") { mutableListOf() } += entry to hit
        }
        byGroup.map { (key, rows) -> ResultGroup(key, rows.first().first.group, rows) }
    }
    val closest = remember(query, docs, hits) {
        if (query.isBlank() || hits.isNotEmpty()) emptyList() else SettingsSearch.closest(query, docs).map { entries[it] }
    }
    val motion = LocalMotion.current
    val keyboard = LocalSoftwareKeyboardController.current
    // Only a fresh search takes the keyboard; coming back from a result keeps the list in view.
    val autofocus = rememberSaveable { query.isEmpty() }
    ScreenBackdrop(bandHeight = statusTop + SearchBandHeight) {
        Column(Modifier.fillMaxSize()) {
            OnBand { SearchBar(query, { query = it }, onBack, autofocus) { keyboard?.hide() } }
            LazyColumn(Modifier.fillMaxSize(), state = rememberLazyListState(), contentPadding = PaddingValues(bottom = navBottom + 32.dp)) {
                when {
                    query.isBlank() -> item(key = "hint") {
                        Note(stringResource(R.string.settings_search_hint), Modifier.appear(this, motion).padding(start = 32.dp, end = 32.dp, top = 24.dp))
                    }
                    groups.isEmpty() -> {
                        item(key = "none") {
                            Note(
                                stringResource(R.string.settings_search_no_results, query.trim()),
                                Modifier.appear(this, motion).padding(start = 32.dp, end = 32.dp, top = 24.dp),
                            )
                        }
                        if (closest.isNotEmpty()) {
                            item(key = "closest.label") {
                                SectionLabel(stringResource(R.string.settings_search_closest), Modifier.appear(this, motion).padding(top = 24.dp))
                            }
                            item(key = "closest") {
                                RowGroup(Modifier.appear(this, motion).padding(top = 8.dp)) {
                                    closest.forEach { entry -> row { shape -> ResultRow(shape, entry, null) { onOpen(entry) } } }
                                }
                            }
                        }
                    }
                    else -> groups.forEachIndexed { index, group ->
                        item(key = "label.${group.key}") {
                            SectionLabel(group.title, Modifier.appear(this, motion).padding(top = if (index == 0) 20.dp else 24.dp))
                        }
                        item(key = "group.${group.key}") {
                            RowGroup(Modifier.appear(this, motion).padding(top = 8.dp)) {
                                group.rows.forEach { (entry, hit) -> row { shape -> ResultRow(shape, entry, hit) { onOpen(entry) } } }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchBar(query: String, onQuery: (String) -> Unit, onBack: () -> Unit, autofocus: Boolean, onSearch: () -> Unit) {
    val colors = BridgeyTheme.colors
    val focus = remember { FocusRequester() }
    val placeholder = stringResource(R.string.settings_search_placeholder)
    LaunchedEffect(Unit) { if (autofocus) focus.requestFocus() }
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(start = 4.dp, end = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BarIconButton(BridgeyIcons.ArrowBack, stringResource(R.string.action_back), onBack)
        Row(
            Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(22.dp)).background(colors.surface2).padding(start = 14.dp, end = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(BridgeyIcons.Search, null, tint = colors.onSurfaceVariant, modifier = Modifier.size(20.dp))
            Box(Modifier.weight(1f).padding(start = 10.dp, end = 8.dp), contentAlignment = Alignment.CenterStart) {
                if (query.isEmpty()) Text(placeholder, style = BridgeyType.bodyText, color = colors.onSurfaceVariant, maxLines = 1)
                BasicTextField(
                    value = query,
                    onValueChange = onQuery,
                    singleLine = true,
                    textStyle = BridgeyType.bodyText.copy(color = colors.onSurface),
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { onSearch() }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus).testTag("settings-search-field")
                        .semantics { contentDescription = placeholder },
                )
            }
            if (query.isNotEmpty()) {
                BarIconButton(BridgeyIcons.Close, stringResource(R.string.settings_search_clear), { onQuery(""); focus.requestFocus() }, size = 40.dp)
            }
        }
    }
}

/** A result: the page's tile, the title with the match marked, where it lives, and the matched description. */
@Composable
private fun ResultRow(shape: Shape, entry: SearchResultEntry, hit: SearchHit?, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    val mark = SpanStyle(color = colors.onTintBlue, fontWeight = FontWeight.Bold)
    val subtitle = entry.subtitle
    val showSubtitle = hit != null && hit.titleRanges.isEmpty() && hit.subtitleRanges.isNotEmpty() && subtitle != null
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(shape)
            .background(colors.surface1)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        IconTile(entry.icon, entry.tint)
        Column(Modifier.weight(1f)) {
            Text(marked(entry.title, hit?.titleRanges.orEmpty(), mark), style = BridgeyType.rowTitle, color = colors.onSurface)
            Text(
                entry.breadcrumb, style = BridgeyType.itemBody, color = colors.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 1.dp),
            )
            if (showSubtitle && subtitle != null) {
                Text(
                    marked(subtitle, hit.subtitleRanges, mark), style = BridgeyType.small, color = colors.onSurfaceVariant,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
        Icon(BridgeyIcons.ChevronRight, null, tint = colors.onSurfaceVariant)
    }
}

/** [text] with [ranges] in [style]. */
internal fun marked(text: String, ranges: List<IntRange>, style: SpanStyle): AnnotatedString = buildAnnotatedString {
    append(text)
    ranges.forEach { r ->
        val start = r.first.coerceIn(0, text.length)
        val end = (r.last + 1).coerceIn(start, text.length)
        if (end > start) addStyle(style, start, end)
    }
}
