package dev.bridgey.android.codes

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.activity.ComponentActivity
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Why "Link this phone to the Mac" stopped. */
enum class LinkFailure(val wire: String) {
    NO_MAC("no_mac"),
    MAC_TOO_OLD("mac_too_old"),
    MAC_NO_ANSWER("mac_no_answer"),
    MAC_BLUETOOTH_OFF("bluetooth_off"),
    MAC_BLUETOOTH_DENIED("unauthorized"),
    MAC_UNSUPPORTED("unsupported"),
    PHONE_UNSUPPORTED("phone_unsupported"),
    CANCELLED("cancelled"),
    FAILED("failed"),
    ;

    companion object {
        /** The Mac's `codes.advertise_result` reason. */
        fun fromMac(reason: String?): LinkFailure = when (reason) {
            "bluetooth_off" -> MAC_BLUETOOTH_OFF
            "unauthorized" -> MAC_BLUETOOTH_DENIED
            "unsupported" -> MAC_UNSUPPORTED
            else -> FAILED
        }
    }
}

sealed interface CompanionLinkState {
    data object Idle : CompanionLinkState
    /** Waiting for the Mac to start its one-minute Bluetooth advertisement. */
    data object AskingMac : CompanionLinkState
    /** Android's own dialog is looking for the Mac. */
    data object Searching : CompanionLinkState
    data object Linked : CompanionLinkState
    data class Failed(val reason: LinkFailure) : CompanionLinkState
}

/** What the linker needs from the connection layer, so it can be driven without a phone. */
interface CompanionLinkTransport {
    /** The connected Mac to link with, if it supports `sms_codes_draft1`. Null: none; MAC_TOO_OLD is told apart by [macTooOld]. */
    fun linkTarget(): String?
    fun macTooOld(): Boolean
    /** Sends `codes.advertise`; [onResult] runs once on the main thread (ok, Mac's reason). */
    fun requestAdvertising(deviceId: String, serviceUuid: UUID, onResult: (Boolean, String?) -> Unit)
    fun stopAdvertising(deviceId: String, serviceUuid: UUID, linked: Boolean)
}

/**
 * "Link this phone to the Mac": the Mac advertises a one-off Bluetooth LE service UUID for a minute,
 * Android's Companion Device Manager dialog finds it (filtered to that UUID, single device), the person
 * taps Allow, and Bridgey asks Android to reconnect its notification listener, which is when Android
 * decides whether to trust it. Created in the activity's onCreate (it registers an activity result).
 */
class CompanionLinker(
    private val activity: ComponentActivity,
    private val transport: () -> CompanionLinkTransport,
    private val onLinked: () -> Unit,
) {
    private val mutableState = MutableStateFlow<CompanionLinkState>(CompanionLinkState.Idle)
    val state: StateFlow<CompanionLinkState> = mutableState.asStateFlow()
    private var attempt: Pair<String, UUID>? = null
    private val launcher = activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK) linked() else fail(LinkFailure.CANCELLED)
    }

    fun start() {
        if (mutableState.value == CompanionLinkState.AskingMac || mutableState.value == CompanionLinkState.Searching) return
        mutableState.value = CompanionLinkState.Idle
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)) {
            return fail(LinkFailure.PHONE_UNSUPPORTED)
        }
        val link = transport()
        val deviceId = link.linkTarget() ?: return fail(if (link.macTooOld()) LinkFailure.MAC_TOO_OLD else LinkFailure.NO_MAC)
        val uuid = UUID.randomUUID()
        attempt = deviceId to uuid
        mutableState.value = CompanionLinkState.AskingMac
        link.requestAdvertising(deviceId, uuid) { ok, reason ->
            if (attempt?.second != uuid) return@requestAdvertising
            if (ok) associate(uuid) else fail(if (reason == null) LinkFailure.MAC_NO_ANSWER else LinkFailure.fromMac(reason))
        }
    }

    fun reset() {
        if (mutableState.value is CompanionLinkState.Failed || mutableState.value == CompanionLinkState.Linked) {
            mutableState.value = CompanionLinkState.Idle
        }
    }

    private fun associate(uuid: UUID) {
        val manager = activity.getSystemService(CompanionDeviceManager::class.java) ?: return fail(LinkFailure.PHONE_UNSUPPORTED)
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build())
            .build()
        val request = AssociationRequest.Builder()
            .addDeviceFilter(filter)
            .setSingleDevice(true)
            .build()
        mutableState.value = CompanionLinkState.Searching
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                manager.associate(request, activity.mainExecutor, object : CompanionDeviceManager.Callback() {
                    override fun onAssociationPending(intentSender: IntentSender) = launch(intentSender)
                    override fun onAssociationCreated(associationInfo: AssociationInfo) = linked()
                    override fun onFailure(error: CharSequence?) = fail(LinkFailure.FAILED)
                })
            } else {
                @Suppress("DEPRECATION")
                manager.associate(request, object : CompanionDeviceManager.Callback() {
                    @Deprecated("Android 13 replaced it with onAssociationPending")
                    override fun onDeviceFound(intentSender: IntentSender) = launch(intentSender)
                    override fun onFailure(error: CharSequence?) = fail(LinkFailure.FAILED)
                }, Handler(Looper.getMainLooper()))
            }
        }.onFailure {
            BridgeyLogging.w(LogCategory.NOTIFICATIONS, "CODES companion association could not start", it)
            fail(LinkFailure.FAILED)
        }
    }

    private fun launch(intentSender: IntentSender) {
        runCatching { launcher.launch(IntentSenderRequest.Builder(intentSender).build()) }
            .onFailure { fail(LinkFailure.FAILED) }
    }

    private fun linked() {
        if (mutableState.value == CompanionLinkState.Linked) return
        val (deviceId, uuid) = attempt ?: return
        attempt = null
        transport().stopAdvertising(deviceId, uuid, linked = true)
        BridgeyLogging.i(LogCategory.NOTIFICATIONS, "CODES companion link created")
        mutableState.value = CompanionLinkState.Linked
        onLinked()
    }

    private fun fail(reason: LinkFailure) {
        // Android 13+ reports a created association and then the dialog's result; a late result never undoes it.
        if (mutableState.value == CompanionLinkState.Linked && attempt == null) return
        attempt?.let { (deviceId, uuid) -> transport().stopAdvertising(deviceId, uuid, linked = false) }
        attempt = null
        BridgeyLogging.i(LogCategory.NOTIFICATIONS, "CODES companion link stopped reason=${reason.wire}")
        mutableState.value = CompanionLinkState.Failed(reason)
    }
}
