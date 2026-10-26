package dev.bridgey.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the Settings section order Rahul agreed, mirrored by the macOS app. Remote control
 * (2026-10-26) sits after Media and quick actions, the other "control the Mac" section.
 */
class SettingsSectionOrderTest {
    @Test
    fun sectionsAreInTheAgreedOrder() {
        assertEquals(
            listOf(
                SettingsSection.THIS_PHONE,
                SettingsSection.DEVICES,
                SettingsSection.CLIPBOARD,
                SettingsSection.NOTIFICATIONS,
                SettingsSection.CALLS,
                SettingsSection.FILES,
                SettingsSection.MEDIA,
                SettingsSection.REMOTE_CONTROL,
                SettingsSection.PRIVACY,
                SettingsSection.UPDATES,
                SettingsSection.GENERAL,
                SettingsSection.ABOUT,
            ),
            SettingsSection.entries.toList(),
        )
    }
}
