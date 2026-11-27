package dev.bridgey.android.stress

import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.StatFs
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingState
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Stress builds only (the `stress` build type; scripts/rr/stress-android.sh, docs/testing-stress.md). A test runner's
 * commands, sent with
 *
 *     adb shell am broadcast -n <app id>/dev.bridgey.android.stress.StressControlReceiver --es cmd <command> ...
 *
 * and answered as JSON in the broadcast's result data. The manifest makes senders hold DUMP, so only the shell can
 * send them. Commands act through the same coordinator calls the UI makes:
 *
 * - `files-on`: File transfer on for every device, as setup's Files choice (a new install starts with it off).
 * - `allow`: Allow pairing (two minutes). `confirm`: Codes match on the pairing prompt showing now.
 * - `send` with `--esa specs name:size:seed,...`: writes each file (the deterministic bytes in [StressBytes]) to
 *   Download/BridgeyStress/ once, then sends them all, in order, to the connected device.
 * - `cancel`: Cancel on every transfer, as the Transfers screen's Cancel all.
 * - `hash` with `--esa names a,b`: SHA-256 of received files in Download/Bridgey/, in the background; see `status`.
 * - `clean`: deletes this app's `stress-*` files in Download/Bridgey/ (pending ones too) and Download/BridgeyStress/.
 * - `status`: connections, the pairing prompt, transfers, received files (pending ones are partials), hashes,
 *   files still being written, free space and errors.
 * - `display-on`: See Mac screens on, for every Mac (fresh installs start with it off).
 * - `display-open`: opens the viewer for the first connected Mac that allows it (Bridgey must be in front, as for any
 *   activity start); `--es device <id>` picks one.
 * - `display-control` with `--es state on|off`: Control on or off in the running viewer, as its button does.
 * - `display-status`: the viewer: phase, Mac name, geometry, control, decoded frames a second, decode time, frames
 *   lost, and the Mac's latest stats.
 * - `screen-on`: Share screen with Macs on, for every Mac (fresh installs start with it off).
 * - `control-grant` with `--es mode off|ask|always`: the phone control grant for every paired Mac, as Settings sets it.
 * - `control-answer` with `--es state allow|deny`: answers the prompt showing now, as its buttons do.
 * - `control-stop`: Stop on the indicator.
 * - `control-status`: phone control: phase, geometry, display size, inputs accepted and rejected, gestures, latency
 *   from arrival to dispatch and to completion, and whether Bridgey control is on and connected.
 * - The upgrade acceptance and soak commands in [AcceptanceControl] (clipboard, process figures, storage snapshot).
 */
class StressControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? BridgeyApplication
        val answer = if (app == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            JSONObject().put("ok", false).put("error", "needs the app and Android 11 or later")
        } else {
            runCatching { StressControl.handle(app, intent) }.getOrElse { JSONObject().put("ok", false).put("error", it.toString()) }
        }
        resultCode = 0
        resultData = answer.toString()
    }
}

@RequiresApi(Build.VERSION_CODES.R)
internal object StressControl {
    private const val RECEIVED = "Download/Bridgey/"
    private const val SOURCES = "Download/BridgeyStress/"
    private const val PREFIX = "stress-"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val writing = AtomicInteger(0)
    private val hashes = ConcurrentHashMap<String, JSONObject>()
    private val errors = ConcurrentLinkedQueue<String>()

    fun handle(app: BridgeyApplication, intent: Intent): JSONObject {
        val pairing = app.pairing
        return when (intent.getStringExtra("cmd")) {
            "files-on" -> ok().also { app.settings.setGlobal(BridgeyFeature.FILES, true) }
            "allow" -> ok().also { pairing.armPairing() }
            "confirm" -> {
                val state = pairing.pairingFlow.value
                if (state is PairingState.Verification && !state.localConfirmed) pairing.confirm(state.token)
                ok().put("pairing", state.javaClass.simpleName)
            }
            "send" -> send(app, intent.getStringArrayExtra("specs").orEmpty().toList())
            "cancel" -> ok().also { pairing.cancelFileTransfer() }
            "hash" -> hash(app.contentResolver, intent.getStringArrayExtra("names").orEmpty().toList())
            "clean" -> clean(app.contentResolver)
            "status" -> status(app)
            "display-on" -> ok().also {
                app.settings.setGlobal(BridgeyFeature.SCREEN_CONTROL, true)
                app.pairing.trustedDeviceIds.value.forEach { id -> app.settings.setForDevice(id, BridgeyFeature.SCREEN_CONTROL, true) }
            }
            "display-open" -> {
                val targets = app.pairing.displayTargets()
                val wanted = intent.getStringExtra("device")
                val target = targets.firstOrNull { wanted == null || it.first == wanted }
                if (target == null) {
                    JSONObject().put("ok", false).put("error", "no Mac allows it").put("targets", targets.size)
                } else {
                    dev.bridgey.android.display.MacScreenActivity.open(app, target.first, target.second)
                    ok().put("device", target.first.take(8)).put("mac", target.second)
                }
            }
            "display-control" -> ok().also {
                if (intent.getStringExtra("state") == "off") app.display.endControl() else app.display.beginControl()
            }
            "display-status" -> displayStatus(app)
            "screen-on" -> ok().also {
                app.settings.setGlobal(BridgeyFeature.SCREEN, true)
                app.pairing.trustedDeviceIds.value.forEach { id -> app.settings.setForDevice(id, BridgeyFeature.SCREEN, true) }
            }
            "control-grant" -> {
                val hub = app.phoneControlOrNull ?: return JSONObject().put("ok", false).put("error", "not in this build")
                val mode = dev.bridgey.android.control.PhoneControlGrantMode.fromWire(intent.getStringExtra("mode"))
                    ?: return JSONObject().put("ok", false).put("error", "mode is off, ask or always")
                val set = app.pairing.trustedDeviceIds.value.filterNot(app.pairing::isAgent).map { id -> hub.setGrant(id, mode) }
                ok().put("set", set.count { it }).put("refused", set.count { !it })
            }
            "control-answer" -> {
                val hub = app.phoneControlOrNull ?: return JSONObject().put("ok", false).put("error", "not in this build")
                hub.answerPending(intent.getStringExtra("state") == "allow")
                ok()
            }
            "control-stop" -> ok().also { app.phoneControlOrNull?.stopLocally() }
            "control-status" -> {
                val hub = app.phoneControlOrNull ?: return JSONObject().put("ok", false).put("error", "not in this build")
                val latch = java.util.concurrent.CountDownLatch(1)
                var stats = JSONObject()
                hub.stats { stats = it; latch.countDown() }
                latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
                ok().put("control", stats).put("state", hub.state.value.phase.name.lowercase())
            }
            else -> AcceptanceControl.handle(app, intent) ?: JSONObject().put("ok", false).put("error", "unknown command")
        }
    }

    private fun ok() = JSONObject().put("ok", true)

    private fun displayStatus(app: BridgeyApplication): JSONObject {
        val view = app.display.state.value
        val stats = view.stats
        return ok()
            .put("phase", view.phase.name.lowercase())
            .put("mac", view.macName)
            .put("display", view.displayName ?: JSONObject.NULL)
            .put("geometry", view.geometry?.let { JSONObject().put("generation", it.generation).put("width", it.width).put("height", it.height) } ?: JSONObject.NULL)
            .put("controlAllowed", view.controlAllowed)
            .put("control", view.control.name.lowercase())
            .put("input", JSONObject().put("pointer", view.input.pointer).put("keys", view.input.keys).put("text", view.input.text))
            .put("decodedFps", view.decodedFps)
            .put("decodeMsAverage", view.decodeMsAverage)
            .put("decodeMsMax", view.decodeMsMax)
            .put("lostFrames", view.lostFrames)
            .put("outcome", view.outcome?.toString() ?: JSONObject.NULL)
            .put("controlNote", view.controlNote?.wire ?: JSONObject.NULL)
            .put(
                "stats",
                stats?.let {
                    JSONObject().put("latencyMs", it.latencyMs).put("rttMs", it.rttMs).put("bitrate", it.bitrate)
                        .put("sentBitrate", it.sentBitrate).put("fps", it.fps).put("dropped", it.dropped)
                } ?: JSONObject.NULL,
            )
    }

    private fun send(app: BridgeyApplication, specs: List<String>): JSONObject {
        val target = app.pairing.connections.value.firstOrNull()?.deviceId ?: return JSONObject().put("ok", false).put("error", "not connected")
        val files = specs.map { spec ->
            val parts = spec.split(':')
            require(parts.size == 3 && parts[0].startsWith(PREFIX) && !parts[0].contains('/')) { "bad spec $spec" }
            Triple(parts[0], parts[1].toLong(), parts[2].toLong())
        }
        writing.incrementAndGet()
        scope.launch {
            try {
                val uris = files.map { (name, size, seed) -> source(app.contentResolver, name, size, seed) }
                withContext(Dispatchers.Main) { app.pairing.sendFiles(uris, target) }
            } catch (error: Exception) {
                errors.add("send: $error")
            } finally {
                writing.decrementAndGet()
            }
        }
        return ok().put("files", files.size)
    }

    /** The source file in Download/BridgeyStress/: kept from an earlier send when its size matches, else written now. */
    private fun source(resolver: ContentResolver, name: String, size: Long, seed: Long): Uri {
        val existing = entries(resolver, SOURCES).filter { it.name == name }
        existing.firstOrNull { !it.pending && it.size == size }?.let { return it.uri }
        existing.forEach { resolver.delete(it.uri, null, null) }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
            put(MediaStore.MediaColumns.RELATIVE_PATH, SOURCES)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = requireNotNull(resolver.insert(downloads(), values)) { "insert $name" }
        requireNotNull(resolver.openOutputStream(uri, "w")) { "open $name" }.use { out ->
            val bytes = StressBytes(seed)
            val buffer = ByteArray(1 shl 20)
            var left = size
            while (left > 0) {
                val n = minOf(left, buffer.size.toLong()).toInt()
                bytes.fill(buffer, n)
                out.write(buffer, 0, n)
                left -= n
            }
        }
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        return uri
    }

    private fun hash(resolver: ContentResolver, names: List<String>): JSONObject {
        for (name in names) {
            hashes[name] = JSONObject().put("state", "running")
            scope.launch {
                val entry = entries(resolver, RECEIVED).firstOrNull { it.name == name && !it.pending }
                hashes[name] = if (entry == null) {
                    JSONObject().put("state", "missing")
                } else {
                    runCatching {
                        val digest = MessageDigest.getInstance("SHA-256")
                        var total = 0L
                        requireNotNull(resolver.openInputStream(entry.uri)).use { input ->
                            val buffer = ByteArray(1 shl 20)
                            while (true) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                digest.update(buffer, 0, n)
                                total += n
                            }
                        }
                        JSONObject().put("state", "done").put("size", total).put("sha256", digest.digest().joinToString("") { "%02x".format(it) })
                    }.getOrElse { JSONObject().put("state", "failed").put("error", it.toString()) }
                }
            }
        }
        return ok().put("files", names.size)
    }

    private fun clean(resolver: ContentResolver): JSONObject {
        var deleted = 0
        for (entry in entries(resolver, RECEIVED).filter { it.name.startsWith(PREFIX) } + entries(resolver, SOURCES)) {
            deleted += runCatching { resolver.delete(entry.uri, null, null) }.getOrDefault(0)
        }
        hashes.clear()
        errors.clear()
        return ok().put("deleted", deleted)
    }

    private fun status(app: BridgeyApplication): JSONObject {
        val pairing = app.pairing
        val connections = JSONArray()
        pairing.connections.value.forEach { connections.put(JSONObject().put("id", it.deviceId).put("name", it.peerName)) }
        val transfers = JSONArray()
        pairing.fileTransfers.value.values.sortedBy { it.startedAtMillis }.forEach {
            transfers.put(
                JSONObject().put("id", it.id).put("name", it.name).put("status", it.status).put("active", it.active)
                    .put("queued", it.queued).put("percent", it.progressPercent ?: -1).put("outcome", it.outcome?.name ?: "")
                    .put("kind", it.kind.name),
            )
        }
        val received = JSONArray()
        entries(app.contentResolver, RECEIVED).filter { it.name.startsWith(PREFIX) }.forEach {
            received.put(JSONObject().put("name", it.name).put("size", it.size).put("pending", it.pending))
        }
        return ok()
            .put("pid", Process.myPid())
            .put("pairing", pairing.pairingFlow.value.javaClass.simpleName)
            .put("connections", connections)
            .put("transfers", transfers)
            .put("received", received)
            .put("hashes", JSONObject(hashes.toMap()))
            .put("writing", writing.get())
            .put("freeBytes", StatFs(app.filesDir.path).availableBytes)
            .put("errors", JSONArray(errors.toList()))
    }

    private data class Entry(val uri: Uri, val name: String, val size: Long, val pending: Boolean)

    private fun downloads(): Uri = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    /** This app's own entries directly in [relativePath], pending ones included. */
    private fun entries(resolver: ContentResolver, relativePath: String): List<Entry> {
        val args = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.MediaColumns.RELATIVE_PATH}=?")
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(relativePath))
            putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
        }
        val projection = arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.IS_PENDING,
        )
        val found = mutableListOf<Entry>()
        resolver.query(downloads(), projection, args, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                found += Entry(Uri.withAppendedPath(downloads(), id.toString()), cursor.getString(1).orEmpty(), cursor.getLong(2), cursor.getInt(3) == 1)
            }
        }
        return found
    }
}

/**
 * The stress harness's file bytes: SplitMix64 from the seed, each word little-endian, the last one cut short. The scripted
 * peer (rust/client/examples/stress.rs, `Gen`) makes the same bytes, so either end knows a file's SHA-256 without it.
 */
internal class StressBytes(private var state: Long) {
    private fun next(): Long {
        state += GOLDEN
        var z = state
        z = (z xor (z ushr 30)) * MIX1
        z = (z xor (z ushr 27)) * MIX2
        return z xor (z ushr 31)
    }

    /** Fills [buffer] up to [length]; every call but the last must ask for a whole number of words. */
    fun fill(buffer: ByteArray, length: Int) {
        var i = 0
        while (i < length) {
            var word = next()
            val n = minOf(8, length - i)
            for (k in 0 until n) {
                buffer[i + k] = word.toByte()
                word = word ushr 8
            }
            i += 8
        }
    }

    private companion object {
        const val GOLDEN = -0x61c8864680b583ebL // 0x9E3779B97F4A7C15
        const val MIX1 = -0x40a7b892e31b1a47L // 0xBF58476D1CE4E5B9
        const val MIX2 = -0x6b2fb644ecceee15L // 0x94D049BB133111EB
    }
}
