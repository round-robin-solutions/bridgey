package dev.bridgey.android.folders

import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderManifestTest {
    private val id = UUID.randomUUID().toString()
    private fun hash(text: String) = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(text.toByteArray()))
    private fun dir(path: String) = ManifestEntry(ManifestEntry.Type.DIR, path)
    private fun file(path: String, size: Long = 3) = ManifestEntry(ManifestEntry.Type.FILE, path, size, hash(path))

    private val tree = listOf(dir("2019"), dir("2019/Empty"), file("2019/a.jpg"), file("2019/b.jpg"), dir("Beach"), file("notes.txt"))

    private fun offer(entries: List<ManifestEntry>, pages: Int, root: String = "Photos", digest: String = ManifestDigest.compute(root, entries)) =
        FolderOfferPayload(id, root, entries.count { !it.isDirectory }, entries.count { it.isDirectory }, entries.sumOf { it.size },
            pages, digest, null, false, SkippedCounts())

    private fun assemble(offer: FolderOfferPayload, pages: List<ManifestPagePayload>): ManifestAssembler.Result {
        val assembler = ManifestAssembler(offer)
        var result: ManifestAssembler.Result = ManifestAssembler.Result.NeedMore
        pages.forEach { result = assembler.add(it, it.toJson().toString().length) }
        return result
    }

    @Test fun aValidManifestAssemblesAcrossPages() {
        val pages = listOf(ManifestPagePayload(id, 0, tree.take(3)), ManifestPagePayload(id, 1, tree.drop(3)))
        val result = assemble(offer(tree, 2), pages)
        assertEquals(ManifestAssembler.Result.Complete(tree), result)
    }

    @Test fun pagesOutOfOrderMissingOrRepeatedAreRejected() {
        val pages = listOf(ManifestPagePayload(id, 0, tree.take(3)), ManifestPagePayload(id, 1, tree.drop(3)))
        assertTrue(assemble(offer(tree, 2), pages.reversed()) is ManifestAssembler.Result.Rejected)
        assertTrue(assemble(offer(tree, 2), listOf(pages[0], pages[0])) is ManifestAssembler.Result.Rejected)
        assertEquals(ManifestAssembler.Result.NeedMore, assemble(offer(tree, 2), listOf(pages[0])))
    }

    @Test fun aChildBeforeItsFolderOrOutOfOrderIsRejectedWithItsIndex() {
        val noParent = listOf(file("2019/a.jpg"))
        assertEquals(ManifestAssembler.Result.Rejected(FolderCodes.INVALID_MANIFEST, 0),
            assemble(offer(noParent, 1), listOf(ManifestPagePayload(id, 0, noParent))))
        val unsorted = listOf(file("b.txt"), file("a.txt"))
        assertEquals(ManifestAssembler.Result.Rejected(FolderCodes.INVALID_MANIFEST, 1),
            assemble(offer(unsorted, 1), listOf(ManifestPagePayload(id, 0, unsorted))))
    }

    @Test fun traversalAndCaseClashesAreRejected() {
        listOf("../evil", "a/../../evil", "/etc/passwd", "C:\\x", "a\\b", "a/./b", "con").forEach { path ->
            val entries = listOf(file(path))
            assertTrue(path, assemble(offer(entries, 1), listOf(ManifestPagePayload(id, 0, entries))) is ManifestAssembler.Result.Rejected)
        }
        val clash = listOf(file("A.txt"), file("a.txt"))
        assertEquals(ManifestAssembler.Result.Rejected(FolderCodes.INVALID_MANIFEST, 1),
            assemble(offer(clash, 1), listOf(ManifestPagePayload(id, 0, clash))))
    }

    @Test fun countsSizesAndDigestMustMatchTheOffer() {
        val page = listOf(ManifestPagePayload(id, 0, tree))
        assertTrue(assemble(offer(tree, 1, digest = hash("other")), page) is ManifestAssembler.Result.Rejected)
        assertTrue(assemble(offer(tree, 1).copy(totalSize = 1), page) is ManifestAssembler.Result.Rejected)
        assertTrue(assemble(offer(tree, 1).copy(fileCount = 2), page) is ManifestAssembler.Result.Rejected)
        assertTrue(assemble(offer(tree, 1).copy(folderCount = 4), page) is ManifestAssembler.Result.Rejected)
    }

    @Test fun aFileWithoutAValidHashIsRejected() {
        val entries = listOf(ManifestEntry(ManifestEntry.Type.FILE, "a.txt", 1, "short"))
        assertTrue(assemble(offer(entries, 1), listOf(ManifestPagePayload(id, 0, entries))) is ManifestAssembler.Result.Rejected)
    }

    @Test fun anEmptyFolderNeedsNoPages() {
        val assembler = ManifestAssembler(offer(emptyList(), 0))
        assertEquals(ManifestAssembler.Result.Complete(emptyList()), assembler.completeWithoutPages())
        assertNull(ManifestAssembler(offer(tree, 1)).completeWithoutPages())
    }

    @Test fun offerLimitsAreCheckedBeforeAnythingIsAllocated() {
        fun parse(change: JSONObject.() -> Unit) = FolderOfferPayload.parse(offer(tree, 1).toJson().apply(change))
        assertTrue(parse {} is FolderOfferPayload.Companion.Result.Valid)
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.LIMIT_EXCEEDED), parse { put("fileCount", 10_001) })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.LIMIT_EXCEEDED), parse { put("folderCount", 2_001) })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.LIMIT_EXCEEDED), parse { put("totalSize", (1L shl 40) + 1) })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.LIMIT_EXCEEDED), parse { put("pageCount", 129) })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.INVALID_MANIFEST), parse { put("rootName", "../x") })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.INVALID_MANIFEST), parse { put("pageCount", 0) })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.UNSUPPORTED), parse { put("version", 2) })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.INVALID_MESSAGE), parse { put("folderTransferId", "not-a-uuid") })
        assertEquals(FolderOfferPayload.Companion.Result.Invalid(FolderCodes.INVALID_MESSAGE),
            parse { put("destination", JSONObject().put("placeId", "default").put("path", "../up")) })
    }

    @Test fun deepTreesBeyondTheDepthLimitAreRejected() {
        val deep = (1..33).map { depth -> dir((1..depth).joinToString("/") { "d" }) }
        val result = assemble(offer(deep, 1), listOf(ManifestPagePayload(id, 0, deep)))
        assertEquals(ManifestAssembler.Result.Rejected(FolderCodes.INVALID_MANIFEST, 32), result)
    }

    @Test fun thePagerKeepsPagesWithinEntryAndByteLimitsAndRoundTrips() {
        val many = (0 until 1_000).map { file("f%04d-%s.bin".format(it, "x".repeat(150))) }
        val pages = ManifestPager.pages(id, many)!!
        assertTrue(pages.all { it.entries.size <= 256 && it.toJson().toString().toByteArray().size <= 32 * 1024 })
        val parsed = pages.map { ManifestPagePayload.parse(JSONObject(it.toJson().toString()))!! }
        assertEquals(many, parsed.flatMap { it.entries })
        assertEquals(ManifestAssembler.Result.Complete(many), assemble(offer(many, pages.size), parsed))
    }

    @Test fun thePagerRefusesManifestsOverTheCap() {
        val tooMany = (0 until 128 * 256 + 1).map { file("f$it") }
        assertNull(ManifestPager.pages(id, tooMany))
    }

    @Test fun messagesRoundTripAndRejectBadFields() {
        val listed = PlacesListedPayload(id, DestinationMode.SENDER_PICKS,
            listOf(PlaceInfo(DEFAULT_PLACE_ID, "Download/Bridgey", true, 100), PlaceInfo("q3Jx0bVv1eG7tq8Wm2l5wA", "Pictures", false, null)), null)
        assertEquals(listed, PlacesListedPayload.parse(JSONObject(listed.toJson().toString())))
        assertNull(PlaceInfo.parse(JSONObject().put("placeId", "content://x").put("label", "x").put("available", true)))
        assertNull(PlacesBrowsePayload.parse(PlacesBrowsePayload(id, DEFAULT_PLACE_ID, "a/../b", null).toJson()))
        assertEquals(FolderResolvePayload(id, ConflictChoice.MERGE), FolderResolvePayload.parse(FolderResolvePayload(id, ConflictChoice.MERGE).toJson()))
        assertNull(FolderResolvePayload.parse(JSONObject().put("version", 1).put("folderTransferId", id).put("choice", "none")))
        val complete = FolderCompletePayload(id, 3, 1, listOf(FailedEntry(4, FolderCodes.SOURCE_CHANGED)))
        assertEquals(complete, FolderCompletePayload.parse(JSONObject(complete.toJson().toString())))
    }
}
