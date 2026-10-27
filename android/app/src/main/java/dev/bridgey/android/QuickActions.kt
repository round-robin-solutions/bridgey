package dev.bridgey.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

internal class QuickRequestSequence {
    private val last = mutableMapOf<String, Long>()
    @Synchronized fun accept(feature: String, sequence: Long): Boolean {
        if (feature !in setOf("links", "media") || sequence !in 1..9_007_199_254_740_991L || sequence <= (last[feature] ?: 0)) return false
        last[feature] = sequence
        return true
    }
}

internal fun validatedWebLink(value: String): String? {
    val text = value.trim()
    if (text.toByteArray(Charsets.UTF_8).size > 4096 || text.any { it.isWhitespace() || it.code < 32 || it == '\\' }) return null
    val uri = runCatching { URI(text) }.getOrNull() ?: return null
    return text.takeIf { uri.scheme?.lowercase() in setOf("https", "http") &&
        !uri.host.isNullOrBlank() && uri.rawUserInfo == null && (uri.port == -1 || uri.port in 1..65535) }
}

data class MacMediaState(
    val player: String = "", val title: String = "", val artist: String = "",
    val playing: Boolean = false, val position: Int = 0, val duration: Int = 0, val volume: Int = 0,
    val detail: String = "Enable a player in Mac Settings → Media",
    val artwork: String? = null,
)

/** How a link sent with Open on Mac ended. [serial] tells two equal results apart. */
data class LinkSendResult(val outcome: Outcome, val serial: Long) {
    enum class Outcome { OPENED, QUEUED, DECLINED, NOT_CONFIRMED, NOT_SENT }
}

class QuickActions(
    private val context: Context,
    private val scope: CoroutineScope,
    private val available: (BridgeyFeature) -> Boolean,
    private val send: (String, JSONObject) -> Boolean,
    /** The selected Mac understands `action: "open"` (draft links_open_draft1). */
    private val linksOpenSupported: () -> Boolean = { false },
) {
    private val mutableLinkResult = MutableStateFlow<LinkSendResult?>(null)

    /** The outcome of the latest link this phone sent, for Open on Mac. */
    val linkResult = mutableLinkResult.asStateFlow()
    private var linkSerial = 0L
    private fun linkResult(outcome: LinkSendResult.Outcome) {
        linkSerial += 1
        mutableLinkResult.value = LinkSendResult(outcome, linkSerial)
    }
    private val mutableLink = MutableStateFlow<String?>(null)
    val receivedLink = mutableLink.asStateFlow()
    private val mutableStatus = MutableStateFlow<String?>(null)
    val status = mutableStatus.asStateFlow()
    private val mutableMedia = MutableStateFlow(MacMediaState())
    val media = mutableMedia.asStateFlow()
    private val pending = mutableMapOf<String, Pair<String, Job>>()
    private var sequence = 0L

    @Synchronized fun request(feature: BridgeyFeature, action: String, value: String = "") {
        if (!available(feature)) { mutableStatus.value = "Feature is unavailable on one of your devices"; return }
        if (feature.key in pending) return
        val id = UUID.randomUUID().toString()
        val expiry = scope.launch {
            delay(8000)
            synchronized(this@QuickActions) {
                if (pending[feature.key]?.first == id) {
                    pending.remove(feature.key)
                    mutableStatus.value = "The other device did not confirm the request"
                    if (feature == BridgeyFeature.LINKS) linkResult(LinkSendResult.Outcome.NOT_CONFIRMED)
                }
            }
        }
        pending[feature.key] = id to expiry
        sequence += 1
        mutableStatus.value = "Sending…"
        if (!send("quick.request", JSONObject().put("version", 1).put("requestId", id)
                .put("feature", feature.key).put("action", action).put("value", value).put("sequence", sequence))) {
            pending.remove(feature.key)?.second?.cancel()
            mutableStatus.value = "Not connected — request not sent"
            if (feature == BridgeyFeature.LINKS) linkResult(LinkSendResult.Outcome.NOT_SENT)
        }
    }

    /**
     * Sends a link to the selected Mac. With [open] (Open on Mac) and a Mac that understands it,
     * the request asks the Mac to open it right away; the Mac's own setting decides, and otherwise
     * queues it like any link.
     */
    fun sendLink(value: String, open: Boolean = false) {
        val url = validatedWebLink(value)
        if (url == null) {
            mutableStatus.value = "Copy a valid http or https link first"
            if (open) linkResult(LinkSendResult.Outcome.NOT_SENT)
            return
        }
        if (open && (!available(BridgeyFeature.LINKS) || BridgeyFeature.LINKS.key in pending)) linkResult(LinkSendResult.Outcome.NOT_SENT)
        request(BridgeyFeature.LINKS, if (open && linksOpenSupported()) "open" else "offer", url)
    }

    @Synchronized fun receive(kind: String, payload: JSONObject) {
        if (payload.opt("version") != 1) return
        when (kind) {
            "quick.request" -> {
                val id = payload.optString("requestId")
                if (runCatching { UUID.fromString(id) }.isFailure) return
                val link = validatedWebLink(payload.optString("value"))
                val accepted = available(BridgeyFeature.LINKS) && payload.optString("feature") == "links" &&
                    payload.optString("action") == "offer" && link != null && mutableLink.value == null
                if (accepted) mutableLink.value = link
                send("quick.result", JSONObject().put("version", 1).put("requestId", id).put("feature", "links")
                    .put("accepted", accepted))
            }
            "quick.result" -> {
                val feature = payload.optString("feature")
                if (pending[feature]?.first != payload.optString("requestId")) return
                pending.remove(feature)?.second?.cancel()
                val accepted = payload.opt("accepted") == true
                val opened = feature == "links" && accepted && payload.opt("opened") == true
                if (feature == "links") {
                    linkResult(
                        when {
                            opened -> LinkSendResult.Outcome.OPENED
                            accepted -> LinkSendResult.Outcome.QUEUED
                            else -> LinkSendResult.Outcome.DECLINED
                        },
                    )
                }
                mutableStatus.value = if (accepted) {
                    if (opened) "Link opened on the Mac"
                    else if (feature == "links") "Link delivered — waiting for the user to open it" else "Media command completed"
                } else if (feature == "media") "Player unavailable or busy — check Mac media settings and try again"
                else "Link declined — check settings or dismiss the previous link"
            }
            "media.state" -> {
                if (!available(BridgeyFeature.MEDIA)) return
                val position = payload.opt("position") as? Int ?: return
                val duration = payload.opt("duration") as? Int ?: return
                val volume = payload.opt("volume") as? Int ?: return
                if (position !in 0..604800 || duration !in 0..604800 || volume !in 0..100 ||
                    payload.opt("playing") !is Boolean) return
                mutableMedia.value = MacMediaState(
                    payload.optString("player").take(64), payload.optString("title").take(256),
                    payload.optString("artist").take(256), payload.getBoolean("playing"),
                    position, duration, volume, payload.optString("detail").take(256),
                    (payload.opt("artwork") as? String)?.takeIf { it.length <= 21848 },
                )
            }
        }
    }

    fun openLink() {
        val link = mutableLink.value?.let(::validatedWebLink) ?: return
        if (!available(BridgeyFeature.LINKS)) { dismissLink(); return }
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .onSuccess { mutableLink.value = null }
            .onFailure { mutableStatus.value = "No browser available" }
    }
    fun dismissLink() { mutableLink.value = null }
    @Synchronized fun policyChanged() {
        if (!available(BridgeyFeature.LINKS)) mutableLink.value = null
        if (!available(BridgeyFeature.MEDIA)) mutableMedia.value = MacMediaState()
        pending.entries.removeAll { (feature, operation) ->
            val disabled = BridgeyFeature.entries.find { it.key == feature }?.let { !available(it) } ?: true
            if (disabled) { operation.second.cancel(); mutableStatus.value = null }
            disabled
        }
    }
    /** The selected device changed: pending requests end, and its own media state (if known) shows. */
    @Synchronized fun targetChanged(media: JSONObject?) {
        pending.values.forEach { it.second.cancel() }; pending.clear()
        mutableMedia.value = MacMediaState()
        media?.let { receive("media.state", it) }
    }
    @Synchronized fun reset() {
        pending.values.forEach { it.second.cancel() }; pending.clear()
        mutableLink.value = null; mutableMedia.value = MacMediaState(); mutableStatus.value = null
    }
}
