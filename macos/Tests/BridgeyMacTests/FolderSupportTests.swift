import Foundation
import XCTest
@testable import BridgeyMac

/// The queue with folder items, the places client, the last destination per phone and the sender journal.
final class FolderSupportTests: XCTestCase {
    // MARK: Queue

    func testAFolderOwnsThePhoneQueueUntilItEnds() {
        var queue = FileSendQueue<OutgoingQueueItem>()
        let file = URL(fileURLWithPath: "/tmp/a.txt")
        queue.enqueue(id: "f1", item: .file(file))
        queue.enqueue(id: "folder", item: .folder)
        queue.enqueue(id: "f2", item: .file(file))
        XCTAssertEqual(queue.startNext()?.item, .file(file))
        XCTAssertNil(queue.startNext())
        queue.finish(id: "f1")
        let next = queue.startNext()
        XCTAssertEqual(next?.id, "folder")
        XCTAssertEqual(next?.item, .folder)
        // Nothing else starts while the folder runs (one folder transfer per phone at a time).
        XCTAssertNil(queue.startNext())
        XCTAssertFalse(queue.finish(id: "f2"))
        XCTAssertTrue(queue.finish(id: "folder"))
        XCTAssertEqual(queue.startNext()?.id, "f2")
    }

    func testCancelAllForgetsWaitingFolders() {
        var queue = FileSendQueue<OutgoingQueueItem>()
        queue.enqueue(id: "a", item: .folder)
        queue.enqueue(id: "b", item: .folder)
        _ = queue.startNext()
        XCTAssertEqual(queue.removeAllPending(), ["b"])
        XCTAssertEqual(queue.removeAll(), ["a"])
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: Places client

    private let phone = "phone-1"

    private func listedData(_ requestID: String, mode: DestinationMode = .senderPicks) -> Data {
        try! FolderJSON.encoder.encode(PlacesListedPayload(
            requestId: requestID, mode: mode,
            places: [PlaceInfo(placeId: "default", label: "Download/Bridgey", available: true, freeBytes: 1_000)],
            fixedLabel: mode == .fixed ? "Pictures/Inbox" : nil
        ))
    }

    func testPlacesListIsAnsweredByRequestID() throws {
        let clock = ManualFolderClock()
        let ids = SequentialIDs()
        let client = PlacesClient(clock: clock, makeID: ids.make)
        var sent: [(String, Data)] = []
        var result: Result<PlacesListedPayload, PlacesFailure>?
        client.list(phoneID: phone, send: { sent.append(($0, $1)); return true }) { result = $0 }
        XCTAssertEqual(sent.first?.0, "places.list")
        let request = try JSONDecoder().decode(PlacesListPayload.self, from: sent[0].1)
        XCTAssertEqual(request.version, 1)
        XCTAssertFalse(client.handle(kind: "places.listed", payload: listedData(request.requestId), from: "another-phone"))
        XCTAssertFalse(client.handle(kind: "places.listed", payload: listedData("00000000-0000-4000-8000-000000000099"), from: phone))
        XCTAssertTrue(client.handle(kind: "places.listed", payload: listedData(request.requestId, mode: .fixed), from: phone))
        XCTAssertEqual(try result?.get().mode, .fixed)
        XCTAssertEqual(try result?.get().fixedLabel, "Pictures/Inbox")
        XCTAssertEqual(client.inFlight, 0)
    }

    func testPlacesRequestsTimeOutAfterEightSeconds() {
        let clock = ManualFolderClock()
        let client = PlacesClient(clock: clock)
        var result: Result<PlacesChildrenPayload, PlacesFailure>?
        client.browse(phoneID: phone, placeId: "default", path: "", cursor: nil, send: { _, _ in true }) { result = $0 }
        clock.advance(7.9)
        XCTAssertNil(result)
        clock.advance(0.2)
        XCTAssertEqual(result.map { if case .failure(.timeout) = $0 { return true } else { return false } }, true)
        XCTAssertEqual(FolderText.noAnswer("OnePlus 11"), "OnePlus 11 did not answer")
    }

    func testPlacesErrorsAndDisconnects() throws {
        let clock = ManualFolderClock()
        let ids = SequentialIDs()
        let client = PlacesClient(clock: clock, makeID: ids.make)
        var created: Result<PlacesFolderCreatedPayload, PlacesFailure>?
        var sent: [Data] = []
        client.createFolder(phoneID: phone, placeId: "default", path: "Trip", name: "Trip: Day 1?", send: { sent.append($1); return true }) { created = $0 }
        let request = try JSONDecoder().decode(PlacesCreateFolderPayload.self, from: sent[0])
        XCTAssertEqual(request.name, "Trip_ Day 1_", "the name is made portable before it is sent")
        let error = try FolderJSON.encoder.encode(PlacesErrorPayload(requestId: request.requestId, code: "exists"))
        XCTAssertTrue(client.handle(kind: "places.error", payload: error, from: phone))
        XCTAssertEqual(created.map { if case .failure(.code("exists")) = $0 { return true } else { return false } }, true)

        var browsed: Result<PlacesChildrenPayload, PlacesFailure>?
        client.browse(phoneID: phone, placeId: "default", path: "", cursor: nil, send: { _, _ in true }) { browsed = $0 }
        client.cancelAll(phoneID: phone)
        XCTAssertEqual(browsed.map { if case .failure(.notConnected) = $0 { return true } else { return false } }, true)
        clock.advance(10)

        var unsent: Result<PlacesListedPayload, PlacesFailure>?
        client.list(phoneID: phone, send: { _, _ in false }) { unsent = $0 }
        XCTAssertEqual(unsent.map { if case .failure(.notConnected) = $0 { return true } else { return false } }, true)
    }

    // MARK: Last destination

    func testLastDestinationIsKeptPerPhone() throws {
        let suite = "bridgey-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = FolderDestinationMemory(defaults: defaults)
        XCTAssertNil(memory.last(for: "a"))
        memory.remember(FolderDestination(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", path: "Trip"), for: "a")
        memory.remember(FolderDestination(placeId: "default", path: ""), for: "b")
        XCTAssertEqual(memory.last(for: "a"), FolderDestination(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", path: "Trip"))
        XCTAssertEqual(memory.last(for: "b"), FolderDestination(placeId: "default", path: ""))
        XCTAssertNotNil(defaults.dictionary(forKey: "folders.lastDestination.a"))
        defaults.set(["placeId": "content://x", "path": "Trip"], forKey: "folders.lastDestination.c")
        XCTAssertNil(memory.last(for: "c"), "only real place IDs are used")
        memory.forget("a")
        XCTAssertNil(memory.last(for: "a"))
    }

    // MARK: Journal

    private func journal(_ id: String, device: String = "phone-1", lastProgress: Date) -> FolderJournal {
        FolderJournal(
            folderTransferId: id, deviceID: device, deviceName: "OnePlus 11", rootPath: "/tmp/Photos", bookmark: nil,
            displayName: "Photos", rootName: "Photos", options: FolderScanOptions(includeHidden: true, includeSystem: false),
            destination: FolderDestination(placeId: "default", path: "Trip"), destinationLabel: "Download/Bridgey/Trip",
            manifestSha256: "q1f3", fileCount: 124, totalSize: 2_469_606_195, createdAt: lastProgress.addingTimeInterval(-60),
            lastProgressAt: lastProgress, completed: [1, 4, 9]
        )
    }

    func testJournalRoundTripsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FolderJournalStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = journal("4b0c9d5e-0000-4000-8000-000000000001", lastProgress: now)
        store.save(saved)
        let loaded = store.load(now: now.addingTimeInterval(3_600))
        XCTAssertEqual(loaded, [saved])
        let file = directory.appendingPathComponent("4b0c9d5e-0000-4000-8000-000000000001.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(folderMode, 0o700)
        XCTAssertTrue(FolderJournalStore.defaultDirectory().path.hasSuffix("\(Edition.supportFolderName)/FolderTransfers"))
        // IDs that are not wire UUIDs never become file names.
        store.save(journal("../escape", lastProgress: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.json").path))
    }

    func testJournalsExpireAfterTwentyFourHoursAndForgetDeletesThem() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FolderJournalStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(journal("4b0c9d5e-0000-4000-8000-000000000001", lastProgress: now.addingTimeInterval(-25 * 3_600)))
        store.save(journal("4b0c9d5e-0000-4000-8000-000000000002", lastProgress: now.addingTimeInterval(-23 * 3_600)))
        store.save(journal("4b0c9d5e-0000-4000-8000-000000000003", device: "phone-2", lastProgress: now))
        XCTAssertEqual(store.load(now: now).map(\.folderTransferId), ["4b0c9d5e-0000-4000-8000-000000000002", "4b0c9d5e-0000-4000-8000-000000000003"])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count, 2, "the expired journal is deleted")
        store.deleteAll(deviceID: "phone-1", now: now)
        XCTAssertEqual(store.load(now: now).map(\.deviceID), ["phone-2"])
        XCTAssertTrue(FolderTimeouts.canResume(lastProgress: now, now: now.addingTimeInterval(24 * 3_600 - 1)))
        XCTAssertFalse(FolderTimeouts.canResume(lastProgress: now, now: now.addingTimeInterval(24 * 3_600)))
    }
}
