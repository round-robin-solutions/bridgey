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

    /** Screen sharing: the phone reads the Mac's request. */
    @Test fun screenRequest() = each("screenRequest") { vector ->
        val result: Any = dev.bridgey.android.screen.decodeScreenRequest(plaintext(vector))?.let { mapOf("requestId" to it) } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Screen sharing: what the phone sends for each status is exactly what the Mac reads. */
    @Test fun screenStatusAsThePhoneSendsIt() {
        var checked = 0
        each("screenStatus") { vector ->
            val wire = vector.optString("android").takeIf { it.isNotEmpty() } ?: return@each true
            checked++
            val plaintext = vector.getJSONObject("plaintext")
            val status = dev.bridgey.android.screen.ScreenStatus.entries.first { it.wire == wire }
            vector.get("expect") != "reject" &&
                normalize(dev.bridgey.android.screen.screenStatusPayload(plaintext.getString("requestId"), status)) == normalize(plaintext)
        }
        assertEquals(dev.bridgey.android.screen.ScreenStatus.entries.size, checked)
    }

    /** Screen sharing: the Mac's stream messages as the phone reads them (decoder android or both). */
    @Test fun screenStreamAsThePhoneReadsIt() {
        var checked = 0
        each("screenStream") { vector ->
            if (vector.getString("decoder") == "mac") return@each true
            checked++
            val result: Any = when (val message = dev.bridgey.android.screen.decodeScreenMacMessage(vector.getString("kind"), plaintext(vector))) {
                null -> "reject"
                is dev.bridgey.android.screen.ScreenMacMessage.Started -> mapOf("streamId" to message.streamId, "sequence" to message.sequence)
                is dev.bridgey.android.screen.ScreenMacMessage.Ack -> mapOf(
                    "streamId" to message.streamId, "sequence" to message.sequence, "frame" to message.frame,
                    "decodeMs" to message.decodeMs, "keyframe" to message.keyframe,
                )
                is dev.bridgey.android.screen.ScreenMacMessage.Stop -> mapOf("streamId" to message.streamId, "sequence" to message.sequence, "reason" to message.reason.wire)
            }
            result == normalize(vector.get("expect"))
        }
        assertTrue(checked >= 20)
    }

    /** Screen sharing: screen.start, screen.stats and the phone's screen.stop exactly as the Mac reads them. */
    @Test fun screenStreamAsThePhoneSendsIt() {
        var checked = 0
        each("screenStream") { vector ->
            if (!vector.optBoolean("android")) return@each true
            checked++
            val plaintext = vector.getJSONObject("plaintext")
            val streamId = plaintext.getString("streamId")
            val sequence = plaintext.getLong("sequence")
            val encoded = when (vector.getString("kind")) {
                "screen.start" -> dev.bridgey.android.screen.screenStartPayload(
                    streamId, sequence,
                    dev.bridgey.android.screen.ScreenStartInfo(
                        plaintext.getInt("width"), plaintext.getInt("height"), plaintext.getInt("fps"), plaintext.getLong("bitrate"),
                        plaintext.optString("requestId").takeIf { it.isNotEmpty() },
                    ),
                )
                "screen.stats" -> dev.bridgey.android.screen.screenStatsPayload(
                    streamId, sequence,
                    dev.bridgey.android.screen.ScreenStats(
                        plaintext.getLong("latencyMs"), plaintext.getLong("rttMs"), plaintext.getLong("bitrate"),
                        plaintext.getLong("sentBitrate"), plaintext.getInt("fps"), plaintext.getInt("dropped"),
                    ),
                )
                "screen.stop" -> dev.bridgey.android.screen.screenStopPayload(
                    streamId, sequence, dev.bridgey.android.screen.ScreenStopReason.entries.first { it.wire == plaintext.getString("reason") },
                )
                else -> return@each false
            }
            vector.get("expect") != "reject" && normalize(encoded) == normalize(plaintext)
        }
        assertTrue(checked >= 9)
    }

    /** Screen sharing: the frame header rules (the Mac's reader), and the phone's writer byte for byte. */
    @Test fun screenFrame() {
        var written = 0
        each("screenFrame") { vector ->
            var bytes = hex(vector.getString("plaintextHex"))
            if (vector.has("padTo")) bytes = bytes.copyOf(vector.getInt("padTo"))
            val decoded = dev.bridgey.android.screen.ScreenFrameCodec.decode(bytes)
            val expect = vector.get("expect")
            if (expect == "reject") return@each decoded == null
            val (header, payload) = decoded ?: return@each false
            // captureMicros may exceed 2^53 (up to 2^63-1): read it as a Long, not through normalize.
            val expected = (normalize(expect) as Map<*, *>) + ("captureMicros" to (expect as JSONObject).getLong("captureMicros"))
            val actual = mutableMapOf<String, Any>(
                "streamId" to header.streamId, "sequence" to header.sequence, "frame" to header.frame, "part" to header.part.toLong(),
                "key" to header.key, "parameterSets" to header.parameterSets, "last" to header.last, "captureMicros" to header.captureMicros,
            )
            if (expected.containsKey("payloadLength")) actual["payloadLength"] = payload.size.toLong() else actual["payloadHex"] = payload.toHex()
            if (actual != expected) return@each false
            if (!vector.optBoolean("android")) return@each true
            written++
            dev.bridgey.android.screen.ScreenFrameCodec.encode(header, payload).contentEquals(bytes)
        }
        assertTrue(written >= 4)
    }

    private fun hex(text: String): ByteArray = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    /** Text messages: the Mac's page, sync, image and contact requests as the phone reads them. */
    @Test fun smsRequest() = each("smsRequest") { vector ->
        val result: Any = dev.bridgey.android.sms.decodeSmsRequest(vector.getString("kind"), plaintext(vector))?.let { request ->
            when (request) {
                is dev.bridgey.android.sms.SmsRequest.Threads -> mapOf("requestId" to request.requestId, "limit" to request.limit.toLong(), "before" to request.before)
                is dev.bridgey.android.sms.SmsRequest.Messages -> mapOf(
                    "requestId" to request.requestId, "threadId" to request.threadId, "limit" to request.limit.toLong(),
                    "before" to request.before?.let { mapOf("date" to it.date, "id" to it.id) },
                )
                is dev.bridgey.android.sms.SmsRequest.Sync -> mapOf(
                    "requestId" to request.requestId, "since" to mapOf("sms" to request.since.sms, "mms" to request.since.mms), "limit" to request.limit.toLong(),
                )
                is dev.bridgey.android.sms.SmsRequest.Attachment -> mapOf("requestId" to request.requestId, "partId" to request.partId)
                is dev.bridgey.android.sms.SmsRequest.Contacts -> mapOf("requestId" to request.requestId, "query" to request.query)
                is dev.bridgey.android.sms.SmsRequest.MarkRead -> mapOf("requestId" to request.requestId, "threadIds" to request.threadIds)
                is dev.bridgey.android.sms.SmsRequest.BlockedNumbers -> mapOf("requestId" to request.requestId, "address" to request.address)
            }
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Text messages: sms.send as the phone reads it. */
    @Test fun smsSend() = each("smsSend") { vector ->
        val result: Any = dev.bridgey.android.sms.decodeSmsSend(plaintext(vector))?.let { request ->
            val target = request.target
            mapOf(
                "requestId" to request.requestId, "body" to request.body,
                "threadId" to (target as? dev.bridgey.android.sms.SendTarget.Thread)?.threadId,
                "address" to (target as? dev.bridgey.android.sms.SendTarget.Address)?.address,
                "notificationId" to (target as? dev.bridgey.android.sms.SendTarget.Notification)?.notificationId,
                "subId" to request.subId?.toLong(),
            )
        } ?: "reject"
        result == normalize(vector.get("expect"))
    }

    /** Text messages: what the phone writes for each status the Mac accepts reads back the same. */
    @Test fun smsStatusAsThePhoneSendsIt() = each("smsStatus") { vector ->
        val expect = vector.get("expect") as? JSONObject ?: return@each true
        val sims = expect.getJSONArray("sims").let { array ->
            (0 until array.length()).map(array::getJSONObject).map { dev.bridgey.android.sms.SimInfo(it.getInt("subId"), it.getInt("slot"), it.getString("label")) }
        }
        val cursor = expect.getJSONObject("cursor")
        val encoded = dev.bridgey.android.sms.smsStatusPayload(
            expect.getBoolean("read"), expect.getBoolean("send"), expect.getBoolean("contacts"), sims,
            dev.bridgey.android.sms.SmsCursor(cursor.getLong("sms"), cursor.getLong("mms")),
        )
        normalize(encoded) == normalize(JSONObject(expect.toString()).put("version", 1))
    }

    /** Text messages: a message the phone writes carries exactly the fields the Mac reads (absent defaults left out). */
    @Test fun smsMessageAsThePhoneSendsIt() = each("smsMessage") { vector ->
        val expect = vector.get("expect") as? JSONObject ?: return@each true
        // A cut body is cut on the phone from a longer one; its vector has no longer body to start from.
        if (expect.getBoolean("truncated")) return@each true
        val parts = expect.getJSONArray("parts").let { array ->
            (0 until array.length()).map(array::getJSONObject).map {
                dev.bridgey.android.sms.SmsPart(it.getString("partId"), it.getString("mimeType"), if (it.isNull("size")) null else it.getLong("size"))
            }
        }
        val message = dev.bridgey.android.sms.SmsMessage(
            id = expect.getString("id"), threadId = expect.getLong("threadId"),
            direction = dev.bridgey.android.sms.SmsDirection.entries.first { it.wire == expect.getString("direction") },
            status = dev.bridgey.android.sms.SmsStatus.entries.first { it.wire == expect.getString("status") },
            date = expect.getLong("date"), address = expect.getString("address"), body = expect.getString("body"),
            subId = if (expect.isNull("subId")) null else expect.getInt("subId"), read = expect.getBoolean("read"), parts = parts,
        )
        val wire = JSONObject(expect.toString()).apply {
            remove("truncated")
            if (isNull("subId")) remove("subId")
            if (getJSONArray("parts").length() == 0) remove("parts") else getJSONArray("parts").let { array ->
                (0 until array.length()).map(array::getJSONObject).forEach { if (it.isNull("size")) it.remove("size") }
            }
        }
        normalize(message.toJson()) == normalize(wire)
    }

    /** Text messages: send statuses as the phone writes them. */
    @Test fun smsSendStatusAsThePhoneSendsIt() = each("smsSendStatus") { vector ->
        val expect = vector.get("expect") as? JSONObject ?: return@each true
        val state = dev.bridgey.android.sms.SendState.entries.first { it.wire == expect.getString("status") }
        val reason = if (expect.isNull("reason")) null else dev.bridgey.android.sms.SendReason.entries.first { it.wire == expect.getString("reason") }
        val via = if (expect.isNull("via")) null else dev.bridgey.android.sms.SendVia.entries.first { it.wire == expect.getString("via") }
        val wire = JSONObject().put("version", 1).put("requestId", expect.getString("requestId")).put("status", state.wire).apply {
            if (reason != null) put("reason", reason.wire)
            if (via != null) put("via", via.wire)
        }
        normalize(dev.bridgey.android.sms.smsSendStatusPayload(expect.getString("requestId"), state, reason, via)) == normalize(wire)
    }

    /** Text messages: Mark as read results as the phone writes them (the Mac decodes the same vectors). */
    @Test fun smsMarkReadResultAsThePhoneSendsIt() = each("smsMarkReadResult") { vector ->
        val expect = vector.get("expect") as? JSONObject ?: return@each true
        val results = expect.getJSONArray("results").let { array ->
            (0 until array.length()).map(array::getJSONObject).map { entry ->
                entry.getLong("threadId") to dev.bridgey.android.sms.MarkReadResult.entries.first { it.wire == entry.getString("result") }
            }
        }
        val error = if (expect.isNull("error")) null else expect.getString("error")
        val written = dev.bridgey.android.sms.smsMarkReadResultPayload(expect.getString("requestId"), results, error)
        val wire = JSONObject(expect.toString()).put("version", 1).apply { if (isNull("error")) remove("error") }
        normalize(written) == normalize(wire)
    }

    /** Text messages: Block on phone results as the phone writes them. */
    @Test fun smsBlockedNumbersResultAsThePhoneSendsIt() = each("smsBlockedNumbersResult") { vector ->
        val expect = vector.get("expect") as? JSONObject ?: return@each true
        val result = dev.bridgey.android.sms.BlockedNumbersResult.entries.first { it.wire == expect.getString("result") }
        val wire = JSONObject().put("version", 1).put("requestId", expect.getString("requestId")).put("result", result.wire)
        normalize(dev.bridgey.android.sms.smsBlockedNumbersResultPayload(expect.getString("requestId"), result)) == normalize(wire)
    }

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
        val result: Any = decoded?.let { mapOf("requestId" to it.requestId, "retry" to it.retry, "auto" to it.auto) } ?: "reject"
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
        "auto" to status.auto, "busy" to status.busy?.wire,
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
