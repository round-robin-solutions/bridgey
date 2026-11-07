package dev.bridgey.android.tailscale

import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class TailscaleSetupTest {
    private class Access : TailscaleAppAccess {
        var present = false
        var availabilityFails = false
        var launcher: Intent? = null
        val attempts = mutableListOf<Intent>()
        var refuse: (Intent) -> Boolean = { false }
        override fun installed(): Boolean {
            if (availabilityFails) throw SecurityException("fixture")
            return present
        }
        override fun launcher(): Intent? = launcher
        override fun open(intent: Intent) {
            attempts += intent
            if (refuse(intent)) throw ActivityNotFoundException("fixture")
        }
    }

    @Test fun refreshAndReturnFromSetupNeverLaunchOrChangeVpn() {
        val access = Access()
        val setup = TailscaleSetup(access)
        setup.refresh()
        assertEquals(false, setup.state.value.installed)
        access.present = true
        setup.refresh()
        assertEquals(true, setup.state.value.installed)
        assertTrue(access.attempts.isEmpty())
    }

    @Test fun unavailablePackageQueryStaysUnknown() {
        val setup = TailscaleSetup(Access().apply { availabilityFails = true })
        setup.refresh()
        assertNull(setup.state.value.installed)
        assertFalse(setup.state.value.openFailed)
    }

    @Test fun installedAppLaunchIsBoundToOfficialPackage() {
        val access = Access().apply { present = true; launcher = Intent(Intent.ACTION_MAIN) }
        val setup = TailscaleSetup(access)
        setup.open()
        assertEquals(1, access.attempts.size)
        assertEquals(TailscaleSetup.PACKAGE, access.attempts.single().`package`)
        assertFalse(setup.state.value.openFailed)
    }

    @Test fun missingAppOpensOnlyOfficialStoreListing() {
        val access = Access()
        TailscaleSetup(access).open()
        val intent = access.attempts.single()
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals("com.android.vending", intent.`package`)
        assertEquals("market://details?id=com.tailscale.ipn", intent.dataString)
    }

    @Test fun missingStoreFallsBackToOfficialHttpsDownload() {
        val access = Access().apply { refuse = { it.data?.scheme == "market" } }
        val setup = TailscaleSetup(access)
        setup.open()
        assertEquals(2, access.attempts.size)
        assertEquals(TailscaleSetup.DOWNLOAD, access.attempts.last().dataString)
        assertFalse(setup.state.value.openFailed)
        assertTrue(setup.state.value.openedDownload)
    }

    @Test fun unavailableInstalledLauncherFallsBackToDownloadWithoutOpeningStore() {
        val access = Access().apply { present = true }
        TailscaleSetup(access).open()
        assertEquals(TailscaleSetup.DOWNLOAD, access.attempts.single().dataString)
    }

    @Test fun failedAppLaunchFallsBackToHttps() {
        val access = Access().apply {
            present = true
            launcher = Intent(Intent.ACTION_MAIN)
            refuse = { it.action == Intent.ACTION_MAIN }
        }
        val setup = TailscaleSetup(access)
        setup.open()
        assertEquals(TailscaleSetup.DOWNLOAD, access.attempts.last().dataString)
        assertFalse(setup.state.value.openFailed)
        assertTrue(setup.state.value.openedDownload)
        setup.refresh(clearResult = false)
        assertTrue(setup.state.value.openedDownload)
    }

    @Test fun completeFailureIsRecoverableOnNextCheck() {
        val access = Access().apply { refuse = { true } }
        val setup = TailscaleSetup(access)
        setup.open()
        assertTrue(setup.state.value.openFailed)
        setup.refresh()
        assertFalse(setup.state.value.openFailed)
        assertEquals(false, setup.state.value.installed)
    }

    @Test fun securityFailureKeepsActionableErrorAcrossAppResume() {
        val access = Access().apply { refuse = { throw SecurityException("fixture") } }
        val setup = TailscaleSetup(access)
        setup.open()
        assertTrue(setup.state.value.openFailed)
        setup.refresh(clearResult = false)
        assertTrue(setup.state.value.openFailed)
        access.refuse = { false }
        setup.open()
        assertFalse(setup.state.value.openFailed)
    }
}
