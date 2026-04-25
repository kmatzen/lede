// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lede",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lede", targets: ["Lede"])
    ],
    dependencies: [
        // Auto-update for direct (non-App-Store) distribution. Sandboxed Mac
        // App Store builds don't load this updater (see UpdateController).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Lede",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Lede"
        ),
        .testTarget(
            name: "LedeTests",
            dependencies: ["Lede"],
            path: "Tests/LedeTests"
        ),
    ]
)
