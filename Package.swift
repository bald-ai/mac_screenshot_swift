// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac_screenshot_swift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScreenshotApp", targets: ["ScreenshotApp"]),
        .executable(name: "DevCLI", targets: ["DevCLI"])
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "ScreenshotApp",
            path: "Sources",
            exclude: ["DevCLI"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "DevCLI",
            path: "Sources/DevCLI"
        )
    ]
)
