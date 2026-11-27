import Foundation

#if DEBUG
extension DemoClient {
    func demoPhoneFiles(deviceID: String, command: [String: Any]) -> [String: Any] { ["ok": true] }

    /// Screenshots of the phone's files (BRIDGEY_DEMO=files-...).
    @MainActor
    static func seedPhoneFiles(_ model: AppModel, screen: String) {}
}
#endif
