import Foundation

/// Round Robin edition identifiers and version labels. Values come from Info.plist, which the build fills from
/// rr-edition.properties (scripts/rr/build-ios.sh); local builds fall back to "<next>-dev".
enum Edition {
    static let displayName = "Bridgey by Round Robin"
    static let upstreamURL = URL(string: "https://github.com/singeol/bridgey")!
    static let sourceURL = URL(string: "https://github.com/round-robin-solutions/bridgey")!
    static let websiteURL = URL(string: "https://roundrobin.in/bridgey")!
    static let privacyURL = URL(string: "https://roundrobin.in/bridgey/privacy-security")!

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // An unexpanded build setting means the value was not set.
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
        }
    }

    /// The edition's version name: 1.0.0-beta.2, 1.0.0-nightly.20261116, or 1.0.0-dev on a local build.
    static var versionName: String {
        info("BridgeyVersionName") ?? "\(info("CFBundleShortVersionString") ?? "1.0.0")-dev"
    }

    /// The UTC build time, YYDDDHHMM (CFBundleVersion).
    static var buildNumber: String { info("CFBundleVersion") ?? "1" }

    /// The upstream release this edition is built on (EDITION_UPSTREAM_BASE).
    static var upstreamBase: String? { info("BridgeyUpstreamBase") }

    /// Shared by the app and its Share extension: settings, and items queued for later.
    static var appGroup: String? { info("BridgeyAppGroup") }

    /// The Keychain group both read the pairing data from. Without a team ID prefix (unsigned builds) it still
    /// names the group; KeychainStore falls back to the app's own Keychain when the entitlement is missing.
    static var keychainGroup: String? { info("BridgeyKeychainGroup") }

    /// Connect anywhere's control service (rr-edition.properties CONNECT_CONTROL_URL); nil: learned addresses only.
    static var connectControlURL: String? { info("BridgeyConnectControlURL") }

    /// About's credit line.
    static var credit: String {
        guard let upstreamBase else { return String(localized: "Built on Bridgey by Semyon Mikhailov (MIT)") }
        return String(localized: "Built on Bridgey \(upstreamBase) by Semyon Mikhailov (MIT)")
    }
}

/// The edition's version names (scripts/rr/versions.py, UpdateLogic.swift, Versions.cs).
enum Versions {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The short label people see: 1.0.0 is "1.0", 1.0.1 "1.0.1", 1.1.0-beta.2 "1.1 Beta 2",
    /// 1.0.0-nightly.20261116 "1.0 Nightly 16 Nov". Anything else comes back unchanged.
    static func display(_ name: String) -> String {
        let pattern = #"^(\d+)\.(\d+)\.(\d+)(?:-rr\.(\d+))?(?:-(beta|nightly)\.(\d+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return name }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: name).map { String(name[$0]) }
        }
        let (major, minor, patch) = (group(1)!, group(2)!, group(3)!)
        let channel = group(5) ?? "stable"
        let number = group(6) ?? ""
        if channel == "nightly", number.count != 8 { return name }
        let base: String
        if let rr = group(4) {
            base = "\(major).\(minor).\(patch)-rr.\(rr)"
        } else {
            base = patch == "0" ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        }
        switch channel {
        case "beta": return "\(base) Beta \(number)"
        case "nightly":
            let value = Int(number) ?? 0
            let day = value % 100, month = value / 100 % 100
            if (1...12).contains(month), (1...31).contains(day) { return "\(base) Nightly \(day) \(months[month - 1])" }
            return "\(base) Nightly \(number)"
        default: return base
        }
    }

    /// "1.0 Beta 1", or "1.0.0-dev" on a local build.
    static var shortLabel: String { display(Edition.versionName) }

    /// "1.0.0-beta.1 (263201050)" for About.
    static var fullLabel: String { "\(Edition.versionName) (\(Edition.buildNumber))" }
}
