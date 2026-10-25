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
        let versionName: String
        let versionCode: Int64
        let url: String
        let sha256: String
        let size: Int64
        let minSdk: Int
    }

    struct MacOS: Decodable, Equatable {
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

    private static let versionPattern = #"^\d+\.\d+\.\d+-rr\.\d+(-(beta\.\d+|nightly\.\d{8}))?$"#

    static func versionName(_ version: String, matches channel: UpdateChannel) -> Bool {
        guard version.range(of: versionPattern, options: .regularExpression) != nil else { return false }
        switch channel {
        case .stable: return !version.contains("-beta.") && !version.contains("-nightly.")
        case .beta: return version.contains("-beta.")
        case .nightly: return version.contains("-nightly.")
        }
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
            guard versionName(android.versionName, matches: expectedChannel) else { throw UpdateFeedError.versionDoesNotMatchChannel }
            guard android.versionCode > 0, android.versionCode <= Int64(Int32.max) else { throw UpdateFeedError.invalidBuild }
            try validate(Asset(url: android.url, sha256: android.sha256, size: android.size), prefix: assetURLPrefix)
        }
        if let macos = feed.macos {
            guard versionName(macos.shortVersion, matches: expectedChannel) else { throw UpdateFeedError.versionDoesNotMatchChannel }
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
