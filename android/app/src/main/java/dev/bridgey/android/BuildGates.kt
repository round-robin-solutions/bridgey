package dev.bridgey.android

/**
 * Features the Google Play build leaves out (build type "play"): the self-updater (Play updates the
 * app) and Text messages (READ_SMS/SEND_SMS). The GitHub builds keep both.
 */
object BuildGates {
    val selfUpdate: Boolean get() = BuildConfig.UPDATE_FEED_BASE_URL.startsWith("https://")
    val sms: Boolean get() = BuildConfig.SMS_AVAILABLE

    /** False for a feature this build does not have, whatever the saved or synced setting says. */
    fun featureBuilt(feature: BridgeyFeature): Boolean = feature != BridgeyFeature.SMS || sms
}
