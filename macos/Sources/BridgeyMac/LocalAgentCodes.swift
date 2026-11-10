import Combine
import Foundation

/// Owns only the new local preferences and runtime. Never changes pairing, code-reader settings,
/// agent grants or settings sync. Starting Bridgey restores the choice, never retained codes.
@MainActor
final class LocalAgentCodes: ObservableObject {
    @Published private(set) var options: LocalAgentCodeOptions
    @Published private(set) var unavailable = false
    let store = LocalAgentCodeStore()
    private let defaults: UserDefaults
    private var server: LocalAgentCodesServer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = LocalAgentCodeOptions(defaults: defaults)
        store.configure(options)
    }

    func start() {
        guard options.enabled, server == nil else { return }
        let server = LocalAgentCodesServer(store: store)
        do { try server.start(); self.server = server; unavailable = false }
        catch { unavailable = true } // No path, payload or code in diagnostics.
    }

    func set(_ options: LocalAgentCodeOptions) {
        guard (1...30).contains(options.minutes) else { return }
        store.configure(options)
        self.options = options
        options.save(to: defaults)
        if options.enabled { start() }
        else { server?.stop(); server = nil; unavailable = false }
    }
}
