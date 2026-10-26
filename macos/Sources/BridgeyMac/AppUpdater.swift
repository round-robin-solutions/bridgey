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

/// Sparkle user driver that draws nothing itself: it turns Sparkle's callbacks into an
/// `UpdateFlow` that Settings and the Stream panel show in the app. Sparkle calls every method
/// on the main thread. Sparkle keeps its own schedule for automatic checks; this only shows them.
@MainActor
final class InAppUpdateDriver: NSObject, SPUUserDriver {
    var onChange: (UpdateFlow) -> Void = { _ in }
    private(set) var flow: UpdateFlow = .idle {
        didSet { if flow != oldValue { onChange(flow) } }
    }

    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var cancelCheck: (() -> Void)?
    private var cancelDownload: (() -> Void)?
    private var retryTerminating: (() -> Void)?
    private var version = ""
    private var expectedLength: UInt64?
    private var receivedLength: UInt64 = 0

    // MARK: Actions from the UI

    func install() {
        if let reply = readyReply {
            readyReply = nil
            flow = .installing(version: version)
            reply(.install)
        } else if let reply = foundReply {
            foundReply = nil
            if case let .available(offer) = flow, offer.downloaded {
                flow = .installing(version: version)
            } else {
                flow = .downloading(version: version, received: 0, expected: nil)
            }
            reply(.install)
        } else if let retry = retryTerminating {
            retryTerminating = nil
            retry()
        }
    }

    /// Later: Sparkle reminds at its next scheduled check. A downloaded update installs on quit.
    func later() {
        if let reply = foundReply {
            foundReply = nil
            reply(.dismiss)
        } else if let reply = readyReply {
            readyReply = nil
            reply(.dismiss)
        }
        flow = .idle
    }

    func skip() {
        guard let reply = foundReply else { return }
        foundReply = nil
        flow = .idle
        reply(.skip)
    }

    func cancel() {
        if let cancel = cancelDownload {
            cancelDownload = nil
            cancel()
        } else if let cancel = cancelCheck {
            cancelCheck = nil
            cancel()
        }
        flow = .idle
    }

    /// Clears a finished message (up to date, or an error).
    func dismissMessage() {
        switch flow {
        case .upToDate, .failed: flow = .idle
        default: break
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist sets SUEnableAutomaticChecks, so Sparkle should never ask. If it does, keep
        // automatic checks on (the user can turn them off in Settings) and send no system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelCheck = cancellation
        flow = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelCheck = nil
        version = appcastItem.displayVersionString
        foundReply = reply
        let notes = appcastItem.itemDescription.flatMap(UpdateFlowText.plainNotes)
        let notesURL = appcastItem.fullReleaseNotesURL.flatMap { $0.scheme == "https" ? $0 : nil }
        flow = .available(UpdateOffer(
            version: version,
            notes: notes,
            downloaded: state.stage != .notDownloaded,
            userInitiated: state.userInitiated,
            notesURL: notesURL
        ))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard case var .available(offer) = flow,
              let text = String(data: downloadData.data, encoding: .utf8).flatMap(UpdateFlowText.plainNotes) else { return }
        offer.notes = text
        flow = .available(offer)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        flow = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        resetReplies()
        flow = .failed(message: UpdateFlowText.errorMessage(domain: nsError.domain, code: nsError.code))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        expectedLength = nil
        receivedLength = 0
        flow = .downloading(version: version, received: 0, expected: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength > 0 ? expectedContentLength : nil
        flow = .downloading(version: version, received: receivedLength, expected: expectedLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        flow = .downloading(version: version, received: receivedLength, expected: expectedLength)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        flow = .extracting(version: version, progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        flow = .extracting(version: version, progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        flow = .ready(version: version)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // Not terminated yet means something (an open sheet) held the quit; Install retries it.
        retryTerminating = applicationTerminated ? nil : retryTerminatingApplication
        flow = .installing(version: version)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        flow = .idle
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        resetReplies()
        switch flow {
        case .upToDate, .failed: break  // keep the message until the user clears it
        default: flow = .idle
        }
    }

    private func resetReplies() {
        foundReply = nil
        readyReply = nil
        cancelCheck = nil
        cancelDownload = nil
        retryTerminating = nil
    }
}

/// Round Robin edition self-update: Sparkle 2 with EdDSA-signed archives, shown in the app.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var channel: UpdateChannel
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var flow: UpdateFlow = .idle
    /// An update put off with Later or Skip, so Settings says what is waiting instead of "Up to date".
    @Published private(set) var deferral: UpdateDeferral?

    /// Sparkle only runs inside a built .app that carries a feed URL (not under `swift run`).
    let isAvailable: Bool
    let versionDescription: String
    let shortVersion: String

    private let defaults: UserDefaults
    private let channelDelegate: UpdateChannelDelegate
    private let driver = InAppUpdateDriver()
    private let updater: SPUUpdater
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        channel = UpdateChannel.stored(in: defaults)
        shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        versionDescription = "\(shortVersion) (\(build))"
        isAvailable = bundle.bundleURL.pathExtension == "app" && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        channelDelegate = UpdateChannelDelegate(defaults: defaults)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: channelDelegate)
        driver.onChange = { [weak self] flow in
            guard let self else { return }
            self.deferral = UpdateDeferral.after(flow, keeping: self.deferral)
            self.flow = flow
        }
        guard isAvailable else { return }
        do {
            try updater.start()
        } catch {
            let nsError = error as NSError
            flow = .failed(message: UpdateFlowText.errorMessage(domain: nsError.domain, code: nsError.code))
            return
        }
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
        if isAvailable { updater.checkForUpdatesInBackground() }
    }

    func setAutomaticallyChecks(_ value: Bool) {
        guard isAvailable else { return }
        updater.automaticallyChecksForUpdates = value
        automaticallyChecks = value
    }

    func checkForUpdates() {
        guard isAvailable, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    var flowActions: UpdateFlowActions {
        UpdateFlowActions(
            install: { [weak self] in self?.install() },
            later: { [weak self] in self?.later() },
            skip: { [weak self] in self?.skip() },
            cancel: { [weak self] in self?.cancel() },
            dismiss: { [weak self] in self?.dismissMessage() },
            checkAgain: { [weak self] in
                self?.dismissMessage()
                self?.checkForUpdates()
            }
        )
    }

    func install() { driver.install() }

    func later() {
        let putOff = UpdateDeferral.putOff(flow, skipped: false)
        driver.later()
        deferral = putOff ?? deferral
    }

    func skip() {
        let putOff = UpdateDeferral.putOff(flow, skipped: true)
        driver.skip()
        deferral = putOff ?? deferral
    }

    func cancel() { driver.cancel() }
    func dismissMessage() { driver.dismissMessage() }
}
