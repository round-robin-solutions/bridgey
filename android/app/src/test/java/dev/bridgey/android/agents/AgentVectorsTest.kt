package dev.bridgey.android.agents

import dev.bridgey.android.connect.hkdfSha256
import dev.bridgey.android.connect.tunnelTranscript
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * protocol/test-vectors/agent-v1.json (generator protocol/tools/agent_vectors.py): what this phone decodes from agents
 * and Macs, and the encodings it sends. The CLI and the Mac check the same file.
 */
class AgentVectorsTest {
    private val vectors = JSONObject(File(File(System.getProperty("bridgey.repoRoot") ?: "../.."), "protocol/test-vectors/agent-v1.json").readText())
    private val control = "wss://connect.roundrobin.in/v1/ws"
    private val now = 1_798_000_000_000L

    private fun cases(name: String): List<JSONObject> = vectors.getJSONArray(name).let { list -> (0 until list.length()).map(list::getJSONObject) }

    private fun bytes(case: JSONObject): ByteArray = case.getJSONObject("plaintext").toString().toByteArray()

    private fun rejects(case: JSONObject) = case.opt("expect") == "reject"

    /** JSON as plain Kotlin values, numbers as Long or Double, so two documents compare whatever their key order. */
    private fun plain(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { plain(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { plain(value.get(it)) }
        is Int -> value.toLong()
        is Long -> value
        is Number -> value.toDouble().let { if (it == Math.floor(it)) it.toLong() else it }
        else -> value
    }

    private fun assertJson(expected: JSONObject, actual: ByteArray, label: String) =
        assertEquals(label, plain(expected), plain(JSONObject(String(actual))))

    // MARK: invite

    @Test fun inviteParsesAndDerives() {
        val invite = vectors.getJSONObject("invite")
        val secret = Base64.getDecoder().decode(invite.getString("secret"))
        val parsed = parseInviteJson(invite.getString("json").toByteArray(), control, now) as InviteParse.Ok
        assertTrue(parsed.invite.secret.contentEquals(secret))
        assertEquals("Contabo Europe", parsed.invite.name)
        assertEquals("cli", parsed.invite.platform)
        assertEquals(1_798_000_600_000L, parsed.invite.expiresAtMillis)
        val fromLink = parseInvite(invite.getString("link"), control, now) as InviteParse.Ok
        assertTrue(fromLink.invite.secret.contentEquals(secret))
        // Pasted as just the fragment, with spaces around it, reads the same.
        assertTrue(parseInvite("  " + invite.getString("link").substringAfter('#') + "\n", control, now) is InviteParse.Ok)
        assertEquals(invite.getString("rdv"), inviteRdv(secret))
        assertEquals("invite:" + invite.getString("rdv"), parsed.invite.peerLabel)
        assertEquals(invite.getString("sigKey"), Base64.getEncoder().encodeToString(hkdfSha256(secret, ByteArray(0), "bridgey-invite-signal-v1".toByteArray())))
        assertEquals(invite.getString("inviteHash"), inviteHash(secret))
    }

    @Test fun inviteTranscriptAppendsTheInvite() {
        val invite = vectors.getJSONObject("invite")
        val t = invite.getJSONObject("transcript")
        val secret = Base64.getDecoder().decode(invite.getString("secret"))
        val base = tunnelTranscript(
            t.getString("sessionId"), t.getString("initiatorId"), t.getString("responderId"),
            t.getString("initiatorKey"), t.getString("responderKey"), t.getString("exporter"),
        )
        assertEquals(t.getString("expected"), Base64.getEncoder().encodeToString(inviteTranscript(base, secret)))
    }

    @Test fun invalidInvitesAreRefused() {
        val list = vectors.getJSONObject("invite").getJSONArray("invalid")
        for (index in 0 until list.length()) {
            val case = list.getJSONObject(index)
            assertEquals(case.getString("name"), InviteParse.Invalid, parseInviteJson(case.getString("json").toByteArray(), control, now))
        }
    }

    @Test fun inviteLimits() {
        val json = vectors.getJSONObject("invite").getString("json")
        // Past, or more than 10 minutes (and the allowed skew) ahead of this phone's clock.
        assertEquals(InviteParse.Expired, parseInviteJson(json.toByteArray(), control, 1_798_000_600_000L))
        assertEquals(InviteParse.Expired, parseInviteJson(json.toByteArray(), control, now - 2 * 60_000))
        // Another control service, or this build has none.
        assertEquals(InviteParse.OtherService, parseInviteJson(json.toByteArray(), "wss://connect.rbansal.xyz/v1/ws", now))
        assertEquals(InviteParse.OtherService, parseInviteJson(json.toByteArray(), "", now))
        // Only agents pair by invite in this version.
        val mac = JSONObject(json).put("p", "macos").toString()
        assertEquals(InviteParse.Invalid, parseInviteJson(mac.toByteArray(), control, now))
        // At most 1,024 bytes, and only bridgey://pair links.
        assertEquals(InviteParse.Invalid, parseInvite("bridgey://pair#" + "A".repeat(1_100), control, now))
        assertEquals(InviteParse.Invalid, parseInvite("https://example.com/#abc", control, now))
        assertEquals(InviteParse.Invalid, parseInvite("bridgey://pair#not base64!", control, now))
        // A name with control or bidi characters is shown without them.
        val named = JSONObject(json).put("n", "Ra\u202Ehul\u0007").toString()
        assertEquals("Rahul", (parseInviteJson(named.toByteArray(), control, now) as InviteParse.Ok).invite.name)
    }

    // MARK: what the phone decodes

    @Test fun notifyPost() {
        cases("notifyPost").forEach { case ->
            val decoded = decodeNotifyPost(bytes(case))
            if (rejects(case)) return@forEach assertNull(case.getString("name"), decoded)
            val expect = case.getJSONObject("expect")
            assertNotNull(case.getString("name"), decoded)
            val actual = JSONObject().put("notifyId", decoded!!.notifyId).put("title", decoded.title).put("priority", decoded.priority.wire).apply {
                decoded.body?.let { put("body", it) }
                decoded.tag?.let { put("tag", it) }
                decoded.from?.let { put("from", it) }
            }
            assertEquals(case.getString("name"), plain(expect), plain(actual))
        }
    }

    @Test fun askRequest() {
        cases("askRequest").forEach { case ->
            val decoded = decodeAskRequest(bytes(case), case.getLong("now"))
            if (rejects(case)) return@forEach assertNull(case.getString("name"), decoded)
            val ask = decoded ?: error("${case.getString("name")} was refused")
            val actual = JSONObject()
                .put("askId", ask.askId).put("title", ask.title)
                .put("options", JSONArray(ask.options.map { JSONObject().put("id", it.id).put("label", it.label) }))
                .put("allowText", ask.allowText).put("requireUnlock", ask.requireUnlock).put("expiresAt", ask.expiresAt)
                .apply {
                    ask.body?.let { put("body", it) }
                    ask.textHint?.let { put("textHint", it) }
                    ask.from?.let { put("from", it) }
                }
            assertEquals(case.getString("name"), plain(case.getJSONObject("expect")), plain(actual))
        }
    }

    @Test fun codesQuery() {
        cases("codesQuery").forEach { case ->
            val decoded = decodeCodesQuery(bytes(case))
            if (rejects(case)) return@forEach assertNull(case.getString("name"), decoded)
            val query = decoded ?: error("${case.getString("name")} was refused")
            val actual = JSONObject().put("queryId", query.queryId).put("sinceMs", query.sinceMs).put("waitMs", query.waitMs).put("latestOnly", query.latestOnly)
                .apply {
                    query.service?.let { put("service", it) }
                    query.newerThan?.let { put("newerThan", it) }
                }
            assertEquals(case.getString("name"), plain(case.getJSONObject("expect")), plain(actual))
        }
    }

    @Test fun codesFound() {
        cases("codesFound").forEach { case ->
            val decoded = decodeCodesFound(bytes(case))
            if (rejects(case)) return@forEach assertNull(case.getString("name"), decoded)
            val found = decoded ?: error("${case.getString("name")} was refused")
            val actual = JSONObject().put("foundId", found.foundId).put("code", found.code).put("service", found.service)
                .put("serviceKey", found.serviceKey).put("source", found.source.wire).put("app", found.app)
                .put("notificationId", found.notificationId).put("postedAt", found.postedAt)
            assertEquals(case.getString("name"), plain(case.getJSONObject("expect")), plain(actual))
        }
    }

    @Test fun codesDetected() {
        cases("codesDetected").forEach { case ->
            val decoded = decodeCodesDetected(bytes(case))
            if (rejects(case)) return@forEach assertNull(case.getString("name"), decoded)
            val d = decoded ?: error("${case.getString("name")} was refused")
            val actual = JSONObject().put("candidateId", d.candidateId).put("outcome", d.outcome.wire)
                .apply { d.code?.let { put("code", it) }; d.reason?.let { put("reason", it) } }
            assertEquals(case.getString("name"), plain(case.getJSONObject("expect")), plain(actual))
        }
    }

    /** What this phone sends as codes.candidate is what the CLI decodes (the vectors' first case). */
    @Test fun codesCandidateEncoding() {
        val case = cases("codesCandidate").first()
        val p = case.getJSONObject("plaintext")
        val payload = codesCandidatePayload(p.getString("candidateId"), CodeSource.SMS, p.getString("app"), p.getString("sender"), p.getString("text"), p.getLong("postedAt"))
        assertJson(p, payload, case.getString("name"))
    }

    @Test fun agentsGrantSet() {
        cases("agentsGrantSet").forEach { case ->
            val decoded = decodeAgentsGrantSet(bytes(case))
            if (rejects(case)) return@forEach assertNull(case.getString("name"), decoded)
            val set = decoded ?: error("${case.getString("name")} was refused")
            val actual = JSONObject().put("requestId", set.requestId).put("deviceId", set.deviceId).put("key", set.grant.key).put("on", set.on)
                .apply { set.window?.let { put("window", it.wire) } }
            assertEquals(case.getString("name"), plain(case.getJSONObject("expect")), plain(actual))
        }
    }

    // MARK: what the phone sends

    @Test fun agentGrantsEncoding() {
        cases("agentGrants").filterNot(::rejects).forEach { case ->
            val expect = case.getJSONObject("expect").getJSONArray("grants")
            val views = (0 until expect.length()).map { index ->
                val grant = expect.getJSONObject(index)
                GrantView(
                    AgentGrant.of(grant.getString("key"))!!,
                    GrantShown.entries.first { it.wire == grant.getString("state") },
                    GrantWindow.of(grant.optString("window").ifEmpty { null }),
                    grant.optLong("grantedAt").takeIf { grant.has("grantedAt") },
                    grant.optLong("expiresAt").takeIf { grant.has("expiresAt") },
                    grant.optString("scope").ifEmpty { null },
                )
            }
            assertJson(JSONObject().put("version", 1).put("grants", expect), agentGrantsPayload(views), case.getString("name"))
        }
    }

    @Test fun askAnswerEncoding() {
        cases("askAnswer").forEach { case ->
            val plaintext = case.getJSONObject("plaintext")
            val encoded = askAnswerPayload(
                plaintext.getString("askId"),
                plaintext.optString("option").ifEmpty { null },
                plaintext.optString("text").ifEmpty { null },
                plaintext.getLong("answeredAt"),
            )
            if (rejects(case)) return@forEach assertNull(case.getString("name"), encoded)
            assertJson(plaintext, encoded!!, case.getString("name"))
        }
    }

    @Test fun clipboardResponseEncoding() {
        cases("clipboardResponse").forEach { case ->
            val plaintext = case.getJSONObject("plaintext")
            val encoded = clipboardResponsePayload(
                plaintext.getString("requestId"),
                ClipResponseStatus.entries.first { it.wire == plaintext.getString("status") },
                plaintext.optString("text").takeIf { plaintext.has("text") },
                plaintext.optString("html").takeIf { plaintext.has("html") },
            )
            if (rejects(case)) return@forEach assertNull(case.getString("name"), encoded)
            assertJson(plaintext, encoded!!, case.getString("name"))
        }
    }

    @Test fun codesResultEncoding() {
        cases("codesResult").forEach { case ->
            val plaintext = case.getJSONObject("plaintext")
            val list = plaintext.getJSONArray("codes")
            val codes = (0 until list.length()).map { index ->
                val code = list.getJSONObject(index)
                val source = CodeSource.of(code.getString("source"))
                if (rejects(case)) return@forEach assertNull(case.getString("name"), source)
                CodeOut(
                    code.getString("code"), code.getString("service"), source!!, code.getString("app"), code.getLong("postedAt"),
                    code.getBoolean("latest"), code.getBoolean("replaced"),
                    code.getJSONArray("via").let { via -> (0 until via.length()).map(via::getString) },
                )
            }
            val encoded = codesResultPayload(plaintext.getString("queryId"), codes, plaintext.getInt("readers"), plaintext.getBoolean("timedOut"))
            assertJson(plaintext, encoded, case.getString("name"))
        }
    }
}
