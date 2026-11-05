package dev.bridgey.android.routing

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PinnedLinkTargetTest {
    @Test fun explicitShareStaysPinnedAndAcceptsOnlyTheChosenMacsAnswer() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val sent = mutableListOf<Pair<String, JSONObject>>()
            var connected = true
            val quick = QuickActions(ApplicationProvider.getApplicationContext<Application>(), scope,
                { true }, { _, _ -> fail("must not use mutable global selection"); false },
                availableFor = { _, id -> connected && id == "chosen" },
                sendTo = { id, _, payload -> sent += id to payload; connected }, linksOpenFor = { true })
            assertTrue(quick.sendLinkToDevice("https://example.com", "chosen", open = true))
            assertEquals("chosen", sent.single().first)
            assertEquals("open", sent.single().second.getString("action"))
            quick.targetChanged(null)
            val reply = JSONObject().put("version", 1).put("feature", "links")
                .put("requestId", sent.single().second.getString("requestId")).put("accepted", true)
            quick.receive("quick.result", reply, "other")
            assertNull(quick.linkResult.value)
            quick.receive("quick.result", reply, "chosen")
            assertEquals(LinkSendResult.Outcome.QUEUED, quick.linkResult.value?.outcome)
            connected = false
            assertFalse(quick.sendLinkToDevice("https://example.com", "chosen"))
            assertEquals(1, sent.size)
        } finally { scope.cancel() }
    }
}
