package dev.bridgey.android.agents

import dev.bridgey.android.codes.CodeGuard
import dev.bridgey.android.codes.CodeRelay
import dev.bridgey.android.codes.codeGuardText

/*
 * Codes over cloud (docs/mesh-and-codes.md, phase 2): when no Mac reads codes and no server with Detect codes is
 * connected, this phone may ask Round Robin's relay (services/otp-proxy, Cloudflare Workers AI) for the code in a
 * text message itself, so servers with Read codes still get it. Only while the person chose "Use cloud when no Mac is
 * reading" (off until chosen). Text messages only: email previews never go to the cloud. The relay's answer counts
 * only if the strict guard finds the code, verbatim, in the text this phone sent. A failure, a time-out or a rate
 * limit means nothing happens; there is no other fallback. Text and codes are never logged.
 */

/** Cloud reads per hour from this phone (the relay allows 10 a minute per install). */
const val CLOUD_READS_PER_HOUR = 20

/** How long a cloud read may take (the relay gives the model 1.5 s). */
const val CLOUD_TIMEOUT_MS = 3_000

/** One request to the relay. The real one is HTTP; tests use a fake. Called off the main thread. */
fun interface CloudExtractor {
    fun extract(text: String, sender: String?): CodeRelay.Answer
}

/** What one cloud read did, as the activity item's word. */
enum class CloudRead(val word: String) {
    FOUND("found"),
    NONE("none"),
    /** The relay answered a code the guard did not find in the text. */
    REFUSED("refused"),
    FAILED("failed"),
    LIMITED("limited"),
    OFF("off"),
}

class CloudCodes(
    private val enabled: () -> Boolean,
    private val extractor: CloudExtractor,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val limiter = SlidingWindowLimiter(CLOUD_READS_PER_HOUR, 3_600_000L)

    fun isOn(): Boolean = enabled()

    /** Reads one candidate text ([text] already joined and gated); the code when the guard accepts it. Blocking. */
    fun read(text: String, sender: String?): Pair<CloudRead, String?> {
        if (!enabled()) return CloudRead.OFF to null
        if (limiter.tryAcquire("cloud", clock()) != null) return CloudRead.LIMITED to null
        return when (val answer = runCatching { extractor.extract(text, sender) }.getOrElse { CodeRelay.Answer.Failed("unavailable") }) {
            is CodeRelay.Answer.Candidate -> CodeGuard.accept(answer.code, codeGuardText(text))?.let { CloudRead.FOUND to it } ?: (CloudRead.REFUSED to null)
            CodeRelay.Answer.NoCode -> CloudRead.NONE to null
            is CodeRelay.Answer.Failed -> CloudRead.FAILED to null
        }
    }
}

/** The relay over HTTPS, as the Mac's Cloud engine calls it: no cache, no cookies, a 3 second limit, the install id. */
class HttpCloudExtractor(private val baseUrl: String, private val installId: () -> String) : CloudExtractor {
    override fun extract(text: String, sender: String?): CodeRelay.Answer {
        val body = CodeRelay.requestBody(text, sender) ?: return CodeRelay.Answer.Failed("not_configured")
        val id = installId()
        if (!baseUrl.startsWith("https://") || !CodeRelay.isInstallId(id)) return CodeRelay.Answer.Failed("not_configured")
        val connection = java.net.URL(baseUrl.trimEnd('/') + "/v1/extract").openConnection() as java.net.HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = CLOUD_TIMEOUT_MS
            connection.readTimeout = CLOUD_TIMEOUT_MS
            connection.useCaches = false
            connection.instanceFollowRedirects = false
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("X-Bridgey-Install", id)
            connection.setRequestProperty("User-Agent", "BridgeyRR/1 (Android)")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val reply = stream?.use { it.readBytes().take(4_096).toByteArray().toString(Charsets.UTF_8) }.orEmpty()
            CodeRelay.parse(status, reply)
        } finally {
            connection.disconnect()
        }
    }
}
