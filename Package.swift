// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updates for the notarized download.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotchDeck",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NotchDeck"
        ),
    ]
)
