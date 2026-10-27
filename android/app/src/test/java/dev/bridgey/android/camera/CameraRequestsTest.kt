package dev.bridgey.android.camera

import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.featureEnabledByLegacyPeer
import dev.bridgey.android.featureOnByDefault
import dev.bridgey.android.fileOfferPayload
import java.io.File
import java.nio.file.Files
import javax.xml.parsers.DocumentBuilderFactory
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Fakes and plain JSON only: nothing here opens the real camera. */
class CameraRequestsTest {
    private var now = 5_000_000L
    private val requests = CameraRequests { now }
    private val id = "0f8e2a4b-7c1d-4e2f-9a3b-5c6d7e8f9a0b"
    private val other = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

    private fun request(requestId: String = id, mode: Any? = "photo", version: Any? = 1) =
        JSONObject().put("version", version).put("requestId", requestId).put("mode", mode)

    @Test fun onlyWellFormedRequestsAreRead() {
        assertEquals(id, parseCameraRequest(request()))
        assertEquals(id, parseCameraRequest(request(id.uppercase())))
        assertNull(parseCameraRequest(request(mode = "video")))
        assertNull(parseCameraRequest(request(mode = null)))
        assertNull(parseCameraRequest(request(version = 2)))
        assertNull(parseCameraRequest(request("not-a-uuid")))
        assertNull(parseCameraRequest(request("1-2-3-4-5")))
        assertNull(parseCameraRequest(JSONObject().put("version", 1).put("mode", "photo")))
        assertEquals(CameraDecision.Drop, requests.receive("mac", "Mac", request(mode = "scan"), enabled = true))
    }

    @Test fun switchedOffIsDisabled() {
        assertEquals(CameraDecision.Refuse(id, CameraStatus.DISABLED), requests.receive("mac", "Mac", request(), enabled = false))
        assertNull(requests.current("mac", id))
    }

    @Test fun oneOpenRequestPerMacAndRateLimited() {
        val accepted = requests.receive("mac", "Work MacBook", request(), enabled = true) as CameraDecision.Accept
        assertEquals("Work MacBook", accepted.request.macName)
        // Within 3 seconds: busy (rate limit).
        now += 1_000
        assertEquals(CameraDecision.Refuse(other, CameraStatus.BUSY), requests.receive("mac", "Work MacBook", request(other), enabled = true))
        // Later, but the first is still open: busy.
        now += CAMERA_REQUEST_SPACING_MILLIS
        assertEquals(CameraDecision.Refuse(other, CameraStatus.BUSY), requests.receive("mac", "Work MacBook", request(other), enabled = true))
        // Another Mac is independent.
        assertTrue(requests.receive("mac-2", "Home Mac", request(other), enabled = true) is CameraDecision.Accept)
        // Finished: a new request is welcome.
        assertTrue(requests.finish("mac", id))
        assertFalse(requests.finish("mac", id))
        now += CAMERA_REQUEST_SPACING_MILLIS
        assertTrue(requests.receive("mac", "Work MacBook", request(other), enabled = true) is CameraDecision.Accept)
    }

    @Test fun requestsExpireAfterTwoMinutes() {
        requests.receive("mac", "Mac", request(), enabled = true)
        assertNotNull(requests.current("mac", id))
        assertNull(requests.current("mac", other))
        now += CAMERA_REQUEST_LIFETIME_MILLIS
        assertNull(requests.current("mac", id))
        // Expired: the next request is accepted.
        assertTrue(requests.receive("mac", "Mac", request(other), enabled = true) is CameraDecision.Accept)
    }

    @Test fun disconnectEndsTheRequest() {
        requests.receive("mac", "Mac", request(), enabled = true)
        assertEquals(id, requests.ended("mac")?.requestId)
        assertNull(requests.current("mac", id))
        assertNull(requests.ended("mac"))
    }

    @Test fun aLockedPhoneNeverOpensTheCamera() {
        assertEquals(CameraRoute.LOCKED_NOTIFICATION, cameraRoute(locked = true, appInForeground = true))
        assertEquals(CameraRoute.LOCKED_NOTIFICATION, cameraRoute(locked = true, appInForeground = false))
        assertEquals(CameraRoute.OPEN_NOW, cameraRoute(locked = false, appInForeground = true))
        assertEquals(CameraRoute.NOTIFICATION, cameraRoute(locked = false, appInForeground = false))
    }

    @Test fun statusesUseTheWireNames() {
        assertEquals(
            listOf("opened", "locked", "permission_required", "cancelled", "busy", "disabled", "sending", "failed"),
            CameraStatus.entries.map { it.wire },
        )
        val payload = cameraStatusPayload(id, CameraStatus.LOCKED)
        assertEquals(1, payload.get("version"))
        assertEquals(id, payload.get("requestId"))
        assertEquals("locked", payload.get("status"))
    }

    @Test fun thePhotoOfferCarriesTheRequestId() {
        val photo = fileOfferPayload("t1", "Photo-20261027-094100.jpg", "image/jpeg", 123L, "aGFzaA==", id)
        assertEquals(id, photo.getString("cameraRequestId"))
        assertEquals("image/jpeg", photo.getString("mimeType"))
        val plain = fileOfferPayload("t2", "notes.txt", "text/plain", 3L, "aGFzaA==")
        assertFalse(plain.has("cameraRequestId"))
        assertEquals(setOf("transferId", "name", "mimeType", "size", "sha256"), plain.keys().asSequence().toSet())
    }

    @Test fun theFeatureIsOnByDefaultAndNewToPeers() {
        assertEquals(CAMERA_FEATURE_KEY, BridgeyFeature.CAMERA.key)
        assertTrue(featureOnByDefault(BridgeyFeature.CAMERA))
        assertFalse(featureEnabledByLegacyPeer(BridgeyFeature.CAMERA))
    }

    @Test fun leftoverPhotosGoAfterAnHour() {
        val cache = Files.createTempDirectory("camera-test").toFile()
        val folder = File(cache, CameraActivity.CACHE_FOLDER).apply { mkdirs() }
        val old = File(folder, "old.jpg").apply { writeText("x"); setLastModified(1_000L) }
        val fresh = File(folder, "fresh.jpg").apply { writeText("x"); setLastModified(now - 60_000) }
        CameraActivity.removeOldPhotos(cache, now)
        assertFalse(old.exists())
        assertTrue(fresh.exists())
        cache.deleteRecursively()
    }

    @Test fun theCameraScreenIsNotExportedAndPhotosAreShared() {
        val ns = "http://schemas.android.com/apk/res/android"
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File("src/main/AndroidManifest.xml"))
        val activities = doc.getElementsByTagName("activity")
        val camera = (0 until activities.length).map { activities.item(it) }.first {
            it.attributes.getNamedItemNS(ns, "name")?.nodeValue == ".camera.CameraActivity"
        }
        assertEquals("false", camera.attributes.getNamedItemNS(ns, "exported").nodeValue)
        assertTrue(File("src/main/res/xml/file_paths.xml").readText().contains("path=\"camera/\""))
    }
}
