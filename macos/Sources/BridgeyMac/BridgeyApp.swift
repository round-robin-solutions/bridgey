import AppKit
import Combine
import SwiftUI

struct BridgeyApp: App {
    @NSApplicationDelegateAdaptor(BridgeyAppDelegate.self) private var appDelegate
    @StateObject private var discovery: BonjourDiscovery
    @StateObject private var pairing: PairingCoordinator
    @StateObject private var settings: BridgeySettings
    private let settingsWindow: SettingsWindowController
    private let serviceProvider: BridgeyServiceProvider
    private let updater: AppUpdater

    init() {
        LegacyPreferences.migrateIfNeeded()
        // Before BridgeySettings writes anything: a pending reset, then setup or the review banner.
        SetupCenter.shared.prepareLaunch()
        let settings = BridgeySettings()
        _settings = StateObject(wrappedValue: settings)
        let discovery = BonjourDiscovery(deviceName: settings.deviceName)
        _discovery = StateObject(wrappedValue: discovery)
        let pairing = PairingCoordinator(deviceID: discovery.localDeviceID, deviceName: discovery.localDeviceName, settings: settings)
        pairing.observe(discovery)
        IntentHost.pairing = pairing
        _pairing = StateObject(wrappedValue: pairing)
        let callServiceProvider = CallServiceProvider { [weak pairing] number in pairing?.sendCallWhenConnected(number, source: .service) }
        // Services: Call with Bridgey RR and Send to Phone with Bridgey (ShareAndServices.swift).
        let serviceProvider = BridgeyServiceProvider(calls: callServiceProvider) { payloads in
            QuickSendController.shared.present(payloads)
        }
        self.serviceProvider = serviceProvider
        NSApplication.shared.servicesProvider = serviceProvider
        QuickSendController.shared.attach(pairing: pairing)
        let updater = AppUpdater()
        self.updater = updater
        let settingsWindow = SettingsWindowController(discovery: discovery, pairing: pairing, settings: settings, updater: updater)
        self.settingsWindow = settingsWindow
        appDelegate.configure { [weak pairing] number in pairing?.sendCallWhenConnected(number, source: .link) }
        // The Share extension's hand-off: what it put on the private pasteboard goes to the chooser.
        appDelegate.configure(onShare: { QuickSendController.shared.present(ShareHandoff.take()) })
        MenuBarHost.start(discovery: discovery, pairing: pairing, settings: settings, updater: updater, openSettings: settingsWindow.show)
        SetupCenter.shared.configure(discovery: discovery, pairing: pairing, settings: settings, updater: updater,
                                     openSettings: settingsWindow.show)
    }

    var body: some Scene {
        // The menu-bar icon and panel are AppKit (MenuBarStatus.swift): they open from code and take drops.
        // An App needs a scene; an uninserted MenuBarExtra shows nothing. A lone Settings scene is opened by
        // SwiftUI at launch as an empty "Bridgey by Round Robin Settings" window (seen in the 0.8 launch smoke).
        MenuBarExtra("Bridgey", systemImage: "link.circle", isInserted: .constant(false)) { EmptyView() }
    }
}

/// Owns the menu-bar icon, its panel and drops on the icon for the life of the app.
@MainActor
enum MenuBarHost {
    private static var status: MenuBarStatusController?
    private static var subscriptions: [AnyCancellable] = []
    private static var opens = 0

    static func start(discovery: BonjourDiscovery, pairing: PairingCoordinator, settings: BridgeySettings, updater: AppUpdater,
                      openSettings: @escaping () -> Void) {
        guard status == nil else { return }
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let controller = MenuBarStatusController(content: hosting)
        let makePanel = {
            AnyView(BridgeyPanel(discovery: discovery, pairing: pairing, settings: settings, updater: updater, onOpenSettings: {
                controller.close()
                openSettings()
            }).id(opens))
        }
        hosting.rootView = makePanel()
        controller.reduceMotion = { settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        controller.onWillOpen = {
            // A fresh panel each time, as the menu-bar window had: onAppear refreshes clipboard and activity.
            opens += 1
            hosting.rootView = makePanel()
        }
        status = controller
        MenuBarDropController.shared.attach(pairing: pairing, status: controller)
        Publishers.CombineLatest(pairing.$state, pairing.remoteInput.$active)
            .receive(on: DispatchQueue.main)
            .sink { state, active in
                let symbol: String
                if active != nil {
                    symbol = "cursorarrow.rays"
                } else if case .connected = state {
                    symbol = "link.circle.fill"
                } else {
                    symbol = "link.circle"
                }
                controller.setSymbol(symbol)
            }
            .store(in: &subscriptions)
    }
}
