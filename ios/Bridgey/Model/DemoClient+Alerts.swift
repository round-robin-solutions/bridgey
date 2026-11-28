import Foundation

#if DEBUG
extension DemoClient {
    /// Screenshots of notifications, the call card and ringing (BRIDGEY_DEMO=alerts-...).
    @MainActor
    static func seedAlerts(_ model: AppModel, screen: String) {}
}
#endif
