package dev.bridgey.android.ui.search

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.PairingState
import dev.bridgey.android.R
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.agents.AGENT_PLATFORM
import dev.bridgey.android.agents.AgentGrant
import dev.bridgey.android.agents.AgentInfo
import dev.bridgey.android.agents.GrantShown
import dev.bridgey.android.agents.GrantView
import dev.bridgey.android.setup.OemChecklist
import dev.bridgey.android.setup.OemStep
import dev.bridgey.android.setup.OemStepKind
import dev.bridgey.android.setup.OemVendor
import dev.bridgey.android.setup.PermissionEntry
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.PermissionState
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.SyncRowStatus
import dev.bridgey.android.sync.SyncSwitches
import dev.bridgey.android.sync.SyncUiState
import dev.bridgey.android.ui.AgentDeviceScreen
import dev.bridgey.android.ui.AgentPageActions
import dev.bridgey.android.ui.AgentPageState
import dev.bridgey.android.ui.CodesSettingsState
import dev.bridgey.android.ui.ConnectSettingsState
import dev.bridgey.android.ui.ConnectState
import dev.bridgey.android.ui.DeviceActions
import dev.bridgey.android.ui.DeviceScreen
import dev.bridgey.android.ui.DeviceState
import dev.bridgey.android.ui.DeviceSyncState
import dev.bridgey.android.ui.DeviceTab
import dev.bridgey.android.ui.DevicesSettingsActions
import dev.bridgey.android.ui.DevicesSettingsScreen
import dev.bridgey.android.ui.DevicesSettingsState
import dev.bridgey.android.ui.FocusSettingsState
import dev.bridgey.android.ui.MessagesSettingsState
import dev.bridgey.android.ui.PermissionRow
import dev.bridgey.android.ui.PermissionsScreen
import dev.bridgey.android.ui.ResetScreen
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsActions
import dev.bridgey.android.ui.SettingsScreen
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.SettingsState
import dev.bridgey.android.ui.SetupSettingsState
import dev.bridgey.android.ui.deviceRings
import dev.bridgey.android.ui.sampleSettingsState
import dev.bridgey.android.ui.settingsRoute
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Settings search cannot drift from the pages: every settings row drawn on every page has a registry entry, and
 * every registry entry is still drawn on its page. Pages render in a very tall window so every list item is
 * composed, with states that turn on every conditional row (developer menu, background clipboard, dual SIM...).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h8000dp-port-mdpi")
class SettingsSearchDriftTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val now = 1_793_000_000_000L
    private val work = TrustedDevice("work", "Work MacBook")
    private val agent = TrustedDevice("agent1", "build-server", AGENT_PLATFORM)
    private val devices = listOf(SearchDevice(work.id, work.name, false), SearchDevice(agent.id, agent.name, true))

    @Before
    fun setUp() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(app.packageManager).addActivityIfNotPresent(ComponentName(app, ComponentActivity::class.java))
    }

    private data class Drawn(val route: String?, val title: String, val searchable: Boolean)

    /** Every row [content] draws, with the route key it was drawn under. */
    private fun record(routeKey: String, content: @Composable () -> Unit): List<Drawn> {
        val drawn = mutableListOf<Drawn>()
        val host = SettingsSearchHost().apply { recorder = { route, _, title, searchable -> drawn += Drawn(route, title, searchable) } }
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    BridgeyTheme {
                        CompositionLocalProvider(LocalSettingsSearch provides host, LocalSearchRoute provides routeKey) { content() }
                    }
                }
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
        }
        return drawn
    }

    /** Every conditional row on: developer menu, background clipboard, Wi-Fi lock, code link, dual SIM, OEM steps. */
    private fun fullState(): SettingsState {
        val base = sampleSettingsState(now)
        return base.copy(
            globalFeatures = BridgeyFeature.entries.associateWith { true },
            backgroundClipboardEnabled = true,
            keepWifiAwakeSupported = true,
            developerMenu = true,
            codes = CodesSettingsState(linkApplies = true),
            focus = FocusSettingsState(share = true, follow = true),
            messages = MessagesSettingsState(dualSim = true),
            setup = SetupSettingsState(oem = OemChecklist(OemVendor.ONEPLUS, listOf(OemStep(OemStepKind.AUTO_START, emptyList())))),
            connect = ConnectSettingsState(on = true, state = ConnectState.ONLINE, reachable = 1),
            // Sync on with status lines, so the lines are drawn (and must not count as settings).
            sync = SyncUiState(
                switches = SyncSwitches(enabled = true),
                rows = mapOf(SyncKey.CLIPBOARD to SyncRowStatus(waitingHere = true, differentOn = listOf("Work MacBook"), waitingOn = listOf("Mac mini"))),
            ),
        )
    }

    private fun deviceState(): DeviceState {
        val ring = deviceRings(listOf(work), emptyList(), PairingState.Connected("work", "Work MacBook")).first()
        val order = dev.bridgey.android.PermissionOrder

        return DeviceState(
            ring = ring, battery = null, connected = true, available = emptySet(), ringing = false,
            permissions = order.map { PermissionRow(it, checked = true, globallyOff = false, remotelyOff = false) },
            notificationAccess = true, notificationAppsEnabled = 3, autoClipboard = true, autoClipboardGlobalOn = true,
            activity = emptyList(), live = emptyList(), now = now,
            sync = DeviceSyncState(on = true, globalOn = true, offRemote = false),
        )
    }

    /** Each page: its route key and the rows it draws. */
    private fun drawAll(): Map<String, List<Drawn>> {
        val state = fullState()
        val pages = linkedMapOf<String, List<Drawn>>()
        pages[Route.Settings.key] = record(Route.Settings.key) { SettingsScreen(state = state, actions = SettingsActions()) }
        SettingsSection.entries.filter { it != SettingsSection.THIS_PHONE && it != SettingsSection.DEVICES }.forEach { section ->
            val key = settingsRoute(section).key
            pages[key] = record(key) { SettingsScreen(state = state, actions = SettingsActions(), section = section) }
        }
        pages[Route.Devices.key] = record(Route.Devices.key) {
            DevicesSettingsScreen(
                DevicesSettingsState(deviceRings(listOf(work, agent), emptyList(), PairingState.Connected("work", "Work MacBook")), connect = state.connect),
                DevicesSettingsActions(),
            )
        }
        pages[Route.Permissions.key] = record(Route.Permissions.key) {
            PermissionsScreen(PermissionKind.entries.map { PermissionEntry(it, PermissionState.ALLOWED) }, onBack = {}) {}
        }
        pages[Route.Reset.key] = record(Route.Reset.key) { ResetScreen(null, null, {}, {}, {}) }
        val deviceKey = Route.Device(work.id).key
        pages[deviceKey] = record(deviceKey) {
            DeviceScreen(deviceState(), DeviceActions(), remember { SnackbarHostState() }, { "" }, initialTab = DeviceTab.PERMISSIONS)
        }
        val agentKey = Route.Device(agent.id).key
        pages[agentKey] = record(agentKey) {
            val ring = deviceRings(listOf(agent), emptyList(), PairingState.Idle).first()
            AgentDeviceScreen(
                AgentPageState(
                    ring = ring, info = AgentInfo("bridgey", "linux", now, now), connected = true,
                    grants = AgentGrant.entries.map { GrantView(it, GrantShown.OFF) }, activity = emptyList(),
                    showPresets = false, folderName = "build-server", now = now, overTailnet = true,
                ),
                AgentPageActions(),
            )
        }
        return pages
    }

    @Test fun everyRowHasAnEntryAndEveryEntryIsDrawn() {
        val pages = drawAll()
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = fullState().sync, devices = devices)
        val offered = entries.filter { it.rowTitle != null }.groupBy({ it.route.key }, { it.rowTitle!! })
        val problems = mutableListOf<String>()
        pages.forEach { (key, drawn) ->
            assertTrue("$key drew no rows", drawn.isNotEmpty())
            // The Devices list shows each device by name; search offers the device's own page for it.
            val allowed = offered[key].orEmpty().toSet() + if (key == Route.Devices.key) devices.map { it.name } else emptyList()
            drawn.filter { it.searchable && it.route == key }.map { it.title }.toSet().forEach { title ->
                if (title !in allowed) problems += "$key: row \"$title\" has no search entry"
            }
        }
        entries.filter { it.rowTitle != null }.forEach { entry ->
            val drawn = pages[entry.route.key]?.filter { it.searchable }?.map { it.title }.orEmpty()
            if (entry.rowTitle !in drawn) problems += "${entry.route.key}: entry ${entry.id} (\"${entry.rowTitle}\") is not drawn"
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
        // Guard against a harness that draws nothing: the pages hold well over a hundred settings rows.
        val total = pages.values.sumOf { drawn -> drawn.count { it.searchable } }
        pages.forEach { (key, drawn) -> println("drift: $key ${drawn.count { it.searchable }} rows") }
        assertTrue("only $total rows drawn", total >= 120)
    }

    @Test fun statusLinesAreNotOffered() {
        val clipboard = drawAll().getValue(settingsRoute(SettingsSection.CLIPBOARD).key)
        val waiting = context.getString(R.string.settings_sync_waiting_here)
        assertTrue(clipboard.any { it.title == waiting && !it.searchable })
    }

    @Test fun developerRowsOnlyWithTheMenu() {
        val off = SettingsSearchRegistry.resolve(context, developerMenu = false, sync = SyncUiState(), devices = emptyList())
        assertTrue(off.none { it.route == settingsRoute(SettingsSection.DEVELOPER) })
        val on = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = SyncUiState(), devices = emptyList())
        assertTrue(on.any { it.route == settingsRoute(SettingsSection.DEVELOPER) })
    }

    private fun topIds(query: String, entries: List<SearchResultEntry>): List<String> =
        SettingsSearch.search(query, entries.map { it.doc }).map { entries[it.index].id }

    @Test fun synonymsReachTheirSettings() {
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = false, sync = SyncUiState(), devices = devices)
        assertTrue(topIds("otp", entries).first().startsWith("notifications.codes"))
        assertEquals("away.switch", topIds("relay", entries).first())
        assertEquals("away.switch", topIds("hotspot", entries).first())
        assertEquals("away.switch", topIds("tailscale", entries).first())
        assertTrue(topIds("update", entries).first().startsWith("updates."))
        assertEquals("general.reduceMotion", topIds("animation", entries).first())
        // Russian synonyms work whatever the app's language.
        assertTrue(topIds("одноразовый код", entries).first().startsWith("notifications.codes"))
        assertTrue(topIds("обновление", entries).first().startsWith("updates."))
    }

    @Test fun devicesAreFoundByName() {
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = false, sync = SyncUiState(), devices = devices)
        val hits = topIds("build-server", entries)
        assertEquals("device.agent1", hits.first())
        val work = SettingsSearch.search("work clipboard", entries.map { it.doc }).map { entries[it.index] }
        assertEquals(Route.Device("work"), work.first().route)
        assertEquals(context.getString(R.string.feature_clipboard), work.first().rowTitle)
        assertTrue(work.first().breadcrumb.contains(" › Work MacBook › "))
    }

    @Test fun syncedRowsAreFoundAsSyncedAndByTheirStatus() {
        val sync = SyncUiState(
            switches = SyncSwitches(enabled = true),
            rows = mapOf(SyncKey.REDUCE_MOTION to SyncRowStatus(waitingOn = listOf("Mac mini"))),
        )
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = false, sync = sync, devices = emptyList())
        assertTrue("general.reduceMotion" in topIds("synced", entries))
        assertEquals("general.reduceMotion", topIds("needs permission mac mini", entries).first())
        val off = SettingsSearchRegistry.resolve(context, developerMenu = false, sync = SyncUiState(switches = SyncSwitches(enabled = false)), devices = emptyList())
        assertTrue("general.reduceMotion" !in topIds("synced", off))
    }

    /** Every string search uses exists in English and Russian, and search's own strings have no em dash. */
    @Test fun stringsExistInEnglishAndRussian() {
        val res = File("src/main/res")
        fun names(dir: String): Set<String> = File(res, dir).listFiles { f -> f.name.endsWith(".xml") }.orEmpty()
            .flatMap { Regex("<(?:string|plurals) name=\"([a-z0-9_]+)\"").findAll(it.readText()).map { m -> m.groupValues[1] }.toList() }.toSet()
        val en = names("values")
        val ru = names("values-ru")
        val ids = SettingsSearchRegistry.entries.flatMap { listOfNotNull(it.title, it.subtitle, it.section) } +
            SearchPage.entries.map { it.titleRes }
        val missing = ids.toSet().map { context.resources.getResourceEntryName(it) }.filter { it !in en || it !in ru }
        assertTrue("missing: $missing", missing.isEmpty())
        listOf("values/strings_search.xml", "values-ru/strings_search.xml").forEach { path ->
            assertTrue("$path has an em dash", '\u2014' !in File(res, path).readText())
        }
    }
}
