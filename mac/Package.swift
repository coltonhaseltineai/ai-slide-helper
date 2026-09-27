// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveOutline",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiveOutline", targets: ["LiveOutline"]),
    ],
    targets: [
        .target(name: "MatcherCore"),
        .executableTarget(name: "LiveOutline", dependencies: ["MatcherCore"]),
        .testTarget(name: "MatcherCoreTests", dependencies: ["MatcherCore"]),
    ]
)
