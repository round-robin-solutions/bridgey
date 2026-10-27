package dev.bridgey.android.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.color.ColorProvider
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R
import dev.bridgey.android.actions.MacActionIds
import dev.bridgey.android.controls.ControlCommand
import dev.bridgey.android.controls.ControlMac
import dev.bridgey.android.controls.controlMacs
import dev.bridgey.android.controls.runControlCommand
import dev.bridgey.android.ui.theme.DarkBridgeyColors
import dev.bridgey.android.ui.theme.LightBridgeyColors

/*
 * Home-screen widget (Glance): one Mac, its connection state and six buttons. A widget either
 * follows the Mac selected in Bridgey (the default, no setup) or shows the Mac picked in its
 * configuration screen; the choice is kept per widget in [WidgetTargets].
 */

/** Which Mac each widget shows; a missing entry follows the Mac selected in Bridgey. */
object WidgetTargets {
    private const val PREFERENCES = "bridgey.widgets"
    fun get(context: Context, appWidgetId: Int): String? =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString("widget.$appWidgetId", null)

    fun set(context: Context, appWidgetId: Int, deviceId: String?) {
        val editor = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
        if (deviceId == null) editor.remove("widget.$appWidgetId") else editor.putString("widget.$appWidgetId", deviceId)
        editor.apply()
    }

    fun remove(context: Context, ids: IntArray) {
        val editor = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
        ids.forEach { editor.remove("widget.$it") }
        editor.apply()
    }
}

/** A widget button: its icon, label and what it does. */
data class WidgetButton(val icon: Int, val label: Int, val enabled: Boolean, val command: ControlCommand?, val sendCopied: Boolean = false)

/** What a widget shows for [mac] (null: no Mac paired). Pure, so the layout can be tested and previewed. */
data class WidgetModel(val name: String?, val connected: Boolean, val status: Int, val buttons: List<WidgetButton>)

fun widgetModel(mac: ControlMac?): WidgetModel {
    if (mac == null) return WidgetModel(null, false, R.string.widget_no_mac, emptyList())
    val catalog = mac.catalog?.takeIf { mac.catalogLive && dev.bridgey.android.BridgeyFeature.MAC_ACTIONS in mac.available }
    fun action(id: String, icon: Int, label: Int) = WidgetButton(
        icon, label, catalog?.entry(id)?.let { it.blocked == null } == true,
        ControlCommand.Run(mac.deviceId, id),
    )
    val buttons = listOf(
        action(MacActionIds.LOCK, R.drawable.ic_action_lock, R.string.action_mac_lock),
        action(MacActionIds.SLEEP, R.drawable.ic_action_sleep, R.string.action_mac_sleep),
        action(MacActionIds.VOLUME_DOWN, R.drawable.ic_action_volume_down, R.string.action_mac_volume_down),
        action(MacActionIds.VOLUME_UP, R.drawable.ic_action_volume_up, R.string.action_mac_volume_up),
        WidgetButton(R.drawable.ic_action_ping, R.string.action_ping, dev.bridgey.android.BridgeyFeature.PING in mac.available, ControlCommand.Ping(mac.deviceId)),
        WidgetButton(R.drawable.ic_action_send, R.string.control_send, dev.bridgey.android.BridgeyFeature.CLIPBOARD in mac.available, null, sendCopied = true),
    )
    val status = when {
        !mac.connected -> R.string.control_status_offline
        else -> R.string.health_connected
    }
    return WidgetModel(mac.name, mac.connected, status, buttons)
}

/** The Mac a widget shows: its own pick if still paired, else the one selected in Bridgey, else the first. */
internal fun widgetMac(app: BridgeyApplication, chosen: String?): ControlMac? {
    val macs = controlMacs(app)
    val selected = (app.pairing.state.value as? dev.bridgey.android.PairingState.Connected)?.deviceId
    return macs.firstOrNull { it.deviceId == chosen } ?: macs.firstOrNull { it.deviceId == selected } ?: macs.firstOrNull { it.connected } ?: macs.firstOrNull()
}

class MacWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val app = context.applicationContext as BridgeyApplication
        val appWidgetId = GlanceAppWidgetManager(context).getAppWidgetId(id)
        val mac = if (app.isPrimaryUser) widgetMac(app, WidgetTargets.get(context, appWidgetId)) else null
        val model = widgetModel(mac)
        provideContent { GlanceTheme { MacWidgetContent(context, model, mac?.deviceId) } }
    }

    companion object {
        /** Redraws every Bridgey widget (state changed). */
        suspend fun refresh(context: Context) = MacWidget().updateAll(context)
    }
}

private val KeyDevice = ActionParameters.Key<String>("device")
private val KeyAction = ActionParameters.Key<String>("action")

/** A widget button tap: a Mac action or Ping, through the coordinator. */
class MacWidgetAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val app = context.applicationContext as BridgeyApplication
        if (!app.isPrimaryUser) return
        val device = parameters[KeyDevice] ?: return
        val command = when (val action = parameters[KeyAction] ?: return) {
            "ping" -> ControlCommand.Ping(device)
            else -> ControlCommand.Run(device, action)
        }
        runControlCommand(app, command)
    }
}

@Composable
internal fun MacWidgetContent(context: Context, model: WidgetModel, deviceId: String?) {
    // The Stream tokens, light and dark.
    val light = LightBridgeyColors
    val dark = DarkBridgeyColors
    val surface = ColorProvider(day = light.surface1, night = dark.surface1)
    val tile = ColorProvider(day = light.surface2, night = dark.surface2)
    val onSurface = ColorProvider(day = light.onSurface, night = dark.onSurface)
    val muted = ColorProvider(day = light.onSurfaceVariant, night = dark.onSurfaceVariant)
    val accent = ColorProvider(day = light.onTintBlue, night = dark.onTintBlue)
    val dim = ColorProvider(day = light.surface4, night = dark.surface4)
    val good = ColorProvider(day = light.good, night = dark.good)
    Column(
        GlanceModifier.fillMaxSize().background(surface).cornerRadius(24.dp).padding(12.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        Row(GlanceModifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(GlanceModifier.size(8.dp).cornerRadius(4.dp).background(if (model.connected) good else dim)) {}
            Spacer(GlanceModifier.width(8.dp))
            Text(
                model.name ?: context.getString(R.string.widget_name),
                style = TextStyle(color = onSurface, fontSize = 15.sp, fontWeight = FontWeight.Medium),
                maxLines = 1,
                modifier = GlanceModifier.defaultWeight(),
            )
            Text(context.getString(model.status), style = TextStyle(color = muted, fontSize = 12.sp), maxLines = 1)
        }
        Spacer(GlanceModifier.height(10.dp))
        if (model.buttons.isEmpty() || deviceId == null) return@Column
        listOf(model.buttons.take(3), model.buttons.drop(3)).forEachIndexed { rowIndex, row ->
            if (rowIndex > 0) Spacer(GlanceModifier.height(6.dp))
            Row(GlanceModifier.fillMaxWidth().defaultWeight()) {
                row.forEachIndexed { index, button ->
                    if (index > 0) Spacer(GlanceModifier.width(6.dp))
                    val action = when {
                        !button.enabled -> null
                        button.sendCopied -> androidx.glance.appwidget.action.actionStartActivity(
                            android.content.Intent(context, dev.bridgey.android.ClipboardCaptureActivity::class.java)
                                .putExtra(dev.bridgey.android.ClipboardCaptureActivity.EXTRA_DEVICE_ID, deviceId)
                                .setData(android.net.Uri.parse("bridgey-send:$deviceId")),
                        )
                        else -> actionRunCallback<MacWidgetAction>(
                            actionParametersOf(
                                KeyDevice to deviceId,
                                KeyAction to when (val command = button.command) {
                                    is ControlCommand.Run -> command.actionId
                                    is ControlCommand.Ping -> "ping"
                                    else -> ""
                                },
                            ),
                        )
                    }
                    val base = GlanceModifier.defaultWeight().fillMaxHeight().background(tile).cornerRadius(16.dp)
                    Column(
                        if (action != null) base.clickable(action) else base,
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Image(
                            ImageProvider(button.icon),
                            context.getString(button.label),
                            colorFilter = ColorFilter.tint(if (button.enabled) accent else dim),
                            modifier = GlanceModifier.size(22.dp),
                        )
                        Text(
                            context.getString(button.label),
                            style = TextStyle(color = if (button.enabled) onSurface else muted, fontSize = 11.sp),
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}

class MacWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = MacWidget()

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        WidgetTargets.remove(context, appWidgetIds)
        super.onDeleted(context, appWidgetIds)
    }
}

/** True when at least one Bridgey widget is on a home screen, so updates are worth computing. */
internal fun hasWidgets(context: Context): Boolean = runCatching {
    AppWidgetManager.getInstance(context)
        .getAppWidgetIds(android.content.ComponentName(context, MacWidgetReceiver::class.java)).isNotEmpty()
}.getOrDefault(false)

