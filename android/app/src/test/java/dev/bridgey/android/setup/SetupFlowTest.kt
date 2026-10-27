package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupFlowTest {
    private fun run(vararg events: SetupEvent, from: SetupState = SetupState()): SetupState =
        events.fold(from) { state, event -> SetupFlow.reduce(state, event) }

    @Test
    fun quickPathGoesThroughEveryStepThenDone() {
        var state = run(SetupEvent.ChooseQuick)
        assertEquals(SetupPath.QUICK, state.path)
        val seen = mutableListOf(state.screen)
        repeat(QuickStep.entries.size) {
            state = SetupFlow.reduce(state, SetupEvent.StepDone((state.screen as SetupScreen.Quick).step))
            state = SetupFlow.reduce(state, SetupEvent.Next)
            seen += state.screen
        }
        assertEquals(
            QuickStep.entries.map { SetupScreen.Quick(it) } + SetupScreen.Done(SetupPath.QUICK),
            seen,
        )
        assertTrue(state.outcomes.values.all { it == StepOutcome.DONE })
        assertTrue(state.finished)
    }

    @Test
    fun advancedPathVisitsEveryGroupInTheSettingsOrder() {
        var state = run(SetupEvent.ChooseAdvanced)
        val pages = mutableListOf<SetupScreen>(state.screen)
        while (!state.finished) {
            state = SetupFlow.reduce(state, SetupEvent.Next)
            pages += state.screen
        }
        assertEquals(SetupGroup.entries.map { SetupScreen.Advanced(it) } + SetupScreen.Done(SetupPath.ADVANCED), pages)
        assertEquals(SetupGroup.entries.toSet(), state.visited)
        assertEquals(3 to 10, run(SetupEvent.ChooseAdvanced, SetupEvent.Next, SetupEvent.Next).position)
    }

    @Test
    fun finishNowFromAnyAdvancedPageLeavesUnvisitedGroupsAtDefaults() {
        SetupGroup.entries.forEach { group ->
            val chosen = run(
                SetupEvent.ChooseAdvanced,
                SetupEvent.Jump(group),
                SetupEvent.Choose(SetupChoice(group, "key.${group.name}", "changed")),
                SetupEvent.Finish,
            )
            assertEquals(SetupScreen.Done(SetupPath.ADVANCED), chosen.screen)
            // Only Devices (the first page) and the jumped-to group were seen; nothing else changed.
            assertEquals(setOf(SetupGroup.DEVICES, group), chosen.visited)
            assertEquals(setOf(group), chosen.choices.groups())
            val untouched = SetupGroup.entries - chosen.visited
            assertTrue(untouched.none { it in chosen.choices.groups() })
        }
    }

    @Test
    fun skippingAPermissionStepRecordsItAsSkippedNotGranted() {
        val state = run(SetupEvent.ChooseQuick, SetupEvent.Skip, SetupEvent.Skip)
        assertEquals(SetupScreen.Quick(QuickStep.BATTERY), state.screen)
        assertEquals(StepOutcome.SKIPPED, state.outcomes[QuickStep.NOTIFICATION_ACCESS])
        assertEquals(setOf(QuickStep.PAIR, QuickStep.NOTIFICATION_ACCESS), state.skipped)

        // The Permissions page still offers what was skipped.
        val kind = PermissionCatalog.forStep(QuickStep.NOTIFICATION_ACCESS)!!
        val entry = PermissionCatalog.entries(PermissionFacts(sdkInt = 35, labBuild = false, granted = emptySet())).single { it.kind == kind }
        assertEquals(PermissionState.NOT_ALLOWED, entry.state)
        assertTrue(entry.offersRequest)
    }

    @Test
    fun aDoneStepStaysDoneWhenSkippedOrFinished() {
        val state = run(SetupEvent.ChooseQuick, SetupEvent.StepDone(QuickStep.PAIR), SetupEvent.Skip, SetupEvent.Finish)
        assertEquals(StepOutcome.DONE, state.outcomes[QuickStep.PAIR])
        assertEquals(StepOutcome.SKIPPED, state.outcomes[QuickStep.NOTIFICATION_ACCESS])
        assertEquals(SetupScreen.Done(SetupPath.QUICK), state.screen)
    }

    @Test
    fun backFromTheFirstStepReturnsToWelcome() {
        assertEquals(SetupScreen.Welcome, run(SetupEvent.ChooseQuick, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Welcome, run(SetupEvent.ChooseAdvanced, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Welcome, run(SetupEvent.Back).screen)
        assertEquals(SetupScreen.Quick(QuickStep.PAIR), run(SetupEvent.ChooseQuick, SetupEvent.Next, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Quick(QuickStep.BATTERY), run(SetupEvent.ChooseQuick, SetupEvent.Finish, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Advanced(SetupGroup.GENERAL), run(SetupEvent.ChooseAdvanced, SetupEvent.Finish, SetupEvent.Back).screen)
    }

    @Test
    fun jumpOnlyWorksOnTheAdvancedPath() {
        assertEquals(SetupScreen.Welcome, run(SetupEvent.Jump(SetupGroup.FILES)).screen)
        assertEquals(SetupScreen.Quick(QuickStep.PAIR), run(SetupEvent.ChooseQuick, SetupEvent.Jump(SetupGroup.FILES)).screen)
        assertEquals(SetupScreen.Advanced(SetupGroup.FILES), run(SetupEvent.ChooseAdvanced, SetupEvent.Jump(SetupGroup.FILES)).screen)
    }

    @Test
    fun reviewStartsTheAdvancedPathAtDevices() {
        val review = SetupState.review()
        assertEquals(SetupScreen.Advanced(SetupGroup.DEVICES), review.screen)
        assertEquals(SetupScreen.Welcome, SetupFlow.reduce(review, SetupEvent.Back).screen)
    }

    @Test
    fun choicesKeepTheLatestValuePerKey() {
        val state = run(
            SetupEvent.ChooseAdvanced,
            SetupEvent.Choose(SetupChoice(SetupGroup.DEVICES, "a", "1")),
            SetupEvent.Choose(SetupChoice(SetupGroup.DEVICES, "a", "2")),
        )
        assertEquals(listOf(SetupChoice(SetupGroup.DEVICES, "a", "2")), state.choices.choices)
    }

    @Test
    fun stateSurvivesEncoding() {
        val state = run(
            SetupEvent.ChooseAdvanced,
            SetupEvent.Next,
            SetupEvent.Choose(SetupChoice(SetupGroup.CLIPBOARD, "global.clipboard", "false")),
        ).copy(outcomes = mapOf(QuickStep.PAIR to StepOutcome.SKIPPED))
        assertEquals(state, SetupState.decode(state.encode()))
        assertEquals(SetupState(), SetupState.decode(SetupState().encode()))
        assertEquals(null, SetupState.decode("not json"))
        assertFalse(SetupState().finished)
    }

    @Test
    fun syncHookOnlyHearsRealChoices() {
        val heard = mutableListOf<SetupChoices>()
        SetupChoicesSync.sink = { heard += it }
        try {
            SetupChoicesSync.offer(SetupChoices())
            SetupChoicesSync.offer(SetupChoices(listOf(SetupChoice(SetupGroup.UPDATES, "updates.channel", "beta"))))
        } finally {
            SetupChoicesSync.sink = null
        }
        assertEquals(1, heard.size)
    }
}
