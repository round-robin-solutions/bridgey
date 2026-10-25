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
        .executableTarget(
            name: "BridgeyMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "BridgeyMacTests", dependencies: ["BridgeyMac"]),
    ],
    swiftLanguageVersions: [.v5]
)
