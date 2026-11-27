import Foundation

/// An Android phone's or a Mac's screen on this device, and control of it.
@MainActor
final class ScreenModel: ObservableObject, SessionFeature {
    private(set) weak var app: AppModel?
    private var client: CoreClient?
    /// The device whose screen is open, if any.
    @Published var viewing: String?

    func attach(_ app: AppModel) { self.app = app }
    func clientChanged(_ client: CoreClient?) {
        self.client = client
        if client == nil { viewing = nil }
    }
    func handle(_ e: CoreEvent) {}

    func open(_ device: DeviceItem) { viewing = device.id }
    func close() { viewing = nil }
}
