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
        let hosting = NSHostingController(rootView: AnyView(Text("Bridgey").frame(width: 200, height: 120)))
        controller = MenuBarStatusController(content: hosting)
        handler = RecordingHandler()
        controller.dropHandler = handler
        file = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-drop-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("bridgey.tests.menubar.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    override func tearDownWithError() throws {
        controller.close()
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
