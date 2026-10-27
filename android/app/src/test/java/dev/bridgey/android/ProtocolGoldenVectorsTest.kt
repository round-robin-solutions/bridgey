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
            is FeatureStateDecoding.State -> mapOf("features" to state.features.mapKeys { it.key.key }, "drafts" to state.drafts)
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
