package dev.bridgey.android

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.view.View
import android.widget.RemoteViews

/**
 * How long after a fresh install the connection notification keeps to the standard template.
 * Android 16's System UI caches each package's resources by package name and does not check the APK path. If it
 * inflates a notification of a build that is being uninstalled after that build's APK is gone, it caches the removed
 * path, and a fresh install under the same name does not replace that entry (an update does: PACKAGE_REPLACED).
 * Until System UI garbage-collects the entry (on the emulator from a few seconds to almost a minute) it cannot load
 * this build's resources, an app layout is "not found", and for the foreground-service notification Android crashes
 * the app (acceptance soak, 28 Nov 2026). The standard template needs no app layout, so System UI can always
 * inflate it.
 */
internal const val FRESH_INSTALL_STANDARD_MS = 10 * 60_000L

/**
 * Whether the connection notification may use its app layouts at [now] (wall-clock milliseconds): always after an
 * update, and after a fresh install once [FRESH_INSTALL_STANDARD_MS] has passed.
 */
internal fun customNotificationLayoutsAllowed(now: Long, firstInstallTime: Long, lastUpdateTime: Long): Boolean =
    firstInstallTime != lastUpdateTime || now !in firstInstallTime until firstInstallTime + FRESH_INSTALL_STANDARD_MS

internal fun clipboardContextLabel(kind: ClipboardContextKind): Int = when (kind) {
    ClipboardContextKind.LINK -> R.string.notification_open_link
    ClipboardContextKind.CALL -> R.string.notification_call
    ClipboardContextKind.EMAIL -> R.string.notification_email
}

/**
 * The clipboard controls of the connection notification: the decorated custom view, or, while [customLayouts] is
 * false (see [FRESH_INSTALL_STANDARD_MS]), the same two controls as standard actions.
 */
internal fun Notification.Builder.clipboardControls(
    context: Context,
    status: String,
    send: PendingIntent,
    local: PendingIntent?,
    kind: ClipboardContextKind?,
    customLayouts: Boolean,
): Notification.Builder {
    if (customLayouts) {
        return setStyle(Notification.DecoratedCustomViewStyle())
            .setCustomContentView(clipboardNotificationContent(context, status, send, local, kind, expanded = false))
            .setCustomBigContentView(clipboardNotificationContent(context, status, send, local, kind))
    }
    if (local != null && kind != null) {
        addAction(android.R.drawable.ic_menu_view, context.getString(clipboardContextLabel(kind)), local)
    }
    return addAction(android.R.drawable.ic_menu_send, context.getString(R.string.notification_send_copied_text), send)
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
