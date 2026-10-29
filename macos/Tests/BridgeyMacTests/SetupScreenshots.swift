import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Setup, the permission explainer, Permissions, Reset and What's new, light and dark, named
/// `mac-<screen>-<light|dark>.png`. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter SetupScreenshots
final class SetupScreenshots: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 41))!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render setup screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Sample state

    private func peer(_ id: String, _ name: String) -> DiscoveredPeer {
        DiscoveredPeer(serviceName: name, deviceIDHint: id, deviceNameHint: name, platformHint: "android", protocolVersionHint: 1, host: "10.0.0.2", port: 4000)
    }

    private func statuses(_ states: [SetupPermission: PermissionSystemState], needs: PermissionNeeds) -> [PermissionStatus] {
        SetupPermission.allCases.map { PermissionStatus(permission: $0, system: states[$0] ?? .notDetermined, needed: needs.needed($0)) }
    }

    /// A first run: nothing paired, two phones nearby, defaults everywhere.
    private var firstRunModel: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        model.rings = deviceRings(trusted: [], peers: [peer(phoneID, "OnePlus 11"), peer(tabletID, "Pixel Tablet")], state: .idle)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .media && $0 != .remoteInput) })
        model.receiveFolderPath = NSHomeDirectory() + "/Downloads/Bridgey"
        model.shortcutKeys = [.clipboard: "C", .call: "P", .link: "Off", .ping: "Off"]
        model.channel = .stable
        model.automaticallyChecks = true
        model.updatesAvailable = true
        model.canCheckForUpdates = true
        model.shortVersion = "0.10.0-rr.1"
        model.versionDescription = "0.10.0-rr.1 (100)"
        model.now = now
        model.setup.permissions = statuses([.localNetwork: .notDetermined], needs: PermissionNeeds())
        return model
    }

    /// An existing user: one phone paired and connected, some features on.
    private var pairedModel: SettingsModel {
        var model = firstRunModel
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.trustedDevices = trusted
        model.rings = deviceRings(trusted: trusted, peers: [peer(phoneID, "OnePlus 11")], state: model.state)
        model.remoteFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.globalFeatures[.media] = true
        model.mediaPlayer = .music
        model.codesEnabled = true
        model.activityCount = 6
        model.launchAtLogin = true
        let needs = PermissionNeeds(notifications: true, calls: true, codes: true, remoteControl: false, media: true, mediaPlayer: .music)
        model.setup.permissions = statuses([.localNetwork: .allowed, .notifications: .allowed, .bluetooth: .notDetermined,
                                            .accessibility: .notDetermined, .automation: .denied], needs: needs)
        return model
    }

    private let notes = """
    ## Bridgey 0.10.0-rr.1
    ### New
    - Setup on first run: get started quickly, or go through every feature with its default.
    - Settings > Privacy > Permissions shows what Bridgey may use on this Mac, and why.
    - Reset Bridgey on this device: activity, caches, settings or everything.
    ### Fixed
    - Reconnects after the Mac wakes are faster and quieter.
    - Copying a big image no longer pauses the clipboard on the phone.
    """

    // MARK: Setup

    @MainActor func testSetupSteps() throws {
        var flow = SetupFlow()
        try setup("setup-welcome", flow: flow, model: firstRunModel)

        flow.send(.chooseQuick)
        try setup("setup-quick-local-network", flow: flow, model: firstRunModel)

        flow.send(.next)
        var allowed = firstRunModel
        allowed.setup.permissions = statuses([.localNetwork: .allowed, .notifications: .allowed], needs: PermissionNeeds())
        try setup("setup-quick-notifications", flow: flow, model: allowed)
        var denied = firstRunModel
        denied.setup.permissions = statuses([.localNetwork: .allowed, .notifications: .denied], needs: PermissionNeeds())
        try setup("setup-quick-notifications-denied", flow: flow, model: denied)

        flow.send(.skip)
        try setup("setup-quick-pair", flow: flow, model: firstRunModel)
        var code = firstRunModel
        code.state = .verification(peerName: "OnePlus 11", code: "482 913")
        try setup("setup-quick-pair-code", flow: flow, model: code)
        try setup("setup-quick-pair-done", flow: flow, model: pairedModel)

        flow.send(.skip)
        try setup("setup-done", flow: flow, model: firstRunModel)

        try questionPath()
    }

    /// The short question path: Intro (with picks and typing), a follow-up, the switches, the
    /// permissions page with mixed statuses, the summary with a refused permission, Leave setup?
    /// and More options. A fresh install: every feature off.
    @MainActor private func questionPath() throws {
        var fresh = pairedModel
        for feature in BridgeyFeature.allCases { fresh.globalFeatures[feature] = false }
        fresh.codesEnabled = false
        fresh.mediaPlayer = .off
        let facts = SetupFacts.make(model: fresh)
        var flow = SetupFlow()
        flow.send(.chooseAdvanced)
        try setup("setup-intro", flow: flow, model: fresh)
        try setup("setup-intro-typed", flow: flow, model: fresh,
                  typed: "I mainly want my WhatsApp notifications and to send photos to my Mac", picked: ["clipboard"])
        flow.send(.startQuestions(["clipboard": SetupAnswerKey.pick, "notifications": SetupAnswerKey.pick, "files": SetupAnswerKey.pick]), facts: facts)
        var picked = fresh
        picked.globalFeatures[.clipboard] = true
        picked.globalFeatures[.notifications] = true
        picked.globalFeatures[.files] = true
        let pickedFacts = SetupFacts.make(model: picked)
        try setup("setup-question-clipboard", flow: flow, model: picked)
        try setup("setup-more-options", flow: flow, model: picked, openPane: .clipboard)
        flow.send(.answer("clipboard", SetupAnswerKey.auto), facts: pickedFacts)
        try setup("setup-question-codes", flow: flow, model: picked)
        flow.send(.answer("codes", SetupAnswerKey.onMac), facts: pickedFacts)
        flow.send(.notNow, facts: pickedFacts)
        try setup("setup-switches", flow: flow, model: picked)
        flow.send(.setSwitch("remote", true), facts: pickedFacts)
        flow.send(.setSwitch("battery", true), facts: pickedFacts)
        var switched = picked
        switched.globalFeatures[.remoteInput] = true
        switched.globalFeatures[.battery] = true
        switched.codesEnabled = true
        try setup("setup-switches-on", flow: flow, model: switched)

        // The permissions page: Local Network allowed, Notifications refused, Accessibility and Bluetooth not yet.
        var asking = switched
        asking.accessibilityTrusted = false
        asking.setup.permissions = statuses([.localNetwork: .allowed, .notifications: .denied, .bluetooth: .notDetermined,
                                             .accessibility: .notDetermined], needs: PermissionNeeds())
        let askingFacts = SetupFacts.make(model: asking)
        flow.send(.proceed, facts: askingFacts)
        try setup("setup-permissions", flow: flow, model: asking)
        flow.send(.asked([.notifications, .accessibility]), facts: askingFacts)
        flow.send(.proceed, facts: askingFacts)
        var after = asking
        after.globalFeatures[.notifications] = false
        after.globalFeatures[.remoteInput] = false
        try setup("setup-summary", flow: flow, model: after)
        // Settings sync (v0.10): the summary's "Settings stay the same on your devices" line.
        try setup("settings-sync-setup-summary", flow: flow, model: after)

        var leaving = SetupFlow()
        leaving.send(.chooseAdvanced)
        leaving.send(.startQuestions(["clipboard": SetupAnswerKey.pick]), facts: facts)
        leaving.send(.askLeave)
        try setup("setup-leave", flow: leaving, model: picked)

        var pair = SetupFlow()
        var unpaired = firstRunModel
        for feature in BridgeyFeature.allCases { unpaired.globalFeatures[feature] = false }
        pair.send(.chooseAdvanced)
        pair.send(.startQuestions(["calls": SetupAnswerKey.pick]), facts: SetupFacts.make(model: unpaired))
        try setup("setup-question-pair", flow: pair, model: unpaired)
    }

    /// Phone screen (v0.9): the Remote control bundle picked, then its follow-up.
    @MainActor func testPhoneScreenQuestion() throws {
        var fresh = pairedModel
        for feature in BridgeyFeature.allCases { fresh.globalFeatures[feature] = false }
        fresh.phoneScreenEnabled = false
        var flow = SetupFlow()
        flow.send(.chooseAdvanced)
        try setup("setup-intro-remote-bundle", flow: flow, model: fresh, picked: ["remote"])
        var picked = fresh
        picked.phoneScreenEnabled = true
        flow.send(.startQuestions(["screen": SetupAnswerKey.pick]), facts: SetupFacts.make(model: picked))
        try setup("setup-question-screen", flow: flow, model: picked)
    }

    // MARK: Explainer, Permissions, Reset

    @MainActor func testPermissionExplainer() throws {
        var flow = SetupFlow()
        flow.send(.chooseQuick)
        for scheme in [ColorScheme.light, .dark] {
            let view = sheet(over: setupWindow(flow: flow, model: firstRunModel), scheme: scheme) {
                PermissionExplainerView(permission: .localNetwork)
            }
            try write(view, scheme: scheme, name: "mac-permission-explainer-\(suffix(scheme))")
            let bluetooth = sheet(over: settingsWindow(pairedModel, pane: .permissions), scheme: scheme) {
                PermissionExplainerView(permission: .bluetooth)
            }
            try write(bluetooth, scheme: scheme, name: "mac-permission-explainer-bluetooth-\(suffix(scheme))")
        }
    }

    @MainActor func testPermissionsAndResetPages() throws {
        for scheme in [ColorScheme.light, .dark] {
            try write(framed(settingsWindow(pairedModel, pane: .permissions), scheme: scheme), scheme: scheme, name: "mac-permissions-\(suffix(scheme))")
            var firstRun = firstRunModel
            firstRun.setup.permissions = statuses([.localNetwork: .allowed], needs: PermissionNeeds())
            try write(framed(settingsWindow(firstRun, pane: .permissions), scheme: scheme), scheme: scheme, name: "mac-permissions-first-run-\(suffix(scheme))")
            try write(framed(settingsWindow(pairedModel, pane: .privacy), scheme: scheme), scheme: scheme, name: "mac-settings-privacy-\(suffix(scheme))")
            try write(framed(settingsWindow(pairedModel, pane: .general), scheme: scheme), scheme: scheme, name: "mac-settings-general-\(suffix(scheme))")
            try write(framed(settingsWindow(pairedModel, pane: .reset), scheme: scheme), scheme: scheme, name: "mac-reset-\(suffix(scheme))")
            var done = pairedModel
            done.setup.resetMessage = ResetChoice.activity.doneMessage
            try write(framed(settingsWindow(done, pane: .reset), scheme: scheme), scheme: scheme, name: "mac-reset-done-\(suffix(scheme))")
            for choice in [ResetChoice.activity, .everything] {
                let view = sheet(over: settingsWindow(pairedModel, pane: .reset), scheme: scheme) { ResetConfirmView(choice: choice) }
                try write(view, scheme: scheme, name: "mac-reset-confirm-\(choice.rawValue)-\(suffix(scheme))")
            }
        }
    }

    // MARK: What's new and the panel banner

    @MainActor func testWhatsNew() throws {
        for scheme in [ColorScheme.light, .dark] {
            let review = WhatsNewContent.make(version: "0.10.0-rr.1", notes: notes, reviewSetup: true)
            try write(framed(whatsNewWindow(review), scheme: scheme), scheme: scheme, name: "mac-whats-new-\(suffix(scheme))")
            let update = WhatsNewContent.make(version: "0.10.1-rr.1", notes: notes, reviewSetup: false)
            try write(framed(whatsNewWindow(update), scheme: scheme), scheme: scheme, name: "mac-whats-new-update-\(suffix(scheme))")

            var panel = PanelModel()
            let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
            panel.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
            panel.rings = deviceRings(trusted: trusted, peers: [peer(phoneID, "OnePlus 11")], state: panel.state)
            panel.now = now
            panel.available = Set(BridgeyFeature.allCases)
            panel.showsSetupReview = true
            let view = BrandRoot(reduceMotion: false) {
                StreamPanelView(model: panel, actions: PanelActions())
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(24)
            .background(backdrop(scheme))
            try write(view, scheme: scheme, name: "mac-panel-review-banner-\(suffix(scheme))")
        }
    }

    // MARK: Rendering

    private func suffix(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    private func backdrop(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0) }

    @MainActor private func setup(_ name: String, flow: SetupFlow, model: SettingsModel, requested: Set<SetupPermission> = [],
                                  typed: String = "", picked: Set<String> = [], openPane: SettingsPane? = nil) throws {
        for scheme in [ColorScheme.light, .dark] {
            let window = setupWindow(flow: flow, model: model, requested: requested, typed: typed, picked: picked, openPane: openPane)
            try write(framed(window, scheme: scheme), scheme: scheme, name: "mac-\(name)-\(suffix(scheme))")
        }
    }

    @MainActor private func setupWindow(flow: SetupFlow, model: SettingsModel, requested: Set<SetupPermission> = [],
                                        typed: String = "", picked: Set<String> = [], openPane: SettingsPane? = nil) -> some View {
        BrandRoot(reduceMotion: true) {
            SetupWindowView(flow: flow, model: model, actions: SettingsActions(), setup: SetupActions(), requested: requested,
                            typedText: typed, pickedBundles: picked, openPane: openPane)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor private func settingsWindow(_ model: SettingsModel, pane: SettingsPane) -> some View {
        BrandRoot(reduceMotion: true) {
            SettingsWindowView(model: model, actions: SettingsActions(), pane: .constant(pane))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor private func whatsNewWindow(_ content: WhatsNewContent) -> some View {
        BrandRoot(reduceMotion: true) {
            WhatsNewView(content: content)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 14)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func framed<V: View>(_ window: V, scheme: ColorScheme) -> some View {
        window
            .compositingGroup()
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 14, y: 8)
            .padding(24)
            .background(backdrop(scheme))
    }

    /// A sheet as macOS draws it: dropped from the window's top edge over a dimmed window.
    @MainActor private func sheet<Base: View, Dialog: View>(over base: Base, scheme: ColorScheme, @ViewBuilder _ dialog: () -> Dialog) -> some View {
        let card = BrandRoot(reduceMotion: true) { dialog() }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(scheme == .dark ? 0.1 : 0), lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        return framed(
            base
                .overlay(Color.black.opacity(scheme == .dark ? 0.35 : 0.18).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                .overlay(alignment: .top) { card.padding(.top, 28) },
            scheme: scheme
        )
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
