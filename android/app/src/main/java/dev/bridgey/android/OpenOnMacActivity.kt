package dev.bridgey.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import dev.bridgey.android.ui.OpenOnMacActions
import dev.bridgey.android.ui.OpenOnMacPhase
import dev.bridgey.android.ui.OpenOnMacSheet
import dev.bridgey.android.ui.OpenOnMacState
import dev.bridgey.android.ui.OpenOnMacTarget
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.net.URI
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** The first http(s) link in shared text (browsers often share "Title https://..."), validated, or null. */
internal fun firstWebLink(text: String?): String? {
    if (text.isNullOrBlank()) return null
    return Regex("""https?://[^\s<>"']+""", RegexOption.IGNORE_CASE).findAll(text).firstNotNullOfOrNull { match ->
        validatedWebLink(match.value.trimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}'))
    }
}

internal fun linkHost(link: String): String? = runCatching { URI(link).host }.getOrNull()?.removePrefix("www.")

/**
 * "Open on Mac" in the share sheet. Any app in the foreground can start this activity with a link,
 * so it never sends on its own: it shows the host and the Mac and waits for Open. The Mac then
 * opens the link right away if its own setting allows it, or queues it like any received link.
 */
class OpenOnMacActivity : ComponentActivity() {
    private var link: String? = null
    private var state by mutableStateOf(OpenOnMacState(null, emptyList(), null, OpenOnMacPhase.Confirm))

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser) { finish(); return }
        link = firstWebLink(intent?.takeIf { it.action == Intent.ACTION_SEND }?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString())
        val pairing = app.pairing
        val targets = pairing.connections.value
            .filter { pairing.isFeatureAvailable(BridgeyFeature.LINKS, it.deviceId) }
            .map { OpenOnMacTarget(it.deviceId, it.peerName) }
        val selectedNow = pairing.state.value.let { (it as? PairingState.Connected)?.deviceId }
        state = OpenOnMacState(
            host = link?.let(::linkHost),
            targets = targets,
            selected = targets.firstOrNull { it.deviceId == selectedNow }?.deviceId ?: targets.firstOrNull()?.deviceId,
            phase = when {
                link == null -> OpenOnMacPhase.Nothing(getString(R.string.open_on_mac_no_link))
                !app.isBridgeyEnabled || targets.isEmpty() -> OpenOnMacPhase.Nothing(getString(R.string.open_on_mac_no_mac))
                else -> OpenOnMacPhase.Confirm
            },
        )
        setContent {
            BridgeyTheme {
                OpenOnMacSheet(
                    state,
                    OpenOnMacActions(
                        select = { id -> state = state.copy(selected = id) },
                        open = ::open,
                        cancel = ::finish,
                    ),
                )
            }
        }
    }

    private fun open() {
        val url = link ?: return
        val target = state.targets.firstOrNull { it.deviceId == state.selected } ?: return
        if (state.phase != OpenOnMacPhase.Confirm) return
        val pairing = (application as BridgeyApplication).pairing
        state = state.copy(phase = OpenOnMacPhase.Sending(target.name))
        val before = pairing.quickActions.linkResult.value?.serial ?: 0
        lifecycleScope.launch {
            pairing.selectDevice(target.deviceId)
            pairing.quickActions.sendLink(url, open = true)
            val result = pairing.quickActions.linkResult.filterNotNull().first { it.serial > before }
            val (message, success) = when (result.outcome) {
                LinkSendResult.Outcome.OPENED -> getString(R.string.open_on_mac_opened, target.name) to true
                LinkSendResult.Outcome.QUEUED -> getString(R.string.open_on_mac_queued, target.name) to true
                LinkSendResult.Outcome.DECLINED -> getString(R.string.open_on_mac_declined, target.name) to false
                LinkSendResult.Outcome.NOT_CONFIRMED -> getString(R.string.mac_action_not_confirmed, target.name) to false
                LinkSendResult.Outcome.NOT_SENT -> getString(R.string.open_on_mac_not_sent, target.name) to false
            }
            state = state.copy(phase = OpenOnMacPhase.Finished(message, success))
            if (success) {
                delay(1_600)
                finish()
            }
        }
    }
}
