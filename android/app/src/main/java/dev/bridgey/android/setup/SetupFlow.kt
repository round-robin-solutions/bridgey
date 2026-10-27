package dev.bridgey.android.setup

import org.json.JSONArray
import org.json.JSONObject

/**
 * First-run setup (v0.10): the pure state machine behind the Welcome screen, the quick path and the
 * advanced path. No Android types, so it runs in plain JUnit. The screens read [SetupState] and send
 * [SetupEvent]s; settings changed on an advanced page are the real settings (applied at once), and
 * are also recorded in [SetupChoices] for a later settings sync.
 */
enum class SetupPath { QUICK, ADVANCED }

/** The quick path's steps on Android, in order. Done follows the last one. */
enum class QuickStep { PAIR, NOTIFICATION_ACCESS, BATTERY }

/** The advanced path's pages: one per feature group, in the agreed settings order (the Mac matches). */
enum class SetupGroup { DEVICES, CLIPBOARD, NOTIFICATIONS, CALLS, FILES, MEDIA, REMOTE_CONTROL, PRIVACY, UPDATES, GENERAL }

/** How a quick step ended: done (granted or paired) or skipped (not granted; Settings still offers it). */
enum class StepOutcome { DONE, SKIPPED }

sealed interface SetupScreen {
    data object Welcome : SetupScreen
    data class Quick(val step: QuickStep) : SetupScreen
    data class Advanced(val group: SetupGroup) : SetupScreen
    data class Done(val path: SetupPath) : SetupScreen
}

/** One setting changed during setup: `group`, a stable `key` (for example `global.clipboard`) and its value. */
data class SetupChoice(val group: SetupGroup, val key: String, val value: String)

/**
 * Settings sync hook (deferred): what the person chose during setup, latest value per key. When
 * settings sync (settings_sync_draft1) lands, it can offer these choices to the other device.
 * Nothing sends them yet.
 */
data class SetupChoices(val choices: List<SetupChoice> = emptyList()) {
    fun with(choice: SetupChoice): SetupChoices =
        SetupChoices(choices.filterNot { it.key == choice.key } + choice)

    fun groups(): Set<SetupGroup> = choices.mapTo(LinkedHashSet()) { it.group }
}

sealed interface SetupEvent {
    data object ChooseQuick : SetupEvent
    data object ChooseAdvanced : SetupEvent
    data object Next : SetupEvent
    data object Back : SetupEvent
    data object Skip : SetupEvent
    data class Jump(val group: SetupGroup) : SetupEvent
    /** "Finish now": anything not visited keeps its current value (on first run, the default). */
    data object Finish : SetupEvent
    /** A quick step's permission was granted, or a Mac was paired. */
    data class StepDone(val step: QuickStep) : SetupEvent
    data class Choose(val choice: SetupChoice) : SetupEvent
}

data class SetupState(
    val screen: SetupScreen = SetupScreen.Welcome,
    val path: SetupPath? = null,
    val visited: Set<SetupGroup> = emptySet(),
    val outcomes: Map<QuickStep, StepOutcome> = emptyMap(),
    val choices: SetupChoices = SetupChoices(),
) {
    val finished: Boolean get() = screen is SetupScreen.Done

    /** "3 of 10" on an advanced page, "2 of 3" on a quick step; null elsewhere. */
    val position: Pair<Int, Int>?
        get() = when (val current = screen) {
            is SetupScreen.Quick -> (current.step.ordinal + 1) to QuickStep.entries.size
            is SetupScreen.Advanced -> (current.group.ordinal + 1) to SetupGroup.entries.size
            else -> null
        }

    val skipped: Set<QuickStep> get() = outcomes.filterValues { it == StepOutcome.SKIPPED }.keys

    fun encode(): String = JSONObject().apply {
        put("screen", when (val current = screen) {
            SetupScreen.Welcome -> "welcome"
            is SetupScreen.Quick -> "quick:${current.step.name}"
            is SetupScreen.Advanced -> "advanced:${current.group.name}"
            is SetupScreen.Done -> "done:${current.path.name}"
        })
        path?.let { put("path", it.name) }
        put("visited", JSONArray(visited.map { it.name }))
        put("outcomes", JSONObject().apply { outcomes.forEach { (step, outcome) -> put(step.name, outcome.name) } })
        put("choices", JSONArray(choices.choices.map { JSONArray(listOf(it.group.name, it.key, it.value)) }))
    }.toString()

    companion object {
        /** Settings > What's new > Review setup: the advanced path at Devices. */
        fun review(): SetupState = SetupFlow.reduce(SetupState(), SetupEvent.ChooseAdvanced)

        fun decode(text: String?): SetupState? = runCatching {
            val json = JSONObject(text ?: return null)
            val (kind, value) = json.getString("screen").split(':', limit = 2).let { it[0] to it.getOrNull(1) }
            val screen = when (kind) {
                "welcome" -> SetupScreen.Welcome
                "quick" -> SetupScreen.Quick(QuickStep.valueOf(value!!))
                "advanced" -> SetupScreen.Advanced(SetupGroup.valueOf(value!!))
                "done" -> SetupScreen.Done(SetupPath.valueOf(value!!))
                else -> return null
            }
            val visited = json.getJSONArray("visited").let { array -> (0 until array.length()).mapTo(LinkedHashSet()) { SetupGroup.valueOf(array.getString(it)) } }
            val outcomesJson = json.getJSONObject("outcomes")
            val outcomes = outcomesJson.keys().asSequence().associate { QuickStep.valueOf(it) to StepOutcome.valueOf(outcomesJson.getString(it)) }
            val choicesJson = json.getJSONArray("choices")
            val choices = (0 until choicesJson.length()).map {
                val entry = choicesJson.getJSONArray(it)
                SetupChoice(SetupGroup.valueOf(entry.getString(0)), entry.getString(1), entry.getString(2))
            }
            SetupState(screen, json.optString("path").takeIf { it.isNotEmpty() }?.let(SetupPath::valueOf), visited, outcomes, SetupChoices(choices))
        }.getOrNull()
    }
}

object SetupFlow {
    fun reduce(state: SetupState, event: SetupEvent): SetupState {
        val screen = state.screen
        return when (event) {
            SetupEvent.ChooseQuick -> state.copy(screen = SetupScreen.Quick(QuickStep.entries.first()), path = SetupPath.QUICK)
            SetupEvent.ChooseAdvanced -> {
                val first = SetupGroup.entries.first()
                state.copy(screen = SetupScreen.Advanced(first), path = SetupPath.ADVANCED, visited = state.visited + first)
            }
            SetupEvent.Next -> when (screen) {
                is SetupScreen.Quick -> {
                    val marked = state.markIfOpen(screen.step, StepOutcome.SKIPPED)
                    val next = QuickStep.entries.getOrNull(screen.step.ordinal + 1)
                    marked.copy(screen = next?.let(SetupScreen::Quick) ?: SetupScreen.Done(SetupPath.QUICK))
                }
                is SetupScreen.Advanced -> {
                    val next = SetupGroup.entries.getOrNull(screen.group.ordinal + 1)
                    if (next == null) {
                        state.copy(screen = SetupScreen.Done(SetupPath.ADVANCED))
                    } else {
                        state.copy(screen = SetupScreen.Advanced(next), visited = state.visited + next)
                    }
                }
                else -> state
            }
            SetupEvent.Skip -> when (screen) {
                is SetupScreen.Quick -> {
                    val next = QuickStep.entries.getOrNull(screen.step.ordinal + 1)
                    state.markIfOpen(screen.step, StepOutcome.SKIPPED)
                        .copy(screen = next?.let(SetupScreen::Quick) ?: SetupScreen.Done(SetupPath.QUICK))
                }
                // An advanced page has nothing to skip: Next leaves its values as they are.
                is SetupScreen.Advanced -> reduce(state, SetupEvent.Next)
                else -> state
            }
            SetupEvent.Back -> when (screen) {
                SetupScreen.Welcome -> state
                is SetupScreen.Quick -> {
                    val previous = QuickStep.entries.getOrNull(screen.step.ordinal - 1)
                    state.copy(screen = previous?.let(SetupScreen::Quick) ?: SetupScreen.Welcome)
                }
                is SetupScreen.Advanced -> {
                    val previous = SetupGroup.entries.getOrNull(screen.group.ordinal - 1)
                    state.copy(screen = previous?.let(SetupScreen::Advanced) ?: SetupScreen.Welcome)
                }
                is SetupScreen.Done -> when (screen.path) {
                    SetupPath.QUICK -> state.copy(screen = SetupScreen.Quick(QuickStep.entries.last()))
                    SetupPath.ADVANCED -> state.copy(screen = SetupScreen.Advanced(SetupGroup.entries.last()))
                }
            }
            is SetupEvent.Jump -> if (state.path == SetupPath.ADVANCED && screen !is SetupScreen.Welcome) {
                state.copy(screen = SetupScreen.Advanced(event.group), visited = state.visited + event.group)
            } else {
                state
            }
            SetupEvent.Finish -> when (screen) {
                is SetupScreen.Quick -> state.markIfOpen(screen.step, StepOutcome.SKIPPED).copy(screen = SetupScreen.Done(SetupPath.QUICK))
                is SetupScreen.Advanced -> state.copy(screen = SetupScreen.Done(SetupPath.ADVANCED))
                else -> state
            }
            is SetupEvent.StepDone -> state.copy(outcomes = state.outcomes + (event.step to StepOutcome.DONE))
            is SetupEvent.Choose -> state.copy(choices = state.choices.with(event.choice))
        }
    }

    /** Leaves a step that is already done as done. */
    private fun SetupState.markIfOpen(step: QuickStep, outcome: StepOutcome): SetupState =
        if (outcomes[step] == StepOutcome.DONE) this else copy(outcomes = outcomes + (step to outcome))
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
