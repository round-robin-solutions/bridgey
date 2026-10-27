package dev.bridgey.android.camera

import java.util.UUID
import org.json.JSONObject

/** Draft, edition only (docs/protocol.md, "Phone camera to Mac"): same key as BridgeyFeature.CAMERA. */
const val CAMERA_FEATURE_KEY = "camera_draft1"

/** camera.request and camera.status plaintext limit. */
const val CAMERA_MESSAGE_MAX_BYTES = 512

/** At most one request from a Mac every 3 seconds. */
const val CAMERA_REQUEST_SPACING_MILLIS = 3_000L

/** An open request expires after 2 minutes. */
const val CAMERA_REQUEST_LIFETIME_MILLIS = 120_000L

/** camera.status values. */
enum class CameraStatus(val wire: String) {
    OPENED("opened"),
    LOCKED("locked"),
    PERMISSION_REQUIRED("permission_required"),
    CANCELLED("cancelled"),
    BUSY("busy"),
    DISABLED("disabled"),
    SENDING("sending"),
    FAILED("failed"),
}

/** One open request: which Mac asked, and when. */
data class CameraRequest(val deviceId: String, val macName: String, val requestId: String, val receivedAtMillis: Long) {
    fun expired(now: Long): Boolean = now - receivedAtMillis >= CAMERA_REQUEST_LIFETIME_MILLIS
}

/** What to do with a camera.request. */
sealed interface CameraDecision {
    /** Malformed: no answer (there is no valid request ID to answer). */
    data object Drop : CameraDecision

    /** Answer with this status and do nothing else. */
    data class Refuse(val requestId: String, val status: CameraStatus) : CameraDecision

    /** Show the camera (or the notification that leads to it). */
    data class Accept(val request: CameraRequest) : CameraDecision
}

/** The request ID of a well-formed camera.request (`version` 1, UUID `requestId`, `mode` photo), else null. */
fun parseCameraRequest(payload: JSONObject): String? {
    if (payload.opt("version") != 1 || payload.opt("mode") != "photo") return null
    val id = payload.opt("requestId") as? String ?: return null
    return id.takeIf { runCatching { UUID.fromString(it) }.isSuccess && it.length == 36 }?.lowercase()
}

fun cameraStatusPayload(requestId: String, status: CameraStatus): JSONObject =
    JSONObject().put("version", 1).put("requestId", requestId).put("status", status.wire)

/**
 * Open camera requests, one per Mac at most. A Mac asking again while its request is open, or
 * within 3 seconds of its last request, is answered `busy`; with the switch off, `disabled`.
 */
class CameraRequests(private val clock: () -> Long) {
    private val open = mutableMapOf<String, CameraRequest>()
    private val lastRequestAt = mutableMapOf<String, Long>()

    @Synchronized fun receive(deviceId: String, macName: String, payload: JSONObject, enabled: Boolean): CameraDecision {
        val requestId = parseCameraRequest(payload) ?: return CameraDecision.Drop
        if (!enabled) return CameraDecision.Refuse(requestId, CameraStatus.DISABLED)
        val now = clock()
        open[deviceId]?.takeIf { it.expired(now) }?.let { open.remove(deviceId) }
        val last = lastRequestAt[deviceId]
        lastRequestAt[deviceId] = now
        if (last != null && now - last < CAMERA_REQUEST_SPACING_MILLIS) return CameraDecision.Refuse(requestId, CameraStatus.BUSY)
        if (open.containsKey(deviceId)) return CameraDecision.Refuse(requestId, CameraStatus.BUSY)
        val request = CameraRequest(deviceId, macName.take(64), requestId, now)
        open[deviceId] = request
        return CameraDecision.Accept(request)
    }

    /** The request, if it is still open and not expired. */
    @Synchronized fun current(deviceId: String, requestId: String): CameraRequest? {
        val request = open[deviceId]?.takeIf { it.requestId == requestId } ?: return null
        if (request.expired(clock())) {
            open.remove(deviceId)
            return null
        }
        return request
    }

    /** The request is over (sent, cancelled, failed or expired). True if it was open. */
    @Synchronized fun finish(deviceId: String, requestId: String): Boolean {
        if (open[deviceId]?.requestId != requestId) return false
        open.remove(deviceId)
        return true
    }

    /** The Mac disconnected or turned the feature off: its request ends. */
    @Synchronized fun ended(deviceId: String): CameraRequest? = open.remove(deviceId)
}

/**
 * Where a request goes: a locked phone shows "Unlock your phone to take the photo"; an unlocked
 * phone with Bridgey on screen opens the camera; otherwise a notification asks for a tap.
 */
enum class CameraRoute { LOCKED_NOTIFICATION, OPEN_NOW, NOTIFICATION }

fun cameraRoute(locked: Boolean, appInForeground: Boolean): CameraRoute = when {
    locked -> CameraRoute.LOCKED_NOTIFICATION
    appInForeground -> CameraRoute.OPEN_NOW
    else -> CameraRoute.NOTIFICATION
}
