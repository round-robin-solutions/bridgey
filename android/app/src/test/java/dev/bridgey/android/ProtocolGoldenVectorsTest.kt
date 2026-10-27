package dev.bridgey.android

import dev.bridgey.android.browse.BrowseRefs
import dev.bridgey.android.remote.PointerButton
import dev.bridgey.android.remote.PresentAction
import dev.bridgey.android.remote.RemoteInput
import dev.bridgey.android.remote.RemoteInputCodec
import dev.bridgey.android.remote.RemoteKey
import dev.bridgey.android.remote.RemoteMode
import dev.bridgey.android.remote.RemoteStopReason
import dev.bridgey.android.remote.ScrollUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.util.Base64

/**
 * protocol/test-vectors/protocol-v1.json: the macOS suite (ProtocolGoldenVectorsTests.swift) decodes the
 * same vectors and must reach the same results. Regenerate with protocol/tools/golden_vectors.py.
 */
class ProtocolGoldenVectorsTest {
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/protocol-v1.json").readText())
    private val sessionId = vectors.getString("sessionId")

    @Test fun frames() = each("frames") { vector ->
        val padding = if (vector.has("padTo")) "a".repeat(vector.getInt("padTo") - padPrefix().length - 2) else ""
        val bytes = when {
            vector.has("lineBase64") -> Base64.getDecoder().decode(vector.getString("lineBase64"))
            vector.has("nest") -> nested(vector.getInt("nest")).toByteArray()
            vector.has("padTo") -> (padPrefix() + padding + "\"}").toByteArray()
            else -> vector.getString("line").toByteArray()
        } + vector.optString("lineEnding", "\n").toByteArray()
        val decoded = runCatching {
            val line = ByteArrayInputStream(bytes).readProtocolLine() ?: error("no frame")
            decodeProtocolMessage(line).toMap()
        }.getOrNull()
        val expect = vector.get("expect")
        if (expect == "reject") return@each decoded == null
        val expected = normalize(expect) as Map<*, *>
        decoded == expected.mapValues { (_, value) -> if (value == "@PAD@") padding else value }
    }

    @Test fun featuresUpdate() = each("featuresUpdate") { vector ->
        val result = when (val state = decodeFeatureState(plaintext(vector))) {
            FeatureStateDecoding.Invalid -> "invalid"
            FeatureStateDecoding.Ignored -> "ignored"
            is FeatureStateDecoding.State -> {
                // Mac actions and the camera are switches here but draft keys on the wire: they are pinned once,
                // under drafts, and the switch must read exactly what the draft key says.
                val drafted = state.features.filterKeys { it.key in KNOWN_DRAFT_FEATURE_KEYS }
                if (drafted.any { (feature, on) -> state.drafts[feature.key] != on }) return@each false
                mapOf("features" to (state.features - drafted.keys).mapKeys { it.key.key }, "drafts" to state.drafts)
            }
        }
        result == normalize(vector.get("expect"))
    }

    @Test fun batteryUpdate() = each("batteryUpdate") { vector ->
        val result: Any = decodeBatteryStatus(plaintext(vector))?.let { mapOf("level" to it.level.toLong(), "isCharging" to it.isCharging) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    @Test fun clipboardRich() = each("clipboardRich") { vector ->
        val result: Any = RichClipboardContent.decode(plaintext(vector))?.let { mapOf("text" to it.text, "html" to it.html) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    @Test fun clipboardOffer() = each("clipboardOffer") { vector ->
        val result: Any = ClipOffer.decode(plaintext(vector))?.let { offer ->
            mapOf(
                "offerId" to offer.offerId.lowercase(), "createdAt" to offer.createdAt, "sensitive" to offer.sensitive,
                "items" to offer.items.map {
                    mapOf(
                        "index" to it.index.toLong(), "kind" to it.kind.key, "mime" to it.mime, "name" to it.name,
                        "size" to it.size, "sha256" to it.sha256, "inlineBytes" to it.inline?.size?.toLong(),
                    )
                },
            )
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Files 2.0 refs: the phone reads them from every browse request; the Mac reads the same ones from media.page. */
    @Test fun browseRef() = each("browseRef") { vector ->
        val result: Any = BrowseRefs.parse(strictJsonObject(plaintext(vector)))?.let { normalize(BrowseRefs.toJson(it)) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Focus sync: both platforms read focus.state alike. */
    @Test fun focusState() = each("focusState") { vector ->
        val result: Any = dev.bridgey.android.focus.decodeFocusState(plaintext(vector))?.let { mapOf("active" to it) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Mac actions: the phone reads the Mac's catalog. */
    @Test fun actionsCatalog() = each("actionsCatalog") { vector ->
        val result: Any = dev.bridgey.android.actions.decodeMacActionCatalog(plaintext(vector))?.let { catalog ->
            mapOf(
                "actions" to catalog.entries.map { mapOf("id" to it.id, "title" to it.title, "blocked" to it.blocked) },
                "volume" to catalog.volume?.let { mapOf("level" to it.level.toLong(), "muted" to it.muted) },
            )
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Mac actions: what the phone sends for a run is byte for byte the plaintext the Mac reads. */
    @Test fun actionsRunAsThePhoneSendsIt() {
        var checked = 0
        each("actionsRun") { vector ->
            val spec = vector.optJSONObject("android") ?: return@each true
            checked++
            val plaintext = vector.getJSONObject("plaintext")
            val value = if (spec.has("value")) spec.getInt("value") else null
            val encoded = dev.bridgey.android.actions.macActionRunPayload(
                plaintext.getString("requestId"), spec.getString("action"), spec.optLong("sequence", plaintext.getLong("sequence")), value,
            )
            vector.get("expect") != "reject" && normalize(encoded) == normalize(plaintext)
        }
        assertTrue(checked >= 5)
    }

    /** Mac actions: the phone reads the Mac's result. */
    @Test fun actionsResult() = each("actionsResult") { vector ->
        val result: Any = dev.bridgey.android.actions.decodeMacActionResult(plaintext(vector))?.let {
            mapOf(
                "requestId" to it.requestId, "action" to it.action, "status" to if (it.done) "done" else "refused", "reason" to it.reason,
                "volume" to it.volume?.let { volume -> mapOf("level" to volume.level.toLong(), "muted" to volume.muted) },
            )
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Phone camera: the phone reads the Mac's request. */
    @Test fun cameraRequest() = each("cameraRequest") { vector ->
        val result: Any = dev.bridgey.android.camera.decodeCameraRequest(plaintext(vector))
            ?.let { dev.bridgey.android.camera.parseCameraRequest(it) }?.let { mapOf("requestId" to it) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Phone camera: what the phone sends for each status is exactly what the Mac reads. */
    @Test fun cameraStatusAsThePhoneSendsIt() {
        var checked = 0
        each("cameraStatus") { vector ->
            val wire = vector.optString("android").takeIf { it.isNotEmpty() } ?: return@each true
            checked++
            val plaintext = vector.getJSONObject("plaintext")
            val status = dev.bridgey.android.camera.CameraStatus.entries.first { it.wire == wire }
            vector.get("expect") != "reject" &&
                normalize(dev.bridgey.android.camera.cameraStatusPayload(plaintext.getString("requestId"), status)) == normalize(plaintext)
        }
        assertEquals(dev.bridgey.android.camera.CameraStatus.entries.size, checked)
    }

    /** Settings sync: both platforms read snapshot and update payloads alike (records kept, entries skipped). */
    @Test fun settingsPayload() = each("settingsPayload") { vector ->
        val result: Any = when (val decoded = dev.bridgey.android.sync.decodeSettingsPayload(plaintext(vector))) {
            dev.bridgey.android.sync.SettingsPayloadDecoding.Invalid -> "invalid"
            is dev.bridgey.android.sync.SettingsPayloadDecoding.UnsupportedSchema -> mapOf("unsupportedSchema" to decoded.schema)
            is dev.bridgey.android.sync.SettingsPayloadDecoding.Records -> mapOf(
                "records" to decoded.records.entries.associate { (key, record) -> key.key to normalize(record.toJson()) },
                "waiting" to decoded.waiting.map { it.key },
                "skipped" to decoded.skipped.toLong(),
                "first" to decoded.first,
                "new" to decoded.new,
                "answered" to decoded.answered,
            )
        }
        result == normalize(vector.get("expect"))
    }

    /** Settings sync: which record wins when an update arrives. */
    @Test fun settingsMerge() = each("settingsMerge") { vector ->
        val local = syncRecord(vector.getJSONObject("local"))
        val remote = syncRecord(vector.getJSONObject("remote"))
        val order = dev.bridgey.android.sync.compareRecords(remote, local)
        val result = when {
            order > 0 -> "remote"
            order < 0 -> "local"
            else -> "equal"
        }
        result == vector.getString("expect")
    }

    /** Settings sync: what a snapshot record does (a chosen value is never overwritten). */
    @Test fun settingsSnapshot() = each("settingsSnapshot") { vector ->
        val outcome = dev.bridgey.android.sync.snapshotOutcome(syncRecord(vector.getJSONObject("local")), syncRecord(vector.getJSONObject("remote")))
        outcome.name.lowercase() == vector.getString("expect")
    }

    /** Settings sync: both sides pick the same device to ask "Use the same settings as <device>?". */
    @Test fun settingsAsker() = each("settingsAsker") { vector ->
        val local = vector.getJSONObject("local")
        val remote = vector.getJSONObject("remote")
        val asker = dev.bridgey.android.sync.settingsAsker(
            local.getBoolean("first"), local.getBoolean("new"), local.getBoolean("phone"), remote.getBoolean("first"), remote.getBoolean("new"),
        )
        asker.name.lowercase() == vector.getString("expect")
    }

    /** Settings sync: a local edit or Apply to all stamps alike on both platforms. */
    @Test fun settingsStamp() = each("settingsStamp") { vector ->
        val current = syncRecord(vector.getJSONObject("current"))
        val stamped = dev.bridgey.android.sync.stampLocal(current, "edit", vector.getLong("now"), vector.getString("device"))
        val expect = vector.getJSONObject("expect")
        stamped.changedAt == expect.getLong("changedAt") && stamped.version == expect.getLong("version") &&
            stamped.changedBy == expect.getString("changedBy") && stamped.value == "edit"
    }

    private fun syncRecord(json: JSONObject) = dev.bridgey.android.sync.SyncRecord(
        json.get("value"), json.getLong("changedAt"), json.getLong("version"), json.getString("changedBy"),
    )

    /** The phone is the controller: what it would send must be exactly what the Mac host accepts. */
    @Test fun remoteInputAsTheControllerSendsIt() {
        var checked = 0
        each("remoteInput") { vector ->
            val spec = vector.optJSONObject("android") ?: return@each true
            checked++
            val input = remoteInput(spec)
            val plaintext = vector.getJSONObject("plaintext")
            val valid = vector.get("expect") != "reject"
            if (input.isValid() != valid) return@each false
            if (input.kind != vector.getString("kind")) return@each false
            val encoded = JSONObject(RemoteInputCodec.encode(input, plaintext.getString("inputSessionId"), plaintext.getLong("sequence")).toString(Charsets.UTF_8))
            normalize(encoded) == normalize(plaintext)
        }
        assertTrue(checked >= 20)
    }

    /** Update all: both platforms read updates.status alike, and write the marked vectors exactly. */
    @Test fun updatesStatus() = each("updatesStatus") { vector ->
        val decoded = dev.bridgey.android.updates.decodeUpdateStatus(plaintext(vector))
        val result: Any = decoded?.let(::statusMap) ?: "reject"
        val written = !vector.optBoolean("write") ||
            (decoded != null && normalize(dev.bridgey.android.updates.updateStatusPayload(decoded)) == normalize(vector.get("plaintext")))
        written && result == normalize(vector.get("expect"))
    }

    @Test fun updatesStart() = each("updatesStart") { vector ->
        val decoded = dev.bridgey.android.updates.decodeUpdateStart(plaintext(vector))
        val result: Any = decoded?.let { mapOf("requestId" to it.requestId, "retry" to it.retry) } ?: "reject"
        val written = !vector.optBoolean("write") ||
            (decoded != null && normalize(dev.bridgey.android.updates.updateStartPayload(decoded)) == normalize(vector.get("plaintext")))
        written && result == normalize(vector.get("expect"))
    }

    @Test fun updatesResult() = each("updatesResult") { vector ->
        val decoded = dev.bridgey.android.updates.decodeUpdateResult(plaintext(vector))
        val result: Any = decoded?.let { mapOf("requestId" to it.requestId, "status" to it.status.wire, "reason" to it.reason?.wire) } ?: "reject"
        val written = !vector.optBoolean("write") ||
            (decoded != null && normalize(dev.bridgey.android.updates.updateResultPayload(decoded)) == normalize(vector.get("plaintext")))
        written && result == normalize(vector.get("expect"))
    }

    private fun statusMap(status: dev.bridgey.android.updates.UpdateStatus): Map<String, Any?> = mapOf(
        "platform" to status.platform.wire, "edition" to status.edition, "app" to status.app, "build" to status.build,
        "channel" to status.channel.wire, "state" to status.state.wire, "target" to status.target, "targetBuild" to status.targetBuild,
        "progress" to status.progress?.toLong(), "reason" to status.reason?.wire, "remoteStart" to status.remoteStart, "checkedAt" to status.checkedAt,
    )

    private fun each(group: String, check: (JSONObject) -> Boolean) {
        val array = vectors.getJSONArray(group)
        assertTrue(array.length() > 5)
        val failed = (0 until array.length()).map(array::getJSONObject).filterNot { runCatching { check(it) }.getOrDefault(false) }.map { it.getString("name") }
        assertEquals("$group vectors that decode differently from the contract", emptyList<String>(), failed)
    }

    private fun plaintext(vector: JSONObject): ByteArray =
        (if (vector.has("plaintextString")) vector.getString("plaintextString") else vector.get("plaintext").toString()).toByteArray()

    private fun padPrefix() = "{\"kind\":\"pairing.offer\",\"sessionId\":\"$sessionId\",\"deviceName\":\""

    private fun nested(depth: Int) = "{\"kind\":\"x.y\",\"sessionId\":\"$sessionId\",\"x\":" + "[".repeat(depth - 1) + "]".repeat(depth - 1) + "}"

    private fun Message.toMap(): Map<String, Any> = listOfNotNull(
        "kind" to kind, "sessionId" to sessionId, deviceId?.let { "deviceId" to it }, deviceName?.let { "deviceName" to it },
        publicKey?.let { "publicKey" to it }, identityKey?.let { "identityKey" to it }, proof?.let { "proof" to it },
        signature?.let { "signature" to it }, messageId?.let { "messageId" to it }, nonce?.let { "nonce" to it },
        ciphertext?.let { "ciphertext" to it }, transferId?.let { "transferId" to it }, sequence?.let { "sequence" to it },
        targetDeviceId?.let { "targetDeviceId" to it },
    ).toMap()

    private fun remoteInput(spec: JSONObject): RemoteInput {
        fun int(name: String) = spec.getInt(name)
        return when (val type = spec.getString("type")) {
            "Start" -> RemoteInput.Start(RemoteMode.entries.first { it.wire == spec.getString("mode") })
            "Heartbeat" -> RemoteInput.Heartbeat
            "Stop" -> RemoteInput.Stop(RemoteStopReason.entries.first { it.wire == spec.getString("reason") })
            "Pointer" -> RemoteInput.Pointer(int("dx"), int("dy"))
            "Button" -> RemoteInput.Button(PointerButton.entries.first { it.wire == spec.getString("button") }, spec.getBoolean("down"))
            "Scroll" -> RemoteInput.Scroll(int("dx"), int("dy"), ScrollUnit.entries.first { it.wire == spec.getString("unit") })
            "DragStart" -> RemoteInput.DragStart
            "DragMove" -> RemoteInput.DragMove(int("dx"), int("dy"))
            "DragEnd" -> RemoteInput.DragEnd
            "Text" -> RemoteInput.Text(spec.getString("text"))
            "Key" -> RemoteInput.Key(RemoteKey.entries.first { it.wire == spec.getString("key") }, spec.optBoolean("shift"))
            "Present" -> RemoteInput.Present(
                PresentAction.entries.first { it.wire == spec.getString("action") },
                spec.opt("x") as? Int, spec.opt("y") as? Int,
            )
            else -> error("unknown type $type")
        }
    }

    companion object {
        /** JSON as plain Kotlin values: maps, lists, Long for integers, null for JSON null. */
        fun normalize(value: Any?): Any? = when (value) {
            is JSONObject -> value.keys().asSequence().associateWith { normalize(value.opt(it)) }
            is JSONArray -> (0 until value.length()).map { normalize(value.opt(it)) }
            JSONObject.NULL -> null
            is Number -> jsonInteger(value) ?: value.toDouble()
            else -> value
        }
    }
}
