import AppIntents
import Foundation
import SwiftUI

/*
 * Focus and Do Not Disturb sync, draft `focus_sync_draft1` (docs/protocol.md; what macOS allows
 * is in docs/automation.md). Both directions are off by default.
 * - Mac to phone ("Share Focus with phones"): macOS has no public way to read the Focus without
 *   the Communication Notifications entitlement, which needs a paid developer account. Bridgey
 *   learns it from its Focus filter (added to a Focus in System Settings > Focus) or from the
 *   "Share Focus with Phones" Shortcuts action, for example in a Focus automation.
 * - Phone to Mac ("Follow the phone's Do Not Disturb"): macOS has no public way to set a Focus
 *   either, so Bridgey runs a Shortcut the person chose for on and one for off (the Shortcuts app's
 *   own "Set Focus" action does the work).
 */

let focusSyncFeatureKey = "focus_sync_draft1"

struct FocusSyncSettings: Codable, Equatable {
    var share = false
    var follow = false
    var onShortcut: String?
    var offShortcut: String?
}

@MainActor
final class FocusSync: ObservableObject {
    static let echoWindow: TimeInterval = 10

    @Published private(set) var settings: FocusSyncSettings
    /// The Mac's Focus as last reported by the filter or the Shortcuts action; nil until then.
    @Published private(set) var localActive: Bool?
    /// What Bridgey last asked the Mac's Focus to be, following the phones.
    @Published private(set) var applied: Bool?

    /// Sends `focus.state` to every phone that understands it.
    var broadcast: (Bool) -> Void = { _ in }
    /// Runs a Shortcut by name; tests replace it.
    var runShortcut: (String) -> Void = { name in
        DispatchQueue.global(qos: .userInitiated).async { _ = ShortcutsCLI.run(name, timeout: 60) }
    }
    var onSettingsChange: () -> Void = {}

    private let defaults: UserDefaults?
    private let clock: () -> Date
    private var phoneStates: [String: Bool] = [:]
    private var suppressUntil = Date.distantPast

    init(defaults: UserDefaults? = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        settings = defaults?.data(forKey: "settings.focusSync").flatMap { try? JSONDecoder().decode(FocusSyncSettings.self, from: $0) } ?? FocusSyncSettings()
    }

    /// This Mac advertises `focus_sync_draft1` while either direction is on.
    var advertised: Bool { settings.share || settings.follow }

    func update(_ change: (inout FocusSyncSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let wasFollowing = settings.follow
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults?.set(data, forKey: "settings.focusSync") }
        if wasFollowing && !next.follow {
            // Hand the Focus back: undo what Bridgey turned on.
            if applied == true, let off = next.offShortcut { runShortcut(off) }
            applied = nil
            phoneStates.removeAll()
        }
        onSettingsChange()
        if next.share, let localActive { broadcast(localActive) }
    }

    /// The Focus filter or the Shortcuts action reported the Mac's Focus.
    func localFocusChanged(_ active: Bool) {
        let changed = localActive != active
        localActive = active
        guard settings.share, changed, clock() >= suppressUntil else { return }
        broadcast(active)
    }

    /// What to send a phone right after its features.update: the current state, if sharing and known.
    var stateForNewPhone: Bool? { settings.share ? localActive : nil }

    /// `focus.state` from a phone.
    func received(active: Bool, from deviceID: String) {
        guard settings.follow else { return }
        phoneStates[deviceID] = active
        let want = phoneStates.values.contains(true)
        guard want != applied else { return }
        guard let name = want ? settings.onShortcut : settings.offShortcut else { return }
        applied = want
        // The Focus filter will fire for our own change: do not send it back to the phones.
        suppressUntil = clock().addingTimeInterval(Self.echoWindow)
        localActive = want
        runShortcut(name)
    }

    func forget(_ deviceID: String) {
        phoneStates.removeValue(forKey: deviceID)
    }
}

// MARK: - Focus filter and Shortcuts action

/// System Settings > Focus > [a Focus] > Focus filters > Bridgey. macOS runs it when that Focus
/// turns on (with the person's choice) and off (with the default, false).
struct BridgeyFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("focus.filter.title", defaultValue: "Bridgey")
    static var description = IntentDescription(LocalizedStringResource("focus.filter.description", defaultValue: "Tell your phones when this Focus is on, if Share Focus with phones is on in Bridgey."))

    @Parameter(title: LocalizedStringResource("focus.filter.quiet", defaultValue: "Share this Focus with my phones"), default: false)
    var shareWithPhones: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: shareWithPhones
            ? LocalizedStringResource("focus.filter.on", defaultValue: "Phones go quiet")
            : LocalizedStringResource("focus.filter.off", defaultValue: "Phones stay as they are"))
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentHost.pairing?.focusSync.localFocusChanged(shareWithPhones)
        return .result()
    }
}

/// For a Shortcuts automation ("When Focus turns on/off"): tells the phones the Mac's Focus state.
struct ShareFocusIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("focus.intent.title", defaultValue: "Share Focus with Phones")
    static var description = IntentDescription(LocalizedStringResource("focus.intent.description", defaultValue: "Tells phones that follow this Mac\u{2019}s Focus whether it is on."))

    @Parameter(title: LocalizedStringResource("focus.intent.on", defaultValue: "Focus is on"), default: true)
    var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let pairing = IntentHost.pairing else { throw IntentFailure.failed }
        guard pairing.focusSync.settings.share else { throw IntentFailure.featureOff(L10n.text("focus.share", fallback: "Share Focus with phones")) }
        pairing.focusSync.localFocusChanged(on)
        return .result()
    }
}

// MARK: - Settings

struct FocusSyncCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let focus = model.focusSync
        SettingsCard(title: L10n.text("focus.title", fallback: "Focus"),
                     footnote: L10n.text("focus.footnote", fallback: "To share, add Bridgey to a Focus in System Settings > Focus > Focus filters, or use the Share Focus with Phones action in a Shortcuts automation. To follow, pick Shortcuts that use the Set Focus action. macOS does not let apps read or change a Focus directly.")) {
            SettingsToggle(title: L10n.text("focus.share", fallback: "Share Focus with phones"),
                           subtitle: L10n.text("focus.share.detail", fallback: "Phones that follow this Mac turn on Do Not Disturb with your Focus"),
                           divider: false, isOn: focus.share, set: { value in actions.setFocusSync { $0.share = value } })
            SettingsToggle(title: L10n.text("focus.follow", fallback: "Follow the phone\u{2019}s Do Not Disturb"),
                           subtitle: L10n.text("focus.follow.detail", fallback: "Runs your Shortcut when Do Not Disturb turns on or off on a phone that shares it"),
                           isOn: focus.follow, set: { value in actions.setFocusSync { $0.follow = value } })
            if focus.follow {
                shortcutRow(L10n.text("focus.follow.on", fallback: "When it turns on, run"), focus.onShortcut) { name in actions.setFocusSync { $0.onShortcut = name } }
                shortcutRow(L10n.text("focus.follow.off", fallback: "When it turns off, run"), focus.offShortcut) { name in actions.setFocusSync { $0.offShortcut = name } }
            }
        }
    }

    private func shortcutRow(_ title: String, _ value: String?, set: @escaping (String?) -> Void) -> some View {
        SettingsRow(title: title, subtitle: value == nil ? L10n.text("focus.follow.none", fallback: "Choose a Shortcut") : nil, subtitleIsWarning: value == nil) {
            ChoiceButton(value: value ?? L10n.text("shortcut.off", fallback: "Off")) {
                var items = [PopUpMenuItem(title: L10n.text("shortcut.off", fallback: "Off"), checked: value == nil) { set(nil) }]
                if let names = model.availableShortcuts {
                    items += names.prefix(200).map { name in PopUpMenuItem(title: name, checked: name == value) { set(name) } }
                } else {
                    items.append(PopUpMenuItem(title: L10n.text("actions.shortcuts.loading", fallback: "Loading Shortcuts\u{2026}"), enabled: false) {})
                }
                return items
            }
        }
    }
}
