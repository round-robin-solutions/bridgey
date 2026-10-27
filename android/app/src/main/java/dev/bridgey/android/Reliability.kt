package dev.bridgey.android

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import kotlin.math.min

internal const val MAX_PROTOCOL_FRAME_BYTES = 65_536
internal const val MAX_TRANSFER_HISTORY = 20

internal class ProtocolFrameTooLargeException : IllegalArgumentException("Protocol frame is too large")

/**
 * One frame: the bytes up to LF, without one CR right before the LF (the Mac reads frames the same way,
 * docs/protocol-contract.md). Over [maxBytes] throws [ProtocolFrameTooLargeException]; invalid UTF-8
 * throws a CharacterCodingException.
 */
internal fun InputStream.readProtocolLine(maxBytes: Int = MAX_PROTOCOL_FRAME_BYTES): String? {
    val value = ByteArrayOutputStream(min(maxBytes, 1024))
    while (true) {
        when (val byte = read()) {
            -1 -> return value.takeIf { it.size() > 0 }?.toFrameString(maxBytes)
            '\n'.code -> return value.toFrameString(maxBytes)
            else -> {
                // One byte over the limit is allowed only for the CR that may end the frame.
                if (value.size() > maxBytes || (value.size() == maxBytes && byte != '\r'.code)) throw ProtocolFrameTooLargeException()
                value.write(byte)
            }
        }
    }
}

private fun ByteArrayOutputStream.toFrameString(maxBytes: Int): String {
    val bytes = toByteArray()
    val length = if (bytes.isNotEmpty() && bytes.last() == '\r'.code.toByte()) bytes.size - 1 else bytes.size
    if (length > maxBytes) throw ProtocolFrameTooLargeException()
    return Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes, 0, length))
        .toString()
}

internal fun heartbeatExpired(
    supported: Boolean,
    lastReceivedAtMillis: Long,
    nowMillis: Long,
    timeoutMillis: Long = ReconnectPolicy.HEARTBEAT_TIMEOUT_MILLIS,
): Boolean = supported && nowMillis - lastReceivedAtMillis >= timeoutMillis

internal fun recoverInterruptedTransfers(
    transfers: Map<String, FileTransferState>,
): Map<String, FileTransferState> = transfers
    .mapValues { (_, transfer) ->
        // Folders report their own interruption (their journal decides whether they resume).
        if (transfer.active && transfer.kind == TransferKind.FILE) transfer.copy(
            status = "Transfer interrupted — reconnect to retry",
            active = false,
            progressPercent = null,
            queued = false,
            outcome = TransferEnd.INTERRUPTED,
        ) else transfer
    }
    .values
    .sortedByDescending(FileTransferState::startedAtMillis)
    .take(MAX_TRANSFER_HISTORY)
    .associateBy(FileTransferState::id)

/** A short reason token for a socket failure, for logs and diagnostics. */
internal fun socketDropReason(error: Throwable): String {
    val message = error.message.orEmpty().lowercase()
    return when {
        error is java.net.SocketTimeoutException -> "timed_out"
        error is java.net.NoRouteToHostException || "host is unreachable" in message || "ehostunreach" in message -> "host_unreachable"
        "network is unreachable" in message || "enetunreach" in message -> "network_unreachable"
        error is java.net.ConnectException && "refused" in message -> "refused"
        "reset" in message -> "reset_by_peer"
        "broken pipe" in message -> "broken_pipe"
        "software caused connection abort" in message -> "aborted"
        "socket closed" in message -> "closed"
        error is ProtocolFrameTooLargeException -> "frame_too_large"
        error is java.nio.charset.CharacterCodingException || error is org.json.JSONException -> "protocol_error"
        error is java.net.UnknownHostException -> "unknown_host"
        else -> error.javaClass.simpleName.lowercase().ifEmpty { "error" }
    }
}
