package dev.bridgey.android.folders

import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Uploads from the Mac's Phone files window: `into` offers, the browse switch and "Allow other devices to change files here". */
class FolderUploadTest {
    @get:Rule val temp = TemporaryFolder()

    private val writable = FolderReceiveSettings(allowReplaceFromOtherDevices = true, allowBrowse = true)

    private fun upload(phone: Phone, folder: TestFolder, link: RecordingLink, destination: FolderDestination?, downloadRequestId: String? = null): FolderReceiveSession {
        val id = UUID.randomUUID().toString()
        val env = FolderEnvironment(phone.places, { phone.settings }, phone.journals, InlineFolderWorker(), phone.scheduler, phone.clock::read)
        val offer = folder.offer(id, destination).copy(into = true, downloadRequestId = downloadRequestId)
        val session = FolderReceiveSession(offer, "mac-1", "MacBook Pro", env, link, phone.listener)
        session.start()
        folder.pages(id).forEach { session.manifestPage(it, it.toJson().toString().length) }
        return session
    }

    private val items = TestFolder(
        "a.txt",
        mapOf("a.txt" to "new a".toByteArray(), "Photos/p.jpg" to ByteArray(3_000) { it.toByte() }, "b.txt" to "b".toByteArray()),
    )

    @Test
    fun anUploadLandsInTheBrowsedFolderAndClashesBecomeCopies() {
        val phone = Phone(temp.newFolder(), writable)
        phone.pictures.put("Trip/a.txt", "old a".toByteArray())
        phone.pictures.put("Trip/Photos/p.jpg", "old p".toByteArray())
        val link = RecordingLink()
        val session = upload(phone, items, link, FolderDestination(Phone.PICTURES, "Trip"))
        val accept = link.last(FolderKinds.ACCEPT)!!
        assertEquals("none", accept.getString("choice"))
        assertEquals("Pictures/Trip", accept.getString("destinationLabel"))
        session.sendAll(items)
        session.completeFolder(3)
        assertEquals(FolderEnd.COMPLETE, phone.finished!!.end)
        // Nothing merged, nothing overwritten.
        assertArrayEquals("old a".toByteArray(), phone.pictures.find("Trip/a.txt")!!.content)
        assertArrayEquals("new a".toByteArray(), phone.pictures.find("Trip/a (1).txt")!!.content)
        assertArrayEquals("old p".toByteArray(), phone.pictures.find("Trip/Photos/p.jpg")!!.content)
        assertEquals(3_000, phone.pictures.find("Trip/Photos (1)/p.jpg")!!.content.size)
        assertNotNull(phone.pictures.find("Trip/b.txt"))
        // No root folder named after the first item.
        assertNull(phone.pictures.find("Trip/a.txt/a.txt"))
        assertTrue(phone.used.isEmpty())
    }

    @Test
    fun uploadsNeedTheChangeSwitch() {
        val phone = Phone(temp.newFolder(), writable.copy(allowReplaceFromOtherDevices = false))
        val link = RecordingLink()
        upload(phone, items, link, FolderDestination(Phone.PICTURES, ""))
        assertEquals(FolderCodes.READ_ONLY, link.last(FolderKinds.REJECTED)!!.getString("code"))
        assertTrue(phone.pictures.nodes.size == 1)
    }

    @Test
    fun uploadsNeedBrowsingOn() {
        val phone = Phone(temp.newFolder(), writable.copy(allowBrowse = false))
        val link = RecordingLink()
        upload(phone, items, link, FolderDestination(Phone.PICTURES, ""))
        assertEquals(FolderCodes.POLICY, link.last(FolderKinds.REJECTED)!!.getString("code"))
    }

    @Test
    fun uploadsNeedADestinationThatExists() {
        val phone = Phone(temp.newFolder(), writable)
        val link = RecordingLink()
        upload(phone, items, link, null)
        assertEquals(FolderCodes.INVALID_MESSAGE, link.last(FolderKinds.REJECTED)!!.getString("code"))
        val missing = RecordingLink()
        upload(phone, items, missing, FolderDestination(Phone.PICTURES, "Nope"))
        assertEquals(FolderCodes.NOT_FOUND, missing.last(FolderKinds.REJECTED)!!.getString("code"))
    }

    @Test
    fun aPhoneNeverTakesAnOfferThatAnswersADownload() {
        val phone = Phone(temp.newFolder(), writable)
        val link = RecordingLink()
        upload(phone, items, link, FolderDestination(Phone.PICTURES, ""), downloadRequestId = UUID.randomUUID().toString())
        assertEquals(FolderCodes.POLICY, link.last(FolderKinds.REJECTED)!!.getString("code"))
    }

    @Test
    fun theOfferFieldsRoundTrip() {
        val requestId = UUID.randomUUID().toString()
        val offer = items.offer(UUID.randomUUID().toString()).copy(into = true, downloadRequestId = requestId)
        val parsed = FolderOfferPayload.parse(offer.toJson()) as FolderOfferPayload.Companion.Result.Valid
        assertTrue(parsed.offer.into)
        assertEquals(requestId, parsed.offer.downloadRequestId)
        val plain = FolderOfferPayload.parse(items.offer(UUID.randomUUID().toString()).toJson()) as FolderOfferPayload.Companion.Result.Valid
        assertEquals(false, plain.offer.into)
        assertNull(plain.offer.downloadRequestId)
        val bad = FolderOfferPayload.parse(offer.toJson().put("downloadRequestId", "nope"))
        assertTrue(bad is FolderOfferPayload.Companion.Result.Invalid)
    }
}
