package dev.bridgey.android.folders

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** In-memory nodes for a folder on the phone. */
class MemoryNode(
    override val name: String,
    private val content: ByteArray? = null,
    val kids: MutableList<MemoryNode> = ArrayList(),
) : SendNode {
    var opens = 0
    var unreadable = false
    override val isDirectory: Boolean get() = content == null
    override val size: Long get() = content?.size?.toLong() ?: 0
    override val modifiedMillis: Long? get() = 1_700_000_000_000L
    override val source: String? get() = if (content == null) null else "content://test/$name"
    override fun children(): List<SendNode> = kids
    override fun open(): InputStream {
        if (unreadable) throw java.io.IOException("unreadable")
        opens++
        return ByteArrayInputStream(content!!)
    }

    fun file(name: String, bytes: ByteArray) = MemoryNode(name, bytes).also { kids += it }
    fun dir(name: String) = MemoryNode(name).also { kids += it }
}

/**
 * Runs every message, timer and worker task of both ends one after another on one queue, so the phone's
 * sender and a receiver (the Android receiver standing in for the Mac, or a fake Mac) talk without threads.
 */
class Bridge {
    val queue = ArrayDeque<() -> Unit>()
    var delivered = 0
    var connected = true
    /** Messages the sender sent, by kind. */
    val counts = HashMap<String, Int>()

    fun post(task: () -> Unit) {
        queue.addLast(task)
    }

    fun drain(limit: Int = 2_000_000) {
        var steps = 0
        while (queue.isNotEmpty() && steps++ < limit) queue.removeFirst().invoke()
    }

    inner class Worker : FolderWorker {
        private var stopped = false
        override fun post(task: () -> Unit) {
            if (!stopped) this@Bridge.post { if (!stopped) task() }
        }
        override fun postControl(task: () -> Unit) = post(task)
        override fun shutdown() {
            stopped = true
        }
    }
}

/** The phone's sender wired to the Android receiver (as the Mac), one device "mac-1". */
class SendHarness(journalDir: java.io.File, receiverJournalDir: java.io.File) {
    /** Settings > Files > Include hidden files and Include system files, as the sender reads them. */
    var scanOptions = FolderScanOptions()
    val bridge = Bridge()
    val clock = FakeClock()
    val scheduler = FakeScheduler(clock)
    val snapshots = ArrayList<FolderSnapshot>()
    val finished = ArrayList<FolderSnapshot>()
    val sendJournals = FolderSendJournals(journalDir, clock::read)
    val mac = Phone(receiverJournalDir, FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
    var dropChunkAcksAfter = Int.MAX_VALUE
    private var chunkAcks = 0

    val receiver: FolderReceiver = FolderReceiver(
        places = mac.places,
        settings = { mac.settings },
        journals = mac.journals,
        listener = object : FolderReceiverListener {},
        newWorker = { InlineFolderWorker() },
        scheduler = scheduler,
        runPlaces = { it() },
        clock = clock::read,
    )

    /** The receiver's answers go back to the sender through the bridge. */
    val macLink: FolderLink = object : FolderLink {
        override fun send(kind: String, payload: JSONObject, outerTransferId: String?) {
            val copy = JSONObject(payload.toString())
            bridge.post { if (bridge.connected) sender.handle("mac-1", kind, copy) }
        }

        override fun sendOuter(kind: String, transferId: String, sequence: Long?) {
            if (kind == "files.chunk.ack" && ++chunkAcks > dropChunkAcksAfter) return
            bridge.post { if (bridge.connected) sender.handleOuter("mac-1", kind, transferId, sequence) }
        }
    }

    /** The phone's link: each message lands in the receiver on the bridge. */
    val phoneLink: FolderSendLink = object : FolderSendLink {
        override fun send(kind: String, payload: JSONObject, outerTransferId: String?): Boolean {
            if (!bridge.connected) return false
            bridge.counts.merge(kind, 1, Int::plus)
            val copy = JSONObject(payload.toString())
            bridge.post {
                if (!bridge.connected) return@post
                when (kind) {
                    FolderKinds.OFFER -> receiver.offer("mac-1", "OnePlus 11", macLink, copy)
                    FolderKinds.MANIFEST -> receiver.manifest("mac-1", copy, copy.toString().length)
                    "files.offer" -> receiver.fileOffer("mac-1", copy.getString("transferId"), copy)
                    "files.complete" -> receiver.fileComplete("mac-1", copy.getString("transferId"), copy.getString("sha256"))
                    FolderKinds.COMPLETE -> receiver.complete("mac-1", copy)
                    FolderKinds.CANCEL -> receiver.cancel("mac-1", macLink, copy)
                    FolderKinds.RESOLVE -> receiver.resolve("mac-1", copy)
                }
            }
            return true
        }

        override fun sendChunk(transferId: String, sequence: Long, bytes: ByteArray): Boolean {
            if (!bridge.connected) return false
            bridge.counts.merge("files.chunk", 1, Int::plus)
            bridge.post { if (bridge.connected) receiver.chunk("mac-1", transferId, sequence, bytes) }
            return true
        }

        override fun sendOuter(kind: String, transferId: String): Boolean {
            if (!bridge.connected) return false
            bridge.post { if (bridge.connected && kind == "files.cancel") receiver.fileCancel("mac-1", transferId, macLink) }
            return true
        }
    }

    val sender: FolderSender = FolderSender(
        journals = sendJournals,
        listener = object : FolderSenderListener {
            override fun snapshot(snapshot: FolderSnapshot) {
                snapshots += snapshot
            }

            override fun finished(snapshot: FolderSnapshot) {
                finished += snapshot
            }
        },
        linkFor = { if (bridge.connected) phoneLink else null },
        newWorker = { bridge.Worker() },
        scheduler = scheduler,
        prepare = { it() },
        openUri = { uri -> openers[uri]?.invoke() ?: throw java.io.IOException("no such uri") },
        clock = clock::read,
        scanOptions = { scanOptions },
    )

    /** Journaled sources after a "restart": test URIs to contents. */
    val openers = HashMap<String, () -> InputStream>()

    fun run() = bridge.drain()

    /** Runs until [count] files of [id] are confirmed by the receiver (the sender journal says so). */
    fun runUntilDone(id: String, count: Int) {
        while (bridge.queue.isNotEmpty() && (sendJournals.read(id)?.done?.size ?: 0) < count) bridge.queue.removeFirst().invoke()
    }

    fun disconnect() {
        bridge.connected = false
        sender.deviceGone("mac-1")
        receiver.deviceGone("mac-1")
        bridge.drain()
    }

    fun reconnect() {
        bridge.connected = true
        sender.deviceReady("mac-1")
        bridge.drain()
    }
}

class FolderSendTest {
    @get:Rule val temp = TemporaryFolder()

    private fun harness() = SendHarness(temp.newFolder(), temp.newFolder())

    private fun photos(): MemoryNode = MemoryNode("Photos").apply {
        file("a.jpg", ByteArray(70_000) { it.toByte() })
        dir("2019").apply {
            file("b.txt", "hello".toByteArray())
            dir("Empty")
            file("big.bin", ByteArray(2_000_000) { (it * 31).toByte() })
        }
        file(".DS_Store", ByteArray(4))
        file(".env", ByteArray(4))
        file("A.JPG", ByteArray(5))
    }

    @Test
    fun aFolderFromThePhoneArrivesWholeWithEmptyFoldersAndSkips() {
        val h = harness()
        val id = h.sender.send("mac-1", "MacBook Pro", photos())
        h.run()
        val end = h.finished.single()
        assertEquals(id, end.folderTransferId)
        assertEquals(FolderEnd.COMPLETE, end.end)
        assertTrue(end.outgoing)
        assertFalse(end.download)
        val root = h.mac.pictures
        // "A.JPG" and "a.jpg" clash without case: the later one in UTF-8 order is numbered.
        assertEquals(5, root.find("Photos/A.JPG")!!.content.size)
        assertArrayEquals(ByteArray(70_000) { it.toByte() }, root.find("Photos/a (1).jpg")!!.content)
        assertArrayEquals("hello".toByteArray(), root.find("Photos/2019/b.txt")!!.content)
        assertEquals(2_000_000, root.find("Photos/2019/big.bin")!!.content.size)
        assertNotNull(root.find("Photos/2019/Empty"))
        assertNull(root.find("Photos/.DS_Store"))
        assertNull(root.find("Photos/.env"))
        assertEquals(1, end.skipped.system)
        assertEquals(1, end.skipped.hidden)
        assertEquals(4, end.filesDone)
        // Every chunk went out after the accept; the window never waited forever.
        assertTrue(h.bridge.counts.getValue("files.chunk") >= 2_000_000 / (24 * 1024))
        // The sender journal is gone once the folder ended.
        assertTrue(h.sendJournals.all().isEmpty())
    }

    @Test
    fun hiddenFilesAreSentOnlyWhenTheOptionIsOn() {
        val h = harness()
        h.scanOptions = FolderScanOptions(includeHidden = true)
        h.sender.send("mac-1", "MacBook Pro", photos())
        h.run()
        val end = h.finished.single()
        assertEquals(FolderEnd.COMPLETE, end.end)
        assertEquals(5, end.filesDone)
        // .env is a user dotfile: it comes with the option. .DS_Store is system clutter: it needs its own option.
        assertNotNull(h.mac.pictures.find("Photos/.env"))
        assertNull(h.mac.pictures.find("Photos/.DS_Store"))
        assertEquals(0, end.skipped.hidden)
        assertEquals(1, end.skipped.system)
    }

    @Test
    fun systemFilesAreSentOnlyWhenTheirOptionIsOn() {
        val h = harness()
        h.scanOptions = FolderScanOptions(includeHidden = false, includeSystem = true)
        h.sender.send("mac-1", "MacBook Pro", photos())
        h.run()
        val end = h.finished.single()
        assertEquals(FolderEnd.COMPLETE, end.end)
        assertNotNull(h.mac.pictures.find("Photos/.DS_Store"))
        assertNull(h.mac.pictures.find("Photos/.env"))
        assertEquals(1, end.skipped.hidden)
        assertEquals(0, end.skipped.system)
    }

    @Test
    fun bothOptionsOnSendEverything() {
        val h = harness()
        h.scanOptions = FolderScanOptions(includeHidden = true, includeSystem = true)
        h.sender.send("mac-1", "MacBook Pro", photos())
        h.run()
        val end = h.finished.single()
        assertEquals(6, end.filesDone)
        assertNotNull(h.mac.pictures.find("Photos/.DS_Store"))
        assertNotNull(h.mac.pictures.find("Photos/.env"))
        assertEquals(0, end.skipped.hidden + end.skipped.system)
    }

    @Test
    fun aDownloadFollowsTheSameOptionsInsideFolders() {
        val h = harness()
        fun folder() = MemoryNode("Repo").apply {
            file("readme.md", ByteArray(10))
            file(".gitignore", ByteArray(10))
            file(".DS_Store", ByteArray(10))
        }
        // Off by default, as on the Mac: only the ordinary file.
        assertEquals(1, h.sender.download("mac-1", "MacBook Pro", UUID.randomUUID().toString(), listOf(folder())).fileCount)
        h.scanOptions = FolderScanOptions(includeHidden = true)
        assertEquals(2, h.sender.download("mac-1", "MacBook Pro", UUID.randomUUID().toString(), listOf(folder())).fileCount)
        h.scanOptions = FolderScanOptions(includeHidden = true, includeSystem = true)
        assertEquals(3, h.sender.download("mac-1", "MacBook Pro", UUID.randomUUID().toString(), listOf(folder())).fileCount)
        h.scanOptions = FolderScanOptions(includeHidden = false, includeSystem = true)
        assertEquals(2, h.sender.download("mac-1", "MacBook Pro", UUID.randomUUID().toString(), listOf(folder())).fileCount)
    }

    @Test
    fun foldersQueueOnePerDeviceInOrder() {
        val h = harness()
        val first = h.sender.send("mac-1", "MacBook Pro", MemoryNode("One").apply { file("1.txt", ByteArray(10)) })
        val second = h.sender.send("mac-1", "MacBook Pro", MemoryNode("Two").apply { file("2.txt", ByteArray(10)) })
        h.run()
        assertEquals(listOf(first, second), h.finished.map { it.folderTransferId })
        assertTrue(h.finished.all { it.end == FolderEnd.COMPLETE })
        assertNotNull(h.mac.pictures.find("One/1.txt"))
        assertNotNull(h.mac.pictures.find("Two/2.txt"))
    }

    @Test
    fun aDisconnectResumesSkippingVerifiedFiles() {
        val h = harness()
        val root = MemoryNode("Big").apply { repeat(8) { file("f$it.bin", ByteArray(100_000) { b -> (b + it).toByte() }) } }
        val id = h.sender.send("mac-1", "MacBook Pro", root)
        // Run until three files are confirmed, then cut the connection.
        h.runUntilDone(id, 3)
        h.disconnect()
        val interrupted = h.snapshots.last()
        assertEquals(FolderEnd.INTERRUPTED, interrupted.end)
        assertTrue(interrupted.resumable)
        assertTrue(h.sendJournals.all().single().done.size >= 3)
        val opensBefore = root.kids.sumOf { it.opens }
        h.reconnect()
        val end = h.finished.single()
        assertEquals(FolderEnd.COMPLETE, end.end)
        repeat(8) { assertEquals(100_000, h.mac.pictures.find("Big/f$it.bin")!!.content.size) }
        // Only the files not yet confirmed were read again.
        assertTrue(root.kids.sumOf { it.opens } - opensBefore <= 8 - 3)
        assertNull(h.mac.pictures.find("Big (1)"))
    }

    @Test
    fun aRestartResumesFromTheJournalWithoutHashingAgain() {
        val sendDir = temp.newFolder()
        val macDir = temp.newFolder()
        val first = SendHarness(sendDir, macDir)
        val root = MemoryNode("Docs").apply { repeat(4) { file("d$it.bin", ByteArray(50_000) { b -> (b * it).toByte() }) } }
        val id = first.sender.send("mac-1", "MacBook Pro", root)
        first.runUntilDone(id, 2)
        first.disconnect()
        // The app restarts: a new sender reads its journal; the receiver's journal is in the same folder.
        val second = SendHarness(sendDir, macDir)
        second.mac.pictures.nodes.putAll(first.mac.pictures.nodes)
        root.kids.forEach { node -> second.openers["content://test/${node.name}"] = { node.open() } }
        second.sender.loadJournals()
        assertEquals(FolderEnd.INTERRUPTED, second.snapshots.single().end)
        second.reconnect()
        val end = second.finished.single()
        assertEquals(id, end.folderTransferId)
        assertEquals(FolderEnd.COMPLETE, end.end)
        repeat(4) { assertEquals(50_000, second.mac.pictures.find("Docs/d$it.bin")!!.content.size) }
    }

    @Test
    fun cancelHereEndsTheFolderAndKeepsWhatArrived() {
        val h = harness()
        val root = MemoryNode("Many").apply { repeat(6) { file("m$it.bin", ByteArray(60_000)) } }
        val id = h.sender.send("mac-1", "MacBook Pro", root)
        h.runUntilDone(id, 2)
        assertTrue(h.sender.cancel(id))
        h.run()
        val end = h.finished.single()
        assertEquals(FolderEnd.INCOMPLETE, end.end)
        assertTrue(end.endedHere)
        assertNotNull(h.mac.pictures.find("Many/m0.bin"))
        assertTrue(h.sendJournals.all().isEmpty())
    }

    @Test
    fun aStalledReceiverInterruptsAfterTenSeconds() {
        val h = harness()
        h.dropChunkAcksAfter = 5
        h.sender.send("mac-1", "MacBook Pro", MemoryNode("Slow").apply { file("s.bin", ByteArray(3_000_000)) })
        h.run()
        assertNull(h.finished.singleOrNull())
        h.scheduler.advance(11_000)
        h.run()
        assertEquals(FolderEnd.INTERRUPTED, h.snapshots.last().end)
    }

    @Test
    fun aRejectedOfferEndsWithItsCode() {
        val h = harness()
        h.mac.pictures.free = 10
        h.sender.send("mac-1", "MacBook Pro", MemoryNode("Too big").apply { file("x.bin", ByteArray(1_000)) })
        h.run()
        val end = h.finished.single()
        assertEquals(FolderEnd.CANCELLED, end.end)
        assertEquals(FolderCodes.INSUFFICIENT_SPACE, end.endCode)
    }

    @Test
    fun anUnreadableFileIsSkippedAndCounted() {
        val h = harness()
        val root = MemoryNode("Mixed").apply {
            file("ok.txt", ByteArray(5))
            file("locked.txt", ByteArray(5)).unreadable = true
        }
        h.sender.send("mac-1", "MacBook Pro", root)
        h.run()
        val end = h.finished.single()
        assertEquals(FolderEnd.COMPLETE, end.end)
        assertEquals(1, end.skipped.unreadable)
        assertNull(h.mac.pictures.find("Mixed/locked.txt"))
    }

    @Test
    fun downloadsGoIntoWithTheirRequestIdAndArriveVerified() {
        val bridge = Bridge()
        val clock = FakeClock()
        val scheduler = FakeScheduler(clock)
        val finished = ArrayList<FolderSnapshot>()
        lateinit var sender: FolderSender
        val mac = FakeMac(bridge) { kind, json -> sender.handle("mac-1", kind, json) }
        mac.outer = { kind, id, sequence -> sender.handleOuter("mac-1", kind, id, sequence) }
        sender = FolderSender(
            journals = FolderSendJournals(temp.newFolder(), clock::read),
            listener = object : FolderSenderListener {
                override fun finished(snapshot: FolderSnapshot) {
                    finished += snapshot
                }
            },
            linkFor = { mac },
            newWorker = { bridge.Worker() },
            scheduler = scheduler,
            prepare = { it() },
            openUri = { throw java.io.IOException("none") },
            clock = clock::read,
        )
        val requestId = UUID.randomUUID().toString()
        val folder = MemoryNode("Trip").apply { file("x.jpg", ByteArray(40_000) { (it % 13).toByte() }) }
        val ticket = sender.download("mac-1", "MacBook Pro", requestId, listOf(MemoryNode("one.jpg", ByteArray(10) { 1 }), folder))
        assertEquals(2, ticket.fileCount)
        assertEquals(1, ticket.folderCount)
        assertEquals(40_010, ticket.totalSize)
        assertEquals("one.jpg", ticket.rootName)
        bridge.drain()
        val offer = mac.offer!!
        assertTrue(offer.getBoolean("into"))
        assertEquals(requestId, offer.getString("downloadRequestId"))
        assertEquals(ticket.folderTransferId, offer.getString("folderTransferId"))
        assertTrue(offer.isNull("destination") || !offer.has("destination"))
        assertArrayEquals(ByteArray(10) { 1 }, mac.files["one.jpg"])
        assertArrayEquals(ByteArray(40_000) { (it % 13).toByte() }, mac.files["Trip/x.jpg"])
        val end = finished.single()
        assertEquals(FolderEnd.COMPLETE, end.end)
        assertTrue(end.download)
        assertTrue(end.outgoing)
    }

    @Test
    fun aDownloadOverTheLimitIsRefusedBeforeAnythingIsSent() {
        val h = harness()
        val many = (0..FolderLimits.MAX_FILES).map { MemoryNode("f$it", ByteArray(0)) }
        val refused = runCatching { h.sender.download("mac-1", "MacBook Pro", UUID.randomUUID().toString(), many) }.exceptionOrNull()
        assertEquals(FolderCodes.LIMIT_EXCEEDED, (refused as DownloadRefused).code)
    }

    @Test
    fun scannerAppliesLimitsAndNames() {
        val root = MemoryNode("Trip: Day 1?").apply { file("CON.txt", ByteArray(1)); file("notes.", ByteArray(1)) }
        val scan = FolderScanner.scanFolder(root)
        assertEquals("Trip_ Day 1_", scan.rootName)
        assertEquals(listOf("CON_.txt", "notes"), scan.entries.map { it.path })
        assertNull(scan.problem)
        val many = MemoryNode("Many").apply { repeat(FolderLimits.MAX_FILES + 1) { file("f$it", ByteArray(0)) } }
        assertEquals(FolderCodes.LIMIT_EXCEEDED, FolderScanner.scanFolder(many).problem)
        // Download items keep a picked hidden item; inside folders the options decide, both off by default.
        val items = FolderScanner.scanItems(
            listOf(MemoryNode(".env", ByteArray(1)), MemoryNode("dir").apply { file(".DS_Store", ByteArray(1)); file(".hidden", ByteArray(1)) }),
        )
        assertEquals(listOf(".env", "dir"), items.entries.map { it.path })
        assertTrue(items.into)
        assertEquals(1, items.skipped.system)
        assertEquals(1, items.skipped.hidden)
    }

    @Test
    fun scannerOptionsMirrorTheMacsHiddenAndSystemRules() {
        fun tree() = MemoryNode("Repo").apply {
            file("a.txt", ByteArray(1))
            file(".gitignore", ByteArray(1))
            file(".DS_Store", ByteArray(1))
            file("._a.txt", ByteArray(1))
            file("Thumbs.db", ByteArray(1))
            dir(".config").apply { file("x", ByteArray(1)) }
        }
        val defaults = FolderScanner.scanFolder(tree())
        assertEquals(FolderScanOptions(includeHidden = false, includeSystem = false), FolderScanOptions())
        assertEquals(listOf("a.txt"), defaults.entries.map { it.path })
        // Hidden: .gitignore and .config (a skipped folder takes its files with it); system: .DS_Store, ._ and Thumbs.db.
        assertEquals(2, defaults.skipped.hidden)
        assertEquals(3, defaults.skipped.system)
        val hidden = FolderScanner.scanFolder(tree(), FolderScanOptions(includeHidden = true))
        assertEquals(listOf(".config", ".config/x", ".gitignore", "a.txt"), hidden.entries.map { it.path }.sorted())
        assertEquals(3, hidden.skipped.system)
        val system = FolderScanner.scanFolder(tree(), FolderScanOptions(includeSystem = true))
        assertEquals(listOf(".DS_Store", "._a.txt", "Thumbs.db", "a.txt"), system.entries.map { it.path }.sorted())
        assertEquals(2, system.skipped.hidden)
        val both = FolderScanner.scanFolder(tree(), FolderScanOptions(includeHidden = true, includeSystem = true))
        assertEquals(7, both.entries.size)
        assertEquals(0, both.skipped.hidden + both.skipped.system)
    }
}

/**
 * A Mac that accepts any folder at once, acknowledges every chunk and file, checks each file's SHA-256 and
 * answers folders.result: enough to see a download arrive byte for byte.
 */
class FakeMac(private val bridge: Bridge, private val answer: (String, JSONObject) -> Unit) : FolderSendLink {
    var offer: JSONObject? = null
    var outer: (String, String, Long?) -> Unit = { _, _, _ -> }
    val files = LinkedHashMap<String, ByteArray>()
    private val manifest = ArrayList<ManifestEntry>()
    private var pagesLeft = 0
    private val incoming = HashMap<String, Pair<String, java.io.ByteArrayOutputStream>>()

    override fun send(kind: String, payload: JSONObject, outerTransferId: String?): Boolean {
        val json = JSONObject(payload.toString())
        bridge.post {
            when (kind) {
                FolderKinds.OFFER -> {
                    offer = json
                    pagesLeft = json.getInt("pageCount")
                    if (pagesLeft == 0) accept()
                }
                FolderKinds.MANIFEST -> {
                    ManifestPagePayload.parse(json)!!.entries.forEach { manifest += it }
                    if (--pagesLeft == 0) accept()
                }
                "files.offer" -> incoming[json.getString("transferId")] = json.getString("path") to java.io.ByteArrayOutputStream()
                "files.complete" -> {
                    val (path, data) = incoming.remove(json.getString("transferId"))!!
                    val bytes = data.toByteArray()
                    check(sha(bytes) == manifest.first { it.path == path }.sha256)
                    files[path] = bytes
                    outer("files.complete.ack", json.getString("transferId"), null)
                }
                FolderKinds.COMPLETE -> answer(
                    FolderKinds.RESULT,
                    FolderResultPayload(json.getString("folderTransferId"), true, files.size, files.values.sumOf { it.size.toLong() }, 0, 0, 0, 0, emptyList()).toJson(),
                )
            }
        }
        return true
    }

    private fun accept() {
        val offer = offer!!
        answer(FolderKinds.ACCEPT, FolderAcceptPayload(offer.getString("folderTransferId"), offer.getString("rootName"), "Downloads", ConflictChoice.NONE, null).toJson())
    }

    override fun sendChunk(transferId: String, sequence: Long, bytes: ByteArray): Boolean {
        bridge.post {
            incoming[transferId]?.second?.write(bytes)
            outer("files.chunk.ack", transferId, sequence)
        }
        return true
    }

    override fun sendOuter(kind: String, transferId: String): Boolean = true
}
