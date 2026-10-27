package dev.bridgey.android.updates

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import java.util.UUID
import org.json.JSONObject

/*
 * Update all, draft `updates_draft1` (docs/protocol.md, "Update all"). Each device tells the devices
 * connected to it which version it runs, on which channel, and where its own update stands
 * (updates.status); Update all asks each connected device to update itself (updates.start), which
 * names no version, URL or file: the receiver checks its own channel feed and installs only through
 * its own checks. The Mac has the same codec in UpdateAll.swift.
 */

/** Draft, edition only: the device sends updates.status and understands updates.start. */
const val UPDATES_FEATURE_KEY = "updates_draft1"

const val UPDATES_STATUS_MAX_BYTES = 1_024
const val UPDATES_START_MAX_BYTES = 512
const val UPDATES_RESULT_MAX_BYTES = 512

/** This edition's name on the wire. */
const val UPDATES_EDITION = "rr"

private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L

enum class UpdatePlatform(val wire: String) {
    ANDROID("android"),
    MACOS("macos"),
    ;

    companion object {
        fun fromWire(value: String): UpdatePlatform? = entries.firstOrNull { it.wire == value }
    }
}

/** A channel as it travels: the same three as [dev.bridgey.android.UpdateChannel]. */
enum class WireChannel(val wire: String) {
    STABLE("stable"),
    BETA("beta"),
    NIGHTLY("nightly"),
    ;

    companion object {
        fun fromWire(value: String): WireChannel? = entries.firstOrNull { it.wire == value }
    }
}

enum class UpdateState(val wire: String) {
    CURRENT("current"),
    CHECKING("checking"),
    AVAILABLE("available"),
    DOWNLOADING("downloading"),
    READY("ready"),
    INSTALLING("installing"),
    NEEDS_USER("needs_user"),
    FAILED("failed"),
    MANUAL("manual"),
    ;

    companion object {
        fun fromWire(value: String): UpdateState? = entries.firstOrNull { it.wire == value }
    }
}

/** Why a state stopped or waits. Unknown reasons read as [OTHER]. */
enum class UpdateReason(val wire: String) {
    CONFIRM("confirm"),
    PERMISSION("permission"),
    CHECK("check"),
    DOWNLOAD("download"),
    SAFETY("safety"),
    INSTALLER("installer"),
    CANCELLED("cancelled"),
    NOT_APPLIED("not_applied"),
    OTHER("other"),
    ;

    companion object {
        fun fromWire(value: String): UpdateReason = entries.firstOrNull { it.wire == value } ?: OTHER
    }
}

/** One device's version and where its own update stands (updates.status). */
data class UpdateStatus(
    val platform: UpdatePlatform,
    val edition: String,
    val app: String,
    val build: Long,
    val channel: WireChannel,
    val state: UpdateState,
    val target: String? = null,
    val targetBuild: Long? = null,
    val progress: Int? = null,
    val reason: UpdateReason? = null,
    val remoteStart: Boolean,
    val checkedAt: Long,
) {
    /** The same status without the download progress: what "changed" means for sending. */
    fun withoutProgress(): UpdateStatus = copy(progress = null)
}

/** updates.start: update yourself now. [retry] only when the person tapped Retry for this device. */
data class UpdateStart(val requestId: String, val retry: Boolean)

enum class UpdateResultStatus(val wire: String) { ACCEPTED("accepted"), REFUSED("refused") }

/** Why a device refused updates.start. Unknown reasons read as [OTHER]. */
enum class UpdateRefusal(val wire: String) {
    DISABLED("disabled"),
    RATE_LIMITED("rate_limited"),
    MANUAL("manual"),
    NOT_APPLIED("not_applied"),
    BUSY("busy"),
    OTHER("other"),
    ;

    companion object {
        fun fromWire(value: String?): UpdateRefusal = entries.firstOrNull { it.wire == value } ?: OTHER
    }
}

/** updates.result: [reason] only with [UpdateResultStatus.REFUSED]. */
data class UpdateResult(val requestId: String, val status: UpdateResultStatus, val reason: UpdateRefusal? = null)

private fun utf8Length(value: String): Int = value.toByteArray(Charsets.UTF_8).size

private fun boundedString(value: Any?, maxBytes: Int): String? =
    (value as? String)?.takeIf { it.isNotEmpty() && utf8Length(it) <= maxBytes }

/** A UUID in its 36-character form, lowercased; null otherwise. */
internal fun wireUuid(value: Any?): String? {
    val text = value as? String ?: return null
    if (text.length != 36 || runCatching { UUID.fromString(text) }.isFailure) return null
    return text.lowercase()
}

/** Optional field: absent or JSON null is null; anything present must pass [read] or the message is malformed. */
private inline fun <T> optional(payload: JSONObject, key: String, read: (Any?) -> T?): Result<T?> {
    if (!payload.has(key) || payload.isNull(key)) return Result.success(null)
    return read(payload.opt(key))?.let { Result.success(it) } ?: Result.failure(IllegalArgumentException(key))
}

fun parseUpdateStatus(payload: JSONObject): UpdateStatus? {
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val platform = (payload.opt("platform") as? String)?.let(UpdatePlatform::fromWire) ?: return null
    val edition = boundedString(payload.opt("edition"), 32) ?: return null
    val app = boundedString(payload.opt("app"), 64) ?: return null
    val build = jsonInteger(payload.opt("build"))?.takeIf { it in 1..MAX_SAFE_INTEGER } ?: return null
    val channel = (payload.opt("channel") as? String)?.let(WireChannel::fromWire) ?: return null
    val state = (payload.opt("state") as? String)?.let(UpdateState::fromWire) ?: return null
    val target = optional(payload, "target") { boundedString(it, 64) }.getOrElse { return null }
    val targetBuild = optional(payload, "targetBuild") { value -> jsonInteger(value)?.takeIf { it in 1..MAX_SAFE_INTEGER } }.getOrElse { return null }
    val progress = optional(payload, "progress") { value -> jsonInteger(value)?.takeIf { it in 0..100 }?.toInt() }.getOrElse { return null }
    val reason = optional(payload, "reason") { (it as? String)?.let(UpdateReason::fromWire) }.getOrElse { return null }
    val remoteStart = payload.opt("remoteStart") as? Boolean ?: return null
    val checkedAt = jsonInteger(payload.opt("checkedAt"))?.takeIf { it in 0..MAX_SAFE_INTEGER } ?: return null
    return UpdateStatus(platform, edition, app, build, channel, state, target, targetBuild, progress, reason, remoteStart, checkedAt)
}

/** An updates.status plaintext as it arrives: at most 1,024 bytes of strict JSON. Null when malformed. */
fun decodeUpdateStatus(plaintext: ByteArray): UpdateStatus? =
    plaintext.takeIf { it.size <= UPDATES_STATUS_MAX_BYTES }?.let(::strictJsonObject)?.let(::parseUpdateStatus)

fun updateStatusPayload(status: UpdateStatus): JSONObject = JSONObject().apply {
    put("version", 1)
    put("platform", status.platform.wire)
    put("edition", status.edition)
    put("app", status.app)
    put("build", status.build)
    put("channel", status.channel.wire)
    put("state", status.state.wire)
    status.target?.let { put("target", it) }
    status.targetBuild?.let { put("targetBuild", it) }
    status.progress?.let { put("progress", it) }
    status.reason?.let { put("reason", it.wire) }
    put("remoteStart", status.remoteStart)
    put("checkedAt", status.checkedAt)
}

fun parseUpdateStart(payload: JSONObject): UpdateStart? {
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val requestId = wireUuid(payload.opt("requestId")) ?: return null
    val retry = optional(payload, "retry") { it as? Boolean }.getOrElse { return null } ?: false
    return UpdateStart(requestId, retry)
}

/** An updates.start plaintext: at most 512 bytes of strict JSON. Null when malformed (dropped, no answer). */
fun decodeUpdateStart(plaintext: ByteArray): UpdateStart? =
    plaintext.takeIf { it.size <= UPDATES_START_MAX_BYTES }?.let(::strictJsonObject)?.let(::parseUpdateStart)

/** `retry` is written only when true. */
fun updateStartPayload(start: UpdateStart): JSONObject = JSONObject().apply {
    put("version", 1)
    put("requestId", start.requestId)
    if (start.retry) put("retry", true)
}

fun parseUpdateResult(payload: JSONObject): UpdateResult? {
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val requestId = wireUuid(payload.opt("requestId")) ?: return null
    val status = when (payload.opt("status")) {
        "accepted" -> UpdateResultStatus.ACCEPTED
        "refused" -> UpdateResultStatus.REFUSED
        else -> return null
    }
    val reason = if (status == UpdateResultStatus.REFUSED) UpdateRefusal.fromWire(payload.opt("reason") as? String) else null
    return UpdateResult(requestId, status, reason)
}

fun decodeUpdateResult(plaintext: ByteArray): UpdateResult? =
    plaintext.takeIf { it.size <= UPDATES_RESULT_MAX_BYTES }?.let(::strictJsonObject)?.let(::parseUpdateResult)

fun updateResultPayload(result: UpdateResult): JSONObject = JSONObject().apply {
    put("version", 1)
    put("requestId", result.requestId)
    put("status", result.status.wire)
    if (result.status == UpdateResultStatus.REFUSED) put("reason", (result.reason ?: UpdateRefusal.OTHER).wire)
}
