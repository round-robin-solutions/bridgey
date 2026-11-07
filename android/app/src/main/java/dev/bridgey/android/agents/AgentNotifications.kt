package dev.bridgey.android.agents

import org.json.JSONArray
import org.json.JSONObject

/** Ephemeral text from an active phone notification. No action, intent, icon or private history. */
data class AgentNotification(
    val id: String,
    val packageName: String,
    val applicationName: String,
    val title: String,
    val text: String,
    val postedAt: Long,
)

data class AgentNotificationsSnapshot(
    val available: Boolean,
    val notifications: List<AgentNotification> = emptyList(),
    val truncated: Boolean = false,
)

const val AGENT_NOTIFICATIONS_MAX_BYTES = 24 * 1_024

/** Fits the encrypted 65 KiB envelope even with Unicode and JSON escaping. */
fun agentNotificationsResultPayload(queryId: String, snapshot: AgentNotificationsSnapshot, limit: Int): ByteArray {
    val items = JSONArray()
    val payload = JSONObject().put("version", 1).put("queryId", queryId)
        .put("status", if (snapshot.available) "ok" else "unavailable")
        .put("notifications", items).put("truncated", snapshot.truncated)
    var truncated = snapshot.truncated
    if (snapshot.available) {
        for (item in snapshot.notifications.take(limit.coerceIn(1, 20))) {
            val entry = JSONObject().put("id", cleanAgentText(item.id).take(128))
                .put("packageName", cleanAgentText(item.packageName).take(256))
                .put("applicationName", cleanAgentText(item.applicationName).take(128))
                .put("title", cleanAgentText(item.title).take(512))
                .put("text", cleanAgentText(item.text, keepLines = true).take(2_048))
                .put("postedAt", item.postedAt)
            items.put(entry)
            if (payload.toString().toByteArray(Charsets.UTF_8).size > AGENT_NOTIFICATIONS_MAX_BYTES - 32) {
                items.remove(items.length() - 1)
                truncated = true
                break
            }
        }
        if (items.length() < snapshot.notifications.size) truncated = true
    }
    payload.put("truncated", truncated)
    return payload.toString().toByteArray(Charsets.UTF_8)
}
