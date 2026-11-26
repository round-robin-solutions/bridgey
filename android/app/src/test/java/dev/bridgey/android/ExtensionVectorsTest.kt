package dev.bridgey.android

import dev.bridgey.android.ProtocolGoldenVectorsTest.Companion.normalize
import dev.bridgey.android.codes.codesAdvertiseStopPayload
import dev.bridgey.android.connect.connectSetupAckPayload
import dev.bridgey.android.remote.HostMessage
import dev.bridgey.android.remote.RemoteInputCodec
import dev.bridgey.android.sms.SmsContact
import dev.bridgey.android.sms.SmsCursor
import dev.bridgey.android.sms.SmsParticipant
import dev.bridgey.android.sms.SmsThread
import dev.bridgey.android.sms.smsAttachmentDataPayload
import dev.bridgey.android.sms.smsAttachmentErrorPayload
import dev.bridgey.android.sms.smsChangedPayload
import dev.bridgey.android.sms.smsContactsResultPayload
import dev.bridgey.android.sms.smsThreadsPagePayload
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.decodeSettingsAck
import dev.bridgey.android.sync.decodeSettingsError
import dev.bridgey.android.sync.settingsAckPayload
import dev.bridgey.android.sync.settingsErrorPayload
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * Edition extension kinds in protocol/test-vectors/protocol-v1.json that had no vector (docs/protocol-v1.md, Gaps). The
 * phone reads "clipboardFetch", "clipboardError", "inputSessionStarted", "settingsAck" and "settingsError", and writes
 * the vectors marked write of "clipboardFetch", "clipboardError", "codesAdvertiseStop", "smsChanged", "smsThreadsPage",
 * "smsAttachmentData", "smsContactsResult", "connectSetupAck", "settingsAck" and "settingsError". The Mac
 * (ExtensionVectorsTests.swift) and rust/client (src/vectors.rs) check the same groups from their side.
 */
class ExtensionVectorsTest {
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/protocol-v1.json").readText())

    private fun cases(group: String): List<JSONObject> = vectors.getJSONArray(group).let { list -> (0 until list.length()).map(list::getJSONObject) }

    private fun plaintext(vector: JSONObject): ByteArray =
        (if (vector.has("plaintextString")) vector.getString("plaintextString") else vector.getJSONObject("plaintext").toString()).toByteArray()

    /** Every vector of [group]: what the phone keeps, or "reject", equals expect. */
    private fun reads(group: String, decode: (ByteArray) -> JSONObject?) {
        val list = cases(group)
        assertTrue(group, list.isNotEmpty())
        val failed = list.filterNot { vector ->
            runCatching { normalize(decode(plaintext(vector)) ?: "reject") == normalize(vector.get("expect")) }.getOrDefault(false)
        }.map { it.getString("name") }
        assertEquals("$group vectors this phone reads differently", emptyList<String>(), failed)
    }

    /** The vectors of [group] marked write: from the plaintext's values, the phone's encoder writes exactly that plaintext. */
    private fun writes(group: String, encode: (JSONObject) -> Any) {
        val list = cases(group).filter { it.optBoolean("write") }
        assertTrue(group, list.isNotEmpty())
        val failed = list.filterNot { vector ->
            val expected = vector.getJSONObject("plaintext")
            runCatching {
                val json = when (val encoded = encode(expected)) {
                    is ByteArray -> JSONObject(String(encoded, Charsets.UTF_8))
                    else -> encoded as JSONObject
                }
                normalize(json) == normalize(expected)
            }.getOrDefault(false)
        }.map { it.getString("name") }
        assertEquals("$group vectors this phone writes differently", emptyList<String>(), failed)
    }

    private fun JSONObject.optionalString(name: String): String? = if (has(name) && !isNull(name)) getString(name) else null

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map(::getJSONObject)

    // MARK: clipboard.fetch and clipboard.error (clipboard_files_draft1)

    @Test fun clipboardFetchReads() = reads("clipboardFetch") { bytes ->
        parseClipReference(bytes, null)?.let { JSONObject().put("offerId", it.offerId).put("index", it.index).put("transferId", it.transferId) }
    }

    @Test fun clipboardFetchWrites() = writes("clipboardFetch") { p ->
        clipFetchPayload(p.getString("offerId"), p.getInt("index"), p.getString("transferId"))
    }

    @Test fun clipboardErrorReads() = reads("clipboardError") { bytes ->
        parseClipError(bytes, null)?.let { (reference, code) ->
            JSONObject().put("offerId", reference.offerId).put("index", reference.index).put("transferId", reference.transferId).put("code", code)
        }
    }

    @Test fun clipboardErrorWrites() = writes("clipboardError") { p ->
        clipErrorPayload(p.getString("offerId"), p.getInt("index"), p.getString("transferId"), p.getString("code"))
    }

    /** A code of another type reads as unavailable too, as on the Mac; an envelope naming another transfer is dropped. */
    @Test fun clipboardErrorCodeOfAnotherTypeReadsAsUnavailable() {
        val reference = """{"version":1,"offerId":"6f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f","index":0,"transferId":"7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d""""
        assertEquals(ClipErrorCode.UNAVAILABLE, parseClipError("$reference,\"code\":7}".toByteArray(), null)?.second)
        assertEquals(null, parseClipError("$reference,\"code\":\"busy\"}".toByteArray(), "0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5a"))
    }

    // MARK: codes.advertise_stop (sms_codes_draft1)

    @Test fun codesAdvertiseStopWrites() = writes("codesAdvertiseStop") { p ->
        codesAdvertiseStopPayload(UUID.fromString(p.getString("serviceUuid")), p.getBoolean("linked"))
    }

    // MARK: input.session.started (remote_input_draft1)

    @Test fun inputSessionStartedReads() = reads("inputSessionStarted") { bytes ->
        (RemoteInputCodec.decodeHostMessage("input.session.started", bytes) as? HostMessage.Started)?.let {
            JSONObject().put("inputSessionId", it.inputSessionId).put("sequence", it.sequence).put("heartbeatSeconds", it.heartbeatMillis / 1000)
        }
    }

    // MARK: Text messages (sms_draft1), written by the phone

    @Test fun smsChangedWrites() = writes("smsChanged") { p ->
        val cursor = p.getJSONObject("cursor")
        smsChangedPayload(SmsCursor(cursor.getLong("sms"), cursor.getLong("mms")))
    }

    @Test fun smsThreadsPageWrites() = writes("smsThreadsPage") { p ->
        val threads = p.getJSONArray("threads").objects().map { t ->
            SmsThread(
                t.getLong("threadId"),
                t.getJSONArray("participants").objects().map { SmsParticipant(it.getString("address"), it.optionalString("name")) },
                t.getString("snippet"), t.getLong("date"), t.getInt("unread"), if (t.has("subId")) t.getInt("subId") else null,
            ).toJson()
        }
        smsThreadsPagePayload(p.getString("requestId"), threads, p.getBoolean("more"), p.optionalString("error"))
    }

    @Test fun smsAttachmentDataWrites() = writes("smsAttachmentData") { p ->
        when (val error = p.optionalString("error")) {
            null -> smsAttachmentDataPayload(p.getString("requestId"), p.getString("partId"), p.getInt("width"), p.getInt("height"), p.getString("data"))
            else -> smsAttachmentErrorPayload(p.getString("requestId"), p.getString("partId"), error)
        }
    }

    @Test fun smsContactsResultWrites() = writes("smsContactsResult") { p ->
        val contacts = p.getJSONArray("contacts").objects().map { SmsContact(it.getString("name"), it.getString("address"), it.optionalString("label")).toJson() }
        smsContactsResultPayload(p.getString("requestId"), contacts, p.optionalString("error"))
    }

    // MARK: connect.setup.ack (connect_draft1): informational, nothing is read from it

    @Test fun connectSetupAckWrites() = writes("connectSetupAck") { connectSetupAckPayload() }

    // MARK: settings.ack and settings.error (settings_sync_draft1)

    @Test fun settingsAckReads() = reads("settingsAck") { bytes ->
        decodeSettingsAck(bytes)?.let { ack ->
            JSONObject().put("ackOf", ack.ackOf).put("applied", JSONArray(ack.applied.map { it.key })).put("kept", JSONArray(ack.kept.map { it.key }))
        }
    }

    @Test fun settingsAckWrites() = writes("settingsAck") { p ->
        fun keys(name: String) = p.getJSONArray(name).let { list -> (0 until list.length()).map { SyncKey.from(list.getString(it))!! } }
        settingsAckPayload(p.getString("ackOf"), keys("applied"), keys("kept"))
    }

    @Test fun settingsErrorReads() = reads("settingsError") { bytes -> decodeSettingsError(bytes)?.let { JSONObject().put("code", it) } }

    @Test fun settingsErrorWrites() = writes("settingsError") { p -> settingsErrorPayload(p.getString("code")) }
}
