package dev.bridgey.android.updates

import android.media.AudioManager
import android.telephony.TelephonyManager
import dev.bridgey.android.FileTransferState
import dev.bridgey.android.PairingState
import dev.bridgey.android.TransferKind
import dev.bridgey.android.folders.FolderSnapshot
import dev.bridgey.android.remote.RemoteMode
import dev.bridgey.android.remote.RemoteSessionState
import dev.bridgey.android.remote.RemoteStopReason
import dev.bridgey.android.screen.ScreenShareState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What counts as busy on this phone for Update all devices automatically. */
class BusyMonitorTest {
    private fun busy(signals: BusySignals) = BusyRules.busy(signals)

    @Test fun nothingGoingOnIsNotBusy() {
        assertEquals(emptySet<UpdateBusy>(), busy(BusySignals()))
    }

    @Test fun callsFromTheAudioModeThePhoneStateOrACallCard() {
        listOf(AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION, 4, 5, 6).forEach { mode ->
            assertTrue("mode $mode", BusyRules.callFromAudioMode(mode))
        }
        assertFalse(BusyRules.callFromAudioMode(AudioManager.MODE_NORMAL))
        assertEquals(setOf(UpdateBusy.CALL), busy(BusySignals(audioMode = AudioManager.MODE_IN_COMMUNICATION)))
        assertEquals(setOf(UpdateBusy.CALL), busy(BusySignals(telephonyCallState = TelephonyManager.CALL_STATE_RINGING)))
        assertEquals(setOf(UpdateBusy.CALL), busy(BusySignals(telephonyCallState = TelephonyManager.CALL_STATE_OFFHOOK)))
        assertEquals(setOf(UpdateBusy.CALL), busy(BusySignals(callCards = true)))
    }

    @Test fun screenSharingAndRemoteControlWhileStartingOrGoing() {
        assertEquals(setOf(UpdateBusy.SCREEN_SHARE), busy(BusySignals(screen = ScreenShareState.Phase.STARTING)))
        assertEquals(setOf(UpdateBusy.SCREEN_SHARE), busy(BusySignals(screen = ScreenShareState.Phase.SHARING)))
        // Android's consent dialog is up: nothing is shared yet.
        assertEquals(emptySet<UpdateBusy>(), busy(BusySignals(screen = ScreenShareState.Phase.ASKING)))
        val mode = RemoteMode.entries.first()
        assertEquals(setOf(UpdateBusy.REMOTE_CONTROL), busy(BusySignals(remote = RemoteSessionState.Starting("m", mode))))
        assertEquals(setOf(UpdateBusy.REMOTE_CONTROL), busy(BusySignals(remote = RemoteSessionState.Active("m", mode, "s"))))
        assertEquals(emptySet<UpdateBusy>(), busy(BusySignals(remote = RemoteSessionState.Ended("m", RemoteStopReason.entries.first()))))
    }

    private fun transfer(id: String, active: Boolean = true, kind: TransferKind = TransferKind.FILE, download: Boolean = false) = FileTransferState(
        id, "photo.jpg", "", active, null, kind = kind,
        folder = if (kind == TransferKind.FOLDER) FolderSnapshot(id, "mac", "Work Mac", "Trip", 3, 1_000, outgoing = download, download = download) else null,
    )

    @Test fun aPhoneFilesDownloadAndOtherTransfers() {
        assertEquals(setOf(UpdateBusy.PHONE_FILES), busy(BusySignals(transfers = listOf(transfer("a", kind = TransferKind.FOLDER, download = true)))))
        assertEquals(setOf(UpdateBusy.TRANSFER), busy(BusySignals(transfers = listOf(transfer("a")))))
        assertEquals(setOf(UpdateBusy.TRANSFER), busy(BusySignals(transfers = listOf(transfer("a", kind = TransferKind.FOLDER)))))
        assertEquals(
            setOf(UpdateBusy.PHONE_FILES, UpdateBusy.TRANSFER),
            busy(BusySignals(transfers = listOf(transfer("a", kind = TransferKind.FOLDER, download = true), transfer("b")))),
        )
        // Finished transfers stay in the list for a while; they are not busy.
        assertEquals(emptySet<UpdateBusy>(), busy(BusySignals(transfers = listOf(transfer("a", active = false)))))
        assertEquals(setOf(UpdateBusy.TRANSFER), busy(BusySignals(clipFetches = 1)))
    }

    @Test fun pairingAndSetup() {
        assertEquals(setOf(UpdateBusy.SETUP), busy(BusySignals(pairing = PairingState.Connecting("Work Mac"))))
        assertEquals(setOf(UpdateBusy.SETUP), busy(BusySignals(pairing = PairingState.Verification("Work Mac", "123456"))))
        assertEquals(setOf(UpdateBusy.SETUP), busy(BusySignals(setupShowing = true)))
        assertEquals(emptySet<UpdateBusy>(), busy(BusySignals(pairing = PairingState.Connected("w", "Work Mac"))))
    }

    @Test fun aCallComesFirstOnTheWire() {
        val everything = busy(
            BusySignals(
                audioMode = AudioManager.MODE_IN_CALL, screen = ScreenShareState.Phase.SHARING, setupShowing = true,
                transfers = listOf(transfer("a")), remote = RemoteSessionState.Active("m", RemoteMode.entries.first(), "s"),
            ),
        )
        assertEquals(UpdateBusy.CALL, UpdateBusy.mostImportant(everything))
        assertEquals(UpdateBusy.REMOTE_CONTROL, UpdateBusy.mostImportant(everything - UpdateBusy.CALL))
    }
}
