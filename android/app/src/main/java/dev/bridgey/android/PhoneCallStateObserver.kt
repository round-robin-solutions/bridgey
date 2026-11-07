package dev.bridgey.android

import android.content.Context
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.annotation.RequiresApi

/** Phone-state events for every supported Android version, with no phone-number access. */
@Suppress("DEPRECATION") // PhoneStateListener is the supported API on Android 8–11.
internal class PhoneCallStateObserver(
    private val context: Context,
    private val onState: (Int) -> Unit,
) {
    private var manager: TelephonyManager? = null
    private var callback: TelephonyCallback? = null
    private var legacyListener: PhoneStateListener? = null
    private var generation = 0

    /** The notification listener checks the feature and READ_PHONE_STATE grant before starting. */
    @Suppress("DEPRECATION")
    @android.annotation.SuppressLint("MissingPermission")
    fun start() {
        stop()
        val telephony = context.getSystemService(TelephonyManager::class.java) ?: return
        val observing = generation
        manager = telephony
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val listener = ModernListener { state ->
                    if (generation == observing) onState(state)
                }
                callback = listener
                telephony.registerTelephonyCallback(context.mainExecutor, listener)
            } else {
                // This is the supported API before Android 12. Constructed on the service's main
                // thread, so callbacks share the lifecycle's Handler and never collect the number.
                val listener = object : PhoneStateListener() {
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        if (generation == observing) onState(state)
                    }
                }
                legacyListener = listener
                telephony.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            }
        } catch (failure: RuntimeException) {
            stop()
            throw failure
        }
    }

    /** Invalidates queued callbacks as well as unregistering from the exact manager used to start. */
    @Suppress("DEPRECATION")
    fun stop() {
        generation += 1
        val telephony = manager
        manager = null
        val modern = callback
        callback = null
        val legacy = legacyListener
        legacyListener = null
        if (telephony == null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && modern != null) {
            runCatching { telephony.unregisterTelephonyCallback(modern) }
        }
        if (legacy != null) {
            runCatching { telephony.listen(legacy, PhoneStateListener.LISTEN_NONE) }
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private class ModernListener(private val changed: (Int) -> Unit) :
        TelephonyCallback(), TelephonyCallback.CallStateListener {
        override fun onCallStateChanged(state: Int) = changed(state)
    }
}
