package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Test

/** "Type what you want": the sentences the Mac tests too (SetupFlowTests.swift). */
class SetupTypedTest {
    private fun match(text: String) = SetupTyped.match(text).toList()

    @Test
    fun sharedSentences() {
        assertEquals(
            listOf("notifications" to Answers.PICK, "files" to Answers.PICK),
            match("I mainly want my WhatsApp notifications and to send photos to my Mac"),
        )
        assertEquals(
            listOf("clipboard" to Answers.PICK, "calls" to Answers.PICK, "media" to Answers.NO),
            match("copy paste and calls but no music"),
        )
        assertEquals(
            listOf("notifications" to Answers.PICK, "calls" to Answers.NO, "files" to Answers.PICK),
            match("Хочу уведомления и фото на Mac, без звонков"),
        )
        assertEquals(listOf("focus" to Answers.BOTH, "updates" to Answers.EARLY), match("Do not disturb in sync, and beta updates"))
        assertEquals(listOf("remote" to Answers.PICK), match("control my mac with a touchpad for slides"))
        assertEquals(emptyList<Pair<String, String>>(), match(""))
    }

    @Test
    fun androidSentences() {
        assertEquals(listOf("codes" to Answers.YES), match("codes from messages"))
        assertEquals(listOf("camera" to Answers.NO), match("no camera"))
        assertEquals(emptyList<Pair<String, String>>(), SetupTyped.match("notifications", listOf("calls")).toList())
    }
}
