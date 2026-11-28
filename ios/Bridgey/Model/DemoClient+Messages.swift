import Foundation

#if DEBUG
extension DemoClient {
    func demoMessages(deviceID: String, command: [String: Any]) -> [String: Any] { ["ok": true] }

    /// Screenshots of Messages (BRIDGEY_DEMO=messages-...).
    @MainActor
    static func seedMessages(_ model: AppModel, screen: String) {}
}
#endif
