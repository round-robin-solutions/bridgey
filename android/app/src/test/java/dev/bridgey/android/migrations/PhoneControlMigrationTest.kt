package dev.bridgey.android.migrations

import dev.bridgey.android.control.GrantSubject
import dev.bridgey.android.control.PhoneControlGrantMode
import dev.bridgey.android.control.PhoneControlGrants
import dev.bridgey.android.migrations.MigrationFixtures.KEY_A
import dev.bridgey.android.migrations.MigrationFixtures.KEY_B
import dev.bridgey.android.migrations.MigrationFixtures.KEY_C
import dev.bridgey.android.migrations.MigrationFixtures.MAC_A
import dev.bridgey.android.migrations.MigrationFixtures.MAC_B
import dev.bridgey.android.migrations.MigrationFixtures.MAC_C
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Phone control grants (no_backup/phone-control-grants.json) from 1.0 Beta 6, before unattended access: every choice
 * stays as it was, the new switch reads as on, and a Mac without a choice follows it. Fixtures in
 * `protocol/test-vectors/migrations/android/phone-control/`.
 */
class PhoneControlMigrationTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun grants(fixture: String): Pair<File, PhoneControlGrants> {
        val file = File(folder.root, PhoneControlGrants.FILE_NAME)
        MigrationFixtures.file("phone-control/$fixture").copyTo(file, overwrite = true)
        return file to PhoneControlGrants(file)
    }

    @Test
    fun beta6ChoicesStayAndTheSwitchIsOn() {
        val (file, grants) = grants("phone-control-grants.1.0.0-beta.6.json")
        assertTrue(grants.unattended)
        assertEquals(PhoneControlGrantMode.ASK, grants.choice(GrantSubject(MAC_A, KEY_A, false)))
        assertEquals(PhoneControlGrantMode.ASK, grants.mode(GrantSubject(MAC_A, KEY_A, false)))
        assertEquals(PhoneControlGrantMode.ALWAYS, grants.mode(GrantSubject(MAC_B, KEY_B, false)))
        // Beta 6 stored no Off: a Mac it had at Off has no entry, so it is on Default now.
        assertNull(grants.choice(GrantSubject(MAC_C, KEY_C, false)))
        assertEquals(PhoneControlGrantMode.ALWAYS, grants.mode(GrantSubject(MAC_C, KEY_C, false)))
        // The next save keeps every choice and adds the switch.
        grants.setUnattended(true)
        val written = JSONObject(file.readText())
        assertTrue(written.getBoolean("unattended"))
        assertEquals(setOf(MAC_A, MAC_B), written.getJSONObject("devices").keys().asSequence().toSet())
        assertEquals(PhoneControlGrantMode.ASK, PhoneControlGrants(file).mode(GrantSubject(MAC_A, KEY_A, false)))
    }

    @Test
    fun badEntriesAreOffOneByOne() {
        val (_, grants) = grants("phone-control-grants.malformed.json")
        assertEquals(PhoneControlGrantMode.ASK, grants.choice(GrantSubject(MAC_A, KEY_A, false)))
        assertEquals("an unknown mode", PhoneControlGrantMode.OFF, grants.mode(GrantSubject(MAC_B, KEY_B, false)))
        assertEquals("a short key digest", PhoneControlGrantMode.OFF, grants.mode(GrantSubject(MAC_C, KEY_C, false)))
        assertTrue(grants.unattended)
    }
}
