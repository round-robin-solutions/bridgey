package dev.bridgey.android.media

import dev.bridgey.android.setup.LocalDataReset
import dev.bridgey.android.setup.ResetChoice
import dev.bridgey.android.setup.ResetEnvironment
import dev.bridgey.android.setup.ResetHook
import dev.bridgey.android.setup.ResetRoot
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallMediaResetSafetyTest {
    @Test fun failedSoundRecoveryRunsNoHooksAndDeletesNoUserData() {
        val operations = mutableListOf<String>()
        val environment = object : ResetEnvironment {
            override fun prepare(choice: ResetChoice): Boolean { operations += "prepare"; return false }
            override fun directory(root: ResetRoot): File { operations += "directory"; return File("unused") }
            override fun deletePreferences(name: String) { operations += "preferences" }
            override fun deleteKeystoreAlias(alias: String) { operations += "keystore" }
            override fun run(hook: ResetHook) { operations += "hook" }
        }
        assertFalse(LocalDataReset(environment).perform(ResetChoice.EVERYTHING))
        assertEquals(listOf("prepare"), operations)
    }

    @Test fun settingsResetKeepsUnresolvedRecoveryAndDoesNotRequireItsRestoration() {
        val root = java.nio.file.Files.createTempDirectory("call-media-settings-reset").toFile()
        try {
            val noBackup = File(root, "no-backup").apply { mkdirs() }
            val journal = File(noBackup, "call-media-mute.json").apply { writeText("unresolved-owned-sound") }
            val operations = mutableListOf<String>()
            val environment = object : ResetEnvironment {
                override fun prepare(choice: ResetChoice): Boolean { operations += "prepare"; return false }
                override fun directory(kind: ResetRoot): File = when (kind) {
                    ResetRoot.NO_BACKUP -> noBackup
                    else -> File(root, kind.name).apply { mkdirs() }
                }
                override fun deletePreferences(name: String) { operations += "preferences" }
                override fun deleteKeystoreAlias(alias: String) { operations += "keystore" }
                override fun run(hook: ResetHook) { operations += "hook" }
            }
            assertTrue(LocalDataReset(environment).perform(ResetChoice.SETTINGS))
            assertFalse(operations.contains("prepare"))
            assertTrue(operations.contains("preferences"))
            assertEquals("unresolved-owned-sound", journal.readText())
        } finally { root.deleteRecursively() }
    }

}
