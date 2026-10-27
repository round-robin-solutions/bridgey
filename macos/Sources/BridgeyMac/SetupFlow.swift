import Foundation

/*
 * v0.10 setup (onboarding), the pure part: the screens, the state machine that moves between
 * them, the launch decision (setup, the review banner, or nothing) and what setup remembers.
 * The windows that draw it are in SetupWindow.swift. Android has the same machine.
 */

extension L10n {
    /// Setup, permissions, reset and What's new text: the `Setup` table (en.lproj/Setup.strings,
    /// ru.lproj/Setup.strings), kept apart from Localizable.strings so branches do not collide.
    static func setup(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, tableName: "Setup", bundle: .main, value: fallback, comment: "")
    }
}

/// The advanced path: one page per settings group, in the Settings order.
enum SetupGroup: String, CaseIterable, Identifiable, Codable {
    case devices, clipboard, notifications, calls, files, media, remoteControl, privacy, updates, general

    var id: String { rawValue }

    /// The Settings page the group shows (the real one, so changes apply at once).
    var pane: SettingsPane {
        switch self {
        case .devices: .devices
        case .clipboard: .clipboard
        case .notifications: .notifications
        case .calls: .calls
        case .files: .files
        case .media: .media
        case .remoteControl: .remoteControl
        case .privacy: .privacy
        case .updates: .updates
        case .general: .general
        }
    }

    var title: String {
        switch self {
        case .devices: L10n.setup("setup.group.devices", fallback: "Devices")
        case .clipboard: L10n.setup("setup.group.clipboard", fallback: "Clipboard")
        case .notifications: L10n.setup("setup.group.notifications", fallback: "Notifications")
        case .calls: L10n.setup("setup.group.calls", fallback: "Calls")
        case .files: L10n.setup("setup.group.files", fallback: "Files")
        case .media: L10n.setup("setup.group.media", fallback: "Media and actions")
        case .remoteControl: L10n.setup("setup.group.remoteControl", fallback: "Remote control")
        case .privacy: L10n.setup("setup.group.privacy", fallback: "Privacy and Logging")
        case .updates: L10n.setup("setup.group.updates", fallback: "Updates")
        case .general: L10n.setup("setup.group.general", fallback: "General")
        }
    }

    /// One line above the group's settings.
    var intro: String {
        switch self {
        case .devices: L10n.setup("setup.group.devices.intro", fallback: "Pair a phone, choose what this Mac shares with each one, and its battery alerts.")
        case .clipboard: L10n.setup("setup.group.clipboard.intro", fallback: "Copy on one device and paste on the other.")
        case .notifications: L10n.setup("setup.group.notifications.intro", fallback: "Your phone\u{2019}s notifications on this Mac, including codes from messages and duplicates, and Focus with your phones.")
        case .calls: L10n.setup("setup.group.calls.intro", fallback: "See, answer and start phone calls from this Mac.")
        case .files: L10n.setup("setup.group.files.intro", fallback: "Where received files go, what folders include when you send them, and photos from the phone camera.")
        case .media: L10n.setup("setup.group.media.intro", fallback: "Control this Mac\u{2019}s music from the phone, the quick actions, and what a phone you allow may do on this Mac.")
        case .remoteControl: L10n.setup("setup.group.remoteControl.intro", fallback: "Let a phone you allow move the pointer and type. Off until you turn it on.")
        case .privacy: L10n.setup("setup.group.privacy.intro", fallback: "What Bridgey keeps on this Mac, and what goes into its logs.")
        case .updates: L10n.setup("setup.group.updates.intro", fallback: "Which releases this Mac gets, and when it checks.")
        case .general: L10n.setup("setup.group.general.intro", fallback: "Launch at login, motion and keyboard shortcuts.")
        }
    }

    var symbol: String { pane.symbol }
}

/// The quick path on the Mac: Local Network, Notifications, Pair a phone, then Done.
enum SetupQuickStep: String, CaseIterable, Codable {
    case localNetwork, notifications, pairPhone

    /// The permission the step asks for; Pair a phone asks for none.
    var permission: SetupPermission? {
        switch self {
        case .localNetwork: .localNetwork
        case .notifications: .notifications
        case .pairPhone: nil
        }
    }
}

enum SetupPath: String, Codable {
    case quick, advanced
}

enum SetupScreen: Equatable {
    case welcome
    case quick(SetupQuickStep)
    case advanced(SetupGroup)
    case done
}

enum SetupEvent: Equatable {
    case chooseQuick, chooseAdvanced, next, back, skip, finish
    case jump(SetupGroup)
}

/// What the user chose during setup. Settings sync (settings_sync_draft1, not built yet) is meant
/// to send this to the other device so it can offer the same choices; until then it is only kept
/// on this Mac (`setup.choices`) and handed to `SetupChoicesSink`, which nothing implements yet.
struct SetupChoices: Codable, Equatable {
    var path: SetupPath?
    var visitedGroups: [SetupGroup] = []
    var skippedPermissions: [SetupPermission] = []
    /// Feature switches changed on setup pages, by `BridgeyFeature` raw value.
    var changedFeatures: [String: Bool] = [:]
}

/// The hook for settings sync: called once when setup finishes. Deferred, so nothing sets it.
@MainActor
protocol SetupChoicesSink: AnyObject {
    func setupFinished(with choices: SetupChoices)
}

/// The setup state machine. Pure: it moves between screens and records what was visited and
/// skipped. Settings changed on a page are applied by the page itself, so finishing early leaves
/// every group that was not visited exactly as it was (on first run, the defaults).
struct SetupFlow: Equatable {
    private(set) var screen: SetupScreen
    private(set) var path: SetupPath?
    /// Advanced groups opened, in the order first opened.
    private(set) var visited: [SetupGroup] = []
    /// Permission steps skipped (not granted). The Permissions page still offers them.
    private(set) var skipped: Set<SetupPermission> = []
    /// "Pair later" on the quick path.
    private(set) var pairingSkipped = false
    private(set) var changedFeatures: [String: Bool] = [:]
    /// The screen Back from Done returns to.
    private var beforeDone: SetupScreen?

    init(start: SetupScreen = .welcome) {
        screen = .welcome
        switch start {
        case .welcome: break
        case let .quick(step):
            path = .quick
            screen = .quick(step)
        case let .advanced(group):
            path = .advanced
            open(group)
        case .done:
            screen = .done
        }
    }

    static let quickSteps = SetupQuickStep.allCases
    static let groups = SetupGroup.allCases

    var unvisitedGroups: [SetupGroup] { Self.groups.filter { !visited.contains($0) } }

    /// "3 of 10" on the advanced path, "1 of 3" on the quick path; nil on Welcome and Done.
    var position: (index: Int, count: Int)? {
        switch screen {
        case let .quick(step): (Self.quickSteps.firstIndex(of: step)! + 1, Self.quickSteps.count)
        case let .advanced(group): (Self.groups.firstIndex(of: group)! + 1, Self.groups.count)
        case .welcome, .done: nil
        }
    }

    var isLastPage: Bool {
        switch screen {
        case let .quick(step): step == Self.quickSteps.last
        case let .advanced(group): group == Self.groups.last
        default: false
        }
    }

    var choices: SetupChoices {
        SetupChoices(path: path, visitedGroups: visited,
                     skippedPermissions: SetupPermission.allCases.filter { skipped.contains($0) },
                     changedFeatures: changedFeatures)
    }

    mutating func send(_ event: SetupEvent) {
        switch (screen, event) {
        case (.welcome, .chooseQuick):
            path = .quick
            screen = .quick(Self.quickSteps[0])
        case (.welcome, .chooseAdvanced):
            path = .advanced
            open(Self.groups[0])

        case let (.quick(step), .next):
            if let permission = step.permission { skipped.remove(permission) }
            if step == .pairPhone { pairingSkipped = false }
            advance(from: step)
        case let (.quick(step), .skip):
            if let permission = step.permission { skipped.insert(permission) }
            if step == .pairPhone { pairingSkipped = true }
            advance(from: step)
        case let (.quick(step), .back):
            let index = Self.quickSteps.firstIndex(of: step)!
            if index == 0 { goToWelcome() } else { screen = .quick(Self.quickSteps[index - 1]) }
        case (.quick, .finish):
            finish()

        case let (.advanced(group), .next), let (.advanced(group), .skip):
            let index = Self.groups.firstIndex(of: group)!
            if index + 1 < Self.groups.count { open(Self.groups[index + 1]) } else { finish() }
        case let (.advanced(group), .back):
            let index = Self.groups.firstIndex(of: group)!
            if index == 0 { goToWelcome() } else { open(Self.groups[index - 1]) }
        case let (.advanced, .jump(group)):
            open(group)
        case (.advanced, .finish):
            finish()

        case (.done, .back):
            screen = beforeDone ?? .welcome
        default:
            break
        }
    }

    /// A feature switch changed on a setup page (for `SetupChoices`).
    mutating func recordFeature(_ feature: String, enabled: Bool) {
        changedFeatures[feature] = enabled
    }

    private mutating func advance(from step: SetupQuickStep) {
        let index = Self.quickSteps.firstIndex(of: step)!
        if index + 1 < Self.quickSteps.count { screen = .quick(Self.quickSteps[index + 1]) } else { finish() }
    }

    private mutating func open(_ group: SetupGroup) {
        if !visited.contains(group) { visited.append(group) }
        screen = .advanced(group)
    }

    private mutating func finish() {
        beforeDone = screen
        screen = .done
    }

    /// Back to the two choices; what was visited and skipped so far is kept.
    private mutating func goToWelcome() {
        screen = .welcome
        path = nil
    }
}

// MARK: - Launch

/// What the app shows at launch about setup.
enum SetupLaunchDecision: Equatable {
    /// A fresh install (or a reset): the setup window.
    case runSetup
    /// An existing user from a version before this setup: the once-only review banner.
    case offerReview
    case none
}

enum SetupLaunch {
    /// The setup this build has. A later redesign can raise it to offer the review again.
    static let currentVersion = 1

    /// Keys that only exist after Bridgey has run before (settings, this Mac's ID, addresses).
    static let storedStatePrefixes = ["settings.", "updates.channel", "media.", "shortcuts.", "folders.", "deviceID", "reconnect.", "trusted"]

    static func decide(setupVersionSeen: Int, setupPending: Bool, onboardingCompleted: Bool, hasStoredState: Bool) -> SetupLaunchDecision {
        if setupPending { return .runSetup }
        if setupVersionSeen >= currentVersion { return .none }
        if onboardingCompleted || hasStoredState { return .offerReview }
        return .runSetup
    }

    static func hasStoredState(keys: some Sequence<String>, trustFileExists: Bool) -> Bool {
        trustFileExists || keys.contains { key in storedStatePrefixes.contains { key.hasPrefix($0) } }
    }

    /// Reads the decision from `defaults`. Call before anything writes settings at launch
    /// (BridgeySettings settles a key on every start), and record a fresh install as pending.
    static func evaluate(_ store: SetupStore, trustFileExists: Bool) -> SetupLaunchDecision {
        let decision = decide(
            setupVersionSeen: store.completedVersion,
            setupPending: store.pending,
            onboardingCompleted: store.defaults.bool(forKey: SetupStore.legacyOnboardingKey),
            hasStoredState: hasStoredState(keys: store.defaults.dictionaryRepresentation().keys, trustFileExists: trustFileExists)
        )
        // A fresh setup closed half way runs again next launch, even though settings exist by then.
        if decision == .runSetup { store.pending = true }
        return decision
    }
}

// MARK: - What setup remembers

/// Setup's own UserDefaults keys (all under `setup.`; Settings > Reset > Settings clears them).
struct SetupStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let completedVersionKey = "setup.completedVersion"
    static let pendingKey = "setup.pending"
    static let explainedKey = "setup.permissions.explained"
    static let skippedKey = "setup.permissions.skipped"
    static let choicesKey = "setup.choices"
    static let automationPrefix = "setup.automation."
    /// The first-run hint from before v0.10 (BridgeySettings.hasCompletedOnboarding).
    static let legacyOnboardingKey = "settings.onboarding.completed"

    var completedVersion: Int { defaults.integer(forKey: Self.completedVersionKey) }

    var pending: Bool {
        get { defaults.bool(forKey: Self.pendingKey) }
        nonmutating set {
            if newValue { defaults.set(true, forKey: Self.pendingKey) } else { defaults.removeObject(forKey: Self.pendingKey) }
        }
    }

    /// The review banner was opened or dismissed, or setup finished: never offered again.
    func markSetupSeen() {
        defaults.set(SetupLaunch.currentVersion, forKey: Self.completedVersionKey)
        pending = false
    }

    func finish(_ choices: SetupChoices) {
        markSetupSeen()
        defaults.set(true, forKey: Self.legacyOnboardingKey)
        defaults.set(choices.skippedPermissions.map(\.rawValue), forKey: Self.skippedKey)
        if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: Self.choicesKey) }
    }

    var choices: SetupChoices? {
        defaults.data(forKey: Self.choicesKey).flatMap { try? JSONDecoder().decode(SetupChoices.self, from: $0) }
    }

    var explained: Set<SetupPermission> {
        Set((defaults.stringArray(forKey: Self.explainedKey) ?? []).compactMap(SetupPermission.init(rawValue:)))
    }

    func wasExplained(_ permission: SetupPermission) -> Bool { explained.contains(permission) }

    func markExplained(_ permission: SetupPermission) {
        var set = explained
        set.insert(permission)
        defaults.set(SetupPermission.allCases.filter { set.contains($0) }.map(\.rawValue), forKey: Self.explainedKey)
    }

    var skipped: Set<SetupPermission> {
        Set((defaults.stringArray(forKey: Self.skippedKey) ?? []).compactMap(SetupPermission.init(rawValue:)))
    }

    /// The last Automation answer seen for a player, for when the player is not running.
    func lastAutomation(_ bundleID: String) -> PermissionSystemState? {
        switch defaults.string(forKey: Self.automationPrefix + bundleID) {
        case "allowed": .allowed
        case "denied": .denied
        default: nil
        }
    }

    func rememberAutomation(_ state: PermissionSystemState, for bundleID: String) {
        switch state {
        case .allowed: defaults.set("allowed", forKey: Self.automationPrefix + bundleID)
        case .denied: defaults.set("denied", forKey: Self.automationPrefix + bundleID)
        default: break
        }
    }
}
