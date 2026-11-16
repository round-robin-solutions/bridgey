import SwiftUI

@main
struct BridgeyApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        var options = LaunchOptions.current
        let defaults: UserDefaults
        if options.ephemeral || options.demo != nil {
            // A throwaway settings domain: tests and screenshots never touch the real ones.
            let suite = "in.roundrobin.bridgey.ephemeral"
            UserDefaults().removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = SharedStorage.defaults
        }
        let settings = AppSettings(defaults: defaults)
        if options.skipSetup { settings.setupDone = true }
        if let demo = options.demo {
            options.discovery = false
            settings.setupDone = demo != "setup"
            settings.deviceName = "Rahul’s iPhone"
            settings.copyReceivedText = false
        }
        if let appearance = options.appearance { settings.appearance = appearance }
        let factory: ClientFactory
        if options.demo != nil {
            factory = DemoClient.factory
        } else {
            let store: SecretStore = options.ephemeral ? MemorySecretStore() : KeychainStore()
            factory = { core, onEvent in try BridgeyCore.start(core, store: store, onEvent: onEvent) }
        }
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings, options: options, makeClient: factory))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .onChange(of: phase) { _, phase in
                    switch phase {
                    // Before setup has explained Local Network access, nothing touches the network.
                    case .active: if settings.setupDone { model.start() }
                    case .background: model.enterBackground()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var systemReduce

    var body: some View {
        BrandRoot(reduceMotion: settings.reduceMotion) {
            ZStack {
                if settings.setupDone {
                    HomeView()
                        .transition(BrandMotion.forward(reduce: settings.reduceMotion || systemReduce))
                } else {
                    SetupView()
                        .transition(BrandMotion.forward(reduce: settings.reduceMotion || systemReduce))
                }
            }
            .animation(BrandMotion.animation(BrandMotion.page, reduce: settings.reduceMotion || systemReduce), value: settings.setupDone)
        }
        .preferredColorScheme(settings.appearance.scheme)
        .onAppear {
            if let demo = model.options.demo { DemoClient.seed(model, screen: demo) }
        }
    }
}
