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
/// the Call with Bridgey Service can come from any app, so this Mac asks first.
enum CallRequestSource: Equatable {
    case bridgey, link, service

    var needsConfirmation: Bool { self != .bridgey }
}

/// The question before another app's call goes to the phone: the number and the phone, when known.
func callConfirmationTitle(number: String, phoneName: String?) -> String {
    guard let phoneName, !phoneName.isEmpty else {
        return String(format: L10n.text("call.confirm.title.anyPhone", fallback: "Call %@ from your phone?"), number)
    }
    return String(format: L10n.text("call.confirm.title", fallback: "Call %1$@ from %2$@?"), number, phoneName)
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
