// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveOutline",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiveOutline", targets: ["LiveOutline"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MatcherCore"),
        .executableTarget(name: "LiveOutline", dependencies: [
            "MatcherCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "MatcherCoreTests", dependencies: ["MatcherCore"]),
    ]
)
