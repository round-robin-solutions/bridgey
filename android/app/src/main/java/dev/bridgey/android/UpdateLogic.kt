package dev.bridgey.android

import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import org.json.JSONException
import org.json.JSONObject

/**
 * Round Robin edition release channels. A channel reads its own feed and the
 * feeds of every more stable channel, then offers the newest build that is
 * newer than the installed one. Build numbers grow across channels, so moving
 * to a more stable channel never downgrades; it waits for a newer build.
 */
enum class UpdateChannel(val key: String, val title: String, val detail: String) {
    STABLE("stable", "Stable", "Tested releases. Recommended."),
    BETA("beta", "Beta", "Upcoming features before they reach Stable."),
    NIGHTLY("nightly", "Nightly", "Daily builds. Expect rough edges."),
    ;

    val feedChannels: List<UpdateChannel> get() = entries.filter { it.ordinal <= ordinal }

    companion object {
        fun fromKey(key: String?): UpdateChannel = entries.firstOrNull { it.key == key } ?: STABLE
    }
}

data class AndroidUpdate(
    val channel: UpdateChannel,
    val versionName: String,
    val versionCode: Long,
    val notesUrl: String,
    val notes: String,
    val apkUrl: String,
    val sha256: String,
    val size: Long,
    val minSdk: Int,
)

class UpdateFeedException(message: String) : Exception(message)

object UpdateFeeds {
    const val SCHEMA = 1
    const val MAX_FEED_BYTES = 64 * 1024
    const val MAX_APK_BYTES = 150L * 1024 * 1024
    const val MAX_NOTES_LENGTH = 4_000
    const val CHECK_INTERVAL_MILLIS = 24L * 60 * 60 * 1000
    const val APP_OPEN_MIN_INTERVAL_MILLIS = 15L * 60 * 1000

    private val sha256Pattern = Regex("^[0-9a-f]{64}$")
    private val versionPattern = Regex("""^\d+\.\d+\.\d+-rr\.\d+(-(beta\.\d+|nightly\.\d{8}))?$""")

    fun feedUrl(baseUrl: String, channel: UpdateChannel): String {
        require(baseUrl.startsWith("https://")) { "Update feeds must use HTTPS" }
        return "${baseUrl.trimEnd('/')}/${channel.key}.json"
    }

    /** Version names carry their channel: no suffix for Stable, -beta.N or -nightly.YYYYMMDD otherwise. */
    fun versionNameMatchesChannel(versionName: String, channel: UpdateChannel): Boolean {
        if (!versionPattern.matches(versionName)) return false
        return when (channel) {
            UpdateChannel.STABLE -> !versionName.contains("-beta.") && !versionName.contains("-nightly.")
            UpdateChannel.BETA -> versionName.contains("-beta.")
            UpdateChannel.NIGHTLY -> versionName.contains("-nightly.")
        }
    }

    /**
     * Parses one channel feed and returns its Android entry, or null when the
     * release has no Android build. Throws [UpdateFeedException] for anything
     * malformed, for another app or channel, or for assets outside [assetUrlPrefix].
     */
    fun parseAndroid(
        json: String,
        expectedChannel: UpdateChannel,
        appId: String,
        assetUrlPrefix: String,
    ): AndroidUpdate? {
        if (json.length > MAX_FEED_BYTES) throw UpdateFeedException("Feed is too large")
        val root = try {
            JSONObject(json)
        } catch (error: JSONException) {
            throw UpdateFeedException("Feed is not valid JSON")
        }
        try {
            if (root.getInt("schema") != SCHEMA) throw UpdateFeedException("Unsupported feed schema")
            if (root.getString("app") != appId) throw UpdateFeedException("Feed is for another app")
            if (root.getString("channel") != expectedChannel.key) throw UpdateFeedException("Feed is for another channel")
            val notesUrl = root.optString("notesUrl", "")
            if (notesUrl.isNotEmpty() && !notesUrl.startsWith("https://")) throw UpdateFeedException("Release notes must use HTTPS")
            val android = root.optJSONObject("android") ?: return null
            val versionName = android.getString("versionName")
            if (!versionNameMatchesChannel(versionName, expectedChannel)) {
                throw UpdateFeedException("Version $versionName does not belong to ${expectedChannel.title}")
            }
            val versionCode = android.getLong("versionCode")
            if (versionCode <= 0 || versionCode > Int.MAX_VALUE) throw UpdateFeedException("Invalid version code")
            val url = android.getString("url")
            if (!url.startsWith(assetUrlPrefix) || !assetUrlPrefix.startsWith("https://")) {
                throw UpdateFeedException("APK URL is outside the release repository")
            }
            val sha256 = android.getString("sha256").lowercase()
            if (!sha256Pattern.matches(sha256)) throw UpdateFeedException("Invalid SHA-256")
            val size = android.getLong("size")
            if (size <= 0 || size > MAX_APK_BYTES) throw UpdateFeedException("Invalid APK size")
            val minSdk = android.optInt("minSdk", 26)
            return AndroidUpdate(
                channel = expectedChannel,
                versionName = versionName,
                versionCode = versionCode,
                notesUrl = notesUrl,
                notes = root.optString("notes", "").take(MAX_NOTES_LENGTH),
                apkUrl = url,
                sha256 = sha256,
                size = size,
                minSdk = minSdk,
            )
        } catch (error: JSONException) {
            throw UpdateFeedException("Feed is missing a required field")
        }
    }

    /** Newest candidate that runs on [sdkInt] and is strictly newer than the installed build. */
    fun selectUpdate(installedVersionCode: Long, candidates: List<AndroidUpdate>, sdkInt: Int): AndroidUpdate? =
        candidates
            .filter { it.versionCode > installedVersionCode && it.minSdk <= sdkInt }
            .maxByOrNull { it.versionCode }

    fun isCheckDue(lastCheckedAt: Long, now: Long, intervalMillis: Long): Boolean =
        lastCheckedAt <= 0 || now < lastCheckedAt || now - lastCheckedAt >= intervalMillis

    fun sha256Hex(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    fun sha256Matches(file: File, expected: String): Boolean =
        file.isFile && file.inputStream().use(::sha256Hex) == expected.lowercase()

    fun certificateSha256(certificate: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(certificate).joinToString("") { "%02x".format(it) }

    /** The downloaded APK must be signed by exactly the certificates of the installed app. */
    fun signersMatch(installed: Set<String>, candidate: Set<String>): Boolean =
        installed.isNotEmpty() && installed == candidate
}
