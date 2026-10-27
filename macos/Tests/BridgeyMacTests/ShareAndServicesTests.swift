import AppKit
import XCTest
@testable import BridgeyMac

final class ShareAndServicesTests: XCTestCase {
    private var macos: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testHandoffURLAndPasteboardMatchTheExtension() throws {
        XCTAssertTrue(ShareHandoff.isHandoff(URL(string: "in.roundrobin.bridgey.send://share")!))
        XCTAssertFalse(ShareHandoff.isHandoff(URL(string: "tel:+911234567890")!))
        XCTAssertFalse(ShareHandoff.isHandoff(URL(string: "in.roundrobin.bridgey.send://other")!))
        let source = try String(contentsOf: macos.appendingPathComponent("ShareExtension/ShareViewController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NSPasteboard.Name(\"\(ShareHandoff.pasteboardName.rawValue)\")"))
        XCTAssertTrue(source.contains("\"\(ShareHandoff.scheme)://share\""))
    }

    func testInfoPlistDeclaresTheServiceAndTheScheme() throws {
        let data = try Data(contentsOf: macos.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let send = try XCTUnwrap(services.first { $0["NSMessage"] as? String == "sendToPhoneWithBridgey" })
        XCTAssertTrue(BridgeyServiceProvider.instancesRespond(to: NSSelectorFromString("sendToPhoneWithBridgey:userData:error:")))
        XCTAssertTrue(BridgeyServiceProvider.instancesRespond(to: NSSelectorFromString("callWithBridgey:userData:error:")))
        XCTAssertEqual(send["NSPortName"] as? String, plist["CFBundleExecutable"] as? String)
        XCTAssertEqual(Set(send["NSSendTypes"] as? [String] ?? []).isSuperset(of: ["public.file-url", "public.url", "public.utf8-plain-text"]), true)
        let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(ShareHandoff.scheme))
        XCTAssertTrue(schemes.contains("tel"))

        let extensionData = try Data(contentsOf: macos.appendingPathComponent("ShareExtension/Info.plist"))
        let extensionPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: extensionData, format: nil) as? [String: Any])
        let ext = try XCTUnwrap(extensionPlist["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "ShareExtension.ShareViewController")
        let entitlements = try String(contentsOf: macos.appendingPathComponent("ShareExtension/Share.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("com.apple.security.app-sandbox"))
    }

    @MainActor func testServiceReadsTheSelectionAndRefusesNothing() throws {
        var received: [DropPayload] = []
        let done = expectation(description: "sent")
        let provider = BridgeyServiceProvider(calls: CallServiceProvider { _ in }) { payloads in
            received = payloads
            done.fulfill()
        }
        let board = NSPasteboard(name: NSPasteboard.Name("bridgey.tests.service.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("Gate 14", forType: .string)
        var error: NSString?
        provider.sendToPhoneWithBridgey(board, userData: "", error: &error)
        wait(for: [done], timeout: 2)
        XCTAssertNil(error)
        XCTAssertEqual(received, [.text("Gate 14")])

        board.clearContents()
        provider.sendToPhoneWithBridgey(board, userData: "", error: &error)
        XCTAssertNotNil(error)
    }

    func testHandoffIsTakenOnce() {
        let board = NSPasteboard(name: NSPasteboard.Name("bridgey.tests.handoff.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(string: "https://example.com/x")! as NSURL])
        XCTAssertEqual(ShareHandoff.take(from: board), [.link(URL(string: "https://example.com/x")!)])
        XCTAssertEqual(ShareHandoff.take(from: board), [])
    }

    func testSharingPickerItemsBecomePayloads() {
        let file = URL(fileURLWithPath: "/tmp/a.pdf")
        let payloads = BridgeySharing.payloads([file, URL(string: "https://example.com")!, "hello", NSAttributedString(string: "rich")])
        XCTAssertEqual(payloads, [.files([file]), .link(URL(string: "https://example.com")!), .text("hello"), .text("rich")])
        XCTAssertEqual(BridgeySharing.payloads([URL(string: "ftp://x")!]), [])
    }
}
