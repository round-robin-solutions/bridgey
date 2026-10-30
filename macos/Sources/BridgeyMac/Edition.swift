import Foundation

/// Round Robin edition identifiers. Everything that would otherwise share state
/// with an installed upstream Bridgey (Keychain items, support folders, legacy
/// preference import) is namespaced here so both apps can live side by side.
enum Edition {
    /// A debug test instance (TestInstance) takes its own bundle ID, so its support folder, Keychain items and
    /// preferences never touch the Bridgey installed on the same Mac.
    static let identifier = TestInstance.enabled ? (Bundle.main.bundleIdentifier ?? "in.roundrobin.bridgey") : "in.roundrobin.bridgey"
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

/// A throwaway second Bridgey on a Mac that already runs one, for live tests (Connect anywhere over the public
/// relay). Debug builds only, and only when Info.plist has `BridgeyTestInstance` = true: release builds compile
/// this to `enabled = false`, so none of it can switch on in a shipped app. It takes its own bundle ID (support
/// folder, Keychain, preferences), its own TCP port (`BridgeyTestPort`), and reads commands from files in
/// `/tmp/<bundle id>-control/` (TestControl in Pairing.swift).
enum TestInstance {
    #if DEBUG
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "BridgeyTestInstance") as? Bool == true
    #else
    static let enabled = false
    #endif

    /// The listening port; nil keeps 42458.
    static let port: UInt16? = enabled ? (Bundle.main.object(forInfoDictionaryKey: "BridgeyTestPort") as? NSNumber)?.uint16Value : nil
    static var listeningPort: UInt16 { port ?? 42_458 }
}
