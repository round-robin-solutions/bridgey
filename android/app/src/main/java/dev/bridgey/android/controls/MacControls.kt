package dev.bridgey.android.controls

import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.actions.MacActionCatalog
import dev.bridgey.android.actions.MacActionIds
import dev.bridgey.android.actions.MacActionKind
import dev.bridgey.android.actions.MacVolume

/*
 * Device Controls and widgets (Android 11+ power menu, Android 12+ Quick Settings "Device
 * controls"): what each paired Mac offers, as plain data. The service turns a [ControlSpec] into
 * an Android `Control`; keeping the mapping here keeps it testable without the framework.
 */

/** One paired Mac as controls see it. [catalog] is the last known one, also while offline. */
data class ControlMac(
    val deviceId: String,
    val name: String,
    val connected: Boolean,
    /** Features usable with this Mac right now (on both sides and connected). */
    val available: Set<BridgeyFeature>,
    val catalog: MacActionCatalog?,
    /** The catalog came from the Mac in its current session, so its entries can run. */
    val catalogLive: Boolean,
    val ringing: Boolean,
)

enum class ControlKind {
    /** Stateless: lock, sleep, screen saver, an app or a Shortcut. */
    ACTION,

    /** Range 0 to 100: `volume_set`. */
    VOLUME,

    /** Toggle: `volume_mute`, checked while muted. */
    MUTE,
    PING,

    /** Toggle: checked while the Mac rings. */
    FIND,

    /** No template: a tap opens the clipboard reader aimed at this Mac (a service cannot read the clipboard). */
    SEND_COPIED,
}

enum class ControlLabel { LOCK, SLEEP, SCREENSAVER, VOLUME, MUTE, PING, FIND, SEND_COPIED, APP, SHORTCUT }

enum class ControlState {
    READY,

    /** The Mac is not connected. */
    OFFLINE,

    /** Connected, but the feature is off on one side, or the Mac needs a permission first. */
    UNAVAILABLE,
}

data class ControlSpec(
    val controlId: String,
    val deviceId: String,
    val kind: ControlKind,
    val label: ControlLabel,
    /** App or Shortcut name from the Mac's list; null for fixed controls (translated here). */
    val customTitle: String?,
    /** The Mac's name: the control's subtitle and zone. */
    val macName: String,
    val state: ControlState,
    /** The action identifier for ACTION, VOLUME and MUTE. */
    val actionId: String? = null,
    val volume: MacVolume? = null,
    val checked: Boolean = false,
    /** The Mac said it needs a permission (Accessibility for Lock). */
    val blocked: Boolean = false,
)

/** `<deviceId>|<element>`: device IDs are UUIDs, so `|` never appears in them. */
fun controlId(deviceId: String, element: String): String = "$deviceId|$element"

/** The device and element of a control ID, or null. */
fun parseControlId(id: String): Pair<String, String>? {
    val index = id.indexOf('|')
    if (index <= 0 || index == id.length - 1) return null
    return id.substring(0, index) to id.substring(index + 1)
}

const val ELEMENT_PING = "ping"
const val ELEMENT_FIND = "find"
const val ELEMENT_SEND = "send"
const val ELEMENT_VOLUME = "volume"
fun actionElement(actionId: String) = "action:$actionId"

/**
 * Every control for every paired Mac, in a stable order: lock, sleep, screen saver, volume and
 * mute, apps and Shortcuts from the Mac's list, then Ping, Find and Send copied item, which every
 * Mac has.
 */
fun controlSpecs(macs: List<ControlMac>): List<ControlSpec> = macs.flatMap { mac ->
    fun state(feature: BridgeyFeature, liveCatalog: Boolean = true): ControlState = when {
        !mac.connected -> ControlState.OFFLINE
        feature !in mac.available || !liveCatalog -> ControlState.UNAVAILABLE
        else -> ControlState.READY
    }
    val actionsState = state(BridgeyFeature.MAC_ACTIONS, mac.catalogLive)
    val catalog = mac.catalog
    buildList {
        if (catalog != null) {
            for (entry in catalog.system) {
                val label = when (entry.id) {
                    MacActionIds.LOCK -> ControlLabel.LOCK
                    MacActionIds.SLEEP -> ControlLabel.SLEEP
                    else -> ControlLabel.SCREENSAVER
                }
                val blocked = entry.blocked != null
                add(ControlSpec(controlId(mac.deviceId, actionElement(entry.id)), mac.deviceId, ControlKind.ACTION, label, null, mac.name,
                    if (blocked && actionsState == ControlState.READY) ControlState.UNAVAILABLE else actionsState, entry.id, blocked = blocked))
            }
            if (catalog.has(MacActionIds.VOLUME_SET)) {
                add(ControlSpec(controlId(mac.deviceId, ELEMENT_VOLUME), mac.deviceId, ControlKind.VOLUME, ControlLabel.VOLUME, null, mac.name,
                    actionsState, MacActionIds.VOLUME_SET, volume = catalog.volume))
            }
            if (catalog.has(MacActionIds.VOLUME_MUTE)) {
                add(ControlSpec(controlId(mac.deviceId, actionElement(MacActionIds.VOLUME_MUTE)), mac.deviceId, ControlKind.MUTE, ControlLabel.MUTE, null,
                    mac.name, actionsState, MacActionIds.VOLUME_MUTE, volume = catalog.volume, checked = catalog.volume?.muted == true))
            }
            for (entry in catalog.apps + catalog.shortcuts) {
                val label = if (entry.kind == MacActionKind.APP) ControlLabel.APP else ControlLabel.SHORTCUT
                add(ControlSpec(controlId(mac.deviceId, actionElement(entry.id)), mac.deviceId, ControlKind.ACTION, label, entry.title, mac.name,
                    actionsState, entry.id))
            }
        }
        add(ControlSpec(controlId(mac.deviceId, ELEMENT_PING), mac.deviceId, ControlKind.PING, ControlLabel.PING, null, mac.name, state(BridgeyFeature.PING)))
        add(ControlSpec(controlId(mac.deviceId, ELEMENT_FIND), mac.deviceId, ControlKind.FIND, ControlLabel.FIND, null, mac.name,
            state(BridgeyFeature.FIND_DEVICE), checked = mac.connected && mac.ringing))
        add(ControlSpec(controlId(mac.deviceId, ELEMENT_SEND), mac.deviceId, ControlKind.SEND_COPIED, ControlLabel.SEND_COPIED, null, mac.name,
            state(BridgeyFeature.CLIPBOARD)))
    }
}

/** What a tap on a control should do. */
sealed interface ControlCommand {
    data class Run(val deviceId: String, val actionId: String, val value: Int? = null) : ControlCommand
    data class Ping(val deviceId: String) : ControlCommand
    data class Find(val deviceId: String, val start: Boolean) : ControlCommand
}

/**
 * The command for a tap on [spec]: [floatValue] for a range, [booleanValue] for a toggle. Null when
 * the control cannot run now (offline, unavailable) or the input does not fit the control.
 */
fun controlCommand(spec: ControlSpec, floatValue: Float? = null, booleanValue: Boolean? = null): ControlCommand? {
    if (spec.state != ControlState.READY) return null
    return when (spec.kind) {
        ControlKind.ACTION -> spec.actionId?.let { ControlCommand.Run(spec.deviceId, it) }
        ControlKind.VOLUME -> floatValue?.takeIf { !it.isNaN() }?.let { ControlCommand.Run(spec.deviceId, MacActionIds.VOLUME_SET, it.toInt().coerceIn(0, 100)) }
        ControlKind.MUTE -> ControlCommand.Run(spec.deviceId, MacActionIds.VOLUME_MUTE)
        ControlKind.PING -> ControlCommand.Ping(spec.deviceId)
        ControlKind.FIND -> ControlCommand.Find(spec.deviceId, booleanValue ?: !spec.checked)
        ControlKind.SEND_COPIED -> null
    }
}
