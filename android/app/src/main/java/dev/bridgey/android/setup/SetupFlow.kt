package dev.bridgey.android.setup

import org.json.JSONArray
import org.json.JSONObject

/**
 * First-run setup: the pure state machine behind Welcome, the quick path and the question path.
 * No Android types, so it runs in plain JUnit. The screens read [SetupState] and send
 * [SetupEvent]s; an answer's settings are applied by the screen as it is given (the real
 * settings), and the machine decides what comes next from the answers and [SetupFacts].
 */
enum class SetupPath { QUICK, ADVANCED }

/** The quick path's steps on Android, in order. Done follows the last one. */
enum class QuickStep { PAIR, NOTIFICATION_ACCESS, BATTERY }

/** How a quick step ended: done (granted or paired) or skipped (not granted; Settings still offers it). */
enum class StepOutcome { DONE, SKIPPED }

sealed interface SetupScreen {
    data object Welcome : SetupScreen
    data class Quick(val step: QuickStep) : SetupScreen
    /** The question path's start: type what you want, or go straight to the questions. */
    data object Intro : SetupScreen
    data class Question(val id: String) : SetupScreen
    /** The permission an answer needs, asked right after it. */
    data class Permission(val id: String, val kind: PermissionKind) : SetupScreen
    /** What was turned on, each with a switch and Change in Settings. */
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
    /** Quick path: finish now. */
    data object Finish : SetupEvent
    /** A quick step's permission was granted, or a Mac was paired. */
    data class StepDone(val step: QuickStep) : SetupEvent
    /** Intro: start the questions; [typed] holds the answers confirmed from typed text. */
    data class StartQuestions(val typed: Map<String, String> = emptyMap()) : SetupEvent
    data class Answer(val id: String, val key: String) : SetupEvent
    /** "Not now" on a card: keep what is set and move on. On a permission: not allowed. */
    data object NotNow : SetupEvent
    /** The permission asked for came back: allowed or not. */
    data class PermissionResult(val granted: Boolean) : SetupEvent
    data class SummarySwitch(val id: String, val on: Boolean) : SetupEvent
    /** "Leave setup?": shown, or answered Keep going. */
    data object AskLeave : SetupEvent
    data object KeepGoing : SetupEvent
}

data class SetupState(
    val screen: SetupScreen = SetupScreen.Welcome,
    val path: SetupPath? = null,
    /** Where this run started (Welcome, or the questions for Review setup). Back there leaves. */
    val entry: SetupScreen = SetupScreen.Welcome,
    val outcomes: Map<QuickStep, StepOutcome> = emptyMap(),
    /** Question id to answer key, in the order given. */
    val answers: Map<String, String> = emptyMap(),
    /** The questions shown so far, in order; Back walks it backwards. */
    val trail: List<String> = emptyList(),
    /** Answers taken from typed text (confirmed); those already applied skip their question. */
    val typed: Map<String, String> = emptyMap(),
    /** Questions whose permission was not allowed: their feature stayed off. */
    val denied: Map<String, PermissionKind> = emptyMap(),
    /** The question whose permission was just refused; the next card says so in one line. */
    val notice: String? = null,
    /** Summary switches turned off. */
    val summaryOff: Set<String> = emptySet(),
    val confirmLeave: Boolean = false,
) {
    val finished: Boolean get() = screen is SetupScreen.Done

    /** "2 of 3" on a quick step; null elsewhere (questions count the steps left instead). */
    val position: Pair<Int, Int>?
        get() = (screen as? SetupScreen.Quick)?.let { (it.step.ordinal + 1) to QuickStep.entries.size }

    val skipped: Set<QuickStep> get() = outcomes.filterValues { it == StepOutcome.SKIPPED }.keys

    /** Something was chosen, so leaving asks first ("Your choices so far are kept"). */
    val hasProgress: Boolean get() = answers.isNotEmpty() || outcomes.values.any { it == StepOutcome.DONE }

    /** The settings chosen, for the settings sync hook. */
    val choices: SetupChoices
        get() = SetupQuestions.all.fold(SetupChoices()) { acc, question ->
            val key = answers[question.id] ?: return@fold acc
            val applied = if (question.id in summaryOff) question.offKey?.let { SetupQuestions.changes(question, it) }.orEmpty()
            else SetupQuestions.changes(question, key) + (if (question.id in denied) SetupQuestions.answer(question, key)?.onDenied.orEmpty() else emptyList())
            applied.fold(acc) { inner, change -> inner.with(SetupChoice(question.section, change.setting.name, change.value)) }
        }

    fun encode(): String = JSONObject().apply {
        put("screen", screen.encode())
        put("entry", entry.encode())
        path?.let { put("path", it.name) }
        put("outcomes", JSONObject().apply { outcomes.forEach { (step, outcome) -> put(step.name, outcome.name) } })
        put("answers", JSONArray(answers.map { JSONArray(listOf(it.key, it.value)) }))
        put("trail", JSONArray(trail))
        put("typed", JSONArray(typed.map { JSONArray(listOf(it.key, it.value)) }))
        put("denied", JSONArray(denied.map { JSONArray(listOf(it.key, it.value.name)) }))
        notice?.let { put("notice", it) }
        put("summaryOff", JSONArray(summaryOff.toList()))
        put("confirmLeave", confirmLeave)
    }.toString()

    companion object {
        /** Settings > What's new > Review setup: straight to the questions. */
        fun review(): SetupState = SetupState(screen = SetupScreen.Intro, path = SetupPath.ADVANCED, entry = SetupScreen.Intro)

        private fun SetupScreen.encode(): String = when (this) {
            SetupScreen.Welcome -> "welcome"
            is SetupScreen.Quick -> "quick:${step.name}"
            SetupScreen.Intro -> "intro"
            is SetupScreen.Question -> "question:$id"
            is SetupScreen.Permission -> "permission:$id:${kind.name}"
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
                "permission" -> SetupScreen.Permission(parts[1], PermissionKind.valueOf(parts[2]))
                "summary" -> SetupScreen.Summary
                "done" -> SetupScreen.Done(SetupPath.valueOf(parts[1]))
                else -> null
            }
        }

        private fun pairs(array: JSONArray?): List<Pair<String, String>> =
            (0 until (array?.length() ?: 0)).map { array!!.getJSONArray(it).let { entry -> entry.getString(0) to entry.getString(1) } }

        /** Restores a saved state (rotation, process death); null when it cannot be read. */
        fun decode(text: String?): SetupState? = runCatching {
            val json = JSONObject(text ?: return null)
            val outcomesJson = json.getJSONObject("outcomes")
            val trailJson = json.getJSONArray("trail")
            val offJson = json.getJSONArray("summaryOff")
            SetupState(
                screen = screen(json.getString("screen")) ?: return null,
                path = json.optString("path").takeIf { it.isNotEmpty() }?.let(SetupPath::valueOf),
                entry = screen(json.getString("entry")) ?: SetupScreen.Welcome,
                outcomes = outcomesJson.keys().asSequence().associate { QuickStep.valueOf(it) to StepOutcome.valueOf(outcomesJson.getString(it)) },
                answers = LinkedHashMap(pairs(json.getJSONArray("answers")).toMap()),
                trail = (0 until trailJson.length()).map(trailJson::getString),
                typed = pairs(json.optJSONArray("typed")).toMap(),
                denied = pairs(json.optJSONArray("denied")).associate { it.first to PermissionKind.valueOf(it.second) },
                notice = json.optString("notice").takeIf { it.isNotEmpty() },
                summaryOff = (0 until offJson.length()).mapTo(LinkedHashSet(), offJson::getString),
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
            SetupEvent.Back -> back(state).copy(notice = null)
            is SetupEvent.StartQuestions -> if (screen == SetupScreen.Intro) {
                // Typed answers that need no permission are applied by the screen and skip their question;
                // the others wait on their card, chosen already, so the permission is asked there.
                val ready = readyTyped(event.typed, facts)
                val started = state.copy(typed = event.typed, answers = state.answers + ready, trail = emptyList(), notice = null)
                advance(started, after = null, facts)
            } else {
                state
            }
            is SetupEvent.Answer -> {
                val question = SetupQuestions.question(event.id)
                if (screen != SetupScreen.Question(event.id) || question == null) return state
                val answer = SetupQuestions.answer(question, event.key) ?: return state
                val answered = state.copy(
                    answers = (state.answers - event.id) + (event.id to event.key),
                    denied = state.denied - event.id,
                    summaryOff = state.summaryOff - event.id,
                    notice = null,
                )
                val permission = answer.permission
                if (permission != null && permission !in facts.granted) {
                    answered.copy(screen = SetupScreen.Permission(event.id, permission))
                } else {
                    advance(answered, after = event.id, facts)
                }
            }
            SetupEvent.NotNow -> when (screen) {
                is SetupScreen.Question -> advance(state.copy(notice = null), after = screen.id, facts)
                is SetupScreen.Permission -> reduce(state, SetupEvent.PermissionResult(granted = false), facts)
                else -> state
            }
            is SetupEvent.PermissionResult -> when (screen) {
                is SetupScreen.Permission -> if (event.granted) {
                    advance(state.copy(denied = state.denied - screen.id, notice = null), after = screen.id, facts)
                } else {
                    advance(state.copy(denied = state.denied + (screen.id to screen.kind), notice = screen.id), after = screen.id, facts)
                }
                else -> state
            }
            is SetupEvent.SummarySwitch -> state.copy(summaryOff = if (event.on) state.summaryOff - event.id else state.summaryOff + event.id)
            SetupEvent.AskLeave -> state.copy(confirmLeave = true)
            SetupEvent.KeepGoing -> state.copy(confirmLeave = false)
        }
    }

    /** One step back. Leaving setup from its first screen is [SetupBack]'s decision, not a step. */
    private fun back(state: SetupState): SetupState = when (val screen = state.screen) {
        SetupScreen.Welcome -> state
        is SetupScreen.Quick -> {
            val previous = QuickStep.entries.getOrNull(screen.step.ordinal - 1)
            state.copy(screen = previous?.let(SetupScreen::Quick) ?: SetupScreen.Welcome)
        }
        SetupScreen.Intro -> if (state.entry == SetupScreen.Intro) state else state.copy(screen = SetupScreen.Welcome)
        is SetupScreen.Question -> {
            val trail = state.trail.dropLast(1)
            if (trail.isEmpty()) state.copy(screen = SetupScreen.Intro, trail = emptyList())
            else state.copy(screen = SetupScreen.Question(trail.last()), trail = trail)
        }
        is SetupScreen.Permission -> state.copy(screen = SetupScreen.Question(screen.id))
        SetupScreen.Summary -> state.trail.lastOrNull()?.let { state.copy(screen = SetupScreen.Question(it)) } ?: state.copy(screen = SetupScreen.Intro)
        is SetupScreen.Done -> when (screen.path) {
            SetupPath.QUICK -> state.copy(screen = SetupScreen.Quick(QuickStep.entries.last()))
            SetupPath.ADVANCED -> state.copy(screen = SetupScreen.Summary)
        }
    }

    /** Typed (or bundle) answers that need no permission now: applied at once, their questions skipped. */
    fun readyTyped(typed: Map<String, String>, facts: SetupFacts): Map<String, String> =
        typed.filter { (id, key) -> SetupQuestions.question(id) != null && !needsPermission(id, key, facts) }

    private fun needsPermission(id: String, key: String, facts: SetupFacts): Boolean {
        val question = SetupQuestions.question(id) ?: return false
        val permission = SetupQuestions.answer(question, key)?.permission ?: return false
        return permission !in facts.granted
    }

    private fun advance(state: SetupState, after: String?, facts: SetupFacts): SetupState {
        val next = nextQuestion(state, facts, after)
        return if (next == null) state.copy(screen = SetupScreen.Summary)
        else state.copy(screen = SetupScreen.Question(next), trail = state.trail + next)
    }

    /** The settings after the answers so far, over [facts]. */
    fun effective(state: SetupState, facts: SetupFacts): Effective {
        val overlay = LinkedHashMap<SetupSetting, String>()
        SetupQuestions.all.forEach { question ->
            val key = state.answers[question.id] ?: return@forEach
            val changes = when {
                question.id in state.summaryOff -> question.offKey?.let { SetupQuestions.changes(question, it) }.orEmpty()
                question.id in state.denied -> SetupQuestions.changes(question, key) + SetupQuestions.answer(question, key)?.onDenied.orEmpty()
                else -> SetupQuestions.changes(question, key)
            }
            changes.forEach { overlay[it.setting] = it.value }
        }
        return Effective(facts, overlay)
    }

    /** The question shown after [after] (from the start when null), skipping implied ones. */
    fun nextQuestion(state: SetupState, facts: SetupFacts, after: String?): String? =
        upcoming(state, facts, after).firstOrNull()

    /** Every question still to come after [after]; the progress line counts these. */
    fun upcoming(state: SetupState, facts: SetupFacts, after: String?): List<String> {
        val effective = effective(state, facts)
        val start = after?.let { id -> SetupQuestions.all.indexOfFirst { it.id == id } + 1 } ?: 0
        return SetupQuestions.all.drop(start)
            .filter { question -> question.asks(effective) && !answeredByTyping(state, question.id) }
            .map { it.id }
    }

    /** Steps left after the current card (0 on the last one). */
    fun stepsLeft(state: SetupState, facts: SetupFacts): Int = when (val screen = state.screen) {
        is SetupScreen.Question -> upcoming(state, facts, screen.id).size
        is SetupScreen.Permission -> upcoming(state, facts, screen.id).size
        SetupScreen.Intro -> upcoming(state, facts, null).size
        else -> 0
    }

    private fun answeredByTyping(state: SetupState, id: String): Boolean =
        id in state.typed && state.answers[id] == state.typed[id] && id !in state.trail

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
    val question: SetupQuestion

    /** A feature an answer turned on; [on]: its switch now. */
    data class TurnedOn(override val question: SetupQuestion, val answer: SetupAnswer, val on: Boolean) : SummaryItem
    /** A choice without an off (updates, where folders go, apps kept on the phone). */
    data class Chosen(override val question: SetupQuestion, val answer: SetupAnswer) : SummaryItem
    /** Its permission was not allowed, so it stayed off. */
    data class NotAllowed(override val question: SetupQuestion, val kind: PermissionKind) : SummaryItem
}

object SetupSummary {
    fun items(state: SetupState): List<SummaryItem> = SetupQuestions.all.mapNotNull { question ->
        val key = state.answers[question.id] ?: return@mapNotNull null
        val answer = SetupQuestions.answer(question, key) ?: return@mapNotNull null
        val denied = state.denied[question.id]
        when {
            denied != null && answer.onDenied.isNotEmpty() -> SummaryItem.NotAllowed(question, denied)
            answer.turnsOn && question.offKey != null -> SummaryItem.TurnedOn(question, answer, question.id !in state.summaryOff)
            answer.turnsOn || question.offKey == null && answer.changes.isNotEmpty() && key != Answers.NO && key != Answers.NONE -> SummaryItem.Chosen(question, answer)
            else -> null
        }
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
