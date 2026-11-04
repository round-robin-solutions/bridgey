import XCTest
@testable import BridgeyMac

/// An accepted file transfer always ends. 2026-11-04: a 112 KB receive was accepted, the sender stopped without
/// a cancel, and the row stayed active for 40 minutes, so Update all kept saying "files are transferring".
final class StuckTransferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ id: String, active: Bool = true, queued: Bool = false, folder: FolderRowSummary? = nil, silentFor seconds: TimeInterval) -> FileTransferRow {
        FileTransferRow(id: id, name: "n", status: "Receiving", active: active, queued: queued, folder: folder,
                        lastProgressAt: now.addingTimeInterval(-seconds))
    }

    private func busy(_ rows: [FileTransferRow]) -> Set<UpdateBusy> {
        MacBusyMonitor.busy(call: false, screen: false, remote: false, transfers: rows, pairing: .idle, setupOpen: false, now: now)
    }

    // MARK: The busy rule

    func testATransferThatIsMovingIsBusy() {
        XCTAssertEqual(busy([row("a", silentFor: 0)]), [.transfer])
        XCTAssertEqual(busy([row("a", silentFor: 119)]), [.transfer])
    }

    func testAStalledTransferIsNotBusy() {
        XCTAssertEqual(busy([row("a", silentFor: 120)]), [])
        XCTAssertEqual(busy([row("a", silentFor: 40 * 60)]), [], "the 2026-11-04 case: 40 minutes with no data")
    }

    func testAStalledTransferDoesNotHideAMovingOne() {
        XCTAssertEqual(busy([row("stuck", silentFor: 600), row("live", silentFor: 3)]), [.transfer])
    }

    func testAStalledPhoneFilesDownloadIsNotBusyEither() {
        var download = FolderRowSummary(phoneName: "OnePlus 11", displayName: "Photos")
        download.incoming = true
        XCTAssertEqual(busy([row("f", folder: download, silentFor: 500)]), [])
        XCTAssertEqual(busy([row("f", folder: download, silentFor: 5)]), [.phoneFiles])
    }

    func testAFinishedRowIsNeverBusy() {
        XCTAssertEqual(busy([row("a", active: false, silentFor: 0)]), [])
    }

    // MARK: The stall timeout

    func testStallTimeoutIsTwoMinutes() {
        XCTAssertEqual(TransferStall.timeout, 120)
        XCTAssertFalse(TransferStall.isStalled(lastProgressAt: now.addingTimeInterval(-119.9), now: now))
        XCTAssertTrue(TransferStall.isStalled(lastProgressAt: now.addingTimeInterval(-120), now: now))
    }

    func testOnlyAnActiveSilentSingleFileIsFailed() {
        var folder = FolderRowSummary(phoneName: "OnePlus 11", displayName: "Photos")
        folder.incoming = true
        let rows = [
            row("stuck-b", silentFor: 300),
            row("stuck-a", silentFor: 121),
            row("fresh", silentFor: 10),
            row("done", active: false, silentFor: 900),
            row("waiting", queued: true, silentFor: 900),
            row("folder", folder: folder, silentFor: 900),
            row("preparing", silentFor: 900),
        ]
        XCTAssertEqual(TransferStall.stalledIDs(rows, excluding: ["preparing"], now: now), ["stuck-a", "stuck-b"])
    }

    func testTheStallMessageIsClearAndHasNoDashes() {
        XCTAssertTrue(TransferStall.message.contains("2 minutes"))
        XCTAssertFalse(TransferStall.message.contains("\u{2014}"))
        XCTAssertFalse(TransferStall.message.contains("\u{2013}"))
    }

    // MARK: Leak paths

    /// A replaced session is already out of the registry, so its own close never reports a disconnect. The
    /// coordinator ends that phone's transfers when it sees `.accepted(replaced:)`, or they would stay active.
    func testAReplacedSessionNeverReportsADisconnect() {
        final class Fake {}
        let registry = SessionRegistry<Fake>(localDeviceID: "m-mac")
        let old = Fake()
        registry.addPending(old, initiatedLocally: false)
        XCTAssertEqual(registry.authenticate(old, deviceID: "a-phone", peerName: "OnePlus 11"), .accepted(replaced: nil))
        let fresh = Fake()
        registry.addPending(fresh, initiatedLocally: false)
        guard case let .accepted(replaced) = registry.authenticate(fresh, deviceID: "a-phone", peerName: "OnePlus 11") else {
            return XCTFail("the newer session should win")
        }
        XCTAssertTrue(replaced === old)
        XCTAssertNil(registry.remove(old), "no device id comes back, so no disconnect cleanup runs for the old session")
    }

    /// Failing a stalled receive frees its slot and its partial file.
    func testFailingAStalledReceiveFreesTheSlotAndThePartialFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stuck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let offer = FileOfferPayload(transferId: UUID().uuidString, name: "a.bin", mimeType: "application/octet-stream", size: 10,
                                     sha256: Data(repeating: 0, count: 32).base64EncodedString())
        let transfer = try IncomingFileTransfer(offer: offer, directoryAccess: ReceiveDirectoryAccess(url: directory, scoped: false))
        try transfer.append(Data(repeating: 1, count: 4), sequence: 0)
        let partial = directory.appendingPathComponent("a.bin.bridgey-part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        transfer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(incomingFileAdmission(size: 1, phoneActive: IncomingFileLimits.perPhone - 1, totalActive: 0, freeBytes: nil, reservedBytes: 0), .accept)
        XCTAssertEqual(incomingFileAdmission(size: 1, phoneActive: IncomingFileLimits.perPhone, totalActive: 0, freeBytes: nil, reservedBytes: 0), .busy)
    }
}
