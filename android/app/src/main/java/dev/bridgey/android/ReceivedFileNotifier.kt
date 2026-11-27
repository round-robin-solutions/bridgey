package dev.bridgey.android

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import android.widget.Toast

private const val APK_MIME_TYPE = "application/vnd.android.package-archive"

/**
 * The type a received file opens with: from the stored name's extension, never the type the sender
 * claimed. Null (open the folder only) for an unknown type or an Android package, so a tap never
 * leads to the installer.
 */
internal fun receivedFileOpenType(name: String, typeForExtension: (String) -> String?): String? {
    val extension = name.substringAfterLast('.', "").lowercase()
    if (extension.isEmpty() || extension == "apk") return null
    return typeForExtension(extension)?.takeIf { it.isNotBlank() && !it.equals(APK_MIME_TYPE, ignoreCase = true) }
}

/**
 * At most this many received-file notifications stay up. Android refuses an app's notifications past 50 at a time, so
 * one per file would, after a large batch, hide Bridgey's pairing, call and control prompts (and keep the shade busy).
 * The files stay in Download/Bridgey and in the activity stream.
 */
internal const val MAX_RECEIVED_SHOWN = 8

/** Of the received-file notifications showing, as (id, posted at), the oldest to cancel so a new one leaves [keep]. */
internal fun receivedToRetire(shown: List<Pair<Int, Long>>, keep: Int = MAX_RECEIVED_SHOWN): List<Int> =
    shown.sortedBy { it.second }.dropLast((keep - 1).coerceAtLeast(0)).map { it.first }

object ReceivedFileNotifier {
    private const val CHANNEL_ID = "bridgey_received_files_v1"

    fun show(context: Context, name: String, uri: Uri) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val id = uri.toString().hashCode()
        runCatching {
            val shown = manager.activeNotifications
                .filter { it.notification.channelId == CHANNEL_ID && it.id != id && (it.notification.flags and Notification.FLAG_GROUP_SUMMARY) == 0 }
                .map { it.id to it.postTime }
            receivedToRetire(shown).forEach(manager::cancel)
        }
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.channel_received), NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = context.getString(R.string.channel_received_detail)
            },
        )
        val intent = Intent()
            .setComponent(ComponentName(context, OpenReceivedFileActivity::class.java)).apply {
            data = uri
            receivedFileOpenType(name) { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) }
                ?.let { putExtra(OpenReceivedFileActivity.EXTRA_MIME_TYPE, it) }
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            uri.toString().hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            id,
            Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(dev.bridgey.android.R.drawable.ic_bridgey_notification)
                .setContentTitle(context.getString(R.string.received_notification_title))
                .setContentText(name)
                .setSubText("Download/Bridgey")
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .build(),
        )
    }
}

class OpenReceivedFileActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val fileUri = intent?.data
        val mimeType = intent?.getStringExtra(EXTRA_MIME_TYPE)?.takeIf { !it.equals(APK_MIME_TYPE, ignoreCase = true) }
        val folderUri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:Download/Bridgey",
        )
        val folderIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(folderUri, DocumentsContract.Document.MIME_TYPE_DIR)
            addCategory(Intent.CATEGORY_OPENABLE)
            flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val openedFolder = folderIntent.resolveActivity(packageManager) != null &&
            runCatching { startActivity(folderIntent) }.isSuccess
        if (!openedFolder && fileUri != null) {
            val fileIntent = mimeType?.let { type ->
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(fileUri, type)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            if (fileIntent == null || runCatching { startActivity(fileIntent) }.isFailure) {
                Toast.makeText(this, R.string.received_notification_saved, Toast.LENGTH_LONG).show()
            }
        }
        finish()
    }

    companion object {
        const val EXTRA_MIME_TYPE = "dev.bridgey.android.extra.MIME_TYPE"
    }
}
