import AppKit
import ImageIO
import XCTest
@testable import BridgeyMac

@MainActor
final class PhoneFilesCopyTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var suite = ""
    private let phone = UIFakeImages.phoneID

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phonefiles-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A private pasteboard: the general one is the user's, and Automatic clipboard would send it to a phone.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("bridgey-copy-test-\(UUID().uuidString)"))
        suite = "phonefiles-copy-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private var received: URL { directory.appendingPathComponent("Received", isDirectory: true) }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    private func makeModel(_ fake: UIFakePhoneFiles, send: SendOptimization = .default) -> PhoneFilesModel {
        let received = self.received
        let model = PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: directory.appendingPathComponent("cache")),
                                    defaults: defaults, listingCache: PhoneListingCache(directory: nil), receivedFolder: { received },
                                    previewFolder: directory.appendingPathComponent("originals"), pasteboard: pasteboard,
                                    sendOptimization: { send }, optimizedCache: directory.appendingPathComponent("optimized"))
        model.start(preferred: phone)
        wait(until: { model.listing(model.section).loaded && !model.listing(model.section).loading })
        return model
    }

    private func pasted() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func longEdge(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
        return max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    /// Visible rows, as the menu shows them without Option.
    private func visible(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// Rows with Option held: each alternate takes the place of the row before it.
    private func withOption(_ menu: NSMenu) -> [String] {
        var rows: [String] = []
        for item in menu.items {
            if item.isAlternate { rows[rows.count - 1] = item.title } else { rows.append(item.isSeparatorItem ? "-" : item.title) }
        }
        return rows
    }

    private func menu(_ model: PhoneFilesModel, _ entry: PhoneFileEntry) -> NSMenu {
        PhoneItemMenus.menu(for: entry, model: model, quickLook: { _ in }, showInFinder: { _ in })
    }

    private func photo(edge: Int, quality: Double) -> Data {
        UIFakeImages.jpeg(width: edge, height: edge * 2 / 3, seed: 3, quality: quality, detail: 2)
    }

    // MARK: Menus

    func testMenuOffersBothQualitiesOptimizedFirst() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(3)
        let model = makeModel(fake)
        let menu = menu(model, model.listing(.media).entries[0])
        XCTAssertEqual(visible(menu), ["Preview", "Quick Look", "-", "Copy Optimized", "Copy Original", "-", "Download Optimized", "Download Original"])
        let copy = menu.items.first { $0.title == "Copy Optimized" && !$0.isAlternate }
        XCTAssertEqual(copy?.keyEquivalent, "c")
        XCTAssertEqual(copy?.keyEquivalentModifierMask, .command)
    }

    func testOptionSwapsEachPair() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(3)
        let model = makeModel(fake)
        let menu = menu(model, model.listing(.media).entries[0])
        XCTAssertEqual(withOption(menu), ["Preview", "Quick Look", "-", "Copy Original", "Copy Optimized", "-", "Download Original", "Download Optimized"])
        for (index, item) in menu.items.enumerated() where item.isAlternate {
            let base = menu.items[index - 1]
            XCTAssertFalse(base.isAlternate)
            XCTAssertEqual(item.keyEquivalent, base.keyEquivalent, "an alternate shares its row's key")
            XCTAssertEqual(item.keyEquivalentModifierMask, base.keyEquivalentModifierMask.union(.option), "\(item.title) shows while Option is held")
        }
        let optionCopy = menu.items.first { $0.isAlternate && $0.keyEquivalent == "c" }
        XCTAssertEqual(optionCopy?.title, "Copy Original")
        XCTAssertEqual(optionCopy?.keyEquivalentModifierMask, [.command, .option])
    }

    func testMultiSelectionMenuActsOnEverySelectedItem() throws {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(4)
        let model = makeModel(fake)
        let entries = model.listing(.media).entries
        model.click(entries[0], command: false, shift: false)
        model.click(entries[2], command: true, shift: false)
        let menu = menu(model, entries[2])
        let copyOriginal = try XCTUnwrap(menu.items.first { $0.title == "Copy Original" && !$0.isAlternate })
        // What AppKit does on a click (performActionForItem needs a running NSApp).
        _ = (copyOriginal.target as? NSObject)?.perform(copyOriginal.action, with: copyOriginal)
        XCTAssertEqual(fake.downloads.last?.refs, [entries[0].ref, entries[2].ref], "one transfer for the whole selection")
        XCTAssertEqual(fake.downloads.last?.purpose, .preview)
        wait(until: { self.pasted().count == 2 })
        XCTAssertEqual(pasted().map(\.lastPathComponent), [entries[0].name, entries[2].name])
    }

    func testSettingFlipsTheDefault() {
        defaults.set(PhoneFetchQuality.original.rawValue, forKey: PhoneFetchQuality.defaultsKey)
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(3)
        let model = makeModel(fake)
        XCTAssertEqual(model.preferredQuality, .original)
        let menu = menu(model, model.listing(.media).entries[0])
        XCTAssertEqual(visible(menu), ["Preview", "Quick Look", "-", "Copy Original", "Copy Optimized", "-", "Download Original", "Download Optimized"])
        XCTAssertEqual(menu.items.first { $0.keyEquivalentModifierMask == .command && $0.keyEquivalent == "c" }?.title, "Copy Original")
        XCTAssertEqual(PhoneDownloadButton.items(preferred: model.preferredQuality, download: { _ in }).map(\.title), ["Download Original", "Download Optimized"])
        defaults.removeObject(forKey: PhoneFetchQuality.defaultsKey)
        XCTAssertEqual(model.preferredQuality, .optimized, "Optimized when nothing is set")
        XCTAssertEqual(PhoneDownloadButton.items(preferred: model.preferredQuality, download: { _ in }).map(\.title), ["Download Optimized", "Download Original"])
    }

    func testDocumentsGetPlainCopyAndDownload() {
        let fake = UIFakePhoneFiles()
        fake.files = UIFakeImages.documents()
        defaults.set(PhoneFilesSection.files.rawValue, forKey: "phoneFiles.last.section")
        let model = makeModel(fake)
        XCTAssertEqual(model.section, .files)
        let menu = menu(model, model.listing(.files).entries[0])
        XCTAssertEqual(visible(menu), ["Preview", "Quick Look", "-", "Copy", "Download"])
        XCTAssertFalse(menu.items.contains(where: \.isAlternate))
    }

    // MARK: Keys

    func testCommandCAndOptionCommandC() {
        XCTAssertEqual(PhoneFilesKeys.copy(keyCode: 8, characters: "c", flags: .command), false)
        XCTAssertEqual(PhoneFilesKeys.copy(keyCode: 8, characters: "c", flags: [.command, .option]), true)
        XCTAssertEqual(PhoneFilesKeys.copy(keyCode: 8, characters: "\u{0441}", flags: .command), false, "Russian layout, same key")
        XCTAssertEqual(PhoneFilesKeys.copy(keyCode: 34, characters: "c", flags: .command), false, "Dvorak C")
        XCTAssertNil(PhoneFilesKeys.copy(keyCode: 8, characters: "c", flags: [.command, .shift]))
        XCTAssertNil(PhoneFilesKeys.copy(keyCode: 8, characters: "c", flags: [.command, .control]))
        XCTAssertNil(PhoneFilesKeys.copy(keyCode: 8, characters: "c", flags: []))
        XCTAssertNil(PhoneFilesKeys.copy(keyCode: 9, characters: "v", flags: .command))
    }

    func testWindowRoutesCopyKeysOnlyOutsideTextFields() throws {
        let window = PhoneFilesNSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let grid = PhoneGridCollectionView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        let field = NSTextField(frame: NSRect(x: 0, y: 160, width: 300, height: 24))
        window.contentView?.addSubview(grid)
        window.contentView?.addSubview(field)
        var copies: [Bool] = []
        window.onCopy = { copies.append($0) }
        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        }
        XCTAssertTrue(window.makeFirstResponder(grid))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(.command)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key([.command, .option])))
        XCTAssertEqual(copies, [false, true])
        XCTAssertTrue(window.makeFirstResponder(field))
        _ = window.performKeyEquivalent(with: try key(.command))
        XCTAssertEqual(copies, [false, true], "Command-C in a text field copies its text")
        window.close()
    }

    func testCommandCCopiesThePreferredQualityAndOptionTheOther() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2)
        fake.downloadData = { _ in self.photo(edge: 3000, quality: 0.95) }
        let model = makeModel(fake)
        let entry = model.listing(.media).entries[0]
        model.click(entry, command: false, shift: false)
        model.copySelection()
        wait(until: { self.pasted().count == 1 && model.activities.isEmpty })
        let optimized = pasted()[0]
        XCTAssertLessThanOrEqual(longEdge(optimized), 2048)
        model.copySelection(model.preferredQuality.other)
        wait(until: { self.pasted().first != optimized && model.activities.isEmpty })
        XCTAssertEqual(longEdge(pasted()[0]), 3000, "Option-Command-C copies the original")
        XCTAssertEqual(fake.downloads.count, 1, "the second copy reuses the original in the cache")
    }

    // MARK: Copy

    func testCopyPutsFileURLsOnThePasteboard() throws {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(3)
        let model = makeModel(fake)
        let entries = Array(model.listing(.media).entries.prefix(2))
        let before = pasteboard.changeCount
        model.copy(entries, quality: .original)
        XCTAssertEqual(model.activities.first?.kind, .copy)
        XCTAssertEqual(PhoneFilesText.activityTitle(try XCTUnwrap(model.activities.first)), "Copying 2 items")
        wait(until: { model.activities.isEmpty })
        let urls = pasted()
        XCTAssertEqual(urls.map(\.lastPathComponent), entries.map(\.name))
        XCTAssertTrue(urls.allSatisfy { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "one pasteboard item per file, as Finder writes them")
        XCTAssertGreaterThan(pasteboard.changeCount, before)
        XCTAssertEqual(fake.copiedChangeCounts, [pasteboard.changeCount], "Automatic clipboard is told it was Bridgey")
        XCTAssertEqual(fake.downloads.count, 1)
        XCTAssertEqual(model.notice, "Copied 2 items to the clipboard")
        // The originals now sit where Quick Look looks for them.
        XCTAssertEqual(model.savedOriginal(entries[0])?.resolvingSymlinksInPath(), urls[0].resolvingSymlinksInPath())
    }

    func testCopyOptimizedPastesASmallerCopyAndLeavesTheOriginal() throws {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(1)
        fake.downloadData = { _ in self.photo(edge: 3000, quality: 0.95) }
        let model = makeModel(fake)
        let entry = model.listing(.media).entries[0]
        model.copy([entry], quality: .optimized)
        wait(until: { model.activities.isEmpty && !self.pasted().isEmpty })
        let copy = try XCTUnwrap(pasted().first)
        let original = try XCTUnwrap(model.savedOriginal(entry))
        XCTAssertNotEqual(copy.resolvingSymlinksInPath(), original.resolvingSymlinksInPath())
        XCTAssertLessThan(size(copy), size(original))
        XCTAssertLessThanOrEqual(longEdge(copy), 2048)
        XCTAssertEqual(longEdge(original), 3000, "the original is never changed")
        XCTAssertEqual(copy.lastPathComponent, entry.name)
    }

    func testOptimizedFallsBackToTheOriginalWhenNotSmaller() throws {
        let fake = UIFakePhoneFiles()
        let media = UIFakeImages.media(4) + [UIFakeImages.documents()[0]]
        fake.media = media
        XCTAssertTrue(media[3].isVideo)
        // A small, heavily compressed photo grows when re-encoded at quality 80; the video and PDF bytes are not media.
        fake.downloadData = { ref in ref == media[0].ref ? self.photo(edge: 300, quality: 0.1) : Data("x".utf8) }
        let model = makeModel(fake)
        let entries = [media[0], media[4], media[3]]
        model.copy(entries, quality: .optimized)
        wait(until: { model.activities.isEmpty && self.pasted().count == 3 })
        let originals = entries.compactMap { model.savedOriginal($0)?.resolvingSymlinksInPath() }
        XCTAssertEqual(pasted().map { $0.resolvingSymlinksInPath() }, originals, "each item silently stays the original")
        XCTAssertNil(model.notice?.range(of: "went wrong"))
    }

    func testSmallerOnlyWhenTheCopyIsSmaller() {
        let source = URL(fileURLWithPath: "/tmp/a.jpg"), output = URL(fileURLWithPath: "/tmp/cache/a.jpg")
        XCTAssertEqual(PhoneFilesOptimization.smaller(OptimizedItem(source: source, output: output, originalBytes: 100, outputBytes: 60), source: source), output)
        XCTAssertEqual(PhoneFilesOptimization.smaller(OptimizedItem(source: source, output: output, originalBytes: 100, outputBytes: 100), source: source), source)
        XCTAssertEqual(PhoneFilesOptimization.smaller(OptimizedItem(source: source, output: output, originalBytes: 100, outputBytes: 140), source: source), source)
        XCTAssertEqual(PhoneFilesOptimization.smaller(OptimizedItem(source: source, output: source, originalBytes: 100, outputBytes: 100), source: source), source)
        XCTAssertEqual(PhoneFilesOptimization.smaller(nil, source: source), source)
    }

    func testOnlyTheLatestCopyWritesThePasteboard() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(3)
        let model = makeModel(fake)
        let entries = model.listing(.media).entries
        model.copy([entries[0]], quality: .original)
        model.copy([entries[1]], quality: .original)
        wait(until: { model.activities.isEmpty })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(pasted().map(\.lastPathComponent), [entries[1].name])
        XCTAssertEqual(fake.copiedChangeCounts.count, 1)
    }

    func testCancelLeavesThePasteboardAlone() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2)
        fake.downloadDelay = 0.2
        fake.cancelCompletes = true
        let model = makeModel(fake)
        let entry = model.listing(.media).entries[0]
        let before = pasteboard.changeCount
        model.copy([entry], quality: .optimized)
        XCTAssertTrue(model.isFetchingOriginal(entry))
        model.cancel(activity: model.activities[0].id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(model.isFetchingOriginal(entry), "a later Quick Look starts afresh")
        XCTAssertNil(model.notice)
    }

    func testAFailedCopyOffersRetryAndCopiesNothing() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2)
        fake.downloadFailure = .timeout
        let model = makeModel(fake)
        let before = pasteboard.changeCount
        model.copy([model.listing(.media).entries[0]], quality: .original)
        wait(until: { model.activities.isEmpty })
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertNotNil(model.noticeRetry)
        fake.downloadFailure = nil
        model.retryNotice()
        wait(until: { model.activities.isEmpty && !self.pasted().isEmpty })
        XCTAssertEqual(pasted().count, 1)
    }

    // MARK: Download

    func testDownloadOriginalSavesTheUsualWay() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2)
        let model = makeModel(fake)
        model.click(model.listing(.media).entries[0], command: false, shift: false)
        model.downloadSelection(.original)
        XCTAssertEqual(fake.downloads.last?.purpose, .save)
        XCTAssertEqual(fake.downloads.last?.directory, received)
    }

    func testDownloadOptimizedSavesASmallerCopyInReceivedFiles() throws {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(1)
        fake.downloadData = { _ in self.photo(edge: 3000, quality: 0.95) }
        let model = makeModel(fake)
        let entry = model.listing(.media).entries[0]
        model.click(entry, command: false, shift: false)
        model.downloadSelection()
        XCTAssertEqual(fake.downloads.last?.purpose, .preview, "Optimized fetches into the private cache first")
        wait(until: { model.activities.isEmpty && model.savedURL(entry) != nil })
        let saved = try XCTUnwrap(model.savedURL(entry))
        XCTAssertEqual(saved.deletingLastPathComponent().resolvingSymlinksInPath(), received.resolvingSymlinksInPath())
        XCTAssertLessThanOrEqual(longEdge(saved), 2048)
        XCTAssertEqual(fake.savedCopyBatches.map { $0.map(\.lastPathComponent) }, [[entry.name]], "History and Finder metadata")
        XCTAssertTrue(FinderMetadata.isQuarantined(saved))
        XCTAssertNotEqual(model.savedOriginal(entry)?.resolvingSymlinksInPath(), saved.resolvingSymlinksInPath(), "Quick Look still opens the original")
        XCTAssertEqual(longEdge(try XCTUnwrap(model.savedOriginal(entry))), 3000)
        XCTAssertEqual(model.notice, "Saved \(entry.name) to Received files")
        // A second Download Optimized keeps both, Finder style.
        model.downloadSelection(.optimized)
        wait(until: { model.activities.isEmpty && fake.savedCopyBatches.count == 2 })
        XCTAssertEqual(fake.savedCopyBatches[1].first?.lastPathComponent, (entry.name as NSString).deletingPathExtension + " 2.jpg")
    }

    func testDownloadOptimizedOfDocumentsIsTheUsualSave() {
        let fake = UIFakePhoneFiles()
        fake.files = UIFakeImages.documents()
        defaults.set(PhoneFilesSection.files.rawValue, forKey: "phoneFiles.last.section")
        let model = makeModel(fake)
        model.download([model.listing(.files).entries[0]], quality: .optimized)
        XCTAssertEqual(fake.downloads.last?.purpose, .save)
    }

    // MARK: Settings

    func testOptimizedUsesTheBeforeSendingSettings() {
        let fromDefault = PhoneFilesOptimization.options(from: .default)
        XCTAssertEqual(fromDefault.imageMode, .optimize)
        XCTAssertEqual(fromDefault.maxEdge, 2048)
        XCTAssertEqual(fromDefault.format, .jpeg)
        XCTAssertEqual(fromDefault.quality, 80)
        XCTAssertEqual(fromDefault.videoMode, .hd1080Balanced)
        XCTAssertTrue(fromDefault.stripLocation)
        var chosen = SendOptimization.default
        chosen.imageMode = .optimize
        chosen.maxEdge = 1280
        chosen.format = .webp
        chosen.quality = 70
        chosen.videoMode = .hd720Small
        chosen.stripCamera = true
        chosen.folderMode = .zip
        let fromChosen = PhoneFilesOptimization.options(from: chosen)
        XCTAssertEqual(fromChosen.maxEdge, 1280)
        XCTAssertEqual(fromChosen.format, .webp)
        XCTAssertEqual(fromChosen.quality, 70)
        XCTAssertEqual(fromChosen.videoMode, .hd720Small)
        XCTAssertTrue(fromChosen.stripCamera)
        XCTAssertEqual(fromChosen.folderMode, .asIs, "folders are never zipped")
    }

    func testSettingsSearchFindsTheRow() {
        let entries = SettingsSearchRegistry.entries(SettingsModel())
        XCTAssertEqual(SettingsSearchOutcome.run("copy and download", entries: entries).rows.first?.entry.id, "files.phoneQuality")
        XCTAssertEqual(SettingsSearchOutcome.run("phone files original", entries: entries).rows.first?.entry.id, "files.phoneQuality")
        XCTAssertEqual(SettingsSearchRegistry.staticEntries.first { $0.id == "files.phoneQuality" }?.breadcrumb, "Files")
    }

    // MARK: Strings

    private func keys(_ language: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)+)"\s*="#, options: .anchorsMatchLines)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    func testStringsHaveNoDuplicatesAndBothLanguages() throws {
        let english = try keys("en"), russian = try keys("ru")
        XCTAssertEqual(english.count, Set(english).count, "duplicate keys in en: \(Dictionary(grouping: english, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
        XCTAssertEqual(russian.count, Set(russian).count, "duplicate keys in ru: \(Dictionary(grouping: russian, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
        XCTAssertEqual(Set(english).symmetricDifference(Set(russian)).sorted(), [])
        let added = ["phonefiles.copy", "phonefiles.copy.optimized", "phonefiles.copy.original", "phonefiles.download.optimized",
                     "phonefiles.download.original", "phonefiles.download.choose", "phonefiles.download.help.optimized",
                     "phonefiles.download.help.original", "phonefiles.activity.copy", "phonefiles.copied", "settings.phoneFiles.quality",
                     "settings.phoneFiles.quality.note", "settings.phoneFiles.quality.optimized", "settings.phoneFiles.quality.original"]
        for language in ["en", "ru"] {
            let bundle = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: bundle) as? [String: String])
            for key in added {
                let value = try XCTUnwrap(table[key], "\(language): \(key) is missing")
                XCTAssertFalse(value.contains("\u{2014}") || value.contains("\u{2013}"), "\(language) \(key) has a dash")
            }
        }
        XCTAssertEqual(PhoneFetchQuality.optimized.copyTitle, "Copy Optimized")
        XCTAssertEqual(PhoneFetchQuality.original.copyTitle, "Copy Original")
        XCTAssertEqual(PhoneFetchQuality.optimized.downloadTitle, "Download Optimized")
        XCTAssertEqual(PhoneFetchQuality.original.downloadTitle, "Download Original")
    }
}
