package dev.bridgey.android.folders

import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FolderReceiveSessionTest {
    @get:Rule val temp = TemporaryFolder()

    private fun phone(settings: FolderReceiveSettings = FolderReceiveSettings()) = Phone(temp.newFolder(), settings)

    private val photos = TestFolder(
        "Photos",
        mapOf(
            "2019/IMG_0001.jpg" to "one".toByteArray(),
            "2019/IMG_0002.jpg" to "two".toByteArray(),
            "a.txt" to "alpha".toByteArray(),
            "notes/deep/x.md" to "x".toByteArray(),
        ),
        dirs = listOf("2019/Empty", "Empty top"),
    )

    private val toPictures = FolderDestination(Phone.PICTURES, "")

    // Destination modes (3.2).

    @Test
    fun modeAWithDestinationWritesTheWholeTreeIncludingEmptyFolders() {
        val phone = phone()
        phone.pictures.mkdirs("Trip")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, FolderDestination(Phone.PICTURES, "Trip"))
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        val accept = link.last(FolderKinds.ACCEPT)!!
        assertEquals("Photos", accept.getString("rootName"))
        assertEquals("Pictures/Trip", accept.getString("destinationLabel"))
        assertEquals("none", accept.getString("choice"))
        assertTrue(accept.isNull("completedBitmap"))
        assertFalse(link.kinds().contains(FolderKinds.WAITING))
        session.sendAll(photos)
        session.completeFolder(4)
        val result = link.last(FolderKinds.RESULT)!!
        assertEquals("complete", result.getString("status"))
        assertEquals(4, result.getInt("savedFiles"))
        assertEquals(5, result.getInt("createdFolders"))
        assertEquals(
            listOf(
                "Trip/", "Trip/Photos/", "Trip/Photos/2019/", "Trip/Photos/2019/Empty/", "Trip/Photos/2019/IMG_0001.jpg",
                "Trip/Photos/2019/IMG_0002.jpg", "Trip/Photos/Empty top/", "Trip/Photos/a.txt", "Trip/Photos/notes/",
                "Trip/Photos/notes/deep/", "Trip/Photos/notes/deep/x.md",
            ),
            phone.pictures.tree(),
        )
        assertArrayEquals("alpha".toByteArray(), phone.pictures.find("Trip/Photos/a.txt")!!.content)
        assertTrue(phone.pictures.nodes.values.all { it.published })
        assertEquals(FolderEnd.COMPLETE, phone.finished!!.end)
        assertEquals(listOf(FolderDestination(Phone.PICTURES, "Trip")), phone.used)
        assertNull("the journal goes once the folder is complete", phone.journals.read(session.id))
        // Every file was acknowledged like a single file.
        assertEquals(4, link.count("files.accept"))
        assertEquals(4, link.count("files.complete.ack"))
    }

    @Test
    fun foldersAreCreatedBeforeTheFilesInsideThemAndEmptyOnesAtTheEnd() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.sendFile(photos, "2019/IMG_0001.jpg")
        assertNotNull(phone.pictures.find("Photos/2019"))
        assertNotNull("2019/Empty comes before IMG_0001 in manifest order", phone.pictures.find("Photos/2019/Empty"))
        assertNull(phone.pictures.find("Photos/Empty top"))
        session.sendAll(photos, except = setOf("2019/IMG_0001.jpg"))
        session.completeFolder(4)
        assertNotNull(phone.pictures.find("Photos/Empty top"))
    }

    @Test
    fun anEmptyFolderNeedsNoPages() {
        val phone = phone()
        val link = RecordingLink()
        val empty = TestFolder("Nothing", emptyMap())
        val session = phone.session(empty, link, destination = toPictures)
        session.start()
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        session.completeFolder(0)
        assertEquals("complete", link.last(FolderKinds.RESULT)!!.getString("status"))
        assertEquals(listOf("Nothing/"), phone.pictures.tree())
    }

    @Test
    fun modeAWithoutADestinationAsksOnThePhone() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        assertEquals(FolderReceiveSession.Phase.ASK_DESTINATION, session.phase)
        val waiting = link.last(FolderKinds.WAITING)!!
        assertEquals("destination", waiting.getString("reason"))
        assertEquals(180, waiting.getInt("timeoutSeconds"))
        val question = phone.lastQuestion!!
        assertEquals(FolderQuestion.Kind.DESTINATION, question.kind)
        assertEquals(FolderPolicy.AskReason.NO_DESTINATION, question.reason)
        assertEquals(phone.clock.now + 180_000, question.deadlineMillis)
        session.answerDestination(DestinationAnswer(placeId = Phone.PICTURES))
        assertNull("the question is cleared once answered", phone.lastQuestion)
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        assertEquals("Pictures", link.last(FolderKinds.ACCEPT)!!.getString("destinationLabel"))
    }

    @Test
    fun modeBAlwaysAsksEvenWithAnOfferedDestination() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS))
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        assertEquals(FolderReceiveSession.Phase.ASK_DESTINATION, session.phase)
        assertEquals(FolderPolicy.AskReason.MODE, phone.lastQuestion!!.reason)
        session.answerDestination(DestinationAnswer(placeId = DEFAULT_PLACE_ID))
        assertEquals("Download/Bridgey", link.last(FolderKinds.ACCEPT)!!.getString("destinationLabel"))
        assertNotNull(phone.downloads.find("Photos"))
    }

    @Test
    fun modeCSavesToTheDefaultFolderWithoutAsking() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
        val link = RecordingLink()
        val session = phone.deliver(photos, link, FolderDestination(DEFAULT_PLACE_ID, ""))
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        assertTrue(phone.questions.none { it != null })
        assertNotNull("the receiver's default wins over the offered destination", phone.pictures.find("Photos"))
    }

    @Test
    fun modeCWithALostDefaultAsksWithTheReasonAndNeverFallsBackSilently() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
        phone.places.entries.first { it.placeId == Phone.PICTURES }.available = false
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        assertEquals(FolderReceiveSession.Phase.ASK_DESTINATION, session.phase)
        val question = phone.lastQuestion!!
        assertEquals(FolderPolicy.AskReason.DEFAULT_UNAVAILABLE, question.reason)
        assertEquals("Pictures", question.unavailableDefaultLabel)
        assertTrue(phone.downloads.tree().isEmpty())
    }

    @Test
    fun anOfferedPlaceThatIsGoneOrAPathThatDoesNotExistIsRejected() {
        val phone = phone()
        phone.places.entries.first { it.placeId == Phone.PICTURES }.available = false
        val link = RecordingLink()
        phone.deliver(photos, link, toPictures)
        assertEquals("place_unavailable", link.last(FolderKinds.REJECTED)!!.getString("code"))
        assertEquals(FolderEnd.CANCELLED, phone.finished!!.end)
        val other = phone()
        val otherLink = RecordingLink()
        other.deliver(photos, otherLink, FolderDestination(Phone.PICTURES, "Missing"))
        assertEquals("not_found", otherLink.last(FolderKinds.REJECTED)!!.getString("code"))
        assertTrue(other.pictures.tree().isEmpty())
        // Rejections repeat the folder ID outside.
        assertEquals(otherLink.sent.last { it.kind == FolderKinds.REJECTED }.outer, other.finished!!.folderTransferId)
    }

    @Test
    fun notEnoughFreeSpaceIsRejectedWithNeededAndFree() {
        val phone = phone()
        phone.pictures.free = 1_000
        val link = RecordingLink()
        phone.deliver(photos, link, toPictures)
        val rejected = link.last(FolderKinds.REJECTED)!!
        assertEquals("insufficient_space", rejected.getString("code"))
        assertEquals(1_000L, rejected.getLong("freeBytes"))
        assertEquals(photos.entries.sumOf { it.size } + FolderLimits.SPACE_MARGIN, rejected.getLong("neededBytes"))
        assertTrue(phone.pictures.tree().isEmpty())
    }

    @Test
    fun aBadManifestIsRejectedWithTheFirstBadEntry() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.session(photos, link, destination = toPictures)
        session.start()
        val page = photos.pages(session.id).first()
        session.manifestPage(page.copy(entries = page.entries.reversed()), 100)
        val rejected = link.last(FolderKinds.REJECTED)!!
        assertEquals("invalid_manifest", rejected.getString("code"))
        assertEquals(0, rejected.getInt("entry"))
    }

    // Timeouts at each wait.

    @Test
    fun missingManifestPagesTimeOutAfter15Seconds() {
        val phone = phone()
        val link = RecordingLink()
        phone.session(photos, link, destination = toPictures).start()
        phone.scheduler.advance(14_999)
        assertTrue(link.sent.isEmpty())
        phone.scheduler.advance(1)
        assertEquals("timeout", link.last(FolderKinds.REJECTED)!!.getString("code"))
        assertEquals(FolderEnd.CANCELLED, phone.finished!!.end)
    }

    @Test
    fun anUnansweredDestinationQuestionCancelsAfterThreeMinutesWritingNothing() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS))
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        phone.scheduler.advance(179_999)
        assertEquals(FolderReceiveSession.Phase.ASK_DESTINATION, session.phase)
        phone.scheduler.advance(1)
        val cancel = link.last(FolderKinds.CANCEL)!!
        assertEquals("timeout", cancel.getString("reason"))
        assertEquals("timeout", cancel.getString("code"))
        assertEquals(FolderEnd.TIMED_OUT, phone.finished!!.end)
        assertNull(phone.lastQuestion)
        assertTrue(phone.downloads.tree().isEmpty())
        assertTrue(phone.pictures.tree().isEmpty())
        // A late answer does nothing.
        session.answerDestination(DestinationAnswer(placeId = Phone.PICTURES))
        assertTrue(phone.pictures.tree().isEmpty())
    }

    @Test
    fun anUnansweredConflictQuestionOnThePhoneTimesOut() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
        phone.pictures.mkdirs("Photos")
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        assertEquals(FolderReceiveSession.Phase.ASK_CONFLICT_HERE, session.phase)
        assertEquals("conflict", link.last(FolderKinds.WAITING)!!.getString("reason"))
        phone.scheduler.advance(180_000)
        assertEquals("timeout", link.last(FolderKinds.CANCEL)!!.getString("code"))
        assertEquals(listOf("Photos/"), phone.pictures.tree())
    }

    @Test
    fun aConflictAskedOnTheMacIsGivenUpAfterTheSendersOwnLimit() {
        val phone = phone()
        phone.pictures.mkdirs("Photos")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        assertEquals(FolderReceiveSession.Phase.ASK_CONFLICT_ON_SENDER, session.phase)
        phone.scheduler.advance(180_000)
        assertEquals("the Mac counts the 180 seconds itself", FolderReceiveSession.Phase.ASK_CONFLICT_ON_SENDER, session.phase)
        phone.scheduler.advance(15_000)
        assertEquals("timeout", link.last(FolderKinds.CANCEL)!!.getString("code"))
        assertEquals(FolderEnd.TIMED_OUT, phone.finished!!.end)
    }

    // Conflicts (3.3).

    @Test
    fun theMacIsAskedInModeAWithTheClashCountAndMergeKeepsBoth() {
        val phone = phone()
        phone.pictures.put("Photos/a.txt", "old".toByteArray())
        phone.pictures.put("Photos/2019/IMG_0001.jpg", "old".toByteArray())
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        val conflict = link.last(FolderKinds.CONFLICT)!!
        assertEquals("folder", conflict.getString("existing"))
        assertEquals(2, conflict.getInt("clashingFiles"))
        assertEquals("Photos (1)", conflict.getString("newFolderName"))
        assertEquals(listOf("merge", "replace", "new_folder"), (0 until 3).map { conflict.getJSONArray("choices").getString(it) })
        assertEquals(180, conflict.getInt("timeoutSeconds"))
        assertTrue("the phone asks nobody itself", phone.questions.none { it != null })
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.MERGE))
        val accept = link.last(FolderKinds.ACCEPT)!!
        assertEquals("merge", accept.getString("choice"))
        assertEquals("Photos", accept.getString("rootName"))
        session.sendAll(photos)
        session.completeFolder(4)
        assertArrayEquals("old".toByteArray(), phone.pictures.find("Photos/a.txt")!!.content)
        assertArrayEquals("alpha".toByteArray(), phone.pictures.find("Photos/a (1).txt")!!.content)
        assertArrayEquals("one".toByteArray(), phone.pictures.find("Photos/2019/IMG_0001 (1).jpg")!!.content)
        val result = link.last(FolderKinds.RESULT)!!
        assertEquals(2, result.getInt("renamedFiles"))
        assertEquals(0, result.getInt("replacedFiles"))
        assertEquals("complete", result.getString("status"))
    }

    @Test
    fun aResolveThatWasNotOfferedOrComesOutOfStateIsIgnored() {
        val phone = phone()
        phone.pictures.put("Photos", "a file".toByteArray())
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        val conflict = link.last(FolderKinds.CONFLICT)!!
        assertEquals("file", conflict.getString("existing"))
        assertEquals(1, conflict.getJSONArray("choices").length())
        assertEquals("new_folder", conflict.getJSONArray("choices").getString(0))
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.MERGE))
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.REPLACE))
        assertEquals(FolderReceiveSession.Phase.ASK_CONFLICT_ON_SENDER, session.phase)
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.NEW_FOLDER))
        assertEquals("Photos (1)", link.last(FolderKinds.ACCEPT)!!.getString("rootName"))
        assertEquals("new_folder", link.last(FolderKinds.ACCEPT)!!.getString("choice"))
        // Out of state now.
        val sentBefore = link.sent.size
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.NEW_FOLDER))
        assertEquals(sentBefore, link.sent.size)
        // Without a question, a resolve is ignored too.
        val quiet = phone()
        val quietLink = RecordingLink()
        val other = quiet.deliver(photos, quietLink, toPictures)
        quiet.pictures.mkdirs("x")
        other.resolve(FolderResolvePayload(other.id, ConflictChoice.REPLACE))
        assertEquals("none", quietLink.last(FolderKinds.ACCEPT)!!.getString("choice"))
    }

    @Test
    fun aResolveCancelEndsWithNothingWritten() {
        val phone = phone()
        phone.pictures.mkdirs("Photos")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.CANCEL))
        assertEquals("declined", link.last(FolderKinds.CANCEL)!!.getString("code"))
        assertEquals(FolderEnd.CANCELLED, phone.finished!!.end)
        assertEquals(listOf("Photos/"), phone.pictures.tree())
    }

    @Test
    fun anExistingFileTurnsAPresetMergeIntoANewFolder() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES, policy = ConflictPolicy.MERGE))
        phone.pictures.put("Photos", "a file".toByteArray())
        val link = RecordingLink()
        phone.deliver(photos, link)
        val accept = link.last(FolderKinds.ACCEPT)!!
        assertEquals("new_folder", accept.getString("choice"))
        assertEquals("Photos (1)", accept.getString("rootName"))
    }

    @Test
    fun anExistingFileOnlyOffersANewFolderWhenThePhoneAsks() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES))
        phone.pictures.put("photos", "a file".toByteArray())
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        val question = phone.lastQuestion!!
        assertEquals(FolderPolicy.Existing.FILE, question.existing)
        assertEquals(listOf(ConflictChoice.NEW_FOLDER), question.choices)
        assertNull("no clash count for a file", question.clashingFiles)
        session.answerConflict(ConflictChoice.MERGE)
        assertEquals(FolderReceiveSession.Phase.ASK_CONFLICT_HERE, session.phase)
        session.answerConflict(ConflictChoice.NEW_FOLDER)
        assertEquals("Photos (1)", link.last(FolderKinds.ACCEPT)!!.getString("rootName"))
    }

    @Test
    fun aReplaceChosenOnTheMacAsksOnThePhoneWhileTheSwitchIsOff() {
        val phone = phone()
        phone.pictures.put("Photos/a.txt", "old".toByteArray())
        phone.pictures.put("Photos/keep.txt", "keep".toByteArray())
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.REPLACE))
        assertEquals(FolderReceiveSession.Phase.ASK_CONFLICT_HERE, session.phase)
        assertEquals("conflict", link.last(FolderKinds.WAITING)!!.getString("reason"))
        val question = phone.lastQuestion!!
        assertTrue(question.confirmsRemoteReplace)
        assertEquals("Pictures", question.destinationLabel)
        assertEquals(1, question.clashingFiles)
        session.answerConflict(ConflictChoice.REPLACE)
        assertEquals("replace", link.last(FolderKinds.ACCEPT)!!.getString("choice"))
        session.sendAll(photos)
        session.completeFolder(4)
        assertArrayEquals("alpha".toByteArray(), phone.pictures.find("Photos/a.txt")!!.content)
        assertArrayEquals("keep".toByteArray(), phone.pictures.find("Photos/keep.txt")!!.content)
        assertNull(phone.pictures.find("Photos/a (1).txt"))
        assertEquals(1, link.last(FolderKinds.RESULT)!!.getInt("replacedFiles"))
        assertTrue("no part files left", phone.pictures.tree().none { it.endsWith(".bridgey-part") })
    }

    @Test
    fun aReplaceChosenOnTheMacGoesAheadWhenTheSwitchIsOn() {
        val phone = phone(FolderReceiveSettings(allowReplaceFromOtherDevices = true))
        phone.pictures.mkdirs("Photos")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.REPLACE))
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        assertEquals("replace", link.last(FolderKinds.ACCEPT)!!.getString("choice"))
        assertEquals(0, link.count(FolderKinds.WAITING))
    }

    @Test
    fun aConfirmationOfTheMacsReplaceCanStillMergeOrCancel() {
        val phone = phone()
        phone.pictures.mkdirs("Photos")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.resolve(FolderResolvePayload(session.id, ConflictChoice.REPLACE))
        session.cancelHere()
        assertEquals("declined", link.last(FolderKinds.CANCEL)!!.getString("code"))
        assertEquals("user", link.last(FolderKinds.CANCEL)!!.getString("reason"))
        assertEquals(listOf("Photos/"), phone.pictures.tree())
    }

    @Test
    fun presetsApplyWithoutAsking() {
        for ((policy, expected) in listOf(
            ConflictPolicy.MERGE to listOf("Photos/", "Photos/a (1).txt", "Photos/a.txt"),
            ConflictPolicy.REPLACE to listOf("Photos/", "Photos/a.txt"),
            ConflictPolicy.NEW_FOLDER to listOf("Photos (1)/", "Photos (1)/a.txt", "Photos/", "Photos/a.txt"),
        )) {
            val phone = phone(FolderReceiveSettings(mode = DestinationMode.FIXED, defaultPlaceId = Phone.PICTURES, policy = policy))
            phone.pictures.put("Photos/a.txt", "old".toByteArray())
            val folder = TestFolder("Photos", mapOf("a.txt" to "new".toByteArray()))
            val link = RecordingLink()
            val session = phone.deliver(folder, link)
            assertTrue(phone.questions.none { it != null })
            assertEquals(policy.wire, link.last(FolderKinds.ACCEPT)!!.getString("choice"))
            session.sendAll(folder)
            session.completeFolder(1)
            assertEquals(policy.name, expected, phone.pictures.tree())
        }
    }

    @Test
    fun aPresetReplaceOnThePhoneNeedsNoSecondQuestion() {
        val phone = phone(FolderReceiveSettings(policy = ConflictPolicy.REPLACE))
        phone.pictures.mkdirs("Photos")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
        assertEquals("replace", link.last(FolderKinds.ACCEPT)!!.getString("choice"))
    }

    @Test
    fun fileAgainstFolderClashesKeepBothByRenamingTheIncomingItem() {
        val phone = phone(FolderReceiveSettings(policy = ConflictPolicy.REPLACE))
        phone.pictures.put("Photos/2019", "a file called 2019".toByteArray())
        phone.pictures.mkdirs("Photos/a.txt")
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.sendAll(photos)
        session.completeFolder(4)
        val tree = phone.pictures.tree()
        assertTrue(tree.toString(), "Photos/2019" in tree)
        assertTrue("the existing file stays and the folder is renamed", "Photos/2019 (1)/IMG_0001.jpg" in tree)
        assertTrue("the existing folder stays and the file is renamed", "Photos/a.txt/" in tree)
        assertTrue("Photos/a (1).txt" in tree)
    }

    @Test
    fun theConflictQuestionOnThePhoneLeadsToMerge() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS))
        phone.pictures.put("Photos/a.txt", "old".toByteArray())
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        session.answerDestination(DestinationAnswer(placeId = Phone.PICTURES))
        assertEquals(listOf("destination", "conflict"), link.sent.filter { it.kind == FolderKinds.WAITING }.map { it.payload!!.getString("reason") })
        val question = phone.lastQuestion!!
        assertEquals(FolderQuestion.Kind.CONFLICT, question.kind)
        assertEquals(1, question.clashingFiles)
        assertEquals("Photos (1)", question.newFolderName)
        assertFalse(question.confirmsRemoteReplace)
        session.answerConflict(ConflictChoice.MERGE)
        assertEquals("merge", link.last(FolderKinds.ACCEPT)!!.getString("choice"))
    }

    @Test
    fun aSlowClashCountReportsNull() {
        val phone = phone()
        phone.pictures.put("Photos/a.txt", "old".toByteArray())
        phone.pictures.onChildren = { phone.clock.now += 4_000 }
        val link = RecordingLink()
        phone.deliver(photos, link, toPictures)
        assertTrue(link.last(FolderKinds.CONFLICT)!!.isNull("clashingFiles"))
    }

    // Cancel in each state, both sides.

    @Test
    fun cancelOnThePhoneInEachStateWritesWhatTheStateAllows() {
        // While the manifest arrives.
        phone().let { phone ->
            val link = RecordingLink()
            val session = phone.session(photos, link, destination = toPictures)
            session.start()
            session.cancelHere()
            val cancel = link.last(FolderKinds.CANCEL)!!
            assertEquals("user", cancel.getString("reason"))
            assertTrue(cancel.isNull("code"))
            assertEquals(link.sent.last().outer, session.id)
            assertEquals(FolderEnd.CANCELLED, phone.finished!!.end)
            assertTrue(phone.finished!!.endedHere)
        }
        // In the Save to… sheet.
        phone(FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS)).let { phone ->
            val link = RecordingLink()
            val session = phone.deliver(photos, link)
            session.cancelHere()
            assertEquals("declined", link.last(FolderKinds.CANCEL)!!.getString("code"))
            assertNull(phone.lastQuestion)
        }
        // While the Mac is asked.
        phone().let { phone ->
            phone.pictures.mkdirs("Photos")
            val link = RecordingLink()
            val session = phone.deliver(photos, link, toPictures)
            session.cancelHere()
            assertTrue(link.last(FolderKinds.CANCEL)!!.isNull("code"))
            assertEquals(listOf("Photos/"), phone.pictures.tree())
        }
        // While receiving: completed files stay, the file in progress goes, the journal goes.
        phone().let { phone ->
            val link = RecordingLink()
            val session = phone.deliver(photos, link, toPictures)
            session.sendFile(photos, "2019/IMG_0001.jpg")
            session.sendFile(photos, "2019/IMG_0002.jpg", complete = false, chunkSize = 1)
            assertNotNull(phone.journals.read(session.id))
            session.cancelHere()
            assertNotNull(phone.pictures.find("Photos/2019/IMG_0001.jpg"))
            assertNull(phone.pictures.find("Photos/2019/IMG_0002.jpg"))
            assertEquals(FolderEnd.INCOMPLETE, phone.finished!!.end)
            assertNull(phone.journals.read(session.id))
        }
    }

    @Test
    fun cancelFromTheMacInEachStateIsAcknowledgedOutsideTheCiphertext() {
        val states = listOf<(Phone, RecordingLink) -> FolderReceiveSession>(
            { phone, link -> phone.session(photos, link, destination = toPictures).also { it.start() } },
            { phone, link -> phone.settings = FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS); phone.deliver(photos, link) },
            { phone, link -> phone.pictures.mkdirs("Photos"); phone.deliver(photos, link, toPictures) },
            { phone, link -> phone.deliver(photos, link, toPictures).also { it.sendFile(photos, "2019/IMG_0001.jpg"); it.sendFile(photos, "a.txt", complete = false, chunkSize = 1, chunks = 2) } },
        )
        states.forEachIndexed { index, setup ->
            val phone = phone()
            val link = RecordingLink()
            val session = setup(phone, link)
            session.cancelledBySender(FolderCancelPayload(session.id, CancelReasons.USER, null))
            val ack = link.sent.last()
            assertEquals("state $index", FolderKinds.CANCEL_ACK, ack.kind)
            assertNull(ack.payload)
            assertEquals(session.id, ack.outer)
            assertEquals(FolderReceiveSession.Phase.DONE, session.phase)
            assertNull(phone.lastQuestion)
            assertTrue(phone.pictures.tree().none { it.startsWith("Photos/a") || it.contains("bridgey-part") })
            assertEquals(if (index == 3) FolderEnd.INCOMPLETE else FolderEnd.CANCELLED, phone.finished!!.end)
        }
    }

    // Failures.

    @Test
    fun fiftyFailedFilesCancelTheFolder() {
        val phone = phone()
        val files = (0 until 60).associate { "f%02d.txt".format(it) to "x$it".toByteArray() }
        val folder = TestFolder("Many", files)
        files.keys.forEach { phone.pictures.failCreate += it }
        val link = RecordingLink()
        val session = phone.deliver(folder, link, toPictures)
        session.sendAll(folder)
        assertEquals(50, link.count(FolderKinds.ENTRY_FAILED))
        assertEquals("io_error", link.last(FolderKinds.ENTRY_FAILED)!!.getString("code"))
        val cancel = link.last(FolderKinds.CANCEL)!!
        assertEquals("error", cancel.getString("reason"))
        assertEquals("too_many_failures", cancel.getString("code"))
        assertEquals(FolderEnd.INCOMPLETE, phone.finished!!.end)
    }

    @Test
    fun aFileThatFailsVerificationIsDeletedAndTheFolderGoesOn() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        val bad = session.sendFile(photos, "2019/IMG_0001.jpg", corrupt = true)
        val failed = link.last(FolderKinds.ENTRY_FAILED)!!
        assertEquals("verification_failed", failed.getString("code"))
        assertEquals(bad, failed.getString("transferId"))
        assertEquals(photos.index("2019/IMG_0001.jpg"), failed.getInt("entry"))
        assertNull(phone.pictures.find("Photos/2019/IMG_0001.jpg"))
        session.sendAll(photos, except = setOf("2019/IMG_0001.jpg"))
        session.completeFolder(4)
        val result = link.last(FolderKinds.RESULT)!!
        assertEquals("incomplete", result.getString("status"))
        assertEquals(1, result.getInt("failedCount"))
        assertEquals("verification_failed", result.getJSONArray("failed").getJSONObject(0).getString("code"))
        assertEquals(FolderEnd.INCOMPLETE, phone.finished!!.end)
    }

    @Test
    fun senderFailuresAreAddedToTheResult() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.sendAll(photos, except = setOf("a.txt"))
        session.completeFolder(3, listOf(FailedEntry(photos.index("a.txt"), "source_changed")))
        val result = link.last(FolderKinds.RESULT)!!
        assertEquals("incomplete", result.getString("status"))
        assertEquals(1, result.getInt("failedCount"))
        assertEquals("source_changed", result.getJSONArray("failed").getJSONObject(0).getString("code"))
    }

    @Test
    fun aRevokedPlaceStopsTheFolderAndKeepsWhatCompleted() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.sendFile(photos, "2019/IMG_0001.jpg")
        val inProgress = session.sendFile(photos, "2019/IMG_0002.jpg", complete = false, chunks = 0)
        phone.pictures.revoked = true
        session.chunk(inProgress, 0, "two".toByteArray())
        val cancel = link.last(FolderKinds.CANCEL)!!
        assertEquals("place_unavailable", cancel.getString("code"))
        assertEquals(listOf("Pictures"), phone.lostAccess)
        phone.pictures.revoked = false
        assertNotNull(phone.pictures.find("Photos/2019/IMG_0001.jpg"))
        assertEquals(FolderEnd.INCOMPLETE, phone.finished!!.end)
    }

    @Test
    fun aFileCancelledByTheMacIsDeletedAndAcknowledged() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        val id = session.sendFile(photos, "a.txt", complete = false, chunkSize = 1, chunks = 2)
        session.fileCancelled(id)
        assertEquals("files.cancel.ack", link.sent.last().kind)
        assertNull(phone.pictures.find("Photos/a.txt"))
        assertEquals(FolderReceiveSession.Phase.RECEIVING, session.phase)
    }

    // Entry validation (4.6).

    @Test
    fun filesThatDoNotMatchTheManifestFailAsInvalidAndTheirChunksAreDropped() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        val content = "alpha".toByteArray()
        val index = photos.index("a.txt")
        fun offer(fields: FolderFileFields, name: String = "a.txt", size: Long = content.size.toLong(), hash: String = sha(content)): String {
            val transferId = UUID.randomUUID().toString()
            session.claim(transferId)
            session.fileOffer(transferId, fields, name, size, hash)
            session.chunk(transferId, 0, content)
            session.fileComplete(transferId, hash)
            return transferId
        }
        val traversal = offer(FolderFileFields(session.id, index, "../a.txt"))
        offer(FolderFileFields(session.id, index, "a.txt"), size = 4)
        offer(FolderFileFields(session.id, index, "a.txt"), hash = sha("other".toByteArray()))
        offer(FolderFileFields(session.id, index, "a.txt"), name = "b.txt")
        offer(FolderFileFields(session.id, photos.index("2019"), "2019"))
        offer(FolderFileFields(session.id, 99, "a.txt"))
        val failures = link.sent.filter { it.kind == FolderKinds.ENTRY_FAILED }.map { it.payload!! }
        assertEquals(6, failures.size)
        assertTrue(failures.all { it.getString("code") == "invalid_message" })
        assertEquals(traversal, failures.first().getString("transferId"))
        assertEquals("no chunk of a refused file is acknowledged", 0, link.count("files.chunk.ack"))
        assertEquals(0, link.count("files.accept"))
        assertTrue(phone.pictures.tree().none { it.endsWith("a.txt") })
        // A good offer, then the same entry again: entries must strictly increase.
        session.sendFile(photos, "a.txt")
        assertNotNull(phone.pictures.find("Photos/a.txt"))
        session.sendFile(photos, "a.txt")
        assertEquals("invalid_message", link.last(FolderKinds.ENTRY_FAILED)!!.getString("code"))
        assertNull(phone.pictures.find("Photos/a (1).txt"))
        session.sendFile(photos, "2019/IMG_0001.jpg")
        assertNull("an earlier entry after a later one is refused", phone.pictures.find("Photos/2019/IMG_0001.jpg"))
    }

    @Test
    fun largeFilesAreWrittenAsHiddenPartFilesAndRenamedAfterVerification() {
        val phone = phone()
        val big = ByteArray(1_100_000) { (it % 251).toByte() }
        val folder = TestFolder("Big", mapOf("movie.mov" to big, "small.txt" to "s".toByteArray()))
        val link = RecordingLink()
        val session = phone.deliver(folder, link, toPictures)
        session.sendFile(folder, "movie.mov", complete = false)
        assertNotNull(phone.pictures.find("Big/.movie.mov.bridgey-part"))
        assertNull(phone.pictures.find("Big/movie.mov"))
        session.fileComplete(link.sent.last { it.kind == "files.accept" }.outer!!, sha(big))
        assertNull(phone.pictures.find("Big/.movie.mov.bridgey-part"))
        assertArrayEquals(big, phone.pictures.find("Big/movie.mov")!!.content)
        session.sendFile(folder, "small.txt", complete = false)
        assertNotNull("small files go straight to their final name", phone.pictures.find("Big/small.txt"))
    }

    @Test
    fun progressCountsFilesAndBytesAndKeepsTheLastNames() {
        val phone = phone()
        val link = RecordingLink()
        val session = phone.deliver(photos, link, toPictures)
        session.sendFile(photos, "2019/IMG_0001.jpg")
        session.sendFile(photos, "2019/IMG_0002.jpg")
        session.sendFile(photos, "a.txt", complete = false, chunks = 0)
        val snapshot = phone.snapshots.last()
        assertEquals(2, snapshot.filesDone)
        assertEquals(4, snapshot.filesTotal)
        assertEquals(6L, snapshot.bytesDone)
        assertEquals("a.txt", snapshot.currentFile)
        assertEquals(listOf("IMG_0001.jpg", "IMG_0002.jpg"), snapshot.recent)
        assertEquals("Pictures", snapshot.destinationLabel)
        assertEquals(ConflictChoice.NONE, snapshot.choice)
        assertNull(snapshot.waiting)
    }

    // Resume (4.7, 6.6).

    @Test
    fun aDisconnectKeepsTheJournalAndAResumeContinuesWithTheBitmap() {
        val phone = phone()
        val id = UUID.randomUUID().toString()
        val link = RecordingLink()
        val first = phone.deliver(photos, link, toPictures, id = id)
        first.sendFile(photos, "2019/IMG_0001.jpg")
        first.sendFile(photos, "2019/IMG_0002.jpg")
        first.sendFile(photos, "a.txt", complete = false, chunkSize = 1, chunks = 2)
        first.interrupt()
        assertEquals(FolderEnd.INTERRUPTED, phone.finished!!.end)
        assertTrue(phone.finished!!.resumable)
        assertNull("the cut-off file restarts", phone.pictures.find("Photos/a.txt"))
        assertNotNull(phone.journals.read(id))

        // The Mac reconnects within the window and resumes; nobody is asked again.
        phone.clock.now += 60 * 60 * 1000L
        phone.pictures.mkdirs("Noise")
        val again = RecordingLink()
        val second = phone.deliver(photos, again, FolderDestination(Phone.PICTURES, "Noise"), id = id, resume = true)
        val accept = again.last(FolderKinds.ACCEPT)!!
        assertEquals("Photos", accept.getString("rootName"))
        assertEquals("Pictures", accept.getString("destinationLabel"))
        assertEquals("none", accept.getString("choice"))
        val done = CompletedBitmap.decode(accept.getString("completedBitmap"), photos.entries.size)!!
        val expected = setOf(
            photos.index("2019"), photos.index("2019/Empty"), photos.index("2019/IMG_0001.jpg"), photos.index("2019/IMG_0002.jpg"),
            // Created before a.txt, which was cut off.
            photos.index("Empty top"),
        )
        assertEquals(expected, done)
        assertTrue(phone.questions.none { it != null })
        second.sendFile(photos, "a.txt")
        second.sendFile(photos, "notes/deep/x.md")
        second.completeFolder(2)
        val result = again.last(FolderKinds.RESULT)!!
        assertEquals("complete", result.getString("status"))
        assertEquals(4, result.getInt("savedFiles"))
        assertNull(phone.pictures.find("Photos (1)"))
        assertNull(phone.pictures.find("Noise/Photos"))
        assertArrayEquals("alpha".toByteArray(), phone.pictures.find("Photos/a.txt")!!.content)
    }

    @Test
    fun aResumeIsRefusedForAnotherDeviceAnotherManifestOrAStaleJournal() {
        val phone = phone()
        val id = UUID.randomUUID().toString()
        phone.deliver(photos, RecordingLink(), toPictures, id = id).let {
            it.sendFile(photos, "2019/IMG_0001.jpg")
            it.interrupt()
        }
        val otherPeer = RecordingLink()
        phone.deliver(photos, otherPeer, toPictures, id = id, resume = true, peer = "mac-2")
        assertEquals("resume_unavailable", otherPeer.last(FolderKinds.REJECTED)!!.getString("code"))
        val changed = TestFolder("Photos", photos.contents + ("new.txt" to "n".toByteArray()))
        val otherManifest = RecordingLink()
        phone.deliver(changed, otherManifest, toPictures, id = id, resume = true)
        assertEquals("resume_unavailable", otherManifest.last(FolderKinds.REJECTED)!!.getString("code"))
        phone.clock.now += FolderTimeouts.RESUME_WINDOW_MILLIS
        val stale = RecordingLink()
        phone.deliver(photos, stale, toPictures, id = id, resume = true)
        assertEquals("resume_unavailable", stale.last(FolderKinds.REJECTED)!!.getString("code"))
        val unknown = RecordingLink()
        phone.deliver(photos, unknown, toPictures, resume = true)
        assertEquals("resume_unavailable", unknown.last(FolderKinds.REJECTED)!!.getString("code"))
    }

    @Test
    fun aUserCancelDeletesTheJournal() {
        val phone = phone()
        val session = phone.deliver(photos, RecordingLink(), toPictures)
        session.sendFile(photos, "2019/IMG_0001.jpg")
        session.cancelHere()
        assertNull(phone.journals.read(session.id))
        val again = RecordingLink()
        phone.deliver(photos, again, toPictures, id = session.id, resume = true)
        assertEquals("resume_unavailable", again.last(FolderKinds.REJECTED)!!.getString("code"))
    }

    @Test
    fun aOneOffFolderIsReleasedAfterTheTransferButKeptWhileItCanResume() {
        val phone = phone(FolderReceiveSettings(mode = DestinationMode.RECEIVER_ASKS))
        val tree = "content://tree/once"
        phone.places.oneOffs[tree] = MemoryTreeStore()
        val link = RecordingLink()
        val session = phone.deliver(photos, link)
        session.answerDestination(DestinationAnswer(oneOffTree = tree))
        assertTrue("a one-off folder is not a recent destination", phone.used.isEmpty())
        session.sendFile(photos, "a.txt")
        session.interrupt()
        assertTrue(phone.released.isEmpty())
        val again = phone.deliver(photos, RecordingLink(), id = session.id, resume = true)
        again.sendAll(photos, except = setOf("a.txt"))
        again.completeFolder(3)
        assertEquals(listOf(tree), phone.released)
        assertNotNull(phone.places.oneOffs[tree]!!.find("Photos/a.txt"))
    }
}
