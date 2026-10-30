package dev.bridgey.android

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.launch

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
    private const val FAST_FRAME_KEY_LABEL = "bridgey-fast-frame-key-v2"

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

    /** The AES-GCM key for binary frames (draft files_fast_draft1, FastTransfer.kt), kept apart from the session key. */
    fun fastFrameKey(sessionKey: ByteArray): ByteArray = hmac(sessionKey, FAST_FRAME_KEY_LABEL.toByteArray(Charsets.UTF_8))

    /**
     * Base64 HMAC-SHA-256 over the sender's device ID and every envelope field of [message] except `tag`. An empty
     * field counts as absent, as the decoders read it.
     */
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
            message.commitment, message.protocolVersion?.toString(), message.reason,
        ).map { it?.takeIf(String::isNotEmpty) },
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

/**
 * Where one end of a pairing stands, for [PairingRules]: who dialled, whether this end committed to its key,
 * whether it holds the other end's commitment, and whether the session key exists yet.
 */
internal data class PairingPosition(
    val initiatedLocally: Boolean,
    val committed: Boolean,
    val holdsRemoteCommitment: Boolean,
    val hasSessionKey: Boolean,
)

/**
 * Which pairing frames each end may act on. The order is what keeps the code honest: the end that answers fixes
 * its key before the dialler's key is revealed, and the dialler committed to its key before it saw the answer.
 */
internal object PairingRules {
    /** Only the end that was dialled takes an offer, once. */
    fun acceptsOffer(p: PairingPosition) = !p.initiatedLocally && !p.hasSessionKey && !p.holdsRemoteCommitment

    /** Only the dialler takes an answer. An answer sent to the dialled end would replace the reveal. */
    fun acceptsAnswer(p: PairingPosition) = p.initiatedLocally && !p.holdsRemoteCommitment && !p.hasSessionKey

    /** Only the dialled end takes a reveal, and only after a committed offer. */
    fun acceptsReveal(p: PairingPosition) = !p.initiatedLocally && p.holdsRemoteCommitment && !p.hasSessionKey

    /**
     * Whether an untrusted device may get the code prompt: only when the dialler committed to its key. A dialler that
     * did not commit (a reconnect to what it thought was a trusted device) never prompts, and neither does the dialled
     * end after a plain protocol 1 offer: a man in the middle could answer that offer's sender with a key ground to
     * match the code it already saw from this end.
     */
    fun mayPromptUntrusted(p: PairingPosition) = if (p.initiatedLocally) p.committed else p.holdsRemoteCommitment

    /**
     * An answered offer costs one [InboundPairingLimiter] slot, whether or not it ever reaches the code, so an attacker
     * cannot try codes faster by giving up before the reveal. Only a plain reconnect from a trusted device is free: a
     * committed offer under a trusted device ID (a one-sided Forget) is a new pairing and pays like any other.
     */
    fun chargesInboundAttempt(initiatedLocally: Boolean, trusted: Boolean, committedOffer: Boolean) =
        !initiatedLocally && (!trusted || committedOffer)

    /**
     * Confirm without a prompt only on a plain reconnect: the device is trusted and neither end committed. A committed
     * pairing under a trusted ID prompts on both ends; pairing.confirm still checks the pinned identity key.
     */
    fun autoConfirms(p: PairingPosition, trusted: Boolean) = trusted && !p.committed && !p.holdsRemoteCommitment

    /**
     * What the dialled end does with a pairing.offer, before it answers or charges the limiter. Malformed (no device
     * ID, or neither a key nor a commitment, or a commitment from protocol 1) closes the connection. An offer without
     * a commitment from a device this end does not trust is refused: an older Bridgey ([OfferVerdict.NEEDS_PROTOCOL_2])
     * or a protocol 2 device that still trusts this end after a one-sided Forget ([OfferVerdict.NOT_TRUSTED]). A
     * committed offer is answered only while pairing is armed here.
     */
    fun offerVerdict(deviceId: String?, publicKey: String?, commitment: String?, protocolVersion: Long, trusted: Boolean, armed: Boolean): OfferVerdict {
        if (deviceId.isNullOrEmpty() || (publicKey == null && commitment == null)) return OfferVerdict.MALFORMED
        val committed = publicKey == null
        if (committed && protocolVersion < SessionSecurity.PROTOCOL_VERSION) return OfferVerdict.MALFORMED
        if (!committed && !trusted) {
            return if (protocolVersion < SessionSecurity.PROTOCOL_VERSION) OfferVerdict.NEEDS_PROTOCOL_2 else OfferVerdict.NOT_TRUSTED
        }
        if (committed && !armed) return OfferVerdict.NOT_ARMED
        return OfferVerdict.ANSWER
    }

    /**
     * Which frames reach the session. Before authentication only pairing frames do; a pairing.cancel that carries a
     * tag must verify when this end already has the envelope key. After authentication every pairing frame is dropped
     * except pairing.cancel on this session, and that one needs a valid tag when the session has an envelope key.
     * Other frames need an authenticated session and, on protocol 2, a valid tag.
     */
    fun admitFrame(kind: String, authenticated: Boolean, sameSession: Boolean, hasEnvelopeKey: Boolean, tagged: Boolean, tagValid: () -> Boolean): FrameVerdict {
        if (SessionSecurity.allowedBeforeAuthentication(kind)) {
            if (!authenticated) {
                return if (kind == CANCEL && tagged && hasEnvelopeKey && !tagValid()) FrameVerdict.BAD_TAG else FrameVerdict.ADMIT
            }
            if (kind != CANCEL) return FrameVerdict.PAIRING_AFTER_AUTHENTICATION
            if (!sameSession) return FrameVerdict.UNAUTHENTICATED
            return if (hasEnvelopeKey && !tagValid()) FrameVerdict.BAD_TAG else FrameVerdict.ADMIT
        }
        if (!authenticated || !sameSession) return FrameVerdict.UNAUTHENTICATED
        return if (hasEnvelopeKey && !tagValid()) FrameVerdict.BAD_TAG else FrameVerdict.ADMIT
    }

    /** The 120 s code timer ran out: who did not confirm, from this end's flags. */
    fun timeoutFailure(localConfirmed: Boolean, remoteConfirmed: Boolean): PairingFailure = when {
        localConfirmed && !remoteConfirmed -> PairingFailure.TIMEOUT_REMOTE
        remoteConfirmed && !localConfirmed -> PairingFailure.TIMEOUT_LOCAL
        else -> PairingFailure.TIMEOUT_NEITHER
    }

    /**
     * Whether this end's dial commits to its key (a first pairing). Only a pairing the user started can: a background
     * reconnect never commits, so it can never turn into a code prompt (for example after the device was forgotten).
     */
    fun diallerCommits(userStarted: Boolean, targetTrusted: Boolean) = userStarted && !targetTrusted

    /**
     * Whether a device the user disconnected keeps a finished handshake closed. A pairing the user went through on
     * purpose (the code was shown, or the user started it) wins and lifts the hold; a reconnect of its own does not.
     */
    fun heldBlocksCompletion(held: Boolean, deliberate: Boolean) = held && !deliberate

    /** A background reconnect goes out only to a device that is still trusted; otherwise it closes before any offer. */
    fun backgroundDialAllowed(targetTrusted: Boolean) = targetTrusted

    /**
     * Whether this dialler is still before the other end's answer: nothing answered, no session key, no code shown.
     * Only then can `not_armed` be true, and only then may a dropped attempt be retried while waiting for Allow pairing.
     */
    fun beforeAnswer(answered: Boolean, hasSessionKey: Boolean, prompted: Boolean) = !answered && !hasSessionKey && !prompted

    /**
     * What a received pairing.cancel means for this end's pairing. Null for `not_armed` before the answer: the dialler
     * waits for Allow pairing and retries instead of failing. A `not_armed` after the answer or the code is a lie (an
     * end that answered was armed), so it reads as cancelled and is never retried. [prompted]: this end showed the
     * code (a timeout maps with its own flags).
     */
    fun cancelFailure(
        reason: String?,
        localConfirmed: Boolean,
        remoteConfirmed: Boolean,
        prompted: Boolean,
        answered: Boolean = false,
        hasSessionKey: Boolean = false,
    ): PairingFailure? =
        when (PairingCancelReason.normalized(reason)) {
            PairingCancelReason.MISMATCH -> PairingFailure.MISMATCH_REMOTE
            PairingCancelReason.TIMEOUT -> if (prompted) timeoutFailure(localConfirmed, remoteConfirmed) else PairingFailure.TIMEOUT
            PairingCancelReason.BUSY -> PairingFailure.BUSY
            PairingCancelReason.RATE_LIMITED -> PairingFailure.RATE_LIMITED
            PairingCancelReason.NEEDS_PROTOCOL_2 -> PairingFailure.OLD_VERSION
            PairingCancelReason.NOT_ARMED -> if (beforeAnswer(answered, hasSessionKey, prompted)) null else PairingFailure.CANCELLED_REMOTE
            else -> PairingFailure.CANCELLED_REMOTE
        }

    private const val CANCEL = "pairing.cancel"
}

/** What the dialled end does with a pairing.offer; see [PairingRules.offerVerdict]. */
internal enum class OfferVerdict { MALFORMED, NEEDS_PROTOCOL_2, NOT_TRUSTED, NOT_ARMED, ANSWER }

/** Whether a frame reaches the session; see [PairingRules.admitFrame]. */
internal enum class FrameVerdict { ADMIT, UNAUTHENTICATED, BAD_TAG, PAIRING_AFTER_AUTHENTICATION }

/** Why a pairing.cancel was sent (its `reason`, at most 32 bytes). Unknown or absent reads as [CANCELLED]. */
internal object PairingCancelReason {
    const val MISMATCH = "mismatch"
    const val CANCELLED = "cancelled"
    const val TIMEOUT = "timeout"
    const val BUSY = "busy"
    const val RATE_LIMITED = "rate_limited"
    const val NOT_ARMED = "not_armed"
    const val NEEDS_PROTOCOL_2 = "needs_protocol_2"
    const val NOT_TRUSTED = "not_trusted"
    private val known = setOf(MISMATCH, CANCELLED, TIMEOUT, BUSY, RATE_LIMITED, NOT_ARMED, NEEDS_PROTOCOL_2, NOT_TRUSTED)

    fun normalized(reason: String?): String = reason?.takeIf { it in known } ?: CANCELLED
}

/**
 * Whether this end answers committed offers: armed for [windowMillis] by Allow pairing (each call restarts the
 * window), and held on while a pairing screen is visible. [clock] is monotonic (elapsedRealtime), so changing the
 * wall clock cannot stretch the window.
 */
internal class PairingArming(private val clock: () -> Long, private val windowMillis: Long = 120_000L) {
    private var armedUntil: Long? = null
    private var holds = 0

    @Synchronized fun arm() {
        armedUntil = clock() + windowMillis
    }

    @Synchronized fun disarm() {
        armedUntil = null
    }

    /** A pairing screen appeared (true) or went away (false). Screens nest, so holds count. */
    @Synchronized fun hold(on: Boolean) {
        holds = if (on) holds + 1 else (holds - 1).coerceAtLeast(0)
    }

    @Synchronized fun held(): Boolean = holds > 0

    @Synchronized fun isArmed(): Boolean = holds > 0 || remainingMillis() > 0

    /** Seconds left on Allow pairing's window, rounded up; 0 when it is not running (a held screen has no countdown). */
    @Synchronized fun remainingSeconds(): Int = ((remainingMillis() + 999) / 1_000).toInt()

    private fun remainingMillis(): Long {
        val until = armedUntil ?: return 0
        val left = until - clock()
        if (left <= 0) armedUntil = null
        return left.coerceAtLeast(0)
    }
}

/**
 * The one pairing that owns the code prompt. Claiming it (the busy check, the assignment and the published state)
 * happens in one step, and the prompt's buttons act only on the session whose random token they were shown with,
 * so a second pairing that arrives while the first prompt is on screen can never be confirmed by its button.
 */
internal class PairingSlot<S : Any> {
    @Volatile var current: S? = null
        private set

    @Synchronized fun set(session: S?) {
        current = session
    }

    /** [session] takes the prompt unless another live pairing holds it ([busy]); [then] runs inside the same step. */
    @Synchronized fun claim(session: S, busy: (S) -> Boolean, then: () -> Unit): Boolean {
        val existing = current
        if (existing != null && existing !== session && busy(existing)) return false
        current = session
        then()
        return true
    }

    /** The session the prompt with [token] belongs to, if it still owns the prompt. */
    @Synchronized fun withToken(token: String, tokenOf: (S) -> String): S? = current?.takeIf { tokenOf(it) == token }

    /** As [withToken], and the prompt is released. */
    @Synchronized fun takeWithToken(token: String, tokenOf: (S) -> String): S? = withToken(token, tokenOf)?.also { current = null }

    /** Releases the prompt if [session] still holds it; [then] runs inside the same step. */
    @Synchronized fun releaseIf(session: S, then: () -> Unit = {}): Boolean {
        if (current !== session) return false
        current = null
        then()
        return true
    }

    /** Runs [block] in the slot's step, for state that must change together with the owner. */
    @Synchronized fun <T> locked(block: () -> T): T = block()
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
 * Answered pairing offers from other devices: at most [perMinute] a minute and [perHour] an hour, on [clock]
 * (monotonic). Each answer is a fresh random code, so this keeps a device on the network from cycling through codes
 * until one matches; the hourly cap bounds a patient attacker.
 */
internal class InboundPairingLimiter(
    private val clock: () -> Long,
    private val perMinute: Int = 3,
    private val perHour: Int = 10,
) {
    private val starts = ArrayDeque<Long>()

    @Synchronized fun tryAcquire(nowMillis: Long = clock()): Boolean {
        while (starts.isNotEmpty() && nowMillis - starts.first() >= HOUR_MILLIS) starts.removeFirst()
        if (starts.size >= perHour) return false
        if (starts.count { nowMillis - it < MINUTE_MILLIS } >= perMinute) return false
        starts.addLast(nowMillis)
        return true
    }

    private companion object {
        const val MINUTE_MILLIS = 60_000L
        const val HOUR_MILLIS = 3_600_000L
    }
}

/**
 * A pending session's own deadline, apart from its reads: a peer that trickles bytes without ever ending a frame
 * keeps the read busy, so this checks [expired] every [pollMillis] until [settled] and runs [onExpire] once.
 */
internal fun kotlinx.coroutines.CoroutineScope.launchPendingWatchdog(
    settled: () -> Boolean,
    expired: () -> Boolean,
    onExpire: () -> Unit,
    pollMillis: Long = 1_000L,
): kotlinx.coroutines.Job = launch {
    while (!settled()) {
        if (expired()) {
            onExpire()
            return@launch
        }
        kotlinx.coroutines.delay(pollMillis)
    }
}
