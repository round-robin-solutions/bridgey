package dev.bridgey.android

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Base64
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream
import dev.bridgey.android.codes.isRedactedNotificationText
import java.security.MessageDigest

class BridgeyNotificationListenerService : NotificationListenerService() {
    // A call in progress is never evicted: its removal must still reach the Mac when it ends.
    private val forwardedNotifications = ForwardedNotificationRegistry(isPinned = { callLifecycle.isTrackedId(it) })
    private val storedActions = linkedMapOf<String, StoredNotificationAction>()
    private val actionTokensByNotificationId = mutableMapOf<String, List<String>>()
    private val applicationIcons = linkedMapOf<String, String>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingCallPosts = mutableMapOf<String, Runnable>()
    private val forwardedNotificationIds = mutableSetOf<String>()
    private var telephonyCallback: TelephonyCallback? = null
    private val callLifecycle = CallLifecycle(
        scheduler = { delayMs, task ->
            val runnable = Runnable(task)
            mainHandler.postDelayed(runnable, delayMs)
            val cancel: () -> Unit = { mainHandler.removeCallbacks(runnable) }
            cancel
        },
        telephonyState = ::currentTelephonyCallType,
        endCall = ::endForwardedCall,
        log = ::logCallEvent,
    )

    override fun onDestroy() {
        unregisterTelephonyCallback()
        callLifecycle.clear()
        pendingCallPosts.values.forEach(mainHandler::removeCallbacks)
        pendingCallPosts.clear()
        if (activeService?.get() === this) activeService = null
        super.onDestroy()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        activeService = java.lang.ref.WeakReference(this)
        val active = activeNotifications.orEmpty().filterNot { it.packageName == packageName }
        // A tracked call keeps its own id even when the dialer re-posted it under a new key.
        active.filterNot { callLifecycle.isTracked(it.key) }
            .forEach { forwardedNotifications.record(notificationToken(it.key), it.key, it.packageName) }
        // Removals are not delivered while unbound, so retract anything that disappeared meanwhile.
        retractStaleForwardedNotifications(active.mapTo(mutableSetOf()) { notificationToken(it.key) })
        restoreSmsTargets(active)
        updateTelephonyCallback()
        refreshActiveCallNotifications()
        BridgeyLogging.i(LogCategory.NOTIFICATIONS, "PLUGIN notification listener connected")
    }

    override fun onListenerDisconnected() {
        unregisterTelephonyCallback()
        if (activeService?.get() === this) activeService = null
        super.onListenerDisconnected()
        // The system can unbind a listener (process trim, OEM battery policy) without rebinding it.
        // A revoked listener stays unbound: the platform only rebinds approved components.
        runCatching { requestRebind(ComponentName(this, javaClass)) }
            .onFailure { BridgeyLogging.w(LogCategory.NOTIFICATIONS, "PLUGIN notification listener rebind request failed", it) }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        BridgeyLogging.d(LogCategory.NOTIFICATIONS, "PLUGIN notification observed package=${sbn.packageName}")
        val bridgey = application as BridgeyApplication
        if (!bridgey.isPrimaryUser || !bridgey.isBridgeyEnabled || sbn.packageName == packageName) return

        // An update that is no longer forwardable retracts any earlier mirrored state for the same key,
        // except a call: its card stays until the call ends (see CallLifecycle).
        val notification = sbn.notification
        val ranking = Ranking()
        val importance = if (rankingMap.getRanking(sbn.key, ranking)) ranking.importance else null
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val outcome = classifyNotificationUpdate(
            NotificationUpdate(
                systemKey = sbn.key,
                flags = notification.flags,
                category = notification.category,
                visibility = notification.visibility,
                importance = importance,
                hasContent = title.isNotEmpty() || text.isNotEmpty(),
            ),
            callLifecycle,
        )
        val isCall = when (outcome) {
            is UpdateOutcome.KeepCall -> return
            is UpdateOutcome.Retract -> return retractForwardedNotification(sbn.key)
            is UpdateOutcome.Forward -> outcome.isCall
        }

        val applicationName = runCatching {
            val info = packageManager.getApplicationInfo(sbn.packageName, 0)
            packageManager.getApplicationLabel(info).toString()
        }.getOrDefault(sbn.packageName)
        bridgey.settings.observeNotificationApplication(sbn.packageName, applicationName)
        if (!bridgey.settings.isNotificationApplicationEnabled(sbn.packageName)) {
            // The app was turned off: an explicit choice, so its call card goes too.
            return retractForwardedNotification(sbn.key)
        }
        val applicationIcon = applicationIcon(sbn.packageName)
        // Codes from messages: the Mac reads codes only in SMS from the default SMS app, and needs to
        // know when Android hid the text from Bridgey. The text is looked at here, never logged.
        val codeAccess = bridgey.codeAccess
        val smsDefaultApp = !isCall && sbn.packageName == codeAccess.defaultSmsPackage()
        val redacted = if (smsDefaultApp) isRedactedNotificationText(text, codeAccess.redactedPlaceholder) else null
        if (smsDefaultApp) codeAccess.observeSms(redacted == true, text)

        val isTelephonyCall = isCall && (callLifecycle.isTelephonyCall(sbn.key) || isTelephonyCallSource(sbn.packageName))
        val telephonyCallType = if (isTelephonyCall) currentTelephonyCallType() else null
        if (telephonyCallType == "idle") {
            // A dialer update while the phone reports no call: a tracked call ends only if IDLE holds.
            if (callLifecycle.isTracked(sbn.key)) return callLifecycle.telephonyChanged("idle")
            retractForwardedNotification(sbn.key)
            return
        }
        val notificationId = if (isCall) {
            callLifecycle.callIdFor(sbn.key, sbn.packageName, notificationToken(sbn.key))
        } else {
            notificationToken(sbn.key)
        }
        forwardedNotifications.record(notificationId, sbn.key, sbn.packageName)
        pendingCallPosts.remove(notificationId)?.let(mainHandler::removeCallbacks)
        val callType = if (isCall) resolvedNotificationCallType(notification, telephonyCallType, isTelephonyCall) else null
        val actions = storeActions(
            notificationId,
            notificationActionCandidates(notification, callType, isTelephonyCall && canControlSystemCalls()),
            isCall = callType != null,
        )
        // Text messages (sms_draft1): a Mac may answer an SMS notification, through the app's own reply or
        // by SMS to the conversation it belongs to. Found here once; the text is matched, never logged.
        var smsReply = false
        var smsThreadId: Long? = null
        // A group summary ("2 new messages") stands for several conversations: no reply from the Mac.
        val groupSummary = notification.flags and Notification.FLAG_GROUP_SUMMARY != 0
        if (smsDefaultApp && !groupSummary && bridgey.settings.smsOn()) {
            val provider = dev.bridgey.android.sms.SmsProvider(this)
            val replyToken = actions.firstOrNull { it.allowsReply }?.token
            // The app's own Mark as read, for a conversation read on the Mac (sms.mark_read).
            val markReadToken = actions.firstOrNull { it.markRead }?.token ?: storeHiddenMarkRead(notificationId, notification)
            smsThreadId = if (provider.canRead) {
                runCatching {
                    dev.bridgey.android.sms.matchNotificationThread(
                        title, text, sbn.postTime, provider.recentInbox(sbn.postTime - dev.bridgey.android.sms.MATCH_WINDOW_BEFORE_MILLIS),
                        messageTime = notification.`when`,
                    )
                }.getOrNull()
            } else {
                null
            } ?: dev.bridgey.android.sms.SmsNotificationTargets.get(notificationId)?.threadId
            dev.bridgey.android.sms.SmsNotificationTargets.record(
                dev.bridgey.android.sms.SmsNotificationTarget(
                    notificationId, title, text, sbn.postTime, smsThreadId, messageTime = notification.`when`, replyToken = replyToken,
                    markReadToken = markReadToken,
                ),
            )
            // With the sender hidden and no conversation found, a reply could only fail: no Reply on the Mac.
            smsReply = replyToken != null || (provider.canSend && provider.canRead && (smsThreadId != null || title.isNotBlank()))
        }
        val forward = Runnable {
            pendingCallPosts.remove(notificationId)
            if (forwardedNotifications.systemKey(notificationId) != sbn.key) return@Runnable
            val forwardedTo = bridgey.pairing.sendNotification(
                packageName = sbn.packageName,
                applicationName = applicationName,
                notificationId = notificationId,
                title = title,
                text = text,
                timestamp = sbn.postTime,
                actions = actions,
                applicationIcon = applicationIcon,
                callType = callType,
                smsDefaultApp = smsDefaultApp,
                redacted = redacted,
                smsReply = smsReply,
                smsThreadId = smsThreadId,
            )
            if (callType != null) {
                callLifecycle.forwarded(notificationId, sbn.key, sbn.packageName, isTelephonyCall)
                BridgeyLogging.line(LogLines.call(BridgeyLogging.policy, "forwarded", notificationId, callType, caller = title))
            }
            val firstForward = notificationId !in forwardedNotificationIds
            if (firstForward && (callType == null || callType == "incoming") && forwardedTo.isNotEmpty()) {
                bridgey.activity.notificationForwarded(
                    devices = forwardedTo,
                    isCall = callType == "incoming",
                    appName = applicationName,
                    // The caller is the call notification's title; it is already read for forwarding.
                    caller = if (callType == "incoming") title else null,
                )
            }
            forwardedNotificationIds += notificationId
            while (forwardedNotificationIds.size > MAX_TRACKED_FORWARDED_NOTIFICATIONS) {
                val oldest = forwardedNotificationIds.firstOrNull { !callLifecycle.isTrackedId(it) } ?: break
                forwardedNotificationIds.remove(oldest)
            }
        }
        if (shouldDelayCallPost(callType)) {
            pendingCallPosts[notificationId] = forward
            mainHandler.postDelayed(forward, CALL_POST_SETTLE_DELAY_MS)
        } else {
            forward.run()
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        // A call's card waits for the call to end; a re-posted call continues it.
        callLifecycle.notificationRemoved(sbn.key)?.let { callId ->
            pendingCallPosts.remove(callId)?.let(mainHandler::removeCallbacks)
            return
        }
        val notificationId = forwardedNotifications.removeSystemKey(sbn.key) ?: return
        pendingCallPosts.remove(notificationId)?.let(mainHandler::removeCallbacks)
        removeActions(notificationId)
        dev.bridgey.android.sms.SmsNotificationTargets.remove(notificationId)
        if (!forwardedNotificationIds.remove(notificationId)) return
        val bridgey = application as BridgeyApplication
        if (!bridgey.isPrimaryUser || !bridgey.isBridgeyEnabled) return
        bridgey.pairing.sendNotificationRemoved(notificationId)
    }

    private fun dismissForwardedNotification(notificationId: String): Boolean {
        val systemKey = forwardedNotifications.systemKey(notificationId) ?: return false
        android.os.Handler(android.os.Looper.getMainLooper()).post { cancelNotification(systemKey) }
        return true
    }

    @Synchronized
    private fun applyApplicationFilter(packageName: String, enabled: Boolean) {
        if (enabled) return
        val bridgey = application as BridgeyApplication
        forwardedNotifications.removePackage(packageName).forEach { notificationId ->
            callLifecycle.forget(notificationId)
            pendingCallPosts.remove(notificationId)?.let(mainHandler::removeCallbacks)
            removeActions(notificationId)
            if (forwardedNotificationIds.remove(notificationId) && bridgey.isPrimaryUser && bridgey.isBridgeyEnabled) {
                bridgey.pairing.sendNotificationRemoved(notificationId)
            }
        }
    }

    @Synchronized
    private fun storeActions(
        notificationId: String,
        actions: List<NotificationActionCandidate>,
        isCall: Boolean,
    ): List<ForwardedNotificationAction> {
        removeActions(notificationId)
        val forwarded = actions.take(MAX_FORWARDED_ACTIONS).mapIndexedNotNull { index, action ->
            val title = action.title.trim().take(64)
            val pendingIntent = action.pendingIntent
            if (title.isEmpty()) return@mapIndexedNotNull null
            val remoteInputs = action.remoteInputs.filter(RemoteInput::getAllowFreeFormInput).toTypedArray()
            val token = notificationActionToken(notificationId, index)
            storedActions[token] = StoredNotificationAction(
                notificationId = notificationId,
                pendingIntent = pendingIntent,
                remoteInputs = remoteInputs,
                systemCallAction = action.systemCallAction,
                isCall = isCall || action.systemCallAction != null,
            )
            ForwardedNotificationAction(token = token, title = title, allowsReply = remoteInputs.isNotEmpty(), markRead = action.markRead)
        }
        actionTokensByNotificationId[notificationId] = forwarded.map(ForwardedNotificationAction::token)
        while (storedActions.size > MAX_STORED_ACTIONS) storedActions.remove(storedActions.keys.first())
        return forwarded
    }

    /**
     * Text messages: the default SMS app's notifications already showing when the listener connects
     * (Bridgey restarted or updated, or Android rebound it) are found again, with their actions, so a
     * Mac can still answer them and mark them read (sms.mark_read). Seen live: after an update the
     * phone answered not_shown for a notification still on screen. Nothing is forwarded again.
     */
    @Synchronized
    private fun restoreSmsTargets(active: List<StatusBarNotification>) {
        val bridgey = application as BridgeyApplication
        val skipped = when {
            !bridgey.isPrimaryUser -> "user"
            !bridgey.isBridgeyEnabled -> "off"
            !bridgey.settings.smsOn() -> "sms_off"
            else -> null
        }
        val smsPackage = if (skipped == null) runCatching { bridgey.codeAccess.defaultSmsPackage() }.getOrNull() else null
        if (skipped != null || smsPackage == null) {
            BridgeyLogging.i(LogCategory.NOTIFICATIONS, "SMS notifications not looked at reason=${skipped ?: "no_default_app"}")
            return
        }
        val provider = dev.bridgey.android.sms.SmsProvider(this)
        var restored = 0
        var matched = 0
        active.filter {
            it.packageName == smsPackage && it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 &&
                bridgey.settings.isNotificationApplicationEnabled(it.packageName)
        }.forEach { sbn ->
            val notificationId = notificationToken(sbn.key)
            if (dev.bridgey.android.sms.SmsNotificationTargets.get(notificationId) != null) return@forEach
            val notification = sbn.notification
            val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
            val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
            // The same tokens as when it was forwarded: they are derived from the notification and the action's place.
            val actions = storeActions(notificationId, notificationActionCandidates(notification, null, false))
            val threadId = if (provider.canRead) {
                runCatching {
                    dev.bridgey.android.sms.matchNotificationThreadAnyTime(title, text, sbn.postTime, notification.`when`, provider::recentInbox)
                }.getOrNull()
            } else {
                null
            }
            dev.bridgey.android.sms.SmsNotificationTargets.record(
                dev.bridgey.android.sms.SmsNotificationTarget(
                    notificationId, title, text, sbn.postTime, threadId, messageTime = notification.`when`,
                    replyToken = actions.firstOrNull { it.allowsReply }?.token,
                    markReadToken = actions.firstOrNull { it.markRead }?.token ?: storeHiddenMarkRead(notificationId, notification),
                ),
            )
            restored++
            if (threadId != null) matched++
        }
        BridgeyLogging.i(LogCategory.NOTIFICATIONS, "SMS notifications found again restored=$restored matched=$matched")
    }

    /**
     * A Mark as read the Mac is not shown (past the forwarded four, untitled, or only in the wearable
     * extension): retained under its own token so sms.mark_read can run it. Null when there is none.
     */
    @Synchronized
    private fun storeHiddenMarkRead(notificationId: String, notification: Notification): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        val candidates = notification.actions.orEmpty().toList() + Notification.WearableExtender(notification).actions
        val action = candidates.firstOrNull { it.semanticAction == Notification.Action.SEMANTIC_ACTION_MARK_AS_READ && it.actionIntent != null } ?: return null
        val token = notificationActionToken(notificationId, HIDDEN_MARK_READ_INDEX)
        storedActions[token] = StoredNotificationAction(notificationId, action.actionIntent, emptyArray(), null)
        actionTokensByNotificationId[notificationId] = actionTokensByNotificationId[notificationId].orEmpty() + token
        while (storedActions.size > MAX_STORED_ACTIONS) storedActions.remove(storedActions.keys.first())
        return token
    }

    @Synchronized
    private fun removeActions(notificationId: String) {
        actionTokensByNotificationId.remove(notificationId).orEmpty().forEach(storedActions::remove)
    }

    @Synchronized
    private fun applicationIcon(packageName: String): String? {
        applicationIcons[packageName]?.let { return it }
        val drawable = runCatching { packageManager.getApplicationIcon(packageName) }.getOrNull() ?: return null
        val encoded = ICON_SIZES.firstNotNullOfOrNull { size ->
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val bytes = ByteArrayOutputStream().use { output ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                output.toByteArray()
            }
            bitmap.recycle()
            bytes.takeIf { it.size <= MAX_ICON_BYTES }
                ?.let { Base64.encodeToString(it, Base64.NO_WRAP) }
        } ?: return null
        applicationIcons[packageName] = encoded
        while (applicationIcons.size > MAX_CACHED_ICONS) applicationIcons.remove(applicationIcons.keys.first())
        return encoded
    }

    @Synchronized
    private fun performAction(notificationId: String, actionToken: String, replyText: String?, callsEnabled: Boolean): Boolean {
        val action = storedActions[actionToken]?.takeIf { it.notificationId == notificationId } ?: return false
        // Answer, decline and hang up need Calls on for the Mac that asked, not only Notifications.
        if (!notificationActionAllowed(action.isCall, callsEnabled)) return false
        if (replyText != null && action.remoteInputs.isEmpty()) return false
        return runCatching {
            val succeeded = if (action.systemCallAction != null) {
                performSystemCallAction(action.systemCallAction)
            } else if (replyText != null && action.remoteInputs.isNotEmpty()) {
                val results = Bundle().apply {
                    action.remoteInputs.forEach { putCharSequence(it.resultKey, replyText.take(MAX_REPLY_LENGTH)) }
                }
                val fillInIntent = Intent()
                RemoteInput.addResultsToIntent(action.remoteInputs, fillInIntent, results)
                action.pendingIntent?.send(this, 0, fillInIntent)
                true
            } else {
                action.pendingIntent?.send()
                true
            }
            if (succeeded) storedActions.remove(actionToken)
            BridgeyLogging.i(
                LogCategory.NOTIFICATIONS,
                "PLUGIN notification action performed system=${action.systemCallAction != null} success=$succeeded",
            )
            succeeded
        }.getOrElse {
            BridgeyLogging.w(LogCategory.NOTIFICATIONS, "PLUGIN notification action failed", it)
            false
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun performSystemCallAction(action: SystemCallAction): Boolean {
        if (!canControlSystemCalls()) return false
        val telecom = getSystemService(TelecomManager::class.java) ?: return false
        // Call integration requires READ_PHONE_STATE; a revoked grant must not act on an unknown call.
        val isRinging = runCatching {
            getSystemService(TelephonyManager::class.java).callState == TelephonyManager.CALL_STATE_RINGING
        }.getOrDefault(false)
        val isInCall = runCatching { telecom.isInCall }.getOrDefault(false)
        if (!canPerformSystemCallAction(action, isRinging, isInCall, Build.VERSION.SDK_INT)) return false
        return when (action) {
            SystemCallAction.ANSWER -> {
                telecom.acceptRingingCall()
                true
            }
            SystemCallAction.END -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && telecom.endCall()
        }
    }

    @Suppress("DEPRECATION")
    private fun currentTelephonyCallType(): String? {
        if (!isCallIntegrationEnabled()) return null
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return null
        return telephonyCallType(getSystemService(TelephonyManager::class.java).callState)
    }

    private fun canControlSystemCalls(): Boolean =
        (application as BridgeyApplication).settings.isEnabled(BridgeyFeature.CALLS, null) &&
            isCallIntegrationEnabled() &&
            checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED

    private fun isCallIntegrationEnabled(): Boolean =
        (application as BridgeyApplication).settings.state.value.directCallsEnabled

    // Phone state and Telecom controls describe the cellular call only. VoIP apps keep their own
    // CallStyle state and actions; Samsung and Xiaomi post call notifications from a separate
    // system in-call UI package rather than from the default dialer.
    private fun isTelephonyCallSource(packageName: String): Boolean {
        val telecom = runCatching { getSystemService(TelecomManager::class.java) }.getOrNull()
        val defaultDialer = runCatching { telecom?.defaultDialerPackage }.getOrNull()
        val systemDialer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching { telecom?.systemDialerPackage }.getOrNull()
        } else {
            null
        }
        return isTelephonyCallSource(packageName, defaultDialer, systemDialer) { isSystemInCallService(packageName) }
    }

    @Suppress("DEPRECATION")
    private fun isSystemInCallService(packageName: String): Boolean = runCatching {
        val info = packageManager.getApplicationInfo(packageName, 0)
        if (info.flags and ApplicationInfo.FLAG_SYSTEM == 0) return@runCatching false
        val intent = Intent(InCallService.SERVICE_INTERFACE).setPackage(packageName)
        packageManager.queryIntentServices(intent, 0).isNotEmpty()
    }.getOrDefault(false)

    private fun updateTelephonyCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        unregisterTelephonyCallback()
        if (!isCallIntegrationEnabled()) return
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return
        val callback = BridgeyCallStateCallback()
        runCatching {
            getSystemService(TelephonyManager::class.java).registerTelephonyCallback(mainExecutor, callback)
            telephonyCallback = callback
        }.onFailure { BridgeyLogging.w(LogCategory.CALLS, "CALL phone-state listener registration failed", it) }
    }

    private fun unregisterTelephonyCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        telephonyCallback?.let { callback ->
            runCatching { getSystemService(TelephonyManager::class.java).unregisterTelephonyCallback(callback) }
        }
        telephonyCallback = null
    }

    private fun refreshActiveCallNotifications() {
        val ranking = currentRanking ?: return
        activeNotifications.orEmpty()
            .filter {
                it.packageName != packageName &&
                    (it.notification.category == Notification.CATEGORY_CALL || callLifecycle.isTracked(it.key))
            }
            .forEach { onNotificationPosted(it, ranking) }
    }

    private fun retractStaleForwardedNotifications(activeNotificationIds: Set<String>) {
        val bridgey = application as BridgeyApplication
        val tracked = forwardedNotificationIds + pendingCallPosts.keys
        staleForwardedNotificationIds(tracked, activeNotificationIds).forEach { notificationId ->
            // A call's id stays after a re-key, so compare its current key; its end is decided by the lifecycle.
            if (callLifecycle.isTrackedId(notificationId)) {
                val key = forwardedNotifications.systemKey(notificationId)
                if (key == null || notificationToken(key) !in activeNotificationIds) {
                    key?.let(callLifecycle::notificationRemoved)
                }
                return@forEach
            }
            forwardedNotifications.systemKey(notificationId)?.let(forwardedNotifications::removeSystemKey)
            pendingCallPosts.remove(notificationId)?.let(mainHandler::removeCallbacks)
            removeActions(notificationId)
            if (
                forwardedNotificationIds.remove(notificationId) &&
                bridgey.isPrimaryUser && bridgey.isBridgeyEnabled
            ) {
                bridgey.pairing.sendNotificationRemoved(notificationId)
            }
        }
    }

    /** The call ended: its card goes from every Mac, marked as ended so they drop it at once. */
    private fun endForwardedCall(notificationId: String, reason: String) {
        forwardedNotifications.removeNotificationId(notificationId)
        pendingCallPosts.remove(notificationId)?.let(mainHandler::removeCallbacks)
        removeActions(notificationId)
        val bridgey = application as BridgeyApplication
        if (
            forwardedNotificationIds.remove(notificationId) &&
            bridgey.isPrimaryUser && bridgey.isBridgeyEnabled
        ) {
            bridgey.pairing.sendNotificationRemoved(notificationId, callEnded = true)
        }
    }

    private fun logCallEvent(event: String, notificationId: String?, reason: String) {
        BridgeyLogging.line(LogLines.call(BridgeyLogging.policy, event, notificationId, reason))
        (application as? BridgeyApplication)?.pairing?.recordCallDiagnostic(event, reason)
    }

    private fun retractForwardedNotification(systemKey: String) {
        val notificationId = forwardedNotifications.removeSystemKey(systemKey) ?: return
        callLifecycle.forget(notificationId)
        pendingCallPosts.remove(notificationId)?.let(mainHandler::removeCallbacks)
        removeActions(notificationId)
        val bridgey = application as BridgeyApplication
        if (
            forwardedNotificationIds.remove(notificationId) &&
            bridgey.isPrimaryUser && bridgey.isBridgeyEnabled
        ) {
            bridgey.pairing.sendNotificationRemoved(notificationId)
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private inner class BridgeyCallStateCallback : TelephonyCallback(), TelephonyCallback.CallStateListener {
        override fun onCallStateChanged(state: Int) {
            BridgeyLogging.d(LogCategory.CALLS, "CALL phone state=${telephonyCallType(state) ?: "idle"}")
            callLifecycle.telephonyChanged(telephonyCallType(state))
            when (state) {
                TelephonyManager.CALL_STATE_RINGING,
                TelephonyManager.CALL_STATE_OFFHOOK,
                -> refreshActiveCallNotifications()
            }
        }
    }

    companion object {
        @Volatile
        private var activeService: java.lang.ref.WeakReference<BridgeyNotificationListenerService>? = null

        fun dismiss(notificationId: String): Boolean {
            val service = activeService?.get() ?: return false
            return service.dismissForwardedNotification(notificationId)
        }

        /** sms.mark_read: the SMS notifications showing now, in case some were missed (Bridgey just started). */
        fun refreshSmsTargets() {
            val service = activeService?.get() ?: return
            runCatching { service.restoreSmsTargets(service.activeNotifications.orEmpty().filterNot { it.packageName == service.packageName }) }
        }

        /** [callsEnabled]: Calls is on for the Mac that asked; actions on a call need it (SMS replies pass false). */
        fun perform(notificationId: String, actionToken: String, replyText: String?, callsEnabled: Boolean = false): Boolean {
            val service = activeService?.get() ?: return false
            return service.performAction(notificationId, actionToken, replyText, callsEnabled)
        }

        fun filterChanged(packageName: String, enabled: Boolean) {
            activeService?.get()?.applyApplicationFilter(packageName, enabled)
        }

        // A new transport session starts with an empty Mac call card, so resend current calls.
        fun resendActiveCalls() {
            activeService?.get()?.mainHandler?.post {
                activeService?.get()?.refreshActiveCallNotifications()
            }
        }

        /**
         * After a companion link: Android decides whether to trust a listener when it connects, so
         * Bridgey's listener disconnects and asks to be bound again (onListenerDisconnected rebinds).
         */
        fun rebindForTrust(context: Context) {
            val service = activeService?.get()
            if (service != null) {
                runCatching { service.requestUnbind() }
                    .onFailure { BridgeyLogging.w(LogCategory.NOTIFICATIONS, "PLUGIN notification listener unbind failed", it) }
            } else {
                runCatching { requestRebind(ComponentName(context, BridgeyNotificationListenerService::class.java)) }
            }
        }

        fun callPermissionsChanged() {
            activeService?.get()?.mainHandler?.post {
                activeService?.get()?.updateTelephonyCallback()
            }
        }

        private const val MAX_FORWARDED_ACTIONS = 4
        /** Token index of a Mark as read kept only for sms.mark_read (forwarded actions use 0 to 3). */
        private const val HIDDEN_MARK_READ_INDEX = 100
        private const val MAX_STORED_ACTIONS = 2_048
        private const val MAX_REPLY_LENGTH = 4_096
        private const val MAX_ICON_BYTES = 20 * 1024
        private const val MAX_CACHED_ICONS = 128
        private const val MAX_TRACKED_FORWARDED_NOTIFICATIONS = 512
        private const val CALL_POST_SETTLE_DELAY_MS = 450L
        private val ICON_SIZES = listOf(64, 48, 32)
    }
}

private data class NotificationActionCandidate(
    val title: String,
    val pendingIntent: PendingIntent? = null,
    val remoteInputs: List<RemoteInput> = emptyList(),
    val systemCallAction: SystemCallAction? = null,
    /** Tagged SEMANTIC_ACTION_MARK_AS_READ by the app (API 28 and later). */
    val markRead: Boolean = false,
)

internal enum class SystemCallAction { ANSWER, END }

internal fun canPerformSystemCallAction(
    action: SystemCallAction,
    isRinging: Boolean,
    isInCall: Boolean,
    sdkInt: Int,
): Boolean = when (action) {
    SystemCallAction.ANSWER -> isRinging
    SystemCallAction.END -> isInCall && sdkInt >= Build.VERSION_CODES.P
}

private fun notificationActionCandidates(
    notification: Notification,
    callType: String?,
    canControlSystemCalls: Boolean,
): List<NotificationActionCandidate> {
    if (callType != null && canControlSystemCalls) {
        return systemCallActionCandidates(callType, Build.VERSION.SDK_INT)
    }
    val candidates = notification.actions.orEmpty().mapNotNull { action ->
        val pendingIntent = action.actionIntent ?: return@mapNotNull null
        NotificationActionCandidate(
            title = action.title?.toString().orEmpty(),
            pendingIntent = pendingIntent,
            remoteInputs = action.remoteInputs.orEmpty().toList(),
            markRead = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && action.semanticAction == Notification.Action.SEMANTIC_ACTION_MARK_AS_READ,
        )
    }
    if (callType == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return candidates

    val callStyleCandidates = callStyleFallbackActions(callType).mapNotNull { action ->
        notification.extras.pendingIntent(action.extraKey)?.let { NotificationActionCandidate(action.title, it) }
    }
    return prioritizedCallActions(callStyleCandidates, candidates, NotificationActionCandidate::pendingIntent)
}

// CallStyle Answer, Decline and Hang Up come first so the forwarded action limit never drops them
// in favour of a dialer's own extra actions. An own action with the same intent is not repeated.
internal fun <T> prioritizedCallActions(
    callStyleActions: List<T>,
    ownActions: List<T>,
    intentOf: (T) -> Any?,
): List<T> = (callStyleActions + ownActions).distinctBy(intentOf)

private fun resolvedNotificationCallType(
    notification: Notification,
    telephonyCallType: String?,
    isTelephonyCall: Boolean,
): String {
    val reportedType = notificationCallType(notification.extras.getInt("android.callType", 0))
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return reportedType
    val hasAnswer = notification.extras.pendingIntent(Notification.EXTRA_ANSWER_INTENT) != null
    val hasDecline = notification.extras.pendingIntent(Notification.EXTRA_DECLINE_INTENT) != null
    val hasHangUp = notification.extras.pendingIntent(Notification.EXTRA_HANG_UP_INTENT) != null
    val hasFullScreenIntent = notification.fullScreenIntent != null
    val resolvedType = resolvedNotificationCallType(
        reportedType = reportedType,
        hasAnswer = hasAnswer,
        hasDecline = hasDecline,
        hasHangUp = hasHangUp,
        hasFullScreenIntent = hasFullScreenIntent,
        telephonyCallType = telephonyCallType,
        isTelephonyCall = isTelephonyCall,
    )
    BridgeyLogging.d(
        LogCategory.CALLS,
        "CALL state reported=$reportedType resolved=$resolvedType " +
            "phoneState=${telephonyCallType ?: "unavailable"} fullScreen=$hasFullScreenIntent " +
            "answer=$hasAnswer decline=$hasDecline hangUp=$hasHangUp",
    )
    return resolvedType
}

internal fun resolvedNotificationCallType(
    reportedType: String,
    hasAnswer: Boolean,
    hasDecline: Boolean,
    hasHangUp: Boolean,
    hasFullScreenIntent: Boolean = false,
    telephonyCallType: String? = null,
    isTelephonyCall: Boolean = true,
): String = when {
    telephonyCallType == "incoming" -> "incoming"
    telephonyCallType == "ongoing" -> "ongoing"
    // Samsung's dialer reports CALL_TYPE_ONGOING with only a hang-up intent while the phone is
    // still ringing. Its full-screen intent is the stable, language-independent incoming-call signal.
    // Other apps can keep a full-screen intent after answering, so a hang-up-only call stays ongoing.
    hasFullScreenIntent && (isTelephonyCall || !hasHangUp) -> "incoming"
    hasAnswer && hasDecline && !hasHangUp -> "incoming"
    hasAnswer && hasHangUp && !hasDecline -> "screening"
    hasHangUp && !hasAnswer && !hasDecline -> "ongoing"
    else -> reportedType
}

internal fun systemCallActionTitles(callType: String, sdkInt: Int): List<String> = when (callType) {
    "incoming" -> buildList {
        if (sdkInt >= Build.VERSION_CODES.P) add("Decline")
        add("Answer")
    }
    "ongoing" -> if (sdkInt >= Build.VERSION_CODES.P) listOf("Hang Up") else emptyList()
    "screening" -> buildList {
        if (sdkInt >= Build.VERSION_CODES.P) add("Hang Up")
        add("Answer")
    }
    else -> emptyList()
}

private fun systemCallActionCandidates(callType: String, sdkInt: Int): List<NotificationActionCandidate> =
    systemCallActionTitles(callType, sdkInt).map { title ->
        NotificationActionCandidate(
            title = title,
            systemCallAction = if (title == "Answer") SystemCallAction.ANSWER else SystemCallAction.END,
        )
    }

internal fun shouldDelayCallPost(callType: String?): Boolean = callType == "ongoing"

internal data class CallStyleFallbackAction(val title: String, val extraKey: String)

internal fun callStyleFallbackActions(callType: String): List<CallStyleFallbackAction> = when (callType) {
    "incoming" -> listOf(
        CallStyleFallbackAction("Decline", Notification.EXTRA_DECLINE_INTENT),
        CallStyleFallbackAction("Answer", Notification.EXTRA_ANSWER_INTENT),
    )
    "ongoing" -> listOf(CallStyleFallbackAction("Hang Up", Notification.EXTRA_HANG_UP_INTENT))
    "screening" -> listOf(
        CallStyleFallbackAction("Hang Up", Notification.EXTRA_HANG_UP_INTENT),
        CallStyleFallbackAction("Answer", Notification.EXTRA_ANSWER_INTENT),
    )
    else -> emptyList()
}

@Suppress("DEPRECATION")
private fun Bundle.pendingIntent(key: String): PendingIntent? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelable(key, PendingIntent::class.java)
    } else {
        getParcelable(key) as? PendingIntent
    }

data class ForwardedNotificationAction(
    val token: String,
    val title: String,
    val allowsReply: Boolean,
    /** The app's own Mark as read: kept on the phone for sms.mark_read, never sent to the Mac. */
    val markRead: Boolean = false,
)

private data class StoredNotificationAction(
    val notificationId: String,
    val pendingIntent: PendingIntent?,
    val remoteInputs: Array<RemoteInput>,
    val systemCallAction: SystemCallAction?,
    /** The action belongs to a call notification (system Answer/End or the dialer's own actions). */
    val isCall: Boolean,
)

/** An action on a call notification needs Calls on for the asking Mac; other actions need only Notifications. */
internal fun notificationActionAllowed(isCallAction: Boolean, callsEnabled: Boolean): Boolean =
    !isCallAction || callsEnabled

/** The actions a Mac receives with a notification: none on a call when Calls is off for that Mac. */
internal fun <T> forwardedActionsFor(actions: List<T>, isCall: Boolean, callsEnabled: Boolean): List<T> =
    if (isCall && !callsEnabled) emptyList() else actions

internal class ForwardedNotificationRegistry(
    private val limit: Int = 512,
    private val isPinned: (String) -> Boolean = { false },
) {
    private data class Entry(val systemKey: String, val packageName: String)
    private val entriesByNotificationId = linkedMapOf<String, Entry>()

    @Synchronized
    fun record(notificationId: String, systemKey: String, packageName: String) {
        entriesByNotificationId.remove(notificationId)
        entriesByNotificationId[notificationId] = Entry(systemKey, packageName)
        while (entriesByNotificationId.size > limit) {
            val oldest = entriesByNotificationId.keys.firstOrNull { !isPinned(it) } ?: break
            entriesByNotificationId.remove(oldest)
        }
    }

    @Synchronized
    fun systemKey(notificationId: String): String? = entriesByNotificationId[notificationId]?.systemKey

    @Synchronized
    fun removeNotificationId(notificationId: String): String? = entriesByNotificationId.remove(notificationId)?.systemKey

    @Synchronized
    fun removeSystemKey(systemKey: String): String? {
        val notificationId = entriesByNotificationId.entries.firstOrNull { it.value.systemKey == systemKey }?.key ?: return null
        entriesByNotificationId.remove(notificationId)
        return notificationId
    }

    @Synchronized
    fun removePackage(packageName: String): List<String> {
        val notificationIds = entriesByNotificationId.filterValues { it.packageName == packageName }.keys.toList()
        notificationIds.forEach(entriesByNotificationId::remove)
        return notificationIds
    }
}

internal fun staleForwardedNotificationIds(
    trackedNotificationIds: Collection<String>,
    activeNotificationIds: Set<String>,
): List<String> = trackedNotificationIds.filterNot(activeNotificationIds::contains)

internal fun notificationToken(systemKey: String): String = MessageDigest.getInstance("SHA-256")
    .digest(systemKey.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it.toInt() and 0xff) }

internal fun notificationActionToken(notificationId: String, index: Int): String = notificationToken("$notificationId\u0000$index")

internal fun isTelephonyCallSource(
    packageName: String,
    defaultDialerPackage: String?,
    systemDialerPackage: String?,
    isSystemInCallService: () -> Boolean,
): Boolean = packageName == defaultDialerPackage || packageName == systemDialerPackage || isSystemInCallService()

internal fun shouldIgnoreOngoingNotification(flags: Int, category: String?): Boolean =
    flags and Notification.FLAG_ONGOING_EVENT != 0 && category != Notification.CATEGORY_CALL

internal fun notificationCallType(value: Int): String = when (value) {
    1 -> "incoming"
    2 -> "ongoing"
    3 -> "screening"
    else -> "unknown"
}

internal fun telephonyCallType(value: Int): String? = when (value) {
    TelephonyManager.CALL_STATE_RINGING -> "incoming"
    TelephonyManager.CALL_STATE_OFFHOOK -> "ongoing"
    TelephonyManager.CALL_STATE_IDLE -> "idle"
    else -> null
}

object NotificationAccess {
    fun isEnabled(context: Context): Boolean {
        val component = ComponentName(context, BridgeyNotificationListenerService::class.java)
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?: return false
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == component }
    }
}
