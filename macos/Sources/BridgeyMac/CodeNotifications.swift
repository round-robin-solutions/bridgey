import CoreGraphics
import Foundation

/// Draft, edition only: SMS notifications carry `smsDefaultApp` and `redacted`, and both sides speak
/// the `codes.*` messages (code access status and the companion link). See docs/protocol.md.
let smsCodesFeatureKey = "sms_codes_draft1"

let codeCopyActionIdentifier = "bridgey.code.copy"
/// The notification's userInfo holds this reference, never the code.
let codeReferenceUserInfoKey = "bridgeyCodeRef"

/// A code the Mac found, kept in memory for the panel card and Copy code.
struct LiveCodeCard: Identifiable, Equatable {
    let id: String
    let code: String
    /// The SMS title (contact or sender ID), else the app's name.
    let sender: String
    let deviceName: String
    let receivedAt: Date
    var copiedAt: Date?
    var copiedAutomatically = false

    /// "Copied. Clears in 42 s." while the clipboard may still hold it.
    func copiedLine(now: Date) -> String? {
        guard let copiedAt else { return nil }
        let left = Int((CodeClipboard.clearAfter - now.timeIntervalSince(copiedAt)).rounded(.up))
        guard left > 0 else { return nil }
        let format = copiedAutomatically
            ? L10n.text("codes.copied.auto", fallback: "Copied automatically. Clears in %d s.")
            : L10n.text("codes.copied", fallback: "Copied. Clears in %d s.")
        return String(format: format, left)
    }
}

/// What Settings says about code access for the selected phone.
enum CodeAccessDisplay: Equatable {
    case noPhone
    /// The phone runs a Bridgey without codes support.
    case phoneTooOld
    /// Connected, no report yet.
    case waiting
    case status(CodeAccessStatus)

    var text: String {
        switch self {
        case .noPhone: L10n.text("codes.access.noPhone", fallback: "Connect a phone to see this")
        case .phoneTooOld: L10n.text("codes.access.tooOld", fallback: "Update Bridgey on the phone to use codes")
        case .waiting: L10n.text("codes.access.waiting", fallback: "Waiting for the phone")
        case .status(.allowed): L10n.text("codes.access.allowed", fallback: "Allowed: Android shows Bridgey the full message")
        case .status(.hidden): L10n.text("codes.access.hidden", fallback: "Hidden by Android: link this phone to the Mac")
        case .status(.notLinked): L10n.text("codes.access.notLinked", fallback: "Not linked: Android may hide codes from Bridgey")
        }
    }

    var isWarning: Bool {
        switch self {
        case .status(.hidden), .status(.notLinked): true
        default: false
        }
    }

    /// The Link button is offered while the phone can link and is not already allowed.
    var offersLink: Bool {
        switch self {
        case .status(.hidden), .status(.notLinked), .waiting: true
        default: false
        }
    }
}

func companionAdvertiseFailureText(_ failure: CompanionAdvertiseFailure) -> String {
    switch failure {
    case .bluetoothOff: L10n.text("codes.link.bluetoothOff", fallback: "Turn on Bluetooth on this Mac, then try again.")
    case .unauthorized: L10n.text("codes.link.unauthorized", fallback: "Allow Bluetooth for Bridgey in System Settings > Privacy & Security > Bluetooth, then try again.")
    case .unsupported: L10n.text("codes.link.unsupported.mac", fallback: "This Mac cannot advertise over Bluetooth. Use the ADB command instead.")
    case .failed: L10n.text("codes.link.failed", fallback: "Bluetooth advertising did not start. Try again.")
    }
}

/// Undocumented but widely used session key; false when it cannot be read.
func macScreenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

/// Seconds since the last keyboard, mouse or trackpad input in this session.
func macIdleSeconds() -> TimeInterval {
    guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
}
