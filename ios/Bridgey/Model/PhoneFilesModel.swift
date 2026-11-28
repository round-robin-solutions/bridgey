import Foundation

/// The phone's files: its places and folders, downloads to this device and uploads to the phone.
@MainActor
final class PhoneFilesModel: ObservableObject, SessionFeature {
    private(set) weak var app: AppModel?
    private var client: CoreClient?

    func attach(_ app: AppModel) { self.app = app }
    func clientChanged(_ client: CoreClient?) { self.client = client }
    func handle(_ e: CoreEvent) {}
}
