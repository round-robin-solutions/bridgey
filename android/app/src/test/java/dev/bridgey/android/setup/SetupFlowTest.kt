package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupFlowTest {
    private fun run(vararg events: SetupEvent, from: SetupState = SetupState(), facts: SetupFacts = SetupFacts()): SetupState =
        events.fold(from) { state, event -> SetupFlow.reduce(state, event, facts) }

    /** Like the app: an answer's settings are applied as it is given, so the facts follow the answers. */
    private class Walk(var facts: SetupFacts, var state: SetupState = SetupState()) {
        fun send(event: SetupEvent): Walk {
            val before = state
            when (event) {
                is SetupEvent.Answer -> SetupQuestions.question(event.id)?.let { apply(SetupQuestions.changes(it, event.key)) }
                is SetupEvent.StartQuestions -> SetupFlow.readyTyped(event.typed, facts).forEach { (id, key) ->
                    apply(SetupQuestions.changes(SetupQuestions.question(id)!!, key))
                }
                is SetupEvent.PermissionResult, SetupEvent.NotNow -> (before.screen as? SetupScreen.Permission)?.let { screen ->
                    val question = SetupQuestions.question(screen.id)!!
                    if ((event as? SetupEvent.PermissionResult)?.granted == true) facts = facts.copy(granted = facts.granted + screen.kind)
                    else apply(SetupQuestions.answer(question, before.answers.getValue(screen.id))!!.onDenied)
                }
                else -> Unit
            }
            state = SetupFlow.reduce(before, event, facts)
            return this
        }

        private fun apply(changes: List<SettingChange>) {
            facts = facts.copy(current = facts.current + changes.associate { it.setting to it.value })
        }

        val question: String? get() = (state.screen as? SetupScreen.Question)?.id

        /** Not now on every card until the summary; the questions seen, in order. */
        fun notNowToTheEnd(): List<String> {
            val seen = mutableListOf<String>()
            while (state.screen != SetupScreen.Summary) {
                question?.let(seen::add)
                send(SetupEvent.NotNow)
            }
            return seen
        }
    }

    private val macControl = listOf("remote", "remote_volume_keys", "mac_actions", "media")

    // Quick path (unchanged apart from back)

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
        assertEquals(QuickStep.entries.map { SetupScreen.Quick(it) } + SetupScreen.Done(SetupPath.QUICK), seen)
        assertTrue(state.outcomes.values.all { it == StepOutcome.DONE })
        assertTrue(state.finished)
    }

    @Test
    fun skippingAPermissionStepRecordsItAsSkippedNotGranted() {
        val state = run(SetupEvent.ChooseQuick, SetupEvent.Skip, SetupEvent.Skip)
        assertEquals(SetupScreen.Quick(QuickStep.BATTERY), state.screen)
        assertEquals(StepOutcome.SKIPPED, state.outcomes[QuickStep.NOTIFICATION_ACCESS])
        assertEquals(setOf(QuickStep.PAIR, QuickStep.NOTIFICATION_ACCESS), state.skipped)
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
    fun quickBackGoesOneStepAtATime() {
        assertEquals(SetupScreen.Welcome, run(SetupEvent.ChooseQuick, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Quick(QuickStep.PAIR), run(SetupEvent.ChooseQuick, SetupEvent.Next, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Quick(QuickStep.BATTERY), run(SetupEvent.ChooseQuick, SetupEvent.Finish, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Welcome, run(SetupEvent.Back).screen)
    }

    // The question path

    @Test
    fun advancedStartsAtTheIntroAndBackReturnsToWelcome() {
        val intro = run(SetupEvent.ChooseAdvanced)
        assertEquals(SetupScreen.Intro, intro.screen)
        assertEquals(SetupPath.ADVANCED, intro.path)
        assertEquals(SetupScreen.Welcome, run(SetupEvent.Back, from = intro).screen)
    }

    @Test
    fun withoutAMacTheQuestionsSkipMacControlAndCodes() {
        val facts = SetupFacts(paired = false, codesLinkApplies = true, duplicateApps = listOf("com.whatsapp" to "WhatsApp"))
        val walk = Walk(facts).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        assertEquals("pair", walk.question)
        val seen = walk.notNowToTheEnd()
        assertTrue(seen.none { it in macControl })
        assertFalse("codes needs a paired Mac to link", "codes" in seen)
        assertTrue("notification_apps" in seen)
        // The agreed order: the catalogue order, with nothing out of place.
        assertEquals(SetupQuestions.all.map { it.id }.filter { it in seen }, seen)
        assertEquals(seen, walk.state.trail)
    }

    @Test
    fun withAMacPairingIsImpliedAndMacControlIsAsked() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        assertEquals("clipboard", walk.question)
        val seen = walk.notNowToTheEnd()
        assertFalse("pair" in seen)
        assertTrue(listOf("remote", "mac_actions", "media").all { it in seen })
        // Remote control is off by default, so its follow-up is not asked.
        assertFalse("remote_volume_keys" in seen)
    }

    @Test
    fun decliningNotificationsSkipsTheirFollowUps() {
        val facts = SetupFacts(paired = true, codesLinkApplies = true, duplicateApps = listOf("com.whatsapp" to "WhatsApp"), sdkInt = 35)
        val walk = Walk(facts).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        while (walk.question != "notifications") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("notifications", Answers.NO))
        // No apps question, no codes question; Bridgey's own notifications are a different thing.
        assertEquals("app_notifications", walk.question)
    }

    @Test
    fun clipboardNoSkipsItsFollowUpsAndTheCountAdapts() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        assertEquals("clipboard", walk.question)
        val before = SetupFlow.stepsLeft(walk.state, walk.facts)
        val upcoming = SetupFlow.upcoming(walk.state, walk.facts, "clipboard")
        assertTrue(upcoming.containsAll(listOf("clipboard_files", "clipboard_screenshot")))
        // Answering No removes the two follow-ups from the count shown on the next card.
        walk.send(SetupEvent.Answer("clipboard", Answers.NO))
        assertEquals("notifications", walk.question)
        assertEquals(before - 3, SetupFlow.stepsLeft(walk.state, walk.facts))
    }

    @Test
    fun anAnswerThatNeedsAPermissionAsksRightAfterIt() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        while (walk.question != "calls") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("calls", Answers.YES))
        assertEquals(SetupScreen.Permission("calls", PermissionKind.PHONE_CALLS), walk.state.screen)
        // Back from the permission returns to its question, with the answer kept.
        walk.send(SetupEvent.Back)
        assertEquals("calls", walk.question)
        assertEquals(Answers.YES, walk.state.answers["calls"])
        walk.send(SetupEvent.Answer("calls", Answers.YES)).send(SetupEvent.PermissionResult(granted = true))
        assertEquals("files", walk.question)
        assertNull(walk.state.notice)
        assertTrue("calls" !in walk.state.denied)
    }

    @Test
    fun aRefusedPermissionLeavesTheFeatureOffAndSaysSo() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        while (walk.question != "calls") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("calls", Answers.YES)).send(SetupEvent.PermissionResult(granted = false))
        assertEquals("files", walk.question)
        assertEquals("calls", walk.state.notice)
        assertEquals(PermissionKind.PHONE_CALLS, walk.state.denied["calls"])
        assertEquals("false", walk.facts.value(SetupSetting.DIRECT_CALLS))
        assertEquals("false", SetupFlow.effective(walk.state, SetupFacts())[SetupSetting.DIRECT_CALLS])
        // The notice shows once, on the next card only.
        walk.send(SetupEvent.NotNow)
        assertNull(walk.state.notice)
        val item = SetupSummary.items(walk.state).single { it.question.id == "calls" }
        assertEquals(SummaryItem.NotAllowed(SetupQuestions.question("calls")!!, PermissionKind.PHONE_CALLS), item)
    }

    @Test
    fun aGrantedPermissionIsNotAskedAgain() {
        val walk = Walk(SetupFacts(paired = true, granted = setOf(PermissionKind.PHONE_CALLS))).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        while (walk.question != "calls") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("calls", Answers.YES))
        assertEquals("files", walk.question)
    }

    @Test
    fun notNowOnAPermissionCountsAsNotAllowed() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        while (walk.question != "camera") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("camera", Answers.YES)).send(SetupEvent.NotNow)
        assertEquals("focus", walk.question)
        assertEquals("false", walk.facts.value(SetupSetting.FEATURE_CAMERA))
    }

    @Test
    fun backWalksTheQuestionsShownInOrder() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        walk.send(SetupEvent.Answer("clipboard", Answers.NO)) // skips clipboard_files and clipboard_screenshot
        walk.send(SetupEvent.NotNow) // notifications
        val third = walk.question
        assertEquals(listOf("clipboard", "notifications", third), walk.state.trail)
        walk.send(SetupEvent.Back)
        assertEquals("notifications", walk.question)
        walk.send(SetupEvent.Back)
        assertEquals("clipboard", walk.question)
        assertEquals(Answers.NO, walk.state.answers["clipboard"])
        walk.send(SetupEvent.Back)
        assertEquals(SetupScreen.Intro, walk.state.screen)
        walk.send(SetupEvent.Back)
        assertEquals(SetupScreen.Welcome, walk.state.screen)
        // Back on Welcome is not a step: SetupBack decides to ask before leaving.
        assertEquals(BackAction.ASK_LEAVE, SetupBack.decide(walk.state))
    }

    @Test
    fun backFromTheSummaryReturnsToTheLastQuestion() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        val seen = walk.notNowToTheEnd()
        walk.send(SetupEvent.Back)
        assertEquals(seen.last(), walk.question)
        walk.send(SetupEvent.NotNow)
        assertEquals(SetupScreen.Summary, walk.state.screen)
        assertEquals(SetupScreen.Done(SetupPath.ADVANCED), run(SetupEvent.Finish, from = walk.state).screen)
    }

    @Test
    fun typedAnswersSkipTheirQuestionsUnlessTheyNeedAPermission() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced)
        walk.send(SetupEvent.StartQuestions(mapOf("notifications" to Answers.YES, "files" to Answers.YES, "clipboard" to Answers.AUTO)))
        assertEquals(Answers.YES, walk.state.answers["files"])
        assertFalse("notifications needs its permission first", "notifications" in walk.state.answers)
        val seen = walk.notNowToTheEnd()
        assertFalse("clipboard" in seen)
        assertFalse("files" in seen)
        assertTrue("notifications" in seen)
        assertEquals("true", walk.facts.value(SetupSetting.AUTO_CLIPBOARD))
    }

    @Test
    fun theStateSurvivesProcessDeath() {
        val walk = Walk(SetupFacts(paired = true)).send(SetupEvent.ChooseAdvanced)
            .send(SetupEvent.StartQuestions(mapOf("files" to Answers.YES)))
        while (walk.question != "calls") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("calls", Answers.YES))
        val atPermission = walk.state.copy(summaryOff = setOf("files"), confirmLeave = true, outcomes = mapOf(QuickStep.PAIR to StepOutcome.SKIPPED))
        assertEquals(atPermission, SetupState.decode(atPermission.encode()))
        walk.send(SetupEvent.PermissionResult(false))
        assertEquals(walk.state, SetupState.decode(walk.state.encode()))
        val review = SetupState.review()
        assertEquals(review, SetupState.decode(review.encode()))
        assertEquals(SetupState(), SetupState.decode(SetupState().encode()))
        assertNull(SetupState.decode("not json"))
        assertNull(SetupState.decode(SetupState(screen = SetupScreen.Question("gone")).encode()))
        assertFalse(SetupState().finished)
    }

    @Test
    fun backDecisions() {
        assertEquals(BackAction.LEAVE, SetupBack.decide(SetupState()))
        assertFalse(SetupBack.intercepts(SetupState()))
        assertEquals(BackAction.STEP, SetupBack.decide(run(SetupEvent.ChooseQuick)))
        assertEquals(BackAction.STEP, SetupBack.decide(run(SetupEvent.ChooseAdvanced)))
        assertEquals(BackAction.ASK_LEAVE, SetupBack.decide(SetupState(answers = mapOf("clipboard" to Answers.NO))))
        assertEquals(BackAction.ASK_LEAVE, SetupBack.decide(SetupState(outcomes = mapOf(QuickStep.PAIR to StepOutcome.DONE))))
        // Review setup starts on the questions: that is its first screen.
        assertEquals(BackAction.LEAVE, SetupBack.decide(SetupState.review()))
        assertEquals(SetupScreen.Intro, run(SetupEvent.Back, from = SetupState.review()).screen)
        // The leave dialog: shown, and Keep going closes it.
        val asking = run(SetupEvent.AskLeave, from = SetupState(answers = mapOf("clipboard" to Answers.NO)))
        assertTrue(asking.confirmLeave)
        assertFalse(run(SetupEvent.KeepGoing, from = asking).confirmLeave)
    }

    @Test
    fun theSummaryListsWhatWasTurnedOn() {
        val walk = Walk(SetupFacts(paired = true, granted = PermissionKind.entries.toSet())).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions())
        walk.send(SetupEvent.Answer("clipboard", Answers.AUTO))
        walk.send(SetupEvent.Answer("clipboard_files", Answers.TEXT))
        while (walk.question != "updates") walk.send(SetupEvent.NotNow)
        walk.send(SetupEvent.Answer("updates", Answers.EARLY))
        val items = SetupSummary.items(walk.state)
        assertEquals(listOf("clipboard", "updates"), items.map { it.question.id })
        assertTrue((items[0] as SummaryItem.TurnedOn).on)
        assertTrue(items[1] is SummaryItem.Chosen)
        val off = run(SetupEvent.SummarySwitch("clipboard", on = false), from = walk.state)
        assertFalse((SetupSummary.items(off)[0] as SummaryItem.TurnedOn).on)
        assertEquals("false", SetupFlow.effective(off, SetupFacts())[SetupSetting.FEATURE_CLIPBOARD])
        // The settings sync hook hears the switch too.
        assertEquals("false", off.choices.choices.single { it.key == SetupSetting.FEATURE_CLIPBOARD.name }.value)
        assertEquals("BETA", off.choices.choices.single { it.key == SetupSetting.UPDATE_CHANNEL.name }.value)
    }

    @Test
    fun syncHookOnlyHearsRealChoices() {
        val heard = mutableListOf<SetupChoices>()
        SetupChoicesSync.sink = { heard += it }
        try {
            SetupChoicesSync.offer(SetupChoices())
            SetupChoicesSync.offer(SetupChoices(listOf(SetupChoice(SetupSection.UPDATES, "UPDATE_CHANNEL", "BETA"))))
        } finally {
            SetupChoicesSync.sink = null
        }
        assertEquals(1, heard.size)
    }
}
