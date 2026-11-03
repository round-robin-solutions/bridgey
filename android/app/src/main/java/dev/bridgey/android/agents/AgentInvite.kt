package dev.bridgey.android.agents

import dev.bridgey.android.connect.hmacSha256
import dev.bridgey.android.jsonInteger
import dev.bridgey.android.sanitizedPeerName
import dev.bridgey.android.strictJsonObject
import java.security.MessageDigest
import java.util.Base64

/*
 * Remote pairing by invite (docs/protocol.md, agent devices): `bridgey pair` shows
 * `bridgey://pair#<base64url JSON>`; the phone opens it, the Connect anywhere core finds the inviter through the
 * invite's one rendezvous ID, and a protocol 2 first pairing runs inside that tunnel.
 */

const val INVITE_SCHEME_PREFIX = "bridgey://pair#"
const val INVITE_MAX_BYTES = 1_024
const val INVITE_MAX_AHEAD_MILLIS = 10L * 60_000

/** Clock skew allowed past the 10 minutes, as the inviter's clock may run a little ahead of the phone's. */
const val INVITE_SKEW_MILLIS = 60_000L

/** The core's label for an invite peer: `invite:<rdv>`. */
const val INVITE_PEER_PREFIX = "invite:"

class AgentInvite(
    /** The 32 random bytes; never logged or shown. */
    val secret: ByteArray,
    val controlUrl: String,
    /** The inviter's name, made safe to show (at most 64 characters). */
    val name: String,
    val platform: String,
    val expiresAtMillis: Long,
) {
    val rdv: String = inviteRdv(secret)
    val peerLabel: String get() = INVITE_PEER_PREFIX + rdv
}

sealed interface InviteParse {
    data class Ok(val invite: AgentInvite) : InviteParse

    /** Not a Bridgey invite, or one this version cannot read. */
    data object Invalid : InviteParse

    /** Past its expiry (or more than 10 minutes ahead of this phone's clock). */
    data object Expired : InviteParse

    /** Made for another control service than this phone's (or this build has none). */
    data object OtherService : InviteParse
}

/**
 * Reads an invite link (or its fragment, as pasted) for a phone whose control service is [ownControlUrl]: version 1,
 * a 32-byte secret, the same control URL, a name of at most 64 characters, platform `cli`, an expiry at most 10
 * minutes ahead and not past, and at most 1,024 bytes in all.
 */
fun parseInvite(text: String, ownControlUrl: String, nowMillis: Long): InviteParse {
    val trimmed = text.trim()
    if (trimmed.toByteArray(Charsets.UTF_8).size > INVITE_MAX_BYTES) return InviteParse.Invalid
    val fragment = when {
        trimmed.startsWith(INVITE_SCHEME_PREFIX, ignoreCase = true) -> trimmed.substring(INVITE_SCHEME_PREFIX.length)
        trimmed.contains('#') -> return InviteParse.Invalid
        else -> trimmed
    }
    if (fragment.isEmpty() || fragment.any { !(it.isLetterOrDigit() && it.code < 128) && it != '-' && it != '_' && it != '=' }) return InviteParse.Invalid
    val json = runCatching { Base64.getUrlDecoder().decode(fragment.trimEnd('=')) }.getOrNull() ?: return InviteParse.Invalid
    return parseInviteJson(json, ownControlUrl, nowMillis)
}

/** The invite's JSON (the decoded fragment); see [parseInvite]. */
fun parseInviteJson(json: ByteArray, ownControlUrl: String, nowMillis: Long): InviteParse {
    val payload = strictJsonObject(json) ?: return InviteParse.Invalid
    if (jsonInteger(payload.opt("v")) != 1L) return InviteParse.Invalid
    val secretText = payload.opt("s") as? String ?: return InviteParse.Invalid
    val secret = runCatching { Base64.getUrlDecoder().decode(secretText.trimEnd('=')) }.getOrNull()?.takeIf { it.size == 32 } ?: return InviteParse.Invalid
    val control = payload.opt("c") as? String ?: return InviteParse.Invalid
    val name = payload.opt("n") as? String ?: return InviteParse.Invalid
    if (name.codePointCount(0, name.length) > 64) return InviteParse.Invalid
    val platform = payload.opt("p") as? String ?: return InviteParse.Invalid
    // Agents only in this version: an invite from anything else would pair a device with the usual permissions.
    if (platform != AGENT_PLATFORM) return InviteParse.Invalid
    val expirySeconds = jsonInteger(payload.opt("x")) ?: return InviteParse.Invalid
    if (ownControlUrl.isEmpty() || control != ownControlUrl) return InviteParse.OtherService
    val expiresAt = expirySeconds * 1_000
    if (expiresAt <= nowMillis || expiresAt > nowMillis + INVITE_MAX_AHEAD_MILLIS + INVITE_SKEW_MILLIS) return InviteParse.Expired
    return InviteParse.Ok(AgentInvite(secret, control, sanitizedPeerName(name, "Agent"), platform, expiresAt))
}

/** base64url(HMAC-SHA256(secret, "bridgey-invite-rdv-v1")[0..16]): the one rendezvous ID of an invite. */
fun inviteRdv(secret: ByteArray): String =
    Base64.getUrlEncoder().withoutPadding().encodeToString(hmacSha256(secret, "bridgey-invite-rdv-v1".toByteArray()).copyOf(16))

/** base64(SHA-256(secret)), standard base64: what the pairing transcript appends. */
fun inviteHash(secret: ByteArray): String = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(secret))

/** The tunnel's bridgey-auth-v2 transcript with the invite appended: `\0` and [inviteHash]. */
fun inviteTranscript(tunnelTranscript: ByteArray, secret: ByteArray): ByteArray =
    tunnelTranscript + byteArrayOf(0) + inviteHash(secret).toByteArray(Charsets.UTF_8)
