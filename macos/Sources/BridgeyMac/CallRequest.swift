import AppKit
import Foundation

func normalizedPhoneNumber(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet(charactersIn: "+-(). 0123456789")
    guard !trimmed.isEmpty,
          trimmed.unicodeScalars.allSatisfy(allowed.contains),
          trimmed.filter({ $0 == "+" }).count <= 1,
          !trimmed.contains("+") || trimmed.first == "+" else { return nil }
    let digits = trimmed.filter(\.isNumber)
    guard (3...15).contains(digits.count) else { return nil }
    return (trimmed.first == "+" ? "+" : "") + digits
}

/// Where a call request came from. Bridgey's own buttons and shortcut call at once; a tel: link or
/// the Call with Bridgey Service can come from any app, so Settings > Calls decides what happens.
enum CallRequestSource: Equatable {
    case bridgey, link, service

    var isFromOtherApp: Bool { self != .bridgey }
}

/// Settings > Calls > When another app asks to call. Stored as `settings.calls.otherApps`; a value
/// this build does not know reads as `ask`.
enum MacOtherAppCallPolicy: String, CaseIterable {
    /// Confirm each call on this Mac first (default).
    case ask
    /// Send the call to the phone without asking.
    case callNow = "call_now"
    /// Drop the request and say so.
    case refuse
}

/// What to do with a call request now: ask on this Mac, send it, or drop it.
enum CallRequestDecision: Equatable {
    case ask, callNow, refuse
}

/// Calls started inside Bridgey (its buttons and shortcut) never ask and are never blocked; a call
/// from another app (tel: link, Call with Bridgey Service) follows the policy.
func otherAppCallDecision(source: CallRequestSource, policy: MacOtherAppCallPolicy) -> CallRequestDecision {
    guard source.isFromOtherApp else { return .callNow }
    switch policy {
    case .ask: return .ask
    case .callNow: return .callNow
    case .refuse: return .refuse
    }
}

/// The question before another app's call goes to the phone: the number and the phone, when known.
func callConfirmationTitle(number: String, phoneName: String?) -> String {
    guard let phoneName, !phoneName.isEmpty else {
        return String(format: L10n.text("call.confirm.title.anyPhone", fallback: "Call %@ from your phone?"), number)
    }
    return String(format: L10n.text("call.confirm.title", fallback: "Call %1$@ from %2$@?"), number, phoneName)
}

/// The question before another app's call goes to the phone, with a Don't ask again box that sets the
/// policy to Call right away once Call is pressed (see `Pairing.confirmCall`).
@MainActor
func makeCallConfirmationAlert(number: String, phoneName: String?) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = callConfirmationTitle(number: number, phoneName: phoneName)
    alert.informativeText = L10n.text("call.confirm.detail", fallback: "Another app asked Bridgey to place this call.")
    alert.addButton(withTitle: L10n.text("call.confirm.call", fallback: "Call"))
    alert.addButton(withTitle: L10n.text("action.cancel", fallback: "Cancel"))
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = L10n.text("call.confirm.dontAsk", fallback: "Don\u{2019}t ask again")
    return alert
}

func pendingPhoneCallCanDispatch(isConnected: Bool, featureStateReceived: Bool) -> Bool {
    isConnected && featureStateReceived
}

@MainActor
final class CallServiceProvider: NSObject {
    private let onCall: (String) -> Void

    init(onCall: @escaping (String) -> Void) {
        self.onCall = onCall
    }

    @objc func callWithBridgey(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let value = pasteboard.string(forType: .string), normalizedPhoneNumber(value) != nil else {
            error.pointee = "The selected text is not a supported phone number."
            return
        }
        onCall(value)
    }
}
