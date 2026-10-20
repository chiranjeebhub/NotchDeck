// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchUtility",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchUtility",
            path: "Sources/NotchUtility"
        ),
    ]
)
