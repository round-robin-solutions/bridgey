package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SharedLinkResultTest {
    @Test fun concurrentSharesMatchOnlyTheirOwnPhoneSessionAndRequest() = runBlocking {
        val sent = mutableMapOf<String, JSONObject>()
        val actions = QuickActions(ApplicationProvider.getApplicationContext(), this, { true }, { _, _ -> true },
            availableFor = { _, _ -> true }, sendTo = { id, _, p -> sent[id] = p; true },
            linksOpenFor = { true }, sessionIdFor = { "session-$it" })
        val work = async(start = CoroutineStart.UNDISPATCHED) { actions.sendSharedLink("https://example.com/a", "work", "session-work") }
        val personal = async(start = CoroutineStart.UNDISPATCHED) { actions.sendSharedLink("https://example.com/b", "personal", "session-personal") }
        fun reply(mac: String, sender: String, opened: Boolean, reason: String = "") {
            actions.receive("quick.result", JSONObject().put("version", 1).put("feature", "links")
                .put("requestId", sent.getValue(mac).getString("requestId")).put("accepted", true)
                .put("opened", opened).put("reason", reason), sender)
        }
        reply("work", "personal", true)
        assertFalse(work.isCompleted)
        reply("personal", "personal", false)
        assertEquals(LinkSendResult.Outcome.QUEUED, personal.await().first)
        assertFalse(work.isCompleted)
        reply("work", "work", true)
        assertEquals(LinkSendResult.Outcome.OPENED, work.await().first)
        assertNull(actions.linkResult.value, "directed shares do not consume the old selected-Mac result stream")
    }
    @Test fun disabledAndReplacedSessionsCannotSend() = runBlocking {
        var sends = 0
        val actions = QuickActions(ApplicationProvider.getApplicationContext(), this, { true }, { _, _ -> true },
            availableFor = { _, _ -> true }, sendTo = { _, _, _ -> sends++; true }, sessionIdFor = { "replacement" })
        assertEquals(LinkSendResult.Outcome.NOT_SENT, actions.sendSharedLink("https://example.com", "work", "old").first)
        assertEquals(0, sends)
    }
}
