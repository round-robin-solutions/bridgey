package dev.bridgey.android.folders

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Runs protocol/test-vectors/folders-v1.json, the vectors macOS runs too. */
class FolderVectorsTest {
    private val vectors = JSONObject(File(System.getProperty("bridgey.repoRoot"), "protocol/test-vectors/folders-v1.json").readText())

    private fun string(value: Any): String = when (value) {
        is String -> value
        is JSONObject -> List(value.getInt("times")) { value.getString("part") }.joinToString(value.optString("join", "")) + value.optString("suffix", "")
        else -> error("unexpected $value")
    }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { string(get(it)) }

    @Test fun portableNames() {
        val cases = vectors.getJSONArray("portableNames")
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val input = string(case.get("input"))
            val expected = string(case.get("portable"))
            val converted = PortableName.convert(input)
            assertEquals("convert(${case.get("input")})", expected, converted)
            assertTrue("portable result $expected", PortableName.isPortable(converted!!))
            assertEquals("idempotent $expected", converted, PortableName.convert(converted))
        }
    }

    @Test fun namesThatAreNotPortable() {
        vectors.getJSONArray("notPortable").strings().forEach { assertFalse("isPortable($it)", PortableName.isPortable(it)) }
    }

    @Test fun unpairedSurrogatesAreRejected() {
        assertNull(PortableName.convert("bad\uD800name"))
        assertNull(PortableName.convert("bad\uDC00"))
        assertFalse(PortableName.isPortable("x\uD800"))
    }

    @Test fun manifestPaths() {
        val paths = vectors.getJSONObject("manifestPaths")
        paths.getJSONArray("valid").strings().forEach { assertTrue("valid $it", FolderPaths.isValidManifestPath(it)) }
        paths.getJSONArray("invalid").strings().forEach { assertFalse("invalid ${it.take(40)}", FolderPaths.isValidManifestPath(it)) }
    }

    @Test fun existingPaths() {
        val paths = vectors.getJSONObject("existingPaths")
        paths.getJSONArray("valid").strings().forEach { assertTrue("valid ${it.take(40)}", FolderPaths.isValidExistingPath(it)) }
        paths.getJSONArray("invalid").strings().forEach { assertFalse("invalid ${it.take(40)}", FolderPaths.isValidExistingPath(it)) }
    }

    @Test fun caseClashesAreRenamedInByteOrder() {
        val cases = vectors.getJSONArray("caseClashes")
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val siblings = case.getJSONArray("siblings").let { array ->
                (0 until array.length()).map { array.getJSONObject(it).let { item -> item.getString("name") to item.getBoolean("dir") } }
            }
            assertEquals(case.getJSONArray("resolved").strings(), ConflictNames.resolveSiblings(siblings).map { it.second })
        }
    }

    @Test fun conflictNames() {
        val cases = vectors.getJSONArray("conflictNames")
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val taken = case.getJSONArray("taken").strings().map(::caseKey).toSet()
            assertEquals(case.getString("result"), ConflictNames.firstFree(case.getString("name"), case.getBoolean("dir")) { it in taken })
        }
    }

    @Test fun systemFileListMatchesTheSharedConstant() {
        val system = vectors.getJSONObject("systemFiles")
        assertEquals(system.getJSONArray("names").strings().toSet(), SystemFiles.NAMES)
        assertEquals(system.getString("appleDoublePrefix"), SystemFiles.APPLE_DOUBLE_PREFIX)
        val cases = system.getJSONArray("classify")
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val kind = SystemFiles.classify(case.getString("name"), case.optBoolean("hiddenFlag", false))
            assertEquals(case.getString("name"), case.getString("class"), kind.name.lowercase())
        }
    }

    @Test fun manifestDigest() {
        val digest = vectors.getJSONObject("manifestDigest")
        val array = digest.getJSONArray("entries")
        val entries = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            if (item.getString("type") == "dir") ManifestEntry(ManifestEntry.Type.DIR, item.getString("path"))
            else ManifestEntry(ManifestEntry.Type.FILE, item.getString("path"), item.getLong("size"), item.getString("sha256"),
                item.optLong("modified").takeIf { item.has("modified") })
        }
        assertEquals(digest.getString("sha256"), ManifestDigest.compute(digest.getString("rootName"), entries))
    }

    @Test fun completedBitmap() {
        val bitmap = vectors.getJSONObject("bitmap")
        val set = (0 until bitmap.getJSONArray("set").length()).map { bitmap.getJSONArray("set").getInt(it) }.toSet()
        val size = bitmap.getInt("size")
        assertEquals(bitmap.getString("base64"), CompletedBitmap.encode(size) { it in set })
        assertEquals(set, CompletedBitmap.decode(bitmap.getString("base64"), size))
        assertNull(CompletedBitmap.decode("CQ==", size))
    }

    /** One golden payload per message kind: what the Mac sends must parse here, and what this phone builds must match. */
    @Test fun goldenMessagesParseAndRoundTrip() {
        val messages = vectors.getJSONObject("messages")
        fun message(kind: String) = JSONObject(messages.getJSONObject(kind).toString())
        assertTrue(PlacesListPayload.parse(message("places.list")) != null)
        val listed = PlacesListedPayload.parse(message("places.listed"))!!
        assertEquals(DestinationMode.SENDER_PICKS, listed.mode)
        assertEquals(listOf(DEFAULT_PLACE_ID, "q3Jx0bVv1eG7tq8Wm2l5wA"), listed.places.map { it.placeId })
        assertEquals(sameJson(message("places.listed")), sameJson(listed.toJson()))
        assertEquals("Trip", PlacesBrowsePayload.parse(message("places.browse"))!!.path)
        assertEquals(sameJson(message("places.children")), sameJson(PlacesChildrenPayload.parse(message("places.children"))!!.toJson()))
        val create = PlacesCreateFolderPayload.parse(message("places.create_folder"))!!
        assertEquals(sameJson(message("places.folder_created")), sameJson(placesFolderCreatedJson(create)))
        assertEquals(sameJson(message("places.error")), sameJson(placesErrorJson(create.requestId, FolderCodes.NOT_FOUND)))
        val offer = (FolderOfferPayload.parse(message("folders.offer")) as FolderOfferPayload.Companion.Result.Valid).offer
        assertEquals(48, offer.skipped.system)
        assertEquals(FolderDestination("q3Jx0bVv1eG7tq8Wm2l5wA", "Trip"), offer.destination)
        val page = ManifestPagePayload.parse(message("folders.manifest"))!!
        assertTrue(ManifestAssembler(offer).add(page, 1_000) is ManifestAssembler.Result.Complete)
        assertEquals(sameJson(message("folders.waiting")), sameJson(foldersWaitingJson(offer.folderTransferId, WaitingReasons.DESTINATION)))
        val conflict = FolderConflictPayload(offer.folderTransferId, FolderConflictPayload.EXISTING_FOLDER, 12, 3, "Photos (1)",
            listOf(ConflictChoice.MERGE, ConflictChoice.REPLACE, ConflictChoice.NEW_FOLDER), 180)
        assertEquals(sameJson(message("folders.conflict")), sameJson(conflict.toJson()))
        assertEquals(ConflictChoice.MERGE, FolderResolvePayload.parse(message("folders.resolve"))!!.choice)
        assertEquals(sameJson(message("folders.accept")),
            sameJson(FolderAcceptPayload(offer.folderTransferId, "Photos", "Pictures/Trip", ConflictChoice.MERGE, null).toJson()))
        assertEquals(sameJson(message("folders.rejected")),
            sameJson(foldersRejectedJson(offer.folderTransferId, FolderCodes.INSUFFICIENT_SPACE, null, 2548170955, 1000000)))
        assertEquals(sameJson(message("folders.entry_failed")),
            sameJson(foldersEntryFailedJson(offer.folderTransferId, 2, "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", FolderCodes.IO_ERROR)))
        assertEquals(sameJson(message("folders.complete")), sameJson(FolderCompletePayload.parse(message("folders.complete"))!!.toJson()))
        val result = FolderResultPayload(offer.folderTransferId, false, 1, 2481123, 2, 0, 0, 1, listOf(FailedEntry(3, FolderCodes.SOURCE_CHANGED)))
        assertEquals(sameJson(message("folders.result")), sameJson(result.toJson()))
        assertEquals(sameJson(message("folders.cancel")), sameJson(FolderCancelPayload.parse(message("folders.cancel"))!!.toJson()))
        assertEquals(FolderFileFields(offer.folderTransferId, 2, "2019/IMG_0001.jpg"), FolderFileFields.parse(message("files.offer")))
    }

    /** JSON compared as a sorted string, so key order and null versus missing do not matter. */
    private fun sameJson(json: JSONObject): String = canonical(json)

    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().filter { !value.isNull(it) }.sorted()
            .joinToString(",", "{", "}") { "\"$it\":${canonical(value.get(it))}" }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        is Number -> value.toLong().toString()
        else -> value.toString()
    }
}
