package dev.bridgey.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the Settings section order Rahul agreed, mirrored by the macOS sidebar. Remote control
 * (2026-10-26) sits after Media and quick actions, the other "control the Mac" section. Since the
 * Settings pages (2026-10-26) the home shows This phone as a header card and the other sections as
 * rows in three groups: Devices, Features, App. Text messages (2026-10-27) follows Notifications; on the
 * Mac it is a card on the Notifications pane.
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
                SettingsSection.MESSAGES,
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

    @Test
    fun homeRowsAreGroupedDevicesFeaturesApp() {
        assertEquals(
            mapOf(
                SettingsGroup.DEVICES to listOf(SettingsSection.DEVICES),
                SettingsGroup.FEATURES to listOf(
                    SettingsSection.CLIPBOARD,
                    SettingsSection.NOTIFICATIONS,
                    SettingsSection.MESSAGES,
                    SettingsSection.CALLS,
                    SettingsSection.FILES,
                    SettingsSection.MEDIA,
                    SettingsSection.REMOTE_CONTROL,
                ),
                SettingsGroup.APP to listOf(
                    SettingsSection.PRIVACY,
                    SettingsSection.UPDATES,
                    SettingsSection.GENERAL,
                    SettingsSection.ABOUT,
                ),
            ),
            SettingsSection.homeRows.groupBy { it.group },
        )
        // This phone is the header card, not a row.
        assertNull(SettingsSection.THIS_PHONE.group)
        assertEquals(SettingsSection.entries.drop(1), SettingsSection.homeRows)
    }

    @Test
    fun everySectionHasAPageThatSurvivesRestore() {
        assertEquals(Route.Devices, settingsRoute(SettingsSection.DEVICES))
        assertEquals(Route.Settings, settingsRoute(SettingsSection.THIS_PHONE))
        SettingsSection.homeRows.forEach { section ->
            val route = settingsRoute(section)
            assertEquals(route, Route.fromKey(route.key))
        }
        assertEquals(Route.SettingsPane(SettingsSection.UPDATES), Route.fromKey("settings:updates"))
        assertNull(Route.fromKey("settings:nope"))
    }

    @Test
    fun aDeepLinkOpensThePageAboveTheSettingsHome() {
        val fromHome = BackStack(listOf(Route.Home))
        fromHome.openSettings(settingsRoute(SettingsSection.UPDATES))
        assertEquals(listOf(Route.Home, Route.Settings, Route.SettingsPane(SettingsSection.UPDATES)), fromHome.entries.toList())

        val inSettings = BackStack(listOf(Route.Home, Route.Settings, Route.SettingsPane(SettingsSection.FILES), Route.Places))
        inSettings.openSettings(settingsRoute(SettingsSection.UPDATES))
        assertEquals(listOf(Route.Home, Route.Settings, Route.SettingsPane(SettingsSection.UPDATES)), inSettings.entries.toList())

        val already = BackStack(listOf(Route.Home, Route.Settings, Route.SettingsPane(SettingsSection.UPDATES)))
        already.openSettings(settingsRoute(SettingsSection.UPDATES))
        assertEquals(3, already.entries.size)

        assertEquals(SettingsSection.UPDATES, SettingsDeepLink.section("UPDATES"))
        assertNull(SettingsDeepLink.section(null))
    }
}
