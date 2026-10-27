package dev.bridgey.android

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Protocol 2 session security (v0.10 security review, docs/security-review-0.10.md):
 *
 * - A first pairing commits to the initiator's ephemeral key before the responder answers, and the six-digit
 *   code comes from its own HKDF label over both keys. The party that answers can no longer pick its key to
 *   make two codes match (the man-in-the-middle grind on the old code).
 * - When both ends speak protocol 2, every frame after pairing carries `tag`: an HMAC over the sender's device
 *   ID and every envelope field, under a key derived from the session key. Replaying a ciphertext under a new
 *   messageId, relabelling its kind or reflecting it back to its sender fails the tag.
 * - A device that once connected with protocol 2 is pinned to it, so a stripped `protocolVersion` cannot
 *   downgrade a later session.
 *
 * The Mac has the same code in SessionSecurity.swift; protocol/test-vectors/crypto-v1.properties pins both.
 */
internal object SessionSecurity {
    const val PROTOCOL_VERSION = 2L
    private const val COMMIT_LABEL = "bridgey-commit-v2"
    private const val SAS_LABEL = "bridgey-sas-v2"
    private const val ENVELOPE_LABEL = "bridgey-envelope-v2"

    /** Base64 SHA-256 over the label, the session ID and the initiator's ephemeral public key (base64 text). */
    fun commitment(sessionId: String, publicKey: String): String =
        base64(MessageDigest.getInstance("SHA-256").digest(lengthPrefixed(listOf(COMMIT_LABEL, sessionId, publicKey))))

    fun commitmentMatches(commitment: String, sessionId: String, publicKey: String): Boolean = runCatching {
        MessageDigest.isEqual(java.util.Base64.getDecoder().decode(commitment), java.util.Base64.getDecoder().decode(commitment(sessionId, publicKey)))
    }.getOrDefault(false)

    /** The protocol 2 code: HKDF-Expand(prk, label + both ephemeral keys), never bytes of the session key. */
    fun sasCode(prk: ByteArray, initiatorKey: String, responderKey: String): String {
        val info = lengthPrefixed(listOf(SAS_LABEL, initiatorKey, responderKey)) + byteArrayOf(1)
        val output = hmac(prk, info)
        val number = ((output[0].toLong() and 0xff) shl 24) or ((output[1].toLong() and 0xff) shl 16) or
            ((output[2].toLong() and 0xff) shl 8) or (output[3].toLong() and 0xff)
        return (number % 1_000_000).toString().padStart(6, '0')
    }

    fun envelopeKey(sessionKey: ByteArray): ByteArray = hmac(sessionKey, ENVELOPE_LABEL.toByteArray(Charsets.UTF_8))

    /** Base64 HMAC-SHA-256 over the sender's device ID and every envelope field of [message] except `tag`. */
    fun tag(envelopeKey: ByteArray, senderDeviceId: String, message: Message): String =
        base64(hmac(envelopeKey, tagInput(senderDeviceId, message)))

    fun tagMatches(envelopeKey: ByteArray, senderDeviceId: String, message: Message): Boolean {
        val received = message.tag ?: return false
        return runCatching {
            MessageDigest.isEqual(java.util.Base64.getDecoder().decode(received), hmac(envelopeKey, tagInput(senderDeviceId, message)))
        }.getOrDefault(false)
    }

    /** Pairing frames run before there is a session key; everything else needs an authenticated session. */
    fun allowedBeforeAuthentication(kind: String): Boolean = kind.startsWith("pairing.")

    private fun tagInput(senderDeviceId: String, message: Message): ByteArray = lengthPrefixed(
        listOf(
            ENVELOPE_LABEL, senderDeviceId, message.kind, message.sessionId, message.deviceId, message.deviceName,
            message.publicKey, message.identityKey, message.proof, message.signature, message.messageId,
            message.nonce, message.ciphertext, message.transferId, message.sequence?.toString(), message.targetDeviceId,
            message.commitment, message.protocolVersion?.toString(),
        ),
    )

    /** Each field as a 4-byte big-endian length and its UTF-8 bytes; an absent field is length 0xFFFFFFFF. */
    internal fun lengthPrefixed(fields: List<String?>): ByteArray {
        val out = ByteArrayOutputStream()
        for (field in fields) {
            val bytes = field?.toByteArray(Charsets.UTF_8)
            val length = bytes?.size ?: -1
            out.write(length ushr 24 and 0xff)
            out.write(length ushr 16 and 0xff)
            out.write(length ushr 8 and 0xff)
            out.write(length and 0xff)
            bytes?.let(out::write)
        }
        return out.toByteArray()
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)

    private fun base64(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)
}

/** A peer-supplied device name made safe to show: no control or bidi characters, at most 64 characters. */
internal fun sanitizedPeerName(name: String?, fallback: String): String {
    val cleaned = name.orEmpty().filterNot { it.isISOControl() || it in BIDI_CONTROLS }.trim()
    val bounded = if (cleaned.length <= MAX_PEER_NAME_CHARS) cleaned else cleaned.take(MAX_PEER_NAME_CHARS).trimEnd()
    return bounded.ifEmpty { fallback }
}

internal const val MAX_PEER_NAME_CHARS = 64
private val BIDI_CONTROLS = setOf(
    '\u200E', '\u200F', '\u061C', '\u202A', '\u202B', '\u202C', '\u202D', '\u202E', '\u2066', '\u2067', '\u2068', '\u2069',
)

/**
 * Connections that have not authenticated yet: at most [maxTotal] in all and [maxPerHost] from one address, so a
 * host on the network cannot hold every reader thread open.
 */
internal fun admitsPendingConnection(pendingHosts: List<String?>, host: String?, maxTotal: Int = 8, maxPerHost: Int = 3): Boolean =
    pendingHosts.size < maxTotal && (host == null || pendingHosts.count { it == host } < maxPerHost)

/**
 * Pairing prompts started by another device: at most [limit] per [windowMillis]. Each prompt is a fresh random
 * code, so this keeps a device on the network from cycling through codes until one matches.
 */
internal class InboundPairingLimiter(private val limit: Int = 3, private val windowMillis: Long = 60_000L) {
    private val starts = ArrayDeque<Long>()

    @Synchronized fun tryAcquire(nowMillis: Long): Boolean {
        while (starts.isNotEmpty() && nowMillis - starts.first() >= windowMillis) starts.removeFirst()
        if (starts.size >= limit) return false
        starts.addLast(nowMillis)
        return true
    }
}
