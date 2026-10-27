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
    /// The question path's start: type what you want, or go straight to the questions.
    case intro
    case question(String)
    /// The permission an answer needs, asked right after it.
    case permission(String, SetupPermission)
    /// What was turned on, each with a switch and Change in Settings.
    case summary
    /// The end of the quick path.
    case done
}

enum SetupEvent: Equatable {
    case chooseQuick, chooseAdvanced
    /// Quick path: next, skip, finish now.
    case next, skip, finish
    case back
    /// Intro: start the questions, with the answers confirmed from typed text.
    case startQuestions([String: String])
    case answer(String, String)
    /// "Not now" on a card: keep what is set and move on. On a permission: not allowed.
    case notNow
    /// The permission asked for came back: allowed or not.
    case permissionResult(Bool)
    case summarySwitch(String, Bool)
    /// "Leave setup?": shown, or answered Keep going.
    case askLeave, keepGoing
}

/// What the user chose during setup. Settings sync (settings_sync_draft1, not built yet) is meant
/// to send this to the other device so it can offer the same choices; until then it is only kept
/// on this Mac (`setup.choices`) and handed to `SetupChoicesSink`, which nothing implements yet.
struct SetupChoices: Codable, Equatable {
    var path: SetupPath?
    var skippedPermissions: [SetupPermission] = []
    /// Question id to answer key.
    var answers: [String: String] = [:]
    /// The settings the answers set, by `SetupSetting` raw value.
    var settings: [String: String] = [:]
}

/// The hook for settings sync: called once when setup finishes. Deferred, so nothing sets it.
@MainActor
protocol SetupChoicesSink: AnyObject {
    func setupFinished(with choices: SetupChoices)
}

/// The setup state machine. Pure: it moves between screens and records answers; SetupCenter
/// applies an answer's settings as it is given (`changes(for:)`), so leaving early keeps them and
/// leaves every question not reached as it was (on first run, the defaults).
struct SetupFlow: Equatable {
    private(set) var screen: SetupScreen = .welcome
    private(set) var path: SetupPath?
    /// Where this run started (Welcome, or the Intro for Review setup). Back there leaves.
    private(set) var entry: SetupScreen = .welcome
    /// Permission steps skipped on the quick path (not granted). The Permissions page still offers them.
    private(set) var skipped: Set<SetupPermission> = []
    /// "Pair later" on the quick path.
    private(set) var pairingSkipped = false
    /// Question id to answer key.
    private(set) var answers: [String: String] = [:]
    /// The questions shown so far, in order; Back walks it backwards.
    private(set) var trail: [String] = []
    /// Answers taken from typed text (confirmed); those already applied skip their question.
    private(set) var typed: [String: String] = [:]
    /// Questions whose permission was not allowed: their feature stayed off.
    private(set) var denied: [String: SetupPermission] = [:]
    /// The question whose permission was just refused; the next card says so in one line.
    private(set) var notice: String?
    /// Summary switches turned off.
    private(set) var summaryOff: Set<String> = []
    private(set) var confirmLeave = false

    init() {}

    /// Settings > What's new > Review setup: straight to the questions.
    static func review() -> SetupFlow {
        var flow = SetupFlow()
        flow.screen = .intro
        flow.path = .advanced
        flow.entry = .intro
        return flow
    }

    static let quickSteps = SetupQuickStep.allCases

    /// "1 of 3" on the quick path; nil elsewhere (questions count the steps left instead).
    var position: (index: Int, count: Int)? {
        if case let .quick(step) = screen { return (Self.quickSteps.firstIndex(of: step)! + 1, Self.quickSteps.count) }
        return nil
    }

    var isLastPage: Bool {
        if case let .quick(step) = screen { return step == Self.quickSteps.last }
        return false
    }

    /// Something was chosen, so leaving asks first ("Your choices so far are kept").
    var hasProgress: Bool { !answers.isEmpty }

    var choices: SetupChoices {
        var settings: [String: String] = [:]
        for question in SetupQuestions.all {
            for change in applied(question) { settings[change.setting.rawValue] = change.value }
        }
        return SetupChoices(path: path, skippedPermissions: SetupPermission.allCases.filter { skipped.contains($0) },
                            answers: answers, settings: settings)
    }

    // MARK: Events

    /// The settings an event sets, before `send` moves on (SetupCenter applies them).
    func changes(for event: SetupEvent, facts: SetupFacts) -> [SettingChange] {
        switch (screen, event) {
        case let (.question(current), .answer(id, key)) where current == id:
            return SetupQuestions.question(id).map { SetupQuestions.changes($0, key) } ?? []
        case let (.permission(id, _), .permissionResult(false)), let (.permission(id, _), .notNow):
            guard let question = SetupQuestions.question(id), let key = answers[id] else { return [] }
            return question.answer(key)?.onDenied ?? []
        case let (.intro, .startQuestions(typed)):
            return SetupQuestions.all.flatMap { question -> [SettingChange] in
                guard let key = typed[question.id], !needsPermission(question.id, key, facts) else { return [] }
                return SetupQuestions.changes(question, key)
            }
        case let (_, .summarySwitch(id, on)):
            guard let question = SetupQuestions.question(id), let key = answers[id] else { return [] }
            if on { return SetupQuestions.changes(question, key) }
            return question.offKey.map { SetupQuestions.changes(question, $0) } ?? []
        default:
            return []
        }
    }

    mutating func send(_ event: SetupEvent, facts: SetupFacts = SetupFacts()) {
        switch (screen, event) {
        case (.welcome, .chooseQuick):
            path = .quick
            screen = .quick(Self.quickSteps[0])
        case (.welcome, .chooseAdvanced):
            path = .advanced
            screen = .intro

        case let (.quick(step), .next):
            if let permission = step.permission { skipped.remove(permission) }
            if step == .pairPhone { pairingSkipped = false }
            advance(from: step)
        case let (.quick(step), .skip):
            if let permission = step.permission { skipped.insert(permission) }
            if step == .pairPhone { pairingSkipped = true }
            advance(from: step)
        case (.quick, .finish):
            screen = .done

        case let (.intro, .startQuestions(confirmed)):
            typed = confirmed
            for (id, key) in confirmed where !needsPermission(id, key, facts) { answers[id] = key }
            trail = []
            notice = nil
            advance(after: nil, facts: facts)

        case let (.question(current), .answer(id, key)) where current == id:
            guard let question = SetupQuestions.question(id), let answer = question.answer(key) else { return }
            answers[id] = key
            denied[id] = nil
            summaryOff.remove(id)
            notice = nil
            if let permission = answer.permission, !facts.granted.contains(permission) {
                screen = .permission(id, permission)
            } else {
                advance(after: id, facts: facts)
            }
        case let (.question(id), .notNow):
            notice = nil
            advance(after: id, facts: facts)
        case let (.permission(id, kind), .notNow), let (.permission(id, kind), .permissionResult(false)):
            denied[id] = kind
            notice = id
            advance(after: id, facts: facts)
        case let (.permission(id, _), .permissionResult(true)):
            denied[id] = nil
            notice = nil
            advance(after: id, facts: facts)

        case let (_, .summarySwitch(id, on)):
            if on { summaryOff.remove(id) } else { summaryOff.insert(id) }
        case (_, .askLeave):
            confirmLeave = true
        case (_, .keepGoing):
            confirmLeave = false
        case (_, .back):
            back()
        default:
            break
        }
    }

    /// One step back. Leaving setup from its first screen is `SetupBack`'s decision, not a step.
    private mutating func back() {
        notice = nil
        switch screen {
        case .welcome:
            break
        case let .quick(step):
            let index = Self.quickSteps.firstIndex(of: step)!
            if index == 0 { goToWelcome() } else { screen = .quick(Self.quickSteps[index - 1]) }
        case .intro:
            if entry != .intro { goToWelcome() }
        case .question:
            trail.removeLast()
            if let previous = trail.last { screen = .question(previous) } else { screen = .intro }
        case let .permission(id, _):
            screen = .question(id)
        case .summary:
            screen = trail.last.map(SetupScreen.question) ?? .intro
        case .done:
            screen = .quick(Self.quickSteps.last!)
        }
    }

    private mutating func advance(from step: SetupQuickStep) {
        let index = Self.quickSteps.firstIndex(of: step)!
        screen = index + 1 < Self.quickSteps.count ? .quick(Self.quickSteps[index + 1]) : .done
    }

    private mutating func advance(after id: String?, facts: SetupFacts) {
        if let next = upcoming(after: id, facts: facts).first {
            screen = .question(next)
            trail.append(next)
        } else {
            screen = .summary
        }
    }

    /// Back to the two choices; what was answered so far is kept.
    private mutating func goToWelcome() {
        screen = .welcome
        path = nil
    }

    // MARK: Reading the answers

    private func needsPermission(_ id: String, _ key: String, _ facts: SetupFacts) -> Bool {
        guard let permission = SetupQuestions.question(id)?.answer(key)?.permission else { return false }
        return !facts.granted.contains(permission)
    }

    /// What a question's answer set, after the summary switch and a refused permission.
    private func applied(_ question: SetupQuestion) -> [SettingChange] {
        guard let key = answers[question.id] else { return [] }
        if summaryOff.contains(question.id) { return question.offKey.map { SetupQuestions.changes(question, $0) } ?? [] }
        let base = SetupQuestions.changes(question, key)
        return denied[question.id] == nil ? base : base + (question.answer(key)?.onDenied ?? [])
    }

    /// The settings after the answers so far, over `facts`.
    func effective(_ facts: SetupFacts) -> SetupEffective {
        var effective = SetupEffective(facts: facts)
        for question in SetupQuestions.all {
            for change in applied(question) { effective.overlay[change.setting] = change.value }
        }
        return effective
    }

    /// Every question still to come after `id` (from the start when nil); the progress line counts these.
    func upcoming(after id: String?, facts: SetupFacts) -> [String] {
        let effective = effective(facts)
        let start = id.flatMap(SetupQuestions.index).map { $0 + 1 } ?? 0
        return SetupQuestions.all.dropFirst(start)
            .filter { $0.asks(effective) && !answeredByTyping($0.id) }
            .map(\.id)
    }

    /// Steps left after the current card (0 on the last one).
    func stepsLeft(_ facts: SetupFacts) -> Int {
        switch screen {
        case let .question(id), let .permission(id, _): upcoming(after: id, facts: facts).count
        case .intro: upcoming(after: nil, facts: facts).count
        default: 0
        }
    }

    private func answeredByTyping(_ id: String) -> Bool {
        typed[id] != nil && answers[id] == typed[id] && !trail.contains(id)
    }
}

/// What Escape (and the window's close button) does in setup, the same as Android's system back.
enum SetupBackAction: Equatable {
    /// Go to the previous step.
    case step
    /// Leaving mid-way: ask "Leave setup? Your choices so far are kept." once.
    case askLeave
    /// On the first screen with nothing chosen: leave setup.
    case leave
}

enum SetupBack {
    /// Escape.
    static func decide(_ flow: SetupFlow) -> SetupBackAction {
        if flow.screen != flow.entry { return .step }
        return flow.hasProgress ? .askLeave : .leave
    }

    /// The window's close button: closes at once on the first screen with nothing chosen, and at the end.
    static func closeAsks(_ flow: SetupFlow) -> Bool {
        if flow.screen == .done { return false }
        return flow.screen != flow.entry || flow.hasProgress
    }
}

/// One line of the summary.
enum SetupSummaryItem {
    /// A feature an answer turned on; `on`: its switch now.
    case turnedOn(SetupQuestion, SetupAnswer, on: Bool)
    /// A choice without an off (updates, where folders go, phone photos).
    case chosen(SetupQuestion, SetupAnswer)
    /// Its permission was not allowed, so it stayed off.
    case notAllowed(SetupQuestion, SetupPermission, note: String)

    var question: SetupQuestion {
        switch self {
        case let .turnedOn(question, _, _), let .chosen(question, _), let .notAllowed(question, _, _): question
        }
    }
}

enum SetupSummary {
    static func items(_ flow: SetupFlow) -> [SetupSummaryItem] {
        SetupQuestions.all.compactMap { question in
            guard let key = flow.answers[question.id], let answer = question.answer(key) else { return nil }
            if let permission = flow.denied[question.id], !answer.onDenied.isEmpty {
                return .notAllowed(question, permission, note: SetupQuestions.deniedShort(question, answer: key, permission))
            }
            if answer.turnsOn && question.offKey != nil { return .turnedOn(question, answer, on: !flow.summaryOff.contains(question.id)) }
            if answer.turnsOn || (question.offKey == nil && !answer.changes.isEmpty && key != SetupAnswerKey.no) { return .chosen(question, answer) }
            return nil
        }
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
