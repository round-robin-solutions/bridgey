import Foundation

/// The phone's text messages: conversations, a conversation, replies.
@MainActor
final class MessagesModel: ObservableObject, SessionFeature {
    private(set) weak var app: AppModel?
    private var client: CoreClient?

    func attach(_ app: AppModel) { self.app = app }
    func clientChanged(_ client: CoreClient?) { self.client = client }
    func handle(_ e: CoreEvent) {}
}
