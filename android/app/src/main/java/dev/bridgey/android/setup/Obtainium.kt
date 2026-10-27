package dev.bridgey.android.setup

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import dev.bridgey.android.UpdateChannel

/**
 * Settings > About > Add to Obtainium. Builds byte for byte the links scripts/rr/obtainium.py writes
 * into the README and the website: JSON keys in the order id, url, author, name, additionalSettings
 * (itself a compact JSON string), percent-encoded like Dart's Uri.encodeComponent. Obtainium filters
 * releases by title (falling back to the tag); our titles end in the version name, so the filters
 * match that ending. Stable leaves out pre-releases, which also hides the `channels` and `models`
 * releases.
 */
object Obtainium {
    const val APP_ID = "in.roundrobin.bridgey"
    const val REPO_URL = "https://github.com/round-robin-solutions/bridgey"
    const val AUTHOR = "Round Robin"
    const val NAME = "Bridgey by Round Robin"
    const val INSTALL_URL = "https://github.com/ImranR98/Obtainium"
    const val WEB_REDIRECT = "https://apps.obtainium.imranr.dev/redirect?r="

    /** Beta reads Stable and Beta, as the in-app Beta channel does. */
    const val BETA_FILTER = "-rr[.][0-9]+(-beta[.][0-9]+)?$"

    /** Nightly reads every channel. */
    const val NIGHTLY_FILTER = "-rr[.][0-9]+(-(beta|nightly)[.][0-9]+)?$"

    fun additionalSettings(channel: UpdateChannel): String = when (channel) {
        UpdateChannel.STABLE -> """{"includePrereleases":false}"""
        UpdateChannel.BETA -> """{"includePrereleases":true,"filterReleaseTitlesByRegEx":${quote(BETA_FILTER)}}"""
        UpdateChannel.NIGHTLY -> """{"includePrereleases":true,"filterReleaseTitlesByRegEx":${quote(NIGHTLY_FILTER)}}"""
    }

    fun appJson(channel: UpdateChannel, appId: String = APP_ID): String =
        """{"id":${quote(appId)},"url":${quote(REPO_URL)},"author":${quote(AUTHOR)},"name":${quote(NAME)},"additionalSettings":${quote(additionalSettings(channel))}}"""

    /** `obtainium://app/<URL-encoded JSON>`. */
    fun link(channel: UpdateChannel, appId: String = APP_ID): String =
        "obtainium://app/" + encodeComponent(appJson(channel, appId), DART_SAFE)

    /** The form for web pages, which cannot open obtainium:// directly. */
    fun webLink(channel: UpdateChannel, appId: String = APP_ID): String =
        WEB_REDIRECT + encodeComponent(link(channel, appId), "")

    /** Opens Obtainium on the link, or Obtainium's page when it is not installed. */
    fun open(context: Context, channel: UpdateChannel) {
        val add = Intent(Intent.ACTION_VIEW, Uri.parse(link(channel, context.packageName))).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(add)
        } catch (_: ActivityNotFoundException) {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(INSTALL_URL)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }

    /** Dart's Uri.encodeComponent keeps these besides letters, digits and - _ . ~ */
    private const val DART_SAFE = "!*'()"

    /** Percent-encodes UTF-8 bytes, keeping letters, digits, `-_.~` and [safe] (Python's quote). */
    internal fun encodeComponent(value: String, safe: String): String = buildString {
        value.toByteArray(Charsets.UTF_8).forEach { byte ->
            val code = byte.toInt() and 0xFF
            val char = code.toChar()
            if (code < 0x80 && (char.isLetterOrDigit() || char in "-_.~" || char in safe)) {
                append(char)
            } else {
                append('%').append(HEX[code shr 4]).append(HEX[code and 0x0F])
            }
        }
    }

    private const val HEX = "0123456789ABCDEF"

    /** A JSON string literal: our values are ASCII without control characters. */
    internal fun quote(value: String): String = buildString {
        append('"')
        value.forEach { char ->
            when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                else -> if (char < ' ') append("\\u%04x".format(char.code)) else append(char)
            }
        }
        append('"')
    }
}
