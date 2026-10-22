// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Arcky",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Arcky",
            path: "Sources/Arcky",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
