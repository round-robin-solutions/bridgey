package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SetupFlowTest {
    private fun run(vararg events: SetupEvent, from: SetupState = SetupState(), facts: SetupFacts = SetupFacts()): SetupState =
        events.fold(from) { state, event -> SetupFlow.reduce(state, event, facts) }

    /** A fresh install: every feature off until chosen. */
    private val allOff: Map<SetupSetting, String> = SetupFeatures.all.flatMap { it.settings }.associateWith { "false" }

    private fun fresh(paired: Boolean = true, granted: Set<PermissionKind> = emptySet(), codes: Boolean = false, apps: Boolean = false) = SetupFacts(
        paired = paired, current = allOff, granted = granted, codesLinkApplies = codes,
        duplicateApps = if (apps) listOf("com.whatsapp" to "WhatsApp") else emptyList(),
    )

    /** Like the app: answers and switches are applied as they are given, so the facts follow them. */
    private class Walk(var facts: SetupFacts, var state: SetupState = SetupState()) {
        val seen = mutableListOf<SetupScreen>()

        fun send(event: SetupEvent): Walk {
            val before = state
            val changes = when (event) {
                is SetupEvent.StartQuestions -> SetupFlow.startChanges(event.chosen)
                is SetupEvent.Answer -> SetupQuestions.question(event.id)?.let { SetupQuestions.changes(it, event.key) }.orEmpty()
                is SetupEvent.Switch -> SetupFeatures.feature(event.feature)!!.let { if (event.on) it.on else it.off }
                SetupEvent.Continue -> if (before.screen == SetupScreen.Permissions) {
                    SetupFlow.neededPermissions(before, facts).filter { it.kind !in facts.granted }.flatMap { it.offWhenRefused }
                } else {
                    emptyList()
                }
                else -> emptyList()
            }
            state = SetupFlow.reduce(before, event, facts)
            facts = facts.copy(current = facts.current + changes.associate { it.setting to it.value })
            if (state.screen != before.screen) seen += state.screen
            return this
        }

        val screen: SetupScreen get() = state.screen

        /** Not now / Continue to the summary; the screens on the way. */
        fun toTheEnd(): Walk {
            while (state.screen != SetupScreen.Summary) {
                send(if (state.screen is SetupScreen.Question) SetupEvent.NotNow else SetupEvent.Continue)
            }
            return this
        }

        /** The whole path, the start and the summary counted. */
        val steps: List<SetupScreen> get() = seen
    }

    private fun start(facts: SetupFacts, chosen: Map<String, String>): Walk =
        Walk(facts).send(SetupEvent.ChooseAdvanced).send(SetupEvent.StartQuestions(chosen))

    private fun q(id: String) = SetupScreen.Question(id)

    // Quick path

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
        assertTrue(state.finished)
    }

    @Test
    fun quickBackGoesOneStepAtATime() {
        assertEquals(SetupScreen.Welcome, run(SetupEvent.ChooseQuick, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Quick(QuickStep.PAIR), run(SetupEvent.ChooseQuick, SetupEvent.Next, SetupEvent.Back).screen)
        assertEquals(SetupScreen.Quick(QuickStep.BATTERY), run(SetupEvent.ChooseQuick, SetupEvent.Finish, SetupEvent.Back).screen)
    }

    @Test
    fun essentialsTurnOnClipboardOnSendAndNotificationsOnly() {
        val changes = SetupBundles.essentialChanges(Effective(fresh()))
        assertEquals(
            mapOf(SetupSetting.FEATURE_CLIPBOARD to "true", SetupSetting.AUTO_CLIPBOARD to "false", SetupSetting.FEATURE_NOTIFICATIONS to "true"),
            changes.associate { it.setting to it.value },
        )
        // Run again on a phone with an automatic clipboard: it is left as it is.
        val upgraded = Effective(SetupFacts(current = mapOf(SetupSetting.FEATURE_CLIPBOARD to "true", SetupSetting.AUTO_CLIPBOARD to "true", SetupSetting.FEATURE_NOTIFICATIONS to "false")))
        assertEquals(listOf(SettingChange.on(SetupSetting.FEATURE_NOTIFICATIONS)), SetupBundles.essentialChanges(upgraded))
    }

    // The short path: typical picks and their length

    @Test
    fun clipboardOnly() {
        val walk = start(fresh(), SetupBundles.answers(setOf("clipboard"), emptyMap()))
        assertEquals(q("clipboard"), walk.screen)
        // After this card: the switches and the permissions pages (the summary is not counted).
        assertEquals(2, SetupFlow.stepsLeft(walk.state, walk.facts))
        walk.send(SetupEvent.Answer("clipboard", Answers.TAP))
        assertEquals(SetupScreen.Switches, walk.screen)
        walk.toTheEnd()
        assertEquals(listOf(SetupScreen.Intro, q("clipboard"), SetupScreen.Switches, SetupScreen.Permissions, SetupScreen.Summary), walk.steps)
        assertEquals("false", walk.facts.value(SetupSetting.AUTO_CLIPBOARD))
    }

    @Test
    fun notificationsAndFilesWithAMacOnAndroid15() {
        val walk = start(fresh(codes = true, apps = true), SetupBundles.answers(setOf("notifications", "files"), emptyMap())).toTheEnd()
        assertEquals(
            listOf(SetupScreen.Intro, q("notification_apps"), q("codes"), q("files_browse"), SetupScreen.Switches, SetupScreen.Permissions, SetupScreen.Summary),
            walk.steps,
        )
    }

    @Test
    fun typedWithoutAMacStartsWithPairing() {
        val chosen = SetupTyped.match("I mainly want my WhatsApp notifications and to send photos to my Mac")
        val walk = start(fresh(paired = false, codes = true, apps = true), chosen).toTheEnd()
        assertEquals(
            listOf(SetupScreen.Intro, q("pair"), q("notification_apps"), q("files_browse"), SetupScreen.Switches, SetupScreen.Permissions, SetupScreen.Summary),
            walk.steps,
        )
    }

    @Test
    fun callsAndRemoteControl() {
        val walk = start(fresh(), SetupBundles.answers(setOf("calls", "remote"), emptyMap())).toTheEnd()
        assertEquals(listOf(SetupScreen.Intro, q("calls"), q("remote_volume_keys"), SetupScreen.Switches, SetupScreen.Permissions, SetupScreen.Summary), walk.steps)
        assertEquals("true", walk.facts.value(SetupSetting.FEATURE_MAC_ACTIONS))
    }

    @Test
    fun pickingNothingIsJustTheSwitches() {
        val walk = start(fresh(), emptyMap()).toTheEnd()
        // Nothing is on, so nothing needs a permission.
        assertEquals(listOf(SetupScreen.Intro, SetupScreen.Switches, SetupScreen.Summary), walk.steps)
        assertTrue(SetupSummary.items(walk.state, walk.facts).isEmpty())
    }

    @Test
    fun theStartNeverCountsEveryQuestion() {
        val intro = Walk(fresh(paired = false, codes = true, apps = true)).send(SetupEvent.ChooseAdvanced).state
        assertTrue(SetupFlow.stepsLeft(intro, fresh(paired = false)) <= 2)
        SetupBundles.all.forEach { bundle ->
            val walk = start(fresh(paired = false, codes = true, apps = true), bundle.answers).toTheEnd()
            assertTrue("${bundle.id}: ${walk.steps}", walk.steps.size in 4..8)
        }
        val everything = start(fresh(paired = false, codes = true, apps = true), SetupBundles.answers(SetupBundles.all.map { it.id }.toSet(), emptyMap())).toTheEnd()
        // Every bundle at once (six since Text messages): at most one follow-up each, then switches, permissions, summary.
        assertTrue(everything.steps.toString(), everything.steps.size <= 11)
    }

    @Test
    fun typedAnswersSkipTheirFollowUps() {
        val walk = start(fresh(), mapOf("clipboard" to Answers.AUTO, "codes" to Answers.YES, "updates" to Answers.EARLY, "media" to Answers.NO))
        assertEquals(setOf("clipboard", "notifications"), walk.state.picked)
        assertEquals("BETA", walk.facts.value(SetupSetting.UPDATE_CHANNEL))
        assertEquals("true", walk.facts.value(SetupSetting.AUTO_CLIPBOARD))
        walk.toTheEnd()
        assertFalse(q("clipboard") in walk.steps)
        assertFalse(q("codes") in walk.steps)
        assertEquals(false, walk.state.switches["media"])
    }

    @Test
    fun theSwitchesListEveryFeatureNotPickedAndTurnThemOn() {
        val walk = start(fresh(), SetupBundles.answers(setOf("files"), emptyMap()))
        walk.send(SetupEvent.Answer("files_browse", Answers.NO))
        assertEquals(SetupScreen.Switches, walk.screen)
        walk.send(SetupEvent.Switch("camera", true)).send(SetupEvent.Switch("links", true)).send(SetupEvent.Switch("links", false))
        assertEquals("true", walk.facts.value(SetupSetting.FEATURE_CAMERA))
        assertEquals("false", walk.facts.value(SetupSetting.FEATURE_LINKS))
        walk.send(SetupEvent.Continue)
        assertEquals(SetupScreen.Permissions, walk.screen)
        val needed = SetupFlow.neededPermissions(walk.state, walk.facts).map { it.kind }
        assertEquals(listOf(PermissionKind.POST_NOTIFICATIONS, PermissionKind.CAMERA, PermissionKind.BATTERY), needed)
    }

    @Test
    fun permissionsNotAllowedLeaveTheirFeaturesOffAndSetupGoesOn() {
        val walk = start(fresh(granted = setOf(PermissionKind.BATTERY)), SetupBundles.answers(setOf("notifications", "calls"), emptyMap()))
        walk.send(SetupEvent.Answer("calls", Answers.YES)).send(SetupEvent.Continue)
        assertEquals(SetupScreen.Permissions, walk.screen)
        walk.send(SetupEvent.Asked(setOf(PermissionKind.PHONE_CALLS)))
        walk.facts = walk.facts.copy(granted = walk.facts.granted + PermissionKind.NOTIFICATION_ACCESS)
        walk.send(SetupEvent.Continue)
        assertEquals(SetupScreen.Summary, walk.screen)
        assertEquals(setOf(PermissionKind.PHONE_CALLS, PermissionKind.POST_NOTIFICATIONS), walk.state.refused)
        assertEquals("false", walk.facts.value(SetupSetting.DIRECT_CALLS))
        assertEquals("true", walk.facts.value(SetupSetting.FEATURE_NOTIFICATIONS))
        val items = SetupSummary.items(walk.state, walk.facts)
        assertTrue(items.any { it is SummaryItem.NotAllowed && it.permission.kind == PermissionKind.PHONE_CALLS })
        assertTrue(items.any { it is SummaryItem.FeatureOn && it.feature.id == "calls" })
    }

    @Test
    fun aPermissionsPageWithEverythingAllowedIsSkipped() {
        val walk = start(fresh(granted = PermissionKind.entries.toSet()), SetupBundles.answers(setOf("notifications"), emptyMap())).toTheEnd()
        assertFalse(SetupScreen.Permissions in walk.steps)
    }

    @Test
    fun backWalksThePathAndPermissionsGoesBackToTheSwitches() {
        val walk = start(fresh(), SetupBundles.answers(setOf("clipboard", "calls"), emptyMap()))
        walk.send(SetupEvent.Answer("clipboard", Answers.AUTO)).send(SetupEvent.Answer("calls", Answers.SEE)).send(SetupEvent.Continue)
        assertEquals(SetupScreen.Permissions, walk.screen)
        walk.send(SetupEvent.Back)
        assertEquals(SetupScreen.Switches, walk.screen)
        walk.send(SetupEvent.Back)
        assertEquals(q("calls"), walk.screen)
        assertEquals(Answers.SEE, walk.state.answers["calls"])
        walk.send(SetupEvent.Back)
        assertEquals(q("clipboard"), walk.screen)
        walk.send(SetupEvent.Back)
        assertEquals(SetupScreen.Intro, walk.screen)
        walk.send(SetupEvent.Back)
        assertEquals(SetupScreen.Welcome, walk.screen)
        assertEquals(BackAction.ASK_LEAVE, SetupBack.decide(walk.state))
    }

    @Test
    fun theStateSurvivesProcessDeathOnThePermissionsPage() {
        val walk = start(fresh(), SetupBundles.answers(setOf("calls"), mapOf("updates" to Answers.EARLY)))
        walk.send(SetupEvent.Answer("calls", Answers.YES)).send(SetupEvent.Switch("camera", true)).send(SetupEvent.Continue)
            .send(SetupEvent.Asked(setOf(PermissionKind.PHONE_CALLS)))
        assertEquals(SetupScreen.Permissions, walk.screen)
        val saved = walk.state.copy(confirmLeave = true, summaryOff = setOf("camera"), outcomes = mapOf(QuickStep.PAIR to StepOutcome.SKIPPED))
        val restored = SetupState.decode(saved.encode())
        assertEquals(saved, restored)
        // Back after the restore still goes to the switches.
        assertEquals(SetupScreen.Switches, run(SetupEvent.Back, from = restored!!).screen)
        assertEquals(SetupState.review(), SetupState.decode(SetupState.review().encode()))
        assertEquals(SetupState(), SetupState.decode(SetupState().encode()))
        assertNull(SetupState.decode("not json"))
        assertNull(SetupState.decode(SetupState(screen = SetupScreen.Question("gone")).encode()))
    }

    @Test
    fun backDecisions() {
        assertEquals(BackAction.LEAVE, SetupBack.decide(SetupState()))
        assertFalse(SetupBack.intercepts(SetupState()))
        assertEquals(BackAction.STEP, SetupBack.decide(run(SetupEvent.ChooseQuick)))
        assertEquals(BackAction.STEP, SetupBack.decide(run(SetupEvent.ChooseAdvanced)))
        assertEquals(BackAction.ASK_LEAVE, SetupBack.decide(SetupState(picked = setOf("clipboard"))))
        assertEquals(BackAction.ASK_LEAVE, SetupBack.decide(SetupState(outcomes = mapOf(QuickStep.PAIR to StepOutcome.DONE))))
        assertEquals(BackAction.LEAVE, SetupBack.decide(SetupState.review()))
        val asking = run(SetupEvent.AskLeave, from = SetupState(picked = setOf("clipboard")))
        assertTrue(asking.confirmLeave)
        assertFalse(run(SetupEvent.KeepGoing, from = asking).confirmLeave)
    }

    @Test
    fun theSummaryShowsWhatIsOnWithSwitches() {
        val walk = start(fresh(granted = PermissionKind.entries.toSet()), SetupBundles.answers(setOf("clipboard"), mapOf("updates" to Answers.NEWEST)))
        walk.send(SetupEvent.Answer("clipboard", Answers.AUTO)).send(SetupEvent.Switch("battery", true)).toTheEnd()
        val items = SetupSummary.items(walk.state, walk.facts)
        val on = items.filterIsInstance<SummaryItem.FeatureOn>()
        assertEquals(listOf("clipboard", "battery"), on.map { it.feature.id })
        assertTrue(on.all { it.on })
        assertTrue(items.any { it is SummaryItem.Chosen })
        val off = run(SetupEvent.SummarySwitch("battery", on = false), from = walk.state)
        assertFalse(SetupSummary.items(off, walk.facts).filterIsInstance<SummaryItem.FeatureOn>().single { it.feature.id == "battery" }.on)
        assertEquals("false", off.choices.choices.single { it.key == SetupSetting.FEATURE_BATTERY.name }.value)
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
