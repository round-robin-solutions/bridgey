package dev.bridgey.android.setup

import androidx.annotation.StringRes
import dev.bridgey.android.R
import org.json.JSONArray
import org.json.JSONObject

/**
 * First-run setup: the pure state machine behind Welcome, the quick path and the short question
 * path. No Android types, so it runs in plain JUnit. The screens read [SetupState] and send
 * [SetupEvent]s; answers and switches are applied to the real settings by the screen as they are
 * given, and the machine decides what comes next from them and [SetupFacts].
 *
 * The question path: Intro (what brought you here, or type it), Pair (when no Mac is paired), a
 * follow-up only for the features picked or typed, Switches (one line per other feature),
 * Permissions (one page for everything the chosen features need), Summary.
 */
enum class SetupPath { QUICK, ADVANCED }

/** The quick path's steps on Android, in order. Done follows the last one. */
enum class QuickStep { PAIR, NOTIFICATION_ACCESS, BATTERY }

/** How a quick step ended: done (granted or paired) or skipped (not granted; Settings still offers it). */
enum class StepOutcome { DONE, SKIPPED }

sealed interface SetupScreen {
    data object Welcome : SetupScreen
    data class Quick(val step: QuickStep) : SetupScreen
    /** The question path's start: bundles, type what you want, or straight on. */
    data object Intro : SetupScreen
    data class Question(val id: String) : SetupScreen
    /** One line per feature that was not picked: plain switches. */
    data object Switches : SetupScreen
    /** Every permission the chosen features need, on one page. */
    data object Permissions : SetupScreen
    data object Summary : SetupScreen
    data class Done(val path: SetupPath) : SetupScreen
}

/** One setting chosen during setup, for a later settings sync: its section, setting and value. */
data class SetupChoice(val section: SetupSection, val key: String, val value: String)

/**
 * Settings sync hook (deferred): what the person chose during setup, latest value per key. When
 * settings sync (settings_sync_draft1) lands, it can offer these choices to the other device.
 * Nothing sends them yet.
 */
data class SetupChoices(val choices: List<SetupChoice> = emptyList()) {
    fun with(choice: SetupChoice): SetupChoices =
        SetupChoices(choices.filterNot { it.key == choice.key } + choice)

    fun sections(): Set<SetupSection> = choices.mapTo(LinkedHashSet()) { it.section }
}

sealed interface SetupEvent {
    data object ChooseQuick : SetupEvent
    data object ChooseAdvanced : SetupEvent
    /** Quick path: the next step. */
    data object Next : SetupEvent
    data object Back : SetupEvent
    /** Quick path: skip a step. */
    data object Skip : SetupEvent
    /** Quick path: finish now. The summary: done. */
    data object Finish : SetupEvent
    /** A quick step's permission was granted, or a Mac was paired. */
    data class StepDone(val step: QuickStep) : SetupEvent
    /**
     * Intro: start, with what was picked and typed (confirmed), keyed by feature or follow-up id:
     * [Answers.PICK] picks a feature, [Answers.NO] leaves it off, other keys answer a follow-up.
     */
    data class StartQuestions(val chosen: Map<String, String> = emptyMap()) : SetupEvent
    data class Answer(val id: String, val key: String) : SetupEvent
    /** "Not now" on a follow-up: keep what is set and move on. */
    data object NotNow : SetupEvent
    /** The switches page: one feature on or off. */
    data class Switch(val feature: String, val on: Boolean) : SetupEvent
    /** The permissions page asked the system for these. */
    data class Asked(val kinds: Set<PermissionKind>) : SetupEvent
    /** Continue on the switches or permissions page (it works whatever the permissions say). */
    data object Continue : SetupEvent
    data class SummarySwitch(val feature: String, val on: Boolean) : SetupEvent
    /** "Leave setup?": shown, or answered Keep going. */
    data object AskLeave : SetupEvent
    data object KeepGoing : SetupEvent
}

data class SetupState(
    val screen: SetupScreen = SetupScreen.Welcome,
    val path: SetupPath? = null,
    /** Where this run started (Welcome, or the start of the questions for Review setup). Back there leaves. */
    val entry: SetupScreen = SetupScreen.Welcome,
    val outcomes: Map<QuickStep, StepOutcome> = emptyMap(),
    /** Features picked at the start (bundles or typed), in the order picked. */
    val picked: Set<String> = emptySet(),
    /** Follow-up and typed answers: id to answer key. */
    val answers: Map<String, String> = emptyMap(),
    /** Answers given at the start: their follow-ups are not asked. */
    val typed: Set<String> = emptySet(),
    /** The switches page, and features typed with a no. */
    val switches: Map<String, Boolean> = emptyMap(),
    /** The screens shown after the start, in order; Back walks it backwards. */
    val trail: List<SetupScreen> = emptyList(),
    /** Permissions asked for on the permissions page during this run. */
    val asked: Set<PermissionKind> = emptySet(),
    /** Permissions still not allowed when the permissions page was left: their features stay off. */
    val refused: Set<PermissionKind> = emptySet(),
    /** Features switched off on the summary. */
    val summaryOff: Set<String> = emptySet(),
    val confirmLeave: Boolean = false,
) {
    val finished: Boolean get() = screen is SetupScreen.Done

    /** "2 of 3" on a quick step; null elsewhere (questions count the steps left instead). */
    val position: Pair<Int, Int>?
        get() = (screen as? SetupScreen.Quick)?.let { (it.step.ordinal + 1) to QuickStep.entries.size }

    val skipped: Set<QuickStep> get() = outcomes.filterValues { it == StepOutcome.SKIPPED }.keys

    /** Something was chosen, so leaving asks first ("Your choices so far are kept"). */
    val hasProgress: Boolean
        get() = picked.isNotEmpty() || answers.isNotEmpty() || switches.isNotEmpty() || outcomes.values.any { it == StepOutcome.DONE }

    /** The settings chosen, for the settings sync hook. */
    val choices: SetupChoices
        get() = SetupFlow.overlay(this).entries.fold(SetupChoices()) { acc, (setting, value) ->
            acc.with(SetupChoice(SetupFlow.sectionOf(setting), setting.name, value))
        }

    fun encode(): String = JSONObject().apply {
        put("screen", screen.encode())
        put("entry", entry.encode())
        path?.let { put("path", it.name) }
        put("outcomes", JSONObject().apply { outcomes.forEach { (step, outcome) -> put(step.name, outcome.name) } })
        put("picked", JSONArray(picked.toList()))
        put("answers", JSONArray(answers.map { JSONArray(listOf(it.key, it.value)) }))
        put("typed", JSONArray(typed.toList()))
        put("switches", JSONArray(switches.map { JSONArray(listOf(it.key, it.value.toString())) }))
        put("trail", JSONArray(trail.map { it.encode() }))
        put("asked", JSONArray(asked.map { it.name }))
        put("refused", JSONArray(refused.map { it.name }))
        put("summaryOff", JSONArray(summaryOff.toList()))
        put("confirmLeave", confirmLeave)
    }.toString()

    companion object {
        /** Settings > What's new > Review setup: straight to the start of the questions. */
        fun review(): SetupState = SetupState(screen = SetupScreen.Intro, path = SetupPath.ADVANCED, entry = SetupScreen.Intro)

        private fun SetupScreen.encode(): String = when (this) {
            SetupScreen.Welcome -> "welcome"
            is SetupScreen.Quick -> "quick:${step.name}"
            SetupScreen.Intro -> "intro"
            is SetupScreen.Question -> "question:$id"
            SetupScreen.Switches -> "switches"
            SetupScreen.Permissions -> "permissions"
            SetupScreen.Summary -> "summary"
            is SetupScreen.Done -> "done:${path.name}"
        }

        private fun screen(text: String): SetupScreen? {
            val parts = text.split(':')
            return when (parts[0]) {
                "welcome" -> SetupScreen.Welcome
                "quick" -> SetupScreen.Quick(QuickStep.valueOf(parts[1]))
                "intro" -> SetupScreen.Intro
                "question" -> SetupScreen.Question(parts[1]).takeIf { SetupQuestions.question(parts[1]) != null }
                "switches" -> SetupScreen.Switches
                "permissions" -> SetupScreen.Permissions
                "summary" -> SetupScreen.Summary
                "done" -> SetupScreen.Done(SetupPath.valueOf(parts[1]))
                else -> null
            }
        }

        private fun strings(array: JSONArray?): List<String> = (0 until (array?.length() ?: 0)).map { array!!.getString(it) }

        private fun pairs(array: JSONArray?): List<Pair<String, String>> =
            (0 until (array?.length() ?: 0)).map { array!!.getJSONArray(it).let { entry -> entry.getString(0) to entry.getString(1) } }

        /** Restores a saved state (rotation, process death); null when it cannot be read. */
        fun decode(text: String?): SetupState? = runCatching {
            val json = JSONObject(text ?: return null)
            val outcomesJson = json.getJSONObject("outcomes")
            SetupState(
                screen = screen(json.getString("screen")) ?: return null,
                path = json.optString("path").takeIf { it.isNotEmpty() }?.let(SetupPath::valueOf),
                entry = screen(json.getString("entry")) ?: SetupScreen.Welcome,
                outcomes = outcomesJson.keys().asSequence().associate { QuickStep.valueOf(it) to StepOutcome.valueOf(outcomesJson.getString(it)) },
                picked = LinkedHashSet(strings(json.optJSONArray("picked"))),
                answers = LinkedHashMap(pairs(json.optJSONArray("answers")).toMap()),
                typed = strings(json.optJSONArray("typed")).toSet(),
                switches = pairs(json.optJSONArray("switches")).associate { it.first to it.second.toBoolean() },
                trail = strings(json.optJSONArray("trail")).map { screen(it) ?: return null },
                asked = strings(json.optJSONArray("asked")).mapTo(LinkedHashSet(), PermissionKind::valueOf),
                refused = strings(json.optJSONArray("refused")).mapTo(LinkedHashSet(), PermissionKind::valueOf),
                summaryOff = strings(json.optJSONArray("summaryOff")).toSet(),
                confirmLeave = json.optBoolean("confirmLeave"),
            )
        }.getOrNull()
    }
}

object SetupFlow {
    fun reduce(state: SetupState, event: SetupEvent, facts: SetupFacts = SetupFacts()): SetupState {
        val screen = state.screen
        return when (event) {
            SetupEvent.ChooseQuick -> state.copy(screen = SetupScreen.Quick(QuickStep.entries.first()), path = SetupPath.QUICK)
            SetupEvent.ChooseAdvanced -> state.copy(screen = SetupScreen.Intro, path = SetupPath.ADVANCED)
            SetupEvent.Next -> when (screen) {
                is SetupScreen.Quick -> {
                    val marked = state.markIfOpen(screen.step, StepOutcome.SKIPPED)
                    val next = QuickStep.entries.getOrNull(screen.step.ordinal + 1)
                    marked.copy(screen = next?.let(SetupScreen::Quick) ?: SetupScreen.Done(SetupPath.QUICK))
                }
                else -> state
            }
            SetupEvent.Skip -> when (screen) {
                is SetupScreen.Quick -> {
                    val next = QuickStep.entries.getOrNull(screen.step.ordinal + 1)
                    state.markIfOpen(screen.step, StepOutcome.SKIPPED)
                        .copy(screen = next?.let(SetupScreen::Quick) ?: SetupScreen.Done(SetupPath.QUICK))
                }
                else -> state
            }
            SetupEvent.Finish -> when (screen) {
                is SetupScreen.Quick -> state.markIfOpen(screen.step, StepOutcome.SKIPPED).copy(screen = SetupScreen.Done(SetupPath.QUICK))
                SetupScreen.Summary -> state.copy(screen = SetupScreen.Done(SetupPath.ADVANCED))
                else -> state
            }
            is SetupEvent.StepDone -> state.copy(outcomes = state.outcomes + (event.step to StepOutcome.DONE))
            SetupEvent.Back -> back(state)
            is SetupEvent.StartQuestions -> if (screen == SetupScreen.Intro) advance(started(state, event.chosen), facts) else state
            is SetupEvent.Answer -> {
                val question = SetupQuestions.question(event.id)
                if (screen != SetupScreen.Question(event.id) || question == null || SetupQuestions.answer(question, event.key) == null) return state
                advance(state.copy(answers = (state.answers - event.id) + (event.id to event.key)), facts)
            }
            SetupEvent.NotNow -> if (screen is SetupScreen.Question) advance(state, facts) else state
            is SetupEvent.Switch -> if (screen == SetupScreen.Switches && SetupFeatures.feature(event.feature) != null) {
                state.copy(switches = state.switches + (event.feature to event.on))
            } else {
                state
            }
            is SetupEvent.Asked -> state.copy(asked = state.asked + event.kinds)
            SetupEvent.Continue -> when (screen) {
                SetupScreen.Switches -> advance(state, facts)
                // Refused or skipped: those features stay off, and setup goes on.
                SetupScreen.Permissions -> advance(state.copy(refused = neededPermissions(state, facts).map { it.kind }.filterTo(LinkedHashSet()) { it !in facts.granted }), facts)
                else -> state
            }
            is SetupEvent.SummarySwitch -> state.copy(summaryOff = if (event.on) state.summaryOff - event.feature else state.summaryOff + event.feature)
            SetupEvent.AskLeave -> state.copy(confirmLeave = true)
            SetupEvent.KeepGoing -> state.copy(confirmLeave = false)
        }
    }

    /** The start's picks and typed answers, as state. */
    private fun started(state: SetupState, chosen: Map<String, String>): SetupState {
        val picked = LinkedHashSet<String>()
        val switches = LinkedHashMap<String, Boolean>()
        val answers = LinkedHashMap<String, String>()
        chosen.forEach { (id, key) ->
            val feature = SetupFeatures.feature(id)
            val question = SetupQuestions.question(id)
            when {
                key == Answers.NO && feature != null -> switches[id] = false
                key == Answers.PICK && feature != null -> picked += id
                question != null && SetupQuestions.answer(question, key) != null -> {
                    answers[id] = key
                    question.feature?.let { if (key != Answers.NO) picked += it }
                }
                SetupQuestions.typedOnly[id]?.containsKey(key) == true -> answers[id] = key
                feature != null -> picked += id
            }
        }
        return state.copy(picked = picked, switches = switches, answers = answers, typed = answers.keys.toSet(), trail = emptyList(), refused = emptySet(), asked = emptySet())
    }

    /** Typed answers the start applies at once: everything chosen, as setting changes (the screen applies them). */
    fun startChanges(chosen: Map<String, String>): List<SettingChange> {
        val state = started(SetupState(), chosen)
        return overlay(state).map { (setting, value) -> SettingChange(setting, value) }
    }

    /** One step back. Leaving setup from its first screen is [SetupBack]'s decision, not a step. */
    private fun back(state: SetupState): SetupState = when (val screen = state.screen) {
        SetupScreen.Welcome -> state
        is SetupScreen.Quick -> {
            val previous = QuickStep.entries.getOrNull(screen.step.ordinal - 1)
            state.copy(screen = previous?.let(SetupScreen::Quick) ?: SetupScreen.Welcome)
        }
        SetupScreen.Intro -> if (state.entry == SetupScreen.Intro) state else state.copy(screen = SetupScreen.Welcome)
        is SetupScreen.Question, SetupScreen.Switches, SetupScreen.Permissions, SetupScreen.Summary -> {
            val trail = state.trail.dropLast(1)
            state.copy(screen = trail.lastOrNull() ?: SetupScreen.Intro, trail = trail)
        }
        is SetupScreen.Done -> when (screen.path) {
            SetupPath.QUICK -> state.copy(screen = SetupScreen.Quick(QuickStep.entries.last()))
            SetupPath.ADVANCED -> state.copy(screen = SetupScreen.Summary)
        }
    }

    private fun advance(state: SetupState, facts: SetupFacts): SetupState {
        val next = nextScreen(state, facts, state.screen)
        return state.copy(screen = next, trail = state.trail + next)
    }

    /** What comes after [after] on the question path. */
    fun nextScreen(state: SetupState, facts: SetupFacts, after: SetupScreen): SetupScreen = when (after) {
        SetupScreen.Intro, is SetupScreen.Question -> followUps(state, facts, (after as? SetupScreen.Question)?.id).firstOrNull()?.let(SetupScreen::Question)
            ?: SetupScreen.Switches
        SetupScreen.Switches -> if (permissionsPage(state, facts)) SetupScreen.Permissions else SetupScreen.Summary
        else -> SetupScreen.Summary
    }

    /** The follow-ups still to come after [after] (from the start when null). */
    fun followUps(state: SetupState, facts: SetupFacts, after: String?): List<String> {
        val effective = effective(state, facts)
        val start = after?.let { id -> SetupQuestions.all.indexOfFirst { it.id == id } + 1 } ?: 0
        return SetupQuestions.all.drop(start)
            .filter { question -> (question.feature == null || question.feature in state.picked) && question.id !in state.typed && question.asks(effective) }
            .map { it.id }
    }

    /** The permissions the features now on need. */
    fun neededPermissions(state: SetupState, facts: SetupFacts): List<SetupPermission> {
        val effective = effective(state.copy(refused = emptySet()), facts)
        return SetupQuestions.permissions.filter { it.needed(effective) }
    }

    /** The permissions page shows when something needed is not allowed yet. */
    fun permissionsPage(state: SetupState, facts: SetupFacts): Boolean =
        neededPermissions(state, facts).any { it.kind !in facts.granted }

    /** Steps left after the current card, the summary not counted; from the path as it is now. */
    fun stepsLeft(state: SetupState, facts: SetupFacts): Int {
        val permissions = if (permissionsPage(state, facts)) 1 else 0
        return when (val screen = state.screen) {
            SetupScreen.Intro -> followUps(state, facts, null).size + 1 + permissions
            is SetupScreen.Question -> followUps(state, facts, screen.id).size + 1 + permissions
            SetupScreen.Switches -> permissions
            else -> 0
        }
    }

    /** Steps on the whole path from the start, the start and the summary counted (for the report and tests). */
    fun pathLength(state: SetupState, facts: SetupFacts): Int = 1 + followUps(state, facts, null).size + 1 + (if (permissionsPage(state, facts)) 1 else 0) + 1

    /** The settings this run changes: picks, answers, switches, refusals and summary switches, in that order. */
    fun overlay(state: SetupState): Map<SetupSetting, String> {
        val overlay = LinkedHashMap<SetupSetting, String>()
        fun put(changes: List<SettingChange>) = changes.forEach { overlay[it.setting] = it.value }
        state.picked.forEach { id -> SetupFeatures.feature(id)?.let { put(it.on) } }
        SetupQuestions.all.forEach { question -> state.answers[question.id]?.let { put(SetupQuestions.changes(question, it)) } }
        SetupQuestions.typedOnly.forEach { (id, answers) -> state.answers[id]?.let { key -> answers[key]?.let(::put) } }
        state.switches.forEach { (id, on) -> SetupFeatures.feature(id)?.let { put(if (on) it.on else it.off) } }
        state.refused.forEach { kind -> SetupQuestions.permission(kind)?.let { put(it.offWhenRefused) } }
        state.summaryOff.forEach { id -> SetupFeatures.feature(id)?.let { put(it.off) } }
        return overlay
    }

    /** The settings after this run's changes, over [facts]. */
    fun effective(state: SetupState, facts: SetupFacts): Effective = Effective(facts, overlay(state))

    fun sectionOf(setting: SetupSetting): SetupSection =
        SetupQuestions.all.firstOrNull { setting in it.covers }?.section ?: SetupSection.GENERAL

    /** Leaves a step that is already done as done. */
    private fun SetupState.markIfOpen(step: QuickStep, outcome: StepOutcome): SetupState =
        if (outcomes[step] == StepOutcome.DONE) this else copy(outcomes = outcomes + (step to outcome))
}

/** What system back (and the predictive gesture) does in setup. */
enum class BackAction {
    /** Go to the previous step. */
    STEP,
    /** Leaving mid-way: ask "Leave setup? Your choices so far are kept." once. */
    ASK_LEAVE,
    /** On the first screen with nothing chosen: leave setup. */
    LEAVE,
}

object SetupBack {
    fun decide(state: SetupState): BackAction = when {
        state.screen != state.entry -> BackAction.STEP
        state.hasProgress -> BackAction.ASK_LEAVE
        else -> BackAction.LEAVE
    }

    /** The page's own back handler wants the gesture (otherwise the page closes like any other). */
    fun intercepts(state: SetupState): Boolean = decide(state) != BackAction.LEAVE
}

/** One line of the summary. */
sealed interface SummaryItem {
    /** A feature that is on; [on]: its switch now; [detail]: the follow-up answer, if any. */
    data class FeatureOn(val feature: SetupFeature, val on: Boolean, @StringRes val detail: Int?) : SummaryItem
    /** A choice without an off: apps kept on the phone, Focus, the update channel. */
    data class Chosen(@StringRes val title: Int, @StringRes val value: Int?, val packages: List<String>, val page: String) : SummaryItem
    /** Not allowed when the permissions page was left: its features stayed off. */
    data class NotAllowed(val permission: SetupPermission) : SummaryItem
}

object SetupSummary {
    private val typedOnlyLabels: Map<String, Pair<Int, Map<String, Int>>> = mapOf(
        "focus" to (R.string.setup_q_focus_summary to mapOf(Answers.BOTH to R.string.setup_a_focus_both, Answers.NO to R.string.setup_a_no)),
        "updates" to (R.string.setup_q_updates_summary to mapOf(
            Answers.STEADY to R.string.setup_a_updates_steady, Answers.EARLY to R.string.setup_a_updates_early, Answers.NEWEST to R.string.setup_a_updates_newest,
        )),
        "updates_auto" to (R.string.setup_q_updates_auto_summary to mapOf(Answers.YES to R.string.setup_a_yes, Answers.NO to R.string.setup_a_no)),
    )

    fun items(state: SetupState, facts: SetupFacts = SetupFacts()): List<SummaryItem> {
        val effective = SetupFlow.effective(state.copy(summaryOff = emptySet()), facts)
        val on = SetupFeatures.all.filter { SetupFeatures.isOn(it, effective) }.map { feature ->
            val detail = SetupQuestions.all.firstOrNull { it.feature == feature.id && !it.multiPick && it.id in state.answers }
                ?.let { question -> SetupQuestions.answer(question, state.answers.getValue(question.id))?.label }
            SummaryItem.FeatureOn(feature, feature.id !in state.summaryOff, detail)
        }
        val chosen = buildList {
            state.answers["notification_apps"]?.takeIf { it.startsWith(Answers.PICKED) && it.length > Answers.PICKED.length }?.let {
                add(SummaryItem.Chosen(R.string.setup_q_notification_apps_summary, null, it.removePrefix(Answers.PICKED).split(','), "NOTIFICATIONS"))
            }
            typedOnlyLabels.forEach { (id, labels) ->
                val key = state.answers[id] ?: return@forEach
                add(SummaryItem.Chosen(labels.first, labels.second[key], emptyList(), if (id == "focus") "NOTIFICATIONS" else "UPDATES"))
            }
        }
        val refused = state.refused.mapNotNull { SetupQuestions.permission(it) }.map(SummaryItem::NotAllowed)
        return on + chosen + refused
    }
}

/**
 * Settings sync hook (deferred until settings_sync_draft1). Setup hands its [SetupChoices] here when
 * it finishes; a later sync sets [sink] to offer them to the other device. Nothing listens yet.
 */
object SetupChoicesSync {
    @Volatile
    var sink: ((SetupChoices) -> Unit)? = null

    fun offer(choices: SetupChoices) {
        if (choices.choices.isNotEmpty()) sink?.invoke(choices)
    }
}
