// swift-tools-version:5.9
import PackageDescription

// Apple's on-device model framework must be weak-linked so the app still launches on macOS 14/15.
#if compiler(>=6.2)
let weakFoundationModels: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
#else
let weakFoundationModels: [LinkerSetting] = []
#endif

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
        .target(name: "EvalCore", dependencies: ["MatcherCore"]),
        .executableTarget(name: "LiveOutline", dependencies: [
            "MatcherCore",
            "EvalCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ], linkerSettings: weakFoundationModels),
        .testTarget(name: "MatcherCoreTests", dependencies: ["MatcherCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "EvalCoreTests", dependencies: ["EvalCore", "MatcherCore"]),
    ]
)
