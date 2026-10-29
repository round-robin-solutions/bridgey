import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Every pairing state in the menu bar panel and in setup's pair step, light and dark, named
/// `panel-<state>-<light|dark>.png` and `setup-pair-<state>-<light|dark>.png`. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter PairingScreenshots
final class PairingScreenshots: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 41))!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let newID = "33333333-3333-3333-3333-333333333333"
    private let newName = "Galaxy S24"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render pairing screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: States

    private var flows: [(String, PairingState)] {
        let prompt = PairingPrompt(peerName: newName, code: "482913", token: "t")
        var waiting = prompt
        waiting.localConfirmed = true
        var confirmedThere = prompt
        confirmedThere.remoteConfirmed = true
        var finishing = waiting
        finishing.remoteConfirmed = true
        var states: [(String, PairingState)] = [
            ("connecting", .connecting(newName)),
            ("waiting-for-allow", .waitingForAllow(newName)),
            ("verification-check", .verification(prompt)),
            ("verification-waiting", .verification(waiting)),
            ("verification-confirmed-there", .verification(confirmedThere)),
            ("verification-finishing", .verification(finishing)),
            ("paired", .paired(deviceID: newID, peerName: newName)),
        ]
        let failures: [(String, PairingFailure)] = [
            ("mismatch-remote", .mismatchRemote), ("mismatch-local", .mismatchLocal), ("timeout-remote", .timeoutRemote),
            ("timeout-local", .timeoutLocal), ("timeout-neither", .timeoutNeither), ("cancelled-remote", .cancelledRemote),
            ("old-version", .oldVersion), ("no-answer", .noAnswer), ("not-allowed", .notAllowed), ("busy", .busy),
            ("rate-limited", .rateLimited), ("connection-lost", .connectionLost), ("could-not-connect", .couldNotConnect),
            ("identity-changed", .identityChanged), ("local-network", .localNetworkDenied),
        ]
        states += failures.map { ("failed-\($0.0)", PairingState.failed($0.1, peerName: newName)) }
        return states
    }

    private func peer(_ id: String, _ name: String) -> DiscoveredPeer {
        DiscoveredPeer(serviceName: name, deviceIDHint: id, deviceNameHint: name, platformHint: "android", protocolVersionHint: 2, host: "10.0.0.2", port: 4000)
    }

    private func panel(_ flow: PairingState) -> PanelModel {
        var model = PanelModel()
        model.state = flow
        model.pairingFlow = flow
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        model.rings = deviceRings(trusted: trusted, peers: [peer(phoneID, "OnePlus 11"), peer(newID, newName)], connected: [], pairing: flow)
        if case let .paired(id, peerName) = flow {
            let connected = PhoneConnection(id: id, name: peerName, state: PhoneLinkState())
            model.state = .connected(deviceID: id, peerName: peerName)
            model.rings = deviceRings(trusted: trusted + [TrustedDeviceInfo(id: id, name: peerName)], peers: [peer(phoneID, "OnePlus 11"), peer(id, peerName)],
                                      connected: [connected], pairing: flow)
            model.targetDeviceID = id
            model.available = Set(BridgeyFeature.allCases)
        }
        model.now = now
        model.clipboardLine = "Room 2 at 4, bring the deck"
        return model
    }

    private var setupModel: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        model.rings = deviceRings(trusted: [], peers: [peer(newID, newName), peer(phoneID, "OnePlus 11")], state: .idle)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .media && $0 != .remoteInput) })
        model.shortVersion = "0.10.0-rr.1"
        model.now = now
        model.setup.permissions = SetupPermission.allCases.map {
            PermissionStatus(permission: $0, system: $0 == .localNetwork ? .allowed : .notDetermined, needed: PermissionNeeds().needed($0))
        }
        return model
    }

    // MARK: Renders

    @MainActor func testPanelPairingStates() throws {
        for (state, flow) in flows {
            for scheme in [ColorScheme.light, .dark] {
                try render(panel: panel(flow), scheme: scheme, name: "panel-\(state)-\(suffix(scheme))")
            }
        }
        var allow = panel(.idle)
        var armed = panel(.idle)
        armed.pairingArmedSeconds = 118
        var request = panel(.idle)
        request.pairingRequest = PairingRequest(deviceID: newID, peerName: newName, oldVersion: false)
        var oldRequest = panel(.idle)
        oldRequest.pairingRequest = PairingRequest(deviceID: newID, peerName: newName, oldVersion: true)
        allow.now = now
        for scheme in [ColorScheme.light, .dark] {
            try render(panel: allow, scheme: scheme, name: "panel-allow-pairing-\(suffix(scheme))")
            try render(panel: armed, scheme: scheme, name: "panel-allow-pairing-countdown-\(suffix(scheme))")
            try render(panel: request, scheme: scheme, name: "panel-pairing-request-\(suffix(scheme))")
            try render(panel: oldRequest, scheme: scheme, name: "panel-pairing-request-old-version-\(suffix(scheme))")
        }
    }

    @MainActor func testSetupPairStepStates() throws {
        var flow = SetupFlow()
        flow.send(.chooseQuick)
        flow.send(.next)
        flow.send(.skip)
        let setupStates: Set<String> = [
            "connecting", "waiting-for-allow", "verification-check", "verification-waiting", "verification-confirmed-there",
            "verification-finishing", "failed-mismatch-remote", "failed-mismatch-local", "failed-old-version", "failed-not-allowed",
            "failed-local-network", "failed-timeout-remote",
        ]
        for scheme in [ColorScheme.light, .dark] {
            try render(setup: flow, model: setupModel, scheme: scheme, name: "setup-pair-nearby-\(suffix(scheme))")
            for (state, pairing) in flows where setupStates.contains(state) {
                var model = setupModel
                model.state = pairing
                model.pairingFlow = pairing
                try render(setup: flow, model: model, scheme: scheme, name: "setup-pair-\(state)-\(suffix(scheme))")
            }
            var paired = setupModel
            paired.trustedDevices = [TrustedDeviceInfo(id: newID, name: newName)]
            paired.state = .connected(deviceID: newID, peerName: newName)
            paired.pairingFlow = .paired(deviceID: newID, peerName: newName)
            try render(setup: flow, model: paired, scheme: scheme, name: "setup-pair-paired-\(suffix(scheme))")
        }
    }

    @MainActor private func render(panel model: PanelModel, scheme: ColorScheme, name: String) throws {
        let view = BrandRoot(reduceMotion: true) {
            StreamPanelView(model: model, actions: PanelActions())
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(1)
        .compositingGroup()
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 16, y: 10)
        .padding(20)
        .frame(width: 400)
        .background(backdrop(scheme))
        try write(view, scheme: scheme, name: name)
    }

    @MainActor private func render(setup flow: SetupFlow, model: SettingsModel, scheme: ColorScheme, name: String) throws {
        let window = BrandRoot(reduceMotion: true) {
            SetupWindowView(flow: flow, model: model, actions: SettingsActions(), setup: SetupActions())
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 14, y: 8)
        .padding(24)
        .background(backdrop(scheme))
        try write(window, scheme: scheme, name: name)
    }

    private func suffix(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    private func backdrop(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0) }

    @MainActor private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 2
        guard var image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        // A fractional view height leaves a see-through last pixel row; drop it.
        if (NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: image.height - 1)?.alphaComponent ?? 1) < 0.5,
           let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height - 1)) {
            image = cropped
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
