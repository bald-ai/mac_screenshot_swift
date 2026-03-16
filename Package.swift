// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac_screenshot_swift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Zoomies", targets: ["Zoomies"])
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "Zoomies",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ZoomiesTests",
            dependencies: ["Zoomies"],
            path: "Tests/ZoomiesTests"
        )
    ]
)
