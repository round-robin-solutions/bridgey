import CryptoKit
import Foundation

/// Round Robin edition release channels. On macOS, Sparkle reads one appcast in
/// which Beta and Nightly items carry `<sparkle:channel>`; items without a channel
/// are Stable and visible to everyone. Sparkle only offers builds newer than the
/// installed CFBundleVersion, so switching to a more stable channel never downgrades.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta, nightly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        case .nightly: "Nightly"
        }
    }

    var detail: String {
        switch self {
        case .stable: L10n.text("channel.stable.detail", fallback: "Tested releases. Best for most people.")
        case .beta: L10n.text("channel.beta.detail", fallback: "New features before they reach Stable.")
        case .nightly: L10n.text("channel.nightly.detail", fallback: "Daily builds. Expect rough edges.")
        }
    }

    /// Sparkle channels allowed in addition to the default (Stable) channel.
    var sparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        case .nightly: ["beta", "nightly"]
        }
    }

    /// JSON feeds a client on this channel reads: its own and every more stable one.
    var feedChannels: [UpdateChannel] {
        Self.allCases.filter { $0.order <= order }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    func feedURL(base: URL) -> URL {
        base.appendingPathComponent("\(rawValue).json")
    }

    static let defaultsKey = "updates.channel"

    static func stored(in defaults: UserDefaults) -> UpdateChannel {
        defaults.string(forKey: defaultsKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}

enum UpdateFeedError: Error, Equatable {
    case invalidJSON
    case unsupportedSchema
    case wrongApp
    case wrongChannel
    case versionDoesNotMatchChannel
    case invalidBuild
    case assetOutsideRepository
    case invalidChecksum
    case invalidSize
    case insecureURL
}

/// The channel feed written by scripts/rr/rrrelease.py (`<channel>.json` on the `channels` release).
struct ChannelFeed: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let url: String
        let sha256: String
        let size: Int64
    }

    struct Android: Decodable, Equatable {
        /// The version from 1.0 (1.0.0-beta.2). Feeds written before 1.0 have only `versionName`.
        var version: String? = nil
        /// The pre-1.0 form that 0.x apps check (1.0.0-rr.1-beta.2); see scripts/rr/versions.py.
        let versionName: String
        let versionCode: Int64
        let url: String
        let sha256: String
        let size: Int64
        let minSdk: Int
    }

    struct MacOS: Decodable, Equatable {
        /// The version from 1.0; `shortVersion` keeps the pre-1.0 form, like Android's `versionName`.
        var version: String? = nil
        let shortVersion: String
        let build: Int64
        let minimumSystemVersion: String
        let dmg: Asset
        let zip: Asset
        let edSignature: String
    }

    let schema: Int
    let app: String
    let channel: String
    let version: String
    let build: Int64
    let notesUrl: String?
    let notes: String?
    let android: Android?
    let macos: MacOS?
}

enum UpdateFeeds {
    static let schema = 1
    static let maxFeedBytes = 64 * 1024
    static let maxAssetBytes: Int64 = 150 * 1024 * 1024

    /// Version names carry their channel: 1.0.0 for Stable, 1.0.0-beta.N or 1.0.0-nightly.YYYYMMDD otherwise.
    /// Names from before 1.0 (0.11.0-rr.1-beta.3) are accepted too; see `VersionNames`.
    static func versionName(_ version: String, matches channel: UpdateChannel) -> Bool {
        VersionNames.parse(version)?.channel == channel
    }

    static func parse(
        _ data: Data,
        expectedChannel: UpdateChannel,
        appID: String,
        assetURLPrefix: String
    ) throws -> ChannelFeed {
        guard data.count <= maxFeedBytes,
              let feed = try? JSONDecoder().decode(ChannelFeed.self, from: data) else { throw UpdateFeedError.invalidJSON }
        guard feed.schema == schema else { throw UpdateFeedError.unsupportedSchema }
        guard feed.app == appID else { throw UpdateFeedError.wrongApp }
        guard feed.channel == expectedChannel.rawValue else { throw UpdateFeedError.wrongChannel }
        guard assetURLPrefix.hasPrefix("https://") else { throw UpdateFeedError.insecureURL }
        if let notesURL = feed.notesUrl, !notesURL.isEmpty, !notesURL.hasPrefix("https://") { throw UpdateFeedError.insecureURL }
        if let android = feed.android {
            guard versionName(android.version ?? android.versionName, matches: expectedChannel) else { throw UpdateFeedError.versionDoesNotMatchChannel }
            guard android.versionCode > 0, android.versionCode <= Int64(Int32.max) else { throw UpdateFeedError.invalidBuild }
            try validate(Asset(url: android.url, sha256: android.sha256, size: android.size), prefix: assetURLPrefix)
        }
        if let macos = feed.macos {
            guard versionName(macos.version ?? macos.shortVersion, matches: expectedChannel) else { throw UpdateFeedError.versionDoesNotMatchChannel }
            guard macos.build > 0 else { throw UpdateFeedError.invalidBuild }
            try validate(macos.dmg, prefix: assetURLPrefix)
            try validate(macos.zip, prefix: assetURLPrefix)
            guard let signature = Data(base64Encoded: macos.edSignature), signature.count == 64 else {
                throw UpdateFeedError.invalidChecksum
            }
        }
        return feed
    }

    private typealias Asset = ChannelFeed.Asset

    private static func validate(_ asset: Asset, prefix: String) throws {
        guard asset.url.hasPrefix(prefix) else { throw UpdateFeedError.assetOutsideRepository }
        guard asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw UpdateFeedError.invalidChecksum
        }
        guard asset.size > 0, asset.size <= maxAssetBytes else { throw UpdateFeedError.invalidSize }
    }

    /// Newest macOS build strictly newer than the installed one that runs on this system.
    static func newestMacUpdate(
        installedBuild: Int64,
        feeds: [ChannelFeed],
        systemVersion: OperatingSystemVersion
    ) -> ChannelFeed? {
        feeds
            .filter { feed in
                guard let macos = feed.macos else { return false }
                return macos.build > installedBuild && systemVersion.isAtLeast(macos.minimumSystemVersion)
            }
            .max { ($0.macos?.build ?? 0) < ($1.macos?.build ?? 0) }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func file(at url: URL, matchesSHA256 expected: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return sha256Hex(data) == expected.lowercased()
    }
}

extension OperatingSystemVersion {
    func isAtLeast(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let required = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return (majorVersion, minorVersion, patchVersion) >= (required.majorVersion, required.minorVersion, required.patchVersion)
    }
}

/// The words of a version label in the app's language.
struct VersionWords: Equatable {
    var beta = "Beta"
    var nightly = "Nightly"
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static var current: VersionWords {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let months = (formatter.shortMonthSymbols ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return VersionWords(
            beta: L10n.text("version.beta", fallback: "Beta"),
            nightly: L10n.text("version.nightly", fallback: "Nightly"),
            months: months.count == 12 ? months : VersionWords().months
        )
    }
}

/// Version names of Bridgey by Round Robin (docs/rr-edition.md, "Versions"; scripts/rr/versions.py and
/// VersionNames in the Android app follow the same rules). From 1.0: 1.0.0, 1.0.0-beta.2,
/// 1.0.0-nightly.20261116. Before 1.0: 0.11.0-rr.1, 0.11.0-rr.1-beta.3. Both parse. People see labels
/// ("1.0 Beta 2"); About shows the full name and the build number.
enum VersionNames {
    struct Parsed: Equatable {
        var major: Int
        var minor: Int
        var patch: Int
        /// The Round Robin count of a name from before 1.0, nil from 1.0.
        var rr: Int?
        var channel: UpdateChannel
        /// Beta number or nightly date (YYYYMMDD); nil for Stable.
        var number: Int?

        var core: String { "\(major).\(minor).\(patch)" }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^(\d+)\.(\d+)\.(\d+)(?:-rr\.(\d+))?(?:-(beta|nightly)\.(\d+))?$"#)

    static func parse(_ name: String) -> Parsed? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = pattern.firstMatch(in: name, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: name).map { String(name[$0]) }
        }
        guard let major = group(1).flatMap({ Int($0) }), let minor = group(2).flatMap({ Int($0) }),
              let patch = group(3).flatMap({ Int($0) }) else { return nil }
        let pre = group(5)
        let digits = group(6)
        let number = digits.flatMap { Int($0) }
        if digits != nil, number == nil { return nil }
        if pre == "nightly", digits?.count != 8 { return nil }
        let channel: UpdateChannel = switch pre {
        case "beta": .beta
        case "nightly": .nightly
        default: .stable
        }
        return Parsed(major: major, minor: minor, patch: patch, rr: group(4).flatMap { Int($0) }, channel: channel, number: number)
    }

    /// "1.0", "1.0.1", "1.0 Beta 2", "1.1 Nightly 16 Nov". A name from before 1.0 keeps its base ("0.11.0-rr.1 Beta 3");
    /// a name that does not parse (a development build) stays as it is.
    static func label(_ name: String, words: VersionWords = VersionWords()) -> String {
        guard let version = parse(name) else { return name }
        let base: String
        if let rr = version.rr {
            base = "\(version.core)-rr.\(rr)"
        } else {
            base = version.patch == 0 ? "\(version.major).\(version.minor)" : version.core
        }
        return pre(version, words: words).map { "\(base) \($0)" } ?? base
    }

    /// `label`, or only the pre-release part ("Beta 10") when `other` is a build of the same release.
    static func short(_ name: String, comparedTo other: String, words: VersionWords = VersionWords()) -> String {
        guard let version = parse(name) else { return name }
        if let against = parse(other), against.core == version.core, against.rr == version.rr, let pre = pre(version, words: words) {
            return pre
        }
        return label(name, words: words)
    }

    /// About: the full name and the build number, "1.0.0-beta.2 (263201200)".
    static func full(_ name: String, build: String) -> String {
        build.isEmpty || build == "0" ? name : "\(name) (\(build))"
    }

    private static func pre(_ version: Parsed, words: VersionWords) -> String? {
        switch version.channel {
        case .stable: return nil
        case .beta: return "\(words.beta) \(version.number ?? 0)"
        case .nightly:
            let date = version.number ?? 0
            let day = date % 100
            let month = (date / 100) % 100
            guard (1...12).contains(month), (1...31).contains(day) else { return "\(words.nightly) \(date)" }
            let name = words.months.indices.contains(month - 1) ? words.months[month - 1] : "\(month)"
            return "\(words.nightly) \(day) \(name)"
        }
    }
}
