package dev.bridgey.android.setup

import dev.bridgey.android.UpdateChannel
import java.net.URLDecoder
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Android builder must produce exactly the links scripts/rr/obtainium.py writes into the README
 * and the website. The expected strings are that script's output (python3 obtainium.py links --deep).
 */
class ObtainiumTest {
    private val prefix = "obtainium://app/%7B%22id%22%3A%22in.roundrobin.bridgey%22%2C%22url%22%3A%22https%3A%2F%2Fgithub.com%2Fround-robin-solutions%2Fbridgey%22%2C%22author%22%3A%22Round%20Robin%22%2C%22name%22%3A%22Bridgey%20by%20Round%20Robin%22%2C%22additionalSettings%22%3A%22"

    @Test
    fun linksMatchTheReleaseScript() {
        assertEquals(prefix + "%7B%5C%22includePrereleases%5C%22%3Afalse%7D%22%7D", Obtainium.link(UpdateChannel.STABLE))
        assertEquals(
            prefix + "%7B%5C%22includePrereleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22-rr%5B.%5D%5B0-9%5D%2B(-beta%5B.%5D%5B0-9%5D%2B)%3F%24%5C%22%7D%22%7D",
            Obtainium.link(UpdateChannel.BETA),
        )
        assertEquals(
            prefix + "%7B%5C%22includePrereleases%5C%22%3Atrue%2C%5C%22filterReleaseTitlesByRegEx%5C%22%3A%5C%22-rr%5B.%5D%5B0-9%5D%2B(-(beta%7Cnightly)%5B.%5D%5B0-9%5D%2B)%3F%24%5C%22%7D%22%7D",
            Obtainium.link(UpdateChannel.NIGHTLY),
        )
    }

    @Test
    fun webLinkMatchesTheReleaseScript() {
        assertEquals(
            "https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522in.roundrobin.bridgey%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fround-robin-solutions%252Fbridgey%2522%252C%2522author%2522%253A%2522Round%2520Robin%2522%252C%2522name%2522%253A%2522Bridgey%2520by%2520Round%2520Robin%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522includePrereleases%255C%2522%253Atrue%252C%255C%2522filterReleaseTitlesByRegEx%255C%2522%253A%255C%2522-rr%255B.%255D%255B0-9%255D%252B%28-beta%255B.%255D%255B0-9%255D%252B%29%253F%2524%255C%2522%257D%2522%257D",
            Obtainium.webLink(UpdateChannel.BETA),
        )
    }

    @Test
    fun linkDecodesToTheAppJson() {
        UpdateChannel.entries.forEach { channel ->
            val json = JSONObject(URLDecoder.decode(Obtainium.link(channel).removePrefix("obtainium://app/"), "UTF-8"))
            assertEquals("in.roundrobin.bridgey", json.getString("id"))
            assertEquals("https://github.com/round-robin-solutions/bridgey", json.getString("url"))
            assertEquals("Round Robin", json.getString("author"))
            assertEquals("Bridgey by Round Robin", json.getString("name"))
            val settings = JSONObject(json.getString("additionalSettings"))
            assertEquals(channel != UpdateChannel.STABLE, settings.getBoolean("includePrereleases"))
            assertEquals(channel != UpdateChannel.STABLE, settings.has("filterReleaseTitlesByRegEx"))
        }
        assertFalse(Obtainium.link(UpdateChannel.BETA).contains('+'))
        assertTrue(Obtainium.link(UpdateChannel.BETA).matches(Regex("""^obtainium://app/[A-Za-z0-9\-_.!~*'()%]+$""")))
    }

    @Test
    fun filtersMatchEachChannelsReleaseTitles() {
        val titles = mapOf(
            "stable" to "Bridgey by Round Robin 0.6.0-rr.1",
            "beta" to "Bridgey by Round Robin 0.6.0-rr.1-beta.13",
            "nightly" to "Bridgey by Round Robin 0.6.0-rr.1-nightly.20261025",
            "models" to "Bridgey code model (on-device)",
            "channels" to "Update channels",
        )
        fun matching(filter: String) = titles.filterValues { Regex(filter).containsMatchIn(it) }.keys
        assertEquals(setOf("stable", "beta"), matching(Obtainium.BETA_FILTER))
        assertEquals(setOf("stable", "beta", "nightly"), matching(Obtainium.NIGHTLY_FILTER))
    }
}
