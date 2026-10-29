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

    /// Fixture written by scripts/rr/rrrelease.py so the generator and parser stay in step.
    func testParsesTheCommittedGeneratorFixture() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("scripts/rr/testdata/feed-sample/beta.json"))
        let feed = try UpdateFeeds.parse(data, expectedChannel: .beta, appID: appID, assetURLPrefix: prefix)
        XCTAssertNotNil(feed.macos)
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
