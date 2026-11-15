package dev.bridgey.android.dialer

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.CallLog
import android.provider.ContactsContract
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.PhoneNumberUtils
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import dev.bridgey.android.BuildGates
import dev.bridgey.android.sms.SimInfo

/*
 * Reads contacts, WhatsApp's contact rows, the call log and the SIMs for the Calls window, only when
 * a Mac asks, and keeps nothing. Nothing read here is logged.
 */
class DialerProvider(private val context: Context) {
    private val resolver = context.contentResolver

    fun granted(permission: String): Boolean = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    val canPlace: Boolean get() = granted(Manifest.permission.CALL_PHONE)

    val contactsAccess: Access
        get() = when {
            !BuildGates.contacts -> Access.UNAVAILABLE
            granted(Manifest.permission.READ_CONTACTS) -> Access.ON
            else -> Access.OFF
        }

    val recentsAccess: Access
        get() = when {
            !BuildGates.callLog -> Access.UNAVAILABLE
            granted(Manifest.permission.READ_CALL_LOG) -> Access.ON
            else -> Access.OFF
        }

    /** WhatsApp or WhatsApp Business is on this phone (the manifest's <queries> names both). */
    fun whatsAppInstalled(): Boolean = WhatsAppApp.entries.any { app ->
        runCatching { context.packageManager.getPackageInfo(app.packageName, 0) }.isSuccess
    }

    /** Contacts whose name or number matches [query], with their WhatsApp call rows. */
    fun contacts(query: String): List<DialerContact> {
        if (contactsAccess != Access.ON) return emptyList()
        val uri = Uri.withAppendedPath(ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI, Uri.encode(query))
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.TYPE,
            ContactsContract.CommonDataKinds.Phone.LABEL,
            ContactsContract.CommonDataKinds.Phone.STARRED,
        )
        val rows = ArrayList<ContactRow>()
        query(uri, projection, null, null, null)?.use { cursor ->
            var read = 0
            while (cursor.moveToNext() && read++ < ROWS_READ_MAX) {
                val number = cursor.getString(2)?.trim().orEmpty()
                if (number.isEmpty()) continue
                val label = runCatching {
                    ContactsContract.CommonDataKinds.Phone.getTypeLabel(context.resources, cursor.getInt(3), cursor.getString(4)).toString()
                }.getOrNull()
                rows += ContactRow(cursor.getLong(0), cursor.getString(1), cursor.getInt(5) == 1, number = DialerNumber(number, label))
            }
        }
        val ids = rows.map { it.contactId }.distinct().take(ROWS_READ_MAX)
        if (ids.isNotEmpty() && whatsAppInstalled()) rows += whatsAppRows(ids)
        return groupContacts(rows)
    }

    /** WhatsApp's voice and video call rows for these contacts. */
    private fun whatsAppRows(contactIds: List<Long>): List<ContactRow> {
        val types = WhatsAppApp.callTypes
        val selection = "${ContactsContract.Data.CONTACT_ID} IN (${contactIds.joinToString(",") { "?" }}) AND " +
            "${ContactsContract.Data.MIMETYPE} IN (${types.joinToString(",") { "?" }})"
        val args = (contactIds.map(Long::toString) + types).toTypedArray()
        val projection = arrayOf(
            ContactsContract.Data._ID, ContactsContract.Data.CONTACT_ID, ContactsContract.Data.MIMETYPE,
            ContactsContract.Data.DATA1, ContactsContract.Data.DATA3, ContactsContract.Data.DISPLAY_NAME,
            ContactsContract.Data.STARRED,
        )
        val rows = ArrayList<ContactRow>()
        query(ContactsContract.Data.CONTENT_URI, projection, selection, args, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val (_, video) = WhatsAppApp.forType(cursor.getString(2)) ?: continue
                val address = whatsAppNumber(cursor.getString(3)) ?: summaryNumber(cursor.getString(4)) ?: continue
                rows += ContactRow(cursor.getLong(1), cursor.getString(5), cursor.getInt(6) == 1, whatsApp = address to WhatsAppCall(cursor.getLong(0), video))
            }
        }
        return rows
    }

    /** The MIME type and name of one data row, for a WhatsApp call the Mac asked for. */
    fun dataRow(dataId: Long): Pair<String, String?>? {
        if (contactsAccess != Access.ON) return null
        val projection = arrayOf(ContactsContract.Data.MIMETYPE, ContactsContract.Data.DISPLAY_NAME)
        return query(ContactsContract.Data.CONTENT_URI, projection, "${ContactsContract.Data._ID} = ?", arrayOf(dataId.toString()), null)?.use { cursor ->
            if (cursor.moveToFirst()) (cursor.getString(0) ?: return@use null) to cursor.getString(1) else null
        }
    }

    /** The newest [limit] calls in the call log. */
    @SuppressLint("MissingPermission")
    fun recents(limit: Int): List<RecentCall> {
        if (recentsAccess != Access.ON) return emptyList()
        val projection = arrayOf(
            CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE,
            CallLog.Calls.DURATION, CallLog.Calls.PHONE_ACCOUNT_ID, CallLog.Calls.NUMBER_PRESENTATION,
        )
        val accounts = accountSubIds()
        val calls = ArrayList<RecentCall>()
        query(CallLog.Calls.CONTENT_URI, projection, null, null, "${CallLog.Calls.DATE} DESC")?.use { cursor ->
            while (cursor.moveToNext() && calls.size < limit) {
                val id = cursor.getLong(0).takeIf { it >= 1 } ?: continue
                val allowed = cursor.getInt(7) == CallLog.Calls.PRESENTATION_ALLOWED
                val address = if (allowed) cursor.getString(1)?.trim().orEmpty() else ""
                val account = cursor.getString(6)
                calls += RecentCall(
                    id = id,
                    address = address.take(DialerLimits.ADDRESS_MAX),
                    name = cursor.getString(2)?.trim()?.takeIf { allowed && it.isNotEmpty() },
                    type = RecentType.fromCallLog(cursor.getInt(3)),
                    date = cursor.getLong(4),
                    duration = cursor.getLong(5),
                    subId = account?.let { accounts[it] ?: it.toIntOrNull()?.takeIf { sub -> sub >= 0 } },
                )
            }
        }
        return calls
    }

    /** The phone's active SIMs, when Android lets Bridgey list them (READ_PHONE_STATE). */
    @SuppressLint("MissingPermission")
    fun sims(): List<SimInfo> {
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        val manager = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        return runCatching {
            manager.activeSubscriptionInfoList.orEmpty().map { info ->
                SimInfo(info.subscriptionId, info.simSlotIndex.coerceIn(0, 3), (info.displayName ?: info.carrierName ?: "").toString())
            }.sortedBy { it.slot }.take(DialerLimits.SIMS_MAX)
        }.getOrDefault(emptyList())
    }

    /** Telecom's phone account for a SIM, or null when it cannot be matched (then the default is used). */
    @SuppressLint("MissingPermission")
    fun phoneAccount(subId: Int): PhoneAccountHandle? {
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return null
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return null
        val handles = runCatching { telecom.callCapablePhoneAccounts }.getOrNull().orEmpty()
        return handles.firstOrNull { subIdOf(it) == subId }
    }

    /** Phone account ID to subId, for the call log's PHONE_ACCOUNT_ID. */
    @SuppressLint("MissingPermission")
    private fun accountSubIds(): Map<String, Int> {
        if (!granted(Manifest.permission.READ_PHONE_STATE)) return emptyMap()
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return emptyMap()
        return runCatching { telecom.callCapablePhoneAccounts }.getOrNull().orEmpty()
            .mapNotNull { handle -> subIdOf(handle)?.let { handle.id to it } }.toMap()
    }

    @SuppressLint("MissingPermission")
    private fun subIdOf(handle: PhoneAccountHandle): Int? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val telephony = context.getSystemService(TelephonyManager::class.java) ?: return null
            return runCatching { telephony.getSubscriptionId(handle) }.getOrNull()?.takeIf { it != SubscriptionManager.INVALID_SUBSCRIPTION_ID }
        }
        // Before Android 11 the SIM's phone account ID is its subId or its ICCID.
        handle.id.toIntOrNull()?.let { return it }
        val manager = context.getSystemService(SubscriptionManager::class.java) ?: return null
        return runCatching { manager.activeSubscriptionInfoList.orEmpty().firstOrNull { it.iccId == handle.id }?.subscriptionId }.getOrNull()
    }

    fun emergency(number: String): Boolean {
        val telephony = context.getSystemService(TelephonyManager::class.java)
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && telephony != null) {
                telephony.isEmergencyNumber(number)
            } else {
                @Suppress("DEPRECATION")
                PhoneNumberUtils.isEmergencyNumber(number)
            }
        }.getOrDefault(true)
    }

    private fun query(uri: Uri, projection: Array<String>, selection: String?, args: Array<String>?, order: String?): Cursor? =
        runCatching { resolver.query(uri, projection, selection, args, order) }.getOrNull()

    companion object {
        /** Phone rows read for one search before grouping. */
        const val ROWS_READ_MAX = 200

        /** The number in a row summary such as "Voice call +91 98765 43210", when the jid is missing. */
        fun summaryNumber(summary: String?): String? {
            val text = summary ?: return null
            val start = text.indexOfFirst { it == '+' || it.isDigit() }.takeIf { it >= 0 } ?: return null
            val digits = text.substring(start).filter(Char::isDigit)
            return if (digits.length in 3..15) "+$digits" else null
        }
    }
}
