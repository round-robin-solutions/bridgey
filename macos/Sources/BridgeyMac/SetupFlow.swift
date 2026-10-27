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
    /// The question path's start: bundles, type what you want, or straight on.
    case intro
    case question(String)
    /// One line per feature that was not picked: plain switches.
    case switches
    /// Every permission the chosen features need, on one page.
    case permissions
    /// What is on, what was not allowed, each with Change in Settings.
    case summary
    /// The end of the quick path.
    case done

    fileprivate var code: String {
        switch self {
        case .welcome: "welcome"
        case let .quick(step): "quick:\(step.rawValue)"
        case .intro: "intro"
        case let .question(id): "question:\(id)"
        case .switches: "switches"
        case .permissions: "permissions"
        case .summary: "summary"
        case .done: "done"
        }
    }

    fileprivate init?(code: String) {
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "welcome": self = .welcome
        case "quick": guard parts.count == 2, let step = SetupQuickStep(rawValue: parts[1]) else { return nil }; self = .quick(step)
        case "intro": self = .intro
        case "question": guard parts.count == 2, SetupQuestions.question(parts[1]) != nil else { return nil }; self = .question(parts[1])
        case "switches": self = .switches
        case "permissions": self = .permissions
        case "summary": self = .summary
        case "done": self = .done
        default: return nil
        }
    }
}

enum SetupEvent: Equatable {
    case chooseQuick, chooseAdvanced
    /// Quick path: next, skip, finish now.
    case next, skip, finish
    case back
    /// Intro: start, with what was picked and typed (confirmed), keyed by feature or follow-up id:
    /// `pick` picks a feature, `no` leaves it off, other keys answer a follow-up.
    case startQuestions([String: String])
    case answer(String, String)
    /// "Not now" on a follow-up: keep what is set and move on.
    case notNow
    /// The switches page: one feature on or off.
    case setSwitch(String, Bool)
    /// The permissions page asked macOS (or opened System Settings) for these.
    case asked(Set<SetupPermission>)
    /// Continue on the switches or permissions page (it works whatever the permissions say).
    case proceed
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
    /// Features picked at the start.
    var picked: [String] = []
    /// Follow-up and typed id to answer key.
    var answers: [String: String] = [:]
    /// The settings this run set, by `SetupSetting` raw value.
    var settings: [String: String] = [:]
}

/// The hook for settings sync: called once when setup finishes. Deferred, so nothing sets it.
@MainActor
protocol SetupChoicesSink: AnyObject {
    func setupFinished(with choices: SetupChoices)
}

/// The setup state machine. Pure: it moves between screens and records picks, answers and
/// switches; SetupCenter applies what an event sets as it is given (`changes(for:facts:)`), so
/// leaving early keeps it and leaves every feature not chosen as it was (on a fresh install, off).
///
/// The question path: Intro, Pair (when no phone is paired), a follow-up only for the features
/// picked or typed, Switches (one line per other feature), Permissions (one page for everything
/// the chosen features need), Summary.
struct SetupFlow: Equatable {
    private(set) var screen: SetupScreen = .welcome
    private(set) var path: SetupPath?
    /// Where this run started (Welcome, or the Intro for Review setup). Back there leaves.
    private(set) var entry: SetupScreen = .welcome
    /// Permission steps skipped on the quick path (not granted). The Permissions page still offers them.
    private(set) var skipped: Set<SetupPermission> = []
    /// "Pair later" on the quick path.
    private(set) var pairingSkipped = false
    /// Features picked at the start (bundles or typed), in the order picked.
    private(set) var picked: [String] = []
    /// Follow-up and typed answers: id to answer key.
    private(set) var answers: [String: String] = [:]
    /// Answers given at the start: their follow-ups are not asked.
    private(set) var typed: Set<String> = []
    /// The switches page, and features typed with a no.
    private(set) var switches: [String: Bool] = [:]
    /// The screens shown after the start, in order; Back walks it backwards.
    private(set) var trail: [SetupScreen] = []
    /// Permissions asked for on the permissions page during this run.
    private(set) var asked: Set<SetupPermission> = []
    /// Permissions still refused when the permissions page was left: their features stay off.
    private(set) var refused: Set<SetupPermission> = []
    /// Features switched off on the summary.
    private(set) var summaryOff: Set<String> = []
    private(set) var confirmLeave = false

    init() {}

    /// Settings > What's new > Review setup: straight to the start of the questions.
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
    var hasProgress: Bool { !picked.isEmpty || !answers.isEmpty || !switches.isEmpty }

    var choices: SetupChoices {
        var settings: [String: String] = [:]
        for (setting, value) in overlay() { settings[setting.rawValue] = value }
        return SetupChoices(path: path, skippedPermissions: SetupPermission.allCases.filter { skipped.contains($0) },
                            picked: picked, answers: answers, settings: settings)
    }

    // MARK: Events

    /// The settings an event sets, before `send` moves on (SetupCenter applies them).
    func changes(for event: SetupEvent, facts: SetupFacts) -> [SettingChange] {
        switch (screen, event) {
        case (.welcome, .chooseQuick):
            return SetupBundles.essentialChanges(effective(facts))
        case let (.intro, .startQuestions(chosen)):
            var started = self
            started.start(chosen)
            return started.overlayChanges()
        case let (.question(current), .answer(id, key)) where current == id:
            return SetupQuestions.question(id).map { SetupQuestions.changes($0, key) } ?? []
        case let (.switches, .setSwitch(id, on)):
            return SetupFeatures.feature(id).map { on ? $0.on : $0.off } ?? []
        case (.permissions, .proceed):
            return neededPermissions(facts).filter { !facts.granted.contains($0.permission) }.flatMap(\.offWhenRefused)
        case let (_, .summarySwitch(id, on)):
            return SetupFeatures.feature(id).map { on ? $0.on : $0.off } ?? []
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

        case let (.intro, .startQuestions(chosen)):
            start(chosen)
            advance(facts)
        case let (.question(current), .answer(id, key)) where current == id:
            guard let question = SetupQuestions.question(id), question.answer(key) != nil else { return }
            answers[id] = key
            advance(facts)
        case (.question, .notNow):
            advance(facts)
        case let (.switches, .setSwitch(id, on)):
            if SetupFeatures.feature(id) != nil { switches[id] = on }
        case let (_, .asked(permissions)):
            asked.formUnion(permissions)
        case (.switches, .proceed):
            advance(facts)
        case (.permissions, .proceed):
            // Refused or skipped: those features stay off, and setup goes on.
            refused = Set(neededPermissions(facts).map(\.permission).filter { !facts.granted.contains($0) })
            advance(facts)

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

    /// The start's picks and typed answers, as state.
    private mutating func start(_ chosen: [String: String]) {
        picked = []
        switches = [:]
        answers = [:]
        for (id, key) in chosen.sorted(by: { Self.order($0.key) < Self.order($1.key) }) {
            let feature = SetupFeatures.feature(id)
            if feature != nil, key == SetupAnswerKey.no {
                switches[id] = false
            } else if feature != nil, key == SetupAnswerKey.pick {
                if !picked.contains(id) { picked.append(id) }
            } else if let question = SetupQuestions.question(id), question.answer(key) != nil {
                answers[id] = key
                if let owner = question.feature, key != SetupAnswerKey.no, !picked.contains(owner) { picked.append(owner) }
            } else if SetupQuestions.typedOnly[id]?[key] != nil {
                answers[id] = key
            } else if feature != nil {
                if !picked.contains(id) { picked.append(id) }
            }
        }
        typed = Set(answers.keys)
        trail = []
        asked = []
        refused = []
    }

    /// Ids in a stable order: the features, then the follow-ups, then the rest.
    private static func order(_ id: String) -> Int {
        if let index = SetupFeatures.all.firstIndex(where: { $0.id == id }) { return index }
        if let index = SetupQuestions.index(id) { return 100 + index }
        return 200
    }

    /// One step back. Leaving setup from its first screen is `SetupBack`'s decision, not a step.
    private mutating func back() {
        switch screen {
        case .welcome:
            break
        case let .quick(step):
            let index = Self.quickSteps.firstIndex(of: step)!
            if index == 0 { goToWelcome() } else { screen = .quick(Self.quickSteps[index - 1]) }
        case .intro:
            if entry != .intro { goToWelcome() }
        case .question, .switches, .permissions, .summary:
            if !trail.isEmpty { trail.removeLast() }
            screen = trail.last ?? .intro
        case .done:
            screen = .quick(Self.quickSteps.last!)
        }
    }

    private mutating func advance(from step: SetupQuickStep) {
        let index = Self.quickSteps.firstIndex(of: step)!
        screen = index + 1 < Self.quickSteps.count ? .quick(Self.quickSteps[index + 1]) : .done
    }

    private mutating func advance(_ facts: SetupFacts) {
        let next = nextScreen(after: screen, facts: facts)
        screen = next
        trail.append(next)
    }

    /// Back to the two choices; what was chosen so far is kept.
    private mutating func goToWelcome() {
        screen = .welcome
        path = nil
    }

    // MARK: The path

    /// What comes after `after` on the question path.
    func nextScreen(after: SetupScreen, facts: SetupFacts) -> SetupScreen {
        switch after {
        case .intro:
            return followUps(after: nil, facts: facts).first.map(SetupScreen.question) ?? .switches
        case let .question(id):
            return followUps(after: id, facts: facts).first.map(SetupScreen.question) ?? .switches
        case .switches:
            return permissionsPage(facts) ? .permissions : .summary
        default:
            return .summary
        }
    }

    /// The follow-ups still to come after `id` (from the start when nil).
    func followUps(after id: String?, facts: SetupFacts) -> [String] {
        let effective = effective(facts)
        let start = id.flatMap(SetupQuestions.index).map { $0 + 1 } ?? 0
        return SetupQuestions.all.dropFirst(start)
            .filter { question in
                (question.feature.map(picked.contains) ?? true) && !typed.contains(question.id) && question.asks(effective)
            }
            .map(\.id)
    }

    /// The permissions the features now on need.
    func neededPermissions(_ facts: SetupFacts) -> [SetupPermissionNeed] {
        var unrefused = self
        unrefused.refused = []
        let effective = unrefused.effective(facts)
        return SetupQuestions.permissions.filter { $0.needed(effective) }
    }

    /// The permissions page shows when something needed is not allowed yet.
    func permissionsPage(_ facts: SetupFacts) -> Bool {
        neededPermissions(facts).contains { !facts.allowed.contains($0.permission) }
    }

    /// Steps left after the current card, the summary not counted; from the path as it is now.
    func stepsLeft(_ facts: SetupFacts) -> Int {
        let permissions = permissionsPage(facts) ? 1 : 0
        switch screen {
        case .intro: return followUps(after: nil, facts: facts).count + 1 + permissions
        case let .question(id): return followUps(after: id, facts: facts).count + 1 + permissions
        case .switches: return permissions
        default: return 0
        }
    }

    /// The Intro's count, as if `chosen` were confirmed now.
    func stepsLeft(ifStarted chosen: [String: String], facts: SetupFacts) -> Int {
        var started = self
        started.start(chosen)
        return started.stepsLeft(facts)
    }

    /// Steps on the whole path, the Intro and the summary counted (for the report and tests).
    func pathLength(_ facts: SetupFacts) -> Int {
        1 + followUps(after: nil, facts: facts).count + 1 + (permissionsPage(facts) ? 1 : 0) + 1
    }

    // MARK: Reading the choices

    /// The settings this run changes: picks, answers, switches, refusals and summary switches, in that order.
    func overlay() -> [SetupSetting: String] {
        var overlay: [SetupSetting: String] = [:]
        func put(_ changes: [SettingChange]) { for change in changes { overlay[change.setting] = change.value } }
        for id in picked { SetupFeatures.feature(id).map { put($0.on) } }
        for question in SetupQuestions.all { if let key = answers[question.id] { put(SetupQuestions.changes(question, key)) } }
        for (id, options) in SetupQuestions.typedOnly.sorted(by: { $0.key < $1.key }) { if let key = answers[id], let changes = options[key] { put(changes) } }
        for feature in SetupFeatures.all { if let on = switches[feature.id] { put(on ? feature.on : feature.off) } }
        for need in SetupQuestions.permissions where refused.contains(need.permission) { put(need.offWhenRefused) }
        for feature in SetupFeatures.all where summaryOff.contains(feature.id) { put(feature.off) }
        return overlay
    }

    /// The overlay as changes, in a stable order.
    func overlayChanges() -> [SettingChange] {
        overlay().map { SettingChange(setting: $0.key, value: $0.value) }.sorted { $0.setting.rawValue < $1.setting.rawValue }
    }

    /// The settings after this run's changes, over `facts`.
    func effective(_ facts: SetupFacts) -> SetupEffective {
        var effective = SetupEffective(facts: facts)
        effective.overlay = overlay()
        return effective
    }

    // MARK: Saving (the window can close and the app quit part way)

    private struct Saved: Codable {
        var screen, entry: String
        var path: SetupPath?
        var picked: [String]
        var answers: [String: String]
        var typed: [String]
        var switches: [String: Bool]
        var trail: [String]
        var asked, refused: [SetupPermission]
        var summaryOff: [String]
        var confirmLeave: Bool
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(Saved(screen: screen.code, entry: entry.code, path: path, picked: picked, answers: answers,
                                        typed: typed.sorted(), switches: switches, trail: trail.map(\.code),
                                        asked: asked.sorted { $0.rawValue < $1.rawValue }, refused: refused.sorted { $0.rawValue < $1.rawValue },
                                        summaryOff: summaryOff.sorted(), confirmLeave: confirmLeave))
    }

    static func decode(_ data: Data?) -> SetupFlow? {
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data),
              let screen = SetupScreen(code: saved.screen), let entry = SetupScreen(code: saved.entry) else { return nil }
        var trail: [SetupScreen] = []
        for code in saved.trail {
            guard let step = SetupScreen(code: code) else { return nil }
            trail.append(step)
        }
        var flow = SetupFlow()
        flow.screen = screen
        flow.entry = entry
        flow.path = saved.path
        flow.picked = saved.picked
        flow.answers = saved.answers
        flow.typed = Set(saved.typed)
        flow.switches = saved.switches
        flow.trail = trail
        flow.asked = Set(saved.asked)
        flow.refused = Set(saved.refused)
        flow.summaryOff = Set(saved.summaryOff)
        flow.confirmLeave = saved.confirmLeave
        return flow
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
    /// A feature that is on; `on`: its switch now; `detail`: the follow-up answer, if any.
    case featureOn(SetupFeature, on: Bool, detail: String?)
    /// A choice without an off: Focus, the update channel.
    case chosen(title: String, value: String, pane: SettingsPane)
    /// Not allowed when the permissions page was left: its features stayed off.
    case notAllowed(SetupPermissionNeed)
}

enum SetupSummary {
    static func items(_ flow: SetupFlow, facts: SetupFacts = SetupFacts()) -> [SetupSummaryItem] {
        var unswitched = flow
        unswitched.clearSummarySwitches()
        let effective = unswitched.effective(facts)
        var items: [SetupSummaryItem] = SetupFeatures.all.filter { SetupFeatures.isOn($0, effective) }.map { feature in
            let detail = SetupQuestions.all.first { $0.feature == feature.id && flow.answers[$0.id] != nil }
                .flatMap { question in flow.answers[question.id].flatMap { question.answer($0)?.label } }
            return .featureOn(feature, on: !flow.summaryOff.contains(feature.id), detail: detail)
        }
        for id in SetupQuestions.typedOnly.keys.sorted() {
            if let key = flow.answers[id], let label = SetupQuestions.typedOnlyLabel(id, key) {
                items.append(.chosen(title: label.title, value: label.value, pane: label.pane))
            }
        }
        for need in SetupQuestions.permissions where flow.refused.contains(need.permission) { items.append(.notAllowed(need)) }
        return items
    }
}

extension SetupFlow {
    /// The summary lists features as they were before its own switches.
    fileprivate mutating func clearSummarySwitches() { summaryOff = [] }
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
    /// The setup in progress, so closing the window or quitting part way comes back to the same step.
    static let flowKey = "setup.flow"
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

    var savedFlow: SetupFlow? {
        get { SetupFlow.decode(defaults.data(forKey: Self.flowKey)) }
        nonmutating set {
            if let data = newValue?.encoded() { defaults.set(data, forKey: Self.flowKey) } else { defaults.removeObject(forKey: Self.flowKey) }
        }
    }

    func finish(_ choices: SetupChoices) {
        markSetupSeen()
        savedFlow = nil
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
