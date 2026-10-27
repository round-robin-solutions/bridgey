package dev.bridgey.android

import dev.bridgey.android.actions.MacActionCatalog
import dev.bridgey.android.actions.MacActionEntry
import dev.bridgey.android.controls.ControlCommand
import dev.bridgey.android.controls.ControlMac
import dev.bridgey.android.widget.widgetModel
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class OpenOnMacTest {
    @Test fun findsTheFirstSafeLinkInSharedText() {
        assertEquals("https://github.com/singeol/bridgey", firstWebLink("Bridgey https://github.com/singeol/bridgey"))
        assertEquals("https://example.com/a?b=1", firstWebLink("Look: https://example.com/a?b=1."))
        assertEquals("https://example.com/x", firstWebLink("(https://example.com/x)"))
        assertEquals("http://localhost:8080/", firstWebLink("http://localhost:8080/"))
        assertEquals("Skips an unsafe one", "https://ok.example/", firstWebLink("https://user:pw@evil.example/ then https://ok.example/"))
        listOf(null, "", "no link here", "javascript:alert(1)", "file:///etc/passwd", "ftp://example.com").forEach { assertNull(it, firstWebLink(it)) }
        assertEquals("github.com", linkHost("https://www.github.com/x"))
    }

    @Test fun shareTargetIsSeparateFromTheMainShareAndOnlyTakesText() {
        val ns = "http://schemas.android.com/apk/res/android"
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val activities = doc.getElementsByTagName("activity")
        val open = (0 until activities.length).map { activities.item(it) as Element }.first { it.getAttributeNS(ns, "name") == ".OpenOnMacActivity" }
        assertEquals("@string/open_on_mac_label", open.getAttributeNS(ns, "label"))
        val types = open.getElementsByTagName("data").let { list -> (0 until list.length).map { (list.item(it) as Element).getAttributeNS(ns, "mimeType") } }
        assertEquals(listOf("text/plain"), types)
        val services = doc.getElementsByTagName("service").let { list -> (0 until list.length).map { list.item(it) as Element } }
        assertEquals("android.permission.BIND_CONTROLS", services.first { it.getAttributeNS(ns, "name") == ".controls.MacControlsService" }.getAttributeNS(ns, "permission"))
        assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", services.first { it.getAttributeNS(ns, "name") == ".LockMacTileService" }.getAttributeNS(ns, "permission"))
    }

    @Test fun widgetButtonsFollowTheMacsList() {
        assertTrue(widgetModel(null).buttons.isEmpty())
        val catalog = MacActionCatalog(listOf(MacActionEntry("lock", blocked = "permission_required"), MacActionEntry("volume_up")))
        val mac = ControlMac("work", "Work MacBook", true, BridgeyFeature.entries.toSet(), catalog, true, false)
        val model = widgetModel(mac)
        assertEquals(listOf(false, false, false, true, true, true), model.buttons.map { it.enabled })
        assertEquals(ControlCommand.Run("work", "volume_up"), model.buttons[3].command)
        val offline = widgetModel(mac.copy(connected = false, available = emptySet(), catalogLive = false))
        assertFalse(offline.connected)
        assertTrue(offline.buttons.none { it.enabled })
    }
}
