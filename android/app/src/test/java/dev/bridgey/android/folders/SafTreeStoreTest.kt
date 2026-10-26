package dev.bridgey.android.folders

import android.app.Application
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

/**
 * A small DocumentsProvider backed by a temporary directory. Like ExternalStorageProvider it refuses a name
 * that already exists, so the test sees any clash the store failed to avoid (Bridgey never relies on a
 * provider's own numbering).
 */
class FakeDocumentsProvider : DocumentsProvider() {
    private fun file(id: String): File = if (id == ROOT_DOC) base else File(base, id.removePrefix("$ROOT_DOC/"))
    private fun id(file: File): String = if (file == base) ROOT_DOC else "$ROOT_DOC/" + file.relativeTo(base).invariantSeparatorsPath

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE, Root.COLUMN_FLAGS, Root.COLUMN_AVAILABLE_BYTES)).apply {
        addRow(arrayOf<Any>("r", ROOT_DOC, "Test storage", Root.FLAG_SUPPORTS_CREATE, 123_456L))
    }

    private val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE)

    /** Honours the projection, like a real provider. */
    private fun row(cursor: MatrixCursor, file: File) {
        val flags = if (file.isDirectory) Document.FLAG_DIR_SUPPORTS_CREATE or Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
        else Document.FLAG_SUPPORTS_WRITE or Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
        val values = mapOf<String, Any>(
            Document.COLUMN_DOCUMENT_ID to id(file), Document.COLUMN_DISPLAY_NAME to file.name,
            Document.COLUMN_MIME_TYPE to if (file.isDirectory) Document.MIME_TYPE_DIR else "application/octet-stream",
            Document.COLUMN_FLAGS to flags, Document.COLUMN_SIZE to file.length(),
        )
        cursor.addRow(cursor.columnNames.map { values[it] }.toTypedArray())
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor = MatrixCursor(projection ?: columns).also {
        val target = file(documentId)
        if (!target.exists()) throw java.io.FileNotFoundException(documentId)
        row(it, target)
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        queries++
        if (!file(parentDocumentId).isDirectory) throw java.io.FileNotFoundException(parentDocumentId)
        return MatrixCursor(projection ?: columns).also { cursor -> file(parentDocumentId).listFiles().orEmpty().sortedBy { it.name }.forEach { row(cursor, it) } }
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file(documentId), ParcelFileDescriptor.parseMode(mode))

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        val target = File(file(parentDocumentId), displayName)
        check(!target.exists()) { "exists: $displayName" }
        if (mimeType == Document.MIME_TYPE_DIR) check(target.mkdir()) else check(target.createNewFile())
        return id(target)
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        val source = file(documentId)
        val target = File(source.parentFile, displayName)
        check(!target.exists()) { "exists: $displayName" }
        check(source.renameTo(target))
        return id(target)
    }

    override fun deleteDocument(documentId: String) {
        check(file(documentId).deleteRecursively())
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        parentDocumentId == ROOT_DOC || documentId.startsWith("$parentDocumentId/")

    companion object {
        const val AUTHORITY = "dev.bridgey.test.documents"
        const val ROOT_DOC = "root"
        lateinit var base: File
        var queries = 0
    }
}

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class SafTreeStoreTest {
    private lateinit var base: File
    private lateinit var treeUri: Uri
    private lateinit var store: SafTreeStore
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    @Before
    fun setUp() {
        base = File(System.getProperty("java.io.tmpdir"), "bridgey-saf-" + UUID.randomUUID()).apply { mkdirs() }
        FakeDocumentsProvider.base = base
        FakeDocumentsProvider.queries = 0
        val info = ProviderInfo().apply {
            authority = FakeDocumentsProvider.AUTHORITY
            exported = true
            grantUriPermissions = true
            readPermission = android.Manifest.permission.MANAGE_DOCUMENTS
            writePermission = android.Manifest.permission.MANAGE_DOCUMENTS
        }
        Robolectric.buildContentProvider(FakeDocumentsProvider::class.java).create(info)
        treeUri = DocumentsContract.buildTreeDocumentUri(FakeDocumentsProvider.AUTHORITY, FakeDocumentsProvider.ROOT_DOC)
        // What the folder picker hands back, then the persisted grant Bridgey takes.
        context.contentResolver.takePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        store = SafTreeStore(context.contentResolver, treeUri)
    }

    @After
    fun tearDown() {
        base.deleteRecursively()
    }

    private fun tree(): List<String> = base.walkTopDown().filter { it != base }
        .map { it.relativeTo(base).invariantSeparatorsPath + if (it.isDirectory) "/" else "" }.sorted().toList()

    private fun session(folder: TestFolder, link: RecordingLink, settings: FolderReceiveSettings): FolderReceiveSession {
        val places = object : PlaceDirectory {
            override fun places() = listOf(PlaceRef(Phone.PICTURES, "Pictures", true, { store }))
        }
        val clock = FakeClock()
        val env = FolderEnvironment(places, { settings }, null, InlineFolderWorker(), FakeScheduler(clock), clock::read)
        val offer = folder.offer(UUID.randomUUID().toString(), FolderDestination(Phone.PICTURES, ""))
        return FolderReceiveSession(offer, "mac-1", "Mac", env, link, object : FolderSessionListener {}).also { session ->
            session.start()
            folder.pages(session.id).forEach { session.manifestPage(it, 100) }
        }
    }

    @Test
    fun theGrantIsPersistedAndTheStoreListsCreatesRenamesAndDeletes() {
        assertTrue(context.contentResolver.persistedUriPermissions.any { it.uri == treeUri && it.isWritePermission })
        assertEquals(FakeDocumentsProvider.ROOT_DOC, store.rootId)
        val dir = store.createDirectory(store.rootId, "Trip")
        val file = store.createFile(dir, "a b.txt")
        store.openOutput(file).use { it.write("hello".toByteArray()) }
        assertEquals(listOf(TreeNode(dir, "Trip", true)), store.children(store.rootId))
        assertEquals("a b.txt", store.children(dir).single().name)
        val renamed = store.rename(file, "c.txt")
        assertEquals("hello", File(base, "Trip/c.txt").readText())
        assertEquals(renamed, store.idOf(store.uriOf(renamed)))
        assertTrue(store.uriOf(renamed).startsWith("content://${FakeDocumentsProvider.AUTHORITY}/tree/"))
        store.delete(renamed)
        assertTrue(store.children(dir).isEmpty())
        assertEquals("Trip", resolveExistingPath(store, "Trip")?.let { id -> store.children(store.rootId).first { it.id == id }.name })
        assertTrue(store.reachable())
        assertTrue(store.supportsCreate())
        assertEquals(base.name, store.rootName())
    }

    @Test
    fun aWholeTreeLandsThroughTheRealStorageAccessFramework() {
        val big = ByteArray(1_300_000) { (it % 253).toByte() }
        val folder = TestFolder(
            "Photos",
            mapOf("2019/a.jpg" to "a".toByteArray(), "2019/deep/b.jpg" to "b".toByteArray(), "movie.mov" to big, "z.txt" to "z".toByteArray()),
            dirs = listOf("Empty", "2019/Also empty"),
        )
        val link = RecordingLink()
        val session = session(folder, link, FolderReceiveSettings())
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        session.sendFile(folder, "2019/a.jpg")
        session.sendFile(folder, "2019/deep/b.jpg")
        session.sendFile(folder, "movie.mov", complete = false)
        assertTrue("large files are written as a hidden part first", File(base, "Photos/.movie.mov.bridgey-part").exists())
        session.fileComplete(link.sent.last { it.kind == "files.accept" }.outer!!, sha(big))
        session.sendFile(folder, "z.txt")
        session.completeFolder(4)
        assertEquals("complete", link.last(FolderKinds.RESULT)!!.getString("status"))
        assertEquals(
            listOf(
                "Photos/", "Photos/2019/", "Photos/2019/Also empty/", "Photos/2019/a.jpg", "Photos/2019/deep/", "Photos/2019/deep/b.jpg",
                "Photos/Empty/", "Photos/movie.mov", "Photos/z.txt",
            ),
            tree(),
        )
        assertArrayEquals(big, File(base, "Photos/movie.mov").readBytes())
    }

    @Test
    fun replaceAndNumberingWorkAgainstAProviderThatRefusesClashes() {
        File(base, "Photos/2019").mkdirs()
        File(base, "Photos/a.txt").writeText("old a")
        File(base, "Photos/b.txt").writeText("old b")
        File(base, "Photos/2019/c.txt").writeText("old c")
        val folder = TestFolder("Photos", mapOf("a.txt" to "new a".toByteArray(), "b.txt" to "new b".toByteArray(), "2019/c.txt" to "new c".toByteArray()))

        val replace = RecordingLink()
        session(folder, replace, FolderReceiveSettings(policy = ConflictPolicy.REPLACE)).apply {
            sendAll(folder)
            completeFolder(3)
        }
        assertEquals(3, replace.last(FolderKinds.RESULT)!!.getInt("replacedFiles"))
        assertEquals("new a", File(base, "Photos/a.txt").readText())
        assertEquals("new c", File(base, "Photos/2019/c.txt").readText())
        assertFalse(tree().any { it.contains("bridgey-part") })

        val merge = RecordingLink()
        session(folder, merge, FolderReceiveSettings(policy = ConflictPolicy.MERGE)).apply {
            sendAll(folder)
            completeFolder(3)
        }
        assertEquals("new a", File(base, "Photos/a (1).txt").readText())
        assertEquals("new c", File(base, "Photos/2019/c (1).txt").readText())

        val copy = RecordingLink()
        session(folder, copy, FolderReceiveSettings(policy = ConflictPolicy.NEW_FOLDER)).apply {
            sendAll(folder)
            completeFolder(3)
        }
        assertEquals("Photos (1)", copy.last(FolderKinds.ACCEPT)!!.getString("rootName"))
        assertNotNull(File(base, "Photos (1)/2019/c.txt").takeIf { it.isFile })
        val again = RecordingLink()
        session(folder, again, FolderReceiveSettings(policy = ConflictPolicy.NEW_FOLDER))
        assertEquals("Photos (2)", again.last(FolderKinds.ACCEPT)!!.getString("rootName"))
    }

    @Test
    fun aRevokedGrantIsReportedAsUnavailable() {
        context.contentResolver.releasePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertFalse(context.contentResolver.persistedUriPermissions.any { it.uri == treeUri })
        base.deleteRecursively()
        assertFalse(store.reachable())
        try {
            store.children(store.rootId)
            org.junit.Assert.fail("expected the place to be unavailable")
        } catch (error: java.io.IOException) {
            assertEquals(FolderCodes.PLACE_UNAVAILABLE, storageErrorCode(error))
        }
    }
}
