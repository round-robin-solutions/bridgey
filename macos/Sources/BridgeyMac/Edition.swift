import Foundation

/// Round Robin edition identifiers. Everything that would otherwise share state
/// with an installed upstream Bridgey (Keychain items, support folders, legacy
/// preference import) is namespaced here so both apps can live side by side.
enum Edition {
    static let identifier = "in.roundrobin.bridgey"
    static let displayName = "Bridgey by Round Robin"
    static let trustKeychainService = "\(identifier).trust"
    static let identityKeychainService = "\(identifier).identity"
    /// Folder name under Application Support and Caches.
    static let supportFolderName = identifier
    /// Upstream imported preferences from the pre-0.2 "BridgeyMac" suite. That suite
    /// belongs to upstream Bridgey, so this edition never reads it.
    static let legacyPreferencesSuite: String? = nil
    static let upstreamProjectURL = URL(string: "https://github.com/singeol/bridgey")!
}
