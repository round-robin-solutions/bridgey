package dev.bridgey.android.stress

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Debug
import android.os.Process
import androidx.annotation.RequiresApi
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingCoordinator
import dev.bridgey.android.PeerActivity
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray
import org.json.JSONObject

/**
 * Stress builds only: the upgrade acceptance and soak commands (docs/acceptance-1.0.md), reached through
 * [StressControlReceiver] like the stress commands. They read and write this app's own storage and process, never
 * another app's:
 *
 * - `clipboard-on`: Clipboard on for every paired device (a new install starts with it off).
 * - `clipboard-send` with `--es text <text>`: sends that text to the connected device, as Send clipboard does; the
 *   result lands in `clipboard-status`.
 * - `clipboard-status`: the sends' results, the newest text that came in and how many came in since these commands were
 *   first used in this process (counted where the activity stream hears of them).
 * - `proc` (`--ez gc true` collects garbage first): this process's resident memory, threads, open files and heaps.
 * - `snapshot`: every SharedPreferences file (values of keys that may hold secrets as SHA-256), the private files the
 *   upgrade policy lists (hashes, sizes and their records), the version and install times, and what the app itself
 *   reads back: trusted devices, per-device switches, phone control grants and Unattended access.
 * - `pref-set` with `--es file <name> --es key <key> --es type boolean|int|long|float|string --es value <value>`: one
 *   preference, as the app stores it. Restart the app afterwards so it reads it (`kill`, `start`).
 * - `control-unattended` with `--es state on|off`: Settings > Remote control > Unattended access.
 */
@RequiresApi(Build.VERSION_CODES.R)
internal object AcceptanceControl {
    private val clipboardResults = ConcurrentLinkedQueue<String>()
    @Volatile private var hooked: PairingCoordinator? = null
    @Volatile private var lastReceived: String? = null
    private val receivedCount = AtomicInteger(0)

    /** Hears received texts beside the activity stream (which keeps a short preview only), once per process. */
    private fun hook(app: BridgeyApplication) {
        val pairing = app.pairing
        if (hooked === pairing) return
        synchronized(this) {
            if (hooked === pairing) return
            val previous = pairing.activityListener
            pairing.activityListener = { event ->
                if (event.activity == PeerActivity.CLIPBOARD_RECEIVED) {
                    lastReceived = event.clipboardText
                    receivedCount.incrementAndGet()
                }
                previous?.invoke(event)
            }
            hooked = pairing
        }
    }

    /** Private files the upgrade policy names (docs/upgrade-policy.md), read for the snapshot. */
    private val PRIVATE_FILES = listOf(
        "activity-stream.json", "file-resume.json", "phone-control-grants.json", "document-index.json", "diagnostics.json",
    )
    private val PRIVATE_FOLDERS = listOf("folder-transfers", "folder-sends", "clipboard-cache")

    /** Preference files whose string values may be credentials: compared by hash only. */
    private val SECRET_FILES = setOf("bridgey.connect", "bridgey.agents", "bridgey.agents.grants", "bridgey_codes")
    private val SECRET_KEY = Regex("token|secret|password|credential|private", RegexOption.IGNORE_CASE)

    fun handle(app: BridgeyApplication, intent: Intent): JSONObject? = when (intent.getStringExtra("cmd")) {
        "clipboard-on" -> ok().also {
            hook(app)
            app.settings.setGlobal(BridgeyFeature.CLIPBOARD, true)
            app.pairing.trustedDeviceIds.value.forEach { id -> app.settings.setForDevice(id, BridgeyFeature.CLIPBOARD, true) }
        }
        "clipboard-send" -> {
            val text = intent.getStringExtra("text").orEmpty()
            app.pairing.sendText(text) { result -> clipboardResults.add(result.name) }
            ok()
        }
        "clipboard-status" -> ok().also { hook(app) }
            .put("results", JSONArray(clipboardResults.toList().takeLast(20)))
            .put("text", lastReceived ?: JSONObject.NULL)
            .put("received", receivedCount.get())
        "proc" -> proc(intent.getBooleanExtra("gc", false))
        "snapshot" -> snapshot(app)
        "pref-set" -> prefSet(app, intent)
        "control-unattended" -> {
            val hub = app.phoneControlOrNull ?: return JSONObject().put("ok", false).put("error", "not in this build")
            ok().put("set", hub.setUnattended(intent.getStringExtra("state") == "on"))
        }
        else -> null
    }

    private fun ok() = JSONObject().put("ok", true)

    private fun proc(gc: Boolean): JSONObject {
        if (gc) {
            Runtime.getRuntime().gc()
            Runtime.getRuntime().runFinalization()
            Runtime.getRuntime().gc()
        }
        val status = runCatching { File("/proc/self/status").readLines() }.getOrDefault(emptyList())
        fun field(name: String): Long =
            status.firstOrNull { it.startsWith("$name:") }?.substringAfter(':')?.trim()?.split(' ')?.firstOrNull()?.toLongOrNull() ?: -1
        val runtime = Runtime.getRuntime()
        return ok()
            .put("pid", Process.myPid())
            .put("rssKb", field("VmRSS"))
            .put("hwmKb", field("VmHWM"))
            .put("threads", field("Threads"))
            .put("fds", File("/proc/self/fd").list()?.size ?: -1)
            .put("javaUsed", runtime.totalMemory() - runtime.freeMemory())
            .put("javaTotal", runtime.totalMemory())
            .put("javaMax", runtime.maxMemory())
            .put("nativeAllocated", Debug.getNativeHeapAllocatedSize())
            .put("cpuMs", Process.getElapsedCpuTime())
            .put("gc", gc)
            .put("uptimeMs", android.os.SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun prefValue(file: String, key: String, value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Boolean, is Int, is Long, is Float -> value
        is Set<*> -> JSONArray(value.map { it.toString() }.sorted())
        else -> {
            val text = value.toString()
            if (file in SECRET_FILES || SECRET_KEY.containsMatchIn(key)) "sha256:" + sha256(text.toByteArray()) else text
        }
    }

    private fun snapshot(app: BridgeyApplication): JSONObject {
        val prefs = JSONObject()
        val prefsDir = File(app.applicationInfo.dataDir, "shared_prefs")
        prefsDir.listFiles { f -> f.name.endsWith(".xml") }.orEmpty().sortedBy { it.name }.forEach { f ->
            val name = f.name.removeSuffix(".xml")
            val values = JSONObject()
            app.getSharedPreferences(name, Context.MODE_PRIVATE).all.toSortedMap().forEach { (key, value) ->
                values.put(key, JSONObject().put("type", value?.javaClass?.simpleName ?: "null").put("value", prefValue(name, key, value)))
            }
            prefs.put(name, values)
        }
        val files = JSONObject()
        val noBackup = app.noBackupFilesDir
        for (name in PRIVATE_FILES) {
            val f = File(noBackup, name)
            if (!f.isFile) continue
            val bytes = f.readBytes()
            val entry = JSONObject().put("size", bytes.size).put("sha256", sha256(bytes))
            when (name) {
                "activity-stream.json" -> entry.put("items", runCatching { activityItems(JSONArray(String(bytes))) }.getOrElse { JSONArray().put(it.toString()) })
                "file-resume.json" -> entry.put("records", runCatching { resumeRecords(JSONObject(String(bytes))) }.getOrElse { JSONArray().put(it.toString()) })
                "phone-control-grants.json" -> entry.put("grants", runCatching { JSONObject(String(bytes)) }.getOrElse { JSONObject().put("error", it.toString()) })
            }
            files.put(name, entry)
        }
        for (folder in PRIVATE_FOLDERS) {
            val dir = File(noBackup, folder)
            if (dir.isDirectory) files.put("$folder/", JSONArray(dir.walkTopDown().filter { it.isFile }.map { it.relativeTo(dir).path }.sorted().toList()))
        }
        val pairing = app.pairing
        val trusted = JSONArray()
        val hub = app.phoneControlOrNull
        for (id in pairing.trustedDeviceIds.value.sorted()) {
            val switches = JSONObject()
            for (feature in BridgeyFeature.entries) switches.put(feature.key, app.settings.isEnabled(feature, id))
            trusted.put(
                JSONObject().put("id", id).put("agent", pairing.isAgent(id)).put("features", switches)
                    .put("controlMode", hub?.mode(id)?.wire ?: JSONObject.NULL)
                    .put("controlChoice", hub?.let { it.choice(id)?.wire ?: "default" } ?: JSONObject.NULL),
            )
        }
        val info = app.packageManager.getPackageInfo(app.packageName, 0)
        return ok()
            .put("package", app.packageName)
            .put("versionName", info.versionName)
            .put("versionCode", info.longVersionCode)
            .put("firstInstallTime", info.firstInstallTime)
            .put("lastUpdateTime", info.lastUpdateTime)
            .put("pid", Process.myPid())
            .put("prefs", prefs)
            .put("files", files)
            .put("trusted", trusted)
            .put("unattended", hub?.unattended ?: JSONObject.NULL)
            .put("connections", JSONArray(pairing.connections.value.map { it.deviceId }))
    }

    private fun activityItems(array: JSONArray): JSONArray {
        val out = JSONArray()
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            out.put(JSONObject().put("id", item.opt("id")).put("kind", item.opt("kind")).put("count", item.opt("count")).put("at", item.opt("at")))
        }
        return out
    }

    private fun resumeRecords(json: JSONObject): JSONArray {
        val out = JSONArray()
        val records = json.optJSONArray("records") ?: return out
        for (i in 0 until records.length()) {
            val r = records.optJSONObject(i) ?: continue
            // The record's own fields, without the part file's location.
            val copy = JSONObject()
            r.keys().forEach { k -> if (k != "path" && k != "partPath" && k != "uri") copy.put(k, r.opt(k)) }
            out.put(copy)
        }
        return out
    }

    private fun prefSet(app: BridgeyApplication, intent: Intent): JSONObject {
        val file = intent.getStringExtra("file") ?: return JSONObject().put("ok", false).put("error", "file")
        val key = intent.getStringExtra("key") ?: return JSONObject().put("ok", false).put("error", "key")
        val value = intent.getStringExtra("value") ?: return JSONObject().put("ok", false).put("error", "value")
        val editor = app.getSharedPreferences(file, Context.MODE_PRIVATE).edit()
        when (intent.getStringExtra("type")) {
            "boolean" -> editor.putBoolean(key, value.toBooleanStrict())
            "int" -> editor.putInt(key, value.toInt())
            "long" -> editor.putLong(key, value.toLong())
            "float" -> editor.putFloat(key, value.toFloat())
            "string" -> editor.putString(key, value)
            else -> return JSONObject().put("ok", false).put("error", "type is boolean, int, long, float or string")
        }
        return ok().put("written", editor.commit())
    }
}
