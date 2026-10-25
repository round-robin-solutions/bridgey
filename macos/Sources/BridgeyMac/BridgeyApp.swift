import AppKit
import SwiftUI

@main
struct BridgeyApp: App {
    @NSApplicationDelegateAdaptor(PhoneURLHandler.self) private var phoneURLHandler
    @StateObject private var discovery: BonjourDiscovery
    @StateObject private var pairing: PairingCoordinator
    @StateObject private var settings: BridgeySettings
    private let settingsWindow: SettingsWindowController
    private let callServiceProvider: CallServiceProvider
    private let updater: AppUpdater

    init() {
        LegacyPreferences.migrateIfNeeded()
        let settings = BridgeySettings()
        _settings = StateObject(wrappedValue: settings)
        let discovery = BonjourDiscovery(deviceName: settings.deviceName)
        _discovery = StateObject(wrappedValue: discovery)
        let pairing = PairingCoordinator(deviceID: discovery.localDeviceID, deviceName: discovery.localDeviceName, settings: settings)
        pairing.observe(discovery)
        _pairing = StateObject(wrappedValue: pairing)
        let callServiceProvider = CallServiceProvider { [weak pairing] number in pairing?.sendCallWhenConnected(number) }
        self.callServiceProvider = callServiceProvider
        NSApplication.shared.servicesProvider = callServiceProvider
        let updater = AppUpdater()
        self.updater = updater
        settingsWindow = SettingsWindowController(discovery: discovery, pairing: pairing, settings: settings, updater: updater)
        phoneURLHandler.configure { [weak pairing] number in pairing?.sendCallWhenConnected(number) }
    }

    var body: some Scene {
        MenuBarExtra("Bridgey", systemImage: menuBarSymbol) {
            BridgeyPanel(
                discovery: discovery,
                pairing: pairing,
                settings: settings,
                onOpenSettings: settingsWindow.show
            )
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if case .connected = pairing.state { return "link.circle.fill" }
        return "link.circle"
    }
}
