package dev.bridgey.android

import android.app.PendingIntent
import android.content.Context
import android.view.View
import android.widget.RemoteViews

internal fun clipboardContextLabel(kind: ClipboardContextKind): Int = when (kind) {
    ClipboardContextKind.LINK -> R.string.notification_open_link
    ClipboardContextKind.CALL -> R.string.notification_call
    ClipboardContextKind.EMAIL -> R.string.notification_email
}

/** Fixtures use the same RemoteViews as the service; no clipboard text enters either view. */
internal fun clipboardNotificationContent(
    context: Context,
    status: String,
    send: PendingIntent,
    local: PendingIntent? = null,
    kind: ClipboardContextKind? = null,
    expanded: Boolean = true,
): RemoteViews {
    val actionable = local != null && kind != null
    return RemoteViews(context.packageName,
        if (actionable) R.layout.notification_clipboard_actions else R.layout.notification_clipboard).apply {
        setTextViewText(R.id.notification_status, status)
        setTextViewText(R.id.notification_send, context.getString(R.string.notification_send_copied_text))
        setOnClickPendingIntent(R.id.notification_send, send)
        if (actionable) {
            setTextViewText(R.id.notification_local_action, context.getString(clipboardContextLabel(kind!!)))
            setOnClickPendingIntent(R.id.notification_local_action, local)
            // Android 12+ caps collapsed custom content. Keep its two 48dp targets visible;
            // the standard notification metadata and expanded content retain connection status.
            setViewVisibility(R.id.notification_status, if (expanded) View.VISIBLE else View.GONE)
        }
    }
}
