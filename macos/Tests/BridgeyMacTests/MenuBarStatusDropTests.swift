import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The AppKit menu-bar icon (Files 2.0, files-browse.md B12) as BridgeyApp's MenuBarHost builds it: a real
/// status item whose button takes drops through its overlay and its window, and a panel that opens from code
/// without taking the keyboard during a drag. The 0.8 merge moved the app start from SwiftUI's MenuBarExtra to
/// this host, so these pin that the icon still accepts a drop. MenuBarDropTests covers what a drop then does.
@MainActor
final class MenuBarStatusDropTests: XCTestCase {
    @MainActor
    private final class RecordingHandler: StatusItemDropHandler {
        var entered = 0
        var exited = 0
        var dropped: [[DropPayload]] = []

        func statusDragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
            entered += 1
            return .copy
        }

        func statusDragExited() { exited += 1 }

        func statusPerformDrop(_ info: NSDraggingInfo) -> Bool {
            dropped.append(DropPayload.from(pasteboard: info.draggingPasteboard))
            return true
        }
    }

    /// What AppKit hands a drag destination; only the pasteboard matters here.
    @MainActor
    private final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private var controller: MenuBarStatusController!
    private var handler: RecordingHandler!
    private var file: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        let hosting = NSHostingController(rootView: AnyView(Text("Bridgey").frame(width: 200, height: 120)))
        controller = MenuBarStatusController(content: hosting)
        controller.reduceMotion = { true }
        handler = RecordingHandler()
        controller.dropHandler = handler
        file = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-drop-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("bridgey.tests.menubar.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    override func tearDownWithError() throws {
        controller.close(animated: false)
        NSStatusBar.system.removeStatusItem(controller.statusItem)
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: file)
    }

    private var dropView: StatusDropView? {
        controller.statusItem.button?.subviews.compactMap { $0 as? StatusDropView }.first
    }

    func testTheIconIsARealStatusItemThatTakesFilesTextLinksAndImages() throws {
        let button = try XCTUnwrap(controller.statusItem.button)
        controller.setSymbol("link.circle")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.accessibilityLabel(), "Bridgey")
        let overlay = try XCTUnwrap(dropView, "the drop overlay sits on the button")
        XCTAssertNil(overlay.hitTest(NSPoint(x: 1, y: 1)), "clicks go through to the button")
        for type in [NSPasteboard.PasteboardType.fileURL, .URL, .string, .png, .tiff] {
            XCTAssertTrue(overlay.registeredDraggedTypes.contains(type), type.rawValue)
        }
    }

    func testADroppedFileReachesTheDropHandlerThroughTheOverlay() throws {
        let overlay = try XCTUnwrap(dropView)
        let drag = FakeDrag(pasteboard)
        XCTAssertEqual(overlay.draggingEntered(drag), .copy)
        XCTAssertEqual(overlay.draggingUpdated(drag), .copy)
        XCTAssertTrue(overlay.performDragOperation(drag))
        XCTAssertEqual(handler.entered, 1)
        XCTAssertEqual(handler.dropped, [[.files([file])]])
        overlay.draggingExited(drag)
        XCTAssertEqual(handler.exited, 1)
    }

    func testADroppedFileReachesTheDropHandlerThroughTheStatusWindow() {
        let drag = FakeDrag(pasteboard)
        XCTAssertEqual(controller.draggingEntered(drag), .copy)
        XCTAssertTrue(controller.performDragOperation(drag))
        XCTAssertEqual(handler.dropped, [[.files([file])]])
    }

    func testAHoveringDragOpensThePanelWithoutTakingTheKeyboard() {
        controller.open(byDrag: true)
        XCTAssertTrue(controller.isOpen)
        XCTAssertTrue(controller.openedByDrag)
        controller.keepOpen()
        XCTAssertFalse(controller.openedByDrag)
        controller.close()
        XCTAssertFalse(controller.isOpen)
    }
}

/// "Clicking the menu bar icon again re-opens the panel instead of closing it" (beta 19, 2026-11-03), and
/// "Toggle didn't work" (0.11.0-rr.1 Beta 1, 2026-11-15). The outside-click monitor or the panel losing key
/// closes it first, then the icon's own action runs `togglePanel` on a closed panel. On macOS 27 that action
/// carries a new mouse-down forwarded by MenuBarAgent, not the event the monitor saw.
@MainActor
final class MenuBarStatusToggleTests: XCTestCase {
    private var controller: MenuBarStatusController!
    private var event: NSEvent?
    private var pointer = NSPoint(x: -5_000, y: -5_000)
    private var clock: TimeInterval = 0

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        controller = MenuBarStatusController(content: NSHostingController(rootView: AnyView(Text("Bridgey").frame(width: 200, height: 120))))
        controller.reduceMotion = { true }
        controller.currentEvent = { [weak self] in self?.event }
        controller.pointerLocation = { [weak self] in self?.pointer ?? .zero }
        controller.now = { [weak self] in self?.clock ?? 0 }
        event = nil
    }

    override func tearDown() {
        controller.close(animated: false)
        NSStatusBar.system.removeStatusItem(controller.statusItem)
        super.tearDown()
    }

    func testIconClickClosesAnOpenPanel() {
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen)
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen)
    }

    private func iconCentre() throws -> NSPoint {
        let icon = try XCTUnwrap(controller.iconFrame)
        return NSPoint(x: icon.midX, y: icon.midY)
    }

    private func mouse(_ number: Int, timestamp: TimeInterval, onIcon: Bool = true,
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        let icon = try XCTUnwrap(controller.iconFrame)
        let point = onIcon ? NSPoint(x: icon.midX, y: icon.midY) : NSPoint(x: icon.minX - 100, y: icon.minY - 100)
        return try mouse(number, timestamp: timestamp, at: point, type: type)
    }

    private func mouse(_ number: Int, timestamp: TimeInterval, at point: NSPoint,
                       type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        // A nil event window means the supplied location is already in screen coordinates.
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                                         windowNumber: 0, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
    }

    /// A window server event that is not a mouse event, as current when the panel lost key on the other display.
    private func windowServerEvent(timestamp: TimeInterval) throws -> NSEvent {
        try XCTUnwrap(NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: timestamp,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
    }

    func testIconClickAfterTheMonitorClosedItDoesNotReopen() throws {
        controller.togglePanel()
        event = try mouse(20, timestamp: 10)
        controller.dismissFromOutside(event: event)
        XCTAssertFalse(controller.isOpen)
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen, "the click that closed it must not open it again")
        event = try mouse(21, timestamp: 10.001)
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen, "a distinct next click opens it immediately")
    }

    /// Recorded with real clicks on macOS 27.2 (fix/menu-icon-toggle): the press goes to the menu bar, so the
    /// global monitor gets it (no window, event number 0) and closes the panel; 54 ms later the button gets a
    /// new mouse-down for the same press (event number 0 again, a point lower after rounding).
    func testMacOS27ForwardedIconMouseDownAfterTheMonitorClosesItDoesNotReopen() throws {
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen)
        let icon = try iconCentre()
        controller.dismissFromOutside(event: try mouse(0, timestamp: 550_979.1021, at: icon))
        XCTAssertFalse(controller.isOpen)
        event = try mouse(0, timestamp: 550_979.1558, at: NSPoint(x: icon.x, y: icon.y - 1))
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen, "the forwarded mouse-down is the same click: it toggles closed")
        // Closed, the monitor is gone: the next press reaches only the button, and opens the panel.
        event = try mouse(0, timestamp: 550_980.4677, at: icon)
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen)
    }

    /// A real press near the icon's edge (2 pt outside its frame, still the icon's): the forwarded mouse-down
    /// lands on the icon's centre, 14 pt from the press.
    func testMacOS27ForwardedMouseDownAtTheIconCentrePairsWithAnOffCentrePress() throws {
        controller.togglePanel()
        let icon = try XCTUnwrap(controller.iconFrame)
        let centre = NSPoint(x: icon.midX, y: icon.midY)
        controller.dismissFromOutside(event: try mouse(21_523, timestamp: 552_064.5849, at: NSPoint(x: icon.maxX + 2, y: centre.y - 2)))
        event = try mouse(0, timestamp: 552_064.6396, at: centre)
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen, "a press anywhere on the icon toggles closed")
    }

    func testAPressOnTheNextStatusItemDoesNotSwallowAnIconClick() throws {
        controller.togglePanel()
        let icon = try XCTUnwrap(controller.iconFrame)
        let neighbour = NSPoint(x: icon.maxX + MenuBarPress.sameClickSlack + 12, y: icon.midY)
        controller.dismissFromOutside(event: try mouse(90, timestamp: 80, at: neighbour))
        event = try mouse(0, timestamp: 80.05, at: NSPoint(x: icon.midX, y: icon.midY))
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen)
    }

    /// Recorded the same way, clicking the icon drawn in the other display's menu bar: no monitor event, the
    /// panel loses key with a window server event current and the pointer on that icon, far from iconFrame
    /// (which still names the first display), then the forwarded mouse-down arrives 66 ms later.
    func testMacOS27IconClickOnTheOtherDisplayClosesThePanel() throws {
        controller.togglePanel()
        let icon = try iconCentre()
        let otherIcon = NSPoint(x: icon.x + 1_920, y: icon.y + 2)
        pointer = NSPoint(x: otherIcon.x + 5, y: otherIcon.y - 3)
        event = try windowServerEvent(timestamp: 551_333.4876)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.panel))
        XCTAssertFalse(controller.isOpen)
        event = try mouse(0, timestamp: 551_333.5530, at: otherIcon)
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen, "the press on the other display's icon toggles closed")
    }

    func testIconClickAfterThePanelLostKeyDoesNotReopen() throws {
        controller.togglePanel()
        event = try mouse(30, timestamp: 20)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.panel))
        XCTAssertFalse(controller.isOpen)
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen)
    }

    func testAnUnrelatedOutsideClickDoesNotSwallowARapidReopen() throws {
        controller.togglePanel()
        event = try mouse(40, timestamp: 30, onIcon: false)
        controller.dismissFromOutside(event: event)
        event = try mouse(41, timestamp: 30.001)
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen)
    }

    func testAnIconClickAfterTheSameClickWindowIsANewClick() throws {
        controller.togglePanel()
        event = try mouse(50, timestamp: 40)
        controller.dismissFromOutside(event: event)
        event = try mouse(51, timestamp: 40 + MenuBarPress.sameClickWindow + 0.05)
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen, "a press whose own mouse-down never came cannot swallow a later click")
    }

    func testKeyboardFocusDismissalDoesNotSuppressTheNextIconClick() throws {
        controller.togglePanel()
        event = nil
        clock = 50
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.panel))
        XCTAssertFalse(controller.isOpen)
        event = try mouse(60, timestamp: 50.1)
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen, "the pointer was elsewhere when the keyboard moved")
    }

    func testTheRightIconMouseDownIsAlsoDeduplicated() throws {
        controller.togglePanel()
        event = try mouse(70, timestamp: 60, type: .rightMouseDown)
        controller.dismissFromOutside(event: event)
        controller.togglePanel()
        XCTAssertFalse(controller.isOpen)
        event = try mouse(71, timestamp: 60.001, type: .rightMouseDown)
        controller.togglePanel()
        XCTAssertTrue(controller.isOpen)
    }
}
