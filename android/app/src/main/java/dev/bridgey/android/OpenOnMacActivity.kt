package dev.bridgey.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.ui.destinationChoices
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
import kotlinx.coroutines.withTimeoutOrNull

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
        state = OpenOnMacState(
            host = link?.let(::linkHost),
            targets = emptyList(),
            selected = savedInstanceState?.getString(SELECTED_DEVICE),
            phase = if (link == null) OpenOnMacPhase.Nothing(getString(R.string.open_on_mac_no_link)) else OpenOnMacPhase.Confirm,
        )
        setContent {
            val connections by pairing.connections.collectAsStateWithLifecycle()
            val trusted by pairing.trustedDevices.collectAsStateWithLifecycle()
            val settings by app.settings.state.collectAsStateWithLifecycle()
            val revision by pairing.smartRoutingRevision.collectAsStateWithLifecycle()
            val choices = androidx.compose.runtime.remember(connections, trusted, settings, revision) {
                destinationChoices(this, pairing, BridgeyFeature.LINKS).map {
                    OpenOnMacTarget(it.deviceId, it.name, it.available && app.isBridgeyEnabled, it.detail, it.suggested)
                }
            }
            BridgeyTheme {
                OpenOnMacSheet(
                    state.copy(targets = choices),
                    OpenOnMacActions(
                        select = { id -> state = state.copy(selected = id, message = null) },
                        open = ::open,
                        cancel = ::finish,
                    ),
                )
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        state.selected?.let { outState.putString(SELECTED_DEVICE, it) }
        super.onSaveInstanceState(outState)
    }

    private fun open() {
        val url = link ?: return
        val id = state.selected ?: return
        if (state.phase != OpenOnMacPhase.Confirm) return
        val app = application as BridgeyApplication
        val pairing = app.pairing
        val target = pairing.connections.value.firstOrNull { it.deviceId == id }
        if (!app.isBridgeyEnabled || target == null || !pairing.isFeatureAvailable(BridgeyFeature.LINKS, id)) {
            state = state.copy(message = getString(R.string.destination_unavailable))
            return
        }
        state = state.copy(phase = OpenOnMacPhase.Sending(target.peerName), message = null)
        val before = pairing.quickActions.linkResult.value?.serial ?: 0
        lifecycleScope.launch {
            if (!pairing.sendLinkToDevice(url, id, open = true)) {
                state = state.copy(phase = OpenOnMacPhase.Confirm, message = getString(R.string.destination_unavailable))
                return@launch
            }
            val result = withTimeoutOrNull(12_000) {
                pairing.quickActions.linkResult.filterNotNull().first { it.serial > before }
            }
            val (message, success) = when (result?.outcome) {
                LinkSendResult.Outcome.OPENED -> getString(R.string.open_on_mac_opened, target.peerName) to true
                LinkSendResult.Outcome.QUEUED -> getString(R.string.open_on_mac_queued, target.peerName) to true
                LinkSendResult.Outcome.DECLINED -> getString(R.string.open_on_mac_declined, target.peerName) to false
                LinkSendResult.Outcome.NOT_CONFIRMED -> getString(R.string.mac_action_not_confirmed, target.peerName) to false
                null -> getString(R.string.mac_action_not_confirmed, target.peerName) to false
                LinkSendResult.Outcome.NOT_SENT -> getString(R.string.open_on_mac_not_sent, target.peerName) to false
            }
            state = state.copy(phase = OpenOnMacPhase.Finished(message, success))
            if (success) {
                delay(1_600)
                finish()
            }
        }
    }
    private companion object {
        const val SELECTED_DEVICE = "selected_destination"
    }
}
