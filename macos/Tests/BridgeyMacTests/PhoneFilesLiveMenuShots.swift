import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The real Phone files window and its real menus on screen, captured with screencapture, light and dark. Opt-in,
/// since it puts a window in front for a few seconds and needs screen recording access:
///   BRIDGEY_LIVE_MENU_DIR=/tmp/shots swift test --filter PhoneFilesLiveMenuShots
@MainActor
final class PhoneFilesLiveMenuShots: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_LIVE_MENU_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_LIVE_MENU_DIR to capture the live menus")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("bridgey-live-menu-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard?.releaseGlobally()
        NSApp.appearance = nil
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testMenus() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        for dark in [false, true] {
            try capture(dark: dark)
        }
    }

    private func capture(dark: Bool) throws {
        let suffix = dark ? "dark" : "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let fake = UIFakePhoneFiles()
        let model = PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: nil), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    listingCache: PhoneListingCache(directory: nil), pasteboard: pasteboard)
        let entries = UIFakeImages.media(36, now: UIFakeImages.base)
        model.setForTesting(phones: [BrowsablePhone(id: UIFakeImages.phoneID, name: "OnePlus 11", browsable: true, route: .lan)],
                            phoneID: UIFakeImages.phoneID, info: PhoneBrowseInfo(places: UIFakeImages.places, writable: true, media: .full, documents: true),
                            section: .media, listings: [.media: PhoneListing(entries: entries, loaded: true)])
        model.displayNow = UIFakeImages.base
        for (index, entry) in entries.enumerated() { model.thumbnails.box(for: entry).setForTesting(UIFakeImages.decoded(seed: index)) }
        model.selection = [entries[1].id, entries[2].id]
        let window = PhoneFilesNSWindow(contentRect: NSRect(origin: .zero, size: PhoneFilesWindowView.size),
                                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = appearance
        window.contentViewController = NSHostingController(rootView: BrandRoot(reduceMotion: false) {
            PhoneFilesWindowView(model: model, promises: PhoneFilePromises(model: model))
        }.ignoresSafeArea())
        window.setContentSize(PhoneFilesWindowView.size)
        window.center()
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        spin(1.0)
        let content = try XCTUnwrap(window.contentView)
        // Right of the second cell, where a right click would open it.
        let menuPoint = NSPoint(x: 520, y: content.isFlipped ? 150 : content.bounds.height - 150)
        let context = PhoneItemMenus.menu(for: entries[1], model: model, quickLook: { _ in }, showInFinder: { _ in })
        try shoot(context, at: menuPoint, in: content, window: window, name: "mac-phonefiles-menu-\(suffix)")
        try shoot(context, at: menuPoint, in: content, window: window, name: "mac-phonefiles-menu-option-\(suffix)", option: true)
        let download = PopUpMenuPresenter.menu(PhoneDownloadButton.items(preferred: model.preferredQuality, download: { _ in }))
        let downloadPoint = NSPoint(x: content.bounds.width - 220, y: content.isFlipped ? 52 : content.bounds.height - 52)
        try shoot(download, at: downloadPoint, in: content, window: window, name: "mac-phonefiles-download-menu-\(suffix)")
    }

    /// Opens `menu` (blocking, as AppKit does), captures the window's area once drawn, then closes it. With `option`,
    /// an Option key-down goes to this process only, as if Option were held while the menu is open.
    private func shoot(_ menu: NSMenu, at point: NSPoint, in view: NSView, window: NSWindow, name: String, option: Bool = false) throws {
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let file = directory.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: file)
        let shooter = MenuShooter(menu: menu, file: file, option: option,
                                  rect: "\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        if option { shooter.perform(#selector(MenuShooter.holdOption), with: nil, afterDelay: 0.25, inModes: [.common]) }
        shooter.perform(#selector(MenuShooter.capture), with: nil, afterDelay: 0.7, inModes: [.common])
        menu.popUp(positioning: nil, at: point, in: view)
        spin(0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(name) was not captured")
    }
}

/// Runs inside the menu's tracking loop (perform(afterDelay:inModes:) with the common modes).
private final class MenuShooter: NSObject {
    let menu: NSMenu
    let file: URL
    let option: Bool
    let rect: String

    init(menu: NSMenu, file: URL, option: Bool, rect: String) {
        self.menu = menu
        self.file = file
        self.option = option
        self.rect = rect
    }

    @objc func holdOption() { post(down: true) }

    @objc func capture() {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-R\(rect)", file.path]
        try? shot.run()
        shot.waitUntilExit()
        if option { post(down: false) }
        MainActor.assumeIsolated { menu.cancelTracking() }
    }

    private func post(down: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: down)
        event?.flags = down ? .maskAlternate : []
        event?.postToPid(getpid())
    }
}
