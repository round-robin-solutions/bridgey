package dev.bridgey.android.folders

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlacesServerTest {
    private val clock = FakeClock()
    private val places = MemoryPlaces()
    private val downloads = MemoryTreeStore(supportsCreateFolder = false)
    private val pictures = MemoryTreeStore()
    private var settings = FolderReceiveSettings()
    private val answers = ArrayList<Pair<String, JSONObject>>()

    /** Requests wait here until [flush], to hold them in flight. */
    private val held = ArrayList<() -> Unit>()
    private var hold = false

    private val server = PlacesServer(
        places, { settings }, { kind, payload -> answers += kind to JSONObject(payload.toString()) },
        { task -> if (hold) held += task else task() }, clock::read,
    )

    init {
        places.entries += MemoryPlaces.Entry(DEFAULT_PLACE_ID, "Download/Bridgey", downloads)
        places.entries += MemoryPlaces.Entry(Phone.PICTURES, "Pictures", pictures)
        pictures.free = 81_604_378_624
    }

    private fun id() = UUID.randomUUID().toString()
    private fun list(requestId: String = id()) = server.handle(FolderKinds.PLACES_LIST, PlacesListPayload(requestId).toJson())
    private fun browse(path: String = "", cursor: String? = null, placeId: String = Phone.PICTURES, requestId: String = id()) =
        server.handle(FolderKinds.PLACES_BROWSE, PlacesBrowsePayload(requestId, placeId, path, cursor).toJson())

    private fun create(name: String, path: String = "", placeId: String = Phone.PICTURES, requestId: String = id()) =
        server.handle(FolderKinds.PLACES_CREATE_FOLDER, PlacesCreateFolderPayload(requestId, placeId, path, name).toJson())

    private fun lastCode(): String = answers.last().second.getString("code")

    @Test
    fun listAnswersTheModeAndPlacesOnlyWhenTheSenderPicks() {
        list()
        val (kind, listed) = answers.last()
        assertEquals(FolderKinds.PLACES_LISTED, kind)
        val parsed = PlacesListedPayload.parse(listed)!!
        assertEquals(DestinationMode.SENDER_PICKS, parsed.mode)
        assertEquals(listOf(DEFAULT_PLACE_ID, Phone.PICTURES), parsed.places.map { it.placeId })
        assertEquals(81_604_378_624, parsed.places[1].freeBytes)
        assertNull(parsed.places[0].freeBytes)
        assertNull(parsed.fixedLabel)
        assertFalse("never a URI", listed.toString().contains("content://"))

        settings = FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES)
        list()
        val fixed = PlacesListedPayload.parse(answers.last().second)!!
        assertEquals(DestinationMode.FIXED, fixed.mode)
        assertTrue(fixed.places.isEmpty())
        assertEquals("Pictures", fixed.fixedLabel)

        settings = FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS)
        list()
        assertTrue(PlacesListedPayload.parse(answers.last().second)!!.places.isEmpty())
    }

    @Test
    fun aPlaceThatLostAccessIsListedAsUnavailable() {
        places.entries.first { it.placeId == Phone.PICTURES }.available = false
        list()
        val parsed = PlacesListedPayload.parse(answers.last().second)!!
        assertFalse(parsed.places[1].available)
        browse()
        assertEquals("place_unavailable", lastCode())
    }

    @Test
    fun browseAndCreateAreRefusedOutsideSenderPicks() {
        for (mode in listOf(DestinationMode.RECEIVER_ASKS, DestinationMode.FIXED)) {
            settings = FolderReceiveSettings(mode = mode)
            browse()
            assertEquals(FolderKinds.PLACES_ERROR, answers.last().first)
            assertEquals("policy", lastCode())
            create("New")
            assertEquals("policy", lastCode())
        }
        assertTrue(pictures.tree().isEmpty())
    }

    @Test
    fun browseListsFolderNamesOnlySortedWithoutHiddenOnes() {
        pictures.mkdirs("Trip/beach")
        pictures.mkdirs("Trip/Album")
        pictures.mkdirs("Trip/.thumbnails")
        pictures.mkdirs("Trip/2019")
        pictures.put("Trip/photo.jpg", "x".toByteArray())
        pictures.put("Trip/.hidden", "x".toByteArray())
        pictures.put("Trip/.a.jpg.bridgey-part", "x".toByteArray())
        browse("Trip")
        val (kind, json) = answers.last()
        assertEquals(FolderKinds.PLACES_CHILDREN, kind)
        val children = PlacesChildrenPayload.parse(json)!!
        assertEquals(listOf("2019", "Album", "beach"), children.folders)
        assertEquals(1, children.fileCount)
        assertEquals(3, children.folderCount)
        assertNull(children.nextCursor)
        assertFalse("no file names", json.toString().contains("photo.jpg"))
        browse("Missing")
        assertEquals("not_found", lastCode())
        browse("trip")
        assertEquals("paths match exact names", "not_found", lastCode())
    }

    @Test
    fun browsePagesAt500NamesWithACursor() {
        (0 until 1_203).forEach { pictures.mkdirs("Big/folder %04d".format(it)) }
        val names = ArrayList<String>()
        var cursor: String? = null
        var pages = 0
        do {
            browse("Big", cursor)
            val page = PlacesChildrenPayload.parse(answers.last().second)!!
            assertTrue(page.folders.size <= 500)
            assertTrue(answers.last().second.toString().toByteArray().size <= FolderLimits.LARGE_PLAINTEXT)
            names += page.folders
            cursor = page.nextCursor
            pages++
        } while (cursor != null && pages < 10)
        assertEquals(3, pages)
        assertEquals((0 until 1_203).map { "folder %04d".format(it) }, names)
    }

    @Test
    fun longNamesSplitPagesBeforeTheyOutgrowTheMessage() {
        (0 until 300).forEach { pictures.mkdirs("Long/" + "n%03d".format(it) + "x".repeat(200)) }
        browse("Long")
        val first = PlacesChildrenPayload.parse(answers.last().second)!!
        assertTrue(first.folders.size < 300)
        assertTrue(answers.last().second.toString().toByteArray().size <= FolderLimits.LARGE_PLAINTEXT)
        assertTrue(first.nextCursor != null)
    }

    @Test
    fun createFolderChecksTheNameAndARepeatedRequestCreatesNothing() {
        pictures.mkdirs("Trip")
        val requestId = id()
        create("Trip 2026", requestId = requestId)
        assertEquals(FolderKinds.PLACES_FOLDER_CREATED, answers.last().first)
        assertEquals("Trip 2026", answers.last().second.getString("name"))
        pictures.nodes.values.first { it.name == "Trip 2026" }.name = "Renamed"
        create("Trip 2026", requestId = requestId)
        assertEquals(FolderKinds.PLACES_FOLDER_CREATED, answers.last().first)
        assertEquals(listOf("Renamed/", "Trip/"), pictures.tree())
        create("trip")
        assertEquals("exists", lastCode())
        create("Trip: 2026?")
        assertEquals("invalid_name", lastCode())
        create("bad.")
        assertEquals("invalid_name", lastCode())
        create("x", path = "Missing")
        assertEquals("not_found", lastCode())
        create("x", placeId = DEFAULT_PLACE_ID)
        assertEquals("Download/Bridgey without full access cannot make folders", "policy", lastCode())
    }

    @Test
    fun rateLimitsAnswerBusy() {
        hold = true
        repeat(4) { list() }
        assertTrue(answers.isEmpty())
        list()
        assertEquals("busy", lastCode())
        hold = false
        held.forEach { it() }
        held.clear()
        // 20 per 10 seconds: 5 so far (4 counted plus nothing for the refused one), 15 more pass.
        answers.clear()
        repeat(16) { list() }
        assertEquals(16, answers.count { it.first == FolderKinds.PLACES_LISTED })
        list()
        assertEquals("busy", lastCode())
        clock.now += 10_000
        list()
        assertEquals(FolderKinds.PLACES_LISTED, answers.last().first)
    }

    @Test
    fun malformedRequestsAreAnsweredAndKeepTheSession() {
        server.handle(FolderKinds.PLACES_BROWSE, JSONObject().put("version", 1).put("requestId", id()).put("placeId", Phone.PICTURES).put("path", "../x"))
        assertEquals("invalid_message", lastCode())
        val before = answers.size
        server.handle(FolderKinds.PLACES_LIST, JSONObject().put("version", 1).put("requestId", "not-a-uuid"))
        assertEquals("no request ID to answer", before, answers.size)
    }
}
