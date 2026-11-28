@testable import Bridgey
import XCTest

/// The phone's files against a scripted session client.
@MainActor
final class PhoneFilesModelTests: XCTestCase {
    static let phone = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
    private var client: FakeClient!
    private var model: AppModel!
    private var files: PhoneFilesModel { model.phoneFiles }
    private var next = 0

    override func setUp() async throws {
        let suite = "bridgey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let on = ["clipboard": true, "files": true, "links": true, "ping": true]
        client = FakeClient(devices: [.init(deviceId: Self.phone, name: "Pixel 9", platform: "android", connected: true, pairedAtMs: nil, lastConnectedMs: nil,
                                            local: on, remote: on.merging(["files_browse_draft1": true]) { $1 })])
        client.phoneAnswers["status"] = ["ok": true, "available": true, "files": true]
        var options = LaunchOptions()
        options.discovery = false
        options.ephemeral = true
        let fake = client!
        model = AppModel(settings: AppSettings(defaults: defaults), options: options, system: FakeSystem(), activityFile: nil) { _, _ in fake }
        model.start()
    }

    /// The request ID the next command gets.
    private func answering(_ op: String) -> String {
        next += 1
        let id = "00000000-0000-4000-8000-\(String(format: "%012d", next))"
        client.phoneAnswers[op] = ["ok": true, "requestId": id, "uploadId": id]
        return id
    }

    private func event(_ name: String, _ detail: [String: Any]) {
        let text = String(data: try! JSONSerialization.data(withJSONObject: detail), encoding: .utf8)
        model.handle(CoreEvent(kind: .phoneFiles, deviceID: Self.phone, name: name, text: text))
    }

    private func last(_ op: String) -> [String: Any]? {
        client.phoneCommands.last { $0.area == .phoneFiles && $0.command["op"] as? String == op }?.command
    }

    func testPlacesThenAFolderWithThumbnails() throws {
        let places = answering("places")
        files.show(Self.phone)
        XCTAssertTrue(files.available)
        XCTAssertNotNil(last("places"), "the places load once browsing works")
        XCTAssertEqual(files.listings[.places]?.loading, true)
        event("places", ["requestId": places, "writable": true, "media": "full", "documents": true, "places": [
            ["placeId": "default", "label": "Download/Bridgey", "available": true, "freeBytes": 1_000_000],
            ["placeId": "q3Jx0bVv1eG7tq8Wm2l5wA", "label": NSNull(), "available": false],
        ]])
        let listing = try XCTUnwrap(files.listings[.places])
        XCTAssertFalse(listing.loading)
        XCTAssertEqual(listing.items.map(\.name), ["Download/Bridgey", "Phone storage"])
        XCTAssertFalse(listing.items[1].placeAvailable)
        XCTAssertTrue(listing.media && listing.documents)

        let trip = PhoneFilesModel.Location.folder(placeID: "default", path: "Trip", title: "Download/Bridgey")
        XCTAssertEqual(trip.title, "Trip")
        let list = answering("list")
        let thumbs = answering("thumbnails")
        files.load(trip)
        XCTAssertEqual(last("list")?["path"] as? String, "Trip")
        XCTAssertEqual(last("list")?["sort"] as? String, "name")
        event("list", ["requestId": list, "placeId": "default", "path": "Trip", "writable": true, "nextCursor": "c2", "entries": [
            ["name": "Beach", "dir": true],
            ["name": "IMG_0001.jpg", "dir": false, "size": 300_000, "mimeType": "image/jpeg", "thumb": true],
        ]])
        let shown = try XCTUnwrap(files.listings[trip])
        XCTAssertEqual(shown.items.map(\.kind), [.folder, .file])
        XCTAssertEqual(shown.items[1].ref, ["placeId": "default", "path": "Trip", "name": "IMG_0001.jpg"])
        XCTAssertTrue(shown.writable)
        let asked = try XCTUnwrap(last("thumbnails")?["items"] as? [[String: Any]])
        XCTAssertEqual(asked.count, 1, "only items with a thumbnail")
        let key = try XCTUnwrap(asked.first?["key"] as? String)
        XCTAssertEqual(key, shown.items[1].id)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        event("thumbnails", ["requestId": thumbs, "thumbs": [["key": key, "data": png, "width": 1, "height": 1]], "missing": [], "done": true])
        XCTAssertNotNil(files.thumbnails[key])

        // The next page adds to the list.
        let more = answering("list")
        files.loadMore(trip)
        XCTAssertEqual(last("list")?["cursor"] as? String, "c2")
        event("list", ["requestId": more, "placeId": "default", "path": "Trip", "writable": true, "entries": [["name": "IMG_0002.jpg", "dir": false, "size": 2048]]])
        XCTAssertEqual(files.listings[trip]?.items.map(\.name), ["Beach", "IMG_0001.jpg", "IMG_0002.jpg"])
        XCTAssertNil(files.listings[trip]?.nextCursor)

        // A folder that is gone says so in plain terms.
        let gone = answering("list")
        files.load(trip)
        event("list", ["requestId": gone, "error": "not_found"])
        XCTAssertEqual(files.listings[trip]?.error, "This item is no longer on the phone.")
    }

    func testPhotosAreAMediaList() {
        files.show(Self.phone)
        let id = answering("media")
        files.load(.photos)
        XCTAssertEqual(last("media")?["kind"] as? String, "media")
        event("media", ["requestId": id, "kind": "media", "access": "full", "items": [
            ["ref": ["mediaId": "101"], "name": "IMG_0001.jpg", "size": 300_000, "mimeType": "image/jpeg", "width": 4000, "height": 3000, "thumb": true],
            ["ref": ["mediaId": "102"], "name": "clip.mp4", "mimeType": "video/mp4", "durationMs": 42_000, "thumb": true],
        ]])
        XCTAssertEqual(files.listings[.photos]?.items.map(\.ref), [["mediaId": "101"], ["mediaId": "102"]])
        XCTAssertEqual(files.listings[.photos]?.items[1].durationMs, 42_000)
    }

    func testADownloadShowsProgressThenWhereItWent() throws {
        files.show(Self.phone)
        let id = answering("download")
        let item = PhoneFilesModel.Item(id: "t9", kind: .file, name: "notes.txt", ref: ["placeId": "default", "path": "", "name": "notes.txt"])
        files.download([item])
        XCTAssertEqual(last("download")?["items"] as? [[String: String]], [["placeId": "default", "path": "", "name": "notes.txt"]])
        XCTAssertEqual(files.transfers.first?.title, "notes.txt")
        event("download", ["requestId": id, "state": "started", "files": 1, "folders": 0, "total": 19])
        event("download", ["requestId": id, "state": "receiving", "files": 1, "filesDone": 0, "bytes": 10, "total": 20, "folder": "/tmp/received"])
        XCTAssertEqual(files.transfers.first?.progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(files.transfers.first?.running ?? false)
        event("download", ["requestId": id, "state": "done", "files": 1, "filesDone": 1, "bytes": 20, "total": 20, "renamed": 1])
        let done = try XCTUnwrap(files.transfers.first)
        XCTAssertFalse(done.running)
        XCTAssertEqual(done.detail, "Done. Items with names already here were numbered.")
        XCTAssertEqual(done.folder, "/tmp/received")
        files.clear(done)
        XCTAssertTrue(files.transfers.isEmpty)

        // A refusal before it starts.
        client.phoneAnswers["download"] = ["ok": false, "error": "invalid"]
        files.download([item])
        XCTAssertEqual(files.notice, "That can’t be downloaded.")
    }

    func testAnUploadGoesIntoTheFolderAndTheFolderShowsItAfter() throws {
        files.show(Self.phone)
        let folder = PhoneFilesModel.Location.folder(placeID: "default", path: "", title: "Download/Bridgey")
        _ = answering("list")
        files.load(folder)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let id = answering("upload")
        files.upload([source], to: folder)
        let command = try XCTUnwrap(last("upload"))
        XCTAssertEqual(command["placeId"] as? String, "default")
        XCTAssertEqual(command["path"] as? String, "")
        let sent = try XCTUnwrap((command["files"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["name"] as? String, source.lastPathComponent)
        let copy = try XCTUnwrap(sent["path"] as? String)
        XCTAssertNotEqual(copy, source.path, "a copy goes, as for sending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy))

        client.phoneCommands = []
        event("upload", ["uploadId": id, "state": "done", "files": 1, "filesDone": 1, "bytes": 5, "total": 5, "destination": ["placeId": "default", "path": ""]])
        XCTAssertEqual(files.transfers.first?.detail, "Done")
        XCTAssertEqual(last("list")?["path"] as? String, "", "the folder lists again with the new file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy), "the copy goes once it is sent")

        let cancel = answering("upload")
        files.upload([source], to: folder)
        files.cancel(try XCTUnwrap(files.transfers.first { $0.id == cancel }))
        XCTAssertEqual(last("cancel_upload")?["uploadId"] as? String, cancel)
    }

    func testWhyNothingShows() {
        client.phoneAnswers["status"] = ["ok": true, "available": false, "files": true]
        files.show(Self.phone)
        XCTAssertEqual(files.statusText, "Turn on Let other devices browse this phone in Bridgey on Pixel 9.")
        XCTAssertNil(last("places"))
        XCTAssertEqual(files.problem("interrupted"), "It stopped: Pixel 9 disconnected.")
        XCTAssertEqual(files.problem("whatever"), "Something went wrong on Pixel 9.")
        // Browsing becomes possible: the places load.
        client.phoneAnswers["status"] = ["ok": true, "available": true, "files": true]
        event("status", ["available": true, "files": true])
        XCTAssertNotNil(last("places"))
    }

    func testTheSessionStoppingEndsTransfers() {
        files.show(Self.phone)
        _ = answering("download")
        files.download([PhoneFilesModel.Item(id: "t1", kind: .file, name: "a.txt", ref: ["placeId": "default", "path": "", "name": "a.txt"])])
        model.stop()
        XCTAssertEqual(files.transfers.first?.running, false)
        XCTAssertEqual(files.transfers.first?.failed, true)
        XCTAssertTrue(files.listings.isEmpty)
    }
}
