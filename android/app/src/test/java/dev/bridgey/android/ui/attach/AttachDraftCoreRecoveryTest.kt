package dev.bridgey.android.ui.attach

import dev.bridgey.android.folders.*
import java.util.UUID
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Real FolderSender events and real sender journals; no Activity, provider, socket or live account. */
class AttachDraftCoreRecoveryTest {
    @get:Rule val temporary = TemporaryFolder()
    private val tree = "content://documents/tree/source"

    private class Persistence : AttachDraftPersistence {
        var text: String? = null
        override fun read() = text
        override fun write(value: String) { text = value }
    }
    private class Grants : AttachDraftReadGrants {
        val held = mutableSetOf<String>()
        var coreOwns: (String) -> Boolean = { false }
        override fun hasRead(uri: String) = uri in held
        override fun retainRead(uri: String): Boolean { held += uri; return true }
        override fun releaseRead(uri: String): Boolean { held -= uri; return true }
        override fun hasOtherOwner(uri: String) = coreOwns(uri)
    }

    private fun wireCore(harness: SendHarness, model: AttachDraftStore, grants: Grants) {
        grants.coreOwns = harness.sender::ownsTree
        harness.onReleaseTree = { uri -> if (!model.adoptReleasedRead(uri)) grants.releaseRead(uri) }
        harness.onFinished = { snapshot ->
            model.transferStates(setOf(snapshot.folderTransferId))
            model.reconcileFolderOwners(model.value.folderLeases.values.flatten().filter(harness.sender::owns).toSet())
        }
    }

    private fun queue(harness: SendHarness, model: AttachDraftStore): String {
        val root = MemoryNode("source")
        root.file("one.txt", byteArrayOf(1, 2, 3))
        root.file("two.txt", byteArrayOf(4, 5, 6))
        val id = UUID.randomUUID().toString()
        assertTrue(model.open("mac-1")); assertTrue(model.addFolder(tree)); assertTrue(model.beginSubmission())
        assertTrue(model.reserveFolder(tree, id))
        assertEquals(id, harness.sender.sendReserved(id, "mac-1", "Mac", root, tree))
        assertTrue(model.folderQueued(tree, id)); assertTrue(model.submissionFinished())
        return id
    }

    @Test fun backgroundCoreCompletionRetiresGrantBeforeAProcessRestartWithoutATerminalUIRow() {
        val senderDir = temporary.newFolder("sender")
        val harness = SendHarness(senderDir, temporary.newFolder("receiver"))
        val data = Persistence(); val grants = Grants(); val model = AttachDraftStore(data, grants, "process-one")
        wireCore(harness, model, grants)
        val id = queue(harness, model)
        // No UI subscribes to snapshots or invokes transferStates. The core listener owns cleanup.
        harness.run()
        assertTrue(harness.finished.any { it.folderTransferId == id })
        assertNull(harness.sendJournals.read(id))
        assertTrue(model.value.folderLeases.isEmpty())
        assertTrue(grants.held.isEmpty())
        val restored = AttachDraftStore(data, grants, "process-two", deferCleanup = true)
        val restartedCore = SendHarness(senderDir, temporary.newFolder("receiver-two"))
        grants.coreOwns = restartedCore.sender::ownsTree
        restartedCore.sender.loadJournals()
        restored.reconcileFolderOwners(emptySet())
        assertTrue(restored.value.folderLeases.isEmpty())
        assertTrue(grants.held.isEmpty())
    }

    @Test fun aPreparingAcceptedIdWithoutAJournalIsNotADurableOwnerAfterRestart() {
        val senderDir = temporary.newFolder("sender")
        val harness = SendHarness(senderDir, temporary.newFolder("receiver"))
        val data = Persistence(); val grants = Grants(); val model = AttachDraftStore(data, grants, "one")
        wireCore(harness, model, grants)
        val id = queue(harness, model)
        assertTrue(harness.sender.owns(id))
        assertNull("the fake wire has not delivered receiver acceptance", harness.sendJournals.read(id))
        // The old in-memory sender and its queued fake wire represent a dead process and are not driven again.
        val restartedCore = SendHarness(senderDir, temporary.newFolder("receiver-two"))
        grants.coreOwns = restartedCore.sender::ownsTree
        val restored = AttachDraftStore(data, grants, "two", deferCleanup = true)
        assertTrue(tree in grants.held)
        restartedCore.sender.loadJournals()
        assertFalse(restartedCore.sender.owns(id))
        restored.reconcileFolderOwners(restored.value.folderLeases.values.flatten().filter(restartedCore.sender::owns).toSet())
        assertTrue(restored.value.folderLeases.isEmpty())
        assertTrue(grants.held.isEmpty())
    }

    @Test fun aRealInterruptedJournalRetainsItsGrantUntilRecoveryEstablishesOwnership() {
        val senderDir = temporary.newFolder("sender")
        val harness = SendHarness(senderDir, temporary.newFolder("receiver"))
        val data = Persistence(); val grants = Grants(); val model = AttachDraftStore(data, grants, "one")
        wireCore(harness, model, grants)
        val id = queue(harness, model)
        harness.runUntilDone(id, 1)
        assertNotNull(harness.sendJournals.read(id))
        harness.disconnect()
        assertNotNull(harness.sendJournals.read(id))
        val restartedCore = SendHarness(senderDir, temporary.newFolder("receiver-two"))
        grants.coreOwns = restartedCore.sender::ownsTree
        val restored = AttachDraftStore(data, grants, "two", deferCleanup = true)
        assertTrue("an empty not-yet-recovered core cannot revoke a valid grant", tree in grants.held)
        restartedCore.sender.loadJournals()
        assertTrue(restartedCore.sender.owns(id))
        restored.reconcileFolderOwners(restored.value.folderLeases.values.flatten().filter(restartedCore.sender::owns).toSet())
        assertEquals(setOf(id), restored.value.folderLeases[tree])
        assertTrue(tree in grants.held)
    }
}
