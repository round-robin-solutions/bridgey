package dev.bridgey.android.ui.search

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The matching and ranking rules, shared with the Mac (SettingsSearchTests.swift). */
class SettingsSearchTest {
    private val docs = listOf(
        SearchDoc("Codes from messages", page = "Notifications", keywords = listOf("otp", "one-time code", "код")),
        SearchDoc("Connect away from home", "Reach your devices over the internet", page = "Devices", keywords = listOf("relay", "tailscale", "удалённо")),
        SearchDoc("Notification forwarding", "Show this phone's notifications on your Macs", page = "Notifications"),
        SearchDoc("Clipboard", "Copy here, paste there", page = "Clipboard", keywords = listOf("copy", "paste")),
        SearchDoc("Reset settings", page = "Reset"),
        SearchDoc("Release channel", page = "Updates", keywords = listOf("update", "обновление", "версия")),
        SearchDoc("Reduce motion", "Fade between screens", page = "General", keywords = listOf("animation")),
    )

    private fun top(query: String): String? = SettingsSearch.search(query, docs).firstOrNull()?.let { docs[it.index].title }

    @Test fun foldsCaseAccentsYoAndPunctuation() {
        assertEquals("елка cafe otp", SettingsSearch.fold("  Ёлка Café, OTP! "))
        assertEquals("удаленно", SettingsSearch.fold("удалённо"))
    }

    @Test fun emptyQueryFindsNothing() {
        assertTrue(SettingsSearch.search("   ", docs).isEmpty())
    }

    @Test fun synonymsLead() {
        assertEquals("Codes from messages", top("otp"))
        assertEquals("Connect away from home", top("relay"))
        assertEquals("Connect away from home", top("tailscale"))
        assertEquals("Release channel", top("update"))
    }

    @Test fun russianSynonymsAndYoFolding() {
        assertEquals("Release channel", top("обновлен"))
        assertEquals("Connect away from home", top("удаленно"))
        assertEquals("Codes from messages", top("КОД"))
    }

    @Test fun titlePrefixBeatsOtherFields() {
        // "Notification forwarding" starts with it; "Codes from messages" only lives on the Notifications page.
        val hits = SettingsSearch.search("notif", docs).map { docs[it.index].title }
        assertEquals("Notification forwarding", hits.first())
        assertTrue("Codes from messages" in hits)
    }

    @Test fun everyWordMustMatch() {
        assertEquals("Connect away from home", top("away home"))
        assertTrue(SettingsSearch.search("away clipboard", docs).isEmpty())
    }

    @Test fun oneTypoIsForgiven() {
        assertEquals("Clipboard", top("clipbaord")) // swapped letters
        assertEquals("Clipboard", top("clipbard")) // one missing
        assertEquals("Connect away from home", top("relya"))
        // A changed first letter is not a typo people make.
        assertTrue(SettingsSearch.search("xlipboard", docs).isEmpty())
        // Short words get no typo pass.
        assertTrue(SettingsSearch.search("otq", docs).isEmpty())
    }

    @Test fun typoRulesDirectly() {
        assertTrue(SettingsSearch.isTypo("relya", "relay"))
        assertTrue(SettingsSearch.isTypo("lcipboard", "clipboard"))
        assertTrue(!SettingsSearch.isTypo("xlipboard", "clipboard"))
        assertEquals(1, SettingsSearch.osaDistance("ab", "ba"))
        assertEquals(3, SettingsSearch.osaDistance("kitten", "sitting"))
    }

    @Test fun exactTitleWins() {
        assertEquals("Clipboard", top("clipboard"))
        val hits = SettingsSearch.search("clipboard", docs)
        assertTrue(hits.first().score >= 1200)
    }

    @Test fun highlightPrefersWordStarts() {
        // "set" marks "settings", not the "set" inside "Reset".
        assertEquals(listOf(6..8), SettingsSearch.highlight("Reset settings", "set"))
        assertEquals(listOf(0..3), SettingsSearch.highlight("Ёлка зелёная", "елка"))
        assertEquals(listOf(0..3, 5..7), SettingsSearch.highlight("Copy and copy", "copy and"))
    }

    @Test fun fuzzyMatchesHighlightNothing() {
        val hit = SettingsSearch.search("clipbaord", docs).first()
        assertTrue(hit.titleRanges.isEmpty())
    }

    @Test fun subtitleHighlightWhenTitleHasNone() {
        val hit = SettingsSearch.search("internet", docs).first()
        assertEquals("Connect away from home", docs[hit.index].title)
        assertTrue(hit.titleRanges.isEmpty())
        assertEquals(listOf(28..35), hit.subtitleRanges)
    }

    @Test fun closestAlwaysOffersThree() {
        assertTrue(SettingsSearch.search("dark", docs).isEmpty())
        val closest = SettingsSearch.closest("dark", docs)
        assertEquals(3, closest.size)
        assertEquals(3, closest.toSet().size)
        assertEquals("Codes from messages", docs[SettingsSearch.closest("otpx", docs).first()].title)
    }

    @Test fun tiesKeepRegistryOrder() {
        val same = listOf(SearchDoc("Alpha", keywords = listOf("shared")), SearchDoc("Beta", keywords = listOf("shared")))
        assertEquals(listOf(0, 1), SettingsSearch.search("shared", same).map { it.index })
    }
}
