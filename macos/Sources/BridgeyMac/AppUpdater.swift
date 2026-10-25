import Combine
import Foundation
import Sparkle

/// Supplies the user's channel to Sparkle. Reads UserDefaults on each call so it
/// is safe on whatever thread Sparkle asks from.
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.stored(in: defaults).sparkleChannels
    }
}

/// Lets Sparkle show its own update window, gently for a menu bar app.
final class UpdateUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }
}

/// Round Robin edition self-update: Sparkle 2 with EdDSA-signed archives.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var channel: UpdateChannel
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var automaticallyChecks = false

    /// Sparkle only runs inside a built .app that carries a feed URL (not under `swift run`).
    let isAvailable: Bool
    let versionDescription: String

    private let defaults: UserDefaults
    private let channelDelegate: UpdateChannelDelegate
    private let userDriverDelegate = UpdateUserDriverDelegate()
    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        channel = UpdateChannel.stored(in: defaults)
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        versionDescription = "\(shortVersion) (\(build))"
        isAvailable = bundle.bundleURL.pathExtension == "app" && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        channelDelegate = UpdateChannelDelegate(defaults: defaults)
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: channelDelegate,
            userDriverDelegate: userDriverDelegate
        )
        guard isAvailable else { return }
        controller.startUpdater()
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastCheck = $0 }
            .store(in: &cancellables)
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    func setChannel(_ value: UpdateChannel) {
        guard value != channel else { return }
        defaults.set(value.rawValue, forKey: UpdateChannel.defaultsKey)
        channel = value
        // Sparkle never offers an older build, so a more stable channel waits for its next newer build.
        if isAvailable { controller.updater.checkForUpdatesInBackground() }
    }

    func setAutomaticallyChecks(_ value: Bool) {
        guard isAvailable else { return }
        controller.updater.automaticallyChecksForUpdates = value
        automaticallyChecks = value
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }
}
