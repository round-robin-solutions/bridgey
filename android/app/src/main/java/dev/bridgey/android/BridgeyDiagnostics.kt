package dev.bridgey.android

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal data class DiagnosticEvent(
    val timestamp: String,
    val category: String,
    val event: String,
    val outcome: String,
    /** The first eight characters of the device id, for connection events. */
    val device: String? = null,
    /** A short normalized detail: an attempt number, an address source, power state. */
    val detail: String? = null,
)

/**
 * A bounded log of what happened, for the exported report. Only normalized tokens are stored:
 * never names, clipboard or notification text, file names or network addresses. With a [file]
 * the events survive the app being killed overnight, so the next morning's report still shows
 * the drops and retries.
 */
internal class BridgeyDiagnostics(
    private val limit: Int = 200,
    private val file: File? = null,
    /** Settings > Privacy > Logging: a category that is off never reaches the report. */
    private val allows: (category: String) -> Boolean = BridgeyLogging::allowsDiagnostic,
) {
    private val events = ArrayDeque<DiagnosticEvent>()
    private val writer = file?.let { Executors.newSingleThreadScheduledExecutor { Thread(it, "bridgey-diagnostics").apply { isDaemon = true } } }
    private var saveScheduled = false

    init {
        file?.let { source -> runCatching { load(source) } }
    }

    @Synchronized fun record(category: String, event: String, outcome: String = "ok", device: String? = null, detail: String? = null) {
        if (!allows(category)) return
        events.addLast(
            DiagnosticEvent(
                Instant.now().toString(),
                token(category),
                token(event),
                token(outcome),
                device?.let { token(it.take(8)) },
                detail?.let(::token),
            ),
        )
        while (events.size > limit) events.removeFirst()
        scheduleSave()
    }

    @Synchronized fun snapshot(): List<DiagnosticEvent> = events.toList()

    /** Clear logs: drops every recorded event, on disk too. */
    @Synchronized fun clear() {
        events.clear()
        scheduleSave()
    }

    fun report(
        context: Context,
        connectionState: String,
        transfers: Collection<FileTransferState>,
        localFeatures: Map<BridgeyFeature, Boolean>,
        remoteFeatures: Map<BridgeyFeature, Boolean>,
        devices: JSONArray = JSONArray(),
        power: String? = null,
    ): String {
        val version = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        }.getOrNull() ?: "unknown"
        return JSONObject().apply {
            put("schemaVersion", 2)
            put("generatedAt", Instant.now().toString())
            put("appVersion", version)
            put("platform", "android")
            put("osApi", Build.VERSION.SDK_INT)
            put("connectionState", token(connectionState))
            put("activeTransferCount", transfers.count(FileTransferState::active))
            put("historyCount", transfers.count { !it.active })
            put("localFeatures", featureObject(localFeatures))
            put("remoteFeatures", featureObject(remoteFeatures))
            power?.let { put("power", token(it)) }
            put("devices", devices)
            put("events", JSONArray().apply { snapshot().forEach { put(it.toJson()) } })
        }.toString(2)
    }

    private fun DiagnosticEvent.toJson() = JSONObject().apply {
        put("timestamp", timestamp)
        put("category", category)
        put("event", event)
        put("outcome", outcome)
        device?.let { put("device", it) }
        detail?.let { put("detail", it) }
    }

    /** Writes at most every two seconds, on its own thread. */
    private fun scheduleSave() {
        val target = file ?: return
        if (saveScheduled) return
        saveScheduled = true
        writer?.schedule({
            val text = synchronized(this) {
                saveScheduled = false
                JSONArray().apply { events.forEach { put(it.toJson()) } }.toString()
            }
            runCatching {
                target.parentFile?.mkdirs()
                val temporary = File(target.parentFile, "${target.name}.tmp")
                temporary.writeText(text, Charsets.UTF_8)
                temporary.renameTo(target)
            }
        }, 2, TimeUnit.SECONDS)
    }

    private fun load(source: File) {
        if (!source.exists()) return
        val array = JSONArray(source.readText(Charsets.UTF_8))
        for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            events.addLast(
                DiagnosticEvent(
                    item.optString("timestamp"),
                    item.optString("category"),
                    item.optString("event"),
                    item.optString("outcome"),
                    item.optString("device").takeIf(String::isNotEmpty),
                    item.optString("detail").takeIf(String::isNotEmpty),
                ),
            )
        }
        while (events.size > limit) events.removeFirst()
    }

    private fun featureObject(features: Map<BridgeyFeature, Boolean>) = JSONObject().apply {
        BridgeyFeature.entries.forEach { put(it.key, features[it] != false) }
    }

    fun token(value: String): String = value.lowercase()
        .replace(Regex("[^a-z0-9_.-]"), "_")
        .take(64)
}
