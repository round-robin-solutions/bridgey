package dev.bridgey.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/** Compatibility for Bridgey's internal explicit intents. Only Send to Mac is exported. */
class OpenOnMacActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(intent).setClass(this, SendToMacActivity::class.java))
        finish()
    }
}
