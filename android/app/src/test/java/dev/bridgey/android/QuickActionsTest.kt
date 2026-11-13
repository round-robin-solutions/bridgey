package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.UUID
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

class QuickActionsTest {
    @Test fun encryptedRequestSequenceRejectsReplayIndependentlyOfOuterMessageId() {
        val sequence = QuickRequestSequence()
        assertTrue(sequence.accept("media", 4))
        assertFalse(sequence.accept("media", 4))
        assertFalse(sequence.accept("media", 3))
        assertTrue(sequence.accept("links", 1))
        assertTrue(sequence.accept("media", 5))
        assertFalse(sequence.accept("other", 6))
        assertFalse(sequence.accept("media", Long.MAX_VALUE))
    }
    @Test fun webLinksAllowOnlyExplicitBrowserNavigation() {
        listOf("https://example.com/path?q=one#two", "http://localhost:8080/", "https://[::1]/").forEach {
            assertEquals(it, validatedWebLink(it))
        }
        assertEquals("https://example.com", validatedWebLink("  https://example.com\n"))
        listOf("", "file:///etc/passwd", "javascript:alert(1)", "tel:+12345678", "bridgey://call", "https://",
            "https://user:pass@example.com", "https://example.com:0", "https://example.com:65536",
            "https://exa mple.com", "https://example.com/\nfoo", "https://example.com/\\evil",
            "https://example.com/\u0000", "https://example.com/" + "a".repeat(4096)).forEach {
            assertNull("Unsafe or oversized link: ${it.take(60)}", validatedWebLink(it))
        }
    }

    @Test fun newFeaturesAreNotAdvertisedByLegacyPeers() {
        assertFalse(featureEnabledByLegacyPeer(BridgeyFeature.LINKS))
        assertFalse(featureEnabledByLegacyPeer(BridgeyFeature.MEDIA))
    }

    @Test fun newComponentsCannotBeInvokedByArbitraryApplications() {
        val ns = "http://schemas.android.com/apk/res/android"
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val activities = doc.getElementsByTagName("activity")
        val confirmation = (0 until activities.length).map { activities.item(it) }.first {
            it.attributes.getNamedItemNS(ns, "name")?.nodeValue == ".ConfirmCallActivity"
        }
        assertEquals("false", confirmation.attributes.getNamedItemNS(ns, "exported").nodeValue)
        val services = doc.getElementsByTagName("service")
        val tile = (0 until services.length).map { services.item(it) }.first {
            it.attributes.getNamedItemNS(ns, "name")?.nodeValue == ".ClipboardTileService"
        }
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", tile.attributes.getNamedItemNS(ns, "permission").nodeValue)
    }
}

/** Web-link offers are checked against the Mac that sent them, and answered on its session. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class QuickActionsSenderTest {
    private val toSelected = mutableListOf<JSONObject>()
    private val replies = mutableListOf<JSONObject>()

    /** The selected Mac is "selected"; Web links are on only for the devices in [linksOn]. */
    private fun quickActions(selectedLinksOn: Boolean, vararg linksOn: String) = QuickActions(
        ApplicationProvider.getApplicationContext(), CoroutineScope(Dispatchers.Unconfined),
        available = { it == BridgeyFeature.LINKS && selectedLinksOn },
        send = { _, payload -> toSelected += payload; true },
        availableFor = { feature, deviceId -> feature == BridgeyFeature.LINKS && deviceId in linksOn },
    )

    private fun offer() = JSONObject().put("version", 1).put("requestId", UUID.randomUUID().toString())
        .put("feature", "links").put("action", "offer").put("value", "https://example.com/page")

    @Test fun aLinkFromAMacWithWebLinksOffIsDeclinedEvenWhenTheSelectedMacAllowsThem() {
        val actions = quickActions(selectedLinksOn = true)
        actions.receive("quick.request", offer(), "other-mac") { _, payload -> replies += payload; true }
        assertNull(actions.receivedLink.value)
        assertEquals(false, replies.single().get("accepted"))
        assertTrue("the answer goes to the sender, not the selected Mac", toSelected.isEmpty())
    }

    @Test fun aLinkFromAMacWithWebLinksOnIsAcceptedWhenTheSelectedMacHasThemOff() {
        val actions = quickActions(selectedLinksOn = false, "other-mac")
        actions.receive("quick.request", offer(), "other-mac") { _, payload -> replies += payload; true }
        assertEquals("https://example.com/page", actions.receivedLink.value)
        assertEquals(true, replies.single().get("accepted"))
        assertTrue(toSelected.isEmpty())
        // The selected Mac's own setting does not drop a link the sender may send.
        actions.policyChanged()
        assertEquals("https://example.com/page", actions.receivedLink.value)
    }
}

/** media.state from any player reaches the card, with its controls; a refusal is reported in plain words. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class QuickActionsMediaTest {
    private val sent = mutableListOf<JSONObject>()
    private fun quickActions(mediaOn: Boolean = true) = QuickActions(
        ApplicationProvider.getApplicationContext(), CoroutineScope(Dispatchers.Unconfined),
        available = { it == BridgeyFeature.MEDIA && mediaOn },
        send = { _, payload -> sent += payload; true },
    )
    private fun state(player: String) = JSONObject().put("version", 1).put("player", player).put("title", "Quiet Track 1")
        .put("artist", "Bridgey Test").put("playing", true).put("position", 3).put("duration", 600).put("volume", 0)
        .put("detail", "").put("controls", org.json.JSONArray(listOf("toggle", "pause", "next", "previous", "seek")))

    @Test fun anyPlayerTheMacReportsShowsWithItsControls() {
        val actions = quickActions()
        actions.receive("media.state", state("Bridgey Media Test Player"))
        val media = actions.media.value
        assertEquals("Bridgey Media Test Player", media.player)
        assertTrue(media.allows("next"))
        assertFalse(media.allows("volume"))
        actions.receive("media.state", state("Spotify").apply { remove("controls") })
        assertEquals("Spotify", actions.media.value.player)
        assertTrue(actions.media.value.allows("volume"))
    }

    @Test fun mediaStateIsIgnoredWhileMediaIsOff() {
        val actions = quickActions(mediaOn = false)
        actions.receive("media.state", state("Safari"))
        assertEquals("", actions.media.value.player)
    }

    @Test fun refusedCommandSaysSoWithoutDashes() {
        val actions = quickActions()
        actions.request(BridgeyFeature.MEDIA, "next")
        val id = sent.single().getString("requestId")
        actions.receive("quick.result", JSONObject().put("version", 1).put("requestId", id).put("feature", "media").put("accepted", false))
        val status = actions.status.value!!
        assertFalse(status.contains('—'))
        assertEquals("The device could not do that. Check its player and try again.", status)
    }
}
