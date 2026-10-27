import Foundation
import UserNotifications

/*
 * Phone battery alerts on the Mac: "OnePlus 11 at 15%" and "OnePlus 11 fully charged". Per phone
 * thresholds in Settings > Devices (default 20% and 100%). Each alert shows once per charge
 * cycle: low again only after the phone was charging (or climbed 5 points above the threshold),
 * full again only after it dropped 5 points below the threshold.
 */

enum BatteryAlertKind: String, Equatable { case low, full }

struct BatteryAlertThresholds: Equatable {
    static let lowChoices = [0, 10, 15, 20, 30]
    static let fullChoices = [0, 80, 90, 100]
    static let `default` = BatteryAlertThresholds(low: 20, full: 100)

    /// 0 is off.
    var low: Int
    var full: Int
}

/// One phone's alert memory. In memory only: a restart may alert once more, which is harmless.
struct BatteryAlertTracker: Equatable {
    private(set) var lowShown = false
    private(set) var fullShown = false
    static let hysteresis = 5

    /// The alert a new reading calls for, if any.
    mutating func update(level: Int, charging: Bool, thresholds: BatteryAlertThresholds) -> BatteryAlertKind? {
        if charging || (thresholds.low > 0 && level > thresholds.low + Self.hysteresis) { lowShown = false }
        if thresholds.full > 0 && level < thresholds.full - Self.hysteresis { fullShown = false }
        if thresholds.low > 0, !charging, level <= thresholds.low, !lowShown {
            lowShown = true
            return .low
        }
        if thresholds.full > 0, charging || level >= 100, level >= thresholds.full, !fullShown {
            fullShown = true
            return .full
        }
        return nil
    }
}

/// The notification text.
func batteryAlertText(_ kind: BatteryAlertKind, phone: String, level: Int) -> (title: String, body: String) {
    switch kind {
    case .low:
        return (String(format: L10n.text("battery.alert.low", fallback: "%@ at %d%%"), phone, level),
                L10n.text("battery.alert.low.body", fallback: "The phone\u{2019}s battery is low."))
    case .full:
        if level >= 100 {
            return (String(format: L10n.text("battery.alert.full", fallback: "%@ fully charged"), phone),
                    L10n.text("battery.alert.full.body", fallback: "You can unplug it."))
        }
        return (String(format: L10n.text("battery.alert.limit", fallback: "%@ at %d%%"), phone, level),
                L10n.text("battery.alert.limit.body", fallback: "Charged to the level you chose."))
    }
}

/// Per phone thresholds in UserDefaults.
final class BatteryAlertSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func thresholds(for deviceID: String) -> BatteryAlertThresholds {
        let low = defaults.object(forKey: key(deviceID, "low")) as? Int
        let full = defaults.object(forKey: key(deviceID, "full")) as? Int
        return BatteryAlertThresholds(
            low: low.flatMap { BatteryAlertThresholds.lowChoices.contains($0) ? $0 : nil } ?? BatteryAlertThresholds.default.low,
            full: full.flatMap { BatteryAlertThresholds.fullChoices.contains($0) ? $0 : nil } ?? BatteryAlertThresholds.default.full
        )
    }

    func set(_ thresholds: BatteryAlertThresholds, for deviceID: String) {
        defaults.set(thresholds.low, forKey: key(deviceID, "low"))
        defaults.set(thresholds.full, forKey: key(deviceID, "full"))
    }

    func remove(_ deviceID: String) {
        defaults.removeObject(forKey: key(deviceID, "low"))
        defaults.removeObject(forKey: key(deviceID, "full"))
    }

    private func key(_ deviceID: String, _ kind: String) -> String { "settings.batteryAlerts.\(deviceID).\(kind)" }
}

/// Decides and posts the alerts; the poster is replaced in tests.
@MainActor
final class BatteryAlerts: ObservableObject {
    @Published private(set) var revision = 0
    private let settings: BatteryAlertSettings
    private var trackers: [String: BatteryAlertTracker] = [:]
    var post: (_ identifier: String, _ title: String, _ body: String) -> Void = { identifier, title, body in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    init(settings: BatteryAlertSettings = BatteryAlertSettings()) { self.settings = settings }

    func thresholds(for deviceID: String) -> BatteryAlertThresholds { settings.thresholds(for: deviceID) }

    func setThresholds(_ thresholds: BatteryAlertThresholds, for deviceID: String) {
        settings.set(thresholds, for: deviceID)
        revision += 1
    }

    func forget(_ deviceID: String) {
        settings.remove(deviceID)
        trackers.removeValue(forKey: deviceID)
        revision += 1
    }

    func received(level: Int, charging: Bool, deviceID: String, phone: String) {
        var tracker = trackers[deviceID] ?? BatteryAlertTracker()
        let kind = tracker.update(level: level, charging: charging, thresholds: settings.thresholds(for: deviceID))
        trackers[deviceID] = tracker
        guard let kind else { return }
        let text = batteryAlertText(kind, phone: phone, level: level)
        post("bridgey.battery.\(deviceID).\(kind.rawValue)", text.title, text.body)
        BridgeyLog.plugin.notice("battery alert kind=\(kind.rawValue, privacy: .public) peer=\(shortDeviceID(deviceID), privacy: .public)")
    }
}
