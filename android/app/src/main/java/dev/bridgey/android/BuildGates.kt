package dev.bridgey.android

/**
 * Features the Google Play build leaves out (build type "play"): the self-updater (Play updates the
 * app) and Text messages (READ_SMS/SEND_SMS). The GitHub builds keep both.
 */
object BuildGates {
    val selfUpdate: Boolean get() = BuildConfig.UPDATE_FEED_BASE_URL.startsWith("https://")
    val sms: Boolean get() = BuildConfig.SMS_AVAILABLE

    /** READ_CONTACTS for the Calls window (Text messages uses it too, under [sms]). Off in the Play build. */
    val contacts: Boolean get() = BuildConfig.CONTACTS_AVAILABLE

    /** READ_CALL_LOG for the Calls window's recent calls. Off in the Play build. */
    val callLog: Boolean get() = BuildConfig.CALL_LOG_AVAILABLE

    /** A Mac controlling this phone through Bridgey's accessibility service. Off in the Play build. */
    val phoneControl: Boolean get() = BuildConfig.PHONE_CONTROL_AVAILABLE

    /** False for a feature this build does not have, whatever the saved or synced setting says. */
    fun featureBuilt(feature: BridgeyFeature): Boolean = feature != BridgeyFeature.SMS || sms
}
