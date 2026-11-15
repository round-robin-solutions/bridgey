import Foundation
import XCTest
@testable import BridgeyMac

final class UpdateLogicTests: XCTestCase {
    private let appID = "in.roundrobin.bridgey"
    private let prefix = "https://github.com/round-robin-solutions/bridgey/releases/download/"
    private let base = URL(string: "https://github.com/round-robin-solutions/bridgey/releases/download/channels")!
    private let signature = Data(repeating: 7, count: 64).base64EncodedString()

    private func feedJSON(
        channel: String = "beta",
        version: String = "0.6.0-rr.2-beta.1",
        build: Int64 = 262_981_315,
        app: String? = nil,
        schema: Int = 1,
        zipURL: String? = nil,
        sha: String = String(repeating: "b", count: 64),
        size: Int64 = 4_096,
        edSignature: String? = nil,
        minimumSystemVersion: String = "13.0"
    ) -> Data {
        let tag = "v\(version)"
        let object: [String: Any] = [
            "schema": schema,
            "app": app ?? appID,
            "channel": channel,
            "version": version,
            "build": build,
            "notesUrl": "https://github.com/round-robin-solutions/bridgey/releases/tag/\(tag)",
            "macos": [
                "shortVersion": version,
                "build": build,
                "minimumSystemVersion": minimumSystemVersion,
                "dmg": ["url": "\(prefix)\(tag)/Bridgey-RR-\(version)-macOS.dmg", "sha256": sha, "size": size],
                "zip": ["url": zipURL ?? "\(prefix)\(tag)/Bridgey-RR-\(version)-macOS.zip", "sha256": sha, "size": size],
                "edSignature": edSignature ?? signature,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testChannelsMapToSparkleChannelsAndFeeds() {
        XCTAssertEqual(UpdateChannel.stable.sparkleChannels, [])
        XCTAssertEqual(UpdateChannel.beta.sparkleChannels, ["beta"])
        XCTAssertEqual(UpdateChannel.nightly.sparkleChannels, ["beta", "nightly"])
        XCTAssertEqual(UpdateChannel.stable.feedChannels, [.stable])
        XCTAssertEqual(UpdateChannel.nightly.feedChannels, [.stable, .beta, .nightly])
        XCTAssertEqual(UpdateChannel.beta.feedURL(base: base).absoluteString, base.absoluteString + "/beta.json")
    }

    func testStoredChannelDefaultsToStable() throws {
        let suite = "in.roundrobin.bridgey.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UpdateChannel.stored(in: defaults), .stable)
        defaults.set("nightly", forKey: UpdateChannel.defaultsKey)
        XCTAssertEqual(UpdateChannel.stored(in: defaults), .nightly)
        defaults.set("canary", forKey: UpdateChannel.defaultsKey)
        XCTAssertEqual(UpdateChannel.stored(in: defaults), .stable)
    }

    func testParsesAValidFeed() throws {
        let feed = try UpdateFeeds.parse(feedJSON(), expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)
        XCTAssertEqual(feed.macos?.build, 262_981_315)
        XCTAssertNil(feed.android)
    }

    func testRejectsInvalidFeeds() {
        let cases: [(Data, UpdateFeedError)] = [
            (Data("nope".utf8), .invalidJSON),
            (feedJSON(schema: 2), .unsupportedSchema),
            (feedJSON(app: "dev.bridgey.mac"), .wrongApp),
            (feedJSON(channel: "stable"), .wrongChannel),
            (feedJSON(version: "0.6.0-rr.2"), .versionDoesNotMatchChannel),
            (feedJSON(build: 0), .invalidBuild),
            (feedJSON(zipURL: "https://evil.example/x.zip"), .assetOutsideRepository),
            (feedJSON(sha: "xyz"), .invalidChecksum),
            (feedJSON(size: 0), .invalidSize),
            (feedJSON(edSignature: "c2hvcnQ="), .invalidChecksum),
            (Data(repeating: 32, count: UpdateFeeds.maxFeedBytes + 1), .invalidJSON),
        ]
        for (data, expected) in cases {
            XCTAssertThrowsError(try UpdateFeeds.parse(data, expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)) {
                XCTAssertEqual($0 as? UpdateFeedError, expected)
            }
        }
    }

    func testVersionNamesMatchTheirChannel() {
        XCTAssertTrue(UpdateFeeds.versionName("0.6.0-rr.1", matches: .stable))
        XCTAssertTrue(UpdateFeeds.versionName("0.6.0-rr.2-beta.1", matches: .beta))
        XCTAssertTrue(UpdateFeeds.versionName("0.6.0-rr.2-nightly.20261025", matches: .nightly))
        XCTAssertFalse(UpdateFeeds.versionName("0.6.0-rr.2-beta.1", matches: .stable))
        XCTAssertFalse(UpdateFeeds.versionName("0.6.0-rc.2", matches: .stable))
        // From 1.0 the edition has its own semver; the names from before it stay valid.
        XCTAssertTrue(UpdateFeeds.versionName("1.0.0", matches: .stable))
        XCTAssertTrue(UpdateFeeds.versionName("1.0.0-beta.2", matches: .beta))
        XCTAssertTrue(UpdateFeeds.versionName("1.1.0-nightly.20261116", matches: .nightly))
        XCTAssertFalse(UpdateFeeds.versionName("1.0.0", matches: .beta))
        XCTAssertFalse(UpdateFeeds.versionName("1.0.0-rc.1", matches: .stable))
        XCTAssertFalse(UpdateFeeds.versionName("1.0.0-dev", matches: .stable))
    }

    func testNeverOffersADowngrade() throws {
        let older = try UpdateFeeds.parse(feedJSON(build: 262_980_000), expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)
        let newer = try UpdateFeeds.parse(feedJSON(build: 263_000_000), expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)
        let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertNil(UpdateFeeds.newestMacUpdate(installedBuild: 263_000_000, feeds: [older, newer], systemVersion: system))
        XCTAssertEqual(UpdateFeeds.newestMacUpdate(installedBuild: 262_990_000, feeds: [older, newer], systemVersion: system), newer)
    }

    func testSkipsBuildsForNewerMacOS() throws {
        let feed = try UpdateFeeds.parse(feedJSON(minimumSystemVersion: "27.1"), expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)
        let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
        XCTAssertNil(UpdateFeeds.newestMacUpdate(installedBuild: 1, feeds: [feed], systemVersion: system))
        XCTAssertTrue(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0).isAtLeast("13.0"))
    }

    func testSHA256CheckDetectsTampering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertTrue(UpdateFeeds.file(at: url, matchesSHA256: abc))
        XCTAssertTrue(UpdateFeeds.file(at: url, matchesSHA256: abc.uppercased()))
        try Data("abd".utf8).write(to: url)
        XCTAssertFalse(UpdateFeeds.file(at: url, matchesSHA256: abc))
    }

    func testInfoPlistCarriesTheEditionIdentityAndSparkleKey() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, Edition.identifier)
        let key = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true, "the EdDSA signature is checked before an update is unpacked")
        XCTAssertFalse(Edition.trustKeychainService.hasPrefix("dev.bridgey"))
        XCTAssertFalse(Edition.identityKeychainService.hasPrefix("dev.bridgey"))
    }

    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repoRoot.appendingPathComponent("scripts/rr/testdata/feed-sample/\(name)"))
    }

    /// Fixtures written by scripts/rr/rrrelease.py so the generator and parser stay in step.
    func testParsesTheCommittedGeneratorFixtures() throws {
        let expected: [(UpdateChannel, String, Int64)] = [
            (.stable, "1.0.0", 263_241_200), (.beta, "1.0.0-beta.1", 263_201_200), (.nightly, "1.0.0-nightly.20261116", 263_200_900),
        ]
        for (channel, version, build) in expected {
            let feed = try UpdateFeeds.parse(fixture("\(channel.rawValue).json"), expectedChannel: channel, appID: appID, assetURLPrefix: prefix)
            XCTAssertEqual(feed.macos?.version, version)
            XCTAssertEqual(feed.android?.version, version)
            XCTAssertEqual(feed.macos?.build, build)
        }
        // The feed as it was published for 0.11.0-rr.1 Beta 3 (no "version" in the entries) still parses.
        let legacy = try UpdateFeeds.parse(fixture("legacy-0.11-beta.json"), expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)
        XCTAssertNil(legacy.macos?.version)
        XCTAssertEqual(legacy.macos?.shortVersion, "0.11.0-rr.1-beta.3")
        XCTAssertEqual(legacy.macos?.build, Self.beta3Build)
    }

    /// The build of 0.11.0-rr.1 Beta 3, on every Mac when the 1.0 versions started.
    private static let beta3Build: Int64 = 263_191_654

    /// Beta 3's feed check, copied from UpdateLogic.swift at v0.11.0-rr.1-beta.3. Sparkle (the appcast) does
    /// the real updates and compares builds; this keeps the JSON feeds readable by the old parser too.
    private static func beta3Accepts(_ version: String, _ channel: UpdateChannel) -> Bool {
        guard version.range(of: #"^\d+\.\d+\.\d+-rr\.\d+(-(beta\.\d+|nightly\.\d{8}))?$"#, options: .regularExpression) != nil else { return false }
        switch channel {
        case .stable: return !version.contains("-beta.") && !version.contains("-nightly.")
        case .beta: return version.contains("-beta.")
        case .nightly: return version.contains("-nightly.")
        }
    }

    func testABeta3ClientReadsThe1_0Feeds() throws {
        for channel in UpdateChannel.allCases {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("\(channel.rawValue).json")) as? [String: Any])
            let macos = try XCTUnwrap(object["macos"] as? [String: Any])
            let android = try XCTUnwrap(object["android"] as? [String: Any])
            XCTAssertTrue(Self.beta3Accepts(try XCTUnwrap(macos["shortVersion"] as? String), channel), channel.rawValue)
            XCTAssertTrue(Self.beta3Accepts(try XCTUnwrap(android["versionName"] as? String), channel), channel.rawValue)
            XCTAssertFalse(Self.beta3Accepts(try XCTUnwrap(macos["version"] as? String), channel), "the plain name alone would be skipped")
            XCTAssertGreaterThan(try XCTUnwrap(macos["build"] as? Int64), Self.beta3Build)
        }
        // And the newest build wins across the boundary, as Sparkle orders by CFBundleVersion.
        let feeds = try UpdateChannel.allCases.map {
            try UpdateFeeds.parse(fixture("\($0.rawValue).json"), expectedChannel: $0, appID: appID, assetURLPrefix: prefix)
        } + [UpdateFeeds.parse(fixture("legacy-0.11-beta.json"), expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)]
        let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(UpdateFeeds.newestMacUpdate(installedBuild: Self.beta3Build, feeds: feeds, systemVersion: system)?.macos?.version, "1.0.0")
    }

    /// End-to-end dry run: BRIDGEY_RR_FEED_DIR=<dist>/<tag>/channels swift test --filter UpdateLogicTests
    func testParsesGeneratedFeedsWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_RR_FEED_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        var parsed = 0
        for channel in UpdateChannel.allCases {
            let url = directory.appendingPathComponent("\(channel.rawValue).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let feed = try UpdateFeeds.parse(data, expectedChannel: channel, appID: appID, assetURLPrefix: prefix)
            parsed += 1
            guard let macos = feed.macos else { continue }
            let releaseDirectory = directory.deletingLastPathComponent().appendingPathComponent("release")
            for asset in [macos.dmg, macos.zip] {
                let file = releaseDirectory.appendingPathComponent(URL(string: asset.url)!.lastPathComponent)
                if FileManager.default.fileExists(atPath: file.path) {
                    XCTAssertTrue(UpdateFeeds.file(at: file, matchesSHA256: asset.sha256), file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(parsed, 0)
    }
}
