// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BackMeUp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BackMeUp", targets: ["BackMeUp"]),
    ],
    dependencies: [
        // In-app updates. Only the app target links it; the core and its tests don't.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        // Everything testable: the System port, its real adapter, output parsers and the scheduler.
        .target(name: "BackMeUpCore"),
        // The menu bar app. Thin: wires the real System into the scheduler and draws the menu.
        .executableTarget(
            name: "BackMeUp",
            dependencies: ["BackMeUpCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "BackMeUpCoreTests",
            dependencies: ["BackMeUpCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
