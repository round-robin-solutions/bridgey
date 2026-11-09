// swift-tools-version: 5.10
import PackageDescription
import Foundation

let storeEdition = ProcessInfo.processInfo.environment["BRIDGEY_DISTRIBUTION"] == "app-store"

// The explicit allowlist is the build boundary. Everything else is excluded, including future full-app files.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let storeShared = ["ProtocolCrypto.swift", "SessionCrypto.swift", "PairingMessage.swift", "JSONInteger.swift", "ProtocolDecoding.swift", "ClipboardPayload.swift"]
let storeExclusions = ((try? FileManager.default.contentsOfDirectory(atPath: packageRoot.path)) ?? [])
    .filter { !["Store", "Sources"].contains($0) }
    + ((try? FileManager.default.contentsOfDirectory(atPath: packageRoot.appendingPathComponent("Sources").path)) ?? [])
        .filter { $0 != "BridgeyMac" }.map { "Sources/" + $0 }
    + ((try? FileManager.default.contentsOfDirectory(atPath: packageRoot.appendingPathComponent("Sources/BridgeyMac").path)) ?? [])
        .filter { !storeShared.contains($0) }.map { "Sources/BridgeyMac/" + $0 }

let package = storeEdition ? Package(
    name: "BridgeyStore",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BridgeyMacStore", targets: ["BridgeyMacStore"])],
    targets: [
        .executableTarget(name: "BridgeyMacStore", path: ".", exclude: storeExclusions, sources: [
            "Store/StoreApp.swift", "Store/StoreConnection.swift", "Store/StoreFiles.swift", "Store/StorePolicy.swift",
        ] + storeShared.map { "Sources/BridgeyMac/" + $0 }, swiftSettings: [.define("BRIDGEY_APP_STORE")]),
        .testTarget(name: "BridgeyStoreTests", dependencies: ["BridgeyMacStore"], path: "StoreTests"),
    ], swiftLanguageVersions: [.v5]
) : Package(
    name: "BridgeyMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BridgeyMac", targets: ["BridgeyMac"])],
    dependencies: [
        // Round Robin edition: EdDSA-signed self-updates. build-app.sh embeds Sparkle.framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.10.0")),
    ],
    targets: [
        // Official BLAKE3 C code, release 1.8.7, unmodified (CC0-1.0 or Apache-2.0). NEON on arm64.
        .target(
            name: "CBlake3",
            exclude: ["LICENSE_CC0", "LICENSE_A2", "BLAKE3_SOURCE.txt"],
            publicHeadersPath: "include",
            cSettings: [
                .define("BLAKE3_NO_SSE2"), .define("BLAKE3_NO_SSE41"),
                .define("BLAKE3_NO_AVX2"), .define("BLAKE3_NO_AVX512"),
            ]
        ),
        // libwebp 1.4.0 (BSD-3-Clause), unmodified: WebP encoding for Settings > Files > Before sending.
        .target(
            name: "CWebP",
            exclude: ["COPYING", "PATENTS", "LIBWEBP_SOURCE.txt"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .define("WEBP_USE_THREAD"), .unsafeFlags(["-w", "-O2"])]
        ),
        // llama.cpp release b11899 (MIT): the Apple framework, with Metal, that runs the on-device
        // code model (Codes from messages > On this Mac). build-app.sh embeds and signs it.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11899/llama-b11899-xcframework.zip",
            checksum: "500a6b8953d10542514daccccd8261e4522e3275692984aa53a380475ee0e625"
        ),
        .executableTarget(
            name: "BridgeyMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "CBlake3", "CWebP", "llama"]
        ),
        .testTarget(name: "BridgeyMacTests", dependencies: ["BridgeyMac"]),
    ],
    swiftLanguageVersions: [.v5]
)
