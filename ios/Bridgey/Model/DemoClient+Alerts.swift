import SwiftUI
import UIKit

#if DEBUG
extension DemoClient {
    /// Screenshots of notifications, the call card and ringing: BRIDGEY_DEMO=alerts (a code and two messages), call
    /// (an incoming call on the phone), ringing (the Mac ringing this device, and this device ringing the phone).
    @MainActor
    static func seedAlerts(_ model: AppModel, screen: String) {
        guard ["alerts", "call", "ringing"].contains(screen) else { return }
        model.alerts.ringer = SilentRinger()
        model.alerts.announce = { _ in }
        let now = Date().timeIntervalSince1970 * 1000
        func post(_ json: [String: Any], quiet: Bool = false) {
            guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else { return }
            model.handle(CoreEvent(kind: .notification, status: quiet ? 1 : 0, deviceID: pixel, name: json["applicationName"] as? String, text: text))
        }
        switch screen {
        case "alerts":
            post(["packageName": "com.google.android.calendar", "applicationName": "Calendar", "notificationId": "cal-1", "title": "Design review",
                  "text": "4:30 to 5:15 · Studio room", "timestamp": now - 9 * 60_000, "icon": icon("31", 0x4285F4)])
            post(["packageName": "com.whatsapp", "applicationName": "WhatsApp", "notificationId": "wa-1", "title": "Anna Kapoor",
                  "text": "Running ten minutes late. Order me a flat white?", "timestamp": now - 2 * 60_000, "icon": icon("W", 0x25D366),
                  "actions": [["token": "wa-reply", "title": "Reply", "allowsReply": true], ["token": "wa-read", "title": "Mark as read", "allowsReply": false]]])
            post(["packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "notificationId": "sms-1", "title": "AX-ROUNDR",
                  "text": "482913 is your Round Robin sign-in code. It expires in 10 minutes.", "timestamp": now - 30_000, "icon": icon("M", 0x1A73E8),
                  "code": ["code": "482913", "service": "AX-ROUNDR", "channel": "sms"],
                  "actions": [["token": "sms-read", "title": "Mark as read", "allowsReply": false]], "smsReply": true])
        case "call":
            post(["packageName": "com.google.android.dialer", "applicationName": "Phone", "notificationId": "call-1", "title": "Anna Kapoor",
                  "text": "Incoming call", "timestamp": now, "callType": "incoming",
                  "actions": [["token": String(repeating: "c", count: 64), "title": "Answer", "allowsReply": false],
                              ["token": String(repeating: "d", count: 64), "title": "Decline", "allowsReply": false]]])
            post(["packageName": "com.whatsapp", "applicationName": "WhatsApp", "notificationId": "wa-1", "title": "Anna Kapoor",
                  "text": "Calling you now", "timestamp": now - 60_000, "icon": icon("W", 0x25D366)])
        default:
            model.handle(CoreEvent(kind: .findRequested, status: 1, deviceID: mac))
            model.handle(CoreEvent(kind: .findState, status: 1, deviceID: pixel))
        }
    }

    /// A small app icon for the samples: a letter on a coloured rounded square, as PNG in base64.
    private static func icon(_ letter: String, _ colour: UInt32) -> String {
        let size = CGSize(width: 96, height: 96)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(Color(hex: colour)).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 26).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor.white]
            let text = letter as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2), withAttributes: attributes)
        }
        return image.pngData()?.base64EncodedString() ?? ""
    }
}

/// Screenshots ring silently.
final class SilentRinger: Ringer {
    func start() {}
    func stop() {}
}
#endif
