// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Barback",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Barback", targets: ["Barback"]),
        .library(name: "BarbackCore", targets: ["BarbackCore"]),
    ],
    targets: [
        // Pure, testable logic: settings, section layout, rehide policy, window-list parsing, hotkeys, notch geometry.
        .target(name: "BarbackCore", path: "Sources/BarbackCore"),
        // App shell: status items, global hotkey, hover monitor, settings window.
        .executableTarget(
            name: "Barback",
            dependencies: ["BarbackCore"],
            path: "Sources/Barback"
        ),
        .testTarget(name: "BarbackCoreTests", dependencies: ["BarbackCore"], path: "Tests/BarbackCoreTests"),
    ]
)
