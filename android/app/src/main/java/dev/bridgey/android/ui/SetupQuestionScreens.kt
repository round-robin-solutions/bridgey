package dev.bridgey.android.ui

import androidx.annotation.StringRes
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.bridgey.android.R
import dev.bridgey.android.setup.Answers
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupQuestion
import dev.bridgey.android.setup.SetupQuestions
import dev.bridgey.android.setup.SetupScreen
import dev.bridgey.android.setup.SetupSummary
import dev.bridgey.android.setup.SetupTyped
import dev.bridgey.android.setup.SummaryItem
import dev.bridgey.android.ui.motion.LocalMotion
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import dev.bridgey.android.ui.theme.OnBand
import dev.bridgey.android.ui.theme.ScreenBackdrop

/*
 * The question path: Intro (what brought you here, or type it), one card per question, the
 * permission an answer needs, and the summary. Cards change with a short shared-axis move
 * (transform and opacity only); reduced motion cross-fades. The predictive back gesture nudges
 * the card towards the previous one while it is held.
 */

/** Where a screen sits in the path, so a change knows whether it moves forward or back. */
private fun SetupScreen.depth(trail: Int): Float = if (this == SetupScreen.Intro) 0f else trail.toFloat()

/** Remembers the last depth, to tell forward from back (plain state, read during composition). */
private class CardDirection(private var last: Float) {
    private var forward = true

    fun update(depth: Float): Boolean {
        if (depth != last) {
            forward = depth > last
            last = depth
        }
        return forward
    }
}

/** The question path's screens, with the card motion between them. */
@Composable
internal fun QuestionPath(state: SetupUiState, actions: SetupActions) {
    val motion = LocalMotion.current
    val density = LocalDensity.current
    val shift = with(density) { 24.dp.toPx() }
    val flow = state.flow
    val back = LocalPageBack.current
    val gesture by animateFloatAsState(back?.progress ?: 0f, motion.fadeSpec(), label = "setup back")
    val depth = flow.screen.depth(flow.trail.size)
    val direction = remember { CardDirection(depth) }
    val forward = direction.update(depth)
    AnimatedContent(
        targetState = flow.screen,
        transitionSpec = { EnterTransition.None togetherWith ExitTransition.None },
        label = "setup card",
    ) { screen ->
        // Forward: the new card comes from the right and the old one leaves to the left; back reverses it.
        val shown by transition.animateFloat(
            transitionSpec = { if (motion.moves) motion.page.spec() else motion.fadeSpec() },
            label = "setup card shown",
        ) { if (it == EnterExitState.Visible) 1f else 0f }
        val entering = transition.targetState == EnterExitState.Visible
        Box(
            Modifier.fillMaxSize().graphicsLayer {
                val hidden = 1f - shown.coerceIn(0f, 1f)
                alpha = shown.coerceIn(0f, 1f) * (1f - 0.2f * gesture)
                if (motion.moves) {
                    val direction = if (entering == forward) 1f else -1f
                    translationX = hidden * shift * direction + gesture * shift
                }
            },
        ) {
            when (screen) {
                SetupScreen.Intro -> IntroPage(state, actions)
                is SetupScreen.Question -> SetupQuestions.question(screen.id)?.let { QuestionPage(it, state, actions) }
                SetupScreen.Switches -> SwitchesPage(state, actions)
                SetupScreen.Permissions -> PermissionsPage(state, actions)
                SetupScreen.Summary -> SummaryPage(state, actions)
                else -> Unit
            }
        }
    }
}

/** The bar on every question screen: back, the steps left, Leave setup. */
@Composable
private fun QuestionFrame(
    state: SetupUiState,
    actions: SetupActions,
    showBack: Boolean = true,
    progress: Boolean = true,
    footer: @Composable () -> Unit,
    content: LazyListScope.() -> Unit,
) {
    val colors = BridgeyTheme.colors
    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    ScreenBackdrop(bandHeight = statusTop + 64.dp) {
        Column(Modifier.fillMaxSize()) {
            OnBand {
                Row(
                    Modifier.fillMaxWidth().statusBarsPadding().height(56.dp).padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (showBack) {
                        BarIconButton(BridgeyIcons.ArrowBack, stringResource(R.string.action_back), { actions.event(SetupEvent.Back) })
                    } else {
                        Spacer(Modifier.size(48.dp))
                    }
                    Text(
                        stringResource(R.string.setup_advanced_title),
                        style = BridgeyType.pageTitle,
                        modifier = Modifier.weight(1f).padding(start = 4.dp).semantics { heading() },
                        maxLines = 1,
                    )
                    BarIconButton(BridgeyIcons.Close, stringResource(R.string.setup_leave_action), actions.leave)
                }
            }
            if (progress) StepsLeft(state)
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                content = content,
            )
            Box(
                Modifier.fillMaxWidth().background(colors.background).navigationBarsPadding()
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 12.dp),
            ) { footer() }
        }
    }
}

/** A thin bar and "6 steps left", from the questions that will still be asked. */
@Composable
private fun StepsLeft(state: SetupUiState) {
    val colors = BridgeyTheme.colors
    val motion = LocalMotion.current
    val left = SetupFlow.stepsLeft(state.flow, state.facts)
    val done = state.flow.trail.size
    val fraction = if (done + left == 0) 0f else done.toFloat() / (done + left)
    val shown by animateFloatAsState(fraction, if (motion.moves) motion.small.spec() else motion.fadeSpec(), label = "setup progress")
    Row(
        Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.weight(1f).height(4.dp).clip(RoundedCornerShape(2.dp)).background(colors.surface3)) {
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0.5f)
                    scaleX = shown.coerceIn(0f, 1f)
                }.background(colors.primary),
            )
        }
        Text(
            if (left == 0) stringResource(R.string.setup_last_step) else pluralStringResource(R.plurals.setup_steps_left, left, left),
            style = BridgeyType.smallStrong,
            color = colors.onSurfaceVariant,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

/** Section, title and the one line of context. */
private fun LazyListScope.questionHeading(@StringRes eyebrowRes: Int, @StringRes titleRes: Int, @StringRes contextRes: Int) {
    item(key = "heading") {
        val colors = BridgeyTheme.colors
        val eyebrow = stringResource(eyebrowRes)
        val title = stringResource(titleRes)
        val context = stringResource(contextRes)
        Column(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 16.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(eyebrow.uppercase(), style = BridgeyType.section, color = colors.primary)
            Text(title, style = BridgeyType.deviceName, color = colors.onSurface, modifier = Modifier.semantics { heading() })
            Text(context, style = BridgeyType.bodyText, color = colors.onSurfaceVariant)
        }
    }
}

/** A big answer: the label, an optional line under it, and a check when it is the answer given. */
@Composable
private fun AnswerButton(label: String, detail: String?, selected: Boolean, current: Boolean, onClick: () -> Unit) {
    val colors = BridgeyTheme.colors
    val shape = RoundedCornerShape(20.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clip(shape)
            .background(colors.surface1)
            .border(if (selected) 2.dp else 1.dp, if (selected) colors.primary else colors.outlineVariant, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = BridgeyType.rowTitle, color = colors.onSurface)
            if (detail != null) Text(detail, style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
        }
        when {
            selected -> Icon(BridgeyIcons.Check, null, tint = colors.primary, modifier = Modifier.size(22.dp))
            current -> StatusPill(stringResource(R.string.setup_answer_current), null, Tint.NEUTRAL)
        }
    }
}

/** "More options" on the left, "Not now" on the right. */
@Composable
private fun QuestionFooter(moreOptions: (() -> Unit)?, notNow: () -> Unit, notNowLabel: String = stringResource(R.string.setup_not_now)) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        if (moreOptions != null) {
            Text(
                stringResource(R.string.setup_more_options),
                style = BridgeyType.label,
                color = BridgeyTheme.colors.primary,
                modifier = Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = moreOptions)
                    .padding(horizontal = 12.dp, vertical = 14.dp),
            )
        }
        Spacer(Modifier.weight(1f))
        OutlinePillButton(notNowLabel, null, notNow)
    }
}

@Composable
private fun QuestionPage(question: SetupQuestion, state: SetupUiState, actions: SetupActions) {
    val flow = state.flow
    val given = flow.answers[question.id]
    val effective = SetupFlow.effective(flow, state.facts)
    QuestionFrame(
        state, actions,
        footer = {
            QuestionFooter(
                moreOptions = question.settingsPage?.let { page -> { actions.openPage(page) } },
                notNow = { actions.event(SetupEvent.NotNow) },
                notNowLabel = if (question.id == "pair" && state.pairedNames.isNotEmpty()) stringResource(R.string.setup_next) else stringResource(R.string.setup_not_now),
            )
        },
    ) {
        questionHeading(question.section.title, question.title, question.context)
        when {
            question.id == "pair" -> pairQuestion(state, actions)
            question.multiPick -> item(key = "pick") { AppPicker(question, state, actions, given) }
            else -> question.answers.forEach { answer ->
                item(key = "answer.${answer.key}") {
                    AnswerButton(
                        label = stringResource(answer.label),
                        detail = answer.detail?.let { stringResource(it) },
                        selected = given == answer.key,
                        current = given == null && answer.changes.isNotEmpty() && answer.changes.all { effective[it.setting] == it.value },
                        onClick = { actions.event(SetupEvent.Answer(question.id, answer.key)) },
                    )
                }
            }
        }
    }
}

/** Pair a Mac inside the questions: the Macs nearby, Pair new device and Look again. */
private fun LazyListScope.pairQuestion(state: SetupUiState, actions: SetupActions) {
    if (state.pairedNames.isNotEmpty()) {
        item(key = "paired") { StatusPill(stringResource(R.string.setup_pair_done, state.pairedNames.first()), BridgeyIcons.Check, Tint.GREEN) }
    }
    item(key = "pair.nearby") {
        val colors = BridgeyTheme.colors
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (state.nearby.isEmpty()) {
                Note(stringResource(R.string.setup_pair_searching), Modifier.padding(horizontal = 8.dp))
            }
            state.nearby.forEach { mac ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(RoundedCornerShape(20.dp)).background(colors.surface1)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    DeviceGlyph(if (mac.paired) RingStyle.SAME_WIFI else RingStyle.NEARBY, BridgeyIcons.LaptopMac, 40.dp, iconSize = 18.dp)
                    Column(Modifier.weight(1f)) {
                        Text(mac.name, style = BridgeyType.rowTitle, color = colors.onSurface)
                        Text(stringResource(if (mac.paired) R.string.pair_paired_suffix else R.string.pair_new_suffix), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                    }
                    if (mac.paired) Icon(BridgeyIcons.Check, null, tint = colors.onTintGreen) else TonalPillButton(stringResource(R.string.setup_pair_action), { actions.pair(mac) })
                }
            }
        }
    }
    item(key = "pair.more") {
        Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            ListRow(groupShape(0, 2), stringResource(R.string.devices_pair_new), stringResource(R.string.devices_pair_new_detail), BridgeyIcons.Add, Tint.BLUE, onClick = actions.addDevice) {
                Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.onSurfaceVariant)
            }
            ListRow(groupShape(1, 2), stringResource(R.string.look_again), stringResource(R.string.look_again_detail), BridgeyIcons.Refresh, Tint.NEUTRAL, onClick = actions.lookForDevices)
        }
    }
}

/** "Which apps already have a Mac app you use?": a tick per app, then Done or None of these. */
@Composable
private fun AppPicker(question: SetupQuestion, state: SetupUiState, actions: SetupActions, given: String?) {
    val colors = BridgeyTheme.colors
    val start = given?.takeIf { it.startsWith(Answers.PICKED) }?.removePrefix(Answers.PICKED)?.split(',')?.filter { it.isNotEmpty() }.orEmpty()
    var picked by rememberSaveable(question.id) { mutableStateOf(start.joinToString(",")) }
    val set = picked.split(',').filter { it.isNotEmpty() }.toSet()
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        state.facts.duplicateApps.forEach { (pkg, name) ->
            val on = pkg in set
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(20.dp)).background(colors.surface1)
                    .border(if (on) 2.dp else 1.dp, if (on) colors.primary else colors.outlineVariant, RoundedCornerShape(20.dp))
                    .toggleable(value = on, role = Role.Checkbox) { picked = (if (it) set + pkg else set - pkg).joinToString(",") }
                    .padding(horizontal = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(name, style = BridgeyType.rowTitle, color = colors.onSurface, modifier = Modifier.weight(1f))
                if (on) Icon(BridgeyIcons.Check, null, tint = colors.primary, modifier = Modifier.size(22.dp))
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinePillButton(stringResource(R.string.setup_a_notification_apps_none), null, { actions.event(SetupEvent.Answer(question.id, Answers.NONE)) })
            Spacer(Modifier.weight(1f))
            GradientButton(
                stringResource(R.string.setup_a_done), null,
                { actions.event(SetupEvent.Answer(question.id, Answers.PICKED + set.sorted().joinToString(","))) },
                enabled = set.isNotEmpty(), height = 48.dp, textStyle = BridgeyType.label,
            )
        }
    }
}

/** Every feature that was not picked: one plain switch each, off until turned on. */
@Composable
private fun SwitchesPage(state: SetupUiState, actions: SetupActions) {
    val colors = BridgeyTheme.colors
    val effective = SetupFlow.effective(state.flow, state.facts)
    val features = SetupFeatures.all.filter { it.id !in state.flow.picked }
    QuestionFrame(
        state, actions,
        footer = {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.setup_switches_details),
                    style = BridgeyType.label,
                    color = colors.primary,
                    modifier = Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button) { actions.openPage("GENERAL") }
                        .padding(horizontal = 12.dp, vertical = 14.dp),
                )
                Spacer(Modifier.weight(1f))
                GradientButton(stringResource(R.string.setup_continue), null, { actions.event(SetupEvent.Continue) }, height = 48.dp, textStyle = BridgeyType.label)
            }
        },
    ) {
        questionHeading(R.string.setup_advanced_title, R.string.setup_switches_title, R.string.setup_switches_context)
        item(key = "switches") {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                features.forEachIndexed { index, feature ->
                    val on = SetupFeatures.isOn(feature, effective)
                    SwitchRow(
                        groupShape(index, features.size), stringResource(feature.title), stringResource(feature.detail), null,
                        if (on) Tint.BLUE else Tint.NEUTRAL, on, { actions.event(SetupEvent.Switch(feature.id, it)) }, compact = true,
                    )
                }
            }
        }
    }
}

/** How a permission row stands right now. */
private enum class PermissionStatus { ALLOWED, NOT_YET, REFUSED }

/** Every permission the chosen features need, on one page: why, for what, and its status. */
@Composable
private fun PermissionsPage(state: SetupUiState, actions: SetupActions) {
    val colors = BridgeyTheme.colors
    val needed = SetupFlow.neededPermissions(state.flow, state.facts)
    fun status(kind: PermissionKind) = when {
        kind in state.facts.granted -> PermissionStatus.ALLOWED
        kind in state.flow.asked -> PermissionStatus.REFUSED
        else -> PermissionStatus.NOT_YET
    }
    val open = needed.filter { status(it.kind) != PermissionStatus.ALLOWED }
    QuestionFrame(
        state, actions,
        footer = {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinePillButton(stringResource(R.string.setup_continue), null, { actions.event(SetupEvent.Continue) })
                Spacer(Modifier.weight(1f))
                if (open.isNotEmpty()) {
                    GradientButton(stringResource(R.string.setup_allow_all), null, actions.allowAll, height = 48.dp, textStyle = BridgeyType.label)
                }
            }
        },
    ) {
        questionHeading(R.string.setup_advanced_title, R.string.setup_permissions_title, R.string.setup_permissions_context)
        needed.forEach { permission ->
            item(key = "perm.${permission.kind.name}") {
                val (icon, tint) = permissionIcon(permission.kind)
                val current = status(permission.kind)
                // Battery optimisation is for every feature that is on.
                val onNow = SetupFlow.effective(state.flow.copy(refused = emptySet()), state.facts)
                val featureNames = (permission.features.mapNotNull(SetupFeatures::feature).ifEmpty { SetupFeatures.all })
                    .filter { SetupFeatures.isOn(it, onNow) }
                    .map { stringResource(it.title) }
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        IconTile(icon, tint, size = 40.dp, corner = 14.dp, iconSize = 22.dp)
                        Text(permissionName(permission.kind), style = BridgeyType.rowTitle, color = colors.onSurface, modifier = Modifier.weight(1f))
                        StatusPill(
                            stringResource(
                                when (current) {
                                    PermissionStatus.ALLOWED -> R.string.setup_status_allowed
                                    PermissionStatus.NOT_YET -> R.string.setup_status_not_yet
                                    PermissionStatus.REFUSED -> R.string.setup_status_refused
                                },
                            ),
                            if (current == PermissionStatus.ALLOWED) BridgeyIcons.Check else null,
                            when (current) {
                                PermissionStatus.ALLOWED -> Tint.GREEN
                                PermissionStatus.NOT_YET -> Tint.NEUTRAL
                                PermissionStatus.REFUSED -> Tint.PURPLE
                            },
                        )
                    }
                    Text(permissionWhy(permission.kind, textMessages = SetupFeatures.feature("messages")?.let { SetupFeatures.isOn(it, onNow) } == true), style = BridgeyType.itemBody, color = colors.onSurface)
                    Text(
                        if (featureNames.isEmpty()) stringResource(R.string.setup_permissions_needed_connection)
                        else stringResource(R.string.setup_permissions_needed_for, featureNames.joinToString(", ")),
                        style = BridgeyType.itemBody, color = colors.onSurfaceVariant,
                    )
                    if (current != PermissionStatus.ALLOWED) {
                        Row(Modifier.fillMaxWidth()) {
                            Spacer(Modifier.weight(1f))
                            TonalPillButton(stringResource(R.string.setup_allow), { actions.allowPermission(permission.kind) })
                        }
                    }
                }
            }
        }
    }
}

/** The start of the questions: bundles, Type what you want, or straight to the questions. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun IntroPage(state: SetupUiState, actions: SetupActions) {
    val colors = BridgeyTheme.colors
    var text by rememberSaveable { mutableStateOf(state.typedText) }
    var picked by rememberSaveable { mutableStateOf(state.pickedBundles.joinToString(",")) }
    val pickedSet = picked.split(',').filter { it.isNotEmpty() }.toSet()
    val typed = SetupTyped.match(text)
    val chosen = SetupBundles.answers(pickedSet, typed)
    QuestionFrame(
        state, actions,
        showBack = state.flow.entry != SetupScreen.Intro,
        progress = false,
        footer = {
            GradientButton(
                stringResource(if (chosen.isEmpty()) R.string.setup_intro_start else R.string.setup_intro_apply), null,
                { actions.event(SetupEvent.StartQuestions(chosen)) },
                modifier = Modifier.fillMaxWidth(), height = 52.dp, textStyle = BridgeyType.label,
            )
        },
    ) {
        questionHeading(R.string.setup_advanced_title, R.string.setup_intro_title, R.string.setup_intro_body)
        item(key = "bundles") {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 4.dp)) {
                Text(stringResource(R.string.setup_intro_bundles), style = BridgeyType.smallStrong, color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = 8.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SetupBundles.all.forEach { bundle ->
                        val on = bundle.id in pickedSet
                        Row(
                            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp))
                                .background(if (on) colors.primary else colors.surface1)
                                .border(1.dp, if (on) colors.primary else colors.outlineVariant, RoundedCornerShape(24.dp))
                                .toggleable(value = on, role = Role.Checkbox) { picked = (if (it) pickedSet + bundle.id else pickedSet - bundle.id).joinToString(",") }
                                .padding(horizontal = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(if (on) BridgeyIcons.Check else BridgeyIcons.Add, null, tint = if (on) colors.onPrimary else colors.onSurfaceVariant, modifier = Modifier.size(18.dp))
                            Text(stringResource(bundle.title), style = BridgeyType.chip, color = if (on) colors.onPrimary else colors.onSurface)
                        }
                    }
                }
            }
        }
        item(key = "type") {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 10.dp)) {
                Text(stringResource(R.string.setup_intro_type), style = BridgeyType.smallStrong, color = colors.onSurfaceVariant, modifier = Modifier.padding(horizontal = 8.dp))
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it.take(400) },
                    placeholder = { Text(stringResource(R.string.setup_intro_placeholder), style = BridgeyType.bodyText) },
                    textStyle = BridgeyType.bodyText.copy(color = colors.onSurface),
                    minLines = 2,
                    maxLines = 4,
                    shape = RoundedCornerShape(18.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = colors.primary,
                        unfocusedBorderColor = colors.outlineVariant,
                        focusedContainerColor = colors.surface1,
                        unfocusedContainerColor = colors.surface1,
                        cursorColor = colors.primary,
                        focusedPlaceholderColor = colors.onSurfaceVariant,
                        unfocusedPlaceholderColor = colors.onSurfaceVariant,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        item(key = "matched") {
            if (chosen.isNotEmpty()) {
                Column(
                    Modifier.fillMaxWidth().padding(top = 4.dp).clip(RoundedCornerShape(20.dp)).background(colors.surface1).padding(16.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(stringResource(R.string.setup_intro_matched), style = BridgeyType.smallStrong, color = colors.onSurfaceVariant)
                    chosen.forEach { (id, key) ->
                        val (title, value) = chosenLine(id, key) ?: return@forEach
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(if (key == Answers.NO) BridgeyIcons.Close else BridgeyIcons.Check, null, tint = if (key == Answers.NO) colors.onSurfaceVariant else colors.onTintGreen, modifier = Modifier.size(16.dp))
                            Text(stringResource(title), style = BridgeyType.itemTitle, color = colors.onSurface, modifier = Modifier.weight(1f))
                            Text(stringResource(value), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
                        }
                    }
                }
            } else if (text.isNotBlank()) {
                Note(stringResource(R.string.setup_intro_nothing), Modifier.padding(horizontal = 8.dp))
            }
        }
    }
}

/** A line in the start's preview: the feature or question, and what it will be. */
private fun chosenLine(id: String, key: String): Pair<Int, Int>? {
    SetupQuestions.question(id)?.let { question ->
        val answer = SetupQuestions.answer(question, key)
        if (answer != null && question.feature != id) return question.summary to answer.label
    }
    SetupFeatures.feature(id)?.let { feature ->
        val answer = SetupQuestions.question(id)?.let { SetupQuestions.answer(it, key) }
        return feature.title to (answer?.label ?: if (key == Answers.NO) R.string.setup_intro_off else R.string.setup_intro_on)
    }
    return when (id) {
        "focus" -> R.string.setup_q_focus_summary to R.string.setup_a_focus_both
        "updates" -> R.string.setup_q_updates_summary to when (key) {
            Answers.NEWEST -> R.string.setup_a_updates_newest
            Answers.EARLY -> R.string.setup_a_updates_early
            else -> R.string.setup_a_updates_steady
        }
        else -> null
    }
}

/** What is on (each with a switch and Change in Settings), the choices, and what was not allowed. */
@Composable
private fun SummaryPage(state: SetupUiState, actions: SetupActions) {
    val colors = BridgeyTheme.colors
    val items = SetupSummary.items(state.flow, state.facts)
    QuestionFrame(
        state, actions,
        progress = false,
        footer = {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinePillButton(stringResource(R.string.setup_open_settings), null, actions.openSettings)
                Spacer(Modifier.weight(1f))
                GradientButton(stringResource(R.string.setup_summary_start), null, actions.start, height = 48.dp, textStyle = BridgeyType.label)
            }
        },
    ) {
        item(key = "summary.head") {
            Column(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 16.dp, bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                IconTile(BridgeyIcons.CheckCircle, Tint.GREEN, size = 52.dp, corner = 18.dp, iconSize = 28.dp)
                Text(stringResource(R.string.setup_summary_title), style = BridgeyType.deviceName, color = colors.onSurface, modifier = Modifier.semantics { heading() })
                Text(
                    stringResource(if (items.none { it !is SummaryItem.Sync }) R.string.setup_summary_empty else R.string.setup_summary_body),
                    style = BridgeyType.bodyText, color = colors.onSurfaceVariant,
                )
            }
        }
        val on = items.filterIsInstance<SummaryItem.FeatureOn>()
        val chosen = items.filterIsInstance<SummaryItem.Chosen>()
        val refused = items.filterIsInstance<SummaryItem.NotAllowed>()
        if (on.isNotEmpty()) {
            item(key = "on.label") { SummaryLabel(stringResource(R.string.setup_summary_on)) }
            on.forEach { item -> item(key = "on.${item.feature.id}") { FeatureOnRow(item, actions) } }
        }
        if (chosen.isNotEmpty()) {
            item(key = "chosen.label") { SummaryLabel(stringResource(R.string.setup_summary_choices)) }
            chosen.forEach { item ->
                item(key = "chosen.${item.title}") {
                    val value = item.value?.let { stringResource(it) }
                        ?: state.facts.duplicateApps.filter { it.first in item.packages }.joinToString(", ") { it.second }.ifEmpty { item.packages.joinToString(", ") }
                    SummaryRow(stringResource(item.title), value, item.page, actions)
                }
            }
        }
        items.filterIsInstance<SummaryItem.Sync>().firstOrNull()?.let { sync ->
            item(key = "sync") { SyncSummaryRow(sync, actions, Modifier.padding(top = 14.dp)) }
        }
        if (refused.isNotEmpty()) {
            item(key = "refused.label") { SummaryLabel(stringResource(R.string.setup_summary_not_allowed)) }
            refused.forEach { item ->
                item(key = "refused.${item.permission.kind.name}") {
                    // What stayed off because of it; a permission that turns nothing off says what is missing.
                    val off = item.permission.offWhenRefused.map { it.setting }.toSet()
                    val names = SetupFeatures.all.filter { feature -> feature.settings.any { it in off } }.map { stringResource(it.title) }
                    SummaryRow(
                        permissionName(item.permission.kind),
                        if (names.isEmpty()) permissionWithout(item.permission.kind) else stringResource(R.string.setup_summary_turned_off, names.joinToString(", ")),
                        "PRIVACY", actions, warning = true,
                    )
                }
            }
        }
    }
}

@Composable
private fun SummaryLabel(text: String) {
    Text(text.uppercase(), style = BridgeyType.section, color = BridgeyTheme.colors.onSurfaceVariant, modifier = Modifier.padding(start = 8.dp, top = 14.dp).semantics { heading() })
}

/** A feature that is on: its switch, and Change in Settings under it. */
@Composable
private fun FeatureOnRow(item: SummaryItem.FeatureOn, actions: SetupActions) {
    val colors = BridgeyTheme.colors
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp)
                .toggleable(value = item.on, role = Role.Switch) { actions.event(SetupEvent.SummarySwitch(item.feature.id, it)) }
                .padding(start = 18.dp, end = 16.dp, top = 12.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(item.feature.title), style = BridgeyType.rowTitle, color = colors.onSurface)
                Text(stringResource(item.detail ?: item.feature.detail), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
            BridgeySwitch(checked = item.on, onCheckedChange = null)
        }
        TextButton(onClick = { actions.openPage(item.feature.page) }, modifier = Modifier.padding(start = 6.dp, bottom = 4.dp)) {
            Text(stringResource(R.string.setup_summary_change), style = BridgeyType.label, color = colors.primary)
        }
    }
}

/** Settings sync on the summary: "Settings stay the same on your devices", its switch, and Change in Settings. */
@Composable
private fun SyncSummaryRow(item: SummaryItem.Sync, actions: SetupActions, modifier: Modifier = Modifier) {
    val colors = BridgeyTheme.colors
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp)
                .toggleable(value = item.on, role = Role.Switch) { actions.event(SetupEvent.SummarySync(it)) }
                .padding(start = 18.dp, end = 16.dp, top = 12.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(R.string.setup_summary_sync), style = BridgeyType.rowTitle, color = colors.onSurface)
                Text(stringResource(R.string.setup_summary_sync_detail), style = BridgeyType.itemBody, color = colors.onSurfaceVariant)
            }
            BridgeySwitch(checked = item.on, onCheckedChange = null)
        }
        TextButton(onClick = { actions.openPage("GENERAL") }, modifier = Modifier.padding(start = 6.dp, bottom = 4.dp)) {
            Text(stringResource(R.string.setup_summary_change), style = BridgeyType.label, color = colors.primary)
        }
    }
}

/** A choice or a refused permission: the text, and Change in Settings. */
@Composable
private fun SummaryRow(title: String, detail: String, page: String?, actions: SetupActions, warning: Boolean = false) {
    val colors = BridgeyTheme.colors
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(colors.surface1)) {
        Column(Modifier.fillMaxWidth().padding(start = 18.dp, end = 16.dp, top = 12.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = BridgeyType.rowTitle, color = colors.onSurface)
            Text(detail, style = BridgeyType.itemBody, color = if (warning) colors.warn else colors.onSurfaceVariant)
        }
        if (page != null) {
            TextButton(onClick = { actions.openPage(page) }, modifier = Modifier.padding(start = 6.dp, bottom = 4.dp)) {
                Text(stringResource(R.string.setup_summary_change), style = BridgeyType.label, color = colors.primary)
            }
        }
    }
}

/** "Leave setup? Your choices so far are kept." */
@Composable
internal fun LeaveSetupDialog(onLeave: () -> Unit, onStay: () -> Unit) {
    val colors = BridgeyTheme.colors
    AlertDialog(
        onDismissRequest = onStay,
        containerColor = colors.surface2,
        title = { Text(stringResource(R.string.setup_leave_title), style = BridgeyType.cardTitle, color = colors.onSurface) },
        text = { Text(stringResource(R.string.setup_leave_body), style = BridgeyType.bodyText, color = colors.onSurfaceVariant) },
        confirmButton = { TextButton(onClick = onStay) { Text(stringResource(R.string.setup_leave_stay), style = BridgeyType.label, color = colors.primary) } },
        dismissButton = { TextButton(onClick = onLeave) { Text(stringResource(R.string.setup_leave_leave), style = BridgeyType.label, color = colors.onSurfaceVariant) } },
    )
}
