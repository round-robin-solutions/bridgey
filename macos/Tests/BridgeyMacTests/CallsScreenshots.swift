import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Calls window: the window and its Settings card, rendered from sample state (made-up names and
/// numbers), light and dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter CallsScreenshots
final class CallsScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    private var recents: [RecentCall] {
        [
            RecentCall(id: 9, address: "+91 98765 43210", name: "Anna Kapoor", type: .outgoing, date: ms(at(15, 9, 32)), duration: 184, subId: 1),
            RecentCall(id: 8, address: "+91 98123 45678", name: "Mahima", type: .missed, date: ms(at(15, 8, 50)), duration: 0, subId: 2),
            RecentCall(id: 7, address: "+91 22 4000 1234", name: "Olive Bar", type: .incoming, date: ms(at(14, 19, 10)), duration: 62, subId: 1),
            RecentCall(id: 6, address: "", type: .missed, date: ms(at(13, 11, 5)), duration: 0, subId: 1),
            RecentCall(id: 5, address: "+91 99001 12233", type: .outgoing, date: ms(at(11, 16, 40)), duration: 455, subId: 2),
            RecentCall(id: 4, address: "100200", name: "Rohan Mehta", type: .rejected, date: ms(at(4, 10, 0)), duration: 0, subId: 1),
        ]
    }

    var model: CallsModel {
        var model = CallsModel()
        model.now = at(15, 9, 41)
        model.phones = [CallsPhoneItem(id: phoneID, name: "OnePlus 11")]
        model.phoneID = phoneID
        model.phoneName = "OnePlus 11"
        model.availability = .ready
        model.status = DialerPhoneStatus(place: true, confirm: false, contacts: .on, recents: .on, whatsApp: true,
                                         sims: [SmsSim(subId: 1, slot: 0, label: "Jio"), SmsSim(subId: 2, slot: 1, label: "Airtel")])
        model.rows = callsRows(query: "", contacts: [], recents: recents, limit: 20)
        model.selection = model.rows.first?.id
        model.pickedSim = 1
        model.simPreference = .sim1
        model.whatsAppOnMac = true
        return model
    }

    private var contacts: [DialerContact] {
        [
            DialerContact(id: 7, name: "Anna Kapoor", starred: true,
                          numbers: [DialerNumber(address: "+91 98765 43210", label: "Mobile"), DialerNumber(address: "+91 22 4000 1234", label: "Work")],
                          whatsApp: [DialerWhatsApp(address: "+919876543210", voice: 4211, video: 4212)]),
            DialerContact(id: 12, name: "Annapurna Stores", numbers: [DialerNumber(address: "+91 98111 22334", label: "Mobile")]),
            DialerContact(id: 15, name: "Hannah Lee", numbers: [DialerNumber(address: "+44 20 7946 0000", label: "Home")],
                          whatsApp: [DialerWhatsApp(address: "+442079460000", voice: 5001, video: nil)]),
        ]
    }

    @MainActor func testRecents() throws {
        try render(model, name: "mac-calls-recents")
    }

    @MainActor func testContactSearch() throws {
        var model = self.model
        model.query = "Ann"
        model.rows = callsRows(query: "Ann", contacts: contacts, recents: recents, limit: 20)
        model.selection = model.rows.first?.id
        try render(model, name: "mac-calls-search")
    }

    @MainActor func testTypedNumberAndAskingForTheSim() throws {
        var model = self.model
        model.query = "+91 99001 12233"
        model.rows = callsRows(query: model.query, contacts: [], recents: recents, limit: 20)
        model.selection = model.rows.first?.id
        model.pickedSim = nil
        model.simPreference = .ask
        model.askingSim = .number("+919900112233", subId: nil)
        try render(model, name: "mac-calls-sim")
    }

    @MainActor func testCallingNotice() throws {
        var model = self.model
        model.notice = ("Calling on OnePlus 11. Talk on the phone or its earbuds.", true, "n")
        try render(model, name: "mac-calls-started")
        var refused = self.model
        refused.notice = ("Call emergency numbers from your phone.", false, "e")
        refused.status?.recents = .off
        refused.rows = []
        try render(refused, name: "mac-calls-recents-off")
    }

    @MainActor func testStates() throws {
        var off = CallsModel()
        off.phoneName = "OnePlus 11"
        off.availability = .macOff("OnePlus 11")
        try render(off, name: "mac-calls-off")
        var phoneOff = CallsModel()
        phoneOff.availability = .phoneOff("OnePlus 11")
        try render(phoneOff, name: "mac-calls-phone-off")
    }

    @MainActor func testSettingsCard() throws {
        var settings = SettingsModel()
        settings.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        settings.trustedDevices = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: "p2", name: "Pixel 9")]
        settings.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .remoteInput) })
        settings.deviceFeatures = [phoneID: [.dialer: true]]
        settings.phoneFeatures = [phoneID: [.dialer: true]]
        settings.callsWindow = CallsWindowSettings(sim: .ask, showWhatsApp: true, recentCount: 20, whatsAppOnMac: true)
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(SettingsPane.calls.title).font(BrandFont.heading(24)).frame(height: 30)
                    CallsWindowCard(model: settings, actions: SettingsActions())
                }
                .padding(32)
                .frame(width: 670, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            try write(view, scheme: scheme, name: "mac-calls-settings-\(scheme == .dark ? "dark" : "light")")
        }
    }

    // MARK: Rendering

    @MainActor private func render(_ model: CallsModel, name: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                CallsView(model: model, actions: CallsActions())
                    .frame(width: CallsModel.size.width, height: CallsModel.size.height)
            }
            try write(view, scheme: scheme, name: "\(name)-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
