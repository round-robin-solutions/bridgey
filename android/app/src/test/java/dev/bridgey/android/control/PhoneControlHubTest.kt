package dev.bridgey.android.control

import dev.bridgey.android.display.Capabilities
import dev.bridgey.android.display.ControlInput
import dev.bridgey.android.display.ControlKey
import dev.bridgey.android.display.ControlNavigation
import dev.bridgey.android.display.ControlPacket
import dev.bridgey.android.display.InputCapabilities
import dev.bridgey.android.display.TouchPhase
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executor
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeEnvironment(val service: FakeControlService = FakeControlService()) : PhoneControlEnvironment {
    override var sdkInt = 36
    override var built = true
    var key: String? = "key-A"
    var agent = false
    var share = true
    var macShows = true
    var locked = false
    var otherDisplay = false
    var connected = true
    var enabled = true
    val prompts = mutableListOf<Long>()
    var dismissed = 0
    val controllingLog = mutableListOf<String?>()
    val grantsChanged = mutableListOf<String>()
    var unattendedChanges = 0

    override fun identityKey(deviceId: String) = key
    override fun isAgent(deviceId: String) = agent
    override fun trusted(deviceId: String) = true
    override fun viewGrant(deviceId: String) = share
    override fun macAdvertises(deviceId: String) = macShows
    override fun unlocked() = !locked
    override fun otherDisplayActive() = otherDisplay
    override fun service(): ControlService? = if (connected) service else null
    override fun serviceEnabled() = enabled
    override fun showPrompt(deviceId: String, macName: String, promptId: Long) { prompts += promptId }
    override fun dismissPrompt() { dismissed++ }
    override fun controlling(macName: String?) { controllingLog += macName }
    override fun grantsChanged(deviceId: String) { grantsChanged += deviceId }
    override fun unattendedChanged() { unattendedChanges++ }
}

private class FakeControlService(val sink: FakeSink = FakeSink()) : ControlService, GestureSink by sink {
    override var canType = true
    var indicator: String? = null
    var stop: (() -> Unit)? = null

    override fun showIndicator(macName: String, onStop: () -> Unit) {
        indicator = macName
        stop = onStop
    }

    override fun hideIndicator() {
        indicator = null
        stop = null
    }

    var prompt: ((Boolean) -> Unit)? = null

    override fun showPrompt(macName: String, answer: (Boolean) -> Unit) { prompt = answer }
    override fun hidePrompt() { prompt = null }
}

private class FakeLink : ControlStreamLink {
    override val streamId = "0d3c2b1a-5948-4776-a5b4-c3d2e1f00a1b"
    override val connection = ByteArray(16) { 5 }
    val sent = mutableListOf<Pair<String, JSONObject>>()
    private var sequence = 1L

    override fun send(kind: String, payload: (Long) -> JSONObject): Boolean {
        sent += kind to payload(++sequence)
        return true
    }

    /** screen.control states in order, with their reason ("ended:local_stop"); available is listed by [available]. */
    fun states(): List<String> = sent.filter { it.first == "screen.control" && it.second.getString("state") != "available" }
        .map { it.second.getString("state") + (it.second.optString("reason").takeIf(String::isNotEmpty)?.let { r -> ":$r" } ?: "") }

    fun available(): List<Boolean> = sent.filter { it.first == "screen.control" && it.second.getString("state") == "available" }.map { it.second.getBoolean("allowed") }
}

/** Runs tasks when the test says so, to show what Stop does to input already queued. */
private class ManualExecutor : Executor {
    val tasks = ArrayDeque<Runnable>()
    var direct = true
    override fun execute(command: Runnable) { if (direct) command.run() else tasks.addLast(command) }
    fun runAll() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
}

class PhoneControlHubTest {
    private val timers = FakeTimers()
    private val environment = FakeEnvironment()
    private val sink get() = environment.service.sink
    private val executor = ManualExecutor()
    private val grants = PhoneControlGrants(File(Files.createTempDirectory("hub").toFile(), PhoneControlGrants.FILE_NAME))
    private val hub = PhoneControlHub(environment, grants, executor, timers, { timers.now })
    private val link = FakeLink()
    private val mac = Capabilities(screenViewer = true, h264Decode = true, inputController = InputCapabilities(pointer = true, touch = true, keys = true, text = true, navigation = true))
    private var macSequence = 2L
    private var seq = 0L
    private lateinit var offer: PhoneControlOffer

    private fun stream(): PhoneControlOffer {
        offer = hub.streamStarting(link, "mac-1", "MacBook Air", 0, 720, 1600, 1080, 2400)
        hub.streamStarted(link)
        return offer
    }

    private fun begin() = hub.macControl(link, MacControlMessage(link.streamId, macSequence++, PhoneControlAction.BEGIN, mac))
    private fun session(): Long = link.sent.last { it.first == "screen.control" && it.second.getString("state") == "active" }.second.getLong("session")
    private fun send(input: ControlInput, geometry: Long = 1) {
        hub.input("mac-1", ControlPacket(session(), offer.transport, link.connection, offer.stream, geometry, ++seq, input).encode(), link.connection)
    }

    private fun active(mode: PhoneControlGrantMode = PhoneControlGrantMode.ALWAYS) {
        assertTrue(hub.setGrant("mac-1", mode))
        stream()
        begin()
        if (mode == PhoneControlGrantMode.ASK) hub.answer(environment.prompts.last(), true)
        assertEquals("active", link.states().last())
        send(ControlInput.GeometryAck)
    }

    @Test fun theOfferIsTheContractObjectForTheStream() {
        hub.setGrant("mac-1", PhoneControlGrantMode.ASK)
        val offer = stream()
        assertTrue(offer.stream >= 1 && offer.transport >= 1)
        assertEquals(1L, offer.geometry.generation)
        assertEquals(1L, offer.geometry.source)
        assertEquals(720, offer.geometry.width)
        assertEquals(phoneHostCapabilities(36), offer.capabilities)
        assertTrue(offer.allowed)
        environment.enabled = false
        assertFalse(hub.streamStarting(FakeLink(), "mac-1", "MacBook Air", 0, 720, 1600, 1080, 2400).allowed)
    }

    @Test fun advertisedOnlyWithAGrantAndSharingAndNeverToAgents() {
        assertTrue(hub.setUnattended(false))
        assertFalse(hub.advertised("mac-1"))
        hub.setGrant("mac-1", PhoneControlGrantMode.ASK)
        assertTrue(hub.advertised("mac-1"))
        assertEquals(listOf("mac-1"), environment.grantsChanged)
        environment.share = false
        assertFalse(hub.advertised("mac-1"))
        environment.share = true
        environment.macShows = false
        assertTrue(hub.advertised("mac-1"))
        assertFalse("an older Mac keeps view only", hub.controlCapable("mac-1"))
        environment.agent = true
        assertFalse(hub.advertised("mac-1"))
        environment.agent = false
        environment.built = false
        assertFalse(hub.advertised("mac-1"))
    }

    @Test fun controlIsRefusedWithoutAGrantTheServiceOrAnUnlockedPhone() {
        hub.setUnattended(false)
        stream()
        begin()
        assertEquals("refused:disabled", link.states().last())
        hub.setGrant("mac-1", PhoneControlGrantMode.ALWAYS)
        environment.connected = false
        begin()
        assertEquals("refused:permission", link.states().last())
        environment.connected = true
        environment.locked = true
        begin()
        assertEquals("refused:locked", link.states().last())
        assertNull(environment.service.indicator)
    }

    @Test fun allowWithoutAskingStartsAtOnceWithTheIndicator() {
        active()
        val started = link.sent.last { it.second.optString("state") == "active" }.second
        assertTrue(started.getJSONObject("input").getBoolean("touch"))
        assertTrue(started.getJSONObject("input").getBoolean("text"))
        assertEquals("MacBook Air", environment.service.indicator)
        assertEquals(listOf<String?>("MacBook Air"), environment.controllingLog)
        assertTrue(hub.controllingNow)
        assertTrue(environment.prompts.isEmpty())
    }

    @Test fun askEachTimeWaitsForThePersonEveryTime() {
        hub.setGrant("mac-1", PhoneControlGrantMode.ASK)
        stream()
        begin()
        assertEquals("waiting", link.states().last())
        val first = environment.prompts.single()
        // Nothing is injected while it waits.
        hub.input("mac-1", ByteArray(4), link.connection)
        assertTrue(sink.dispatched.isEmpty())
        hub.answer(first + 7, true)
        assertEquals("a stale prompt changes nothing", "waiting", link.states().last())
        assertTrue("asked on the screen too", environment.service.prompt != null)
        hub.answer(first, false)
        assertEquals("refused:declined", link.states().last())
        assertNull("the on-screen question goes with the answer", environment.service.prompt)
        begin()
        val second = environment.prompts.last()
        assertTrue(second > first)
        hub.answer(second, true)
        assertEquals("active", link.states().last())
        // Ending control and asking again asks again.
        hub.macControl(link, MacControlMessage(link.streamId, macSequence++, PhoneControlAction.END))
        begin()
        assertEquals("waiting", link.states().last())
    }

    @Test fun theOnScreenQuestionAnswersTheCurrentPrompt() {
        hub.setGrant("mac-1", PhoneControlGrantMode.ASK)
        stream()
        begin()
        environment.service.prompt!!.invoke(true)
        assertEquals("active", link.states().last())
    }

    @Test fun theUnansweredPromptExpiresAfterAMinute() {
        hub.setGrant("mac-1", PhoneControlGrantMode.ASK)
        stream()
        begin()
        timers.advance(59_000)
        assertEquals("waiting", link.states().last())
        timers.advance(1_500)
        assertEquals("refused:declined", link.states().last())
        assertTrue(environment.dismissed > 0)
    }

    @Test fun aTapLandsOnTheMappedDisplayPixel() {
        active()
        send(ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5))
        val down = sink.dispatched.last().strokes.single()
        assertEquals(listOf(DisplayPoint(540.75, 1200.75)), down.points)
        sink.complete()
        send(ControlInput.Touch(0, TouchPhase.UP, 0.5, 0.5))
        assertFalse(sink.dispatched.last().strokes.single().willContinue)
    }

    @Test fun navigationAndTypingReachTheService() {
        active()
        send(ControlInput.Navigate(ControlNavigation.BACK))
        send(ControlInput.Navigate(ControlNavigation.HOME))
        send(ControlInput.Navigate(ControlNavigation.RECENTS))
        assertEquals(listOf(ControlNavigation.BACK, ControlNavigation.HOME, ControlNavigation.RECENTS), sink.navigated)
        send(ControlInput.Text("Hello, Привет"))
        send(ControlInput.Key(ControlKey.SHIFT, true))
        send(ControlInput.Key(ControlKey.LEFT, true))
        send(ControlInput.Key(ControlKey.LEFT, false))
        send(ControlInput.Key(ControlKey.SHIFT, false))
        assertEquals(listOf("Hello, Привет"), sink.typed)
        assertEquals(listOf(Triple(ControlKey.LEFT, true, true), Triple(ControlKey.LEFT, false, true)), sink.keys)
    }

    @Test fun rotationMovesToANewGenerationLiftsFingersAndFencesOldInput() {
        active()
        send(ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5))
        sink.complete()
        hub.geometryChanged(link, 1600, 720, 2400, 1080)
        val geometry = link.sent.last { it.first == "screen.geometry" }.second.getJSONObject("geometry")
        assertEquals(2L, geometry.getLong("generation"))
        assertEquals(1600, geometry.getInt("width"))
        // The held finger lifted where it was.
        assertFalse(sink.dispatched.last().strokes.single().willContinue)
        sink.complete()
        val parts = sink.dispatched.size
        send(ControlInput.Touch(0, TouchPhase.UP, 0.5, 0.5), geometry = 1)
        send(ControlInput.Touch(1, TouchPhase.DOWN, 0.25, 0.25), geometry = 2)
        assertEquals("old geometry and unacknowledged input send nothing", parts, sink.dispatched.size)
        assertEquals("active", link.states().last())
        send(ControlInput.GeometryAck, geometry = 2)
        send(ControlInput.Touch(1, TouchPhase.DOWN, 0.5, 0.5), geometry = 2)
        assertEquals(listOf(DisplayPoint(1200.75, 540.75)), sink.dispatched.last().strokes.single().points)
    }

    @Test fun stopOnThePhoneBeatsInputAlreadyQueued() {
        active()
        send(ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5))
        sink.complete()
        executor.direct = false
        send(ControlInput.Touch(0, TouchPhase.MOVE, 0.6, 0.5))
        send(ControlInput.Navigate(ControlNavigation.HOME))
        environment.service.stop!!.invoke()
        executor.runAll()
        executor.direct = true
        assertTrue(sink.navigated.isEmpty())
        assertEquals("ended:local_stop", link.states().last())
        assertNull(environment.service.indicator)
        assertFalse(hub.controllingNow)
        // The finger lifted where it was, not at the dropped move.
        val lift = sink.dispatched.last().strokes.single()
        assertEquals(listOf(DisplayPoint(540.75, 1200.75)), lift.points)
        assertFalse(lift.willContinue)
    }

    @Test fun turningTheGrantOffEndsControlAndRaisingItMeanwhileIsRefused() {
        active(PhoneControlGrantMode.ASK)
        assertFalse("a Mac cannot grant itself more while it controls the phone", hub.setGrant("mac-1", PhoneControlGrantMode.ALWAYS))
        assertEquals(PhoneControlGrantMode.ASK, hub.mode("mac-1"))
        send(ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5))
        sink.complete()
        assertTrue(hub.setGrant("mac-1", PhoneControlGrantMode.OFF))
        assertEquals("ended:disabled", link.states().last())
        assertFalse(sink.dispatched.last().strokes.single().willContinue)
        assertTrue(hub.setGrant("mac-1", PhoneControlGrantMode.ALWAYS))
    }

    @Test fun losingTheServiceEndsControl() {
        active()
        environment.connected = false
        hub.policyChanged()
        assertEquals("ended:permission", link.states().last())
        assertEquals(false, link.available().last())
    }

    @Test fun typingThatCouldGoOutsideTheSharedDisplayEndsControl() {
        active()
        environment.otherDisplay = true
        send(ControlInput.Text("secret"))
        assertEquals("ended:focus", link.states().last())
        assertTrue(sink.typed.isEmpty())
    }

    @Test fun modifierKeysEndControl() {
        active()
        send(ControlInput.Key(ControlKey.CONTROL, true))
        assertEquals("ended:invalid", link.states().last())
    }

    @Test fun androidTwelveOffersNoTypingButKeepsGestures() {
        environment.sdkInt = 31
        active()
        val started = link.sent.last { it.second.optString("state") == "active" }.second
        assertFalse(started.getJSONObject("input").getBoolean("text"))
        send(ControlInput.Text("ignored"))
        assertEquals("unsupported input is refused, control stays", "active", link.states().last())
        send(ControlInput.Navigate(ControlNavigation.BACK))
        assertEquals(listOf(ControlNavigation.BACK), sink.navigated)
    }

    @Test fun malformedInputEndsControl() {
        active()
        hub.input("mac-1", "{\"v\":1}".toByteArray(), link.connection)
        assertEquals("ended:invalid", link.states().last())
    }

    @Test fun inputFromAnotherSessionIsRefused() {
        active()
        hub.input("mac-1", ControlPacket(session(), offer.transport, ByteArray(16) { 6 }, offer.stream, 1, ++seq, ControlInput.Navigate(ControlNavigation.HOME)).encode(), ByteArray(16) { 6 })
        assertTrue(sink.navigated.isEmpty())
        assertEquals("active", link.states().last())
    }

    @Test fun theStreamEndingEndsControlAndNothingResumes() {
        active()
        send(ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5))
        sink.complete()
        val before = link.sent.size
        hub.streamEnded(link)
        assertNull(environment.service.indicator)
        assertEquals("the stream's own stop says it", before, link.sent.size)
        assertFalse(sink.dispatched.last().strokes.single().willContinue)
        // A new share starts with control off; the Mac asks again.
        val next = FakeLink()
        hub.streamStarting(next, "mac-1", "MacBook Air", 0, 720, 1600, 1080, 2400)
        hub.streamStarted(next)
        assertTrue(next.states().none { it == "active" })
        assertEquals(PhoneControlViewState(), hub.state.value)
    }

    @Test fun silenceEndsControlAfterSixSeconds() {
        active()
        timers.advance(5_000)
        assertEquals("active", link.states().last())
        timers.advance(1_500)
        assertEquals("ended:timeout", link.states().last())
    }

    // MARK: Unattended access

    @Test fun aMacOnDefaultFollowsUnattendedAccessAndStartsWithoutAsking() {
        assertTrue(hub.unattended)
        assertNull(hub.choice("mac-1"))
        assertEquals(PhoneControlGrantMode.ALWAYS, hub.mode("mac-1"))
        assertTrue(hub.advertised("mac-1"))
        assertTrue(hub.unattendedView("mac-1"))
        stream()
        begin()
        assertEquals("active", link.states().last())
        assertTrue(environment.prompts.isEmpty())
        assertEquals("the indicator still names the Mac, with Stop", "MacBook Air", environment.service.indicator)
    }

    @Test fun turningUnattendedAccessOffEndsControlByAMacOnDefault() {
        stream()
        begin()
        assertEquals("active", link.states().last())
        assertTrue("lowering always works", hub.setUnattended(false))
        assertEquals("ended:disabled", link.states().last())
        assertEquals(PhoneControlGrantMode.OFF, hub.mode("mac-1"))
        assertFalse(hub.advertised("mac-1"))
        assertEquals(1, environment.unattendedChanges)
    }

    @Test fun aMacsOwnChoiceStaysWhateverTheSwitchSays() {
        assertTrue(hub.setGrant("mac-1", PhoneControlGrantMode.ASK))
        hub.setUnattended(false)
        assertEquals(PhoneControlGrantMode.ASK, hub.mode("mac-1"))
        hub.setUnattended(true)
        assertEquals(PhoneControlGrantMode.ASK, hub.mode("mac-1"))
        assertTrue(hub.setGrant("mac-1", PhoneControlGrantMode.OFF))
        assertEquals("an explicit Off is not overridden", PhoneControlGrantMode.OFF, hub.mode("mac-1"))
        assertFalse(hub.unattendedView("mac-1"))
        assertTrue(hub.setGrant("mac-1", null))
        assertEquals(PhoneControlGrantMode.ALWAYS, hub.mode("mac-1"))
    }

    @Test fun agentsNeverGetUnattendedAccess() {
        environment.agent = true
        assertTrue(hub.unattended)
        assertEquals(PhoneControlGrantMode.OFF, hub.mode("mac-1"))
        assertFalse(hub.advertised("mac-1"))
        assertFalse(hub.unattendedView("mac-1"))
        assertFalse(hub.setGrant("mac-1", PhoneControlGrantMode.ALWAYS))
    }

    @Test fun nothingRaisesAccessWhileAMacControlsThePhone() {
        hub.setUnattended(false)
        active(PhoneControlGrantMode.ASK)
        assertFalse("its own grant", hub.setGrant("mac-1", PhoneControlGrantMode.ALWAYS))
        assertFalse("the switch", hub.setUnattended(true))
        assertFalse(hub.unattended)
        assertEquals("active", link.states().last())
        // Lowering works: Default with the switch off is Off for this Mac, so control ends.
        assertTrue(hub.setGrant("mac-1", null))
        assertEquals("ended:disabled", link.states().last())
        assertTrue("once nothing controls the phone, the switch can go on again", hub.setUnattended(true))
    }

    @Test fun defaultThatWouldRaiseIsRefusedWhileControlled() {
        active(PhoneControlGrantMode.ASK)
        assertTrue(hub.unattended)
        assertFalse("Default is Allow without asking with the switch on: a raise", hub.setGrant("mac-1", null))
        assertEquals(PhoneControlGrantMode.ASK, hub.choice("mac-1"))
        assertTrue("turning the switch off is never refused", hub.setUnattended(false))
        assertEquals("active", link.states().last())
    }

    @Test fun theMacHearsWhenTheServiceComesOn() {
        environment.connected = false
        environment.enabled = false
        hub.setGrant("mac-1", PhoneControlGrantMode.ASK)
        assertFalse(stream().allowed)
        environment.enabled = true
        environment.connected = true
        hub.policyChanged()
        assertEquals(listOf(true), link.available())
    }
}
