package dev.bridgey.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** The phone shows whichever player the Mac names, and offers only the controls the Mac lists. */
class MacMediaStateTest {
    private fun state(player: String = "Spotify", detail: String = "", controls: List<Any>? = null) =
        JSONObject().put("version", 1).put("player", player).put("title", "Song").put("artist", "Band")
            .put("playing", true).put("position", 12).put("duration", 200).put("volume", 40).put("detail", detail)
            .also { if (controls != null) it.put("controls", JSONArray(controls)) }

    @Test fun anyNamedPlayerIsReadyNotOnlyMusicOrSpotify() {
        listOf("Music", "Spotify", "Safari", "Podcasts", "Bridgey Media Test Player").forEach {
            val media = MacMediaState.parse(state(it))!!
            assertEquals(it, media.player)
            assertTrue(it, media.ready)
            assertTrue(it, media.allows("toggle"))
        }
    }

    @Test fun offEmptyOrExplainedPlayersAreNotReady() {
        assertFalse(MacMediaState().ready)
        assertFalse(MacMediaState.parse(state("Off", "Choose a player in Bridgey Settings on your Mac, under Media"))!!.ready)
        assertFalse(MacMediaState.parse(state("Off"))!!.ready)
        assertFalse(MacMediaState.parse(state(""))!!.ready)
        val waiting = MacMediaState.parse(state("Safari", "Play something in Safari on your Mac"))!!
        assertFalse(waiting.ready)
        assertFalse(waiting.allows("next"))
    }

    @Test fun olderMacsWithoutControlsAllowEverything() {
        val media = MacMediaState.parse(state("Music"))!!
        assertNull(media.controls)
        MacMediaState.CONTROLS.forEach { assertTrue(it, media.allows(it)) }
    }

    @Test fun listedControlsAreTheOnlyOnesAllowed() {
        val media = MacMediaState.parse(state("Safari", controls = listOf("toggle", "pause", "next", "previous", "seek", "eject", 7)))!!
        assertEquals(setOf("toggle", "pause", "next", "previous", "seek"), media.controls)
        assertTrue(media.allows("seek"))
        assertFalse(media.allows("volume"))
        assertFalse(media.allows("eject"))
        val none = MacMediaState.parse(state("Safari", controls = emptyList()))!!
        assertEquals(emptySet<String>(), none.controls)
        assertFalse(none.allows("toggle"))
    }

    @Test fun malformedStatesAreDropped() {
        assertNull(MacMediaState.parse(state().put("version", 2)))
        assertNull(MacMediaState.parse(state().put("position", -1)))
        assertNull(MacMediaState.parse(state().put("duration", 604801)))
        assertNull(MacMediaState.parse(state().put("volume", 101)))
        assertNull(MacMediaState.parse(state().put("playing", "yes")))
        assertNull(MacMediaState.parse(state().put("controls", "toggle")))
        assertNull(MacMediaState.parse(state().apply { remove("position") }))
    }

    @Test fun textIsBoundedAndDefaultCopyIsPlain() {
        val media = MacMediaState.parse(state("P".repeat(100)).put("title", "t".repeat(300)))!!
        assertEquals(64, media.player.length)
        assertEquals(256, media.title.length)
        val detail = MacMediaState().detail
        assertFalse(detail.contains('→'))
        assertFalse(detail.contains('—'))
    }
}
