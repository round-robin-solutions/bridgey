package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Test

/** "Type what you want": the sentences the Mac tests too (SetupFlowTests.swift). */
class SetupTypedTest {
    private val ids = SetupQuestions.all.map { it.id }

    private fun match(text: String) = SetupTyped.match(text, ids).toList()

    @Test
    fun sharedSentences() {
        assertEquals(
            listOf("notifications" to Answers.YES, "files" to Answers.YES),
            match("I mainly want my WhatsApp notifications and to send photos to my Mac"),
        )
        assertEquals(
            listOf("clipboard" to Answers.AUTO, "calls" to Answers.YES, "media" to Answers.NO),
            match("copy paste and calls but no music"),
        )
        assertEquals(
            listOf("notifications" to Answers.YES, "calls" to Answers.NO, "files" to Answers.YES),
            match("Хочу уведомления и фото на Mac, без звонков"),
        )
        assertEquals(listOf("focus" to Answers.BOTH, "updates" to Answers.EARLY), match("Do not disturb in sync, and beta updates"))
        assertEquals(listOf("remote" to Answers.YES), match("control my mac with a touchpad for slides"))
        assertEquals(emptyList<Pair<String, String>>(), match(""))
    }

    @Test
    fun androidSentences() {
        assertEquals(listOf("codes" to Answers.YES), match("codes from messages"))
        assertEquals(listOf("camera" to Answers.NO), match("no camera"))
        // Only questions this device has.
        assertEquals(emptyList<Pair<String, String>>(), SetupTyped.match("notifications", listOf("calls")).toList())
    }
}
