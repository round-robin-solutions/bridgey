package dev.bridgey.android.controls

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.service.controls.Control
import android.service.controls.ControlsProviderService
import android.service.controls.DeviceTypes
import android.service.controls.actions.BooleanAction
import android.service.controls.actions.ControlAction
import android.service.controls.actions.FloatAction
import android.service.controls.templates.ControlButton
import android.service.controls.templates.ControlTemplate
import android.service.controls.templates.RangeTemplate
import android.service.controls.templates.StatelessTemplate
import android.service.controls.templates.ToggleTemplate
import androidx.annotation.RequiresApi
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.ClipboardCaptureActivity
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R
import java.util.concurrent.Flow
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.function.Consumer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow as KFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** Every paired Mac as controls see it, now. */
internal fun controlMacs(app: BridgeyApplication): List<ControlMac> {
    val pairing = app.pairing
    val connections = pairing.connections.value.associateBy { it.deviceId }
    val catalogs = pairing.macActions.catalogs.value
    val live = pairing.macActions.live.value
    return pairing.trustedDevices.value.map { device ->
        val connection = connections[device.id]
        val available = if (connection == null || !app.isBridgeyEnabled) emptySet() else BridgeyFeature.entries.filter { pairing.isFeatureAvailable(it, device.id) }.toSet()
        ControlMac(device.id, device.name, connection != null && app.isBridgeyEnabled, available, catalogs[device.id], device.id in live, connection?.state?.ringing == true)
    }
}

/** A flow that ticks whenever anything a control or widget shows may have changed. */
internal fun controlChanges(app: BridgeyApplication): KFlow<Unit> = combine(
    combine(app.pairing.connections, app.pairing.trustedDevices, app.pairing.macActions.catalogs, app.pairing.macActions.live, app.settings.state) { _, _, _, _, _ -> },
    app.pairing.state,
) { _, _ -> }

/** Runs a control or widget command through the coordinator. */
internal fun runControlCommand(app: BridgeyApplication, command: ControlCommand) {
    when (command) {
        is ControlCommand.Run -> app.pairing.macActions.run(command.deviceId, command.actionId, command.value)
        is ControlCommand.Ping -> app.pairing.sendPing(command.deviceId)
        is ControlCommand.Find -> if (command.start) app.pairing.findMac(command.deviceId) else app.pairing.stopFinding(command.deviceId)
    }
}

/** Opens the clipboard reader aimed at [deviceId]: a tap on Send copied item (the reader must be in front to read). */
internal fun sendCopiedIntent(context: Context, deviceId: String, requestCode: Int): PendingIntent = PendingIntent.getActivity(
    context, requestCode,
    Intent(context, ClipboardCaptureActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        .putExtra(ClipboardCaptureActivity.EXTRA_DEVICE_ID, deviceId)
        .setData(android.net.Uri.parse("bridgey-send:$deviceId")),
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
)

internal fun ControlLabel.iconRes(): Int = when (this) {
    ControlLabel.LOCK -> R.drawable.ic_action_lock
    ControlLabel.SLEEP -> R.drawable.ic_action_sleep
    ControlLabel.SCREENSAVER -> R.drawable.ic_action_screensaver
    ControlLabel.VOLUME -> R.drawable.ic_action_volume_up
    ControlLabel.MUTE -> R.drawable.ic_action_volume_off
    ControlLabel.PING -> R.drawable.ic_action_ping
    ControlLabel.FIND -> R.drawable.ic_action_find
    ControlLabel.SEND_COPIED -> R.drawable.ic_action_send
    ControlLabel.APP -> R.drawable.ic_action_app
    ControlLabel.SHORTCUT -> R.drawable.ic_action_shortcut
}

internal fun ControlSpec.title(context: Context): String = customTitle ?: context.getString(
    when (label) {
        ControlLabel.LOCK -> R.string.action_mac_lock
        ControlLabel.SLEEP -> R.string.action_mac_sleep
        ControlLabel.SCREENSAVER -> R.string.action_mac_screensaver
        ControlLabel.VOLUME -> R.string.mac_volume
        ControlLabel.MUTE -> R.string.action_mac_mute
        ControlLabel.PING -> R.string.action_ping
        ControlLabel.FIND -> R.string.action_find
        ControlLabel.SEND_COPIED -> R.string.control_send
        ControlLabel.APP, ControlLabel.SHORTCUT -> R.string.feature_mac_actions
    },
)

/**
 * Device Controls (Android 11+): each paired Mac's actions in the power menu or Quick Settings.
 * The mapping is [controlSpecs]; this service only builds `Control`s and dispatches taps.
 */
@RequiresApi(30)
class MacControlsService : ControlsProviderService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val app get() = application as BridgeyApplication

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun specs(): List<ControlSpec> = if (app.isPrimaryUser) controlSpecs(controlMacs(app)) else emptyList()

    override fun createPublisherForAllAvailable(): Flow.Publisher<Control> {
        val controls = specs().map(::statelessControl)
        return ListPublisher(controls)
    }

    override fun createPublisherFor(controlIds: MutableList<String>): Flow.Publisher<Control> {
        val wanted = controlIds.toSet()
        return LivePublisher(scope, if (app.isPrimaryUser) controlChanges(app) else null) {
            specs().filter { it.controlId in wanted }.map(::statefulControl)
        }
    }

    override fun performControlAction(controlId: String, action: ControlAction, consumer: Consumer<Int>) {
        val spec = specs().firstOrNull { it.controlId == controlId }
        val command = spec?.let {
            controlCommand(it, floatValue = (action as? FloatAction)?.newValue, booleanValue = (action as? BooleanAction)?.newState)
        }
        if (command == null) {
            consumer.accept(ControlAction.RESPONSE_FAIL)
            return
        }
        runControlCommand(app, command)
        consumer.accept(ControlAction.RESPONSE_OK)
    }

    private fun openIntent(spec: ControlSpec): PendingIntent = if (spec.kind == ControlKind.SEND_COPIED) {
        sendCopiedIntent(this, spec.deviceId, spec.controlId.hashCode())
    } else {
        PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun deviceType(spec: ControlSpec): Int = when (spec.kind) {
        ControlKind.ACTION -> if (spec.label == ControlLabel.LOCK) DeviceTypes.TYPE_LOCK else DeviceTypes.TYPE_GENERIC_START_STOP
        ControlKind.VOLUME, ControlKind.MUTE -> DeviceTypes.TYPE_GENERIC_ON_OFF
        ControlKind.PING, ControlKind.FIND -> DeviceTypes.TYPE_REMOTE_CONTROL
        ControlKind.SEND_COPIED -> DeviceTypes.TYPE_GENERIC_ON_OFF
    }

    private fun statelessControl(spec: ControlSpec): Control =
        Control.StatelessBuilder(spec.controlId, openIntent(spec))
            .setTitle(spec.title(this))
            .setSubtitle(spec.macName)
            .setZone(spec.macName)
            .setStructure(getString(R.string.launcher_name))
            .setDeviceType(deviceType(spec))
            .setCustomIcon(Icon.createWithResource(this, spec.label.iconRes()))
            .build()

    private fun statefulControl(spec: ControlSpec): Control {
        val title = spec.title(this)
        val template: ControlTemplate = when (spec.kind) {
            ControlKind.ACTION, ControlKind.PING -> StatelessTemplate(spec.controlId)
            ControlKind.VOLUME -> RangeTemplate(spec.controlId, 0f, 100f, (spec.volume?.level ?: 0).toFloat(), 1f, "%.0f%%")
            ControlKind.MUTE -> ToggleTemplate(spec.controlId, ControlButton(spec.checked, title))
            ControlKind.FIND -> ToggleTemplate(spec.controlId, ControlButton(spec.checked, title))
            ControlKind.SEND_COPIED -> ControlTemplate.getNoTemplateObject()
        }
        val status = when {
            spec.blocked -> getString(R.string.control_status_blocked)
            spec.state == ControlState.OFFLINE -> getString(R.string.control_status_offline)
            spec.state == ControlState.UNAVAILABLE -> getString(R.string.control_status_unavailable)
            spec.kind == ControlKind.FIND && spec.checked -> getString(R.string.control_status_ringing)
            spec.kind == ControlKind.MUTE && spec.checked -> getString(R.string.mac_volume_muted)
            else -> getString(R.string.control_status_ready)
        }
        return Control.StatefulBuilder(spec.controlId, openIntent(spec))
            .setTitle(title)
            .setSubtitle(spec.macName)
            .setZone(spec.macName)
            .setStructure(getString(R.string.launcher_name))
            .setDeviceType(deviceType(spec))
            .setCustomIcon(Icon.createWithResource(this, spec.label.iconRes()))
            .setStatus(Control.STATUS_OK)
            .setStatusText(status)
            .setControlTemplate(template)
            .build()
    }
}

/** Emits [items] as demand allows, then completes. */
@RequiresApi(30)
private class ListPublisher<T>(private val items: List<T>) : Flow.Publisher<T> {
    override fun subscribe(subscriber: Flow.Subscriber<in T>) {
        var index = 0
        val done = AtomicBoolean(false)
        subscriber.onSubscribe(object : Flow.Subscription {
            override fun request(n: Long) {
                if (n <= 0) {
                    if (done.compareAndSet(false, true)) subscriber.onError(IllegalArgumentException("request $n"))
                    return
                }
                var left = n
                while (left > 0 && index < items.size && !done.get()) {
                    subscriber.onNext(items[index++])
                    left--
                }
                if (index >= items.size && done.compareAndSet(false, true)) subscriber.onComplete()
            }
            override fun cancel() { done.set(true) }
        })
    }
}

/**
 * Emits the current controls on subscribe and again on every [changes] tick, while there is
 * demand; it never completes (the system cancels it when the controls close).
 */
@RequiresApi(30)
private class LivePublisher<T>(
    private val scope: CoroutineScope,
    private val changes: KFlow<Unit>?,
    private val current: () -> List<T>,
) : Flow.Publisher<T> {
    override fun subscribe(subscriber: Flow.Subscriber<in T>) {
        val demand = AtomicLong(0)
        val cancelled = AtomicBoolean(false)
        val queue = ArrayDeque<T>()
        var job: Job? = null
        fun drain() = synchronized(queue) {
            while (!cancelled.get() && demand.get() > 0 && queue.isNotEmpty()) {
                demand.decrementAndGet()
                subscriber.onNext(queue.removeFirst())
            }
        }
        fun refresh() {
            synchronized(queue) {
                queue.clear()
                queue.addAll(current())
            }
            drain()
        }
        subscriber.onSubscribe(object : Flow.Subscription {
            override fun request(n: Long) {
                if (n <= 0 || cancelled.get()) return
                demand.updateAndGet { old -> if (Long.MAX_VALUE - old < n) Long.MAX_VALUE else old + n }
                drain()
            }
            override fun cancel() {
                cancelled.set(true)
                job?.cancel()
            }
        })
        job = scope.launch {
            if (changes == null) refresh() else changes.collect { refresh() }
        }
    }
}
