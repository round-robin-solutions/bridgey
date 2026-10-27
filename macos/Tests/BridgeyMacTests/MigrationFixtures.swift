import Foundation
import XCTest
@testable import BridgeyMac

/// The upgrade fixtures in `protocol/test-vectors/migrations/macos`: what a Mac on an older edition
/// release has on disk. Synthetic only (throwaway keys, made-up names). See docs/upgrade-policy.md.
enum MigrationFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../protocol/test-vectors/migrations/macos")
        .standardizedFileURL

    /// 2026-10-26T09:00:00Z: the base time of the fixtures.
    static let base = Date(timeIntervalSince1970: 1_793_005_200)

    // The throwaway ids and keys used across the fixtures.
    static let macID = "9e82d846-bd24-47b7-83ff-7e9210a5e6b2"
    static let macIdentityKey = "6lPC7/XZ/yo00dtHninKVbbYyRWipoAtl69CkLcLrCY="
    static let macPublicKey = "BPkaGu23YSYkmcoH7vpDN3l+2MvSRMbs6zejZC2NG0ym35BaDoo/qtcRIrKfymUxOtBHEXqnU/JRPfc4YUWIEAI="
    static let branchIdentityKey = "ulNbCMO5cY462+AiJEN4oqi7s7Aswz7rXSuV3BP43HE="
    static let phoneA = "d60c274e-f2b8-452d-8031-912d80624414"
    static let phoneB = "662af8a6-40db-4ee9-8fa4-7a8d96bc57aa"
    static let phoneC = "774b2849-c24b-4801-9f28-adc1791de920"
    static let phoneD = "7e70d34b-7dc9-46ba-859a-d4bdda9f67d2"
    static let keyA = "BFkZcBf13AVnQfYMltgYTNL6PBvjMvP0t5QSidXNJnxmfDhrfZ4EXC/R3f+lBWjffxuXzNPmqtJ0oaNiDwZA8J4="
    static let keyB = "BEa9WLz3KQw/cIYnQE/fSh+LB+d9HhjjaE17Y4gSq6KA3tLU2XtUgoFc4iI2aomR2EaHJrFf0k6udwCU+VVl9UQ="
    static let keyC = "BPDrYwgn95Rt7OA82fv5jhC9J0Jt2CFaaUBQaB6FC5Vlya5tFv7Aqm+0lwYgkdsYEQPHVwt+74z31vXgHTE4PDA="

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    /// A plist fixture as the dictionary UserDefaults would hold.
    static func defaults(_ path: String) throws -> [String: Any] {
        let value = try PropertyListSerialization.propertyList(from: data(path), options: [], format: nil)
        return try XCTUnwrap(value as? [String: Any])
    }

    /// A fresh folder under the temporary directory, never the user's Application Support.
    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-migration-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
