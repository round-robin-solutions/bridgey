import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Settings > Devices > Agents on <phone>: Permissions and Activity, a pending switch, and the phone away (read-only),
/// light and dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter AgentsScreenshots
@MainActor
final class AgentsScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 14, minute: 40))!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func ms(_ minutes: Double) -> Int64 { unixMillis(now.addingTimeInterval(minutes * 60)) }

    private var agents: [AgentDevice] {
        [
            AgentDevice(deviceId: "agent-1", name: "Contabo Europe", platform: "cli", app: "bridgey 0.1.0", os: "linux x86_64",
                        pairedAt: ms(-600), lastSeenAt: ms(0), online: true, route: "relay",
                        grants: [
                            AgentGrant(key: .files, state: .on, window: .forever, grantedAt: ms(-600), scope: "Download/Bridgey/Contabo Europe"),
                            AgentGrant(key: .notify, state: .on, window: .today, grantedAt: ms(-60), expiresAt: ms(560)),
                            AgentGrant(key: .ask, state: .on, window: .today, grantedAt: ms(-60), expiresAt: ms(560)),
                            AgentGrant(key: .codes, state: .on, window: .oneHour, grantedAt: ms(-60), expiresAt: ms(60)),
                            AgentGrant(key: .clipboardRequest, state: .waiting),
                        ],
                        activity: [
                            AgentActivityEntry(at: ms(-3), action: "notify", outcome: "delivered", detail: "Nightly passed"),
                            AgentActivityEntry(at: ms(-20), action: "ask", outcome: "answered:approve", detail: "Deploy rr-web?"),
                            AgentActivityEntry(at: ms(-60), action: "grant.change", outcome: "ok", detail: "codes 1h"),
                            AgentActivityEntry(at: ms(-1_500), action: "pair", outcome: "ok"),
                        ]),
            AgentDevice(deviceId: "agent-2", name: "rr-dev-1", platform: "cli", app: "bridgey 0.1.0", os: "linux aarch64",
                        pairedAt: ms(-3_000), lastSeenAt: ms(-90), online: false, grants: [], activity: []),
        ]
    }

    private func model(live: Bool) -> SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        model.trustedDevices = trusted
        model.state = live ? .connected(deviceID: phoneID, peerName: "OnePlus 11") : .idle
        model.rings = deviceRings(trusted: trusted, peers: [], state: model.state)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, !$0.needsDeviceGrant) })
        model.now = now
        model.agents = AgentsDisplay(
            phones: [phoneID: AgentsMirrorPhoneState(agents: agents, receivedAt: now)],
            pending: live ? [AgentsMirror.pendingKey(phone: phoneID, agent: "agent-1", key: .battery):
                                AgentGrantPending(requestId: "r", on: true, sentAt: now)] : [:],
            codeReads: [AgentCodesReadEntry(id: "1", phoneID: phoneID, agentID: "agent-1", agentName: "Contabo Europe", service: "HDFC Bank",
                                            source: .sms, app: "messages", at: now.addingTimeInterval(-60), count: 2)],
            live: live ? [phoneID] : [])
        return model
    }

    func testAgentsCard() throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try render(model: model(live: true), scheme: scheme, name: "mac-agents-permissions-\(suffix)")
            try render(model: model(live: false), scheme: scheme, name: "mac-agents-away-\(suffix)")
        }
        // The Activity tab of the same agent (the tab is view state, so it is drawn on its own here).
        for scheme in [ColorScheme.light, .dark] {
            let rows = AgentActivity.rows(agent: agents[0], phoneID: phoneID, reads: model(live: true).agents.codeReads)
            XCTAssertEqual(rows.first?.title, "Read the code from HDFC Bank")
            let view = BrandRoot(reduceMotion: false) {
                SettingsCard(title: "Activity") {
                    ForEach(rows) { row in
                        HStack {
                            RowText(title: row.title, subtitle: row.detail)
                            Text(AgentsText.time(row.at, now: self.now)).font(BrandFont.body(12))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(32)
                .frame(width: 670)
                .fixedSize(horizontal: false, vertical: true)
                .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            try write(view, scheme: scheme, name: "mac-agents-activity-rows-\(scheme == .dark ? "dark" : "light")")
        }
    }

    private func render(model: SettingsModel, scheme: ColorScheme, name: String) throws {
        let view = BrandRoot(reduceMotion: false) {
            VStack(alignment: .leading, spacing: 16) {
                AgentsOnPhoneCard(phoneID: phoneID, phoneName: "OnePlus 11", model: model, actions: SettingsActions())
            }
            .padding(32)
            .frame(width: 670, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
        }
        try write(view, scheme: scheme, name: name)
    }

    private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
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
