package dev.bridgey.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ShareTargetFilterTest {
    private val id = "dev.bridgey.android"

    @Test fun anotherAppsContentUriIsShareable() {
        assertTrue(isShareableStream("content", "com.android.providers.media.documents", id))
        assertTrue(isShareableStream("CONTENT", "media", id))
        assertTrue("a different app whose name only begins the same", isShareableStream("content", "dev.bridgey.androidx.files", id))
    }

    @Test fun filePathsAndOtherSchemesAreDropped() {
        assertFalse(isShareableStream("file", null, id))
        assertFalse(isShareableStream("file", "", id))
        assertFalse(isShareableStream("http", "example.com", id))
        assertFalse(isShareableStream(null, null, id))
        assertFalse(isShareableStream("content", null, id))
    }

    @Test fun bridgeysOwnProvidersAreDropped() {
        assertFalse(isShareableStream("content", "$id.fileprovider", id))
        assertFalse(isShareableStream("content", "$id.clipboard", id))
        assertFalse(isShareableStream("content", "DEV.BRIDGEY.ANDROID.clipboard", id))
        assertFalse("a user-prefixed authority", isShareableStream("content", "0@$id.fileprovider", id))
        assertFalse(isShareableStream("content", id, id))
    }
}
