package dev.bridgey.android.ui

import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PermissionOrder
import dev.bridgey.android.ui.search.SettingsSearchRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins Settings in six groups (direction A, chosen 26 Nov 2026), mirrored by the macOS sidebar: Devices, Sharing,
 * Notifications and calls ("Phone" on the Mac), Control, Privacy, App. Every page that existed before has a group and a
 * card, so every place that opened one still lands somewhere.
 */
class SettingsSectionOrderTest {
    @Test
    fun groupsAreInTheAgreedOrder() {
        assertEquals(
            listOf(SettingsGroup.DEVICES, SettingsGroup.SHARING, SettingsGroup.PHONE, SettingsGroup.CONTROL, SettingsGroup.PRIVACY, SettingsGroup.APP),
            SettingsGroup.entries.toList(),
        )
    }

    /** The old pages, each to the group the plan put it in (outputs/bridgey/settings-redesign/spec.md). */
    @Test
    fun everyOldPageMapsToAGroup() {
        val expected = mapOf(
            SettingsSection.THIS_PHONE to SettingsGroup.DEVICES,
            SettingsSection.DEVICES to SettingsGroup.DEVICES,
            SettingsSection.AWAY to SettingsGroup.DEVICES,
            SettingsSection.CLIPBOARD to SettingsGroup.SHARING,
            SettingsSection.FILES to SettingsGroup.SHARING,
            SettingsSection.MEDIA to SettingsGroup.SHARING,
            SettingsSection.NOTIFICATIONS to SettingsGroup.PHONE,
            SettingsSection.MESSAGES to SettingsGroup.PHONE,
            SettingsSection.CALLS to SettingsGroup.PHONE,
            SettingsSection.REMOTE_CONTROL to SettingsGroup.CONTROL,
            SettingsSection.PRIVACY to SettingsGroup.PRIVACY,
            SettingsSection.UPDATES to SettingsGroup.APP,
            SettingsSection.GENERAL to SettingsGroup.APP,
            SettingsSection.ABOUT to SettingsGroup.APP,
            SettingsSection.DEVELOPER to SettingsGroup.APP,
        )
        assertEquals("every section is mapped", SettingsSection.entries.toSet(), expected.keys)
        SettingsSection.entries.forEach { section ->
            assertEquals(section.name, expected.getValue(section), section.group)
            assertEquals(section.name, Route.SettingsGroupPage(section.group), settingsRoute(section))
        }
    }

    /** Every card sits in one group, each group has cards, and the old pages' features each have a card. */
    @Test
    fun everyCardHasAGroup() {
        SettingsGroup.entries.forEach { group -> assertTrue("$group has no cards", SettingsCard.entries.any { it.group == group }) }
        assertEquals(SettingsCard.entries.size, SettingsCard.entries.map { it.key }.toSet().size)
        // Ping, Find and Battery act on a device: Devices. The screens and Mac actions: Control.
        assertEquals(SettingsGroup.DEVICES, SettingsCard.FIND_PING.group)
        assertEquals(SettingsGroup.DEVICES, SettingsCard.BATTERY.group)
        assertEquals(SettingsGroup.CONTROL, SettingsCard.SHARE_SCREEN.group)
        assertEquals(SettingsGroup.CONTROL, SettingsCard.MAC_ACTIONS.group)
    }

    @Test
    fun everyPageSurvivesRestore() {
        SettingsGroup.entries.forEach { group ->
            val route = settingsRoute(group)
            assertEquals(route, Route.fromKey(route.key))
        }
        // Keys saved before the groups open the group that took the page over.
        assertEquals(Route.SettingsGroupPage(SettingsGroup.APP), Route.fromKey("settings:updates"))
        assertEquals(Route.SettingsGroupPage(SettingsGroup.SHARING), Route.fromKey("settings:clipboard"))
        assertEquals(Route.SettingsGroupPage(SettingsGroup.DEVICES), Route.fromKey("devices"))
        assertNull(Route.fromKey("settings:nope"))
    }

    @Test
    fun aDeepLinkOpensThePageAboveTheSettingsHome() {
        val updates = Route.SettingsGroupPage(SettingsGroup.APP)
        val fromHome = BackStack(listOf(Route.Home))
        fromHome.openSettings(settingsRoute(SettingsSection.UPDATES))
        assertEquals(listOf(Route.Home, Route.Settings, updates), fromHome.entries.toList())

        val inSettings = BackStack(listOf(Route.Home, Route.Settings, Route.SettingsGroupPage(SettingsGroup.SHARING), Route.Places))
        inSettings.openSettings(settingsRoute(SettingsSection.UPDATES))
        assertEquals(listOf(Route.Home, Route.Settings, updates), inSettings.entries.toList())

        val already = BackStack(listOf(Route.Home, Route.Settings, updates))
        already.openSettings(settingsRoute(SettingsSection.UPDATES))
        assertEquals(3, already.entries.size)

        assertEquals(SettingsSection.UPDATES, SettingsDeepLink.section("UPDATES"))
        assertNull(SettingsDeepLink.section(null))
    }

    /**
     * The chips replace the device page's switches one for one: every switch the page had is a chip row (and the
     * search ids count them in the same order), and every chip row's card is in the group of its feature.
     */
    @Test
    fun everyPerDeviceSwitchIsAChipRow() {
        assertEquals(SettingsSearchRegistry.devicePermissionRows, DeviceChoices.map { it.titleRes to it.features })
        val chipFeatures = DeviceChoices.filter { it.features.isNotEmpty() && !it.more }.map { it.features }.toSet()
        assertEquals(PermissionOrder.toSet(), chipFeatures)
        // Automatic clipboard per device sits in Clipboard's More options; sync per device in Sync settings.
        assertEquals(SettingsCard.CLIPBOARD, DeviceChoices.single { it.more }.card)
        assertEquals(SettingsCard.SYNC, DeviceChoices.single { it.features.isEmpty() }.card)
        assertEquals(SettingsCard.CALLS_WINDOW, DeviceChoices.single { it.features == listOf(BridgeyFeature.DIALER) }.card)
    }
}
