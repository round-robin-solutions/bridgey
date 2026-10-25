package dev.bridgey.android.activity

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ActivityLogTest {
    @get:Rule
    val folder = TemporaryFolder()

    private var now = 1_800_000_000_000L
    private val direct = java.util.concurrent.Executor { it.run() }

    private fun log(file: File? = null) = ActivityLog(file, direct) { now }

    @Test
    fun newestFirstAndCappedAtTwoHundred() {
        val log = log()
        repeat(250) { index ->
            now += 1_000
            log.record(ActivityKind.PING_SENT, "mac", "Mac $index")
        }
        val items = log.items.value
        assertEquals(ActivityHistory.MAX_ITEMS, items.size)
        assertEquals("Mac 249", items.first().deviceName)
        assertEquals("Mac 50", items.last().deviceName)
        assertTrue(items.zipWithNext().all { (a, b) -> a.atMillis >= b.atMillis })
    }

    @Test
    fun itemsOlderThanSevenDaysExpire() {
        val log = log()
        log.record(ActivityKind.CLIPBOARD_SENT, "mac", "Mac")
        now += ActivityHistory.MAX_AGE_MILLIS - 1
        log.prune()
        assertEquals(1, log.items.value.size)
        now += 2
        log.prune()
        assertTrue(log.items.value.isEmpty())
    }

    @Test
    fun expiredItemsAreDroppedOnLoad() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        log(file).record(ActivityKind.FILE_SENT, "mac", "Mac", "old.pdf")
        now += ActivityHistory.MAX_AGE_MILLIS + 1
        assertTrue(log(file).items.value.isEmpty())
    }

    @Test
    fun alertsOnTheSameDeviceMergeIntoOneItemWithACount() {
        val log = log()
        log.record(ActivityKind.NOTIFICATIONS_SHOWN, "mac", "Mac")
        val id = log.items.value.single().id
        now += 60_000
        log.record(ActivityKind.NOTIFICATIONS_SHOWN, "mac", "Mac")
        now += 60_000
        log.record(ActivityKind.NOTIFICATIONS_SHOWN, "mac", "Mac")
        val merged = log.items.value.single()
        assertEquals(id, merged.id)
        assertEquals(3, merged.count)
        assertEquals(now, merged.atMillis)

        now += ActivityKind.NOTIFICATIONS_SHOWN.mergeWindowMillis + 1
        log.record(ActivityKind.NOTIFICATIONS_SHOWN, "mac", "Mac")
        assertEquals(2, log.items.value.size)
        log.record(ActivityKind.NOTIFICATIONS_SHOWN, "other", "Other")
        assertEquals(3, log.items.value.size)
    }

    @Test
    fun onlyFileEventsKeepAName() {
        val log = log()
        log.record(ActivityKind.CLIPBOARD_SENT, "mac", "Mac", fileName = "secret clipboard text")
        log.record(ActivityKind.LINK_RECEIVED, "mac", "Mac", fileName = "https://example.com/private")
        log.record(ActivityKind.FILE_RECEIVED, "mac", "Mac", fileName = "invoice.pdf")
        val items = log.items.value
        assertNull(items.first { it.kind == ActivityKind.CLIPBOARD_SENT }.fileName)
        assertNull(items.first { it.kind == ActivityKind.LINK_RECEIVED }.fileName)
        assertEquals("invoice.pdf", items.first { it.kind == ActivityKind.FILE_RECEIVED }.fileName)
    }

    @Test
    fun theRecordHasNoContentFields() {
        val fields = ActivityItem::class.java.declaredFields
            .filterNot { java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .map { it.name }
            .toSet()
        assertEquals(
            setOf("id", "kind", "deviceId", "deviceName", "fileName", "preview", "appName", "sensitive", "automatic", "count", "atMillis"),
            fields,
        )
    }

    @Test
    fun persistedJsonHoldsOnlyTheAllowedKeys() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        val log = log(file)
        ActivityKind.entries.forEach { log.record(it, "mac", "Mac", fileName = "a.txt") }
        val array = JSONArray(file.readText())
        val keys = (0 until array.length()).flatMap { array.getJSONObject(it).keys().asSequence().toList() }.toSet()
        assertEquals(setOf("id", "kind", "deviceId", "deviceName", "fileName", "preview", "appName", "sensitive", "automatic", "count", "at"), keys)
        // File names only on file events.
        (0 until array.length()).map { array.getJSONObject(it) }.forEach { item ->
            val kind = ActivityKind.fromKey(item.getString("kind"))!!
            assertEquals(kind.carriesFileName, !item.isNull("fileName"))
        }
    }

    @Test
    fun decodingIgnoresUnknownKindsAndExtraFields() {
        val json = """[
            {"id":1,"kind":"clipboard_sent","deviceId":"mac","deviceName":"Mac","fileName":"leak","count":1,"at":$now,"text":"secret"},
            {"id":2,"kind":"something_new","deviceId":"mac","deviceName":"Mac","count":1,"at":$now}
        ]"""
        val items = ActivityHistory.decode(json, now)
        assertEquals(1, items.size)
        assertNull(items.single().fileName)
        assertEquals(ActivityKind.CLIPBOARD_SENT, items.single().kind)
    }

    @Test
    fun persistsAcrossRestartsOwnerOnly() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        log(file).apply {
            record(ActivityKind.FILE_SENT, "mac", "Mac", "deck.key")
            now += 1_000
            record(ActivityKind.PING_RECEIVED, "mac", "Mac")
        }
        val reloaded = log(file).items.value
        assertEquals(listOf(ActivityKind.PING_RECEIVED, ActivityKind.FILE_SENT), reloaded.map { it.kind })
        assertEquals("deck.key", reloaded.last().fileName)
        val permissions = Files.getPosixFilePermissions(file.toPath())
        assertEquals(setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE), permissions)
    }

    @Test
    fun newIdsKeepGrowingAfterARestart() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        log(file).record(ActivityKind.PING_SENT, "mac", "Mac")
        val first = log(file).items.value.single().id
        val second = log(file).apply { record(ActivityKind.PING_SENT, "mac", "Mac") }.items.value.first().id
        assertTrue(second > first)
    }

    @Test
    fun clearEmptiesMemoryAndDisk() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        val log = log(file)
        log.record(ActivityKind.CLIPBOARD_RECEIVED, "mac", "Mac")
        log.clear()
        assertTrue(log.items.value.isEmpty())
        assertFalse(file.exists())
        assertTrue(log(file).items.value.isEmpty())
    }

    @Test
    fun aClockSetBackDoesNotPinFutureItems() {
        val items = listOf(ActivityItem(1, ActivityKind.PING_SENT, "mac", "Mac", null, null, null, false, false, 1, now + 24 * 60 * 60 * 1000L))
        assertTrue(ActivityHistory.prune(items, now).isEmpty())
    }

    @Test
    fun clipboardPreviewIsOneLineOfAtMostEightyCharacters() {
        assertEquals("Room 2 at 4, bring the deck", clipboardPreview("  Room 2 at 4,\n\n bring\tthe deck  "))
        assertNull(clipboardPreview(" \n\t "))
        val long = clipboardPreview("word ".repeat(40))!!
        assertTrue(long.length <= ActivityHistory.MAX_PREVIEW_LENGTH)
        assertTrue(long.endsWith("\u2026"))
        assertFalse(long.contains("\n"))
        val emoji = clipboardPreview("a".repeat(78) + "\uD83D\uDE00\uD83D\uDE00")!!
        assertFalse(Character.isHighSurrogate(emoji[emoji.length - 2]))
    }

    @Test
    fun clipboardEventsKeepAPreviewThatIsCapped() {
        val log = log()
        log.record(ActivityKind.CLIPBOARD_SENT, "mac", "Mac", preview = "x".repeat(5_000))
        val item = log.items.value.single()
        assertEquals(ActivityHistory.MAX_PREVIEW_LENGTH, item.preview!!.length)
        assertFalse(item.sensitive)
    }

    @Test
    fun sensitiveClipsStoreNoText() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        val log = log(file)
        log.record(ActivityKind.CLIPBOARD_SENT, "mac", "Mac", preview = "hunter2-password", sensitive = true)
        val item = log.items.value.single()
        assertTrue(item.sensitive)
        assertNull(item.preview)
        assertFalse(file.readText().contains("hunter2"))
    }

    @Test
    fun onlyClipboardAndCallsKeepPreviewsAndOnlyAlertsKeepAppNames() {
        val log = log()
        ActivityKind.entries.forEach { log.record(it, "mac", "Mac", preview = "text", appName = "WhatsApp") }
        log.items.value.forEach { item ->
            assertEquals(item.kind.carriesPreview, item.preview != null)
            assertEquals(item.kind.carriesAppName, item.appName != null)
        }
    }

    @Test
    fun alertsGroupPerDeviceAndPerApp() {
        val log = log()
        listOf("WhatsApp", "Gmail", "WhatsApp", "WhatsApp", "Gmail").forEach {
            now += 10_000
            log.record(ActivityKind.NOTIFICATIONS_SHOWN, "mac", "Mac", appName = it)
        }
        val items = log.items.value
        assertEquals(listOf("Gmail" to 2, "WhatsApp" to 3), items.map { it.appName to it.count })
    }

    @Test
    fun previewsOffStoresNoTextOrAppNames() {
        val file = File(folder.root, ActivityLog.FILE_NAME)
        val log = log(file)
        recordPeerEvent(log, dev.bridgey.android.PeerEvent(dev.bridgey.android.PeerActivity.CLIPBOARD_RECEIVED, "mac", "Mac", "secret note"), previews = false)
        recordNotification(log, "mac", "Mac", isCall = false, appName = "WhatsApp", caller = null, previews = false)
        recordNotification(log, "mac", "Mac", isCall = true, appName = "Phone", caller = "Mum", previews = false)
        assertTrue(log.items.value.all { it.preview == null && it.appName == null })
        val text = file.readText()
        listOf("secret", "WhatsApp", "Mum", "Phone").forEach { assertFalse(text.contains(it)) }

        recordPeerEvent(log, dev.bridgey.android.PeerEvent(dev.bridgey.android.PeerActivity.CLIPBOARD_SENT, "mac", "Mac", "visible note"), previews = true)
        assertEquals("visible note", log.items.value.first().preview)
    }

    @Test
    fun diagnosticsNeverIncludePreviews() {
        // The activity stream is separate from diagnostics: the report is built from BridgeyDiagnostics only.
        val root = File(System.getProperty("bridgey.repoRoot"), "android/app/src/main/java/dev/bridgey/android")
        val diagnostics = File(root, "BridgeyDiagnostics.kt").readText()
        listOf("ActivityLog", "ActivityItem", "preview", "appName").forEach { assertFalse(diagnostics.contains(it)) }
        val coordinator = File(root, "PairingCoordinator.kt").readText()
        val report = coordinator.substringAfter("fun diagnosticsReport()").substringBefore("\n    }\n")
        listOf("activity", "clipboardText", "preview").forEach { assertFalse(report.contains(it, ignoreCase = true)) }
    }
}
