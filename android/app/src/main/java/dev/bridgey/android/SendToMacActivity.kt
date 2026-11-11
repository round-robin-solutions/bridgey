package dev.bridgey.android

import android.app.Application
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewModelScope
import dev.bridgey.android.sharing.ShareFlow
import dev.bridgey.android.sharing.ShareMac
import dev.bridgey.android.sharing.SharePhase
import dev.bridgey.android.ui.SendToMacSheet
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.net.URI
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** The first http(s) link in shared text, including browser shares with a title. */
internal fun firstWebLink(text: String?): String? {
    if (text.isNullOrBlank()) return null
    return Regex("""https?://[^\s<>"']+""", RegexOption.IGNORE_CASE).findAll(text).firstNotNullOfOrNull { match ->
        validatedWebLink(match.value.trimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}'))
    }
}
internal fun linkHost(link: String): String? = runCatching { URI(link).host }.getOrNull()?.removePrefix("www.")

internal data class SharedMacContent(val text: String?, val files: List<Uri>) {
    val link: String? get() = if (files.isEmpty()) firstWebLink(text) else null
    val feature: BridgeyFeature get() = when {
        files.isNotEmpty() -> BridgeyFeature.FILES
        link != null -> BridgeyFeature.LINKS
        else -> BridgeyFeature.CLIPBOARD
    }
}

/** Exported input is untrusted. Never accept internal URIs, paths or non-share intents. */
@Suppress("DEPRECATION")
internal fun sharedMacContent(intent: Intent, packageName: String): SharedMacContent? = runCatching {
    if (intent.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return null
    val streams = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
    } else listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
    val uris = (streams.ifEmpty {
        intent.clipData?.let { clip -> (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri } }.orEmpty()
    }).distinct()
    if (uris.size > 1000 || uris.any { !isShareableStream(it.scheme, it.authority, packageName) }) return null
    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() && uris.isEmpty() }
    if (text == null && uris.isEmpty()) return null
    SharedMacContent(text, uris)
}.getOrNull()

/** One share owns its destination and results across rotation. Process death requires a fresh choice. */
class SendToMacModel(application: Application) : AndroidViewModel(application) {
    private val app = application as BridgeyApplication
    private val pairing get() = app.pairing
    private var content: SharedMacContent? = null
    private var initialized = false
    private var remainingFiles = emptyList<Uri>()
    private val mutableFlow = MutableStateFlow(ShareFlow(SharePhase.CHOOSING))
    val flow = mutableFlow.asStateFlow()
    private val mutableMacs = MutableStateFlow<List<ShareMac>>(emptyList())
    val macs = mutableMacs.asStateFlow()
    val host: String? get() = content?.link?.let(::linkHost)
    val isFileShare: Boolean get() = content?.files?.isNotEmpty() == true

    fun initialize(intent: Intent, recreated: Boolean) {
        if (initialized) return
        initialized = true
        content = sharedMacContent(intent, app.packageName)
        remainingFiles = content?.files.orEmpty()
        refresh()
        mutableFlow.value = if (content == null || !app.isBridgeyEnabled) {
            ShareFlow(SharePhase.FAILED, message = app.getString(if (content == null) R.string.share_nothing else R.string.share_app_off))
        } else ShareFlow.begin(macs.value, app.settings.state.value.lastSharedMac,
            app.settings.state.value.shareAlwaysAsk || recreated, SystemClock.elapsedRealtime())
        viewModelScope.launch {
            combine(pairing.connections, pairing.trustedDevices, pairing.presenceRevision, app.settings.state) { _, _, _, _ -> Unit }
                .collect { refresh() }
        }
    }

    private fun refresh() {
        val feature = content?.feature ?: BridgeyFeature.LINKS
        mutableMacs.value = pairing.trustedDevices.value.filterNot { it.isAgent }.map { device ->
            ShareMac(device.id, device.name, pairing.shareSessionId(device.id),
                pairing.isFeatureAvailable(feature, device.id), pairing.sharePresence(device.id))
        }.sortedWith(compareByDescending<ShareMac> { it.presence?.activeAge(SystemClock.elapsedRealtime()) != null }.thenBy { it.name })
    }

    fun choose(id: String) { refresh(); macs.value.firstOrNull { it.id == id }?.let { mutableFlow.value = flow.value.choose(it) } }
    fun change() { refresh(); mutableFlow.value = flow.value.change() }
    fun cancel() { mutableFlow.value = flow.value.cancel() }

    fun send() {
        val shared = content ?: return
        if (!app.isPrimaryUser || !app.isBridgeyEnabled) {
            mutableFlow.value = flow.value.copy(phase = SharePhase.FAILED, message = app.getString(R.string.share_app_off))
            return
        }
        refresh()
        val before = flow.value
        val target = macs.value.firstOrNull { it.id == before.target }
        val next = before.send(macs.value, app.getString(R.string.share_unavailable, target?.name ?: "Mac"))
        mutableFlow.value = next
        if (next.phase != SharePhase.SENDING || before.phase == SharePhase.SENDING) return
        val id = next.target ?: return
        val session = next.sessionId ?: return
        val name = target?.name ?: "Mac"
        viewModelScope.launch {
            val (success, message) = when {
                shared.link != null -> {
                    val (outcome, reason) = pairing.quickActions.sendSharedLink(shared.link!!, id, session)
                    when (outcome) {
                        LinkSendResult.Outcome.OPENED -> true to app.getString(R.string.open_on_mac_opened, name)
                        LinkSendResult.Outcome.QUEUED -> true to app.getString(R.string.share_parked, name)
                        LinkSendResult.Outcome.NOT_CONFIRMED -> false to app.getString(R.string.share_unconfirmed, name)
                        else -> false to app.getString(when (reason) {
                            "rate_limited" -> R.string.share_rate_limited
                            "browser_failed" -> R.string.share_browser_failed
                            "links_disabled" -> R.string.share_links_off
                            else -> R.string.share_unavailable
                        }, name)
                    }
                }
                shared.files.isNotEmpty() -> sendFiles(id, session, name)
                else -> {
                    val result = CompletableDeferred<ClipboardSendResult>()
                    pairing.sendSharedText(shared.text.orEmpty(), id, session) { result.complete(it) }
                    when (withTimeoutOrNull(10_000) { result.await() }) {
                        ClipboardSendResult.DELIVERED -> true to app.getString(R.string.share_copied, name)
                        ClipboardSendResult.TOO_LARGE -> false to app.getString(R.string.share_text_large)
                        ClipboardSendResult.DISABLED -> false to app.getString(R.string.share_clipboard_off, name)
                        ClipboardSendResult.NO_ACKNOWLEDGEMENT, null -> false to app.getString(R.string.share_unconfirmed, name)
                        else -> false to app.getString(R.string.share_unavailable, name)
                    }
                }
            }
            if (success) app.settings.setLastSharedMac(id)
            mutableFlow.value = flow.value.finish(success, message)
        }
    }

    private suspend fun sendFiles(id: String, session: String, name: String): Pair<Boolean, String> {
        var ids = emptyList<String>()
        val batch = remainingFiles
        if (!pairing.sendSharedFiles(batch, id, session) { ids = it }) return false to app.getString(R.string.share_unavailable, name)
        val ended = pairing.fileTransfers.first { states -> ids.all { states[it]?.active == false } }
        val failed = ids.indices.filter { ended[ids[it]]?.outcome != TransferEnd.SENT }
        remainingFiles = failed.map { batch[it] }
        return if (failed.isEmpty()) true to app.getString(R.string.share_files_sent, name)
            else false to (ended[ids[failed.first()]]?.status ?: app.getString(R.string.share_file_failed, name))
    }
}

class SendToMacActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (!(application as BridgeyApplication).isPrimaryUser) { finish(); return }
        val model = ViewModelProvider(this)[SendToMacModel::class.java]
        model.initialize(intent, savedInstanceState != null)
        setContent {
            BridgeyTheme {
                val flow by model.flow.collectAsStateWithLifecycle()
                val macs by model.macs.collectAsStateWithLifecycle()
                SendToMacSheet(flow, macs, model.host, model.isFileShare, model::choose, model::send, model::change) {
                    model.cancel()
                    finish()
                }
            }
        }
        // Hidden or backgrounded activities cannot finish the automatic countdown.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                model.flow.map { it.phase }.distinctUntilChanged().collectLatest { phase ->
                    when (phase) {
                        SharePhase.GRACE -> { delay(1_500); model.send() }
                        SharePhase.SUCCEEDED -> { delay(1_600); finish() }
                        SharePhase.CANCELLED -> finish()
                        else -> Unit
                    }
                }
            }
        }
    }
}
