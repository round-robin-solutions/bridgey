package dev.bridgey.android.sms

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.PhoneNumberUtils
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Base64
import java.io.ByteArrayOutputStream

/*
 * Reads the SMS and MMS provider, contacts and SIMs for Text messages. Read only: Bridgey never
 * writes the provider and never becomes the default SMS app. Nothing is cached beyond one request,
 * and nothing read here is logged.
 */
class SmsProvider(private val context: Context) {
    val resolver: ContentResolver = context.contentResolver

    fun granted(permission: String): Boolean = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    val canRead: Boolean get() = granted(Manifest.permission.READ_SMS)
    val canSend: Boolean get() = granted(Manifest.permission.SEND_SMS)
    val canReadContacts: Boolean get() = granted(Manifest.permission.READ_CONTACTS)

    /** The newest _id of each table (0 when empty or not allowed). */
    fun cursor(): SmsCursor {
        if (!canRead) return SmsCursor(0, 0)
        return SmsCursor(maxId(Telephony.Sms.CONTENT_URI), maxId(Telephony.Mms.CONTENT_URI))
    }

    private fun maxId(uri: Uri): Long = query(uri, arrayOf("_id"), null, null, "_id DESC")?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else 0L
    } ?: 0L

    /** How many rows both tables hold after [since]. */
    fun countNewer(since: SmsCursor): Long =
        count(Telephony.Sms.CONTENT_URI, "_id > ?", arrayOf(since.sms.toString())) +
            count(Telephony.Mms.CONTENT_URI, "_id > ?", arrayOf(since.mms.toString()))

    private fun count(uri: Uri, selection: String, args: Array<String>): Long =
        query(uri, arrayOf("_id"), selection, args, null)?.use { it.count.toLong() } ?: 0L

    // MARK: Threads

    /** The newest [limit] conversations (plus one, to tell whether there are more) before [before]. */
    fun threads(before: Long?, limit: Int): Pair<List<SmsThread>, Boolean> {
        val uri = Uri.parse("content://mms-sms/conversations?simple=true")
        val selection = before?.let { "date < ?" }
        val args = before?.let { arrayOf(it.toString()) }
        data class Row(val id: Long, val date: Long, val recipients: List<Long>, val snippet: String)
        val rows = ArrayList<Row>()
        var more = false
        query(uri, arrayOf("_id", "date", "recipient_ids", "snippet"), selection, args, "date DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                if (rows.size >= limit) { more = true; break }
                val recipients = cursor.getString(2).orEmpty().split(' ').mapNotNull { it.trim().toLongOrNull() }
                rows += Row(cursor.getLong(0), cursor.getLong(1), recipients, cursor.getString(3).orEmpty())
            }
        }
        if (rows.isEmpty()) return emptyList<SmsThread>() to false
        val addresses = canonicalAddresses(rows.flatMap { it.recipients }.toSet())
        val ids = rows.map { it.id }
        val unread = unreadCounts(ids)
        val subIds = lastSubIds(ids)
        val names = NameLookup()
        val threads = rows.map { row ->
            val participants = row.recipients.mapNotNull { addresses[it] }.take(SmsLimits.PARTICIPANTS_MAX).map { SmsParticipant(it, names.name(it)) }
            SmsThread(row.id, participants, row.snippet, normalizeDate(row.date), unread[row.id] ?: 0, subIds[row.id])
        }.filter { it.participants.isNotEmpty() }
        return threads to more
    }

    /** One conversation's participants (numbers only). */
    fun participants(threadId: Long): List<String> {
        val uri = Uri.parse("content://mms-sms/conversations?simple=true")
        val recipients = query(uri, arrayOf("_id", "recipient_ids"), "_id = ?", arrayOf(threadId.toString()), null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(1).orEmpty().split(' ').mapNotNull { it.trim().toLongOrNull() } else null
        } ?: return emptyList()
        val addresses = canonicalAddresses(recipients.toSet())
        return recipients.mapNotNull { addresses[it] }
    }

    /** The thread a number belongs to, if any, without creating one. */
    fun threadForAddress(address: String): Long? {
        val uri = Uri.parse("content://mms-sms/conversations?simple=true")
        val canonical = HashMap<Long, String>()
        query(Uri.parse("content://mms-sms/canonical-addresses"), arrayOf("_id", "address"), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) cursor.getString(1)?.let { canonical[cursor.getLong(0)] = it }
        }
        val match = canonical.filterValues { sameNumber(normalizeSmsAddress(it), address) }.keys
        if (match.isEmpty()) return null
        return query(uri, arrayOf("_id", "recipient_ids"), null, null, "date DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val ids = cursor.getString(1).orEmpty().split(' ').mapNotNull { it.trim().toLongOrNull() }
                if (ids.size == 1 && ids[0] in match) return@use cursor.getLong(0)
            }
            null
        }
    }

    private fun canonicalAddresses(ids: Set<Long>): Map<Long, String> {
        if (ids.isEmpty()) return emptyMap()
        val result = HashMap<Long, String>()
        val uri = Uri.parse("content://mms-sms/canonical-addresses")
        val selection = "_id IN (${ids.joinToString(",")})"
        val rows = query(uri, arrayOf("_id", "address"), selection, null, null)
            ?: query(uri, arrayOf("_id", "address"), null, null, null)
        rows?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                if (id in ids) cursor.getString(1)?.let { result[id] = it }
            }
        }
        return result
    }

    private fun unreadCounts(threadIds: List<Long>): Map<Long, Int> {
        val counts = HashMap<Long, Int>()
        val inThreads = "thread_id IN (${threadIds.joinToString(",")})"
        query(Telephony.Sms.CONTENT_URI, arrayOf("thread_id"), "read = 0 AND type = 1 AND $inThreads", null, null)?.use { cursor ->
            while (cursor.moveToNext()) counts.merge(cursor.getLong(0), 1, Int::plus)
        }
        query(Telephony.Mms.CONTENT_URI, arrayOf("thread_id"), "read = 0 AND msg_box = 1 AND $inThreads", null, null)?.use { cursor ->
            while (cursor.moveToNext()) counts.merge(cursor.getLong(0), 1, Int::plus)
        }
        return counts
    }

    /** The SIM each conversation last used (SMS only; older phones have no sub_id column). */
    private fun lastSubIds(threadIds: List<Long>): Map<Long, Int> {
        val result = HashMap<Long, Int>()
        query(Telephony.Sms.CONTENT_URI, arrayOf("thread_id", "sub_id"), "thread_id IN (${threadIds.joinToString(",")})", null, "date DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val thread = cursor.getLong(0)
                if (thread !in result && !cursor.isNull(1)) cursor.getInt(1).takeIf { it >= 0 }?.let { result[thread] = it }
            }
        }
        return result
    }

    fun lastSubId(threadId: Long): Int? = lastSubIds(listOf(threadId))[threadId]

    // MARK: Messages

    /** Candidates for one conversation page: up to [limit] + 20 of each table at or before [before]. */
    fun conversation(threadId: Long, before: MessageKey?, limit: Int): Pair<List<SmsMessage>, Boolean> {
        val take = limit + 20
        val smsSelection = buildString {
            append("thread_id = ? AND type != 3")
            if (before != null) append(" AND date <= ${before.date}")
        }
        val (sms, smsFull) = smsRows(smsSelection, arrayOf(threadId.toString()), "date DESC, _id DESC", take)
        val mmsSelection = buildString {
            append("thread_id = ? AND msg_box != 3")
            if (before != null) append(" AND date <= ${before.date / 1000 + 1}")
        }
        val (mms, mmsFull) = mmsRows(mmsSelection, arrayOf(threadId.toString()), "date DESC, _id DESC", take)
        return conversationPage(sms + mms, before, limit, smsFull || mmsFull)
    }

    /** Rows after [since] in each table, ascending _id, at most [limit] each. */
    fun newer(since: SmsCursor, limit: Int): Triple<List<SmsMessage>, List<SmsMessage>, Boolean> {
        val (sms, smsFull) = smsRows("_id > ? AND type != 3", arrayOf(since.sms.toString()), "_id ASC", limit)
        val (mms, mmsFull) = mmsRows("_id > ? AND msg_box != 3", arrayOf(since.mms.toString()), "_id ASC", limit)
        // An unknown row is skipped, so fullness counts the rows read, not the messages kept.
        return Triple(sms, mms, smsFull || mmsFull)
    }

    /** Recent inbox SMS, newest first, for matching a notification to its conversation. */
    fun recentInbox(since: Long): List<InboxCandidate> {
        val names = NameLookup()
        val result = ArrayList<InboxCandidate>()
        query(Telephony.Sms.CONTENT_URI, arrayOf("thread_id", "address", "body", "date"), "type = 1 AND date >= ?", arrayOf(since.toString()), "date DESC")?.use { cursor ->
            while (cursor.moveToNext() && result.size < 50) {
                val address = cursor.getString(1).orEmpty()
                result += InboxCandidate(cursor.getLong(0), address, cursor.getString(2).orEmpty(), cursor.getLong(3), names.name(address))
            }
        }
        return result
    }

    /** Messages from up to [limit] rows, and whether [limit] rows were read (there may be more). */
    private fun smsRows(selection: String, args: Array<String>, order: String, limit: Int): Pair<List<SmsMessage>, Boolean> {
        val withSub = arrayOf("_id", "thread_id", "address", "body", "date", "type", "status", "read", "sub_id")
        val rows = query(Telephony.Sms.CONTENT_URI, withSub, selection, args, order)
            ?: query(Telephony.Sms.CONTENT_URI, withSub.copyOf(8).requireNoNulls(), selection, args, order)
            ?: return emptyList<SmsMessage>() to false
        val result = ArrayList<SmsMessage>()
        var raw = 0
        rows.use { cursor ->
            val hasSub = cursor.columnCount > 8
            while (cursor.moveToNext() && raw < limit) {
                raw++
                val (direction, status) = smsDirectionStatus(cursor.getInt(5), cursor.getInt(6)) ?: continue
                result += SmsMessage(
                    id = "s${cursor.getLong(0)}",
                    threadId = cursor.getLong(1),
                    direction = direction,
                    status = status,
                    date = cursor.getLong(4),
                    address = cursor.getString(2).orEmpty(),
                    body = cursor.getString(3).orEmpty(),
                    subId = if (hasSub && !cursor.isNull(8)) cursor.getInt(8).takeIf { it >= 0 } else null,
                    read = cursor.getInt(7) != 0,
                )
            }
        }
        return result to (raw >= limit)
    }

    private fun mmsRows(selection: String, args: Array<String>, order: String, limit: Int): Pair<List<SmsMessage>, Boolean> {
        val withSub = arrayOf("_id", "thread_id", "date", "msg_box", "read", "sub_id")
        val rows = query(Telephony.Mms.CONTENT_URI, withSub, selection, args, order)
            ?: query(Telephony.Mms.CONTENT_URI, withSub.copyOf(5).requireNoNulls(), selection, args, order)
            ?: return emptyList<SmsMessage>() to false
        data class Row(val id: Long, val thread: Long, val date: Long, val direction: SmsDirection, val status: SmsStatus, val read: Boolean, val subId: Int?)
        val found = ArrayList<Row>()
        var raw = 0
        rows.use { cursor ->
            val hasSub = cursor.columnCount > 5
            while (cursor.moveToNext() && raw < limit) {
                raw++
                val (direction, status) = mmsDirectionStatus(cursor.getInt(3)) ?: continue
                found += Row(
                    cursor.getLong(0), cursor.getLong(1), cursor.getLong(2) * 1000, direction, status, cursor.getInt(4) != 0,
                    if (hasSub && !cursor.isNull(5)) cursor.getInt(5).takeIf { it >= 0 } else null,
                )
            }
        }
        return found.map { row ->
            val (text, parts) = mmsParts(row.id)
            SmsMessage(
                id = "m${row.id}", threadId = row.thread, direction = row.direction, status = row.status, date = row.date,
                address = if (row.direction == SmsDirection.IN) mmsSender(row.id).orEmpty() else "",
                body = text, subId = row.subId, read = row.read, parts = parts,
            )
        } to (raw >= limit)
    }

    private fun mmsParts(messageId: Long): Pair<String, List<SmsPart>> {
        val text = StringBuilder()
        val images = ArrayList<SmsPart>()
        query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "text"), "mid = ?", arrayOf(messageId.toString()), "_id ASC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val type = cursor.getString(1).orEmpty().lowercase()
                when {
                    type == "text/plain" -> cursor.getString(2)?.let { if (text.isNotEmpty()) text.append('\n'); text.append(it) }
                    type.startsWith("image/") && images.size < SmsLimits.PARTS_MAX -> images += SmsPart("p${cursor.getLong(0)}", type.take(64))
                }
            }
        }
        return text.toString() to images
    }

    private fun mmsSender(messageId: Long): String? =
        query(Uri.parse("content://mms/$messageId/addr"), arrayOf("address", "type"), "type = 137", null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0)?.takeIf { it != "insert-address-token" } else null
        }

    // MARK: Attachments

    sealed interface ImageResult {
        data class Image(val width: Int, val height: Int, val jpeg: ByteArray) : ImageResult
        data class Error(val reason: String) : ImageResult
    }

    /** An MMS image scaled down to a JPEG of at most 28,672 bytes. */
    fun image(partId: String): ImageResult {
        if (!canRead) return ImageResult.Error("permission")
        val id = providerId(partId) ?: return ImageResult.Error("not_found")
        val type = query(Uri.parse("content://mms/part"), arrayOf("_id", "ct"), "_id = ?", arrayOf(id.toString()), null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(1).orEmpty().lowercase() else null
        } ?: return ImageResult.Error("not_found")
        if (!type.startsWith("image/")) return ImageResult.Error("unsupported")
        val uri = Uri.parse("content://mms/part/$id")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        runCatching { resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return ImageResult.Error("unsupported")
        for (side in listOf(640, 480, 360, 240, 160)) {
            val bitmap = decodeScaled(uri, bounds.outWidth, bounds.outHeight, side) ?: return ImageResult.Error("unsupported")
            for (quality in listOf(80, 65, 50)) {
                val bytes = ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                    out.toByteArray()
                }
                if (bytes.size <= SmsLimits.ATTACHMENT_MAX_BYTES) {
                    val result = ImageResult.Image(bitmap.width, bitmap.height, bytes)
                    bitmap.recycle()
                    return result
                }
            }
            bitmap.recycle()
        }
        return ImageResult.Error("unsupported")
    }

    private fun decodeScaled(uri: Uri, width: Int, height: Int, side: Int): Bitmap? {
        var sample = 1
        while (maxOf(width, height) / (sample * 2) >= side) sample *= 2
        val decoded = runCatching {
            resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
        }.getOrNull() ?: return null
        val longest = maxOf(decoded.width, decoded.height)
        if (longest <= side) return decoded
        val scale = side.toFloat() / longest
        val scaled = Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt().coerceAtLeast(1), (decoded.height * scale).toInt().coerceAtLeast(1), true)
        if (scaled !== decoded) decoded.recycle()
        return scaled
    }

    fun imageData(image: ImageResult.Image): String = Base64.encodeToString(image.jpeg, Base64.NO_WRAP)

    // MARK: Contacts and SIMs

    /** Up to 20 contacts whose name or number matches [query]. */
    fun contacts(query: String): List<SmsContact> {
        if (!canReadContacts) return emptyList()
        val uri = Uri.withAppendedPath(ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI, Uri.encode(query))
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.TYPE,
            ContactsContract.CommonDataKinds.Phone.LABEL,
        )
        val result = ArrayList<SmsContact>()
        val seen = HashSet<String>()
        query(uri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext() && result.size < SmsLimits.CONTACTS_MAX) {
                val number = cursor.getString(1)?.trim().orEmpty()
                val normalized = normalizeSmsAddress(number) ?: continue
                if (!seen.add(normalized)) continue
                val label = runCatching {
                    ContactsContract.CommonDataKinds.Phone.getTypeLabel(context.resources, cursor.getInt(2), cursor.getString(3)).toString()
                }.getOrNull()
                result += SmsContact(cursor.getString(0)?.trim().orEmpty().ifEmpty { number }, number.take(SmsLimits.ADDRESS_MAX), label)
            }
        }
        return result
    }

    /** Names for numbers, looked up once each within one request. */
    inner class NameLookup {
        private val names = HashMap<String, String?>()

        fun name(address: String): String? {
            if (!canReadContacts || address.isBlank()) return null
            return names.getOrPut(address) {
                val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address))
                query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0)?.trim()?.takeIf { it.isNotEmpty() } else null
                }
            }
        }
    }

    /** The phone's active SIMs, when Android lets Bridgey list them (READ_PHONE_STATE, checked first). */
    @android.annotation.SuppressLint("MissingPermission")
    fun sims(): List<SimInfo> {
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        val manager = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        return runCatching {
            manager.activeSubscriptionInfoList.orEmpty().map { info ->
                SimInfo(info.subscriptionId, info.simSlotIndex.coerceIn(0, 3), (info.displayName ?: info.carrierName ?: "").toString())
            }.sortedBy { it.slot }.take(SmsLimits.SIMS_MAX)
        }.getOrDefault(emptyList())
    }

    fun emergency(address: String): Boolean {
        val telephony = context.getSystemService(TelephonyManager::class.java)
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && telephony != null) {
                telephony.isEmergencyNumber(address)
            } else {
                @Suppress("DEPRECATION")
                PhoneNumberUtils.isEmergencyNumber(address)
            }
        }.getOrDefault(false)
    }

    private fun query(uri: Uri, projection: Array<String>, selection: String?, args: Array<String>?, order: String?): Cursor? =
        runCatching { resolver.query(uri, projection, selection, args, order) }.getOrNull()

    /** Some conversation tables keep seconds; everything on the wire is milliseconds. */
    private fun normalizeDate(date: Long): Long = if (date in 1 until 100_000_000_000L) date * 1000 else date
}

/** Phones with two SIM slots (no permission needed). */
fun isDualSim(context: Context): Boolean {
    val telephony = context.getSystemService(TelephonyManager::class.java) ?: return false
    return runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) telephony.activeModemCount >= 2
        else @Suppress("DEPRECATION") telephony.phoneCount >= 2
    }.getOrDefault(false)
}
