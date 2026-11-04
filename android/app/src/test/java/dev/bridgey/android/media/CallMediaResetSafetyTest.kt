package dev.bridgey.android.media

import dev.bridgey.android.setup.LocalDataReset
import dev.bridgey.android.setup.ResetChoice
import dev.bridgey.android.setup.ResetEnvironment
import dev.bridgey.android.setup.ResetHook
import dev.bridgey.android.setup.ResetRoot
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
