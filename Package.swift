// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lede",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lede", targets: ["Lede"])
    ],
    targets: [
        .executableTarget(
            name: "Lede",
            path: "Sources/Lede"
        )
    ]
)
