import AppKit
import SwiftUI

struct BridgeyApp: App {
    @NSApplicationDelegateAdaptor(PhoneURLHandler.self) private var phoneURLHandler
    @StateObject private var discovery: BonjourDiscovery
    @StateObject private var pairing: PairingCoordinator
    @StateObject private var settings: BridgeySettings
    /// Observed so the menu-bar icon changes while a phone controls this Mac.
    @StateObject private var remoteInput: RemoteInputHost
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
        IntentHost.pairing = pairing
        _pairing = StateObject(wrappedValue: pairing)
        _remoteInput = StateObject(wrappedValue: pairing.remoteInput)
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
                updater: updater,
                onOpenSettings: settingsWindow.show
            )
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if remoteInput.active != nil { return "cursorarrow.rays" }
        if case .connected = pairing.state { return "link.circle.fill" }
        return "link.circle"
    }
}
