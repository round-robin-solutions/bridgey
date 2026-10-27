package dev.bridgey.android.folders

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Phone free space before big sends: places.listed carries defaultFreeBytes in every mode; folders.accept carries freeBytes. */
class FreeSpaceTest {
    @get:Rule val temp = TemporaryFolder()

    private val places = MemoryPlaces()
    private val downloads = MemoryTreeStore(supportsCreateFolder = false).apply { free = 5_000_000_000 }
    private val pictures = MemoryTreeStore().apply { free = 81_604_378_624 }
    private var settings = FolderReceiveSettings()
    private val answers = ArrayList<Pair<String, JSONObject>>()
    private val server = PlacesServer(places, { settings }, { kind, payload -> answers += kind to JSONObject(payload.toString()) }, { it() })

    init {
        places.entries += MemoryPlaces.Entry(DEFAULT_PLACE_ID, "Download/Bridgey", downloads)
        places.entries += MemoryPlaces.Entry(Phone.PICTURES, "Pictures", pictures)
    }

    private fun listed(): JSONObject {
        server.handle(FolderKinds.PLACES_LIST, PlacesListPayload(UUID.randomUUID().toString()).toJson())
        return answers.last().also { assertEquals(FolderKinds.PLACES_LISTED, it.first) }.second
    }

    @Test
    fun listedCarriesTheDefaultFreeSpaceInEveryMode() {
        settings = FolderReceiveSettings(mode = DestinationMode.SENDER_PICKS)
        assertEquals(5_000_000_000, listed().getLong("defaultFreeBytes"))
        settings = FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS)
        val asks = listed()
        assertEquals(0, asks.getJSONArray("places").length())
        assertEquals(5_000_000_000, asks.getLong("defaultFreeBytes"))
        // Fixed mode: the default folder's storage, not Download/Bridgey.
        settings = FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES)
        val fixed = listed()
        assertEquals(0, fixed.getJSONArray("places").length())
        assertEquals(81_604_378_624, fixed.getLong("defaultFreeBytes"))
        // Unknown free space, or a default folder that lost access: null.
        places.entries[1].available = false
        assertTrue(listed().isNull("defaultFreeBytes"))
        settings = FolderReceiveSettings()
        downloads.free = null
        assertTrue(listed().isNull("defaultFreeBytes"))
    }

    @Test
    fun listedRoundTripsTheField() {
        val payload = PlacesListedPayload(UUID.randomUUID().toString(), DestinationMode.FIXED, emptyList(), "Pictures", 1234)
        assertEquals(1234L, PlacesListedPayload.parse(payload.toJson())!!.defaultFreeBytes)
        assertEquals(null, PlacesListedPayload.parse(payload.copy(defaultFreeBytes = null).toJson())!!.defaultFreeBytes)
    }

    @Test
    fun acceptCarriesTheChosenDestinationsFreeSpace() {
        val phone = Phone(temp.newFolder(), FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
        phone.pictures.free = 42_000_000_000
        val link = RecordingLink()
        phone.deliver(TestFolder("Photos", mapOf("a.txt" to "a".toByteArray())), link)
        val accept = link.last(FolderKinds.ACCEPT)!!
        assertEquals(42_000_000_000, accept.getLong("freeBytes"))
        assertEquals(42_000_000_000, parseFolderAccept(accept)!!.freeBytes)
        // Unknown free space is null, not a missing field.
        val unknown = Phone(temp.newFolder(), FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
        val other = RecordingLink()
        unknown.deliver(TestFolder("Photos", mapOf("a.txt" to "a".toByteArray())), other)
        assertTrue(other.last(FolderKinds.ACCEPT)!!.has("freeBytes"))
        assertTrue(other.last(FolderKinds.ACCEPT)!!.isNull("freeBytes"))
    }
}
