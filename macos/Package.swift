// swift-tools-version: 5.10
import PackageDescription

let package = Package(
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
        // llama.cpp release b11899 (MIT): the Apple framework, with Metal, that runs the on-device
        // code model (Codes from messages > On this Mac). build-app.sh embeds and signs it.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11899/llama-b11899-xcframework.zip",
            checksum: "500a6b8953d10542514daccccd8261e4522e3275692984aa53a380475ee0e625"
        ),
        .executableTarget(
            name: "BridgeyMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "CBlake3", "llama"]
        ),
        .testTarget(name: "BridgeyMacTests", dependencies: ["BridgeyMac"]),
    ],
    swiftLanguageVersions: [.v5]
)
