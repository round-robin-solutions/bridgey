import Foundation

#if DEBUG
extension DemoClient {
    func demoScreen(_ area: PhoneArea, deviceID: String, command: [String: Any]) -> [String: Any] { ["ok": true] }

    func demoScreenFrame(_ stream: UInt64, timeoutMs: UInt32, buffer: UnsafeMutableRawBufferPointer) -> ScreenFramePull { .ended }

    /// Screenshots of a screen (BRIDGEY_DEMO=screen-...).
    @MainActor
    static func seedScreen(_ model: AppModel, screen: String) {}
}
#endif
