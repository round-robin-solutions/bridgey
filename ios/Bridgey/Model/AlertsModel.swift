import Foundation

/// What the phone and other devices tell this one while it is open: notifications (with codes), the phone's call,
/// a device ringing this one, and this device's own battery for them.
@MainActor
final class AlertsModel: ObservableObject, SessionFeature {
    private(set) weak var app: AppModel?
    private var client: CoreClient?

    func attach(_ app: AppModel) { self.app = app }
    func clientChanged(_ client: CoreClient?) { self.client = client }
    func handle(_ e: CoreEvent) {}

    /// Rings a device until it is stopped there or here.
    func ring(_ device: DeviceItem) {
        try? client?.find(device.id, ring: true)
    }
}
