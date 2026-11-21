// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MouseController",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mouse-controller", targets: ["mouse-controller"]),
    ],
    targets: [
        // Pure, side-effect-free logic: config model, trigger matching, debounce, key tables.
        .target(name: "MouseControllerCore", path: "src/Core"),
        // macOS integration: CGEventTap, IOHIDManager, event posting, CLI.
        .executableTarget(
            name: "mouse-controller",
            dependencies: ["MouseControllerCore"],
            path: "src/App"
        ),
        .testTarget(
            name: "MouseControllerCoreTests",
            dependencies: ["MouseControllerCore"],
            path: "tests/CoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
