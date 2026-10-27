package dev.bridgey.android.ui.attach

import dev.bridgey.android.browse.DocumentItem
import dev.bridgey.android.browse.MediaItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AttachModelTest {
    private fun media(id: Long, size: Long = 1_000) = MediaItem(id, "IMG_$id.jpg", size, id, id, "image/jpeg", 100, 100, null, "Camera", "content://media/external/images/media/$id")
    private fun document(name: String, size: Long) = DocumentItem("p", "", name, size, 1, "application/pdf", "content://docs/$name", "Documents")

    @Test
    fun picksKeepTheirOrderAndCountersMoveUp() {
        var selection = emptyList<String>()
        listOf("m:1", "d:x", "m:2", "f:default").forEach { selection = AttachSelection.toggle(selection, it) }
        assertEquals(mapOf("m:1" to 1, "d:x" to 2, "m:2" to 3, "f:default" to 4), AttachSelection.order(selection))
        selection = AttachSelection.toggle(selection, "d:x")
        assertEquals(mapOf("m:1" to 1, "m:2" to 2, "f:default" to 3), AttachSelection.order(selection))
    }

    @Test
    fun aFullSelectionIgnoresNewPicks() {
        val full = (1..AttachSelection.MAX).map { "m:$it" }
        assertEquals(full, AttachSelection.toggle(full, "m:999"))
        assertEquals(AttachSelection.MAX - 1, AttachSelection.toggle(full, "m:1").size)
    }

    @Test
    fun selectedBytesAndPrune() {
        val items = listOf(media(1, 2_000), media(2, 3_000))
        val docs = listOf(document("a.pdf", 500))
        val selection = listOf("m:2", "d:content://docs/a.pdf", "f:default", "m:9")
        assertEquals(3_500, AttachSelection.bytes(selection, items, docs))
        val pruned = AttachSelection.prune(selection, items, docs, listOf(AttachFolder("default", "Download/Bridgey", null, true, isDefault = true)))
        assertEquals(listOf("m:2", "d:content://docs/a.pdf", "f:default"), pruned)
        val state = AttachState(media = items, documents = docs, selection = pruned)
        assertEquals(3_500, state.selectedBytes)
        assertEquals(1, state.selectedFolders)
    }

    @Test
    fun durations() {
        assertEquals("0:42", AttachSelection.duration(42_000))
        assertEquals("12:05", AttachSelection.duration(725_000))
        assertEquals("1:02:09", AttachSelection.duration(3_729_000))
    }

    @Test
    fun targetFallsBackToTheFirstDevice() {
        val targets = listOf(AttachTarget("a", "MacBook Pro"), AttachTarget("b", "Personal Mac"))
        assertEquals("b", AttachState(targets = targets, targetId = "b").target?.deviceId)
        assertEquals("a", AttachState(targets = targets, targetId = "gone").target?.deviceId)
        assertTrue(AttachState().target == null)
    }
}
