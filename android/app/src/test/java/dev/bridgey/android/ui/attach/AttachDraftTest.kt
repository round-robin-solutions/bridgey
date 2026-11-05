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
        assertTrue(store.fileQueued(a, "transfer-a")) // b's dispatch failed: there is no accepted ID.
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
        assertTrue(store.folderQueued(tree, "folder-tree"))
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
        val before = AttachDraftStore(memory, grants, "p")
        before.open("mac-a"); before.addFolder(tree); before.beginSubmission()
        val after = AttachDraftStore(memory, grants, "p")
        assertTrue(after.value.submitting)
        assertFalse(after.beginSubmission())
        assertFalse(after.target("mac-b"))
        assertFalse(after.cancel())
        after.dismiss()
        before.folderQueued(tree, "folder-tree") // The original root callback completes after recreation.
        before.submissionFinished()
        after.reload()
        assertFalse(after.value.hasContent)
        assertFalse(after.value.visible)
        assertFalse(after.value.submitting)
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
        before.fileQueued(a, "old-file-queue"); before.submissionFinished()
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
        store.fileQueued(a, "file-a"); store.submissionFinished()
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
        assertTrue(store.adoptReleasedRead(tree)) // Core preparation already ended and skips its release.
        store.transferStates(setOf("already-ended-folder")) // Terminal snapshot arrived before its queue callback.
        store.folderQueued(tree, "already-ended-folder"); store.submissionFinished()
        assertTrue(tree in store.value.ownedReads)
        store.transferStates(setOf("already-ended-folder"))
        assertEquals(listOf(tree), grants.released)
        assertTrue(store.value.ownedReads.isEmpty())
    }

    @Test fun acceptedFolderReadLeaseSurvivesProcessRestartForItsDurableCoreJournal() {
        val memory = Memory(); val grants = Grants()
        val before = AttachDraftStore(memory, grants, "old")
        before.open("mac-a"); before.addFolder(tree); before.beginSubmission()
        before.folderQueued(tree, "durable-folder"); before.submissionFinished()
        val after = AttachDraftStore(memory, grants, "new")
        assertFalse(after.value.hasContent)
        assertEquals(setOf("durable-folder"), after.value.folderLeases[tree])
        assertTrue(tree in grants.reads)
        assertTrue(grants.released.isEmpty())
        after.transferStates(setOf("durable-folder"))
        assertEquals(listOf(tree), grants.released)
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
