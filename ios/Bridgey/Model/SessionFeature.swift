import Foundation

/// A feature that follows the session: the screens, the phone's messages and files, and its alerts. AppModel owns
/// one of each, tells it when a client starts or stops, and hands it every event in order, after applying it itself.
@MainActor
protocol SessionFeature: AnyObject {
    /// Called once, when AppModel is made.
    func attach(_ app: AppModel)
    /// A client started, or the session stopped (nil): the app left the screen or Bridgey stopped.
    func clientChanged(_ client: CoreClient?)
    func handle(_ e: CoreEvent)
}

/// Where the stream's navigation goes: pushed on iPhone, in the detail column on iPad.
enum Route: Hashable {
    case messages(deviceID: String)
    case phoneFiles(deviceID: String)
}

/// One area's event detail: `text` as a JSON object.
extension CoreEvent {
    var json: [String: Any] {
        guard let data = text?.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
