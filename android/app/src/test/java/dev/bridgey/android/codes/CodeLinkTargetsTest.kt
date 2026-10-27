package dev.bridgey.android.codes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CodeLinkTargetsTest {
    private val personal = CodeLinkMac("p", "Personal Mac")
    private val work = CodeLinkMac("w", "Work MacBook")

    @Test
    fun pickedThenSelectedThenFirst() {
        val macs = listOf(personal, work)
        assertEquals(work, CodeLinkTargets.current(macs, picked = "w", selected = "p"))
        assertEquals(personal, CodeLinkTargets.current(macs, picked = null, selected = "p"))
        assertEquals(work, CodeLinkTargets.current(macs, picked = "gone", selected = "w"))
        assertEquals(personal, CodeLinkTargets.current(macs, picked = null, selected = null))
        assertNull(CodeLinkTargets.current(emptyList(), picked = "w", selected = "w"))
    }

    @Test
    fun pickerOnlyForTwoOrMore() {
        assertFalse(CodeLinkTargets.needsPicker(emptyList()))
        assertFalse(CodeLinkTargets.needsPicker(listOf(personal)))
        assertTrue(CodeLinkTargets.needsPicker(listOf(personal, work)))
    }
}
