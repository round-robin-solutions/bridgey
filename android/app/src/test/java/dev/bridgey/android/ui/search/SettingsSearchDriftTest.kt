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
import dev.bridgey.android.ui.DialerMac
import dev.bridgey.android.ui.DialerSettingsState
import dev.bridgey.android.ui.PhoneControlMac
import dev.bridgey.android.ui.PhoneControlSettingsState
import dev.bridgey.android.control.PhoneControlGrantMode
import dev.bridgey.android.ui.FocusSettingsState
import dev.bridgey.android.ui.MessagesSettingsState
import dev.bridgey.android.ui.PermissionRow
import dev.bridgey.android.ui.PermissionsScreen
import dev.bridgey.android.ui.ResetScreen
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsActions
import dev.bridgey.android.ui.SettingsScreen
import dev.bridgey.android.ui.LocalCardsExpanded
import dev.bridgey.android.ui.SettingsDevice
import dev.bridgey.android.ui.SettingsGroup
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.SettingsState
import dev.bridgey.android.ui.SetupSettingsState
import dev.bridgey.android.ui.deviceRings
import dev.bridgey.android.ui.sampleSettingsState
import dev.bridgey.android.ui.settingsRoute
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

    private data class Drawn(val route: String?, val title: String, val searchable: Boolean, val scope: String? = null, val row: Any? = null)

    /** Every row [content] draws, with the route key it was drawn under; [expanded] opens or closes every More options. */
    private fun record(routeKey: String, expanded: Boolean? = null, content: @Composable () -> Unit): List<Drawn> {
        val drawn = mutableListOf<Drawn>()
        val host = SettingsSearchHost().apply { recorder = { route, scope, title, searchable, row -> drawn += Drawn(route, title, searchable, scope, row) } }
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    BridgeyTheme {
                        CompositionLocalProvider(LocalSettingsSearch provides host, LocalSearchRoute provides routeKey, LocalCardsExpanded provides expanded) { content() }
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
            // The paired Mac's chips on every card, and the paired devices list.
            devices = listOf(SettingsDevice(work.id, work.name, on = BridgeyFeature.entries.associateWith { true })),
            rings = deviceRings(listOf(work, agent), emptyList(), PairingState.Connected("work", "Work MacBook")),
            // A paired Mac's own rows: Macs that can call, and control of this phone.
            dialer = DialerSettingsState(macs = listOf(DialerMac(work.id, work.name, allowed = true))),
            phoneControl = PhoneControlSettingsState(macs = listOf(PhoneControlMac(work.id, work.name, PhoneControlGrantMode.ASK, sharing = true))),
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

    /** Each page: its route key and the rows it draws, every card's More options open. */
    private fun drawAll(expanded: Boolean = true): Map<String, List<Drawn>> {
        val state = fullState()
        val pages = linkedMapOf<String, List<Drawn>>()
        pages[Route.Settings.key] = record(Route.Settings.key) { SettingsScreen(state = state, actions = SettingsActions()) }
        SettingsGroup.entries.forEach { group ->
            val key = settingsRoute(group).key
            pages[key] = record(key, expanded) { SettingsScreen(state = state, actions = SettingsActions(), group = group) }
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

    private fun Drawn.id() = scope to title

    private fun SearchResultEntry.id() = scope to rowTitle

    @Test fun everyRowHasAnEntryAndEveryEntryIsDrawn() {
        val pages = drawAll()
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = fullState().sync, devices = devices)
        val offered = entries.filter { it.rowTitle != null }.groupBy({ it.route.key }, { it.id() })
        val problems = mutableListOf<String>()
        pages.forEach { (key, drawn) ->
            assertTrue("$key drew no rows", drawn.isNotEmpty())
            val allowed = offered[key].orEmpty().toSet()
            drawn.filter { it.searchable && it.route == key }.map { it.id() }.toSet().forEach { id ->
                if (id !in allowed) problems += "$key: row \"${id.second}\"${id.first?.let { " [$it]" } ?: ""} has no search entry"
            }
        }
        entries.filter { it.rowTitle != null }.forEach { entry ->
            val drawn = pages[entry.route.key]?.filter { it.searchable }?.map { it.id() }.orEmpty()
            if (entry.id() !in drawn) problems += "${entry.route.key}: entry ${entry.id} (\"${entry.rowTitle}\") is not drawn"
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
        // Guard against a harness that draws nothing: the pages hold well over a hundred settings rows.
        val total = pages.values.sumOf { drawn -> drawn.count { it.searchable } }
        pages.forEach { (key, drawn) -> println("drift: $key ${drawn.count { it.searchable }} rows") }
        assertTrue("only $total rows drawn", total >= 120)
    }

    /**
     * Every entry lands on a row a person can see: drawn with every card closed, or (an entry that names its card's
     * More options) drawn only once that card's More options open.
     */
    @Test fun everyEntryResolvesToAVisibleOrDisclosedRow() {
        val open = drawAll(expanded = true)
        val closed = drawAll(expanded = false)
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = fullState().sync, devices = devices)
        val problems = mutableListOf<String>()
        var disclosed = 0
        entries.filter { it.rowTitle != null }.forEach { entry ->
            val shown = closed[entry.route.key].orEmpty().filter { it.searchable }.map { it.id() }
            val inMore = open[entry.route.key].orEmpty().filter { it.searchable }.map { it.id() }
            when {
                entry.expand == null && entry.id() !in shown -> problems += "${entry.id} (\"${entry.rowTitle}\") is not on its page with More options closed"
                entry.expand != null && entry.id() in shown -> problems += "${entry.id} names More options of ${entry.expand}, but it is shown without them"
                entry.expand != null && entry.id() !in inMore -> problems += "${entry.id} is not in ${entry.expand}'s More options"
                entry.expand != null -> disclosed++
            }
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
        assertTrue("only $disclosed rows behind More options", disclosed >= 25)
    }

    /** One row per title on a page: rows sharing a title would all highlight, and the scroll would pick either. */
    @Test fun noPageDrawsATitleTwice() {
        val problems = drawAll().flatMap { (key, drawn) ->
            drawn.filter { it.searchable && it.route == key }.distinctBy { it.row }.groupingBy { it.scope to it.title }.eachCount()
                .filter { it.value > 1 }.keys.map { (_, title) -> "$key draws \"$title\" more than once" }
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }

    /**
     * With every feature off most option rows are hidden. A result for one of them must name the switch that shows
     * it (the page highlights that instead), and that switch must be on the page in that state; otherwise the jump
     * would land on nothing.
     */
    @Test fun hiddenRowsNameTheSwitchThatShowsThem() {
        val off = sampleSettingsState(now).copy(
            globalFeatures = BridgeyFeature.entries.associateWith { false },
            autoClipboardEnabled = false,
            developerMenu = true,
            connect = ConnectSettingsState(on = false),
        )
        val pages = linkedMapOf<String, List<Pair<String?, String>>>()
        SettingsGroup.entries.forEach { group ->
            val key = settingsRoute(group).key
            pages[key] = record(key, expanded = true) { SettingsScreen(state = off, actions = SettingsActions(), group = group) }
                .filter { it.searchable && it.route == key }.map { it.id() }
        }
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = SyncUiState(), devices = emptyList())
        val problems = mutableListOf<String>()
        var hidden = 0
        entries.filter { it.rowTitle != null && it.route.key in pages }.forEach { entry ->
            val drawn = pages.getValue(entry.route.key)
            if (entry.id() in drawn) return@forEach
            hidden++
            val fallback = entry.fallbackTitle
            when {
                fallback == null -> problems += "${entry.route.key}: ${entry.id} (\"${entry.rowTitle}\") is hidden with its feature off and names no revealedBy switch"
                (entry.fallbackScope to fallback) !in drawn -> problems += "${entry.route.key}: ${entry.id} falls back to \"$fallback\" in ${entry.fallbackScope}, which is not on the page either"
            }
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
        // The off state really hides the option rows (Files, Calls, Text messages...).
        assertTrue("only $hidden rows hidden", hidden >= 30)
    }

    @Test fun statusLinesAreNotOffered() {
        val clipboard = drawAll().getValue(settingsRoute(SettingsSection.CLIPBOARD).key)
        assertEquals(settingsRoute(SettingsGroup.SHARING).key, settingsRoute(SettingsSection.CLIPBOARD).key)
        val waiting = context.getString(R.string.settings_sync_waiting_here)
        assertTrue(clipboard.any { it.title == waiting && !it.searchable })
    }

    @Test fun developerRowsOnlyWithTheMenu() {
        val off = SettingsSearchRegistry.resolve(context, developerMenu = false, sync = SyncUiState(), devices = emptyList())
        assertTrue(off.none { it.id.startsWith("developer.") })
        val on = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = SyncUiState(), devices = emptyList())
        assertTrue(on.filter { it.id.startsWith("developer.") }.all { it.route == settingsRoute(SettingsGroup.APP) })
        assertTrue(on.any { it.id.startsWith("developer.") })
    }

    /** Results for rows inside More options name their card, so the card opens them; others name none. */
    @Test fun moreOptionsRowsOpenTheirCard() {
        val entries = SettingsSearchRegistry.resolve(context, developerMenu = true, sync = SyncUiState(), devices = devices).associateBy { it.id }
        assertEquals("clipboard", entries.getValue("clipboard.eager").expand)
        assertEquals("logging", entries.getValue("privacy.logCalls").expand)
        assertEquals("clipboard", entries.getValue("device.work.1").expand)
        assertNull(entries.getValue("clipboard.auto").expand)
        assertNull(entries.getValue("device.work.0").expand)
        assertEquals("work", entries.getValue("device.work.0").scope)
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
        // A Mac's name leads to its page, then to its chips and its row on Let Macs control this phone.
        val mac = topIds("work macbook", entries)
        assertEquals("device.work", mac.first())
        assertTrue("remote.mac.work" in mac && "device.work.12" in mac)
        // "May it start calls" was a row on Calls and a switch on its page: now one chip, one result.
        assertFalse(entries.any { it.id == "calls.mac.work" })
        val work = SettingsSearch.search("work clipboard", entries.map { it.doc }).map { entries[it.index] }
        assertEquals(Route.SettingsGroupPage(SettingsGroup.SHARING), work.first().route)
        assertEquals(context.getString(R.string.feature_clipboard), work.first().rowTitle)
        assertEquals("work", work.first().scope)
        assertTrue(work.first().breadcrumb, work.first().breadcrumb.endsWith(" › Work MacBook"))
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
