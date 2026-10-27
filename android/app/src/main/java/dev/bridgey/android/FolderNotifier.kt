package dev.bridgey.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import dev.bridgey.android.folders.ConflictChoice
import dev.bridgey.android.folders.FolderEnd
import dev.bridgey.android.folders.FolderQuestion
import dev.bridgey.android.folders.FolderSnapshot
import dev.bridgey.android.ui.FolderText

/**
 * Folder notifications (3.4, 6.4): the result ("Folder Photos saved to Pictures/Trip (124 files)" with Open),
 * lost access, and the phone's questions in the high-importance "Folder questions" channel. The ongoing
 * progress notification is the connection service's, one per folder like a file.
 */
object FolderNotifier {
    const val QUESTIONS_CHANNEL_ID = "bridgey_folder_questions_v1"
    private const val RESULTS_CHANNEL_ID = "bridgey_received_folders_v1"
    private const val LOST_ACCESS_ID = 61_999

    fun questionNotificationId(folderTransferId: String): Int = 62_000 + (folderTransferId.hashCode() and 0x0fff)
    private fun resultNotificationId(folderTransferId: String): Int = 66_000 + (folderTransferId.hashCode() and 0x0fff)

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(QUESTIONS_CHANNEL_ID, context.getString(R.string.notification_channel_folder_questions), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.notification_channel_folder_questions_detail)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(RESULTS_CHANNEL_ID, context.getString(R.string.notification_channel_received_folders), NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    fun finished(context: Context, folder: FolderSnapshot) {
        // Sent folders and downloads show in the Stream; the other device tells its own user where they landed.
        if (folder.outgoing) return
        val title = when (folder.end) {
            FolderEnd.COMPLETE -> context.resources.getQuantityString(
                R.plurals.notification_folder_saved, folder.filesDone, folder.rootName, folder.destinationLabel.orEmpty(), folder.filesDone,
            )
            FolderEnd.INCOMPLETE -> context.resources.getQuantityString(
                R.plurals.notification_folder_incomplete, folder.filesTotal, folder.rootName, folder.filesDone, folder.filesTotal,
            )
            else -> return
        }
        ensureChannels(context)
        val builder = Notification.Builder(context, RESULTS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(title)
            .setContentText(context.getString(R.string.notification_folder_from, folder.deviceName))
            .setAutoCancel(true)
        openIntent(context, folder)?.let { intent ->
            val pending = PendingIntent.getActivity(context, resultNotificationId(folder.folderTransferId), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.setContentIntent(pending)
            builder.addAction(Notification.Action.Builder(null, context.getString(R.string.action_open), pending).build())
        }
        context.getSystemService(NotificationManager::class.java).notify(resultNotificationId(folder.folderTransferId), builder.build())
    }

    /** Open the saved folder in the Files app when the device can; Download/Bridgey through the existing opener. */
    private fun openIntent(context: Context, folder: FolderSnapshot): Intent? {
        val root = folder.rootUri
        if (root != null) {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(root), DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return intent.takeIf { it.resolveActivity(context.packageManager) != null }
        }
        if (folder.destinationLabel?.startsWith("Download/Bridgey") != true) return null
        return Intent().setComponent(ComponentName(context, OpenReceivedFileActivity::class.java)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun lostAccess(context: Context, placeLabel: String) {
        ensureChannels(context)
        val notification = Notification.Builder(context, RESULTS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(context.getString(R.string.notification_lost_access, placeLabel))
            .setContentText(context.getString(R.string.notification_lost_access_detail))
            .setContentIntent(openApp(context, null))
            .setAutoCancel(true)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(LOST_ACCESS_ID, notification)
    }

    private fun openApp(context: Context, folderTransferId: String?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            folderTransferId?.let { putExtra(EXTRA_FOLDER_QUESTION, it) }
        }
        return PendingIntent.getActivity(
            context, folderTransferId?.let(::questionNotificationId) ?: 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * The phone's question as a notification: tap opens the sheet (with Cancel); a conflict also gets Merge,
     * Replace (needs an unlocked phone on Android 12+) and New folder. Dismissing does not answer.
     */
    fun question(context: Context, question: FolderQuestion, answerIntent: (ConflictChoice) -> PendingIntent): Notification {
        val builder = Notification.Builder(context, QUESTIONS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentIntent(openApp(context, question.folderTransferId))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter((question.deadlineMillis - System.currentTimeMillis()).coerceAtLeast(1_000))
        if (question.kind == FolderQuestion.Kind.DESTINATION) {
            builder.setContentTitle(context.getString(R.string.notification_folder_destination_title, question.rootName, question.deviceName))
                .setContentText(context.getString(R.string.notification_folder_destination_text))
            return builder.build()
        }
        val title = if (question.confirmsRemoteReplace) {
            context.getString(R.string.notification_folder_confirm_title, question.deviceName, question.destinationLabel)
        } else {
            context.getString(R.string.notification_folder_conflict_title, question.rootName, question.destinationLabel)
        }
        val text = when {
            question.existing == dev.bridgey.android.folders.FolderPolicy.Existing.FILE -> context.getString(R.string.conflict_existing_file)
            question.clashingFiles == null -> context.getString(R.string.conflict_clashes_unknown)
            else -> context.resources.getQuantityString(R.plurals.conflict_clashes, question.fileCount, question.clashingFiles, question.fileCount)
        }
        builder.setContentTitle(title).setContentText(text).setStyle(Notification.BigTextStyle().bigText(text))
        listOf(ConflictChoice.MERGE, ConflictChoice.REPLACE, ConflictChoice.NEW_FOLDER).filter { it in question.choices }.forEach { choice ->
            val label = context.getString(
                when (choice) {
                    ConflictChoice.MERGE -> R.string.action_merge
                    ConflictChoice.REPLACE -> R.string.action_replace
                    else -> R.string.action_new_folder
                },
            )
            val action = Notification.Action.Builder(null, label, answerIntent(choice))
            if (choice == ConflictChoice.REPLACE && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) action.setAuthenticationRequired(true)
            builder.addAction(action.build())
        }
        return builder.build()
    }

    /** "Photos · 37 of 124 files", for the ongoing notification. */
    fun progressTitle(context: Context, folder: FolderSnapshot): String =
        context.resources.getQuantityString(R.plurals.notification_folder_title, folder.filesTotal, folder.rootName, folder.filesDone, folder.filesTotal)

    fun progressText(context: Context, folder: FolderSnapshot): String = FolderText.statusLine(context, folder, System.currentTimeMillis())

    const val EXTRA_FOLDER_QUESTION = "dev.bridgey.android.extra.FOLDER_QUESTION"
}
