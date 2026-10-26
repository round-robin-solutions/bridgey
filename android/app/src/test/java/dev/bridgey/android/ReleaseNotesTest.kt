package dev.bridgey.android

import dev.bridgey.android.ReleaseNoteBlock.Bullet
import dev.bridgey.android.ReleaseNoteBlock.Heading
import dev.bridgey.android.ReleaseNoteBlock.Paragraph
import org.junit.Assert.assertEquals
import org.junit.Test

/** The notes parser behind Settings > Updates. The Mac's ReleaseNotesTests pin the same rules. */
class ReleaseNotesTest {
    @Test fun dashLinesBecomeBullets() {
        val notes = "- Faster pairing\n* Calmer reconnects\n• One Keychain question\n+ Fixes\n1. Numbered too"
        assertEquals(
            listOf(Bullet("Faster pairing"), Bullet("Calmer reconnects"), Bullet("One Keychain question"), Bullet("Fixes"), Bullet("Numbered too")),
            ReleaseNotes.blocks(notes),
        )
    }

    @Test fun headingsParagraphsAndRulesAreKept() {
        assertEquals(
            listOf(Heading("Changes"), Paragraph("Shorter Settings."), Bullet("Item")),
            ReleaseNotes.blocks("## Changes\nShorter Settings.\n\n---\n- Item"),
        )
    }

    @Test fun wrappedLinesJoinTheirItem() {
        val notes = "- Constrain the macOS menu-bar panel to its content's ideal height when the\n  connection state changes.\n- Next item"
        assertEquals(
            listOf(Bullet("Constrain the macOS menu-bar panel to its content's ideal height when the connection state changes."), Bullet("Next item")),
            ReleaseNotes.blocks(notes),
        )
    }

    @Test fun aFinishedSentenceStartsANewParagraph() {
        assertEquals(listOf(Bullet("Done."), Paragraph("Thanks for testing")), ReleaseNotes.blocks("- Done.\nThanks for testing"))
        assertEquals(listOf(Bullet("Done. lowercase goes on")), ReleaseNotes.blocks("- Done.\nlowercase goes on"))
    }

    @Test fun theVersionIsNotRepeated() {
        val version = "0.6.0-rr.1-beta.10"
        assertEquals(listOf(Bullet("a")), ReleaseNotes.blocks("# v$version\n$version\n- a", version))
    }

    @Test fun inlineMarkdownBecomesPlainWords() {
        assertEquals(
            listOf(Bullet("Bold and code and the checklist")),
            ReleaseNotes.blocks("- **Bold** and `code` and the [checklist](https://example.com/x)"),
        )
    }

    @Test fun emptyNotesHaveNoBlocks() {
        assertEquals(emptyList<ReleaseNoteBlock>(), ReleaseNotes.blocks(""))
        assertEquals(emptyList<ReleaseNoteBlock>(), ReleaseNotes.blocks("\n- \n\n"))
    }

    @Test fun previewFitsAboutFourLines() {
        val short = (1..9).map { Bullet("Item $it") }
        assertEquals(short.take(4), ReleaseNotes.preview(short))
        val long = "x".repeat(60) // two lines each at 44 characters
        val blocks = listOf(Bullet(long), Bullet(long), Bullet("short"))
        assertEquals(blocks.take(2), ReleaseNotes.preview(blocks))
        val huge = listOf(Paragraph("y".repeat(500)), Bullet("b"))
        assertEquals("always shows at least one block", huge.take(1), ReleaseNotes.preview(huge))
    }

    @Test fun previewNeverEndsOnAHeading() {
        val blocks = listOf(Bullet("a"), Bullet("b"), Bullet("c"), Heading("Fixes"), Bullet("d"))
        assertEquals(blocks.take(3), ReleaseNotes.preview(blocks))
    }
}
