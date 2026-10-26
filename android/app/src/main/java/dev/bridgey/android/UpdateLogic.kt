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

/** Why an update step stopped, in words the Settings card can show. */
enum class UpdateError { CHECK, DOWNLOAD, SAFETY, INSTALLER, CANCELLED }

class UpdateFeedException(message: String, val error: UpdateError = UpdateError.SAFETY) : Exception(message)

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

    /**
     * What a finished check offers. A skipped version stays hidden from automatic checks; a check
     * the user started shows it again (as Sparkle does on the Mac).
     */
    fun offer(update: AndroidUpdate?, skippedVersionCode: Long, userInitiated: Boolean): AndroidUpdate? =
        update?.takeIf { userInitiated || it.versionCode != skippedVersionCode }

    /**
     * The part of [versionName] that differs from [other]: "beta.10" when both are pre-releases
     * of the same release, otherwise the whole name.
     */
    fun shortVersion(versionName: String, other: String): String {
        fun split(value: String): Pair<String, String?> {
            for (marker in listOf("-beta.", "-nightly.")) {
                val index = value.indexOf(marker)
                if (index >= 0) return value.substring(0, index) to value.substring(index + 1)
            }
            return value to null
        }
        val (base, pre) = split(versionName)
        return if (pre != null && base == split(other).first) pre else versionName
    }

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

/** One piece of release notes as Settings draws it. */
sealed interface ReleaseNoteBlock {
    val text: String

    data class Heading(override val text: String) : ReleaseNoteBlock
    data class Bullet(override val text: String) : ReleaseNoteBlock
    data class Paragraph(override val text: String) : ReleaseNoteBlock
}

/**
 * Turns release notes (Markdown, one item per line) into headings, bullets and paragraphs, so
 * Settings can draw a real list. The Mac app has the same rules (ReleaseNotes in UpdateFlow.swift).
 */
object ReleaseNotes {
    private val bullet = Regex("""^(?:[-*+•–]|\d{1,3}[.)])\s+""")
    private val heading = Regex("""^#{1,6}\s*""")
    private val link = Regex("""\[([^\]]+)]\((?:[^)]+)\)""")
    private val emphasis = Regex("""(\*\*|__|`)""")

    /** [version] is dropped where the notes repeat it as a line or heading (the card names it already). */
    fun blocks(notes: String, version: String? = null): List<ReleaseNoteBlock> {
        val blocks = mutableListOf<ReleaseNoteBlock>()
        var open = false
        for (raw in notes.lines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.all { it in "-*_=" }) {
                open = false
                continue
            }
            if (line.startsWith("#")) {
                val text = plain(line.replaceFirst(heading, "").trim())
                if (text.isNotEmpty() && !isVersion(text, version)) blocks += ReleaseNoteBlock.Heading(text)
                open = false
                continue
            }
            if (isVersion(line, version)) {
                open = false
                continue
            }
            val marker = bullet.find(line)
            if (marker != null) {
                val text = plain(line.substring(marker.range.last + 1).trim())
                if (text.isNotEmpty()) {
                    blocks += ReleaseNoteBlock.Bullet(text)
                    open = true
                }
                continue
            }
            val last = blocks.lastOrNull()
            if (open && last != null && continues(last.text, line)) {
                blocks[blocks.lastIndex] = when (last) {
                    is ReleaseNoteBlock.Bullet -> ReleaseNoteBlock.Bullet("${last.text} ${plain(line)}")
                    is ReleaseNoteBlock.Paragraph -> ReleaseNoteBlock.Paragraph("${last.text} ${plain(line)}")
                    is ReleaseNoteBlock.Heading -> last
                }
                continue
            }
            blocks += ReleaseNoteBlock.Paragraph(plain(line))
            open = true
        }
        return blocks
    }

    /** The first blocks that fit about [lines] lines of [charsPerLine] characters; always at least one. */
    fun preview(blocks: List<ReleaseNoteBlock>, lines: Int = 4, charsPerLine: Int = 44): List<ReleaseNoteBlock> {
        var used = 0
        val result = mutableListOf<ReleaseNoteBlock>()
        for (block in blocks) {
            val cost = maxOf(1, (block.text.length + charsPerLine - 1) / maxOf(1, charsPerLine))
            if (result.isNotEmpty() && used + cost > lines) break
            result += block
            used += cost
        }
        while (result.size > 1 && result.last() is ReleaseNoteBlock.Heading) result.removeAt(result.lastIndex)
        return result
    }

    /** Inline Markdown as plain words: link text, no bold or code markers. */
    fun plain(text: String): String = text.replace(link, "$1").replace(emphasis, "")

    private fun isVersion(text: String, version: String?): Boolean {
        if (version.isNullOrEmpty()) return false
        return listOf(version, "v$version", "bridgey $version", "bridgey v$version").any { it.equals(text, ignoreCase = true) }
    }

    /** A wrapped line continues the item above unless that item already ended a sentence. */
    private fun continues(previous: String, line: String): Boolean {
        val end = previous.lastOrNull() ?: return false
        if (line.first().isLowerCase()) return true
        return end !in ".!?:"
    }
}
