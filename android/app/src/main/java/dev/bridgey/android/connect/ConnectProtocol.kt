package dev.bridgey.android.connect

import dev.bridgey.android.jsonInteger
import dev.bridgey.android.strictJsonObject
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/*
 * Connect anywhere (draft connect_draft1, docs/protocol.md "Draft: Connect anywhere"): the
 * in-session messages, the pair secret and the tunnel transcript. Pure Kotlin, so the golden
 * vectors (protocol/test-vectors/protocol-v1.json and connect-v1.json) run in plain JUnit. The Mac
 * has the same rules in ConnectProtocol.swift.
 */

const val CONNECT_FEATURE_KEY = "connect_draft1"

/** The connect.* kinds this phone sends and handles (the contract scanner reads this list). */
object ConnectKinds {
    const val SETUP = "connect.setup"
    const val SETUP_ACK = "connect.setup.ack"
    const val ADDRESSES = "connect.addresses"
}

const val CONNECT_SETUP_MAX_BYTES = 256
const val CONNECT_ADDRESSES_MAX_BYTES = 2_048
const val CONNECT_MAX_ADDRESSES = 16

class ConnectSetup(val contribution: ByteArray, val rotate: Boolean)

/** One address a peer can be dialled at: an IP literal, `lan`, `vpn` or `public6`, and the VPN when known. */
data class ConnectAddress(val a: String, val kind: String, val vpn: String? = null)

data class ConnectAddresses(val port: Int, val addrs: List<ConnectAddress>, val pairCheck: String?)

/** connect.setup: version 1, a 32-byte contribution, rotate an optional boolean; anything else is null. */
fun decodeConnectSetup(plaintext: ByteArray): ConnectSetup? {
    if (plaintext.size > CONNECT_SETUP_MAX_BYTES) return null
    val payload = strictJsonObject(plaintext) ?: return null
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val text = payload.opt("contribution") as? String ?: return null
    val contribution = runCatching { Base64.getDecoder().decode(text) }.getOrNull()?.takeIf { it.size == 32 } ?: return null
    val rotate = when (val value = payload.opt("rotate")) {
        null -> false
        is Boolean -> value
        else -> return null
    }
    return ConnectSetup(contribution, rotate)
}

fun connectSetupPayload(contribution: ByteArray, rotate: Boolean): ByteArray = JSONObject()
    .put("version", 1)
    .put("contribution", Base64.getEncoder().encodeToString(contribution))
    .put("rotate", rotate)
    .toString().toByteArray(Charsets.UTF_8)

fun connectSetupAckPayload(): ByteArray = JSONObject().put("version", 1).toString().toByteArray(Charsets.UTF_8)

private val ADDRESS_KINDS = setOf("lan", "vpn", "public6")
private val VPN_NAMES = setOf("tailscale", "other")
private val PAIR_CHECK = Regex("^[A-Za-z0-9_-]{11}$")

/**
 * connect.addresses: version 1, port 1 to 65535, at most 16 entries. Entries with an unknown kind
 * or an address that is not a usable IP literal are skipped; an unknown VPN name reads as none.
 */
fun decodeConnectAddresses(plaintext: ByteArray): ConnectAddresses? {
    if (plaintext.size > CONNECT_ADDRESSES_MAX_BYTES) return null
    val payload = strictJsonObject(plaintext) ?: return null
    if (jsonInteger(payload.opt("version")) != 1L) return null
    val port = jsonInteger(payload.opt("port"))?.takeIf { it in 1L..65_535L } ?: return null
    val list = payload.opt("addrs") as? JSONArray ?: return null
    if (list.length() > CONNECT_MAX_ADDRESSES) return null
    val pairCheck = when (val value = payload.opt("pairCheck")) {
        null -> null
        is String -> value.takeIf(PAIR_CHECK::matches) ?: return null
        else -> return null
    }
    val addrs = (0 until list.length()).mapNotNull { index ->
        val entry = list.opt(index) as? JSONObject ?: return@mapNotNull null
        val a = entry.opt("a") as? String ?: return@mapNotNull null
        val kind = entry.opt("kind") as? String ?: return@mapNotNull null
        if (kind !in ADDRESS_KINDS || !isUsableIpLiteral(a)) return@mapNotNull null
        ConnectAddress(a, kind, (entry.opt("vpn") as? String)?.takeIf { it in VPN_NAMES })
    }
    return ConnectAddresses(port.toInt(), addrs, pairCheck)
}

fun connectAddressesPayload(port: Int, addrs: List<ConnectAddress>, pairCheck: String?): ByteArray = JSONObject()
    .put("version", 1)
    .put("port", port)
    .put("addrs", JSONArray(addrs.take(CONNECT_MAX_ADDRESSES).map { address ->
        JSONObject().put("a", address.a).put("kind", address.kind).apply { address.vpn?.let { put("vpn", it) } }
    }))
    .apply { pairCheck?.let { put("pairCheck", it) } }
    .toString().toByteArray(Charsets.UTF_8)

/**
 * An IPv4 dotted quad or an IPv6 literal (never a name, never resolved) that is not loopback,
 * unspecified or multicast. Zone suffixes (`%wlan0`) are refused.
 */
fun isUsableIpLiteral(text: String): Boolean {
    val v4 = parseIPv4Literal(text)
    if (v4 != null) return usableIPv4(v4)
    val v6 = parseIPv6Literal(text) ?: return false
    if (v6.all { it == 0 }) return false
    if (v6.take(7).all { it == 0 } && v6[7] == 1) return false
    if ((v6[0] and 0xff00) == 0xff00) return false
    // IPv4-mapped: judge the IPv4 address.
    if (v6.take(5).all { it == 0 } && v6[5] == 0xffff) {
        return usableIPv4(intArrayOf(v6[6] shr 8, v6[6] and 0xff, v6[7] shr 8, v6[7] and 0xff))
    }
    return true
}

/** Not 0.0.0.0, not loopback (127/8), not multicast (224/4). */
private fun usableIPv4(b: IntArray): Boolean = !b.all { it == 0 } && b[0] != 127 && b[0] !in 224..239

private fun parseIPv4Literal(text: String): IntArray? {
    val parts = text.split('.')
    if (parts.size != 4) return null
    return IntArray(4) { index ->
        val part = parts[index]
        if (part.isEmpty() || part.length > 3 || part.any { !it.isDigit() } || (part.length > 1 && part[0] == '0')) return null
        part.toInt().takeIf { it <= 255 } ?: return null
    }
}

/** Eight 16-bit groups, or null; accepts `::` once and a trailing dotted IPv4. */
private fun parseIPv6Literal(text: String): IntArray? {
    if (text.isEmpty() || text.length > 45 || '%' in text || !text.contains(':')) return null
    if (text.any { !(it.isDigit() || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.') }) return null
    val halves = text.split("::")
    if (halves.size > 2) return null
    fun groups(part: String): List<Int>? {
        if (part.isEmpty()) return emptyList()
        val out = ArrayList<Int>()
        val pieces = part.split(':')
        pieces.forEachIndexed { index, piece ->
            if (index == pieces.lastIndex && piece.contains('.')) {
                val v4 = parseIPv4Literal(piece) ?: return null
                out += (v4[0] shl 8) or v4[1]
                out += (v4[2] shl 8) or v4[3]
            } else {
                if (piece.isEmpty() || piece.length > 4 || piece.contains('.')) return null
                out += piece.toInt(16)
            }
        }
        return out
    }
    val head = groups(halves[0]) ?: return null
    val tail = if (halves.size == 2) groups(halves[1]) ?: return null else emptyList()
    val total = head.size + tail.size
    return when {
        halves.size == 1 && total == 8 -> head.toIntArray()
        halves.size == 2 && total <= 7 -> (head + List(8 - total) { 0 } + tail).toIntArray()
        else -> null
    }
}

/** 0 when this device has the lower device ID (plain string order, as the duplicate rule). */
fun connectSide(localId: String, remoteId: String): Int = if (localId < remoteId) 0 else 1

/**
 * pairSecret = HKDF-SHA256(cLow || cHigh, salt "bridgey-pair-secret-v1", info idLow 0x00 idHigh, 32),
 * where cLow is the lower device ID's contribution.
 */
fun pairSecret(localId: String, remoteId: String, localContribution: ByteArray, remoteContribution: ByteArray): ByteArray {
    val localLow = localId < remoteId
    val (idLow, idHigh) = if (localLow) localId to remoteId else remoteId to localId
    val (cLow, cHigh) = if (localLow) localContribution to remoteContribution else remoteContribution to localContribution
    return hkdfSha256(cLow + cHigh, "bridgey-pair-secret-v1".toByteArray(), idLow.toByteArray() + byteArrayOf(0) + idHigh.toByteArray())
}

/** base64url(HMAC-SHA256(pairSecret, "bridgey-pair-check-v1")[0..8]): both sides compare it, never the secret. */
fun pairCheck(pairSecret: ByteArray): String =
    Base64.getUrlEncoder().withoutPadding().encodeToString(hmacSha256(pairSecret, "bridgey-pair-check-v1".toByteArray()).copyOf(8))

/** The tunnel transcript: bridgey-auth-v2 binds the identity signatures to the QUIC connection. */
fun tunnelTranscript(
    sessionId: String,
    initiatorId: String,
    responderId: String,
    initiatorEphemeralKey: String,
    responderEphemeralKey: String,
    exporter: String,
): ByteArray = listOf("bridgey-auth-v2", sessionId, initiatorId, responderId, initiatorEphemeralKey, responderEphemeralKey, exporter)
    .joinToString("\u0000").toByteArray()

internal fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray =
    Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)

internal fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
    val prk = hmacSha256(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
    val out = java.io.ByteArrayOutputStream()
    var block = ByteArray(0)
    var counter = 1
    while (out.size() < length) {
        block = hmacSha256(prk, block + info + byteArrayOf(counter.toByte()))
        out.write(block)
        counter++
    }
    return out.toByteArray().copyOf(length)
}

/** Constant-time comparison of two pair checks. */
fun samePairCheck(a: String?, b: String?): Boolean =
    a != null && b != null && MessageDigest.isEqual(a.toByteArray(), b.toByteArray())
