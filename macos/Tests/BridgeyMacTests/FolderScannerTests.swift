import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

final class FolderScannerTests: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-scan-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Make everything removable again, then clean up.
        if let enumerator = FileManager.default.enumerator(atPath: base.path) {
            for case let path as String in enumerator {
                chmod(base.appendingPathComponent(path).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func dir(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
    }

    private func scalars(_ paths: [String]) -> [[UInt32]] { paths.map { $0.unicodeScalars.map(\.value) } }

    /// The tree from section 10.1: links, a loop, an alias, a package, system and hidden files, an unreadable
    /// file, an NFD name and an empty folder.
    private func buildTree() throws {
        try write("a.txt", "hello")
        try write("sub/inner.txt", "inner")
        try dir("Empty")
        try write("App.app/Contents/Info.plist", "<plist/>")
        try write(".DS_Store")
        try write("._a.txt")
        try write("Thumbs.db")
        try write("sub/.DS_Store")
        try write(".env", "SECRET=1")
        try write(".config/settings.json", "{}")
        try write("e\u{301}te\u{301}.txt", "nfd")
        try write("report.bridgey-part")
        try write("locked.txt", "no")
        chmod(root.appendingPathComponent("locked.txt").path, 0o000)
        let manager = FileManager.default
        try manager.createSymbolicLink(at: root.appendingPathComponent("link-to-file"), withDestinationURL: root.appendingPathComponent("a.txt"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link-to-folder"), withDestinationURL: root.appendingPathComponent("sub"))
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("sub/loop").path, withDestinationPath: "..")
        let bookmark = try root.appendingPathComponent("a.txt").bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: root.appendingPathComponent("a alias"))
    }

    func testLinksAliasesSystemAndHiddenFilesWithDefaults() throws {
        try buildTree()
        let scan = FolderScanner.scan(root, options: FolderScanOptions())
        XCTAssertNil(scan.problem)
        XCTAssertEqual(scan.rootName, "Photos")
        XCTAssertEqual(scalars(scan.entries.map(\.path)), scalars([
            "App.app", "App.app/Contents", "App.app/Contents/Info.plist", "Empty", "a.txt", "sub", "sub/inner.txt", "\u{e9}t\u{e9}.txt",
        ]))
        XCTAssertEqual(scan.skipped.links, 4, "two symlinks, the loop and the alias")
        XCTAssertEqual(scan.skipped.system, 4, ".DS_Store twice, ._a.txt, Thumbs.db")
        XCTAssertEqual(scan.skipped.hidden, 2, ".env and .config")
        XCTAssertEqual(scan.skipped.unreadable, 1)
        XCTAssertEqual(scan.fileCount, 4)
        XCTAssertEqual(scan.folderCount, 4)
        XCTAssertEqual(scan.packages, ["App.app"])
        XCTAssertEqual(scan.renamed, 0, "NFD to NFC is not a visible rename")
        XCTAssertEqual(FolderText.skippedHiddenSystem(scan.skipped), "Skipped 2 hidden files, 4 system files")
        XCTAssertEqual(FolderText.packageNotice(scan.packages), "App.app is an app bundle. On the phone it is an ordinary folder.")
    }

    func testHiddenAndSystemOptionsAreSeparate() throws {
        try buildTree()
        let hidden = FolderScanner.scan(root, options: FolderScanOptions(includeHidden: true, includeSystem: false))
        XCTAssertTrue(hidden.entries.map(\.path).contains(".env"))
        XCTAssertTrue(hidden.entries.map(\.path).contains(".config/settings.json"))
        XCTAssertFalse(hidden.entries.map(\.path).contains(".DS_Store"), "system files stay out when only hidden files are included")
        XCTAssertFalse(hidden.entries.map(\.path).contains("._a.txt"))
        XCTAssertEqual(hidden.skipped.hidden, 0)
        XCTAssertEqual(hidden.skipped.system, 4)

        let system = FolderScanner.scan(root, options: FolderScanOptions(includeHidden: false, includeSystem: true))
        XCTAssertTrue(system.entries.map(\.path).contains(".DS_Store"))
        XCTAssertTrue(system.entries.map(\.path).contains("._a.txt"))
        XCTAssertTrue(system.entries.map(\.path).contains("Thumbs.db"))
        XCTAssertFalse(system.entries.map(\.path).contains(".env"))
        XCTAssertEqual(system.skipped.hidden, 2)
        XCTAssertEqual(system.skipped.system, 0)

        let both = FolderScanner.scan(root, options: FolderScanOptions(includeHidden: true, includeSystem: true))
        XCTAssertEqual(both.skipped.hidden + both.skipped.system, 0)
        XCTAssertFalse(both.entries.contains { $0.path.hasSuffix(".bridgey-part") }, "partial files are always skipped")
        XCTAssertEqual(both.skipped.links, 4)
    }

    func testManifestIsInOrderAndHashesMatch() throws {
        try buildTree()
        let scan = FolderScanner.scan(root, options: FolderScanOptions())
        for (a, b) in zip(scan.entries, scan.entries.dropFirst()) {
            XCTAssertTrue(FolderPaths.precedes(a.path, b.path), "\(a.path) before \(b.path)")
        }
        var fractions: [Double] = []
        let hashed = try XCTUnwrap(FolderHasher.hash(scan, progress: { fractions.append(Double($0) / Double($1)) }))
        XCTAssertTrue(hashed.hashed)
        let entry = try XCTUnwrap(hashed.entries.first { $0.path == "a.txt" })
        XCTAssertEqual(entry.sha256, Data(SHA256.hash(data: Data("hello".utf8))).base64EncodedString())
        XCTAssertEqual(entry.size, 5)
        XCTAssertNotNil(entry.modified)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertTrue(hashed.entries.filter { !$0.isDirectory }.allSatisfy { $0.sha256?.count == 44 })
        XCTAssertEqual(hashed.manifestDigest, ManifestDigest.compute(rootName: "Photos", entries: hashed.entries))
    }

    func testAFileGoneBeforeHashingIsDroppedAsUnreadable() throws {
        try write("a.txt", "a")
        try write("b.txt", "b")
        let scan = FolderScanner.scan(root, options: FolderScanOptions())
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        let hashed = try XCTUnwrap(FolderHasher.hash(scan))
        XCTAssertEqual(hashed.entries.map(\.path), ["a.txt"])
        XCTAssertEqual(hashed.fileCount, 1)
        XCTAssertEqual(hashed.skipped.unreadable, 1)
    }

    func testEmptyFoldersAreKeptAndAnEmptyRootHasNoEntries() throws {
        try dir("a/b/c")
        let scan = FolderScanner.scan(root, options: FolderScanOptions())
        XCTAssertEqual(scan.entries, [.dir("a"), .dir("a/b"), .dir("a/b/c")])
        let empty = base.appendingPathComponent("Nothing", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = FolderScanner.scan(empty, options: FolderScanOptions())
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.problem)
        XCTAssertEqual(ManifestPager.pages(folderTransferID: "4b0c9d5e-0000-4000-8000-000000000001", entries: none.entries)?.count, 0)
    }

    func testNamesAreMadePortable() throws {
        try write("Trip: Day 1?.txt")
        try write("CON.txt")
        let scan = FolderScanner.scan(root, options: FolderScanOptions())
        XCTAssertEqual(scan.entries.map(\.path), ["CON_.txt", "Trip_ Day 1_.txt"])
        XCTAssertEqual(scan.renamed, 2)
        XCTAssertEqual(FolderText.renamed(scan.renamed), "2 names changed to fit the phone")
    }

    // MARK: Injected listings (case clashes, limits)

    private struct FakeListing: FolderListing {
        var tree: [String: [FolderScanItem]]
        func children(of url: URL) throws -> [FolderScanItem] {
            guard let items = tree[url.path] else { throw CocoaError(.fileReadNoPermission) }
            return items
        }
    }

    private func file(_ parent: String, _ name: String, size: Int64 = 1) -> FolderScanItem {
        var item = FolderScanItem(name: name, url: URL(fileURLWithPath: parent).appendingPathComponent(name))
        item.isRegularFile = true
        item.size = size
        return item
    }

    private func folder(_ parent: String, _ name: String) -> FolderScanItem {
        var item = FolderScanItem(name: name, url: URL(fileURLWithPath: parent).appendingPathComponent(name, isDirectory: true))
        item.isDirectory = true
        return item
    }

    func testCaseClashesAreNumberedAndCounted() {
        let listing = FakeListing(tree: [
            "/Photos": [file("/Photos", "a.txt"), file("/Photos", "A.txt"), folder("/Photos", "Docs"), file("/Photos", "docs")],
            "/Photos/Docs": [],
        ])
        let scan = FolderScanner.scan(URL(fileURLWithPath: "/Photos"), options: FolderScanOptions(), listing: listing)
        XCTAssertEqual(scan.entries.map(\.path), ["A.txt", "Docs", "a (1).txt", "docs (1)"])
        XCTAssertEqual(scan.renamed, 2)
    }

    func testOtherItemsUnreadableFoldersCloudAndTooLarge() {
        var socket = FolderScanItem(name: "socket", url: URL(fileURLWithPath: "/Photos/socket"))
        socket.isRegularFile = false
        var volume = folder("/Photos", "USB")
        volume.isVolume = true
        var cloud = file("/Photos", "cloud.mov")
        cloud.notDownloaded = true
        let big = file("/Photos", "big.bin", size: FolderLimits.maxFileSize + 1)
        let listing = FakeListing(tree: [
            "/Photos": [socket, volume, cloud, big, folder("/Photos", "Locked"), file("/Photos", "ok.txt")],
        ])
        let scan = FolderScanner.scan(URL(fileURLWithPath: "/Photos"), options: FolderScanOptions(), listing: listing)
        XCTAssertEqual(scan.entries.map(\.path), ["ok.txt"])
        XCTAssertEqual(scan.skipped.other, 2)
        XCTAssertEqual(scan.skipped.notDownloaded, 1)
        XCTAssertEqual(scan.skipped.tooLarge, 1)
        XCTAssertEqual(scan.skipped.unreadable, 1, "a folder that cannot be listed")
        XCTAssertEqual(FolderText.skippedOther(scan.skipped), "1 not downloaded \u{00B7} 1 unreadable \u{00B7} 1 over 10 GB \u{00B7} 2 other items")
    }

    func testTooManyFilesIsRefusedWithTheCount() {
        let names = (0..<10_001).map { String(format: "IMG_%05d.jpg", $0) }
        let listing = FakeListing(tree: ["/Photos": names.map { file("/Photos", $0) }])
        let scan = FolderScanner.scan(URL(fileURLWithPath: "/Photos"), options: FolderScanOptions(), listing: listing)
        XCTAssertEqual(scan.problem, .tooManyFiles(10_001))
        XCTAssertEqual(scan.problem?.message(folder: "Photos"),
                       "Photos has \(FolderText.number(10_001)) files; the limit is \(FolderText.number(10_000)). Send its subfolders separately.")
    }

    func testTooManyFoldersAndTooDeepAreRefused() {
        var wide: [String: [FolderScanItem]] = ["/P": (0..<2_001).map { folder("/P", "d\($0)") }]
        for index in 0..<2_001 { wide["/P/d\(index)"] = [] }
        XCTAssertEqual(FolderScanner.scan(URL(fileURLWithPath: "/P"), options: FolderScanOptions(), listing: FakeListing(tree: wide)).problem, .tooManyFolders(2_001))

        var deep: [String: [FolderScanItem]] = [:]
        var path = "/P"
        for _ in 0..<33 {
            deep[path] = [folder(path, "d")]
            path += "/d"
        }
        deep[path] = []
        let scan = FolderScanner.scan(URL(fileURLWithPath: "/P"), options: FolderScanOptions(), listing: FakeListing(tree: deep))
        XCTAssertEqual(scan.problem, .tooDeep)
        XCTAssertEqual(scan.problem?.message(folder: "P"), "P has folders more than 32 levels deep. Send its subfolders separately.")

        var ok: [String: [FolderScanItem]] = [:]
        path = "/P"
        for _ in 0..<32 {
            ok[path] = [folder(path, "d")]
            path += "/d"
        }
        ok[path] = []
        XCTAssertNil(FolderScanner.scan(URL(fileURLWithPath: "/P"), options: FolderScanOptions(), listing: FakeListing(tree: ok)).problem)
    }

    func testAnUnreadableRootIsRefused() {
        let scan = FolderScanner.scan(URL(fileURLWithPath: "/Nope"), options: FolderScanOptions(), listing: FakeListing(tree: [:]))
        XCTAssertEqual(scan.problem, .unreadable)
    }

    /// The real thing on a case-sensitive APFS disk image, when hdiutil is allowed here.
    func testCaseClashOnACaseSensitiveVolume() throws {
        let image = base.appendingPathComponent("cs.dmg")
        let mount = base.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "Case-sensitive APFS", "-volname", "BridgeyCS", "-quiet", image.path]),
              run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-quiet", "-mountpoint", mount.path, image.path]) else {
            throw XCTSkip("hdiutil cannot create or attach a disk image here")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let folder = mount.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("2".utf8).write(to: folder.appendingPathComponent("A.txt"))
        let scan = FolderScanner.scan(folder, options: FolderScanOptions())
        XCTAssertEqual(scan.entries.map(\.path), ["A.txt", "a (1).txt"])
        XCTAssertEqual(scan.renamed, 1)
    }

    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
