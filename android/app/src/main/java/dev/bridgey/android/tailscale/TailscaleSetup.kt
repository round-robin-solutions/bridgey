package dev.bridgey.android.tailscale

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Package availability only: the companion app exposes no public login/connection status API. */
data class TailscaleSetupState(
    val installed: Boolean? = null,
    val openFailed: Boolean = false,
    val openedDownload: Boolean = false,
)

class TailscaleSetupActions(val open: () -> Unit = {}, val refresh: () -> Unit = {})

internal interface TailscaleAppAccess {
    fun installed(): Boolean
    fun launcher(): Intent?
    fun open(intent: Intent)
}

internal class AndroidTailscaleAppAccess(private val context: Context) : TailscaleAppAccess {
    override fun installed(): Boolean = try {
        @Suppress("DEPRECATION")
        context.packageManager.getPackageInfo(TailscaleSetup.PACKAGE, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) { false }

    override fun launcher(): Intent? = context.packageManager.getLaunchIntentForPackage(TailscaleSetup.PACKAGE)
    override fun open(intent: Intent) { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

/** All external activities require an explicit button tap. Refresh never starts or changes a VPN. */
internal class TailscaleSetup(private val access: TailscaleAppAccess) {
    companion object {
        const val PACKAGE = "com.tailscale.ipn"
        const val DOWNLOAD = "https://tailscale.com/download/android"
    }

    private val mutableState = MutableStateFlow(TailscaleSetupState())
    val state = mutableState.asStateFlow()

    fun refresh(clearResult: Boolean = true) {
        mutableState.value = mutableState.value.copy(
            installed = runCatching(access::installed).getOrNull(),
            openFailed = if (clearResult) false else mutableState.value.openFailed,
            openedDownload = if (clearResult) false else mutableState.value.openedDownload,
        )
    }

    fun open() {
        refresh()
        val launcher = runCatching(access::launcher).getOrNull()?.setPackage(PACKAGE)
        val first = launcher ?: if (mutableState.value.installed == true) null else {
            Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$PACKAGE")).setPackage("com.android.vending")
        }
        val opened = first?.let { runCatching { access.open(it) }.isSuccess } == true
        val downloaded = !opened && runCatching { access.open(Intent(Intent.ACTION_VIEW, Uri.parse(DOWNLOAD))) }.isSuccess
        mutableState.value = mutableState.value.copy(openFailed = !opened && !downloaded, openedDownload = downloaded)
    }
}
