package dev.bridgey.android.ui.attach

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Recreate the draft owner from serialized storage while the provider's grants live independently. */
class AttachDraftTest {
    private val a = "content://documents/a.pdf"
    private val b = "content://documents/b.pdf"
    private val tree = "content://documents/tree/photos"

    private class Memory : AttachDraftPersistence {
        var encoded: String? = null
        override fun read(): String? = encoded
        override fun write(value: String) { encoded = value }
    }
    private class Grants : AttachDraftReadGrants {
        val reads = mutableSetOf<String>()
        val denied = mutableSetOf<String>()
        val others = mutableSetOf<String>()
        val retained = mutableListOf<String>()
        val released = mutableListOf<String>()
        override fun hasRead(uri: String) = uri in reads
        override fun retainRead(uri: String): Boolean {
            retained += uri
            return (uri !in denied).also { if (it) reads += uri }
        }
        override fun releaseRead(uri: String): Boolean { released += uri; reads -= uri; return true }
        override fun hasOtherOwner(uri: String) = uri in others
    }

    private fun admittedFile(store: AttachDraftStore, uri: String, id: String): Boolean {
        assertTrue(store.reserveFiles(listOf(uri to id)))
        return store.fileQueued(uri, id)
    }
    private fun admittedFolder(store: AttachDraftStore, uri: String, id: String): Boolean {
        assertTrue(store.reserveFolder(uri, id))
        return store.folderQueued(uri, id)
    }

    @Test fun browseFilesAndFolderSurviveSerializedProcessRecreationWithoutSending() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "process-a")
        assertTrue(before.open("chosen-mac"))
        assertTrue(before.addFiles(listOf(a, b)))
        assertTrue(before.addFolder(tree))
        val encoded = memory.encoded
        assertNotNull(encoded)
        val after = AttachDraftStore(memory, grants, "process-b")
        assertEquals(listOf(a, b), after.value.files)
        assertEquals(tree, after.value.folder)
        assertEquals("chosen-mac", after.value.targetId)
        assertTrue(after.value.visible)
        assertTrue(after.pendingAccessAvailable())
        assertFalse(after.value.submitting)
        assertTrue(after.value.fileLeases.isEmpty())
        assertTrue(grants.released.isEmpty())
        assertTrue(memory.encoded!!.toByteArray().size <= AttachDraftCodec.MAX_BYTES)
        assertEquals(listOf(a, b, tree), grants.retained)
    }

    @Test fun recreationDuringSecondPickerRetainsEarlierSelectionAndExplicitTarget() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "same-process")
        before.open("mac-a"); before.addFiles(listOf(a)); before.select(listOf("m:42"))
        // Owner is recreated while another Activity owns the system document picker.
        val after = AttachDraftStore(memory, grants, "same-process")
        assertTrue(after.addFiles(listOf(b, a)))
        assertEquals(listOf(a, b), after.value.files)
        assertEquals(listOf("m:42"), after.value.selection)
        assertEquals("mac-a", after.value.targetId)
        assertTrue(after.value.visible)
        assertTrue(after.value.fileLeases.isEmpty())
    }

    @Test fun dismissAndReopenPreserveDraftButExplicitCancelClearsIt() {
        val memory = Memory(); val grants = Grants()
        grants.reads += b // A grant owned by another existing feature before this draft.
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a, b)); store.addFolder(tree)
        assertTrue(store.dismiss())
        assertFalse(store.value.visible)
        assertTrue(store.open("mac-b"))
        assertEquals("mac-a", store.value.targetId)
        assertEquals(listOf(a, b), store.value.files)
        assertEquals(tree, store.value.folder)
        assertTrue(store.cancel())
        assertFalse(store.value.hasContent)
        assertNull(store.value.targetId)
        assertEquals(setOf(a, tree), grants.released.toSet())
        assertEquals(setOf(b), grants.reads)
        assertFalse(AttachDraftStore(memory, grants, "p").value.hasContent)
    }

    @Test fun failedNewProviderGrantKeepsPriorDraftAndRollsBackOnlyNewGrants() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a))
        val before = memory.encoded
        grants.denied += tree
        assertFalse(store.addFiles(listOf(b, tree)))
        assertEquals(before, memory.encoded)
        assertEquals(listOf(a), store.value.files)
        assertEquals(listOf(b), grants.released)
        assertEquals(setOf(a), grants.reads)
        assertEquals("mac-a", store.value.targetId)
    }

    @Test fun revokedPendingAccessNeverDiscardsTheDraftOrPretendsItCanSend() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); grants.reads -= a
        val after = AttachDraftStore(memory, grants, "new-process")
        assertFalse(after.pendingAccessAvailable())
        assertEquals(listOf(a), after.value.files)
        // A fresh explicit Browse result reacquires the grant without duplicating or sending it.
        assertTrue(after.addFiles(listOf(a)))
        assertTrue(after.pendingAccessAvailable())
        assertTrue(after.value.fileLeases.isEmpty())
    }

    @Test fun onlyAcceptedFilesLeaveDraftAndGrantLivesThroughRetryableQueueState() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a, b)); store.beginSubmission()
        assertTrue(admittedFile(store, a, "transfer-a")) // b's dispatch failed: there is no accepted ID.
        assertTrue(store.submissionFinished())
        assertEquals(listOf(b), store.value.files)
        assertEquals("mac-a", store.value.targetId)
        assertTrue(store.value.visible)
        store.transferStates(emptySet()) // Queued, active, missing and retryable transfers are not terminal proof.
        assertTrue(a in grants.reads)
        assertTrue(store.cancel())
        assertEquals(listOf(b), grants.released)
        store.transferStates(setOf("transfer-a")) // Known finished and nonretryable.
        assertEquals(setOf(a, b), grants.released.toSet())
        assertTrue(store.value.ownedReads.isEmpty())
    }

    @Test fun acceptedFolderRetainsReadGrantUntilKnownNonretryableCompletion() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFolder(tree); store.beginSubmission()
        assertTrue(admittedFolder(store, tree, "folder-tree"))
        store.submissionFinished(); store.cancel(); store.transferStates(emptySet())
        assertFalse(store.value.hasContent)
        assertTrue(tree in grants.reads)
        assertTrue(grants.released.isEmpty())
        assertTrue(tree in store.value.ownedReads)
        assertEquals(setOf("folder-tree"), store.value.folderLeases[tree])
        store.transferStates(setOf("folder-tree"))
        assertEquals(listOf(tree), grants.released)
    }

    @Test fun cancelledDraftCannotRevokeGrantAnotherPlaceOrFileStillOwns() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); grants.others += a
        store.cancel()
        assertTrue(grants.released.isEmpty())
        assertTrue(a in store.value.ownedReads)
        grants.others -= a
        store.transferStates(emptySet())
        assertEquals(listOf(a), grants.released)
    }

    @Test fun configurationRecreationKeepsSubmissionPendingAndCannotDuplicateSend() {
        val memory = Memory(); val grants = Grants()
        val core = AttachDraftStore(memory, grants, "p")
        core.open("mac-a"); core.addFolder(tree); core.beginSubmission()
        assertTrue(core.reserveFolder(tree, "folder-tree"))
        // A recreated UI aliases the application's same controller; it cannot clear its admission receipts.
        val recreatedUi = core
        assertTrue(recreatedUi.value.submitting)
        assertFalse(recreatedUi.beginSubmission())
        assertFalse(recreatedUi.target("mac-b"))
        assertFalse(recreatedUi.cancel())
        recreatedUi.dismiss()
        assertTrue(core.folderQueued(tree, "folder-tree"))
        assertTrue(core.submissionFinished())
        assertFalse(recreatedUi.value.hasContent)
        assertFalse(recreatedUi.value.visible)
        assertFalse(recreatedUi.value.submitting)
    }

    @Test fun processRestartUnblocksUnacceptedFolderButDoesNotReleaseItsReadGrant() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "old")
        before.open("mac-a"); before.addFolder(tree); before.beginSubmission()
        val after = AttachDraftStore(memory, grants, "new")
        assertFalse(after.value.submitting)
        assertEquals(tree, after.value.folder)
        assertEquals("mac-a", after.value.targetId)
        assertTrue(after.pendingAccessAvailable())
        assertTrue(grants.released.isEmpty())
    }

    @Test fun fileLeaseCleanupAfterProcessDeathPreservesUnsentAndOtherOwnedUris() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "old")
        before.open("mac-a"); before.addFiles(listOf(a, b)); before.beginSubmission()
        admittedFile(before, a, "old-file-queue"); before.submissionFinished()
        val after = AttachDraftStore(memory, grants, "new")
        assertEquals(listOf(b), after.value.files)
        assertEquals(setOf(b), grants.reads)
        assertEquals(listOf(a), grants.released)
        assertTrue(after.pendingAccessAvailable())
    }

    @Test fun coreFolderFinishHandsBorrowedGrantToWaitingDraftThenCancelReleasesIt() {
        val memory = Memory(); val grants = Grants()
        grants.reads += tree // Held by an older core folder send before this new Browse result.
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFolder(tree); store.dismiss()
        assertFalse(tree in store.value.ownedReads)
        assertTrue(store.adoptReleasedRead(tree)) // Core must skip its release after this ownership handoff.
        assertTrue(tree in store.value.ownedReads)
        assertTrue(store.pendingAccessAvailable())
        val after = AttachDraftStore(memory, grants, "next-process")
        assertEquals(tree, after.value.folder)
        assertTrue(after.pendingAccessAvailable())
        assertTrue(after.cancel())
        assertEquals(listOf(tree), grants.released)
    }

    @Test fun coreGrantHandoffAlsoProtectsBorrowedFileLeaseAndRespectsOtherOwners() {
        val memory = Memory(); val grants = Grants()
        grants.reads += a
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        admittedFile(store, a, "file-a"); store.submissionFinished()
        assertFalse(a in store.value.ownedReads)
        assertTrue(store.adoptReleasedRead(a))
        grants.others += a
        store.transferStates(setOf("file-a"))
        assertTrue(grants.released.isEmpty())
        grants.others -= a
        store.transferStates(emptySet())
        assertEquals(listOf(a), grants.released)
        assertFalse(store.adoptReleasedRead(tree))
    }

    @Test fun fastCoreFolderReleaseBeforeQueueCallbackCannotLoseGrantCleanupOwnership() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFolder(tree); store.beginSubmission()
        assertTrue(store.reserveFolder(tree, "already-ended-folder"))
        assertTrue(store.adoptReleasedRead(tree))
        store.transferStates(setOf("already-ended-folder"))
        assertTrue(store.value.folderLeases.isEmpty())
        assertTrue(tree in store.value.ownedReads) // Pending URI still protects the read until its ACK.
        assertFalse(store.submissionFinished())
        assertTrue(store.folderQueued(tree, "already-ended-folder"))
        assertTrue(store.submissionFinished())
        assertTrue(store.value.folderLeases.isEmpty()) // Acknowledgement never recreates a terminal lease.
        assertEquals(listOf(tree), grants.released)
        store.transferStates(setOf("already-ended-folder"))
        assertEquals(listOf(tree), grants.released)
    }

    @Test fun acceptedFolderReadLeaseSurvivesProcessRestartForItsDurableCoreJournal() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "old")
        before.open("mac-a"); before.addFolder(tree); before.beginSubmission()
        admittedFolder(before, tree, "durable-folder"); before.submissionFinished()
        val after = AttachDraftStore(memory, grants, "new")
        assertFalse(after.value.hasContent)
        assertEquals(setOf("durable-folder"), after.value.folderLeases[tree])
        assertTrue(tree in grants.reads)
        assertTrue(grants.released.isEmpty())
        after.transferStates(setOf("durable-folder"))
        assertEquals(listOf(tree), grants.released)
    }

    private fun ids(count: Int): Set<String> = (0 until count).map {
        "00000000-0000-0000-0000-" + it.toString().padStart(12, '0')
    }.toSet()

    private fun seeded(memory: Memory, grants: Grants, value: AttachDraft, process: String = "p", deferCleanup: Boolean = false): AttachDraftStore {
        memory.encoded = requireNotNull(AttachDraftCodec.encode(value))
        grants.reads += value.ownedReads
        return AttachDraftStore(memory, grants, process, deferCleanup)
    }

    @Test fun saturatedRepeatedFileUriRejectsWholeSubmissionBeforeAnyQueueSideEffect() {
        val memory = Memory(); val grants = Grants()
        val store = seeded(memory, grants, AttachDraft(visible = true, targetId = "mac-a", files = listOf(a),
            ownedReads = setOf(a), fileLeases = mapOf(a to ids(256)), leaseProcess = "p"))
        val before = memory.encoded
        var queues = 0
        if (store.beginSubmission()) {
            if (store.reserveFiles(listOf(a to "new-file"))) queues++
        }
        assertEquals(0, queues)
        assertEquals(before, memory.encoded)
        assertFalse(store.value.submitting)
        assertEquals(listOf(a), store.value.files)
        assertEquals(256, store.value.fileLeases.getValue(a).size)
    }

    @Test fun ordinaryMediaAccessDoesNotConsumePersistedBrowseGrantLeaseCapacity() {
        val memory = Memory(); val grants = Grants()
        val key = AttachKeys.MEDIA + "42"
        val media = "content://media/external/images/media/42"
        val store = seeded(memory, grants, AttachDraft(visible = true, targetId = "mac-a", selection = listOf(key),
            ownedReads = setOf(a), fileLeases = mapOf(a to ids(256)), leaseProcess = "p"))
        assertTrue(store.beginSubmission(fileUris = listOf(media), treeUris = emptyList()))
        assertTrue(store.reserveFiles(listOf(media to "media-transfer")))
        assertTrue(store.fileQueued(media, "media-transfer", setOf(key)))
        assertTrue(store.submissionFinished())
        assertFalse(media in store.value.fileLeases)
        assertFalse(media in store.value.ownedReads)
        assertEquals(256, store.value.fileLeases.getValue(a).size)
    }

    @Test fun aCoreReleaseDuringRecoveryKeepsCleanupEvidenceAcrossProcessDeath() {
        val memory = Memory(); val grants = Grants()
        grants.reads += tree
        val recovering = AttachDraftStore(memory, grants, "one", deferCleanup = true)
        assertTrue(recovering.deferCoreReadRelease(tree))
        assertTrue(tree in recovering.value.ownedReads)
        val restarted = AttachDraftStore(memory, grants, "two", deferCleanup = true)
        assertTrue(tree in grants.reads)
        grants.others += tree // A genuine legacy folder owner appears only after journal recovery.
        restarted.reconcileFolderOwners(emptySet())
        assertTrue(tree in grants.reads)
        grants.others -= tree
        restarted.reconcileFolderOwners(emptySet())
        assertEquals(listOf(tree), grants.released)
    }

    @Test fun saturatedRepeatedTreeUriRejectsFolderBeforeAnyQueueSideEffect() {
        val memory = Memory(); val grants = Grants()
        val store = seeded(memory, grants, AttachDraft(visible = true, targetId = "mac-a", folder = tree,
            ownedReads = setOf(tree), folderLeases = mapOf(tree to ids(256)), leaseProcess = "p"))
        var queues = 0
        if (store.beginSubmission(emptyList(), listOf(tree))) {
            if (store.reserveFolder(tree, "new-folder")) queues++
        }
        assertEquals(0, queues)
        assertEquals(tree, store.value.folder)
        assertFalse(store.value.submitting)
    }

    @Test fun mixedSubmissionReservesEveryFileAndTreeSlotBeforeItsFirstItem() {
        val memory = Memory(); val grants = Grants()
        val store = seeded(memory, grants, AttachDraft(visible = true, targetId = "mac-a", files = listOf(a), folder = tree,
            ownedReads = setOf(a, tree), fileLeases = mapOf(a to ids(255)), leaseProcess = "p"))
        assertFalse(store.beginSubmission(listOf(a), listOf(tree))) // Each alone could fit, both cannot.
        assertFalse(store.reserveFiles(listOf(a to "must-not-start")))
        assertEquals(listOf(a), store.value.files)
        assertEquals(tree, store.value.folder)
    }

    @Test fun reservationRechecksFullCapacityBeforeFilesOrFoldersCanBeCreated() {
        for (folder in listOf(false, true)) {
            val memory = Memory(); val grants = Grants()
            val original = AttachDraft(visible = true, targetId = "mac-a", files = if (folder) emptyList() else listOf(a),
                folder = if (folder) a else null, ownedReads = setOf(a), fileLeases = mapOf(a to ids(255)), leaseProcess = "p")
            val store = seeded(memory, grants, original)
            assertTrue(store.beginSubmission(if (folder) emptyList() else listOf(a), if (folder) listOf(a) else emptyList()))
            // Another authoritative ownership change fills the last slot while this submission waits.
            memory.encoded = requireNotNull(AttachDraftCodec.encode(store.value.copy(fileLeases = mapOf(a to ids(256)))))
            store.reload()
            var queued = 0
            val admitted = if (folder) store.reserveFolder(a, "after-capacity-change") else store.reserveFiles(listOf(a to "after-capacity-change"))
            if (admitted) queued++
            assertFalse(admitted)
            assertEquals(0, queued)
            assertTrue(store.submissionFinished()) // Nothing was accepted, so the pending item may be tried later.
            assertTrue(store.value.hasContent)
        }
    }

    @Test fun bytePreflightIncludesLongUriPotentialOwnershipAnd128CharacterIds() {
        val memory = Memory(); val grants = Grants()
        val longUri = "content://documents/" + "q".repeat(4000)
        val longIds = (0 until 170).map { ("history-" + it).padEnd(128, 'x') }.toSet()
        val store = seeded(memory, grants, AttachDraft(visible = true, targetId = "mac-a", files = listOf(longUri),
            ownedReads = setOf(a, longUri), fileLeases = mapOf(a to longIds), leaseProcess = "p"))
        assertTrue(memory.encoded!!.toByteArray().size <= AttachDraftCodec.MAX_BYTES)
        assertFalse(store.beginSubmission(listOf(longUri), emptyList()))
        assertFalse(store.value.submitting)
        assertTrue(grants.released.isEmpty())
    }

    @Test fun atomicFileReservationLeavesNoAcceptedItemPresentedAsUnsent() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a, b))
        assertTrue(store.beginSubmission(listOf(a, b), emptyList()))
        var queued = 0
        assertTrue(store.reserveFiles(listOf(a to "file-a", b to "file-b")))
        queued += 2 // Core side effects happen only after the successful admission record.
        assertEquals(listOf(a, b), store.value.files)
        assertTrue(store.fileQueued(a, "file-a"))
        assertTrue(store.fileQueued(b, "file-b"))
        assertTrue(store.fileQueued(b, "file-b")) // Duplicate same-receipt callback is harmless before finalization.
        assertTrue(store.submissionFinished())
        assertEquals(2, queued)
        assertFalse(store.value.hasContent)
        assertEquals(setOf("file-a"), store.value.fileLeases[a])
        assertEquals(setOf("file-b"), store.value.fileLeases[b])
    }

    @Test fun fastFileCompletionBeforeAcknowledgementDoesNotResurrectLeaseOrDuplicateSend() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        assertTrue(store.reserveFiles(listOf(a to "fast-file")))
        store.transferStates(setOf("fast-file"))
        assertTrue(store.value.fileLeases.isEmpty())
        assertFalse(store.submissionFinished()) // Accepted-but-unacknowledged still holds the Send gate.
        assertTrue(a in grants.reads)
        assertTrue(store.fileQueued(a, "fast-file"))
        assertTrue(store.value.fileLeases.isEmpty())
        assertTrue(store.submissionFinished())
        assertFalse(store.value.hasContent)
        assertEquals(listOf(a), grants.released)
    }

    @Test fun invalidAcknowledgementCannotUnlockAcceptedUnrecordedPendingContent() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        assertTrue(store.reserveFiles(listOf(a to "file-a")))
        assertFalse(store.fileQueued(b, "file-a"))
        assertFalse(store.submissionFinished())
        assertTrue(store.value.submitting)
        assertEquals(listOf(a), store.value.files)
        assertTrue(store.fileQueued(a, "file-a"))
        assertTrue(store.submissionFinished())
        assertFalse(store.value.hasContent)
    }

    @Test fun rejectedCoreEnqueueRetiresAdmissionAndKeepsBothFileAndFolderPending() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.addFolder(tree)
        assertTrue(store.beginSubmission())
        assertTrue(store.reserveFiles(listOf(a to "rejected-file")))
        assertTrue(store.reserveFolder(tree, "rejected-folder"))
        assertTrue(store.rejectReserved("rejected-file"))
        assertTrue(store.rejectReserved("rejected-folder"))
        assertTrue(store.submissionFinished())
        assertEquals(listOf(a), store.value.files)
        assertEquals(tree, store.value.folder)
        assertTrue(store.value.fileLeases.isEmpty())
        assertTrue(store.value.folderLeases.isEmpty())
        assertEquals(setOf(a, tree), grants.reads)
    }

    @Test fun retryMigratesF1ToF2BeforeStartAndHistoryRetirementReleasesLastGrant() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        assertTrue(admittedFile(store, a, "F1")); assertTrue(store.submissionFinished())
        grants.others += a // Core keeps F1's source while admitting its retry.
        assertTrue(store.replaceFileTransfer("F1", "F2"))
        assertEquals(setOf("F2"), store.value.fileLeases[a])
        store.transferStates(setOf("F1")); store.reconcileFileOwners(setOf("F2"))
        assertEquals(setOf("F2"), store.value.fileLeases[a])
        assertTrue(a in grants.reads)
        grants.others -= a
        store.reconcileFileOwners(emptySet()) // Clear history removes the last source, independent of a terminal row.
        assertTrue(store.value.fileLeases.isEmpty())
        assertEquals(listOf(a), grants.released)
        assertTrue(store.replaceFileTransfer("no-lease", "any-new-id"))
    }

    @Test fun retryF2SuccessRetiresMigratedOwnershipWithoutRestart() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        admittedFile(store, a, "F1"); store.submissionFinished()
        assertTrue(store.replaceFileTransfer("F1", "F2"))
        store.transferStates(setOf("F2"))
        assertTrue(store.value.fileLeases.isEmpty())
        assertEquals(listOf(a), grants.released)
    }

    @Test fun historyReconciliationPreservesPendingUriAndOtherGrantOwner() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        admittedFile(store, a, "history-file"); store.submissionFinished()
        store.addFiles(listOf(a)) // New unsent draft still references the same URI.
        store.reconcileFileOwners(emptySet())
        assertTrue(store.value.fileLeases.isEmpty())
        assertEquals(listOf(a), store.value.files)
        assertTrue(grants.released.isEmpty())
        grants.others += a
        store.cancel()
        assertTrue(grants.released.isEmpty())
        grants.others -= a
        store.reconcileFileOwners(emptySet())
        assertEquals(listOf(a), grants.released)
    }

    @Test fun postRecoveryReconciliationKeepsGenuineJournalAndRetiresPreparingOrMissingIds() {
        val memory = Memory(); val grants = Grants()
        val store = seeded(memory, grants, AttachDraft(ownedReads = setOf(tree),
            folderLeases = mapOf(tree to setOf("recoverable-journal", "preparing-without-journal")), leaseProcess = "old"), process = "new", deferCleanup = true)
        assertEquals(2, store.value.folderLeases.getValue(tree).size)
        store.reconcileFolderOwners(setOf("recoverable-journal"))
        assertEquals(setOf("recoverable-journal"), store.value.folderLeases[tree])
        assertTrue(tree in grants.reads)
        store.reconcileFolderOwners(emptySet())
        assertTrue(store.value.folderLeases.isEmpty())
        assertEquals(listOf(tree), grants.released)
    }

    @Test fun deferredCleanupWaitsForLateRecoveryOwnerBeforeReleasingOldFileGrant() {
        val memory = Memory(); val grants = Grants()
        val store = seeded(memory, grants, AttachDraft(ownedReads = setOf(a),
            fileLeases = mapOf(a to setOf("old-process-file")), leaseProcess = "old"), process = "new", deferCleanup = true)
        assertTrue(store.value.fileLeases.isEmpty())
        store.reconcileFileOwners(emptySet())
        assertTrue(grants.released.isEmpty()) // Folder recovery has not established ownership yet.
        grants.others += a // A real recovered legacy folder needs that URI after load.
        store.reconcileFolderOwners(setOf("legacy-journal"))
        assertTrue(a in grants.reads)
        assertTrue(grants.released.isEmpty())
        grants.others -= a
        store.reconcileFolderOwners(emptySet())
        assertEquals(listOf(a), grants.released)
    }

    @Test fun normalReloadKeepsReceiptButMissingOrInvalidResetClearsEphemeralAdmission() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a)); store.beginSubmission()
        store.reserveFiles(listOf(a to "reserved-file")); store.reload()
        assertTrue(store.fileQueued(a, "reserved-file")); assertTrue(store.submissionFinished())
        store.addFiles(listOf(b)); store.beginSubmission(); store.reserveFiles(listOf(b to "old-receipt"))
        memory.encoded = null; store.reload()
        assertFalse(store.value.submitting)
        assertFalse(store.value.hasContent)
        assertFalse(store.fileQueued(b, "old-receipt"))
        assertTrue(store.open("mac-a")); assertTrue(store.addFiles(listOf(b))); assertTrue(store.beginSubmission())
        assertTrue(store.reserveFiles(listOf(b to "old-receipt"))) // Reset did not leave an orphaned in-memory receipt.
    }

    @Test fun processRestartDoesNotReplayOrAcknowledgeOldInMemoryReceipts() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "old")
        before.open("mac-a"); before.addFiles(listOf(a)); before.beginSubmission(); before.reserveFiles(listOf(a to "reserved"))
        val after = AttachDraftStore(memory, grants, "new")
        assertFalse(after.value.submitting)
        assertEquals(listOf(a), after.value.files)
        assertFalse(after.fileQueued(a, "reserved"))
        assertTrue(after.beginSubmission()) // Only a new explicit submission can dispatch it again.
    }

    @Test fun placeFolderAdmissionClearsOnlyItsAcceptedSelectionWithoutAUriLease() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.select(listOf("f:place"))
        assertTrue(store.beginSubmission(emptyList(), emptyList()))
        assertTrue(store.reserveFolder(null, "place-folder"))
        assertTrue(store.folderQueued(null, "place-folder", "f:place"))
        assertTrue(store.submissionFinished())
        assertFalse(store.value.hasContent)
        assertTrue(store.value.folderLeases.isEmpty())
    }

    @Test fun oversizedOrUnsafeResultIsRejectedBeforeTakingGrantsAndKeepsPriorDraft() {
        val memory = Memory(); val grants = Grants()
        val store = AttachDraftStore(memory, grants, "p")
        store.open("mac-a"); store.addFiles(listOf(a))
        val before = memory.encoded; val calls = grants.retained.toList()
        assertFalse(store.addFiles((1..101).map { "content://documents/$it" }))
        assertFalse(store.addFiles(listOf("file:///private/path")))
        assertFalse(store.addFiles((1..20).map { "content://documents/" + "x".repeat(2000) + it }))
        assertEquals(calls, grants.retained)
        assertEquals(before, memory.encoded)
        assertNull(AttachDraftCodec.decode("x".repeat(AttachDraftCodec.MAX_BYTES + 1)))
        assertNull(AttachDraftCodec.decode("{\"version\":1,\"visible\":\"true\"}"))
    }
}
