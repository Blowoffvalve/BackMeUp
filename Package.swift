// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BackMeUp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BackMeUp", targets: ["BackMeUp"]),
    ],
    targets: [
        // Everything testable: the System port, its real adapter, output parsers and the scheduler.
        .target(name: "BackMeUpCore"),
        // The menu bar app. Thin: wires the real System into the scheduler and draws the menu.
        .executableTarget(name: "BackMeUp", dependencies: ["BackMeUpCore"]),
        .testTarget(
            name: "BackMeUpCoreTests",
            dependencies: ["BackMeUpCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
