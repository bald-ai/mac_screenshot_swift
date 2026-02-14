// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac_screenshot_swift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScreenshotApp", targets: ["ScreenshotApp"])
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "ScreenshotApp",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
