import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The Messages window takes its content's smallest size as its own minimum, so a pane must not ask
/// for more than the window's usual size (the several-selected pane once grew it to twice its height).
final class MessagesWindowLayoutTests: XCTestCase {
    @MainActor func testSeveralSelectedDoesNotMakeTheWindowTaller() {
        var model = MessagesModel()
        model.phones = [MessagesPhone(id: "phone", name: "Pixel")]
        model.phoneID = "phone"
        model.phoneName = "Pixel"
        model.availability = .ready
        model.threads = (1...4).map { id in
            SmsThread(threadId: id, participants: [SmsParticipant(address: "+91990011220\(id)", name: nil)],
                      snippet: "Message \(id)", date: 1_793_185_000_000 - id * 60_000, unread: id == 1 ? 1 : 0, subId: 1)
        }
        model.rows = model.threads.map { SmsThreadRow(thread: $0, unread: $0.unread, pinned: false, muted: false, archived: false) }
        model.states = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })

        var bulk = model
        bulk.selecting = true
        bulk.selected = [1, 2, 3]
        XCTAssertTrue(bulk.bulk)

        let host = NSHostingController(rootView: BrandRoot(reduceMotion: true) {
            MessagesView(model: bulk, actions: MessagesActions(), copiedMessage: nil)
        })
        let smallest = host.sizeThatFits(in: .zero)
        XCTAssertLessThanOrEqual(smallest.height, MessagesView.size.height)
        XCTAssertLessThanOrEqual(smallest.width, MessagesView.size.width)
    }
}
