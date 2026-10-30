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
        assertEquals(listOf("messages" to Answers.PICK), match("I want to answer SMS from my Mac"))
        assertEquals(listOf("messages" to Answers.PICK), match("Хочу отвечать на СМС с Mac"))
        assertEquals(emptyList<Pair<String, String>>(), match(""))
    }

    /** Update all devices automatically (typed id updates_auto, after the channel so it wins). The Mac tests the same sentences. */
    @Test
    fun automaticUpdatesSentences() {
        assertEquals(listOf("updates_auto" to Answers.YES), match("update all my devices automatically"))
        assertEquals(listOf("updates_auto" to Answers.YES), match("Auto-update everything"))
        assertEquals(listOf("updates" to Answers.EARLY, "updates_auto" to Answers.NO), match("beta, but no automatic updates"))
        assertEquals(listOf("updates_auto" to Answers.NO), match("don't update automatically"))
        assertEquals(listOf("updates" to Answers.NEWEST, "updates_auto" to Answers.YES), match("nightly builds that install automatically"))
        assertEquals(listOf("updates_auto" to Answers.YES), match("Хочу автообновление"))
        assertEquals(listOf("updates_auto" to Answers.NO), match("без автообновлений"))
        assertEquals(listOf("updates" to Answers.STEADY, "updates_auto" to Answers.YES), match("стабильные, обновлять автоматически"))
        // Plain "update" is not enough.
        assertEquals(emptyList<Pair<String, String>>(), match("I want to update my Mac"))
    }

    @Test
    fun androidSentences() {
        assertEquals(listOf("codes" to Answers.YES), match("codes from messages"))
        assertEquals(listOf("camera" to Answers.NO), match("no camera"))
        assertEquals(emptyList<Pair<String, String>>(), SetupTyped.match("notifications", listOf("calls")).toList())
    }
}
