package dev.bridgey.android.folders

import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderReceiverTest {
    @get:Rule val temp = TemporaryFolder()

    private val clock = FakeClock()
    private val scheduler = FakeScheduler(clock)
    private val places = MemoryPlaces()
    private val pictures = MemoryTreeStore()
    private var settings = FolderReceiveSettings()
    private val snapshots = ArrayList<FolderSnapshot>()
    private val finished = ArrayList<FolderSnapshot>()
    private lateinit var receiver: FolderReceiver

    private val folder = TestFolder("Photos", mapOf("a.txt" to "alpha".toByteArray(), "b/c.txt" to "c".toByteArray()))

    private fun receiver(): FolderReceiver {
        places.entries += MemoryPlaces.Entry(DEFAULT_PLACE_ID, "Download/Bridgey", MemoryTreeStore(supportsCreateFolder = false))
        places.entries += MemoryPlaces.Entry(Phone.PICTURES, "Pictures", pictures)
        return FolderReceiver(
            places, { settings }, FolderJournals(temp.newFolder(), clock::read),
            object : FolderReceiverListener {
                override fun snapshot(snapshot: FolderSnapshot) {
                    snapshots += snapshot
                }

                override fun finished(snapshot: FolderSnapshot) {
                    finished += snapshot
                }
            },
            { InlineFolderWorker() }, scheduler, { it() }, clock::read,
        ).also { receiver = it }
    }

    private fun offer(link: RecordingLink, device: String = "mac-1", id: String = UUID.randomUUID().toString(), destination: FolderDestination? = FolderDestination(Phone.PICTURES, "")): String {
        receiver.offer(device, "MacBook Pro", link, folder.offer(id, destination).toJson())
        folder.pages(id).forEach { receiver.manifest(device, it.toJson(), 100) }
        return id
    }

    private fun sendFile(device: String, folderId: String, path: String): String {
        val transferId = UUID.randomUUID().toString()
        val content = folder.contents.getValue(path)
        val payload = JSONObject().put("transferId", transferId).put("name", FolderPaths.leaf(path)).put("mimeType", "application/octet-stream")
            .put("size", content.size).put("sha256", sha(content)).put("folderTransferId", folderId).put("entry", folder.index(path)).put("path", path)
        assertTrue(receiver.fileOffer(device, transferId, payload))
        assertTrue(receiver.handles(transferId))
        receiver.chunk(transferId, 0, content)
        receiver.fileComplete(transferId, sha(content))
        return transferId
    }

    @Test
    fun aSecondFolderFromTheSameDeviceIsBusyButAnotherDeviceMayStart() {
        receiver()
        val link = RecordingLink()
        val first = offer(link)
        assertNotNull(receiver.activeFor("mac-1"))
        val second = RecordingLink()
        val secondId = offer(second)
        val rejected = second.last(FolderKinds.REJECTED)!!
        assertEquals("busy", rejected.getString("code"))
        assertEquals(secondId, second.sent.last().outer)
        assertEquals(first, receiver.activeFor("mac-1")!!.id)
        val other = RecordingLink()
        offer(other, device = "mac-2")
        assertNull(other.last(FolderKinds.REJECTED))
        assertNotNull(receiver.activeFor("mac-2"))
    }

    @Test
    fun filesOfAFolderAreRoutedToItsSessionAndPlainFilesAreNot() {
        receiver()
        val link = RecordingLink()
        val id = offer(link)
        assertFalse(receiver.fileOffer("mac-1", UUID.randomUUID().toString(), JSONObject().put("transferId", "x").put("name", "a.txt")))
        sendFile("mac-1", id, "a.txt")
        sendFile("mac-1", id, "b/c.txt")
        receiver.complete("mac-1", FolderCompletePayload(id, 2, 0, emptyList()).toJson())
        assertEquals("complete", link.last(FolderKinds.RESULT)!!.getString("status"))
        assertEquals(FolderEnd.COMPLETE, finished.single().end)
        assertNull(receiver.activeFor("mac-1"))
        assertEquals(listOf("Photos/", "Photos/a.txt", "Photos/b/", "Photos/b/c.txt"), pictures.tree())
    }

    @Test
    fun anotherDeviceCannotTouchAFolderThatIsNotItsOwn() {
        receiver()
        val link = RecordingLink()
        val id = offer(link)
        val transferId = UUID.randomUUID().toString()
        val payload = JSONObject().put("transferId", transferId).put("folderTransferId", id).put("entry", folder.index("a.txt")).put("path", "a.txt")
        assertTrue("dropped quietly", receiver.fileOffer("mac-2", transferId, payload))
        receiver.cancel("mac-2", RecordingLink(), FolderCancelPayload(id, CancelReasons.USER, null).toJson())
        assertNotNull(receiver.activeFor("mac-1"))
        assertEquals(0, link.count("files.accept"))
    }

    @Test
    fun filesOfAFolderThatEndedAreDroppedQuietly() {
        receiver()
        val link = RecordingLink()
        val id = offer(link)
        receiver.cancel(id)
        val transferId = UUID.randomUUID().toString()
        val sentBefore = link.sent.size
        assertTrue(receiver.fileOffer("mac-1", transferId, JSONObject().put("folderTransferId", id).put("entry", 1).put("path", "a.txt")))
        assertTrue(receiver.handles(transferId))
        receiver.chunk(transferId, 0, ByteArray(3))
        assertEquals(sentBefore, link.sent.size)
        // A late folders.cancel is still acknowledged, outside the ciphertext.
        val late = RecordingLink()
        receiver.cancel("mac-1", late, FolderCancelPayload(id, CancelReasons.USER, null).toJson())
        assertEquals(FolderKinds.CANCEL_ACK, late.sent.single().kind)
    }

    @Test
    fun invalidOffersAreRejectedWithoutClosingAnything() {
        receiver()
        val link = RecordingLink()
        val id = UUID.randomUUID().toString()
        receiver.offer("mac-1", "Mac", link, folder.offer(id).toJson().put("rootName", "bad:name"))
        assertEquals("invalid_manifest", link.last(FolderKinds.REJECTED)!!.getString("code"))
        receiver.offer("mac-1", "Mac", link, folder.offer(id).toJson().put("version", 2))
        assertEquals("unsupported", link.last(FolderKinds.REJECTED)!!.getString("code"))
        receiver.offer("mac-1", "Mac", link, folder.offer(id).toJson().put("fileCount", 20_000))
        assertEquals("limit_exceeded", link.last(FolderKinds.REJECTED)!!.getString("code"))
        assertNull(receiver.activeFor("mac-1"))
        // A broken page after a good offer ends that folder with invalid_message.
        receiver.offer("mac-1", "Mac", link, folder.offer(id).toJson())
        receiver.manifest("mac-1", JSONObject().put("version", 1).put("folderTransferId", id).put("page", 0).put("entries", "nope"), 10)
        assertEquals("invalid_message", link.last(FolderKinds.REJECTED)!!.getString("code"))
    }

    @Test
    fun questionsAreCollectedPerFolderAndAnsweredByID() {
        settings = FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS)
        receiver()
        val link = RecordingLink()
        val id = offer(link, destination = null)
        val question = receiver.questions.value.single()
        assertEquals(id, question.folderTransferId)
        assertEquals("MacBook Pro", question.deviceName)
        val second = RecordingLink()
        val otherId = offer(second, device = "mac-2", destination = null)
        assertEquals(listOf(id, otherId), receiver.questions.value.map { it.folderTransferId })
        receiver.answerDestination(id, DestinationAnswer(placeId = Phone.PICTURES))
        assertEquals(listOf(otherId), receiver.questions.value.map { it.folderTransferId })
        scheduler.advance(180_000)
        assertTrue(receiver.questions.value.isEmpty())
        assertEquals(FolderEnd.TIMED_OUT, finished.single { it.folderTransferId == otherId }.end)
    }

    @Test
    fun aDisconnectInterruptsOnlyThatDevicesFolders() {
        receiver()
        val one = offer(RecordingLink())
        offer(RecordingLink(), device = "mac-2")
        receiver.deviceGone("mac-1")
        assertEquals(listOf(one), finished.map { it.folderTransferId })
        assertEquals(FolderEnd.INTERRUPTED, finished.single().end)
        assertNotNull(receiver.activeFor("mac-2"))
    }

    @Test
    fun placesRequestsAreServedPerDevice() {
        receiver()
        val link = RecordingLink()
        receiver.places("mac-1", link, FolderKinds.PLACES_LIST, PlacesListPayload(UUID.randomUUID().toString()).toJson())
        assertEquals(FolderKinds.PLACES_LISTED, link.sent.single().kind)
    }
}
